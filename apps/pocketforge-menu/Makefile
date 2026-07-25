# pocketforge-menu — MVP static launcher (bd: tsp-ga7s.1)
#
# The AUTHORITATIVE aarch64 build for the on-device image happens inline in
# scripts/build-rootfs.sh (mirroring pocketforge-boot-animator and
# pocketforge-placeholder — deterministic cross-compile via ${CROSS_CC},
# stripped, exported via PF_MENU_BIN into the mmdebstrap customize hook).
#
# THIS Makefile is a HOST build for local verification only — `make -C
# image/apps/pocketforge-menu` compiles main.c with the host toolchain so a
# developer (or a PR gate) can catch a compile or warning regression without
# spinning a full image build. It is not consumed by the image pipeline.

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function
BIN     := pocketforge-menu
SRC     := src/main.c

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC)

.PHONY: clean
clean:
	rm -f $(BIN)
