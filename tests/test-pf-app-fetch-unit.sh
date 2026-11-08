#!/usr/bin/env bash
# pf-app-fetch@.service and its boot sweep (bd tsp-ziac.4.3.5, W3 of tsp-ziac.4.3).
# Static contract of the unit (identity, storage, the enforced egress floor, the
# enforced-vs-declared comment), the tmpfiles sweep, the build/install wiring, and
# systemd-analyze verify of the instantiated unit.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
unit="${root}/rootfs-overlay/etc/systemd/system/pf-app-fetch@.service"
app_unit="${root}/rootfs-overlay/etc/systemd/system/pf-app@.service"
sweep="${root}/rootfs-overlay/usr/lib/tmpfiles.d/pf-app-fetch.conf"
dockerfile="${root}/build/Dockerfile.pf"
installer="${root}/scripts/install-default-app-support.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

test -f "${unit}" || fail "missing ${unit}"
test -f "${sweep}" || fail "missing ${sweep}"

# Exactly-one-line directives the contract depends on.
require() {
    local line="$1" count
    count="$(grep -cxF -- "${line}" "${unit}" || true)"
    [ "${count}" = 1 ] || fail "pf-app-fetch@.service needs exactly one '${line}' (found ${count})"
}
require 'Type=oneshot'
require 'User=gamer'
require 'Group=gamer'
require 'RequiresMountsFor=/var/lib/pocketforge/apps'
require 'Conflicts=pf-app@%i.service'
require 'ExecStart=/usr/bin/pf-app-fetch --app-id %i --descriptor /opt/pocketforge/apps/%i/app.toml --state-dir /var/lib/pocketforge/apps/%i'
require 'TimeoutStartSec=30min'
require 'KillSignal=SIGTERM'
require 'UMask=0022'
require 'ProtectSystem=strict'
require 'ProtectHome=yes'
require 'PrivateDevices=yes'
require 'PrivateTmp=yes'
require 'InaccessiblePaths=-/run/pocketforge'
require 'NoExecPaths=/'
require 'ExecPaths=/usr/bin/pf-app-fetch'
require 'RestrictAddressFamilies=AF_INET AF_INET6'
require 'IPAddressAllow=localhost'
require 'NoNewPrivileges=yes'
require 'CapabilityBoundingSet='
require 'AmbientCapabilities='
require 'ProtectProc=invisible'
require 'RestrictNamespaces=yes'
require 'MemoryDenyWriteExecute=yes'
deny="$(sed -n 's/^IPAddressDeny=//p' "${unit}")"
for prefix in link-local multicast 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 fc00::/7; do
    case " ${deny} " in *" ${prefix} "*) ;; *) fail "IPAddressDeny= lacks ${prefix}" ;; esac
done
grep -q '^SystemCallFilter=@system-service landlock_create_ruleset landlock_add_rule landlock_restrict_self$' "${unit}" \
    || fail "the seccomp allow-list must keep the three Landlock syscalls"

# Same state directory, mode and owner as pf-app@, so systemd never re-chowns the payload.
for line in 'StateDirectory=pocketforge/apps/%i' 'StateDirectoryMode=0700' 'User=gamer' 'Group=gamer'; do
    grep -qxF -- "${line}" "${app_unit}" || fail "pf-app@.service no longer has '${line}'"
    require "${line}"
done
# Its only writable path is the StateDirectory.
! grep -Eq '^(ReadWritePaths|BindPaths|CacheDirectory|LogsDirectory|RuntimeDirectory|ConfigurationDirectory)=' "${unit}" \
    || fail "pf-app-fetch@ must write only its StateDirectory"
# Dormant: started by the session authority (W4), never enabled.
! grep -q '^\[Install\]' "${unit}" || fail "pf-app-fetch@.service must have no [Install]"
! grep -Eq '^(User|Group)=root$|^DynamicUser=' "${unit}" || fail "pf-app-fetch@ must run as gamer"

# The comment block states what is enforced and what is only declared.
grep -q '^# EGRESS: what is ENFORCED and what is only DECLARED\.$' "${unit}" || fail "missing egress header"
grep -q '^# Enforced by the kernel' "${unit}" || fail "missing enforced list"
grep -q '^# Declared, and checked in the binary only (NOT kernel-enforced):$' "${unit}" || fail "missing declared list"
grep -q 'host-level enforcement is a follow-on bead' "${unit}" || fail "missing the follow-on note"

# Boot sweep: exactly the two leftover globs, nothing that could touch a receipt or payload.
want_sweep=$'R /var/lib/pocketforge/apps/*/.pf-fetch/.staging.*\nR /var/lib/pocketforge/apps/*/.pf-fetch/.old.*'
[ "$(grep -v '^#' "${sweep}" | grep -v '^$')" = "${want_sweep}" ] || fail "unexpected tmpfiles sweep lines"

# Build and install wiring.
grep -F 'cargo build --offline --locked --release --target "${PF_RUNTIME_TARGET}" -p pf-app-fetch --bin pf-app-fetch' "${dockerfile}" >/dev/null \
    || fail "runtime stage does not build pf-app-fetch"
grep -F 'CC_aarch64_unknown_linux_musl=aarch64-none-linux-gnu-gcc' "${dockerfile}" >/dev/null \
    || fail "runtime stage must point ring's cc-rs at the Arm toolchain"
grep -F 'pf-app-fetch is dynamically linked (expected static musl)' "${dockerfile}" >/dev/null || fail "no static gate"
grep -F 'pf-app-fetch is not aarch64' "${dockerfile}" >/dev/null || fail "no e_machine gate"
grep -F "grep -qa 'PF_APP_FETCH_TEST_'" "${dockerfile}" >/dev/null || fail "no hook-free gate"
grep -F 'install -D -m 0755 "${APP_FETCH_BIN}" /out/bin/pf-app-fetch' "${dockerfile}" >/dev/null || fail "no stage install"
grep -F 'install -D -m 0755 "${fetcher}" "${rootfs}/usr/bin/pf-app-fetch"' "${installer}" >/dev/null || fail "no rootfs install"
grep -F 'pf-app-fetch@.service must be installed but never enabled' "${installer}" >/dev/null || fail "no never-enabled gate"

# systemd-analyze verify of an instance, when the host has it (CI runners do).
if command -v systemd-analyze >/dev/null 2>&1; then
    scratch="$(mktemp -d)"
    trap 'rm -rf "${scratch}"' EXIT
    verify="${scratch}/root"
    units="${verify}/etc/systemd/system"
    mkdir -p "${units}" "${verify}/usr/bin" "${verify}/usr/lib/tmpfiles.d"
    cp "${unit}" "${units}/pf-app-fetch@.service"
    for target in sysinit.target basic.target shutdown.target local-fs.target network.target; do
        printf '[Unit]\nDescription=fixture\n' >"${units}/${target}"
    done
    for service in pf-app@.service systemd-resolved.service systemd-tmpfiles-setup.service; do
        printf '[Unit]\nDescription=fixture\n[Service]\nType=oneshot\nExecStart=/usr/bin/test\n' \
            >"${units}/${service}"
    done
    for binary in pf-app-fetch test; do
        printf '#!/bin/sh\nexit 0\n' >"${verify}/usr/bin/${binary}"
        chmod 0755 "${verify}/usr/bin/${binary}"
    done
    if ! systemd-analyze verify --man=no --root="${verify}" \
        pf-app-fetch@org.pocketforge.fixture.service >"${scratch}/verify.out" 2>&1; then
        cat "${scratch}/verify.out" >&2
        fail "systemd-analyze rejected pf-app-fetch@.service"
    fi
    if grep -i 'pf-app-fetch' "${scratch}/verify.out" >&2; then
        fail "systemd-analyze reported a pf-app-fetch@.service warning"
    fi
    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        cp "${sweep}" "${verify}/usr/lib/tmpfiles.d/pf-app-fetch.conf"
        state="${verify}/var/lib/pocketforge/apps/org.example/.pf-fetch"
        mkdir -p "${state}/.staging.ab/tree.0" "${state}/.old.cd/data" "${verify}/var/lib/pocketforge/apps/org.example/data"
        printf '{}\n' >"${state}/receipt.json"
        printf '{}\n' >"${state}/result.json"
        systemd-tmpfiles --root="${verify}" --remove pf-app-fetch.conf >/dev/null 2>&1 \
            || systemd-tmpfiles --root="${verify}" --remove >/dev/null
        [ ! -e "${state}/.staging.ab" ] && [ ! -e "${state}/.old.cd" ] || fail "boot sweep left leftovers"
        [ -f "${state}/receipt.json" ] && [ -f "${state}/result.json" ] \
            && [ -d "${verify}/var/lib/pocketforge/apps/org.example/data" ] || fail "boot sweep removed live state"
    fi
fi

echo 'PASS: pf-app-fetch@.service identity, storage, enforced egress floor, boot sweep and wiring'
