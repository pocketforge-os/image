# TrimUI Smart Pro Device Tree Source — Notes

## Source and provenance

`trimui-smart-pro.dts` was decompiled from the vendor DTB extracted from
our device's `boot_package.fex`:

```
vendor-dtb.bin  SHA-256: f6486899b53e005f0df54bbac4b1183710f73e90efd94cd7cbde58cdfba792ac
```

Decompiled with `dtc -I dtb -O dts` inside the `pocketforge/build:10.3-2021.07-bookworm`
container. The vendor DTB lives at `blobs/tsp/boot-chain/vendor-dtb.bin` (reference-only).

## Round-trip verification

Compiling this `.dts` back to DTB produces **byte-identical** content to the
vendor DTB (148,439 bytes of FDT content; the vendor file has 4,137 bytes of
trailing zero-padding to reach 152,576 bytes total, which is standard for
boot_package.fex alignment).

## Compile command

```sh
dtc -I dts -O dtb \
  -W no-simple_bus_reg \
  -W no-unique_unit_address \
  -W no-alias_paths \
  -W no-pwms_property \
  -W no-interrupt_provider \
  -W no-spi_bus_reg \
  -o dtb.bin \
  image/boards/tsp/trimui-smart-pro.dts
```

The `-W no-*` flags suppress dtc warnings that are standard Allwinner vendor
DTS noise (duplicate PWM unit addresses, missing reg/ranges on pseudo-nodes,
leading-zero unit address formatting). These are harmless and present in every
Allwinner A133 DTS including KNULLI's tracked copy. The output DTB is
functionally identical with or without these flags; they only suppress stderr.

Additional warnings remain unsuppressed (`unit_address_vs_reg`,
`unit_address_format`, `clocks_property`, `iommus_property`, etc.) — these are
also vendor DTS artifacts and do not affect the compiled DTB output.

## Differences from KNULLI's tracked DTS

KNULLI publishes a tracked copy at:
```
https://github.com/knulli-cfw/knulli-linux/blob/knulli-main/package/boot/uboot-a133/trimui-smart-pro/boot_package/trimui-smart-pro.dts
```

Our vendor-decompiled `.dts` and KNULLI's differ in **11 properties** — all are
KNULLI's tuning tweaks, not vendor-original values:

| Property | Our vendor DTB | KNULLI | Meaning |
| --- | --- | --- | --- |
| `pa_msleep_time` | 0x28 (40 ms) | 0x78 (120 ms) | Audio PA sleep delay |
| CPU OPP 408/600/720/816 MHz voltages | 0.900 V | 0.850 V | CPU undervolting at low OPPs |
| CPU OPP 1008 MHz voltage | 0.938 V | 0.900 V | CPU undervolting |
| CPU OPP 1200 MHz voltage | 1.020 V | 0.975 V | CPU undervolting |
| CPU OPP 1416 MHz voltage | 1.100 V (single) | 1.050 V (range) | CPU undervolting |
| CPU OPP 1608 MHz voltage | 1.180 V min | 1.130 V min | CPU undervolting |
| CPU OPP 1800 MHz voltage | 1.250 V min | 1.200 V min | CPU undervolting |
| GPU max operating-point | 700 MHz | 720 MHz | GPU overclock |

Our `.dts` uses the **vendor-original** values from the device's own
`boot_package.fex`. These are the values this specific hardware was shipped
with and has been running successfully.

## Display rotation

The Allwinner DE2.0 disp engine rotation is **implicit** in the DTS, not an
explicit property. The rotation mechanism:

- `fb0_width = 0x500` (1280) — landscape framebuffer width
- `fb0_height = 0x2d0` (720) — landscape framebuffer height
- `lcd_x = 0x2d0` (720) — portrait panel pixel width
- `lcd_y = 0x500` (1280) — portrait panel pixel height

The fb0 dimensions (1280x720) are transposed relative to the lcd dimensions
(720x1280). The disp engine driver detects this mismatch and applies rotation
code 3 (270 degrees). On the live device, this manifests as `rotate: 768`
(0x300, where bits [9:8] = 3) in the framebuffer sysfs.

Apps render into a landscape 1280x720 surface; the kernel rotates it
automatically. No per-app rotation is needed.

## Key nodes summary

| Node | Path | Key properties |
| --- | --- | --- |
| Root | `/` | `compatible = "allwinner,a133\0arm,sun50iw10p1"` |
| Panel | `lcd0@01c0c000` | `otm1289a` driver, 720x1280, MIPI-DSI 4-lane, 70 MHz dclk |
| Display | `disp@06000000` | fb0 1280x720, screen0 LCD output |
| RTC | `rtc@07000000` | `allwinner,sunxi-rtc`, battery-backed, wakeup-source |
| Thermal | `thermal-zones/cpu_thermal_zone` | 70C passive, 80C passive+cooling, 110C critical |
| GPU | `gpu@0x01800000` | `img,gpu` (PowerVR GE8300), 700 MHz max, DVFS enabled |
| WiFi | `wlan@0` | xradio, PG6 data/clk GPIOs |
| Memory | `memory@40000000` | 512 MiB at 0x40000000 |

## Per-board directory architecture

The `image/boards/<id>/` structure is architected from day one so adding the
Smart Pro S unit (Phase 3) is purely additive. Each board directory contains
its own `.dts`, `cmdline.txt`, and notes. The vendor SPL (`boot0.img`) carries
DRAM-init parameters specific to the PCB layout, so per-board directories are
the correct granularity.
