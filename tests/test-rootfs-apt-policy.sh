#!/usr/bin/env bash
# Release-rootfs apt policy (bd tsp-mc9m.41.1002.5).
#
# Build-6 shipped the build-transport apt proxy into the release rootfs:
# mmdebstrap 1.5.5 permanently writes every --aptopt into
# etc/apt/apt.conf.d/99mmdebstrap (its cleanup unlinks only 00mmdebstrap and
# 99debconf), so `--aptopt='Acquire::http::Proxy "http://10.0.32.86:3142"'`
# from PF_APT_PROXY survived into /etc/apt on the device. First-boot
# cloud-config then talked to the unreachable private endpoint and failed.
#
# Contract under test:
#   * scripts/verify-rootfs-apt-policy.sh fails closed on any persisted
#     Acquire::*::Proxy directive or private build endpoint (10.x / 192.168.x /
#     the apt-cacher-ng host:port) under etc/apt of the assembled rootfs.
#   * scripts/strip-rootfs-apt-proxy.sh removes the mmdebstrap-persisted proxy
#     directive wherever it lives under etc/apt, keeps the sibling build
#     hardening options (Check-Valid-Until, Retries, Sandbox::User) and the
#     pinned snapshot.debian.org source, and is a byte-identical no-op on a
#     clean (direct, PF_APT_PROXY unset) rootfs.
#   * Both rootfs builders run strip-then-verify on the extracted tree before
#     mke2fs, so no ext4 can be assembled with the proxy persisted.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
strip="${repo_dir}/scripts/strip-rootfs-apt-proxy.sh"
verify="${repo_dir}/scripts/verify-rootfs-apt-policy.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "${strip}" ] || fail "missing ${strip} (base commit has no proxy-strip step)"
[ -f "${verify}" ] || fail "missing ${verify} (base commit has no apt policy gate)"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-rootfs-apt-policy.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

# Fixture: exactly what mmdebstrap 1.5.5 persists for build-rootfs.sh's
# --aptopt set when PF_APT_PROXY=http://10.0.32.86:3142 (build-6 witness:
# /home/matt/recovery/tsp-mc9m.41.1002.4/, raw partition 5
# /etc/apt/apt.conf.d/99mmdebstrap).
make_proxy_rootfs() {
    local dir="$1"
    mkdir -p "${dir}/etc/apt/apt.conf.d" "${dir}/etc/apt/sources.list.d"
    cat > "${dir}/etc/apt/apt.conf.d/99mmdebstrap" <<'EOF'
Acquire::Check-Valid-Until "false";
APT::Sandbox::User "root";
Acquire::Retries "5";
Acquire::http::Proxy "http://10.0.32.86:3142";
EOF
    echo 'deb http://snapshot.debian.org/archive/debian/20260601T000000Z/ bookworm main' \
        > "${dir}/etc/apt/sources.list"
}

# ---------------------------------------------------------------------------
# Negative control 1: the gate must REJECT the build-6 persisted shape as-is.
# ---------------------------------------------------------------------------
rootfs="${scratch}/rootfs-proxy"
make_proxy_rootfs "${rootfs}"
if "${verify}" "${rootfs}" >"${scratch}/n1.out" 2>"${scratch}/n1.err"; then
    fail "verify-rootfs-apt-policy accepted the build-6 persisted proxy config"
fi
for needle in '99mmdebstrap' 'Proxy' '10.0.32.86:3142'; do
    grep -Fq "${needle}" "${scratch}/n1.err" \
        || fail "gate stderr does not name ${needle} (got: $(cat "${scratch}/n1.err"))"
done

# ---------------------------------------------------------------------------
# Positive control: strip removes the persisted proxy and the gate then passes;
# the sibling aptopts and the pinned snapshot source are untouched.
# ---------------------------------------------------------------------------
"${strip}" "${rootfs}"
"${verify}" "${rootfs}" >"${scratch}/p1.out" 2>"${scratch}/p1.err" \
    || fail "strip+verify rejected its own cleaned rootfs: $(cat "${scratch}/p1.err")"
conf="${rootfs}/etc/apt/apt.conf.d/99mmdebstrap"
if grep -qi 'proxy' "${conf}"; then
    fail "strip left a proxy directive in 99mmdebstrap: $(cat "${conf}")"
fi
for keep in 'Acquire::Check-Valid-Until "false";' 'APT::Sandbox::User "root";' 'Acquire::Retries "5";'; do
    grep -Fxq "${keep}" "${conf}" \
        || fail "strip removed sibling build-hardening aptopt: ${keep}"
done
grep -Fxq 'deb http://snapshot.debian.org/archive/debian/20260601T000000Z/ bookworm main' \
    "${rootfs}/etc/apt/sources.list" \
    || fail "strip altered the pinned snapshot.debian.org source"

# Idempotence: a second strip is a byte-identical no-op.
before="$(sha256sum "${conf}" | cut -d' ' -f1)"
"${strip}" "${rootfs}"
after="$(sha256sum "${conf}" | cut -d' ' -f1)"
[ "${before}" = "${after}" ] || fail "second strip mutated 99mmdebstrap"

# ---------------------------------------------------------------------------
# Negative control 2: the gate is not hardcoded to 99mmdebstrap. Proxy
# directives in another etc/apt file — including the per-host Proxy::<host>
# form — must also be rejected and stripped.
# ---------------------------------------------------------------------------
rootfs2="${scratch}/rootfs-elsewhere"
make_proxy_rootfs "${rootfs2}"
find "${rootfs2}/etc/apt" -name 99mmdebstrap -delete
cat > "${rootfs2}/etc/apt/apt.conf" <<'EOF'
Acquire::https::Proxy "http://192.168.7.1:3142";
Acquire::http::Proxy::10.0.32.86 "DIRECT";
EOF
if "${verify}" "${rootfs2}" >"${scratch}/n2.out" 2>"${scratch}/n2.err"; then
    fail "gate accepted Acquire::https::Proxy in etc/apt/apt.conf"
fi
grep -Fq 'etc/apt/apt.conf' "${scratch}/n2.err" \
    || fail "gate stderr does not name the offending file for apt.conf proxy"
"${strip}" "${rootfs2}"
"${verify}" "${rootfs2}" >"${scratch}/p2.out" 2>"${scratch}/p2.err" \
    || fail "strip did not remove the apt.conf proxy directive: $(cat "${scratch}/p2.err")"

# ---------------------------------------------------------------------------
# Negative control 3: a private build endpoint WITHOUT a proxy directive (e.g.
# a sources.list.d drop-in pointing at the build cache) must fail the gate, and
# strip must NOT launder it — the endpoint policy is independent.
# ---------------------------------------------------------------------------
rootfs3="${scratch}/rootfs-endpoint"
make_proxy_rootfs "${rootfs3}"
find "${rootfs3}/etc/apt" -name 99mmdebstrap -delete
echo 'deb http://10.0.32.86:3142/debian bookworm main' \
    > "${rootfs3}/etc/apt/sources.list.d/build-cache.list"
"${strip}" "${rootfs3}"
if "${verify}" "${rootfs3}" >"${scratch}/n3.out" 2>"${scratch}/n3.err"; then
    fail "gate accepted a private build endpoint in sources.list.d after strip"
fi
grep -Fq 'build-cache.list' "${scratch}/n3.err" \
    || fail "gate stderr does not name build-cache.list for the private endpoint"

# ---------------------------------------------------------------------------
# Negative control 4: unquoted value forms. apt accepts values without double
# quotes, so gate and strip must match independent of quoting (review
# r4374217256): plain DIRECT/false values, a block-body Proxy without quotes,
# the per-host Proxy::<host> form with an unquoted value, and the
# Proxy-Auto-Detect key.
# ---------------------------------------------------------------------------
rootfs5="${scratch}/rootfs-unquoted"
make_proxy_rootfs "${rootfs5}"
find "${rootfs5}/etc/apt" -name 99mmdebstrap -delete
cat > "${rootfs5}/etc/apt/apt.conf.d/10transport" <<'EOF'
Acquire::http::Proxy DIRECT;
Acquire::ftp::Proxy false;
Acquire::http::Proxy::example.com DIRECT;
Acquire::http::Proxy-Auto-Detect /usr/bin/foo;
Acquire::https {
    Proxy false;
    Timeout "30";
};
EOF
if "${verify}" "${rootfs5}" >"${scratch}/n4.out" 2>"${scratch}/n4.err"; then
    fail "gate accepted unquoted-value proxy directives"
fi
for needle in 'Acquire::http::Proxy DIRECT;' 'Acquire::ftp::Proxy false;' \
              'Proxy::example.com DIRECT;' 'Proxy-Auto-Detect /usr/bin/foo;' \
              'Proxy false;'; do
    grep -Fq "${needle}" "${scratch}/n4.err" \
        || fail "gate stderr does not name ${needle} (got: $(cat "${scratch}/n4.err"))"
done
"${strip}" "${rootfs5}"
"${verify}" "${rootfs5}" >"${scratch}/p4.out" 2>"${scratch}/p4.err" \
    || fail "strip did not remove the unquoted proxy directives: $(cat "${scratch}/p4.err")"
transport="${rootfs5}/etc/apt/apt.conf.d/10transport"
if grep -qi 'proxy' "${transport}"; then
    fail "strip left proxy content in 10transport: $(cat "${transport}")"
fi
grep -Fxq '    Timeout "30";' "${transport}" \
    || fail "strip removed the sibling block-body Timeout option"

# ---------------------------------------------------------------------------
# Negative control 5: block and multiline forms (review r4374286544). apt
# accepts a closing brace as the statement terminator ('{ Proxy DIRECT }'),
# values terminated by '}' on a following line, and key/value splits across
# lines — all confirmed with apt-config dump. The gate must reject every
# variant and the strip must excise it while keeping non-proxy siblings and
# balanced braces.
# ---------------------------------------------------------------------------
rootfs6="${scratch}/rootfs-blockforms"
make_proxy_rootfs "${rootfs6}"
find "${rootfs6}/etc/apt" -name 99mmdebstrap -delete
cat > "${rootfs6}/etc/apt/apt.conf.d/20blocks" <<'EOF'
Acquire::http { Proxy DIRECT }
Acquire::https {
    Proxy "http://cache.example.invalid:3142"
};
Acquire::file::Proxy
    "DIRECT";
Acquire::ftp {
    Proxy::example.com DIRECT
};
Acquire::cdrom {
    Proxy-Auto-Detect /usr/bin/foo
};
Acquire::gpgv {
    Timeout "30";
};
EOF
if "${verify}" "${rootfs6}" >"${scratch}/n5.out" 2>"${scratch}/n5.err"; then
    fail "gate accepted block/multiline proxy directive forms"
fi
for needle in '{ Proxy DIRECT }' 'Proxy "http://cache.example.invalid:3142"' \
              'Acquire::file::Proxy' 'Proxy::example.com DIRECT' \
              'Proxy-Auto-Detect /usr/bin/foo'; do
    grep -Fq "${needle}" "${scratch}/n5.err" \
        || fail "gate stderr does not name ${needle} (got: $(cat "${scratch}/n5.err"))"
done
"${strip}" "${rootfs6}"
"${verify}" "${rootfs6}" >"${scratch}/p5.out" 2>"${scratch}/p5.err" \
    || fail "strip did not remove the block/multiline proxy directives: $(cat "${scratch}/p5.err")"
blocks="${rootfs6}/etc/apt/apt.conf.d/20blocks"
if grep -qi 'proxy' "${blocks}"; then
    fail "strip left proxy content in 20blocks: $(cat "${blocks}")"
fi
grep -Fxq 'Acquire::http { }' "${blocks}" \
    || fail "single-line block lost its braces: $(cat "${blocks}")"
grep -Fxq '    Timeout "30";' "${blocks}" \
    || fail "strip removed the sibling Timeout option in 20blocks"
grep -Fxq 'Acquire::gpgv {' "${blocks}" \
    || fail "strip removed the unrelated non-proxy block"
[ "$(grep -c '{' "${blocks}")" -eq "$(grep -c '}' "${blocks}")" ] \
    || fail "strip unbalanced the braces in 20blocks: $(cat "${blocks}")"
before6="$(cd "${rootfs6}" && find etc -type f -exec sha256sum {} + | sha256sum)"
"${strip}" "${rootfs6}"
after6="$(cd "${rootfs6}" && find etc -type f -exec sha256sum {} + | sha256sum)"
[ "${before6}" = "${after6}" ] || fail "second strip is not a byte-identical no-op"

# ---------------------------------------------------------------------------
# Negative control 6: invalid-but-tolerated forms. Two consecutive unterminated
# proxy statements in one block are rejected by apt itself ('Extra junk after
# value'), and an unterminated 'Proxy false' directly followed by a sibling
# must not eat that sibling: the strip excises both proxy lines and keeps
# 'Timeout "30";' and the braces (over-deletion protection).
# ---------------------------------------------------------------------------
rootfs7="${scratch}/rootfs-invalid-forms"
make_proxy_rootfs "${rootfs7}"
find "${rootfs7}/etc/apt" -name 99mmdebstrap -delete
cat > "${rootfs7}/etc/apt/apt.conf.d/30invalid" <<'EOF'
Acquire::ftp {
    Proxy::example.com DIRECT
    Proxy-Auto-Detect /usr/bin/foo
};
Acquire::https {
    Proxy false
    Timeout "30";
};
EOF
if "${verify}" "${rootfs7}" >"${scratch}/n6.out" 2>"${scratch}/n6.err"; then
    fail "gate accepted invalid-form proxy directives"
fi
for needle in 'Proxy::example.com DIRECT' 'Proxy-Auto-Detect /usr/bin/foo' \
              'Proxy false'; do
    grep -Fq "${needle}" "${scratch}/n6.err" \
        || fail "gate stderr does not name ${needle} (got: $(cat "${scratch}/n6.err"))"
done
"${strip}" "${rootfs7}"
"${verify}" "${rootfs7}" >"${scratch}/p6.out" 2>"${scratch}/p6.err" \
    || fail "strip did not remove the invalid-form proxy directives: $(cat "${scratch}/p6.err")"
invalid="${rootfs7}/etc/apt/apt.conf.d/30invalid"
if grep -qi 'proxy' "${invalid}"; then
    fail "strip left proxy content in 30invalid: $(cat "${invalid}")"
fi
grep -Fxq '    Timeout "30";' "${invalid}" \
    || fail "strip over-deleted the sibling after an unterminated proxy line"
grep -Fxq 'Acquire::ftp {' "${invalid}" \
    || fail "strip removed the enclosing ftp block opener"
[ "$(grep -c '};' "${invalid}")" -eq 2 ] \
    || fail "strip unbalanced the block closers in 30invalid: $(cat "${invalid}")"

# ---------------------------------------------------------------------------
# Positive control 2: a clean rootfs (direct build, PF_APT_PROXY unset) passes
# the gate untouched, and strip is a byte-identical no-op on it.
# ---------------------------------------------------------------------------
rootfs4="${scratch}/rootfs-clean"
make_proxy_rootfs "${rootfs4}"
find "${rootfs4}/etc/apt" -name 99mmdebstrap -delete
cat > "${rootfs4}/etc/apt/apt.conf.d/99mmdebstrap" <<'EOF'
Acquire::Check-Valid-Until "false";
APT::Sandbox::User "root";
Acquire::Retries "5";
EOF
clean_before="$(find "${rootfs4}/etc/apt" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
"${verify}" "${rootfs4}" || fail "gate rejected a clean direct-build rootfs"
"${strip}" "${rootfs4}"
clean_after="$(find "${rootfs4}/etc/apt" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
[ "${clean_before}" = "${clean_after}" ] || fail "strip mutated a clean rootfs"

# ---------------------------------------------------------------------------
# Wiring: both rootfs builders must run strip-then-verify on the tree that
# actually gets assembled, before mke2fs.
# ---------------------------------------------------------------------------
first_line_no() {
    # Prints the first matching line number, or nothing; never aborts set -e.
    local pattern="$1" file="$2" ln=""
    if ! ln="$(grep -n "${pattern}" "${file}" | head -1 | cut -d: -f1)"; then
        ln=""
    fi
    printf '%s' "${ln}"
}
assert_wired() {
    local builder="$1" target="$2" strip_ln verify_ln mke2fs_ln
    strip_ln="$(first_line_no "strip-rootfs-apt-proxy.sh\" \"\${${target}}\"" "${builder}")"
    [ -n "${strip_ln}" ] \
        || fail "${builder} does not strip the apt proxy on \${${target}} before assembly"
    verify_ln="$(first_line_no "verify-rootfs-apt-policy.sh\" \"\${${target}}\"" "${builder}")"
    [ -n "${verify_ln}" ] \
        || fail "${builder} does not run the release apt policy gate on \${${target}}"
    [ "${strip_ln}" -lt "${verify_ln}" ] \
        || fail "${builder}: strip must run before the verify gate"
    mke2fs_ln="$(first_line_no '^mke2fs' "${builder}")"
    [ -n "${mke2fs_ln}" ] || fail "${builder}: no mke2fs invocation found"
    [ "${verify_ln}" -lt "${mke2fs_ln}" ] \
        || fail "${builder}: apt policy gate runs after ext4 assembly"
}
assert_wired "${repo_dir}/scripts/build-rootfs.sh" 'ROOTFS_EXTRACTED'
assert_wired "${repo_dir}/scripts/build-rootfs-a523.sh" 'EXT'

echo "rootfs-apt-policy=PASS positive=strip-then-verify-clean-proxied-and-direct-rootfs,block-sibling-timeout-kept,braces-balanced,second-strip-noop negative=persisted-99mmdebstrap-proxy,apt.conf-proxy,bare-private-endpoint,unquoted-proxy-values,block-brace-terminator,split-key-value,invalid-consecutive-forms"
