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

# ---- build-image ------------------------------------------------------------
# Build the SD image inside the container. Uses local blobs checkout by default.
# For CI, run 'make fetch-blobs' first, then 'make build-image BLOBS_SRC=work/blobs'.
#
# The container gets bind mounts:
#   /work/src   (ro) - this image repo
#   /work/blobs (ro) - blobs repo checkout
#   /work/out   (rw) - build output
BLOBS_SRC ?= $(LOCAL_BLOBS)

.PHONY: build-image
build-image:
	@echo "=== make build-image (variant=$(VARIANT)) ==="
	@[ -d "$(BLOBS_SRC)/tsp/boot-chain" ] || { echo "ERROR: blobs not found at $(BLOBS_SRC)"; echo "Set BLOBS_SRC= or LOCAL_BLOBS= to the blobs repo checkout"; exit 1; }
	@mkdir -p "$(OUT_DIR)"
	docker run --rm \
		--user "$$(id -u):$$(id -g)" \
		-v "$(CURDIR_ABS):/work/src:ro" \
		-v "$(BLOBS_SRC):/work/blobs:ro" \
		-v "$(OUT_DIR):/work/out:rw" \
		-e SOURCE_DATE_EPOCH="$$(git log -1 --format=%ct)" \
		$(CONTAINER) \
		bash /work/src/scripts/build-sd-image.sh --m1b-mode --variant $(VARIANT)

# Build the SD image directly on the host (no container; for debugging only)
.PHONY: build-image-host
build-image-host:
	@echo "=== make build-image-host (variant=$(VARIANT)) ==="
	@[ -d "$(BLOBS_SRC)/tsp/boot-chain" ] || { echo "ERROR: blobs not found at $(BLOBS_SRC)"; exit 1; }
	@mkdir -p "$(OUT_DIR)"
	SRC_DIR="$(CURDIR_ABS)" BLOBS_DIR="$(BLOBS_SRC)" OUT_DIR="$(OUT_DIR)" \
		SOURCE_DATE_EPOCH="$$(git log -1 --format=%ct)" \
		bash scripts/build-sd-image.sh --m1b-mode --variant $(VARIANT)

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
	@echo "  build-image      Build the SD image in the container (default: --m1b-mode)"
	@echo "  build-image-host Build on host directly (debugging only, no container)"
	@echo "  fetch-blobs      Fetch vendor blobs via IPFS (reads signed manifest)"
	@echo "  warm-cache       Pin all blob CIDs in local kubo (run once per machine)"
	@echo "  update-manifest  Force-update the vendor-manifest repo"
	@echo "  clean            Remove work/blobs and work/out"
	@echo "  clean-all        Remove entire work/ directory"
	@echo ""
	@echo "Environment variables:"
	@echo "  VARIANT          Image variant: dev (default) or release"
	@echo "  LOCAL_BLOBS      Path to local blobs repo checkout (default: ~/blobs)"
	@echo "  BLOBS_SRC        Override blobs source for build-image (default: LOCAL_BLOBS)"
	@echo "  IPFS_API         kubo API multiaddr (default: /ip4/127.0.0.1/tcp/5001)"
	@echo ""
	@echo "Quick start (first SD image):"
	@echo "  1. make build-image"
	@echo "  2. xz -dc work/out/pocketforge-tsp-dev-m1b.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync"
