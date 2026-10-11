#!/usr/bin/env bash
# Verify the browser platform defaults on an extracted rootfs (bd tsp-be9lx):
#   - /etc/machine-info sets CHASSIS=handset, which WebKit's GLib chassis
#     detection reads to send a mobile user agent, so UA-sniffing sites serve
#     phone layouts on this handheld.
#   - the systemd-resolved drop-in resolves DNSOverTLS=opportunistic.
#   - systemd-coredump ProcessSizeMax/ExternalSizeMax cap a core at 64 MiB, so
#     a crashing web process cannot fill the card. Unset keys count as
#     systemd's multi-gigabyte defaults and fail the cap.
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

# Effective value of a [Coredump] key across /etc/systemd/coredump.conf and its
# drop-in dir, in systemd's merge order (lexicographic; the last assignment of
# a key wins). Comments and blank lines are skipped.
coredump_effective() {
    local key="$1" val="" files=() f line
    [ -f "${ROOTFS}/etc/systemd/coredump.conf" ] \
        && files+=( "${ROOTFS}/etc/systemd/coredump.conf" )
    if [ -d "${ROOTFS}/etc/systemd/coredump.conf.d" ]; then
        while IFS= read -r f; do
            files+=( "$f" )
        done < <(find "${ROOTFS}/etc/systemd/coredump.conf.d" -maxdepth 1 -type f -name '*.conf' \
                 | LC_ALL=C sort)
    fi
    for f in ${files[@]+"${files[@]}"}; do
        while IFS= read -r line || [ -n "${line}" ]; do
            line="${line#"${line%%[![:space:]]*}"}"
            case "${line}" in
                '#'*|';'*|'') continue ;;
                "${key}="*)
                    val="${line#"${key}="}"
                    val="${val%%[[:space:]]*}"
                    ;;
            esac
        done < "$f"
    done
    printf '%s' "${val}"
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
