#!/usr/bin/env bash
# tsp-mc9m.60.29.33.16 RED/GREEN gate (first stage): a whole-image owned-SPL build
# must also stage the Odyssey SDR50 opt-in DTB on boot-resource FAT p4 as
# dtb-sdr50.bin, beside the shipping dtb.bin, WITHOUT changing the default boot.
# The kit swaps it in (snapshot, stage, reboot, restore) for the SD UHS proof.
# The worker keeps this stage and adds behavioural coverage beside it.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
s="${repo}/scripts/build-sd-image.sh"
grep -q '::/dtb-sdr50.bin' "${s}" || { echo "FAIL reason=dtb_sdr50_not_staged hint=mcopy the sun50i-a133-pocketforge-odyssey-sdr50.dtb to ::/dtb-sdr50.bin in the owned-spl branch of scripts/build-sd-image.sh"; exit 1; }
grep -q '::/dtb.bin' "${s}" || { echo "FAIL reason=default_dtb_no_longer_staged"; exit 1; }
echo PASS
