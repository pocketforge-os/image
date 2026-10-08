# A133 open-GPU GLVND EGL/GLX device proof

This check belongs to the coordinator's device run. It must use an image built
from the exact PR head; it is not a host-container substitute for the GE8300.

The image keeps its existing X11 GLX surface, but replaces Debian Mesa 22.3
with the same pinned Mesa/Zink implementation that owns EGL, GBM, and Vulkan.
Do not set `SDL_VIDEO_X11_FORCE_EGL`, `__GLX_VENDOR_LIBRARY_NAME`,
`__EGL_VENDOR_LIBRARY_FILENAMES`, or `LD_LIBRARY_PATH`: this proof exercises
the production GLVND routes.

Pinned Debian Xwayland 22.1.9 builds both glamor and GLX: its unmodified Meson
defaults are `glamor=true` and `glx=true` (`meson_options.txt:1-2,14`), and
Debian's `debian/rules:12-15` does not override either option. Its server-side
GLX implementation explicitly derives GLX capabilities from the glamor EGL
renderer (`hw/xwayland/xwayland-glx.c:27-39`). The GBM backend creates an
`EGL_PLATFORM_GBM_MESA` display and initializes EGL
(`hw/xwayland/xwayland-glamor-gbm.c:1028-1048`), while glamor initializes with
`GLAMOR_USE_EGL_SCREEN` (`hw/xwayland/xwayland-glamor.c:453-477`). These source
lines are from Debian snapshot `20260601T000000Z`, source package
`xwayland 2:22.1.9-1`.

## Preflight evidence

Record these outputs without changing the rootfs:

```sh
dpkg-query -W -f='${Package} ${Status} ${Version}\n' \
  pocketforge-open-gpu-stack libegl1 libgl1 libglx0 libglvnd0 xwayland
dpkg-query -S \
  /usr/local/lib/libEGL_mesa.so.0 \
  /usr/local/lib/libGLX_mesa.so.0 \
  /usr/local/lib/libgbm.so.1 \
  /usr/local/lib/libgallium_dri.so \
  /usr/share/glvnd/egl_vendor.d/50_mesa.json
cat /usr/share/glvnd/egl_vendor.d/50_mesa.json
find /usr/local/share/vulkan/icd.d /usr/share/vulkan/icd.d \
  -name 'powervr_mesa_icd.aarch64.json' -print
find /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu \
  \( -path '*/dri/*_dri.so*' -o -name 'libEGL_mesa.so*' -o \
     -name 'libGLX_mesa.so*' -o -name 'libgbm.so*' \) -print
systemctl show-environment | grep -Fx MESA_LOADER_DRIVER_OVERRIDE=zink
```

The package, neutral GLVND dispatchers, and Xwayland must be installed; every
queried owned file must resolve to `pocketforge-open-gpu-stack`; the EGL vendor
JSON must name the absolute `/usr/local/lib/libEGL_mesa.so.0`; exactly one
`libGLX_mesa.so.0` must exist, at `/usr/local/lib`; and the final `find` must
print nothing. The Vulkan-manifest `find` must print exactly the canonical
`/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json`, never a second
`/usr/local/share` route. This build-time assertion proves one loader route;
the device run must separately prove that route enumerates one physical device:

```sh
vulkaninfo --summary | tee /run/pocketforge-vulkan-summary.txt
test "$(grep -c '^[[:space:]]*deviceName[[:space:]]*=[[:space:]]*PowerVR Rogue GE8300$' \
  /run/pocketforge-vulkan-summary.txt)" -eq 1
```

Quote the full summary and the successful count check. Two identical `deviceName`
lines fail even when they name the same hardware. The system manager must supply
the image-owned Zink selection; do not add an ad hoc
`MESA_LOADER_DRIVER_OVERRIDE` to the test command.

## Runtime routing evidence

Launch `glxinfo -B`, `glxgears`, or an X11 GL client with
`SDL_VIDEODRIVER=x11` and no EGL-forcing override. Wait until it has rendered,
then preserve its PID and Xwayland's PID. Quote the renderer output and,
rather than summarizing, the GPU library mappings:

```sh
grep -E '/(lib(EGL|GLES|GLX|gbm|gallium|vulkan)|dri/).*\.so' \
  /proc/CLIENT_PID/maps
grep -E '/(lib(EGL|GLES|GLX|gbm|gallium|vulkan)|dri/).*\.so' \
  /proc/XWAYLAND_PID/maps
```

The client must map Debian's neutral `libGL.so.1`/`libGLX.so.0` dispatchers from
`/usr/lib/aarch64-linux-gnu` and our `/usr/local/lib/libGLX_mesa.so.0`,
Gallium/Zink implementation, and PowerVR ICD. Xwayland must use the owned GBM
and GLVND-selected Mesa EGL vendor. Neither process may map
`/usr/lib/aarch64-linux-gnu/libEGL_mesa.so.0`,
`/usr/lib/aarch64-linux-gnu/libGLX_mesa.so.0`, a Debian `dri/*_dri.so`, or a
Debian `libgbm`.

Finally quote the Xwayland startup lines that identify glamor initialization
and DRI3 enablement. `glxinfo -B` (or the chosen client's equivalent) must name
Mesa 26.1.7 Zink on PowerVR Rogue GE8300. Treat any glamor initialization
failure, llvmpipe/swrast selection, or software-renderer continuation as a
failure; there is no silent software fallback acceptance arm. A diagnostic
Xwayland no-glamor arm may be run separately, but it is not a passing product
configuration.
