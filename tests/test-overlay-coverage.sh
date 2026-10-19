#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
checker="${root}/scripts/check-overlay-coverage.py"
fixtures="${root}/tests/fixtures/overlay-coverage"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/overlay-coverage-test.XXXXXX")"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

if ! "${checker}" --repo "${fixtures}/valid" >"${tmp}/valid.out" 2>"${tmp}/valid.err"; then
    echo "FAIL: valid overlay fixture was rejected" >&2
    cat "${tmp}/valid.err" >&2
    exit 1
fi
grep -Fxq 'OVERLAY_COVERAGE PASS files=8 referenced=6 not_installed=2' "${tmp}/valid.out" || {
    echo 'FAIL: valid fixture did not report its complete coverage totals' >&2
    cat "${tmp}/valid.out" >&2
    exit 1
}

if "${checker}" --repo "${fixtures}/malformed-manifest" \
    >"${tmp}/manifest.out" 2>"${tmp}/manifest.err"; then
    echo 'FAIL: malformed NOT-INSTALLED fixture was accepted' >&2
    exit 1
fi
grep -Fq 'MANIFEST NOT-INSTALLED:1: expected path<TAB>one-line reason' \
    "${tmp}/manifest.err" || {
    echo 'FAIL: malformed manifest fixture did not report its missing reason' >&2
    cat "${tmp}/manifest.err" >&2
    exit 1
}

if "${checker}" --repo "${fixtures}/orphan" >"${tmp}/orphan.out" 2>"${tmp}/orphan.err"; then
    echo 'FAIL: orphan overlay fixture was accepted' >&2
    exit 1
fi
grep -Fq 'ORPHAN etc/systemd/system/pocketforge-foreground.target.d/10-owner-ghost.conf' \
    "${tmp}/orphan.err" || {
    echo 'FAIL: orphan fixture did not name its unreferenced file' >&2
    cat "${tmp}/orphan.err" >&2
    exit 1
}

if "${checker}" --repo "${fixtures}/dangling" >"${tmp}/dangling.out" 2>"${tmp}/dangling.err"; then
    echo 'FAIL: dangling installer fixture was accepted' >&2
    exit 1
fi
grep -Fq 'DANGLING scripts/build-rootfs.sh:etc/missing.conf' "${tmp}/dangling.err" || {
    echo 'FAIL: dangling fixture did not name its missing overlay path' >&2
    cat "${tmp}/dangling.err" >&2
    exit 1
}

mkdir -p "${tmp}/bin"
mkdir -p "${tmp}/target/usr/lib"
printf '%s\n' stale >"${tmp}/target/usr/lib/preserved.sh"
printf '%s\n' stale >"${tmp}/target/usr/lib/preserved-two.sh"
printf '%s\n' keep >"${tmp}/target/usr/lib/keep.sh"
cat >"${tmp}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
after_separator=0
for arg in "$@"; do
    if [ "${after_separator}" = 1 ]; then
        case "${arg}" in
            /*)
                target="${FAKE_TARGET_ROOT}${arg}"
                [ ! -d "${target}" ] || exit 1
                rm -f -- "${target}"
                ;;
        esac
    elif [ "${arg}" = -- ]; then
        after_separator=1
    fi
done
exit 0
EOF
cat >"${tmp}/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${RSYNC_CAPTURE}"
EOF
chmod +x "${tmp}/bin/ssh" "${tmp}/bin/rsync"
RSYNC_CAPTURE="${tmp}/rsync.args" \
FAKE_TARGET_ROOT="${tmp}/target" \
PATH="${tmp}/bin:${PATH}" \
SRC_DIR="${fixtures}/valid" \
TSP_HOST=fixture@invalid \
SSH_KEY="${tmp}/unused-key" \
    "${root}/scripts/deploy.sh" --overlay-only --no-restart >"${tmp}/deploy.out"
grep -Fxq -- '--exclude=/NOT-INSTALLED' "${tmp}/rsync.args" || {
    echo 'FAIL: deploy would copy the overlay exclusion manifest' >&2
    cat "${tmp}/rsync.args" >&2
    exit 1
}
grep -Fxq -- '--exclude=/usr/lib/preserved.sh' "${tmp}/rsync.args" || {
    echo 'FAIL: deploy would copy a NOT-INSTALLED overlay path' >&2
    cat "${tmp}/rsync.args" >&2
    exit 1
}
grep -Fxq -- '--exclude=/usr/lib/preserved-two.sh' "${tmp}/rsync.args" || {
    echo 'FAIL: deploy would copy the second NOT-INSTALLED overlay path' >&2
    cat "${tmp}/rsync.args" >&2
    exit 1
}
[ ! -e "${tmp}/target/usr/lib/preserved.sh" ] || {
    echo 'FAIL: deploy left the first stale NOT-INSTALLED path on the target' >&2
    exit 1
}
[ ! -e "${tmp}/target/usr/lib/preserved-two.sh" ] || {
    echo 'FAIL: deploy left the second stale NOT-INSTALLED path on the target' >&2
    exit 1
}
[ -f "${tmp}/target/usr/lib/keep.sh" ] || {
    echo 'FAIL: deploy removed an unlisted target path' >&2
    exit 1
}

grep -Fq 'tests/test-overlay-coverage.sh' "${root}/.github/workflows/hermetic-tests.yml" || {
    echo 'FAIL: hermetic CI does not run the overlay coverage check' >&2
    exit 1
}
"${checker}" --repo "${root}" >"${tmp}/repository.out"
grep -Fq 'OVERLAY_COVERAGE PASS ' "${tmp}/repository.out" || {
    echo 'FAIL: repository overlay did not report complete coverage' >&2
    cat "${tmp}/repository.out" >&2
    exit 1
}

echo 'PASS: overlay coverage rejects orphan/dangling fixtures and deploy excludes/removes NOT-INSTALLED'
