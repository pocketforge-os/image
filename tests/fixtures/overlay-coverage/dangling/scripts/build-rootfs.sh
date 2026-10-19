#!/usr/bin/env bash

install -D -m 0644 \
    "/work/src/rootfs-overlay/etc/literal.conf" \
    "${ROOTFS}/etc/literal.conf"
install -D -m 0644 \
    "/work/src/rootfs-overlay/etc/missing.conf" \
    "${ROOTFS}/etc/missing.conf"
