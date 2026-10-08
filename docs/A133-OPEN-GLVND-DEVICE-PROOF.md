# A133 open-GPU GLVND phase-1 device proof

This check belongs to the coordinator's device run. It must use an image built
from the exact PR head; it is not a host-container substitute for the GE8300.

Phase 1 intentionally exposes EGL + GLES + GBM + Vulkan, not desktop GLX. Run
the X11 SDL client with `SDL_VIDEO_X11_FORCE_EGL=1`; an X11 client selecting
GLX is outside this phase's supported route.

## Preflight evidence

Record these outputs without changing the rootfs:

```sh
dpkg-query -W -f='${Package} ${Status} ${Version}\n' \
  pocketforge-open-gpu-stack libegl1 xwayland
dpkg-query -S \
  /usr/local/lib/libEGL_mesa.so.0 \
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

The package and neutral `libegl1`/Xwayland must be installed; every queried
owned file must resolve to `pocketforge-open-gpu-stack`; the vendor JSON must
name the absolute `/usr/local/lib/libEGL_mesa.so.0`; and the final `find` must
print nothing. The Vulkan-manifest `find` must print exactly the canonical
`/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json`, never a second
`/usr/local/share` route. The system manager must supply the image-owned Zink
selection; do not add an ad hoc `MESA_LOADER_DRIVER_OVERRIDE` to the test
command.

## Runtime routing evidence

Launch the phase-1 X11 GLES client with
`SDL_VIDEO_X11_FORCE_EGL=1 SDL_VIDEODRIVER=x11`, wait until it has rendered,
and preserve its PID and Xwayland's PID. Quote, rather than summarize, the GPU
library mappings:

```sh
grep -E '/(lib(EGL|GLES|GLX|gbm|gallium|vulkan)|dri/).*\.so' \
  /proc/CLIENT_PID/maps
grep -E '/(lib(EGL|GLES|GLX|gbm|gallium|vulkan)|dri/).*\.so' \
  /proc/XWAYLAND_PID/maps
```

The client may map Debian's neutral GLVND dispatch libraries from
`/usr/lib/aarch64-linux-gnu`, but its Mesa vendor, GBM/Gallium, and PowerVR ICD
must map only from `/usr/local/lib`. Xwayland must likewise use the owned GBM
and GLVND-selected Mesa EGL vendor; neither process may map Debian
`libEGL_mesa`, `libGLX_mesa`, `zink_dri`, `swrast_dri`, or `libgbm`.

Finally quote the Xwayland startup lines that identify glamor initialization
and DRI3 enablement. Treat any glamor initialization failure, llvmpipe/swrast
selection, or software-renderer continuation as a failure; there is no silent
software fallback acceptance arm. A diagnostic Xwayland no-glamor arm may be
run separately, but it is not a passing product configuration.
