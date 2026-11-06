#!/usr/bin/env bash
# tsp-ddfd23ce0e7fdf05fb50: with the A133 Headphone Playback Volume inverted (7 = 0 dB), the
# image default must be 7 (loudest, raw register 0), not 0 (-42 dB).
set -euo pipefail
f=$(cd "$(dirname "$0")/.." && pwd)/device-config/alsa/mixer-defaults.sun4i-codec-7.x
grep -Fqx 'Headphone Playback Volume=7' "$f" || { echo "FAIL default is not Headphone Playback Volume=7"; exit 1; }
echo "PASS hp volume default inverted"
