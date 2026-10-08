# =============================================================================
# PocketForge image — top-level Makefile
# =============================================================================
# The owned OS-image build lives in the platform: `pf build --device <id>
# --artifact os-image` drives the multistage build/Dockerfile.pf entirely
# in-container from committed refs (hermetic in-container .car blob fetch),
# resolving every source THROUGH platform.lock. The legacy host-orchestrated
# image build (`make build-image SUBSTRATE=owned LOCAL_*` + bind-mounted
# pre-built kernel/GPU/SDL trees + `build-image-host`) was RETIRED in
# tsp-1dl.4.5; its remaining host-side helpers (the kubo fetch-blobs/warm-cache/
# update-manifest targets — pf build now fetches the .car in-container) were
# removed in tsp-7xe. This Makefile no longer builds the image or fetches blobs.
#
# What remains here: hermetic source checks and local cleanup helpers.
# =============================================================================

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# ---- paths ------------------------------------------------------------------
CURDIR_ABS := $(shell pwd)
WORK       := $(CURDIR_ABS)/work

# ---- hermetic build-file tests ----------------------------------------------
.PHONY: test-app-runtime-root test-cts-bundle-image test-gles32-candidate-profile test-dockerfile-pf-transforms test-kernel-build-identity
test-app-runtime-root:
	@tests/test-app-runtime-root.sh

test-cts-bundle-image:
	@tests/test-cts-bundle-image.sh

test-gles32-candidate-profile:
	@tests/test-gles32-candidate-profile.sh

test-dockerfile-pf-transforms:
	@tests/test-a133-cma-bootargs.sh
	@tests/test-dockerfile-pf-transforms.sh
	@tests/test-initrd-selfflash-watchdog.sh
	@tests/test-poolsuite-variant-stage.sh
	@python3 -B tests/test-poolsuite-source-digest.py
	@tests/test-poolsuite-rootfs-install.sh
	@tests/test-default-app-platform.sh
	@tests/test-default-app-rootfs.sh
	@python3 tests/verify-gamepad-input-wiring.py
	@python3 tests/verify-owned-spl-layout-gate.py
	@tests/test-launcher-runtime-contract.sh
	@tests/test-session-authority-systemd-safety.sh
	@tests/test-session-compositor-contract.sh
	@python3 -B tests/test-reproducible-assembly.py

test-kernel-build-identity:
	@bash tests/test-kernel-build-identity.sh

# ---- clean ------------------------------------------------------------------
.PHONY: clean clean-all
clean clean-all:
	@if [ -d "$(WORK)" ]; then \
		find "$(WORK)" -mindepth 1 -delete; \
		rmdir "$(WORK)"; \
	fi

# ---- help -------------------------------------------------------------------
.PHONY: help
help:
	@echo "PocketForge image — remaining make targets:"
	@echo ""
	@echo "  The OWNED OS-image build is NOT here — run it from the platform repo:"
	@echo "    pf build --device a133 --artifact os-image --target dev-modelmaker --no-dry-run"
	@echo "  (in-container multistage build from committed refs; hermetic in-container .car blob fetch)."
	@echo "  The legacy 'make build-image SUBSTRATE=owned LOCAL_*' path was retired (tsp-1dl.4.5;"
	@echo "  its host-side fetch-blobs/warm-cache/update-manifest helpers were removed in tsp-7xe)."
	@echo ""
	@echo "  Dev helpers:"
	@echo "    test-app-runtime-root          Test proposed app-root rendering/isolation (no network)"
	@echo "    test-dockerfile-pf-transforms  Test Dockerfile source transforms (no Docker/network)"
	@echo "    test-kernel-build-identity    Test pinned kernel UTS identity (no Docker/network)"
	@echo ""
	@echo "  Cleanup:"
	@echo "    clean / clean-all     Remove the work/ directory"
	@echo ""
