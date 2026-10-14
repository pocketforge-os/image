#!/usr/bin/env bash
# The open-GPU probe's embedded Venus writeback SPIR-V (tsp-mc9m.41.984.54.18):
# decodes the uint32 array in tools/open-gpu-probe.c and proves the strict
# virtual readback contract (GLCompute 'main', LocalSize 1 1 1, StorageBuffer
# Binding=0/DescriptorSet=0 in a Block struct, OpConstant 0x5046564e,
# OpStore) with corruption controls for the magic, reserved word, execution
# model, pattern constant and binding decoration.
#
# It runs no container, no user or system manager and no Vulkan loader.
#
# Usage: tests/test-open-gpu-probe-spirv.sh
# Exit status: 0 PASS, 1 FAIL, 75 BLOCKED.
set -euo pipefail

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
python3 -B "$root/tests/test-open-gpu-probe-spirv.py" "$@"
