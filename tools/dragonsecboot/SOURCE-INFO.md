# dragonsecboot -- Vendored Allwinner boot_package Packer

## Upstream source

- **Repository:** <https://github.com/bkleiner/hdzero-goggle-tools>
- **Commit:** `66703c7b12278857dad3483e9c9080758dca819d` (2023-02-16)
- **File in repo:** `dragonsecboot` (root of repository)
- **Vendored date:** 2026-06-12
- **Pinning method:** SHA-256 (below). NOT a live git submodule -- mitigates upstream-disappears risk.

### Source correction (2026-06-12)

The DDD review (2026-06-11) originally identified FriendlyARM's `h3_lichee` (commit
`75b584e2`, path `tools/pack/pctools/linux/openssl/`) as the canonical source. That
binary is an **older H3-era build that only supports `-toc0`/`-toc1`/`-key`** -- it does
NOT have the `-pack` mode needed for `boot_package.fex` assembly. The `-pack` mode was
added in later Allwinner SDK generations (H5+/A133/H700). The correct source is
`bkleiner/hdzero-goggle-tools`, which is the actual upstream of KNULLI's
`host-allwinner-utils` package.

## What this tool does

`dragonsecboot` is the Allwinner SDK tool that packs bootloader components (U-Boot,
BL31 monitor, SCP firmware, and the device tree blob) into a `boot_package.fex`
archive. This archive is written at a raw offset (16 MiB on SD) and is loaded by the
vendor SPL (boot0) at early boot.

PocketForge usage: `dragonsecboot -pack boot_package.cfg`

The tool also supports `-toc0`, `-toc1`, `-key`, `-pack`, `-rotpk`, `-resign_toc0`,
and `-resign_toc1` modes. PocketForge only uses `-pack`.

## Vendored file (SHA-256)

The vendored binary is a **precompiled, statically-linked x86-64 ELF executable**.
No external runtime dependencies (no libstdc++, no sibling OpenSSL tools needed).
There is no source code in the upstream repository for this binary.

```
36a42fc093ac082f2589a843407a1e460d1f4362ca321923521b755ac43aa094  dragonsecboot
```

Verify: `cd image/tools/dragonsecboot && sha256sum -c <<< "36a42fc093ac082f2589a843407a1e460d1f4362ca321923521b755ac43aa094  dragonsecboot"`

| File | Arch | Size | Linking | Purpose |
|------|------|-----:|---------|---------|
| `dragonsecboot` | x86-64 | 1,829,296 | statically linked | Packs boot_package.fex (`-pack`); also creates TOC0/TOC1 images and generates keypairs |

### Runtime dependencies

None. The binary is statically linked against glibc and libstdc++. It runs directly on
any x86-64 Linux host (including the PocketForge build container).

### Buildable source fallback

If a from-source build is ever needed, `HandsomeMod/allwinner-bsp-tools` contains the
GPL-2.0-licensed source in its `toc_tools/` directory (`dragonsecboot.c` +
`create_package.c` + support files). Build with `make -C toc_tools` (host gcc).

## KNULLI provenance chain (why we vendor from bkleiner, not KNULLI)

KNULLI's `uboot-a133.mk` references `host-allwinner-utils` as a Buildroot build
dependency:
```makefile
UBOOT_A133_DEPENDENCIES = host-allwinner-utils host-dtc
```

The `host-allwinner-utils` package definition resolves to:
```makefile
# knulli-cfw/knulli-linux/package/boot/allwinner-utils/allwinner-utils.mk
ALLWINNER_UTILS_VERSION = 66703c7b12278857dad3483e9c9080758dca819d
ALLWINNER_UTILS_SITE = $(call github,knulli-cfw,hdzero-goggle-tools,$(ALLWINNER_UTILS_VERSION))
```

KNULLI's fork (`knulli-cfw/hdzero-goggle-tools`) is a mirror of `bkleiner/hdzero-goggle-tools`
at the same commit. We vendor from the original `bkleiner` repo.

**The gap:** anyone cloning KNULLI to rebuild from source will hit a missing-dependency
error at the `dragonsecboot` step unless they also have the `allwinner-utils.mk` package
definition -- which lives in KNULLI's private Buildroot overlay, not in the public tree.
This is why we vendor directly at a pinned SHA rather than depending on KNULLI's build
system.

### Retracted source: FriendlyARM h3_lichee

The earlier plan referenced `friendlyarm/h3_lichee` commit `75b584e2`, path
`tools/pack/pctools/linux/openssl/`. That directory contains 6 precompiled binaries
(dragonsecboot + 4 OpenSSL 1.0.1g tools + create_toc0), but the `dragonsecboot` in
that tree is an **H3-era build** whose only modes are `-toc0`, `-toc1`, `-key`. Running
it with `-pack` prints usage showing only those three modes. The `-pack` mode needed for
`boot_package.fex` assembly does not exist in that binary. Retracted; do not use.

## Reproducibility note

`dragonsecboot -pack` embeds wall-clock timestamps in the output `boot_package.fex`
header. For bit-for-bit reproducible builds (G-reproducible gate, M1.E), wrap the
invocation with `faketime`:

```bash
faketime "$(date -d @$SOURCE_DATE_EPOCH -u +%Y-%m-%d\ %H:%M:%S)" \
    dragonsecboot -pack boot_package.cfg
```

Do NOT combine `faketime` with parallel `make -jN` (libfaketime interacts badly with
parallel builds). Keep faketime'd steps serial.

## Usage in PocketForge

```bash
# Ensure dragonsecboot is on PATH
export PATH="$(realpath tools/dragonsecboot):$PATH"

# Create the config file
cat > boot_package.cfg <<'EOF'
[package]
item=u-boot,                 u-boot.bin
item=monitor,                monitor.bin
item=scp,                    scp.bin
item=dtb,                    dtb.bin
EOF

# Pack (all 4 component files must be in the working directory)
dragonsecboot -pack boot_package.cfg
# Output: boot_package.fex
```

The output `boot_package.fex` is written to the SD image at offset 16 MiB (sector 32768)
via `genimage`. See `sd-boot-research.md` section 7.3 and `build-integration-reference.md`
section 8.4 for the full build flow.

## Smoke-test results (2026-06-12)

Pack + extract round-trip verified against the vendor boot chain blobs from
`blobs/tsp/boot-chain/`:

1. `dragonsecboot -pack boot_package.cfg` with vendor `u-boot.bin` + `monitor.bin` +
   `scp.bin` + `vendor-dtb.bin` (as `dtb.bin`) produced a 1,081,344-byte
   `boot_package.fex`.
2. KNULLI's `extract_boot_package.py` parsed the output and extracted all 4 components.
3. All 4 extracted components are **byte-identical** to the original input blobs.
4. The repacked `boot_package.fex` is byte-identical to the vendor original for all
   1,081,344 meaningful bytes (the vendor file has 32 KiB trailing zero-pad which
   the BROM ignores).

## Fallback recipe (if upstream disappears)

If the `bkleiner/hdzero-goggle-tools` repo disappears AND our vendored copy is lost,
the boot_package.fex can be reconstructed without `dragonsecboot`:

1. **Extract a known-good `boot_package.fex`** from the device or from a working SD
   image (the file is at raw offset 16 MiB on the SD/eMMC):
   ```bash
   dd if=/dev/mmcblk1 of=boot_package.fex bs=512 skip=32768 count=2176
   ```

2. **Use KNULLI's `extract_boot_package.py`** to split it into individual components:
   ```bash
   python3 extract_boot_package.py boot_package.fex
   # Produces: output_blocks/{u-boot.bin, monitor.bin, scp.bin, dtb.bin}
   ```
   Source: `knulli-cfw/knulli-linux/package/boot/uboot-a133/extract_boot_package.py`

3. **Replace only the DTB** (the only component PocketForge edits) with a freshly
   compiled one, then **reassemble** using a minimal Python packer (~200 lines) that
   writes the `sunxi-package` header + concatenates the 4 component files at
   1 KiB-aligned offsets matching the original layout.

   The `boot_package.fex` format (`sunxi-package` / TOC1-without-certs) is documented
   in `bkleiner/hdzero-goggle-tools/dump_boot_package/private_toc.h`:
   - Header: `sbrom_toc1_head_info_t` (magic `0x89119800`, name `"sunxi-package"`,
     item count, valid length, checksum)
   - Per-item: `sbrom_toc1_item_info_t` (name, offset, length, type)
   - Payloads at 1 KiB boundaries; total size rounded to 16 KiB

   Alternatively, the GPL-2.0-licensed source in `HandsomeMod/allwinner-bsp-tools`
   `toc_tools/` directory can be built from source (`make -C toc_tools`).

   The implementation is deferred (documented here as a mitigation plan per
   `pocketforge-plan.md` section 15 risk #20).
