#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy userspace artifacts to a running PocketForge dev rootfs
# =============================================================================
# Rsyncs the rootfs-overlay (config files under /etc/, /usr/lib/) and
# /opt/pocketforge/ (libSDL3, supervisor, apps) to the device over SSH,
# then restarts the kiosk service.
#
# This is the v2 deploy script for PocketForge's own Debian rootfs (M1.C+).
# It supersedes the Phase 0 deploy-to-tsp.sh which targeted root@ on stock
# CrossMix with scp.
#
# Implements the SSH retry loop mandated by AGENTS.md: 5-second interval,
# 60 attempts (5 minutes), silent during retries, report only final outcome.
#
# Usage:
#   deploy.sh [--overlay-only] [--pocketforge-only] [--no-restart]
#
# Environment:
#   TSP_HOST      Target host (default: gamer@192.168.86.98)
#   SSH_KEY       SSH identity file (default: ~/.ssh/id_ed25519)
#   LIBSDL3_DIR   Path to libSDL3 build dir (default: ~/libsdl3-sunxifb/_build)
#   SRC_DIR       Path to image repo root (default: script's parent dir)
#
# bd: tsp-iuz.2.7
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- configuration ---------------------------------------------------------
TSP_HOST="${TSP_HOST:-gamer@192.168.86.98}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
LIBSDL3_DIR="${LIBSDL3_DIR:-${HOME}/libsdl3-sunxifb/_build}"
SRC_DIR="${SRC_DIR:-$(dirname "${SCRIPT_DIR}")}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new -i "${SSH_KEY}")
RSYNC_SSH="ssh ${SSH_OPTS[*]}"

RETRY_INTERVAL=5
RETRY_MAX=60

# Parse arguments
DO_OVERLAY=1
DO_POCKETFORGE=1
DO_RESTART=1
while [ $# -gt 0 ]; do
    case "$1" in
        --overlay-only)     DO_POCKETFORGE=0; shift ;;
        --pocketforge-only) DO_OVERLAY=0; shift ;;
        --no-restart)       DO_RESTART=0; shift ;;
        -h|--help)
            echo "Usage: deploy.sh [--overlay-only] [--pocketforge-only] [--no-restart]"
            echo ""
            echo "Deploys rootfs-overlay configs and /opt/pocketforge/ to the device."
            echo "Set TSP_HOST, SSH_KEY, LIBSDL3_DIR, SRC_DIR via environment."
            exit 0
            ;;
        *) echo "deploy.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ---- SSH retry loop (AGENTS.md mandate) ------------------------------------
# Tries SSH connectivity for up to 5 minutes. Silent during retries.
# Returns 0 on success, 1 on failure.
ssh_retry() {
    local cmd=("$@")
    local attempt=0
    local start_time
    start_time="$(date +%s)"

    while [ $attempt -lt $RETRY_MAX ]; do
        if ssh "${SSH_OPTS[@]}" "${TSP_HOST}" "${cmd[@]}" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "${RETRY_INTERVAL}"
    done

    local elapsed=$(( $(date +%s) - start_time ))
    echo "ERROR: SSH to ${TSP_HOST} failed after ${RETRY_MAX} attempts (${elapsed}s elapsed)" >&2
    return 1
}

# Rsync with retry — retries the full rsync command on SSH failure.
rsync_retry() {
    local attempt=0
    local start_time
    start_time="$(date +%s)"

    while [ $attempt -lt $RETRY_MAX ]; do
        if rsync "$@" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "${RETRY_INTERVAL}"
    done

    local elapsed=$(( $(date +%s) - start_time ))
    echo "ERROR: rsync to ${TSP_HOST} failed after ${RETRY_MAX} attempts (${elapsed}s elapsed)" >&2
    return 1
}

# ---- pre-flight: verify SSH connectivity -----------------------------------
echo "Connecting to ${TSP_HOST}..."
if ! ssh_retry true; then
    echo "FATAL: device unreachable at ${TSP_HOST}" >&2
    exit 1
fi
echo "  Connected."

# ---- deploy rootfs-overlay (config files) ----------------------------------
if [ "$DO_OVERLAY" = 1 ]; then
    OVERLAY_DIR="${SRC_DIR}/rootfs-overlay"
    if [ ! -d "${OVERLAY_DIR}" ]; then
        echo "WARN: rootfs-overlay not found at ${OVERLAY_DIR}, skipping config deploy" >&2
    else
        echo "Deploying rootfs-overlay -> /..."
        # rsync the overlay tree to / on the device.
        # --rsync-path='sudo rsync' because target paths (/etc/, /usr/lib/) are root-owned.
        # --chmod=D755,F644 preserves standard permissions for config files.
        rsync_retry -rlpt --rsync-path='sudo rsync' \
            -e "${RSYNC_SSH}" \
            "${OVERLAY_DIR}/" "${TSP_HOST}:/"
        echo "  rootfs-overlay deployed."
    fi
fi

# ---- deploy /opt/pocketforge/ (libraries, apps, supervisor) ----------------
if [ "$DO_POCKETFORGE" = 1 ]; then
    # Stage files into a local tree matching the on-device layout.
    # Currently: libSDL3-pocketforge.so.0 under lib/
    # M1.D will add: supervisor binary, apps/, etc.
    STAGE_DIR="${SRC_DIR}/work/deploy-stage/opt/pocketforge"
    mkdir -p "${STAGE_DIR}/lib"

    if [ -f "${LIBSDL3_DIR}/libSDL3-pocketforge.so.0" ]; then
        cp "${LIBSDL3_DIR}/libSDL3-pocketforge.so.0" "${STAGE_DIR}/lib/"
        echo "Deploying /opt/pocketforge/..."
        rsync_retry -rlpt --rsync-path='sudo rsync' \
            -e "${RSYNC_SSH}" \
            "${STAGE_DIR}/" "${TSP_HOST}:/opt/pocketforge/"
        echo "  /opt/pocketforge/ deployed."
    else
        echo "WARN: libSDL3-pocketforge.so.0 not found at ${LIBSDL3_DIR}, skipping" >&2
    fi
fi

# ---- restart kiosk service -------------------------------------------------
if [ "$DO_RESTART" = 1 ]; then
    echo "Reloading systemd and restarting kiosk..."
    # The || true is because pocketforge-kiosk.service does not exist until M1.D.
    ssh_retry 'sudo systemctl daemon-reload && sudo systemctl restart pocketforge-kiosk 2>/dev/null || true'
    echo "  daemon-reload done (kiosk restart attempted)."
fi

echo ""
echo "Deploy complete to ${TSP_HOST}."
