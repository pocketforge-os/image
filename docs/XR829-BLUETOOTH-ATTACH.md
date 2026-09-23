# XR829 Bluetooth attach

The A133 mainline image ships a dedicated `xr829-hciattach` helper, not stock
`btattach` or stock BlueZ `hciattach`. Those generic tools can select an H4 line
discipline, but they do not implement the XR829 boot-ROM protocol. The preserved
Xradio implementation additionally power-cycles the Bluetooth rfkill device,
synchronizes with the boot ROM, changes baud rate, downloads
`/lib/firmware/fw_xr829_bt.bin`, starts the controller, assigns its persistent
address, and resets it before H4 is selected. Source and licence provenance are
recorded in `third_party/xradio-hciattach/SOURCE.md`.

The board DTS aliases `serial1` to `uart1`; that controller uses PG8/PG9 with
RTS/CTS and enumerates as `/dev/ttyS1`. The enabled
`pocketforge-xr829-hciattach.service` is therefore bound and ordered after
`dev-ttyS1.device`, and ordered after udev settling and systemd's rfkill state
restore. The helper also discovers the Bluetooth rfkill entry by its type before
touching it. It has a bounded 30-second initialization and the unit has
`Restart=no`, so a missing/unresponsive controller produces a concrete journal
error without a retry loop. On success the foreground helper keeps the tty and
H4 line discipline attached.

No `bluez` Debian package, `bluetoothd`, `btmgmt`, pairing agent, or audio
profile daemon is included. This change only creates `hci0`; pairing, A2DP,
other Bluetooth profiles, and their command-line management tools remain out of
scope. A bench experimenter can validate controller identity with a transient
diagnostic tool or read `/sys/class/bluetooth/hci0/address`; adding a product
host/profile stack requires a separate packaging decision.

The measured payload delta is approximately 86 KiB uncompressed: a 67,616-byte
stripped AArch64 helper (local cross-build), the 18,006-byte GPL text, and less
than 2 KiB of unit/provenance text. There are no added Debian packages or daemon
dependencies. The hermetic build prints the exact helper size so the final image
receipt can replace the local estimate with the pinned-toolchain measurement.
