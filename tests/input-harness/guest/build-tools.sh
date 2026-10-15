#!/bin/bash
set -euo pipefail
export SOURCE_DATE_EPOCH=1780272000
export LC_ALL=C.UTF-8

meson setup /src/libei/build /src/libei --buildtype=release \
    --prefix=/usr/local -Ddocumentation=[] -Dtests=disabled -Dliboeffis=disabled
meson compile -C /src/libei/build
meson install -C /src/libei/build

cmake -S /src/sdl3 -B /src/sdl-build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DSDL_STATIC=OFF -DSDL_SHARED=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_VIDEO_DRIVER_SUNXIFB=OFF
cmake --build /src/sdl-build --parallel 2
cmake --install /src/sdl-build

wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
    /src/xdg-shell-client-protocol.h
wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
    /src/xdg-shell-protocol.c
wayland-scanner client-header /src/gamescope-control.xml /src/gamescope-control-client-protocol.h
wayland-scanner private-code /src/gamescope-control.xml /src/gamescope-control-protocol.c

gcc -O2 -Wall -Wextra -fPIC -shared -o /out/lib/libpf-transcript.so /src/tools/transcript.c -lpthread
gcc -O2 -Wall -Wextra -fPIC -shared -o /out/lib/libpf-transcript-preload.so \
    /src/tools/transcript-preload.c /src/tools/transcript.c \
    $(pkg-config --cflags --libs wayland-client) -ldl -lpthread
tx='-L/out/lib -lpf-transcript -Wl,-rpath,/opt/pf-input-harness/lib'
gcc -O2 -Wall -Wextra -I/src/tools -o /out/bin/fake-input /src/tools/fake-input.c
gcc -O2 -Wall -Wextra -o /out/bin/private-input /src/tools/private-input.c
gcc -O2 -Wall -Wextra -o /out/bin/eis-bridge /src/tools/eis-bridge.c \
    $(pkg-config --cflags --libs libei-1.0)
gcc -O2 -Wall -Wextra -I/src -o /out/bin/pf-shot /src/tools/pf-shot.c \
    /src/gamescope-control-protocol.c $(pkg-config --cflags --libs wayland-client)
gcc -O2 -I/out/lib -o /out/bin/gtk4-text /src/clients/gtk4-text.c $(pkg-config --cflags --libs gtk4) $tx
g++ -O2 -fPIC -I/out/lib -o /out/bin/qt6-text /src/clients/qt6-text.cpp $(pkg-config --cflags --libs Qt6Widgets) $tx
gcc -O2 -I/out/lib -o /out/bin/sdl3-text /src/clients/sdl3-text.c \
    $(pkg-config --cflags sdl3) -L/usr/local/lib -lSDL3-pocketforge $tx
gcc -O2 -I/out/lib -o /out/bin/sdl2-game /src/clients/sdl2-game.c $(pkg-config --cflags --libs sdl2) $tx
gcc -O2 -I/out/lib -o /out/bin/x11-gtk /src/clients/x11-gtk.c $(pkg-config --cflags --libs gtk+-3.0) $tx
gcc -O2 -I/out/lib -o /out/bin/xim-only /src/clients/xim-only.c -lX11 $tx
gcc -O2 -I/out/lib -I/src -o /out/bin/no-im /src/clients/no-im.c /src/xdg-shell-protocol.c -lwayland-client $tx
gcc -O2 -I/out/lib -o /out/bin/broken-client /src/clients/broken-client.c $tx
find /usr/local/lib \( -type f -o -type l \) -name 'libSDL3*.so*' \
    -exec cp -a {} /out/lib/ \;
find /usr/local/lib \( -type f -o -type l \) \
    \( -name 'libei.so*' -o -name 'libeis.so*' \) \
    -exec cp -a {} /out/lib/ \;
