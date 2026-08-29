#!/bin/sh
# F13 device/simulator fault definitions. This file defines the deferred proof;
# it does not claim that the proof has run on product-010 hardware.
set -eu

AUTHORITY_UNIT=pf-session-authorityd.service
SELECTED_UNIT=pf-shell-selected.service
FOREGROUND_TEMPLATE=pf-foreground@
STATE_FILE=/var/lib/pocketforge/session-authority/authority.json
SOCKET=/run/pocketforge/session-authority.sock

fail() { echo "F13 fault test: FAIL: $*" >&2; exit 1; }
require_active() { [ "$(systemctl is-active "$1")" = active ] || fail "$1 is not active"; }
require_inactive() { [ "$(systemctl is-active "$1")" = inactive ] || fail "$1 is not inactive"; }
require_socket() { [ -S "$SOCKET" ] || fail "authority socket is absent: $SOCKET"; }
require_recovery() {
    session=$1
    grep -F '"RecoveryRequired"' "$STATE_FILE" >/dev/null || fail "RecoveryRequired is not durable"
    grep -F "$session" "$STATE_FILE" >/dev/null || fail "RecoveryRequired lacks session $session"
}
assert_ack_before_receipt() {
    events=$1
    ack_line=$(grep -n 'PresentationAcknowledged' "$events" | tail -1 | cut -d: -f1)
    receipt_line=$(grep -n 'TerminalReceipt' "$events" | head -1 | cut -d: -f1)
    if [ -z "$ack_line" ] || [ -z "$receipt_line" ] || [ "$ack_line" -ge "$receipt_line" ]; then
        fail "presentation acknowledgement did not precede terminal receipt"
    fi
}

# Harness contract: SESSION_ID identifies an already-started test session and
# EVENTS is the ordered client observation log. The harness injects each rung,
# then calls this definition with RUNG=graceful-timeout|unit-inactive|
# target-released|owner-activation. Every rung must persist RecoveryRequired.
run_fault_rung() {
    : "${SESSION_ID:?SESSION_ID is required}"
    : "${EVENTS:?EVENTS is required}"
    unit="${FOREGROUND_TEMPLATE}${SESSION_ID}.service"
    require_active "$AUTHORITY_UNIT"
    require_socket
    case "${RUNG:?RUNG is required}" in
        graceful-timeout)
            # stop is bounded by TimeoutStopSec=2s; the authority's next rung is
            # systemctl kill --kill-who=all, matching CommandTemplates exactly.
            systemctl stop "$unit" || true
            systemctl kill --kill-who=all "$unit" || true
            require_inactive "$unit"
            ;;
        unit-inactive)
            systemctl stop "$unit" || true
            require_inactive "$unit"
            ;;
        target-released)
            require_inactive "$unit"
            ;;
        owner-activation)
            systemctl stop "$SELECTED_UNIT" || true
            require_inactive "$SELECTED_UNIT"
            ;;
        *) fail "unknown rung: $RUNG" ;;
    esac
    require_active "$AUTHORITY_UNIT"
    require_recovery "$SESSION_ID"
    require_active "$SELECTED_UNIT"
    assert_ack_before_receipt "$EVENTS"
}

case "${1:---check}" in
    --check)
        grep -F 'TimeoutStopSec=2s' "$(dirname "$0")/../rootfs-overlay/etc/systemd/system/pf-foreground@.service" >/dev/null
        grep -F 'ExecStart=/usr/bin/pf-session-authorityd --state-dir /var/lib/pocketforge/session-authority --socket /run/pocketforge/session-authority.sock' \
            "$(dirname "$0")/../rootfs-overlay/etc/systemd/system/pf-session-authorityd.service" >/dev/null
        printf '%s\n' 'F13 fault definitions: PASS (syntax/contracts; execution deferred)'
        ;;
    --run) run_fault_rung ;;
    *) fail "usage: $0 [--check|--run]" ;;
esac
