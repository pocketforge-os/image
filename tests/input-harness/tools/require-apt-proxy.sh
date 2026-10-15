#!/bin/sh
# Source this at the start of every payload producer RUN that invokes apt.
case "${PF_APT_PROXY:-}" in
    '')
        echo 'input-harness-payload=REFUSED reason=missing_apt_proxy' >&2
        exit 64
        ;;
    http://*) ;;
    *)
        echo 'input-harness-payload=REFUSED reason=invalid_apt_proxy' >&2
        exit 64
        ;;
esac
export http_proxy="$PF_APT_PROXY"
