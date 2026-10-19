#!/usr/bin/env bash

source "${SRC_DIR}/scripts/overlay-helper.sh"

install -D -m 0644 \
    "/work/src/rootfs-overlay/etc/literal.conf" \
    "${ROOTFS}/etc/literal.conf"

PF_PANEL_OWNER=shell
case "${PF_PANEL_OWNER}" in
    shell) ;;
    menu) ;;
    placeholder) ;;
    animator) ;;
esac
owner_dropin="/work/src/rootfs-overlay/etc/systemd/system/pocketforge-foreground.target.d/10-owner-${PF_PANEL_OWNER}.conf"
install -D -m 0644 "${owner_dropin}" "${ROOTFS}/etc/systemd/system/owner.conf"
