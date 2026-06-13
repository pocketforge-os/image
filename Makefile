# =============================================================================
# PocketForge image — top-level Makefile
# =============================================================================
# Phase 1 build pipeline entry points. Blob fetching runs on the host (outside
# the container); image assembly runs inside the container via bind mounts.
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
CACHE_DIR  := $(WORK)/cache
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
	@echo "  fetch-blobs      Fetch vendor blobs via IPFS (reads signed manifest)"
	@echo "  warm-cache       Pin all blob CIDs in local kubo (run once per machine)"
	@echo "  update-manifest  Force-update the vendor-manifest repo"
	@echo "  clean            Remove work/blobs and work/out"
	@echo "  clean-all        Remove entire work/ directory"
	@echo ""
	@echo "Environment variables:"
	@echo "  IPFS_API         kubo API multiaddr (default: /ip4/127.0.0.1/tcp/5001)"
	@echo ""
	@echo "First-time setup on a new machine:"
	@echo "  1. Install kubo (see kubo.pin for version)"
	@echo "  2. sudo systemctl start ipfs"
	@echo "  3. make warm-cache"
	@echo "  4. make fetch-blobs"
