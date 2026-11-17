# kexec-tools source

`kexec-tools-2.0.32.tar.xz` and `kexec-tools-2.0.32.tar.sign` are the upstream
release files, byte for byte, from
<https://mirrors.edge.kernel.org/pub/linux/utils/kernel/kexec/>.

| File | SHA-256 |
|---|---|
| `kexec-tools-2.0.32.tar.xz` | `8f81422a5fd2362cf6cb001b511e535565ed0f32c2f4451fb5eb68fed6710a5d` |
| `kexec-tools-2.0.32.tar.sign` | `d978feacbe2a4507e0461f951d18124bc34af5c11687ec1b5b164c378470056f` |

The tarball digest matches kernel.org's `sha256sums.asc` entry. The detached
signature covers the uncompressed `.tar`. It verifies as a good signature from
Simon Horman, the kexec-tools maintainer: key
`E27CD9A1F5ACC2FF4BFE7285D7CF64696A374FBE`, from the kernel.org `pgpkeys.git`
keyring. Signed 2025-10-16. To re-check:

```sh
xz -dc kexec-tools-2.0.32.tar.xz > /tmp/kexec-tools-2.0.32.tar
gpg --verify kexec-tools-2.0.32.tar.sign /tmp/kexec-tools-2.0.32.tar
```

kexec-tools is GPL-2.0 (the tarball's `COPYING`). We redistribute the
complete corresponding source here, next to the binary built from it.

## Build

`boards/tsp/initrd/build-kexec-static.sh` builds it, and `build-initrd.sh` calls
that script for `--variant dev` only. The build runs inside the pinned build
container (`container.pin`), with no network, using:

```sh
./configure --host=aarch64-none-linux-gnu --build=x86_64-linux-gnu --prefix=/ \
    --without-zlib --without-lzma --without-xen --without-booke \
    CFLAGS="-O2 -ffile-prefix-map=<srcdir>/=" LDFLAGS=-static
make build/sbin/kexec
aarch64-none-linux-gnu-strip
```

The result is a static AArch64 binary of 742248 bytes, SHA-256
`09b191b07a4d24e7ccf3546199b68368cf02931706db67b3305662c00fd098c2`. It is
linked against the container's glibc 2.33 and has no `PT_INTERP` or dynamic
section. The output was the same when built as root and as a non-root user,
from two different source paths, at `-j3` and `-j8`. The builder refuses a
tarball or an output that does not match its pin.

The pin covers the shipped bytes only. No patches are applied. Without
`--without-zlib` and `--without-lzma`, the build would pick up whatever the
container offers, so those flags are fixed. The initrd hands kexec a
raw arm64 `Image` taken from the target `boot.img`, so neither decompressor is
needed.
