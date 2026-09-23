# XR829 HCI attach source

`hciattach_xradio.c` is preserved from the `bluez-5.54-xradio` branch of
<https://github.com/Sakura-Pi/Xradio-XR829-Bluetooth> at commit
`d7a793ae529de0c27ebd91867636485877c22ef8` (2024-11-17). The source identifies
Xradio Technology Co., Ltd. as its 2018 copyright holder and is licensed under
GPL-2.0-or-later; the corresponding GPLv2 text is preserved as `COPYING`.

The vendor implementation is not ordinary H4 attachment: it toggles the
Bluetooth rfkill power state, synchronizes with the XR829 boot ROM, changes the
UART rate, downloads `/lib/firmware/fw_xr829_bt.bin`, starts the controller,
sets a persistent controller address, and resets it before H4 is selected.
Upstream `btattach` and Debian's unpatched BlueZ `hciattach` do not perform this
sequence.

PocketForge supplies a small GPL-2.0-or-later wrapper (`main.c` and
`hciattach.h`) instead of shipping the rest of the BlueZ host stack. The wrapper
opens the board's DTS-selected UART, runs the preserved vendor initialization,
selects the kernel H4 line discipline, and remains alive to retain the tty.

PocketForge changes to the preserved source are intentionally limited to its
includes and returning initialization failures to the wrapper. Compare against
the pinned source with:

```sh
git show d7a793ae529de0c27ebd91867636485877c22ef8:tools/hciattach_xradio.c
```
