#!/usr/bin/env bash
# Remove the build-transport apt proxy directives that mmdebstrap persisted
# into the assembled rootfs (bd tsp-mc9m.41.1002.5).
#
# mmdebstrap 1.5.5 permanently appends every --aptopt value to
# etc/apt/apt.conf.d/99mmdebstrap (its cleanup unlinks only 00mmdebstrap and
# 99debconf), so build-rootfs.sh's PF_APT_PROXY transport option
# 'Acquire::http::Proxy "http://<build-cache>:3142"' would otherwise ship in
# the release image. Build-6 did exactly that and first-boot cloud-config died
# on the unreachable private endpoint. This excises every proxy directive from
# any TEXT file under etc/apt (never hardcoded to 99mmdebstrap) — quoted or
# unquoted values, ';' terminators, block '}' terminators ('{ Proxy DIRECT }')
# and key/value splits across lines (review r4374286544; all confirmed with
# apt-config dump) — keeps the sibling build-hardening aptopts
# (Check-Valid-Until, Retries, Sandbox::User) and the pinned
# snapshot.debian.org source, drops files that become empty, and is a
# byte-identical no-op on an already-clean (direct build) tree.
#
# Twin of scripts/verify-rootfs-apt-policy.sh: discovery here and the gate
# there MUST use the same token-boundary PROXY_RE, and the statement-precise
# python3 remover below re-scans every rewritten file with the equivalent
# TOKEN regex, failing closed (the build halts before mke2fs) if any Proxy*
# token survives — the gate can never reject what this strip released.
set -euo pipefail

ROOTFS="${1:?usage: strip-rootfs-apt-proxy.sh ROOTFS}"
APT_DIR="${ROOTFS}/etc/apt"

[ -d "${APT_DIR}" ] \
    || { echo "FATAL: rootfs apt strip: ${APT_DIR} is missing" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 \
    || { echo "FATAL: rootfs apt strip: python3 is required for statement-precise removal" >&2
         exit 1; }

# Any Proxy* key as its own config token: left boundary start-of-line,
# whitespace or '{'; right boundary end-of-line, whitespace, ';', '}' or a
# quote. Value shape and terminator are deliberately NOT required — apt
# accepts 'Proxy DIRECT }', a value on the line after the key, etc. Prose
# like '// proxy:' cannot match (':' is not a token boundary). MUST stay
# equivalent to the python3 TOKEN regex below and to the verify twin.
PROXY_RE='(^|[[:space:]{])([[:alnum:]_+.-]+::)*[Pp][Rr][Oo][Xx][Yy]([[:alnum:]_.-]+|::)*($|[[:space:];}"])'

# grep -I skips binaries (trusted.gpg.d keyrings); rc=1 (no match) is the
# clean-tree fast path, rc>=2 is a real error and must not be swallowed.
rc=0
files="$(grep -rIlE "${PROXY_RE}" "${APT_DIR}")" || rc=$?
case "${rc}" in
    0) ;;
    1) echo "  rootfs apt strip: no persisted proxy directives under etc/apt"
       exit 0 ;;
    *) echo "FATAL: rootfs apt strip: grep over ${APT_DIR} failed (rc=${rc})" >&2
       exit 1 ;;
esac

# Statement-precise removal (newline-separated candidate paths via env; grep
# lists one path per line, as did the previous bash loop). A directive is a
# Proxy* token followed by an optional value and a terminator: ';' (excise
# through it), '}' (excise up to it, keep the brace and the rest of the line)
# or end-of-line (excise key and value, then consume continuation lines until
# the value and/or terminator arrives: '"DIRECT";', '};', a bare value or a
# blank). A continuation line that is neither (e.g. a sibling 'Timeout "30";'
# after an unterminated 'Proxy false') ends the statement scan and is kept.
# Rewrites truncate in place, preserving inode/owner/mode for mke2fs -d.
summary="$(PF_STRIP_FILES="${files}" python3 - "${APT_DIR}" <<'PYEOF'
import os, re, sys

S = r'[ \t\v\f\r]'
TOKEN = re.compile(r'(^|[ \t\v\f\r{])([A-Za-z0-9_+.-]+::)*[Pp][Rr][Oo][Xx][Yy]'
                   r'([A-Za-z0-9_.-]+|::)*($|[ \t\v\f\r;}"])')
KEY = re.compile(r'([A-Za-z0-9_+.-]+::)*[Pp][Rr][Oo][Xx][Yy]([A-Za-z0-9_.-]+|::)*')
VAL = r'(?:"[^"]*"|[^ \t\v\f\r;}"\']+)'
SHAPE = re.compile(S + r'*(?:' + VAL + r')?' + S + r'*(;|}|$)')
CONT = re.compile(r'^' + S + r'*(?:' + VAL + S + r'*)?([;}]|$)')

def scan(line):
    """Excise complete proxy directives from one line -> (new, n, pending);
    pending means a statement was left open at end-of-line."""
    out, i, n, pending = [], 0, 0, False
    while True:
        m = KEY.search(line, i)
        if m is None:
            out.append(line[i:])
            break
        if m.start() > 0 and line[m.start() - 1] not in ' \t\v\f\r{':
            out.append(line[i:m.end()])
            i = m.end()
            continue
        sm = SHAPE.match(line, m.end())
        if sm is None:
            out.append(line[i:m.end()])
            i = m.end()
            continue
        out.append(line[i:m.start()])
        n += 1
        if sm.group(1) == '}':
            i = sm.end() - 1           # keep the brace and the rest
        else:
            i = sm.end()               # ';' or EOL: consume through it
            pending = sm.group(1) == ''
    return ''.join(out), n, pending

removed_lines = 0
removed_files = 0
for path in [p for p in os.environ['PF_STRIP_FILES'].splitlines() if p]:
    with open(path, 'r', encoding='utf-8', errors='surrogateescape',
              newline='') as fh:
        text = fh.read()
    out, pending, removed = [], False, 0
    for line in text.split('\n'):
        if pending:
            cm = CONT.match(line)
            if cm is not None:
                term = cm.group(1)
                if term == '':         # bare value or blank: still open
                    if line.strip():
                        removed += 1
                    continue
                pending = False
                rest = line[cm.end():] if term == ';' else line[cm.start(1):]
                if rest != line:       # part of the line was consumed
                    removed += 1
                if rest.strip() == '':
                    continue
                line = rest            # scan the kept remainder
            else:
                pending = False        # sibling content: keep the whole line
        new, n, pending = scan(line)
        removed += n
        if n and new.strip() == '':
            continue                   # directive consumed the whole line
        out.append(new)
    new_text = '\n'.join(out)
    for line in new_text.split('\n'):
        if TOKEN.search(line):
            sys.stderr.write('FATAL: rootfs apt strip: unremovable proxy '
                             'token in %s: %s\n' % (path, line.strip()))
            sys.exit(1)
    if new_text.strip() == '':
        os.unlink(path)
        removed_files += 1
    elif new_text != text:
        with open(path, 'w', encoding='utf-8', errors='surrogateescape',
                  newline='') as fh:
            fh.write(new_text)
    removed_lines += removed
print(removed_lines, removed_files)
PYEOF
)"
read -r removed_lines removed_files <<< "${summary}"

echo "  rootfs apt strip: removed ${removed_lines} proxy directive line(s)" \
     "(${removed_files} file(s) became empty and were dropped)"
