#!/bin/sh
set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
dockerfile="$root/build/Dockerfile.pf"
customize="$root/scripts/build-rootfs.sh"
gate="$root/rootfs-overlay/usr/lib/pocketforge/open-gpu-gate.sh"
unit="$root/rootfs-overlay/etc/systemd/system/pf-open-gpu-gate.service"
required="$root/rootfs-overlay/etc/systemd/system/pf-open-gpu-required.conf"

# Literal Dockerfile variables are intentional in these structural assertions.
# shellcheck disable=SC2016
grep -F 'COPY --from=vendor-manifest-src public /work/vm/public' "$dockerfile" >/dev/null
grep -F -- '--cid-version=1 --raw-leaves' "$dockerfile" >/dev/null
grep -F 'group=pvr-fw-open-22.102.54.38' "$dockerfile" >/dev/null
grep -F 'b571cdd90312c20fe87f14aae43484f7279859921ae3abe58e935412040c7f98' "$dockerfile" >/dev/null
grep -F 'LICENSE.powervr' "$dockerfile" >/dev/null
grep -F 'powervr.ko (in-tree, kernel-tsp)' "$customize" >/dev/null
grep -F "grep -F 'img,img-rogue'" "$customize" >/dev/null
grep -F '/lib/firmware/powervr/rogue_22.102.54.38_v1.fw' "$gate" >/dev/null
grep -F 'llvmpipe' "$gate" >/dev/null
grep -F 'PF-OPEN-GPU PASS:' "$gate" >/dev/null
grep -F 'timeout 25s env SDL_VIDEODRIVER=sunxifb' "$gate" >/dev/null
if grep -F 'pf-take-panel' "$gate" >/dev/null || grep -F 'systemctl' "$gate" >/dev/null; then
    echo 'open GPU gate must not wait on the foreground handoff or another unit' >&2
    exit 1
fi
grep -F 'Before=pf-shell-selected.service pocketforge-menu.service pocketforge-placeholder.service' "$unit" >/dev/null
if grep -Eq '^[[:space:]]*(Condition|Assert)[A-Za-z]*=' "$unit"; then
    echo 'open GPU gate must not skip on a missing required artifact' >&2
    exit 1
fi
grep -F 'multi-user.target.wants/pf-open-gpu-gate.service' "$customize" >/dev/null
grep -Fx 'Requires=pf-open-gpu-gate.service' "$required" >/dev/null
grep -Fx 'After=pf-open-gpu-gate.service' "$required" >/dev/null
grep -F 'for ui_unit in pf-shell-selected.service pocketforge-menu.service pocketforge-placeholder.service' "$customize" >/dev/null
grep -F '20-open-gpu-required.conf' "$customize" >/dev/null

# Requires + After makes a failed gate a prerequisite failure, rather than mere
# ordering. Assert both edges as the unit-file-level negative-control contract.
awk '
    /^Requires=pf-open-gpu-gate.service$/ { requires=1 }
    /^After=pf-open-gpu-gate.service$/ { after=1 }
    END { exit !(requires && after) }
' "$required"

# The gate may wait for device discovery, but must not wait for the foreground
# target or any UI unit that is itself gated by this service.
after="$(sed -n 's/^After=//p' "$unit")"
for forbidden in pocketforge-foreground.target pf-shell-selected.service pocketforge-menu.service pocketforge-placeholder.service; do
    case " $after " in
        *" $forbidden "*)
            echo "open GPU gate has cyclic After= dependency on $forbidden" >&2
            exit 1
            ;;
    esac
done

echo 'open-gpu-integration=PASS'
