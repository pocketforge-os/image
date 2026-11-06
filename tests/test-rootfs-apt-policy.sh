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
#   * scripts/verify-rootfs-apt-policy.sh parses the rootfs apt config with
#     apt's OWN parser (apt-config dump pointed at the rootfs tree) and fails
#     closed on any effective Acquire::*Proxy* key — quoting and layout forms
#     a line matcher cannot enumerate must not slip through (review
#     r4374477053) — plus on any private build endpoint (10.x / 192.168.x /
#     the apt-cacher-ng host:port) under etc/apt as text.
#   * The dump reads the rootfs etc/apt/apt.conf and apt.conf.d/* parts and
#     never the host's /etc/apt (sentinel + host-key isolation proof below).
#   * scripts/strip-rootfs-apt-proxy.sh removes exactly the builder-written
#     persisted line(s) from the known mmdebstrap drop-in, keeps the sibling
#     build hardening options (Check-Valid-Until, Retries, Sandbox::User) and
#     the pinned snapshot.debian.org source, and is a byte-identical no-op and
#     idempotent on a clean (direct, PF_APT_PROXY unset) rootfs. Proxy config
#     the builder did not write is NOT laundered: the gate must still reject
#     it so the build fails closed naming the offending file.
#   * Both rootfs builders run strip-then-verify on the extracted tree before
#     mke2fs, so no ext4 can be assembled with the proxy persisted.
#   * CVE-2026-109518 (bd tsp-hqm1p.143): the gate also rejects any plain-http
#     apt source and any installed apt below its line's fix (a dpkg database
#     carrying the snapshot's apt 2.6.1, a stale libapt-pkg, or none at all).
#     scripts/rewrite-rootfs-apt-sources-https.sh turns the cache-mode
#     http://snapshot.debian.org/ source into the https one a direct build
#     persists, is idempotent, and launders no other plain-http source; both
#     builders run it before strip-then-verify.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
strip="${repo_dir}/scripts/strip-rootfs-apt-proxy.sh"
verify="${repo_dir}/scripts/verify-rootfs-apt-policy.sh"
rewrite="${repo_dir}/scripts/rewrite-rootfs-apt-sources-https.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "${strip}" ] || fail "missing ${strip} (base commit has no proxy-strip step)"
[ -f "${verify}" ] || fail "missing ${verify} (base commit has no apt policy gate)"
[ -x "${rewrite}" ] || fail "missing ${rewrite} (base commit has no https source rewrite)"
command -v apt-config >/dev/null 2>&1 \
    || fail "this test requires apt-config (apt) on the host"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-rootfs-apt-policy.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

# The exact line mmdebstrap 1.5.5 persists for build-rootfs.sh's
# --aptopt='Acquire::http::Proxy "http://10.0.32.86:3142"' (it appends the
# trailing ';' when missing). Build-6 witness:
# /home/matt/recovery/tsp-mc9m.41.1002.4/, raw partition 5
# /etc/apt/apt.conf.d/99mmdebstrap.
PERSISTED_LINE='Acquire::http::Proxy "http://10.0.32.86:3142";'

make_proxy_rootfs() {
    local dir="$1"
    mkdir -p "${dir}/etc/apt/apt.conf.d" "${dir}/etc/apt/sources.list.d"
    cat > "${dir}/etc/apt/apt.conf.d/99mmdebstrap" <<'EOF'
Acquire::Check-Valid-Until "false";
APT::Sandbox::User "root";
Acquire::Retries "5";
Acquire::http::Proxy "http://10.0.32.86:3142";
EOF
    echo "${SNAPSHOT_SOURCE}" > "${dir}/etc/apt/sources.list"
    make_dpkg_db "${dir}" 2.6.2 2.6.2
}

SNAPSHOT_SOURCE='deb https://snapshot.debian.org/archive/debian/20260601T000000Z/ bookworm main'

# make_dpkg_db ROOTFS APT_VERSION LIBAPT_VERSION -- an arm64 rootfs dpkg
# database, as mmdebstrap leaves it, carrying just apt and its library.
make_dpkg_db() {
    local dir="$1"
    mkdir -p "${dir}/var/lib/dpkg/info" "${dir}/var/lib/dpkg/updates"
    printf 'Package: %s\nStatus: install ok installed\nArchitecture: arm64\nVersion: %s\n\n' \
        apt "$2" libapt-pkg6.0 "$3" > "${dir}/var/lib/dpkg/status"
}

# Same mechanism the gate uses: point apt-config's Dir at a tree so it reads
# only that tree's etc/apt config. apt_dump <rootfs> <out> <err>; returns rc.
apt_dump() {
    local rootfs="$1"
    local cfg="${scratch}/aptcfg.$(basename "${rootfs}")"
    local rc=0
    printf 'Dir "%s";\n' "${rootfs}" > "${cfg}"
    APT_CONFIG="${cfg}" apt-config dump >"$2" 2>"$3" || rc=$?
    return "${rc}"
}

# ---------------------------------------------------------------------------
# Isolation control: the rootfs-scoped dump must read the rootfs main file AND
# its apt.conf.d parts, and must NOT read the host's /etc/apt. Proof: sentinel
# keys in both fixture locations appear in the dump; every key the host config
# adds over a built-in-defaults baseline (empty-tree dump) is absent from the
# fixture dump.
# ---------------------------------------------------------------------------
rootfs0="${scratch}/rootfs-isolation"
mkdir -p "${rootfs0}/etc/apt/apt.conf.d"
echo 'PfPolicyTest::Sentinel::Main "main-read";' > "${rootfs0}/etc/apt/apt.conf"
echo 'PfPolicyTest::Sentinel::Part "part-read";' > "${rootfs0}/etc/apt/apt.conf.d/05sentinel"
empty0="${scratch}/rootfs-empty"
mkdir -p "${empty0}"
rc=0; apt_dump "${empty0}" "${scratch}/n0.base" "${scratch}/n0.base.err" || rc=$?
[ "${rc}" -eq 0 ] || fail "apt-config rejected an empty-tree Dir override (rc=${rc}): $(cat "${scratch}/n0.base.err")"
rc=0; apt_dump "${rootfs0}" "${scratch}/n0.fix" "${scratch}/n0.fix.err" || rc=$?
[ "${rc}" -eq 0 ] || fail "apt-config rejected the sentinel fixture (rc=${rc}): $(cat "${scratch}/n0.fix.err")"
grep -Fxq 'PfPolicyTest::Sentinel::Main "main-read";' "${scratch}/n0.fix" \
    || fail "rootfs-scoped dump did not read the rootfs etc/apt/apt.conf"
grep -Fxq 'PfPolicyTest::Sentinel::Part "part-read";' "${scratch}/n0.fix" \
    || fail "rootfs-scoped dump did not read the rootfs apt.conf.d parts"
rc=0; apt-config dump > "${scratch}/n0.host" 2>/dev/null || rc=$?
if [ "${rc}" -eq 0 ]; then
    rc=0
    host_only="$(grep -Fxv -f "${scratch}/n0.base" "${scratch}/n0.host")" || rc=$?
    case "${rc}" in
        0) ;;
        1) host_only="" ;;
        *) fail "grep failed diffing host apt config vs baseline (rc=${rc})" ;;
    esac
    if [ -n "${host_only}" ]; then
        rc=0
        overlap="$(grep -Fx -f <(printf '%s\n' "${host_only}") "${scratch}/n0.fix")" || rc=$?
        case "${rc}" in
            0) fail "rootfs-scoped dump leaked host /etc/apt keys: ${overlap}" ;;
            1) : ;;
            *) fail "grep failed the host-leak check (rc=${rc})" ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
# Negative control 1: the gate must REJECT the build-6 persisted shape as-is.
# ---------------------------------------------------------------------------
rootfs="${scratch}/rootfs-proxy"
make_proxy_rootfs "${rootfs}"
if "${verify}" "${rootfs}" >"${scratch}/n1.out" 2>"${scratch}/n1.err"; then
    fail "verify-rootfs-apt-policy accepted the build-6 persisted proxy config"
fi
for needle in 'Proxy' '10.0.32.86:3142' '99mmdebstrap'; do
    grep -Fq "${needle}" "${scratch}/n1.err" \
        || fail "gate stderr does not name ${needle} (got: $(cat "${scratch}/n1.err"))"
done

# ---------------------------------------------------------------------------
# Positive control 1: strip removes the builder-written persisted line and the
# gate then passes; the sibling aptopts and the pinned snapshot source are
# untouched; a second strip is a byte-identical no-op.
# ---------------------------------------------------------------------------
"${strip}" "${rootfs}" "${PERSISTED_LINE}"
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
grep -Fxq "${SNAPSHOT_SOURCE}" "${rootfs}/etc/apt/sources.list" \
    || fail "strip altered the pinned snapshot.debian.org source"
grep -Fq 'apt_cve_2026_109518=PASS version=2.6.2 min=2.6.2 reason=fixed' "${scratch}/p1.out" \
    || fail "gate does not report the CVE-2026-109518 apt PASS (got: $(cat "${scratch}/p1.out"))"
before="$(sha256sum "${conf}" | cut -d' ' -f1)"
"${strip}" "${rootfs}" "${PERSISTED_LINE}"
after="$(sha256sum "${conf}" | cut -d' ' -f1)"
[ "${before}" = "${after}" ] || fail "second strip mutated 99mmdebstrap"

# ---------------------------------------------------------------------------
# Negative control 2: the gate is not hardcoded to 99mmdebstrap. Proxy
# directives in another etc/apt file — including the per-host Proxy::<host>
# form — must be rejected, and strip must NOT launder files the builder did
# not write: after strip the gate must still reject (the real build fails
# closed here) with the file unchanged.
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
before2="$(sha256sum "${rootfs2}/etc/apt/apt.conf" | cut -d' ' -f1)"
"${strip}" "${rootfs2}"
after2="$(sha256sum "${rootfs2}/etc/apt/apt.conf" | cut -d' ' -f1)"
[ "${before2}" = "${after2}" ] || fail "strip laundered a file the builder did not write"
if "${verify}" "${rootfs2}" >"${scratch}/n2b.out" 2>"${scratch}/n2b.err"; then
    fail "gate accepted the apt.conf proxy after strip (must stay rejected)"
fi

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
# Negative control 4: unquoted value forms (review r4374217256). apt accepts
# values without double quotes; apt-config dump normalizes them, so the
# parser-backed gate must reject every variant, and strip must not launder
# the file.
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
for needle in 'Acquire::http::Proxy "DIRECT";' 'Acquire::ftp::Proxy "false";' \
              'Acquire::http::Proxy::example.com "DIRECT";' \
              'Acquire::http::Proxy-Auto-Detect "/usr/bin/foo";' \
              'Acquire::https::Proxy "false";'; do
    grep -Fq "${needle}" "${scratch}/n4.err" \
        || fail "gate stderr does not name ${needle} (got: $(cat "${scratch}/n4.err"))"
done
"${strip}" "${rootfs5}"
if "${verify}" "${rootfs5}" >"${scratch}/n4b.out" 2>"${scratch}/n4b.err"; then
    fail "gate accepted the unquoted forms after strip (must stay rejected)"
fi

# ---------------------------------------------------------------------------
# Negative control 5: block and multiline forms (review r4374286544). apt
# accepts a closing brace as the statement terminator ('{ Proxy DIRECT }'),
# values terminated by '}' on a following line, and key/value splits across
# lines — all confirmed with apt-config dump. The parser-backed gate must
# reject every effective key; strip must not launder the file.
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
for needle in 'Acquire::http::Proxy "DIRECT";' \
              'Acquire::https::Proxy "http://cache.example.invalid:3142";' \
              'Acquire::file::Proxy "DIRECT";' \
              'Acquire::ftp::Proxy::example.com "DIRECT";' \
              'Acquire::cdrom::Proxy-Auto-Detect "/usr/bin/foo";'; do
    grep -Fq "${needle}" "${scratch}/n5.err" \
        || fail "gate stderr does not name ${needle} (got: $(cat "${scratch}/n5.err"))"
done
"${strip}" "${rootfs6}"
if "${verify}" "${rootfs6}" >"${scratch}/n5b.out" 2>"${scratch}/n5b.err"; then
    fail "gate accepted the block forms after strip (must stay rejected)"
fi

# ---------------------------------------------------------------------------
# Negative control 6: syntactically invalid config (two consecutive
# unterminated statements) makes apt-config itself fail; the gate must fail
# closed on the non-zero exit and surface apt's error, which names the file.
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
    fail "gate accepted a rootfs whose apt config apt-config cannot parse"
fi
for needle in 'apt-config' 'Extra junk' '30invalid'; do
    grep -Fq "${needle}" "${scratch}/n6.err" \
        || fail "gate stderr does not name ${needle} for the parse failure (got: $(cat "${scratch}/n6.err"))"
done

# ---------------------------------------------------------------------------
# Negative control 7: quoted key components (review r4374477053). apt-config
# accepts quotes around ANY config-key component and normalizes them in the
# dump, so a matcher keyed on the literal token 'Proxy' after a boundary
# misses every one of these. Each variant below was confirmed to parse and
# dump as an Acquire::*Proxy* key (host apt 2.8.3, container apt 2.6.1).
# ---------------------------------------------------------------------------
rootfs8="${scratch}/rootfs-quoted-keys"
make_proxy_rootfs "${rootfs8}"
find "${rootfs8}/etc/apt" -name 99mmdebstrap -delete
cat > "${rootfs8}/etc/apt/apt.conf.d/40quoted" <<'EOF'
Acquire::"http"::Proxy "QV1";
Acquire::https::"Proxy" "QV2";
"Acquire"::ftp::Proxy "QV3";
Acquire::file { "Proxy" false; }
Acquire::cdrom::"Proxy-Auto-Detect" "/usr/bin/qfoo";
Acquire::rsh::"Proxy::example.com" "DIRECT";
EOF
if "${verify}" "${rootfs8}" >"${scratch}/n7.out" 2>"${scratch}/n7.err"; then
    fail "gate accepted quoted-key-component proxy directives"
fi
for needle in 'Acquire::http::Proxy "QV1";' 'Acquire::https::Proxy "QV2";' \
              'Acquire::ftp::Proxy "QV3";' 'Acquire::file::Proxy "false";' \
              'Acquire::cdrom::Proxy-Auto-Detect "/usr/bin/qfoo";' \
              'Acquire::rsh::Proxy::example.com "DIRECT";'; do
    grep -Fq "${needle}" "${scratch}/n7.err" \
        || fail "gate stderr does not name ${needle} (got: $(cat "${scratch}/n7.err"))"
done
"${strip}" "${rootfs8}"
if "${verify}" "${rootfs8}" >"${scratch}/n7b.out" 2>"${scratch}/n7b.err"; then
    fail "gate accepted the quoted-key forms after strip (must stay rejected)"
fi

# ---------------------------------------------------------------------------
# Negative control 8: plain-http apt sources (CVE-2026-109518). The cache-mode
# snapshot source left unrewritten, a deb822 drop-in and a mirror+http URI
# must each fail the gate naming the file; a commented-out http line and an
# https source must not.
# ---------------------------------------------------------------------------
rootfs9="${scratch}/rootfs-http-source"
make_proxy_rootfs "${rootfs9}"
"${strip}" "${rootfs9}" "${PERSISTED_LINE}"
printf '%s\n' '# deb http://deb.debian.org/debian bookworm main' "${SNAPSHOT_SOURCE}" \
    > "${rootfs9}/etc/apt/sources.list"
"${verify}" "${rootfs9}" >"${scratch}/p8.out" 2>"${scratch}/p8.err" \
    || fail "gate rejected a commented-out http line beside the https source: $(cat "${scratch}/p8.err")"
echo 'deb http://snapshot.debian.org/archive/debian/20260601T000000Z/ bookworm main' \
    > "${rootfs9}/etc/apt/sources.list"
if "${verify}" "${rootfs9}" >"${scratch}/n8.out" 2>"${scratch}/n8.err"; then
    fail "gate accepted a plain-http snapshot source"
fi
for needle in 'plain-http apt source' 'etc/apt/sources.list:1:'; do
    grep -Fq "${needle}" "${scratch}/n8.err" \
        || fail "gate stderr does not name ${needle} (got: $(cat "${scratch}/n8.err"))"
done
echo "${SNAPSHOT_SOURCE}" > "${rootfs9}/etc/apt/sources.list"
printf '%s\n' 'Types: deb' 'URIs: http://deb.debian.org/debian' 'Suites: bookworm' 'Components: main' \
    > "${rootfs9}/etc/apt/sources.list.d/debian.sources"
if "${verify}" "${rootfs9}" >"${scratch}/n8b.out" 2>"${scratch}/n8b.err"; then
    fail "gate accepted a plain-http deb822 source"
fi
grep -Fq 'sources.list.d/debian.sources:2:' "${scratch}/n8b.err" \
    || fail "gate stderr does not name the deb822 source (got: $(cat "${scratch}/n8b.err"))"
echo 'deb mirror+http://deb.debian.org/debian bookworm main' \
    > "${rootfs9}/etc/apt/sources.list.d/debian.sources"
if "${verify}" "${rootfs9}" >"${scratch}/n8c.out" 2>"${scratch}/n8c.err"; then
    fail "gate accepted a mirror+http source"
fi

# ---------------------------------------------------------------------------
# Negative control 9: the installed apt (CVE-2026-109518). The snapshot's
# vulnerable 2.6.1, a fixed apt over a stale libapt-pkg6.0, and a rootfs with
# no dpkg database at all must each fail the gate with the assert's reason.
# ---------------------------------------------------------------------------
rootfs10="${scratch}/rootfs-apt-version"
make_proxy_rootfs "${rootfs10}"
"${strip}" "${rootfs10}" "${PERSISTED_LINE}"
make_dpkg_db "${rootfs10}" 2.6.1 2.6.1
if "${verify}" "${rootfs10}" >"${scratch}/n9.out" 2>"${scratch}/n9.err"; then
    fail "gate accepted the snapshot's vulnerable apt 2.6.1"
fi
grep -Fq 'apt_cve_2026_109518=FAIL version=2.6.1 min=2.6.2 reason=below-minimum' "${scratch}/n9.err" \
    || fail "gate stderr does not carry the apt 2.6.1 FAIL (got: $(cat "${scratch}/n9.err"))"
make_dpkg_db "${rootfs10}" 2.6.2 2.6.1
if "${verify}" "${rootfs10}" >"${scratch}/n9b.out" 2>"${scratch}/n9b.err"; then
    fail "gate accepted apt 2.6.2 over libapt-pkg6.0 2.6.1"
fi
grep -Fq 'reason=libapt-mismatch:libapt-pkg6.0:arm64=2.6.1' "${scratch}/n9b.err" \
    || fail "gate stderr does not name the stale libapt-pkg6.0 (got: $(cat "${scratch}/n9b.err"))"
find "${rootfs10}/var/lib/dpkg" -mindepth 1 -delete
if "${verify}" "${rootfs10}" >"${scratch}/n9c.out" 2>"${scratch}/n9c.err"; then
    fail "gate accepted a rootfs with no dpkg database"
fi
grep -Fq 'reason=no-dpkg-status:' "${scratch}/n9c.err" \
    || fail "gate stderr does not report the missing dpkg database (got: $(cat "${scratch}/n9c.err"))"

# ---------------------------------------------------------------------------
# Positive control 3: the https rewrite. A cache-mode build persists the
# http snapshot mirror; the rewrite makes it the exact https source a direct
# build persists, the gate passes, and a second rewrite is a byte-identical
# no-op. It launders no other plain-http source: the gate still rejects one.
# ---------------------------------------------------------------------------
rootfs11="${scratch}/rootfs-cache-mode"
make_proxy_rootfs "${rootfs11}"
"${strip}" "${rootfs11}" "${PERSISTED_LINE}"
echo 'deb http://snapshot.debian.org/archive/debian/20260601T000000Z/ bookworm main' \
    > "${rootfs11}/etc/apt/sources.list"
"${rewrite}" "${rootfs11}" >"${scratch}/p3.out"
grep -Fq 'rewrote 1 file(s) to https' "${scratch}/p3.out" \
    || fail "rewrite did not report its one rewritten file (got: $(cat "${scratch}/p3.out"))"
[ "$(cat "${rootfs11}/etc/apt/sources.list")" = "${SNAPSHOT_SOURCE}" ] \
    || fail "rewrite did not persist the direct-build https source: $(cat "${rootfs11}/etc/apt/sources.list")"
"${verify}" "${rootfs11}" >"${scratch}/p3v.out" 2>"${scratch}/p3v.err" \
    || fail "gate rejected the rewritten cache-mode rootfs: $(cat "${scratch}/p3v.err")"
rewrite_before="$(find "${rootfs11}/etc/apt" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
"${rewrite}" "${rootfs11}" >"${scratch}/p3b.out"
rewrite_after="$(find "${rootfs11}/etc/apt" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
[ "${rewrite_before}" = "${rewrite_after}" ] || fail "second rewrite mutated etc/apt"
grep -Fq 'rewrote 0 file(s) to https' "${scratch}/p3b.out" \
    || fail "second rewrite was not a no-op (got: $(cat "${scratch}/p3b.out"))"
echo 'deb http://deb.debian.org/debian bookworm main' > "${rootfs11}/etc/apt/sources.list.d/other.list"
"${rewrite}" "${rootfs11}" >/dev/null
grep -Fxq 'deb http://deb.debian.org/debian bookworm main' "${rootfs11}/etc/apt/sources.list.d/other.list" \
    || fail "rewrite laundered a non-snapshot plain-http source"
if "${verify}" "${rootfs11}" >"${scratch}/n10.out" 2>"${scratch}/n10.err"; then
    fail "gate accepted a non-snapshot plain-http source the rewrite does not own"
fi

# ---------------------------------------------------------------------------
# Positive control 2: a clean rootfs (direct build, PF_APT_PROXY unset) passes
# the gate untouched, and strip is a byte-identical no-op on it — with no
# persisted line argument and with one (absent line = idempotent skip).
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
"${strip}" "${rootfs4}" "${PERSISTED_LINE}"
clean_after="$(find "${rootfs4}/etc/apt" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
[ "${clean_before}" = "${clean_after}" ] || fail "strip mutated a clean rootfs"

# ---------------------------------------------------------------------------
# Wiring: both rootfs builders must run strip-then-verify on the tree that
# actually gets assembled, before mke2fs; the a133 builder must hand strip the
# exact line its PF_APT_PROXY --aptopt persists.
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
    local builder="$1" target="$2" rewrite_ln strip_ln verify_ln mke2fs_ln
    rewrite_ln="$(first_line_no "rewrite-rootfs-apt-sources-https.sh\" \"\${${target}}\"" "${builder}")"
    [ -n "${rewrite_ln}" ] \
        || fail "${builder} does not rewrite the persisted apt sources to https on \${${target}}"
    strip_ln="$(first_line_no "strip-rootfs-apt-proxy.sh\" \"\${${target}}\"" "${builder}")"
    [ -n "${strip_ln}" ] \
        || fail "${builder} does not strip the apt proxy on \${${target}} before assembly"
    verify_ln="$(first_line_no "verify-rootfs-apt-policy.sh\" \"\${${target}}\"" "${builder}")"
    [ -n "${verify_ln}" ] \
        || fail "${builder} does not run the release apt policy gate on \${${target}}"
    [ "${strip_ln}" -lt "${verify_ln}" ] \
        || fail "${builder}: strip must run before the verify gate"
    [ "${rewrite_ln}" -lt "${verify_ln}" ] \
        || fail "${builder}: the https rewrite must run before the verify gate"
    mke2fs_ln="$(first_line_no '^mke2fs' "${builder}")"
    [ -n "${mke2fs_ln}" ] || fail "${builder}: no mke2fs invocation found"
    [ "${verify_ln}" -lt "${mke2fs_ln}" ] \
        || fail "${builder}: apt policy gate runs after ext4 assembly"
}
assert_wired "${repo_dir}/scripts/build-rootfs.sh" 'ROOTFS_EXTRACTED'
assert_wired "${repo_dir}/scripts/build-rootfs-a523.sh" 'EXT'
grep -Fxq '"${SRC_DIR}/scripts/strip-rootfs-apt-proxy.sh" "${ROOTFS_EXTRACTED}" "${APT_PROXY_PERSISTED}"' \
    "${repo_dir}/scripts/build-rootfs.sh" \
    || fail "build-rootfs.sh must pass its persisted PF_APT_PROXY aptopt line to the strip"
grep -n 'APT_PROXY_PERSISTED=' "${repo_dir}/scripts/build-rootfs.sh" >/dev/null \
    || fail "build-rootfs.sh does not derive APT_PROXY_PERSISTED from its --aptopt"
grep -Fxq '"${SRC_DIR}/scripts/strip-rootfs-apt-proxy.sh" "${EXT}"' \
    "${repo_dir}/scripts/build-rootfs-a523.sh" \
    || fail "build-rootfs-a523.sh strip call changed shape; update this test deliberately"

echo "rootfs-apt-policy=PASS positive=strip-then-verify-clean-proxied-and-direct-rootfs,apt-config-rootfs-isolation,second-strip-noop,https-rewrite-cache-mode-idempotent,commented-http-line negative=persisted-99mmdebstrap-proxy,apt.conf-proxy,bare-private-endpoint,unquoted-proxy-values,block-brace-terminator,split-key-value,invalid-config-parse-failure,quoted-key-components,host-config-leak,http-snapshot-source,http-deb822-source,mirror+http-source,apt-2.6.1,libapt-mismatch,no-dpkg-db,rewrite-launders-nothing-else"
