# IME bus security test container

The container uses the image build's Debian snapshot and carries only the tools
needed by the real-binary private-bus harness. Docker's normal seccomp policy
blocks the namespace operations bubblewrap needs. `bwrap-seccomp.json` is the
Flatpak Docker example profile, vendored byte-for-byte from
`/usr/share/doc/flatpak/examples/flatpak-docker-seccomp.json` in Ubuntu package
`flatpak 1.14.6-1ubuntu0.1+esm1` (LGPL-2+ and LGPL-2.1+). Its SHA-256 is
`a775db1206ab90d93aee2313040c1d23d5b2d12a12691021fe060fbe33323ed7`.

The profile remains default-deny while admitting the namespace syscalls. The
host's AppArmor policy separately blocks bubblewrap's mount setup, so the test
disables AppArmor only for this non-root, networkless container. The checkout is
mounted read-only, no capabilities are added, and the container is removed on
exit.
