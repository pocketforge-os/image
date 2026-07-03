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
# What remains here: dev wifi.txt generation and SD-card helpers.
# =============================================================================

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# ---- paths ------------------------------------------------------------------
CURDIR_ABS := $(shell pwd)
WORK       := $(CURDIR_ABS)/work

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
			-m 0 -O "^metadata_csum,^metadata_csum_seed,^orphan_file,^64bit" \
			"$(USERDATA_PART)" && \
		echo "userdata partition wiped. Fresh ext4 ready for first-boot."

# ---- clean ------------------------------------------------------------------
.PHONY: clean clean-all
clean clean-all:
	rm -rf "$(WORK)"

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
	@echo "  Dev / SD helpers:"
	@echo "    generate-wifi-config  Stage boards/tsp/boot-resource/wifi.txt from PF_WIFI_PSK/keyring"
	@echo "    wipe-userdata         Fresh ext4 on the userdata partition (SD reader only)"
	@echo ""
	@echo "  Cleanup:"
	@echo "    clean / clean-all     Remove the work/ directory"
	@echo ""
	@echo "Environment variables:"
	@echo "  WIFI_SSID        WiFi SSID for generate-wifi-config (default: Cobblejob)"
	@echo "  PF_WIFI_PSK      WiFi PSK for generate-wifi-config (else keyring or pre-staged wifi.txt)"
	@echo "  USERDATA_PART    Userdata partition path (default: /dev/disk/by-partlabel/userdata)"
	@echo "  SD_MAX_SIZE_BYTES  Max disk size safety cap (default: 128 GiB)"
