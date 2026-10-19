#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <rootfs> <kernel-repo> <device-id> <source-root>" >&2
    exit 2
fi

rootfs="$1"
kernel_repo="$2"
device_id="$3"
source_root="$4"

case "${device_id}" in
    a133-open-7x|a133-open-7x-gpu|a133-open-7x-gpu-cts|a133-open-7x-gpu-noradio|a133-open-7x-gpu-spl-trace)
        if [ "${kernel_repo}" != kernel-sunxi-7.x ]; then
            echo "memory-policy install: FAIL device=${device_id} kernel=${kernel_repo} expected=kernel-sunxi-7.x" >&2
            exit 1
        fi
        ;;
    *)
        echo "memory-policy install: NOT-SHIPPED device=${device_id} kernel=${kernel_repo}"
        exit 0
        ;;
esac

overlay="${source_root}/rootfs-overlay"

install_policy_file() {
    relative="$1"
    source="${overlay}/${relative}"
    destination="${rootfs}/${relative}"

    [ -f "${source}" ] || {
        echo "memory-policy install: FAIL missing ${source}" >&2
        exit 1
    }
    install -d "$(dirname "${destination}")"
    install -m 0644 "${source}" "${destination}"
}

for relative in \
    etc/systemd/zram-generator.conf \
    etc/sysctl.d/90-pocketforge-memory.conf \
    usr/lib/tmpfiles.d/pocketforge-memory.conf \
    etc/systemd/system/apps.slice \
    etc/systemd/system/pfsession.slice \
    etc/systemd/system/systemd-zram-setup@zram0.service.d/10-pocketforge-mem-limit.conf \
    etc/systemd/system/pf-session-authorityd.service.d/10-memory-policy.conf \
    etc/systemd/system/pf-prefsd.service.d/10-memory-policy.conf \
    etc/systemd/system/pf-powerd.service.d/10-memory-policy.conf \
    etc/systemd/system/pf-input-decode.service.d/10-memory-policy.conf \
    etc/systemd/system/pf-fcitx5.service.d/10-memory-policy.conf \
    etc/systemd/system/pf-osk.service.d/10-memory-policy.conf \
    etc/systemd/system/pf-ime-bus.service.d/10-memory-policy.conf; do
    install_policy_file "${relative}"
done

echo "memory-policy install: PASS device=${device_id} kernel=${kernel_repo} zram_mem_limit=448M session_slice=pfsession.slice"
