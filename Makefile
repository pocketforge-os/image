# =============================================================================
# PocketForge image — top-level Makefile
# =============================================================================
# The owned OS-image build lives in the platform: `pf build --device <id>
# --artifact os-image` drives the multistage build/Dockerfile.pf entirely
# in-container from committed refs (hermetic kubo .car blob fetch), resolving
# every source THROUGH platform.lock. The legacy host-orchestrated image build
# (`make build-image SUBSTRATE=owned LOCAL_*` + bind-mounted pre-built kernel/
# GPU/SDL trees + `build-image-host`) was RETIRED in tsp-1dl.4.5 — this Makefile
# no longer builds the image.
#
# What remains here: the host-side vendor-blob fetch helpers (fetch-blobs,
# warm-cache, update-manifest) and dev wifi.txt generation.
#
# bd: tsp-iby.3 (fetch-blobs, warm-cache)
# =============================================================================

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# ---- paths ------------------------------------------------------------------
CURDIR_ABS := $(shell pwd)
WORK       := $(CURDIR_ABS)/work
BLOBS_DIR  := $(WORK)/blobs
OUT_DIR    := $(WORK)/out

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
	@echo "PocketForge image — remaining make targets:"
	@echo ""
	@echo "  The OWNED OS-image build is NOT here — run it from the platform repo:"
	@echo "    pf build --device a133 --artifact os-image --target dev-modelmaker --no-dry-run"
	@echo "  (in-container multistage build from committed refs; hermetic .car blob fetch)."
	@echo "  The legacy 'make build-image SUBSTRATE=owned LOCAL_*' path was retired (tsp-1dl.4.5)."
	@echo ""
	@echo "  Blob management (host-side vendor-blob fetch):"
	@echo "    fetch-blobs      Fetch vendor blobs via IPFS (reads signed manifest)"
	@echo "    warm-cache       Pin all blob CIDs in local kubo (run once per machine)"
	@echo "    update-manifest  Force-update the vendor-manifest repo"
	@echo ""
	@echo "  Dev helpers:"
	@echo "    generate-wifi-config  Stage boards/tsp/boot-resource/wifi.txt from PF_WIFI_PSK/keyring"
	@echo ""
	@echo "  Cleanup:"
	@echo "    clean            Remove work/blobs and work/out"
	@echo "    clean-all        Remove entire work/ directory"
	@echo ""
	@echo "Environment variables:"
	@echo "  WIFI_SSID        WiFi SSID for generate-wifi-config (default: Cobblejob)"
	@echo "  PF_WIFI_PSK      WiFi PSK for generate-wifi-config (else keyring or pre-staged wifi.txt)"
	@echo "  IPFS_API         kubo API multiaddr (default: /ip4/127.0.0.1/tcp/5001)"
