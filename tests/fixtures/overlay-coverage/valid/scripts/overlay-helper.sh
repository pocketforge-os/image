#!/usr/bin/env bash

install -D -m 0755 \
    "${SRC_DIR}/rootfs-overlay/usr/lib/helper.sh" \
    "${ROOTFS}/usr/lib/helper.sh"
