# pvr-buildopts.mk -- PowerVR DDK 1.19 build-options for TrimUI Smart Pro
#
# Source: M2.A.4 vendor pvrsrvkm.ko analysis (logs/pvrsrvkm-buildopts-vendor.txt)
# Bead:   tsp-cv7.3.4
#
# The vendor pvrsrvkm.ko was built from an Allwinner-internal DDK 1.19 source
# tree whose rgx_options.h has DIFFERENT bit assignments than the
# DC-DeepComputing DDK 1.19 source we build from. Individual -DSUPPORT_*
# flags would set the WRONG semantic bits in the build-options word.
#
# Strategy: the gpu-km-tsp repo patches rgx_options.h to override the
# computed RGX_BUILD_OPTIONS_KM / RGX_BUILD_OPTIONS_MASK_KM / RGX_BUILD_OPTIONS
# constants to the exact values the vendor UM blobs expect. This makefile
# supplies the functional CFLAGS that control #ifdef code paths (orthogonal
# to the bitmask) and the PVRVERSION_BUILD override.
#
# Consumed by:
#   - gpu-km-tsp/Makefile  (included via ccflags-y)
#   - gpu-km-tsp/build-sunxi-a133.sh
#   - image repo CI workflows
#
# --------------------------------------------------------------------------
# Vendor identity (from strings/objdump of blobs/tsp/kernel-4.9.191/modules/pvrsrvkm.ko)
# --------------------------------------------------------------------------
#   DDK version:          1.19
#   DDK build revision:   1      (NOT 6345021 from DC-DeepComputing source)
#   Build-options word:   0x0060d13d
#   Build-options mask:   0x0060fffb  (bits 0-15 + 21-22, excluding bit 2 UNUSED1)
#   BVNC:                 22.102.54.38 (PowerVR GE8300)
#   PVR_BUILD_DIR:        sunxi_linux_nullws_release
#   Build type:           release (0x10 = PVRSRV_BUILD_RELEASE)

# --------------------------------------------------------------------------
# Build-options constants (patched into rgx_options.h, documented here)
# --------------------------------------------------------------------------
# These are applied via a patch to gpu-km-tsp/include/rogue/rgx_options.h,
# NOT via CFLAGS. Listed here for reference and CI validation.
PVR_VENDOR_BUILD_OPTIONS_KM      := 0x0060d13d
PVR_VENDOR_BUILD_OPTIONS_MASK_KM := 0x0060fffb

# --------------------------------------------------------------------------
# DDK version override
# --------------------------------------------------------------------------
# The vendor module reports PVRVERSION_BUILD = 1. The DC-DeepComputing source
# defaults to 6345021. The KM/UM version check at srvcore.c:580-588 compares
# the full packed DDK version (maj<<16 | min) AND the build revision. Both
# must match the vendor UM blobs.
PVR_BUILD_OVERRIDE := 1

# --------------------------------------------------------------------------
# Functional CFLAGS for code-path selection
# --------------------------------------------------------------------------
# These control #ifdef branches in the DDK source and must be set for correct
# runtime behavior. They are INDEPENDENT of the build-options bitmask override.
#
# SUPPORT_RGX=1               : essential -- this is a GPU driver build
# RELEASE                     : release build (not debug); suppresses debug paths
# SUPPORT_DISPLAY_CLASS=1     : required for dc_sunxi.ko DC API symbol exports
# SUPPORT_WORKLOAD_ESTIMATION=1 : vendor has this enabled (bit 8 in their word)
#
# DO NOT SET:
#   NO_HARDWARE         (disables HW register access -- bit 0 in DC layout)
#   DEBUG               (debug build -- conflicts with RELEASE)
#   PDUMP               (parameter dump -- not in vendor build)
#   SUPPORT_PDVFS       (proactive DVFS -- bit 9 = 0 in vendor)
PVR_KM_CFLAGS := \
	-DSUPPORT_RGX=1 \
	-DRELEASE \
	-DSUPPORT_DISPLAY_CLASS=1 \
	-DSUPPORT_WORKLOAD_ESTIMATION=1
