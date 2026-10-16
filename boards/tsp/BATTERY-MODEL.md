# TSP AXP717 fuel-gauge model

The TrimUI Smart Pro fuel-gauge model is a 128-byte vendor calibration blob.
It is not checked into this repository. Image assembly extracts it
reproducibly from the preserved vendor DTB:

- custody group: `sunxi-a133-boot-chain` (`redistributable = false`)
- source: `sunxi/a133/boot-chain/vendor-dtb.bin`
- source SHA-256: `f6486899b53e005f0df54bbac4b1183710f73e90efd94cd7cbde58cdfba792ac`
- source node/property: `/axp2202-parameter/battery-model` / `parameter`
- extracted size: 128 bytes
- extracted SHA-256: `b44940da920519986192f758eb4eb65eea5728179ebdd28393671be4c5557c5a`
- installed path: `/lib/firmware/x-powers/axp717-tsp-battery-model.bin`

`scripts/extract-a133-battery-model.py` pins and validates both digests before
atomically installing the generated firmware. `scripts/verify-rootfs-firmware.sh`
then independently verifies the final rootfs artifact.

This follows the owner-approved Debian non-free-firmware custody model
(2026-09-22 option A) and the authorized clean-room extraction described in
`PMIC-RUNTIME-USBC.md` R-A1. The public kernel consumes the installed file via
`request_firmware`; it must not contain a DTS byte array copy.
