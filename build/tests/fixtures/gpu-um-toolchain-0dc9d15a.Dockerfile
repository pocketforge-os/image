# Vendored from gpu-um-tsp docker/Dockerfile.ge8300-mesa-cross at 0dc9d15a.
# Update this fixture deliberately when the platform.lock gpu-um-tsp pin moves.
FROM ubuntu:24.04@sha256:d78ab76437b1afc5f01e223d6bf0172763f404bb166441328845adbef44518cb AS toolchain

COPY scripts/install-mesa-buildenv.sh /usr/local/src/install-mesa-buildenv.sh
# No apt snapshot: snapshot.ubuntu.com answers 401 for /ubuntu-ports/ (Ubuntu
# Pro only, 2026-09-21), so a snapshot can pin only the amd64 half and the
# reconciled amd64 libc6 (8.6) then mismatches the live arm64 libc6 (8.9):
# "held broken packages" on every Multi-Arch: same arm64 package. Both halves
# are installed live, as the 2026-09-17 toolchain that reproduced r461 was
# (/toolchain-packages.txt is the record of what each build actually used).
ENV MESA_UBUNTU_SNAPSHOT=none
# Only the EXIT trap that deletes the downloaded LLVM key is dropped. The old
# blanket '/rm -f/d' also hollowed out the reconcile block whose sole body is
# `rm -f /etc/apt/preferences.d/50mesa-snapshot`, leaving `if ...; then fi`:
# a bash syntax error at parse time (masked while the toolchain layer was cached).
RUN sed -i '/^trap .rm -f -- /d' /usr/local/src/install-mesa-buildenv.sh \
    && /usr/local/src/install-mesa-buildenv.sh \
    && sed -i '/^Types:/a Architectures: amd64' /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i 's/^deb \[/deb [arch=amd64 /' /etc/apt/sources.list.d/llvm-20.list \
    # ports.ubuntu.com has no apt snapshot service ("E: Snapshots not supported for
    # http://ports.ubuntu.com/ubuntu-ports/ noble", cold rebuild 2026-09-21); the
    # arm64 stanza says 'Snapshot: no' explicitly so it stays usable even when a
    # caller re-enables APT::Snapshot for the amd64 half (with the option set
    # globally, apt fetches a stanza that omits the field but does not use its
    # lists; verified in a plain container, 2026-09-21).
    && printf '%s\n' \
       'Types: deb' \
       'URIs: http://ports.ubuntu.com/ubuntu-ports' \
       'Suites: noble noble-updates noble-backports noble-security' \
       'Components: main universe restricted multiverse' \
       'Architectures: arm64' \
       'Snapshot: no' \
       'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
       >/etc/apt/sources.list.d/ubuntu-arm64.sources \
    && dpkg --add-architecture arm64 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       binutils-aarch64-linux-gnu \
       bison \
       flex \
       g++-aarch64-linux-gnu \
       gcc-aarch64-linux-gnu \
       libc6-dev:arm64 \
       libdrm-dev:arm64 \
    && dpkg-query -W > /toolchain-packages.txt

COPY docker/pkg-config/ /usr/local/bin/
COPY docker/meson/ /usr/local/share/mesa-cross/
RUN chmod 0755 /usr/local/bin/aarch64-linux-gnu-pkg-config \
                  /usr/local/bin/x86_64-linux-gnu-pkg-config

ENV CCACHE_DIR=/root/.cache/ccache \
    CCACHE_MAXSIZE=20G \
    CCACHE_COMPILERCHECK=content \
    LLVM_CONFIG=llvm-config-20
