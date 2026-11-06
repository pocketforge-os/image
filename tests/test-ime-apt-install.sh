#!/usr/bin/env bash
# Hermetic proof of the IME harness image's apt policy (bd tsp-hqm1p.143, CVE-2026-109518).
#
# tests/ime-bus-security/Containerfile used to read http://snapshot.debian.org straight from
# the internet with apt 2.6.1 and Acquire::Retries "5": the CVE's own condition, over a plain
# http internet leg, with `-qq` and no timeout. On a pf-public-ci runner (the NAS cache is
# fenced off: 10.0.0.0/8 is a pf-public deny CIDR) a stalled snapshot answer then held the RUN
# silent until the 30-minute job timeout (run 42189186714).
#
# The apt step is now tests/ime-bus-security/install-tools.sh. This test needs no docker, no
# network and no root: it runs that script against a stub apt-get (modelled on apt 2.6.1: a
# failed index fetch exits 0 unless --error-on=any) and the real `timeout`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
container_dir="${root}/tests/ime-bus-security"
script="${container_dir}/install-tools.sh"
containerfile="${container_dir}/Containerfile"
wrapper="${root}/tests/test-ime-bus-security.sh"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ime-apt-install.XXXXXX")"
trap 'find "${scratch}" -mindepth 1 -delete; rmdir "${scratch}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "${script}" ] || fail "tests/ime-bus-security/install-tools.sh is missing: the apt step is not testable"

# ---- stubs ------------------------------------------------------------------------------
stub_bin="${scratch}/bin"
mkdir -p "${stub_bin}"
cat >"${stub_bin}/apt-get" <<'STUB'
#!/bin/sh
# Stand-in for apt 2.6.1. PF_FAKE_UPDATE: ok | fail (fetch error) | stall | flaky (fails once).
# PF_FAKE_INSTALL: ok | fail | flaky (a pool object 503s twice, as libdbus-1-3 did in CI).
cmd=''; error_on=0
for a in "$@"; do
    case "$a" in
        update|install|clean) cmd=$a ;;
        --error-on=any) error_on=1 ;;
    esac
done
printf '%s|%s\n' "$cmd" "$*" >>"$PF_FAKE_LOG"
case "$cmd" in
    update)
        mode=${PF_FAKE_UPDATE:-ok}
        if [ "$mode" = flaky ]; then
            n=$(cat "$PF_FAKE_LOG.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$PF_FAKE_LOG.n"
            if [ "$n" -le 1 ]; then mode=fail; else mode=ok; fi
        fi
        case "$mode" in
            stall) sleep 30 ;;
            fail)
                echo "E: Failed to fetch https://snapshot.debian.org/ 503  No healthy backends" >&2
                [ "$error_on" = 1 ] || exit 0   # apt 2.6.1: a failed fetch is only a warning
                exit 100 ;;
        esac ;;
    install)
        mode=${PF_FAKE_INSTALL:-ok}
        if [ "$mode" = flaky ]; then
            n=$(cat "$PF_FAKE_LOG.i" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$PF_FAKE_LOG.i"
            if [ "$n" -le 2 ]; then mode=fail; else mode=ok; fi
        fi
        if [ "$mode" = fail ]; then
            echo "E: Failed to fetch https://snapshot.debian.org/archive/debian/x/pool/main/d/dbus/libdbus-1-3.deb  504  Gateway Timeout" >&2
            exit 100
        fi ;;
esac
exit 0
STUB
chmod 0755 "${stub_bin}/apt-get"

run_script() {
    # run_script NAME SCRIPT [ENV=VALUE...] -> sets rc, log, out; the fake root is per run.
    local name=$1 candidate=$2
    shift 2
    run_root="${scratch}/${name}"
    mkdir -p "${run_root}/etc/apt/sources.list.d" "${run_root}/etc/apt/apt.conf.d"
    : >"${run_root}/etc/apt/sources.list.d/debian.sources"
    log="${run_root}.log"
    out="${run_root}.out"
    : >"${log}"
    rc=0
    env PATH="${stub_bin}:${PATH}" PF_FAKE_LOG="${log}" PF_IME_ROOT="${run_root}" \
        PF_IME_APT_BACKOFF=0 PF_IME_APT_ATTEMPTS=3 \
        PF_IME_APT_UPDATE_TIMEOUT=60 PF_IME_APT_INSTALL_TIMEOUT=60 "$@" \
        sh "${candidate}" 20260601T000000Z >"${out}" 2>&1 || rc=$?
}
calls() { cut -d'|' -f1 "${log}" | tr '\n' ' ' | sed 's/ $//'; }

# ---- 1. green path: https only, no apt retries, update fails closed ----------------------
run_script green "${script}"
[ "${rc}" -eq 0 ] || { cat "${out}" >&2; fail "green run exited ${rc}"; }
[ "$(calls)" = "update install clean" ] || fail "green run apt sequence: $(calls)"
grep -q '^update|.*--error-on=any' "${log}" || fail "apt-get update must run with --error-on=any"
while IFS='|' read -r cmd args; do
    case "${cmd}" in
        update|install) ;;
        *) continue ;;
    esac
    case " ${args} " in
        *" -o Acquire::Retries=0 "*) ;;
        *) fail "apt-get ${cmd} runs without -o Acquire::Retries=0 (the CVE needs Retries > 0): ${args}" ;;
    esac
done <"${log}"
sources="${run_root}/etc/apt/sources.list"
[ "$(wc -l <"${sources}")" -eq 3 ] || fail "expected 3 snapshot source lines: $(cat "${sources}")"
grep -q backports "${sources}" && fail "bookworm-backports is not installed from; its snapshot index only adds a way to fail"
if grep -v '^deb \[check-valid-until=no\] https://snapshot\.debian\.org/archive/debian\(-security\)\?/20260601T000000Z/ bookworm' "${sources}"; then
    fail "every source must be https://snapshot.debian.org at the frozen date"
fi
grep -q 'http://' "${sources}" && fail "a plain-http source line was written"
[ ! -e "${run_root}/etc/apt/sources.list.d/debian.sources" ] || fail "the base's http debian.sources was left in place"
conf="${run_root}/etc/apt/apt.conf.d/99-pocketforge-snapshot"
grep -q 'Acquire::Retries "0";' "${conf}" || fail "persisted apt config must keep Retries at 0"
grep -Eq 'Acquire::Retries "[1-9]' "${conf}" && fail "persisted apt config re-enables Retries"
echo "ok 1 - https snapshot sources, Retries 0 on every apt call, update --error-on=any"

# ---- 2. a failed index fetch stops the step with a reason; it never installs --------------
run_script failing "${script}" PF_FAKE_UPDATE=fail
[ "${rc}" -ne 0 ] || fail "a failed index fetch must fail the step"
grep -q '^install|' "${log}" && fail "install ran after a failed index fetch"
[ "$(grep -c '^update|' "${log}")" -eq 3 ] || fail "expected 3 bounded attempts, got: $(calls)"
grep -q 'ime_apt=FAIL' "${out}" && grep -q 'reason=' "${out}" || { cat "${out}" >&2; fail "failure must name the step and a reason"; }
echo "ok 2 - a failed fetch fails closed after the bounded attempts, with a reason, no install"

# ---- 3. a stalled apt is cut by the step timeout instead of holding the RUN ---------------
started=$(date +%s)
run_script stalled "${script}" PF_FAKE_UPDATE=stall PF_IME_APT_UPDATE_TIMEOUT=1 PF_IME_APT_ATTEMPTS=2
elapsed=$(( $(date +%s) - started ))
[ "${rc}" -ne 0 ] || fail "a stalled apt-get update must fail the step"
[ "${elapsed}" -lt 20 ] || fail "a stalled apt-get update was not cut by its timeout (${elapsed}s)"
grep -q 'rc=124' "${out}" && grep -q 'timed out after 1s' "${out}" || { cat "${out}" >&2; fail "a timeout must be reported as one"; }
echo "ok 3 - a stalled apt-get is cut at its step timeout and reported (${elapsed}s)"

# ---- 4. a transient snapshot failure is ridden out by a fresh apt, not apt's own Retries --
run_script flaky "${script}" PF_FAKE_UPDATE=flaky
[ "${rc}" -eq 0 ] || { cat "${out}" >&2; fail "one transient failure must not fail the step"; }
[ "$(calls)" = "update update install clean" ] || fail "flaky run apt sequence: $(calls)"
echo "ok 4 - a transient failure is retried by re-running apt with Retries 0"

# ---- 4b. a flaky pool object is ridden out without refetching the indexes -----------------
run_script flaky_install "${script}" PF_FAKE_INSTALL=flaky
[ "${rc}" -eq 0 ] || { cat "${out}" >&2; fail "two failed installs inside the budget must not fail the step"; }
[ "$(calls)" = "update install install install clean" ] || fail "flaky install apt sequence: $(calls)"
grep -c 'ime_apt=FAIL step=install' "${out}" | grep -qx 2 || { cat "${out}" >&2; fail "each failed install must be reported"; }
grep -q 'ime_apt=PASS' "${out}" || fail "a recovered run must say PASS"
echo "ok 4b - a flaky pool object is retried; the indexes are fetched once"

# ---- 4c. the retries are bounded by a time budget and say so ------------------------------
started=$(date +%s)
run_script budget "${script}" PF_FAKE_INSTALL=fail PF_IME_APT_ATTEMPTS=1000 PF_IME_APT_BACKOFF=1 PF_IME_APT_BUDGET=4
elapsed=$(( $(date +%s) - started ))
[ "${rc}" -ne 0 ] || fail "a permanently failing install must fail the step"
[ "${elapsed}" -lt 15 ] || fail "the retry budget did not bound the step (${elapsed}s)"
grep -q 'ime_apt=FAIL reason=budget_exhausted budget=4s' "${out}" || { cat "${out}" >&2; fail "budget exhaustion must be named"; }
[ "$(grep -c '^update|' "${log}")" -eq 1 ] || fail "the indexes must be fetched once, got: $(calls)"
echo "ok 4c - retries stop at the time budget with a named reason (${elapsed}s)"

# ---- 5. red control: without --error-on=any the failed fetch runs on into the install -----
sed 's/ --error-on=any//' "${script}" >"${scratch}/install-tools-no-error-on.sh"
cmp -s "${script}" "${scratch}/install-tools-no-error-on.sh" && fail "negative control did not change the script"
run_script mutant "${scratch}/install-tools-no-error-on.sh" PF_FAKE_UPDATE=fail
grep -q '^install|' "${log}" || fail "negative control: dropping --error-on=any must let the install run, or step 2 proves nothing"
echo "ok 5 - red control: the stub apt exits 0 on a failed fetch unless --error-on=any is passed"

# ---- 6. the Containerfile: https only, public CA store, bounded script step ---------------
code="$(grep -v '^[[:space:]]*#' "${containerfile}")"
case "${code}" in *"http://"*) fail "Containerfile names a plain-http endpoint" ;; esac
case "${code}" in *"Retries"*) fail "Containerfile sets apt Retries; install-tools.sh owns the apt policy" ;; esac
grep -Eq '^FROM docker\.io/library/alpine:[0-9.]+@sha256:[0-9a-f]{64} AS pf-ca-bundle$' "${containerfile}" \
    || fail "the public CA store must come from a digest-pinned image stage"
grep -Fq 'COPY --from=pf-ca-bundle /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt' "${containerfile}" \
    || fail "the CA store is not copied into the harness image before the first apt run"
grep -Fq 'COPY install-tools.sh ' "${containerfile}" || fail "Containerfile does not ship install-tools.sh"
case "${code}" in *"apt-get"*) fail "Containerfile still runs apt-get itself" ;; esac
if grep -Eq 'apt-get[^|]* -qq|apt-get[^|]* -q ' "${script}"; then fail "-q/-qq hides what a stalled apt was doing"; fi
grep -Fq 'http://' "${script}" && fail "install-tools.sh names a plain-http endpoint"
echo "ok 6 - Containerfile: https only, digest-pinned CA store, no apt of its own"

# ---- 7. the wrapper bounds the whole image build and says why it stopped ------------------
cat >"${stub_bin}/docker" <<'STUB'
#!/bin/sh
case "$1" in
    build) sleep 30 ;;
    container) exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod 0755 "${stub_bin}/docker"
# The wrapper refuses uid/gid below 1000; pin an acceptable identity so the proof does not
# depend on who runs it.
cat >"${stub_bin}/id" <<'STUB'
#!/bin/sh
echo 1001
STUB
chmod 0755 "${stub_bin}/id"
mkdir -p "${scratch}/wrapper-tmp"
started=$(date +%s)
rc=0
env PATH="${stub_bin}:${PATH}" RUNNER_TEMP="${scratch}/wrapper-tmp" PF_IME_BUILD_TIMEOUT=2 \
    bash "${wrapper}" >"${scratch}/wrapper.out" 2>&1 || rc=$?
elapsed=$(( $(date +%s) - started ))
[ "${rc}" -ne 0 ] || fail "a stalled image build must fail the wrapper"
[ "${elapsed}" -lt 25 ] || fail "the wrapper did not bound the image build (${elapsed}s)"
grep -q 'IME harness image build exceeded 2s' "${scratch}/wrapper.out" \
    || { cat "${scratch}/wrapper.out" >&2; fail "the wrapper must report that the image build timed out"; }
echo "ok 7 - a stalled image build fails the wrapper at its bound with a reason (${elapsed}s)"

echo 'PASS: IME harness apt policy is https-only, Retries 0, fail-closed and time-bounded'
