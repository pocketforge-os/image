#!/bin/sh
set -eu

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ "$#" -eq 2 ] || fail "expected runner uid and gid"
uid=$1
gid=$2

case "${uid}:${gid}" in
    *[!0-9:]*|*::*|:*|*:)
        fail "runner uid and gid must be numeric"
        ;;
esac

[ "${uid}" -ge 1000 ] || fail "runner uid ${uid} is a reserved system identity"
[ "${gid}" -ge 1000 ] || fail "runner gid ${gid} is a reserved system identity"
[ "${uid}" -ne 65534 ] || fail "runner uid collides with the nobody negative control"
[ "${gid}" -ne 65534 ] || fail "runner gid collides with the nobody negative control"

printf '%s:%s\n' "${uid}" "${gid}"
