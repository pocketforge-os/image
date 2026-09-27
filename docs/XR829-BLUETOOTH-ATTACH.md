# XR829 Bluetooth attach

The `a133-open-7x` image ships a dedicated `xr829-hciattach` helper, not stock
`btattach` or stock BlueZ `hciattach`. Those generic tools can select an H4 line
discipline, but they do not implement the XR829 boot-ROM protocol. The preserved
Xradio implementation additionally power-cycles the Bluetooth rfkill device,
synchronizes with the boot ROM, changes baud rate, downloads
`/lib/firmware/fw_xr829_bt.bin`, starts the controller, assigns its persistent
address, and resets it before H4 is selected. Source and licence provenance are
recorded in `third_party/xradio-hciattach/SOURCE.md`.

Image integration is keyed to the exact `PF_DEVICE_ID=a133-open-7x` profile.
That profile declares `gpu.model = "none"` and `display.pipeline = "none"`; the
Bluetooth decision is deliberately independent of those unrelated settings.
The `a133-open` 6.x profile (`gpu.model = "open"`) and all other profiles do not
install this helper. A future platform Bluetooth capability can replace this
temporary device-profile boundary without changing the packaged implementation.

The board DTS aliases `serial1` to `uart1`; that controller uses PG8/PG9 with
RTS/CTS and enumerates as `/dev/ttyS1`. The enabled
`pocketforge-xr829-hciattach.service` is therefore bound and ordered after
`dev-ttyS1.device`, and ordered after udev settling and systemd's rfkill state
restore. The helper also discovers the Bluetooth rfkill entry by its type before
touching it. It has a bounded 30-second initialization and the unit has
`Restart=no`, so a missing/unresponsive controller produces a concrete journal
error without a retry loop. On success the foreground helper keeps the tty and
H4 line discipline attached.

The shared rootfs package manifest includes Debian bookworm's maintained
`bluez` package, which supplies `bluetoothctl` and `btmgmt` for controller and
pairing management (and its package-owned `bluetoothd` unit). The image does
not add a custom pairing agent, audio/profile daemon, or Bluetooth policy.
`hciconfig` is present in Debian's `bluez` package only as a legacy
compatibility utility: it is not an image contract and no PocketForge unit or
documentation directs users to it. The supported management interfaces are
`btmgmt` and `bluetoothctl`; the XR829 boot-ROM attach remains the dedicated
`xr829-hciattach` helper above, not stock BlueZ attach tooling.

The rootfs verifier fails closed unless all four XR829 payloads
(`fw_xr829.bin`, `boot_xr829.bin`, `sdd_xr829.bin`, and `fw_xr829_bt.bin`) and
the shipped attach-source licence/provenance are present. The firmware group
remains subject to the preserved vendor-manifest custody policy documented by
the firmware verifier. The hermetic build prints the exact helper size so the
final image receipt can replace the local estimate with the pinned-toolchain
measurement.
