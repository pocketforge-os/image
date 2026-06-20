# =============================================================================
# PocketForge image — top-level Makefile
# =============================================================================
# Phase 1 build pipeline entry points. Blob fetching runs on the host (outside
# the container); image assembly runs inside the container via bind mounts.
#
# bd: tsp-iby.3 (fetch-blobs, warm-cache), tsp-iuz.1.7 (build-image)
# =============================================================================

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# ---- paths ------------------------------------------------------------------
CURDIR_ABS := $(shell pwd)
WORK       := $(CURDIR_ABS)/work
BLOBS_DIR  := $(WORK)/blobs
CACHE_DIR  := $(WORK)/cache
OUT_DIR    := $(WORK)/out

# Container image (local tag; pin by digest in container.pin for CI)
CONTAINER  := pocketforge/build:10.3-2021.07-bookworm

# Path to a local blobs repo checkout (used when IPFS is not available)
LOCAL_BLOBS ?= $(HOME)/blobs

# Image build variant (dev or release)
VARIANT ?= dev

# M1B mode: set M1B_MODE=1 for the M1.B busybox-shell image (no rootfs).
# Default is off (full Debian rootfs via mmdebstrap).
M1B_MODE ?= 0

# Path to a local libsdl3-sunxifb build (contains libSDL3-pocketforge.so.0)
LOCAL_LIBSDL3 ?= $(HOME)/libsdl3-sunxifb/_build

# Vendor manifest repo (private; requires GitHub auth for clone)
MANIFEST_REPO  := https://github.com/pocketforge-os/vendor-manifest.git
MANIFEST_DIR   := $(WORK)/vendor-manifest
MANIFEST_FILE  := $(MANIFEST_DIR)/manifest.toml

# IPFS API endpoint (kubo on localhost by default)
IPFS_API ?= /ip4/127.0.0.1/tcp/5001

# ---- fetch-blobs ------------------------------------------------------------
# Fetch all vendor blobs via IPFS, verified against the signed manifest.
# Output: work/blobs/ with the same directory structure as the old git-clone.
# Runs on the HOST, outside the container. No kubo inside the container.
#
# Prerequisite: kubo daemon running (sudo systemctl start ipfs).
# First run on a new machine: run 'make warm-cache' first to pin all CIDs.
.PHONY: fetch-blobs
fetch-blobs: $(MANIFEST_FILE)
	@echo "=== make fetch-blobs ==="
	@mkdir -p "$(BLOBS_DIR)"
	IPFS_API="$(IPFS_API)" $(CURDIR_ABS)/scripts/ipfs-fetch.sh "$(MANIFEST_FILE)" "$(BLOBS_DIR)"

# Clone or update the vendor-manifest repo (shallow, private).
$(MANIFEST_FILE):
	@if [ -d "$(MANIFEST_DIR)/.git" ]; then \
		echo "Updating vendor-manifest..."; \
		git -C "$(MANIFEST_DIR)" pull --ff-only --depth=1 2>/dev/null || \
		git -C "$(MANIFEST_DIR)" fetch --depth=1 origin main && \
		git -C "$(MANIFEST_DIR)" reset --hard origin/main; \
	else \
		echo "Cloning vendor-manifest (private, requires GitHub auth)..."; \
		mkdir -p "$(WORK)"; \
		git clone --depth=1 "$(MANIFEST_REPO)" "$(MANIFEST_DIR)"; \
	fi

# Force re-clone the manifest (e.g. after a manifest update)
.PHONY: update-manifest
update-manifest:
	@if [ -d "$(MANIFEST_DIR)/.git" ]; then \
		echo "Updating vendor-manifest..."; \
		git -C "$(MANIFEST_DIR)" fetch --depth=1 origin main && \
		git -C "$(MANIFEST_DIR)" reset --hard origin/main; \
	else \
		echo "Cloning vendor-manifest (private, requires GitHub auth)..."; \
		mkdir -p "$(WORK)"; \
		git clone --depth=1 "$(MANIFEST_REPO)" "$(MANIFEST_DIR)"; \
	fi

# ---- warm-cache -------------------------------------------------------------
# Pre-fetch all CIDs into the local kubo cache. Run once at runner bootstrap
# (after kubo install), or whenever the manifest adds new blobs.
# After warm-cache, all fetches are disk-speed instant.
.PHONY: warm-cache
warm-cache: $(MANIFEST_FILE)
	@echo "=== make warm-cache ==="
	@echo "Pinning all blob CIDs in local kubo..."
	@python3 -c " \
import tomllib, sys; \
f = open(sys.argv[1], 'rb'); m = tomllib.load(f); f.close(); \
cids = set(); \
[cids.add(b['cid']) for b in m.get('blobs', [])]; \
print(f'Pinning {len(cids)} unique CIDs...'); \
[print(c) for c in sorted(cids)]" "$(MANIFEST_FILE)" | \
	while read -r line; do \
		if [[ "$$line" == baf* ]]; then \
			printf "  pin %-70s " "$$line"; \
			if ipfs --api "$(IPFS_API)" pin ls --type=recursive "$$line" >/dev/null 2>&1; then \
				echo "ALREADY PINNED"; \
			elif ipfs --api "$(IPFS_API)" pin add --progress=false "$$line" >/dev/null 2>&1; then \
				echo "OK"; \
			else \
				echo "FAILED"; \
				echo "ERROR: failed to pin CID $$line" >&2; \
				exit 1; \
			fi; \
		else \
			echo "$$line"; \
		fi; \
	done
	@echo "=== warm-cache done ==="

# WiFi network name for dev builds (looked up in system keyring)
WIFI_SSID ?= Cobblejob

# ---- generate-wifi-config ---------------------------------------------------
# Pull WiFi PSK from the system keyring (secret-tool) and generate wifi.txt
# for the boot-resource FAT partition. Dev builds only — release images use
# the WiFi wizard (M1.D). The PSK is never committed; wifi.txt is gitignored.
#
# To store a PSK:
#   echo -n "YourPassword" | secret-tool store --label="PocketForge WiFi PSK (MyNetwork)" \
#     service pocketforge type wifi-psk network MyNetwork
BOOT_RES_DIR := $(CURDIR_ABS)/boards/tsp/boot-resource
WIFI_TXT     := $(BOOT_RES_DIR)/wifi.txt

.PHONY: generate-wifi-config
generate-wifi-config:
	@mkdir -p "$(BOOT_RES_DIR)"
	@PSK=$$(secret-tool lookup service pocketforge type wifi-psk network "$(WIFI_SSID)" 2>/dev/null) || true; \
	if [ -n "$${PF_WIFI_PSK:-}" ]; then \
		printf 'SSID=%s\nPSK=%s\n' "$(WIFI_SSID)" "$${PF_WIFI_PSK}" > "$(WIFI_TXT)"; \
		echo "  wifi.txt generated from PF_WIFI_PSK env for SSID=$(WIFI_SSID)"; \
	elif [ -n "$$PSK" ]; then \
		printf 'SSID=%s\nPSK=%s\n' "$(WIFI_SSID)" "$$PSK" > "$(WIFI_TXT)"; \
		echo "  wifi.txt generated from keyring for SSID=$(WIFI_SSID)"; \
	elif grep -q '^SSID=' "$(WIFI_TXT)" 2>/dev/null && grep -q '^PSK=' "$(WIFI_TXT)" 2>/dev/null; then \
		echo "  using pre-staged $(WIFI_TXT) (gitignored; no keyring/env PSK)"; \
	else \
		echo "WARN: No WiFi PSK (PF_WIFI_PSK env, keyring, or pre-staged wifi.txt) for '$(WIFI_SSID)' -- WiFi NOT configured"; \
		rm -f "$(WIFI_TXT)"; \
	fi

# ---- build-image ------------------------------------------------------------
# Build the SD image inside the container. Uses local blobs checkout by default.
# For CI, run 'make fetch-blobs' first, then 'make build-image BLOBS_SRC=work/blobs'.
#
# The container gets bind mounts:
#   /work/src     (ro) - this image repo
#   /work/blobs   (ro) - blobs repo checkout
#   /work/libsdl3 (ro) - libSDL3-pocketforge.so.0 release artifact
#   /work/out     (rw) - build output
#
# M1B_MODE=1 builds the M1.B busybox-shell image (no rootfs, non-root container).
# Default (M1B_MODE=0) builds the full Debian rootfs (M1.C+), which requires
# running the container as root (mmdebstrap needs real chroot/mount for cross-arch
# arm64 builds; the container provides the isolation boundary).
BLOBS_SRC ?= $(LOCAL_BLOBS)
LIBSDL3_SRC ?= $(LOCAL_LIBSDL3)

.PHONY: build-image
build-image: generate-wifi-config
	@echo "=== make build-image (variant=$(VARIANT), m1b=$(M1B_MODE)) ==="
	@[ -d "$(BLOBS_SRC)/tsp/boot-chain" ] || { echo "ERROR: blobs not found at $(BLOBS_SRC)"; echo "Set BLOBS_SRC= or LOCAL_BLOBS= to the blobs repo checkout"; exit 1; }
ifeq ($(M1B_MODE),0)
	@[ -f "$(LIBSDL3_SRC)/libSDL3-pocketforge.so.0" ] || { echo "ERROR: libSDL3-pocketforge.so.0 not found at $(LIBSDL3_SRC)"; echo "Set LIBSDL3_SRC= or LOCAL_LIBSDL3= to the build output directory"; exit 1; }
endif
	@mkdir -p "$(OUT_DIR)"
ifeq ($(M1B_MODE),1)
	docker run --rm \
		--user "$$(id -u):$$(id -g)" \
		-v "$(CURDIR_ABS):/work/src:ro" \
		-v "$(BLOBS_SRC):/work/blobs:ro" \
		-v "$(OUT_DIR):/work/out:rw" \
		-e SOURCE_DATE_EPOCH="$$(git log -1 --format=%ct)" \
		$(CONTAINER) \
		bash /work/src/scripts/build-sd-image.sh --m1b-mode --variant $(VARIANT)
else
	docker run --rm \
		-e CALLER_UID="$$(id -u)" -e CALLER_GID="$$(id -g)" \
		--cap-add SYS_ADMIN \
		--security-opt seccomp=unconfined \
		--security-opt apparmor=unconfined \
		-v "$(CURDIR_ABS):/work/src:ro" \
		-v "$(BLOBS_SRC):/work/blobs:ro" \
		-v "$(LIBSDL3_SRC):/work/libsdl3:ro" \
		-v "$(OUT_DIR):/work/out:rw" \
		-e SOURCE_DATE_EPOCH="$$(git log -1 --format=%ct)" \
		$(CONTAINER) \
		bash /work/src/scripts/build-sd-image.sh --variant $(VARIANT)
endif

# Build the rootfs ext4 only (no SD image composition).
# Runs as root inside the container (mmdebstrap needs chroot/mount).
.PHONY: build-rootfs
build-rootfs:
	@echo "=== make build-rootfs (variant=$(VARIANT)) ==="
	@[ -d "$(BLOBS_SRC)/tsp/boot-chain" ] || { echo "ERROR: blobs not found at $(BLOBS_SRC)"; exit 1; }
	@[ -f "$(LIBSDL3_SRC)/libSDL3-pocketforge.so.0" ] || { echo "ERROR: libSDL3 not found at $(LIBSDL3_SRC)"; exit 1; }
	@mkdir -p "$(OUT_DIR)"
	docker run --rm \
		-e CALLER_UID="$$(id -u)" -e CALLER_GID="$$(id -g)" \
		--cap-add SYS_ADMIN \
		--security-opt seccomp=unconfined \
		--security-opt apparmor=unconfined \
		-v "$(CURDIR_ABS):/work/src:ro" \
		-v "$(BLOBS_SRC):/work/blobs:ro" \
		-v "$(LIBSDL3_SRC):/work/libsdl3:ro" \
		-v "$(OUT_DIR):/work/out:rw" \
		-e SOURCE_DATE_EPOCH="$$(git log -1 --format=%ct)" \
		$(CONTAINER) \
		bash /work/src/scripts/build-rootfs.sh --variant $(VARIANT) --owner "$$(id -u):$$(id -g)"

# Build the SD image directly on the host (no container; for debugging only)
.PHONY: build-image-host
build-image-host:
	@echo "=== make build-image-host (variant=$(VARIANT), m1b=$(M1B_MODE)) ==="
	@[ -d "$(BLOBS_SRC)/tsp/boot-chain" ] || { echo "ERROR: blobs not found at $(BLOBS_SRC)"; exit 1; }
	@mkdir -p "$(OUT_DIR)"
	SRC_DIR="$(CURDIR_ABS)" BLOBS_DIR="$(BLOBS_SRC)" LIBSDL3_DIR="$(LIBSDL3_SRC)" OUT_DIR="$(OUT_DIR)" \
		SOURCE_DATE_EPOCH="$$(git log -1 --format=%ct)" \
		bash scripts/build-sd-image.sh $(if $(filter 1,$(M1B_MODE)),--m1b-mode) --variant $(VARIANT)

# ---- deploy (primary iteration target) --------------------------------------
# Rsync rootfs-overlay configs + /opt/pocketforge/ to the running dev rootfs.
# Uses gamer@ with passwordless sudo (dev variant only).
# SSH retry loop (5s x 60 attempts, silent) per AGENTS.md.
TSP_HOST ?= gamer@192.168.86.98

.PHONY: deploy
deploy:
	@echo "=== make deploy -> $(TSP_HOST) ==="
	TSP_HOST="$(TSP_HOST)" LIBSDL3_DIR="$(LIBSDL3_SRC)" SRC_DIR="$(CURDIR_ABS)" \
		bash "$(CURDIR_ABS)/scripts/deploy.sh"

# ---- reflash-boot (rebuild boot.img + write to SD) --------------------------
# Rebuilds boot.img (initrd + kernel + cmdline) inside the container, then
# writes it to the SD's boot partition. Two modes:
#   make reflash-boot              — SD in host reader (default)
#   make reflash-boot MODE=ssh     — live-write via SSH to running device
#
# The build always runs in the container (needs cross readelf + abootimg);
# the write runs on the host or via SSH.
MODE ?= sd
BOOT_PART ?= /dev/disk/by-partlabel/boot

.PHONY: reflash-boot
reflash-boot:
	@echo "=== make reflash-boot (mode=$(MODE)) ==="
	@[ -d "$(BLOBS_SRC)/tsp/boot-chain" ] || { echo "ERROR: blobs not found at $(BLOBS_SRC)"; exit 1; }
	@mkdir -p "$(OUT_DIR)"
	docker run --rm \
		--user "$$(id -u):$$(id -g)" \
		-v "$(CURDIR_ABS):/work/src:ro" \
		-v "$(BLOBS_SRC):/work/blobs:ro" \
		-v "$(OUT_DIR):/work/out:rw" \
		-e SOURCE_DATE_EPOCH="$$(git log -1 --format=%ct)" \
		$(CONTAINER) \
		bash /work/src/scripts/build-sd-image.sh --boot-only --variant $(VARIANT)
ifeq ($(MODE),ssh)
	@echo "Writing boot.img to device via SSH..."
	scp -o BatchMode=yes -o ConnectTimeout=8 -i ~/.ssh/id_ed25519 \
		"$(OUT_DIR)/boot.img" "$(TSP_HOST):/tmp/boot.img"
	ssh -o BatchMode=yes -o ConnectTimeout=8 -i ~/.ssh/id_ed25519 \
		"$(TSP_HOST)" 'sudo dd if=/tmp/boot.img of=/dev/disk/by-partlabel/boot bs=4M conv=fsync && rm /tmp/boot.img && echo "boot.img written; reboot to apply"'
else
	@bash "$(CURDIR_ABS)/scripts/sd-safety-check.sh" "$(BOOT_PART)" "$(SD_MAX_SIZE_BYTES)"
	sudo dd if="$(OUT_DIR)/boot.img" of="$(BOOT_PART)" bs=4M conv=fsync status=progress
	@echo "boot.img written to $(BOOT_PART). Safe to remove SD."
endif

# ---- wipe-userdata (fresh ext4 for first-boot UX testing) -------------------
# SD-reader-ONLY: you cannot rewrite the partition you're running from.
# Creates a fresh ext4 with the committed UUIDs from fs-uuids.env.
USERDATA_PART ?= /dev/disk/by-partlabel/userdata
SD_MAX_SIZE_BYTES ?= 137438953472

.PHONY: wipe-userdata
wipe-userdata:
	@echo "=== make wipe-userdata (SD reader only) ==="
	@bash "$(CURDIR_ABS)/scripts/sd-safety-check.sh" "$(USERDATA_PART)" "$(SD_MAX_SIZE_BYTES)"
	@echo "Loading filesystem UUIDs..."
	@. boards/tsp/fs-uuids.env && \
		echo "  UUID=$$USERDATA_FS_UUID  hash_seed=$$USERDATA_HASH_SEED" && \
		sudo mke2fs -t ext4 -L POCKETFORGE_DATA \
			-U "$$USERDATA_FS_UUID" \
			-E "hash_seed=$$USERDATA_HASH_SEED" \
			-m 0 -O "^metadata_csum" \
			"$(USERDATA_PART)" && \
		echo "userdata partition wiped. Fresh ext4 ready for first-boot."

# ---- full-image (alias for build-image with YYYY.MM naming) -----------------
# Produces out/pocketforge-tsp-{dev-,}YYYY.MM.img.xz + SHA-256 manifest.
# This is the gate before each Release publication.
.PHONY: full-image
full-image: build-image

# ---- clean ------------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf "$(BLOBS_DIR)" "$(OUT_DIR)"

.PHONY: clean-all
clean-all:
	rm -rf "$(WORK)"

# ---- help -------------------------------------------------------------------
.PHONY: help
help:
	@echo "PocketForge image build targets:"
	@echo ""
	@echo "  Build:"
	@echo "    build-image      Build the full SD image in the container"
	@echo "    build-rootfs     Build only the rootfs ext4 in the container"
	@echo "    build-image-host Build on host directly (debugging only, no container)"
	@echo "    full-image       Alias for build-image (release gate)"
	@echo ""
	@echo "  Iteration (fast dev loop):"
	@echo "    deploy           Rsync configs + libs to running dev rootfs (seconds)"
	@echo "    reflash-boot     Rebuild boot.img + write to SD boot partition (1-2 min)"
	@echo "    wipe-userdata    Fresh ext4 on userdata partition, SD-reader only"
	@echo ""
	@echo "  Blob management:"
	@echo "    fetch-blobs      Fetch vendor blobs via IPFS (reads signed manifest)"
	@echo "    warm-cache       Pin all blob CIDs in local kubo (run once per machine)"
	@echo "    update-manifest  Force-update the vendor-manifest repo"
	@echo ""
	@echo "  Cleanup:"
	@echo "    clean            Remove work/blobs and work/out"
	@echo "    clean-all        Remove entire work/ directory"
	@echo ""
	@echo "Environment variables:"
	@echo "  VARIANT          Image variant: dev (default) or release"
	@echo "  M1B_MODE         Set to 1 for M1.B busybox-shell image (default: 0)"
	@echo "  TSP_HOST         Deploy target (default: gamer@192.168.86.98)"
	@echo "  MODE             reflash-boot write mode: sd (default) or ssh"
	@echo "  BOOT_PART        Boot partition path (default: /dev/disk/by-partlabel/boot)"
	@echo "  USERDATA_PART    Userdata partition path (default: /dev/disk/by-partlabel/userdata)"
	@echo "  SD_MAX_SIZE_BYTES  Max disk size safety cap (default: 128 GiB)"
	@echo "  LOCAL_BLOBS      Path to local blobs repo checkout (default: ~/blobs)"
	@echo "  LOCAL_LIBSDL3    Path to libSDL3 build dir (default: ~/libsdl3-sunxifb/_build)"
	@echo "  BLOBS_SRC        Override blobs source for build-image (default: LOCAL_BLOBS)"
	@echo "  LIBSDL3_SRC      Override libsdl3 source (default: LOCAL_LIBSDL3)"
	@echo "  IPFS_API         kubo API multiaddr (default: /ip4/127.0.0.1/tcp/5001)"
	@echo ""
	@echo "Quick start (M1.C full image):"
	@echo "  1. make build-image VARIANT=dev"
	@echo "  2. xz -dc work/out/pocketforge-tsp-dev.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync"
	@echo ""
	@echo "Fast iteration loop:"
	@echo "  1. (edit code)"
	@echo "  2. make deploy                         # seconds"
	@echo "  3. (verify on device)"
	@echo ""
	@echo "M1.B mode (busybox shell, no rootfs):"
	@echo "  1. make build-image M1B_MODE=1"
