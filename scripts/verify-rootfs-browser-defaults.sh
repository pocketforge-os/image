#!/usr/bin/env bash
# Verify the browser platform defaults on an extracted rootfs (bd tsp-be9lx):
#   - /etc/machine-info sets CHASSIS=handset, which WebKit's GLib chassis
#     detection reads to send a mobile user agent, so UA-sniffing sites serve
#     phone layouts on this handheld.
#   - the systemd-resolved drop-in resolves DNSOverTLS=opportunistic.
#   - systemd-coredump ProcessSizeMax/ExternalSizeMax cap a core at 64 MiB, so
#     a crashing web process cannot fill the card. The effective value is
#     merged across every config path systemd-coredump reads (/etc, /run,
#     /usr/local/lib, /usr/lib main files and drop-in dirs, with same-name
#     masking and name-order merge), so no vendor or runtime drop-in can
#     silently raise the cap. Unset (or blanked) keys count as systemd's
#     multi-gigabyte defaults and fail the cap.
#   - /usr/share/applications/pocketforge-mimeapps.list registers the browser
#     as the default http/https handler (URL-open design item 6).
#   - pf-app@.service gives each app its own cache dir (XDG_CACHE_HOME +
#     CacheDirectory + ReadWritePaths); required to exist with --expect-pf-app
#     (open profiles), content-checked whenever present.
set -euo pipefail

fatal() { echo "FATAL: browser defaults: $*" >&2; exit 1; }

ROOTFS=""
EXPECT_PF_APP=0
for arg in "$@"; do
    case "${arg}" in
        --expect-pf-app) EXPECT_PF_APP=1 ;;
        -*) echo "usage: verify-rootfs-browser-defaults.sh ROOTFS [--expect-pf-app]" >&2; exit 2 ;;
        *)
            [ -z "${ROOTFS}" ] || { echo "usage: verify-rootfs-browser-defaults.sh ROOTFS [--expect-pf-app]" >&2; exit 2; }
            ROOTFS="${arg}"
            ;;
    esac
done
[ -n "${ROOTFS}" ] || { echo "usage: verify-rootfs-browser-defaults.sh ROOTFS [--expect-pf-app]" >&2; exit 2; }

# --- chassis -------------------------------------------------------------------
MACHINE_INFO="${ROOTFS}/etc/machine-info"
[ -f "${MACHINE_INFO}" ] || fatal "/etc/machine-info is missing"
grep -Eq '^CHASSIS=handset$' "${MACHINE_INFO}" \
    || fatal "/etc/machine-info does not set CHASSIS=handset (WebKit mobile user agent needs it)"

# --- DNS-over-TLS ---------------------------------------------------------------
RESOLVED_CONF="${ROOTFS}/etc/systemd/resolved.conf.d/pocketforge.conf"
[ -f "${RESOLVED_CONF}" ] || fatal "resolved drop-in /etc/systemd/resolved.conf.d/pocketforge.conf is missing"
grep -Eq '^DNSOverTLS=opportunistic$' "${RESOLVED_CONF}" \
    || fatal "resolved drop-in does not resolve DNSOverTLS=opportunistic"

# --- coredump size cap -----------------------------------------------------------
# Convert a systemd size suffix to bytes (K/M/G/T, optional trailing B, all
# base-1024 like systemd's parse_size; "infinity" yields the literal word).
size_to_bytes() {
    local v="$1"
    if [[ "${v,,}" == infinity ]]; then
        echo infinity
        return 0
    fi
    if [[ "$v" =~ ^([0-9]+)([KkMmGgTt])?[Bb]?$ ]]; then
        local n="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2],,}" in
            '') echo "${n}" ;;
            k)  echo $(( n * 1024 )) ;;
            m)  echo $(( n * 1024 * 1024 )) ;;
            g)  echo $(( n * 1024 * 1024 * 1024 )) ;;
            t)  echo $(( n * 1024 * 1024 * 1024 * 1024 )) ;;
        esac
        return 0
    fi
    return 1
}

# Last assignment of `key` inside the [Coredump] section of one file, printed
# as "<found>\t<value>". found=1 when the key is assigned at all — including
# `Key=` (an empty assignment), which systemd treats as a reset to its
# compiled-in default. Lines in other sections, comments and blanks are
# ignored.
coredump_file_value() {
    local file="$1" key="$2" line section="" out="" found=0
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "${line}" in
            '#'*|';'*|'') continue ;;
            '['*']')
                section="${line%%[[:space:]]*}"
                continue
                ;;
        esac
        [ "${section}" = '[Coredump]' ] || continue
        case "${line}" in
            "${key}="*)
                found=1
                out="${line#"${key}="}"
                out="${out%%[[:space:]]*}"
                ;;
        esac
    done < "${file}"
    printf '%s\t%s' "${found}" "${out}"
}

# Effective value of a [Coredump] key, merged the way systemd-coredump merges
# its configuration:
#   - the main file is the first that exists of /etc, /run, /usr/local/lib,
#     /usr/lib systemd/coredump.conf (a higher-priority dir masks the others);
#   - every *.conf in the four coredump.conf.d drop-in dirs is then applied in
#     lexicographic order of its file NAME across all dirs (so a later vendor
#     file in /usr/lib beats an earlier one in /etc), with a same-name file in
#     a higher-priority dir masking lower-priority copies;
#   - the last assignment of the key wins.
coredump_effective() {
    local key="$1" f name entry
    local -a files=()
    for f in \
        "${ROOTFS}/etc/systemd/coredump.conf" \
        "${ROOTFS}/run/systemd/coredump.conf" \
        "${ROOTFS}/usr/local/lib/systemd/coredump.conf" \
        "${ROOTFS}/usr/lib/systemd/coredump.conf"; do
        if [ -f "${f}" ]; then
            files+=( "${f}" )
            break
        fi
    done
    local -A seen=()
    local -a entries=()
    local d
    for d in \
        "${ROOTFS}/etc/systemd/coredump.conf.d" \
        "${ROOTFS}/run/systemd/coredump.conf.d" \
        "${ROOTFS}/usr/local/lib/systemd/coredump.conf.d" \
        "${ROOTFS}/usr/lib/systemd/coredump.conf.d"; do
        [ -d "${d}" ] || continue
        while IFS= read -r f; do
            name="${f##*/}"
            [ -n "${seen["${name}"]:-}" ] && continue
            seen["${name}"]=1
            entries+=( "${name}"$'\t'"${f}" )
        done < <(find "${d}" -maxdepth 1 -type f -name '*.conf')
    done
    if [ "${#entries[@]}" -gt 0 ]; then
        while IFS= read -r entry; do
            files+=( "${entry#*$'\t'}" )
        done < <(printf '%s\n' "${entries[@]}" | LC_ALL=C sort)
    fi
    local found last="" rec
    for f in ${files[@]+"${files[@]}"}; do
        rec="$(coredump_file_value "${f}" "${key}")"
        found="${rec%%$'\t'*}"
        if [ "${found}" = 1 ]; then
            last="${rec#*$'\t'}"
        fi
    done
    printf '%s' "${last}"
}

require_cap() {
    local key="$1" val bytes
    val="$(coredump_effective "${key}")"
    [ -n "${val}" ] || fatal "systemd-coredump ${key} is unset; systemd's multi-gigabyte default could fill the card (need <= 64 MiB)"
    bytes="$(size_to_bytes "${val}")" || fatal "systemd-coredump ${key}='${val}' is not a parseable size"
    [ "${bytes}" != infinity ] || fatal "systemd-coredump ${key}=infinity does not cap a core at 64 MiB"
    if ! { [ "${bytes}" -ge 1 ] && [ "${bytes}" -le $(( 64 * 1024 * 1024 )) ]; }; then
        fatal "systemd-coredump ${key}=${val} (${bytes} bytes) does not cap a core at 64 MiB"
    fi
}
require_cap ProcessSizeMax
require_cap ExternalSizeMax

# --- default browser files -------------------------------------------------------
MIMEAPPS="${ROOTFS}/usr/share/applications/pocketforge-mimeapps.list"
[ -f "${MIMEAPPS}" ] || fatal "/usr/share/applications/pocketforge-mimeapps.list is missing"
grep -Eq '^\[Default Applications\]$' "${MIMEAPPS}" \
    || fatal "pocketforge-mimeapps.list has no [Default Applications] section"
grep -Eq '^x-scheme-handler/http=pocketforge-browser\.desktop$' "${MIMEAPPS}" \
    || fatal "pocketforge-mimeapps.list does not name pocketforge-browser.desktop for x-scheme-handler/http"
grep -Eq '^x-scheme-handler/https=pocketforge-browser\.desktop$' "${MIMEAPPS}" \
    || fatal "pocketforge-mimeapps.list does not name pocketforge-browser.desktop for x-scheme-handler/https"

# --- pf-app@ per-app cache --------------------------------------------------------
APP_UNIT="${ROOTFS}/etc/systemd/system/pf-app@.service"
if [ "${EXPECT_PF_APP}" = 1 ] && [ ! -f "${APP_UNIT}" ]; then
    fatal "pf-app@.service is missing on a profile that must ship it"
fi
if [ -f "${APP_UNIT}" ]; then
    grep -Fqx 'Environment=XDG_CACHE_HOME=/var/cache/pocketforge/apps/%i' "${APP_UNIT}" \
        || fatal "pf-app@.service does not set Environment=XDG_CACHE_HOME=/var/cache/pocketforge/apps/%i"
    grep -Fqx 'CacheDirectory=pocketforge/apps/%i' "${APP_UNIT}" \
        || fatal "pf-app@.service does not set CacheDirectory=pocketforge/apps/%i"
    grep -Eq '^ReadWritePaths=(.* )?/var/cache/pocketforge/apps/%i( .*)?$' "${APP_UNIT}" \
        || fatal "pf-app@.service ReadWritePaths does not include /var/cache/pocketforge/apps/%i"
fi

pf_app_cache=no
[ -f "${APP_UNIT}" ] && pf_app_cache=yes
echo "  rootfs browser defaults self-check: chassis=handset DNSOverTLS=opportunistic coredump<=64MiB mimeapps=pocketforge-browser.desktop pf-app-cache=${pf_app_cache}"
