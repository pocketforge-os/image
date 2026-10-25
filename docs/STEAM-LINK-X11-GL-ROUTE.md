# Steam Link X11 GL route

## Offline finding

Build 44's release-image evidence is consistent with an Xwayland glamor/GLX
server using the Mesa Zink path over PowerVR KMSRO. The image's pinned
Xwayland package is built with glamor and GLX; on this stack the usable DRI
route is DRI3, backed by the `sun4i-drm` render path and Zink. The `dri2`
failure in the Steam Link journal is the client-side fallback while creating
its GL context, not the intended Xwayland server route.

The release image provides GLVND dispatch plus the package-owned Mesa client
stack: `libEGL_mesa.so.0`, `libGLX_mesa.so.0`, `libgbm.so.1`, Gallium's
`libgallium_dri.so`, `zink_dri.so`, and the PowerVR Vulkan ICD. The app
platform runtime also needs the X11 DRI3 client closure, specifically
`libxcb-dri3.so.0`, `libxcb-present.so.0`, and `libxshmfence.so.1`; these are
now explicit runtime seeds so the closure cannot omit them.

Steam Link uses its bundled Qt 5.14.1 runtime. Its manifest requests X11, and
the runtime's measured launch environment sets `QT_PLUGIN_PATH` to the
bundled Qt plugin directory. The live presentation evidence loaded
`libqxcb-egl-integration.so` from that directory, so the earlier diagnostic
that reported missing xcb EGL/GLX plugins was checking the wrong path. Keep
the X11 route and make its DRI3 client closure complete. Native
`QT_QPA_PLATFORM=wayland` remains a possible fallback, but it would bypass
the Xwayland acceptance target and is not justified while the bundled xcb
integration is present.

## Device acceptance

The next unsealed window must verify, as `gamer`, that `glxinfo` or `eglinfo`
creates a Zink/PowerVR context through Xwayland, then rerun the Steam Link GL
diagnostic. A passing result is required before the image change is promoted
to an image PR.
