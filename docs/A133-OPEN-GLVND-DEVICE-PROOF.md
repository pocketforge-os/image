# A133 open-GPU GLVND EGL/GLX device proof

This check belongs to the coordinator's device run. It must use an image built
from the exact PR head; it is not a host-container substitute for the GE8300.

The image keeps its existing X11 GLX surface, but replaces Debian Mesa 22.3
with the same pinned Mesa/Zink implementation that owns EGL, GBM, and Vulkan.
Do not set `SDL_VIDEO_X11_FORCE_EGL`, `__GLX_VENDOR_LIBRARY_NAME`,
`__EGL_VENDOR_LIBRARY_FILENAMES`, or `LD_LIBRARY_PATH`: this proof exercises
the production GLVND routes.

## Zink selection mechanism

The provider and GLVND conversion does not change either DRM kernel-driver
name. Before this change, the pinned gpu-um-tsp source already selected Zink
for the PowerVR render node in its Gallium pipe loader: it first obtains the
driver name from `loader_get_driver_for_fd` and then rewrites `powervr` to
`zink` because PowerVR has no Gallium driver
(`src/gallium/auxiliary/pipe-loader/pipe_loader_drm.c:119-157`, gpu-um-tsp
`16550cc1`). The same build enables KMSRO when KMS DRM and Zink are present
(`meson.build:335-336`), installs the dril compatibility entry for
`sun4i-drm` (`src/gallium/targets/dril/meson.build:65-103`), and that entry
re-enters EGL through a GBM device
(`src/gallium/targets/dril/dril_target.c:361-389,684`). That is why the prior
image's clean-environment KMS/GBM path could reach Zink without a global
loader override.

The image makes only the `powervr` render-node kernel name explicit at the
common Mesa loader boundary. `sun4i-drm` must remain unmapped so the display
card follows Mesa's KMSRO path to the PowerVR render node. The owned
`libgallium_dri.so` must export both `kmsro_drm_screen_create` and
`zink_drm_create_screen_renderonly`. `loader_get_driver_for_fd` checks the
driconf result before its PCI/kernel-name fallback
(`src/loader/loader.c:764-790`); the driconf helper passes the actual kernel
driver to `driParseConfigFiles` and returns its non-empty `dri_driver` option
(`src/loader/loader.c:329-359`). The loader is compiled with `USE_DRICONF`
(`src/loader/meson.build:37-39`), and the target build enables XML config so
`DATADIR/drirc.d` is parsed (`src/util/xmlconfig.c:1258-1268`). With Mesa's
`/usr/local` prefix, the provider-owned policy is
`/usr/local/share/drirc.d/10-pocketforge-zink.conf`. No process environment is
part of this selection.

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
  /usr/local/share/drirc.d/10-pocketforge-zink.conf \
  /usr/share/glvnd/egl_vendor.d/50_mesa.json
cat /usr/share/glvnd/egl_vendor.d/50_mesa.json
cat /usr/local/share/drirc.d/10-pocketforge-zink.conf
find /usr/local/share/vulkan/icd.d /usr/share/vulkan/icd.d \
  -name 'powervr_mesa_icd.aarch64.json' -print
find /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu \
  \( -path '*/dri/*_dri.so*' -o -name 'libEGL_mesa.so*' -o \
     -name 'libGLX_mesa.so*' -o -name 'libgbm.so*' \) -print
test -z "$(find / -xdev -type f -exec \
  grep -IlE '(^|[^[:alnum:]_])MESA_LOADER_DRIVER_OVERRIDE[[:space:]]*=' {} + \
  2>/dev/null)"
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
lines fail even when they name the same hardware. The drirc file must contain
exactly the `powervr` loader mapping to `zink`, with no `sun4i-drm` mapping; the
clean-rootfs scan must find no environment assignment.

Before starting Xwayland, stage the device kit's arm64 node-selecting GBM/EGL
probe in tmpfs and record its SHA-256. The probe must open the named node,
create a GBM device, obtain and initialize an `EGL_PLATFORM_GBM_KHR` display,
create an OpenGL ES context, and print `GL_RENDERER`. Run it with a genuinely
empty inherited environment against both DRM names:

```sh
for node in /dev/dri/card0 /dev/dri/renderD128; do
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/run/pf-egl-empty \
    XDG_RUNTIME_DIR=/run/user/1000 \
    /run/pf-egl-node-probe "$node"
done
```

Both invocations must name Mesa Zink on PowerVR Rogue GE8300. `env -i` is the
positive proof that the provider-owned drirc policy, rather than a service,
login shell, launcher, or inherited override, selects Zink. A failure to open
or initialize either node is not a negative control and does not pass.

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
