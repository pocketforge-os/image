#!/usr/bin/env python3
"""Digest the Cargo.lock-pinned source a Poolsuite build compiles (bd tsp-mc9m.41.984.20.1).

`cargo fetch --locked` fills CARGO_HOME with two kinds of state:

* the pinned source input: each registry crate archive
  (registry/cache/<registry>/<name>-<version>.crate, whose sha256 Cargo.lock
  records as `checksum`) and each git dependency's working tree
  (git/checkouts/<repo>-<hash>/<short-rev>/, at the commit Cargo.lock records);
* fetch bookkeeping, which differs on every fetch: the sparse-index cache (HTTP
  validators and every version published since), the git object databases,
  each checkout's .git, the .global-cache last-use database and lock files.

The previous digest tarred all of CARGO_HOME, so it recorded the bookkeeping and
changed on every build while ps-app did not. This digest covers only the pinned
source input, and it refuses a closure that Cargo.lock does not pin exactly:

* every .crate must be a registry package in Cargo.lock, and its sha256 must be
  the checksum Cargo.lock records for it;
* every git checkout's HEAD must be a commit that Cargo.lock pins, and the tree
  digest excludes only .git and cargo's .cargo-ok marker.

Registry trees unpacked under registry/src are not digested: cargo derives them
from the verified archives. At least one .crate must be present, so a cargo
layout change fails closed instead of digesting nothing.

Prints the sha256 of the canonical manifest on stdout. --manifest also writes
the manifest (its preimage), one line per input:

    pocketforge.poolsuite-fetched-source/v1
    cargo_lock_sha256 <sha256 of Cargo.lock>
    crate <name> <version> <sha256>
    git <url> <rev> <tree-sha256>

Errors print `reason=<token>` and exit 1. Standard library only (Python 3.11+).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tomllib

SCHEMA = "pocketforge.poolsuite-fetched-source/v1"


class DigestError(Exception):
    def __init__(self, reason: str, detail: str) -> None:
        super().__init__(f"reason={reason} {detail}")


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_lock(path: str) -> tuple[str, dict[str, tuple[str, str, str | None]], dict[str, set[str]]]:
    """Return (lock sha256, {crate file name: (name, version, checksum)}, {rev: {url}})."""
    with open(path, "rb") as handle:
        raw = handle.read()
    try:
        lock = tomllib.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise DigestError("cargo_lock_unreadable", f"path={path} error={exc}") from exc
    crates: dict[str, tuple[str, str, str | None]] = {}
    git_revs: dict[str, set[str]] = {}
    for package in lock.get("package", []):
        source = package.get("source", "")
        name, version = package.get("name"), package.get("version")
        if source.startswith("registry+"):
            crates[f"{name}-{version}.crate"] = (name, version, package.get("checksum"))
        elif source.startswith("git+"):
            url, sep, rev = source[len("git+"):].partition("#")
            if not sep or len(rev) != 40 or any(c not in "0123456789abcdef" for c in rev):
                raise DigestError("git_source_unpinned", f"package={name} source={source}")
            git_revs.setdefault(rev, set()).add(url)
    return hashlib.sha256(raw).hexdigest(), crates, git_revs


def crate_lines(cargo_home: str, pinned: dict[str, tuple[str, str, str | None]]) -> set[str]:
    cache = os.path.join(cargo_home, "registry", "cache")
    lines: set[str] = set()
    registries = sorted(os.listdir(cache)) if os.path.isdir(cache) else []
    for registry in registries:
        registry_dir = os.path.join(cache, registry)
        if not os.path.isdir(registry_dir):
            continue
        for entry in sorted(os.listdir(registry_dir)):
            if not entry.endswith(".crate"):
                continue
            path = os.path.join(registry_dir, entry)
            if entry not in pinned:
                raise DigestError("crate_not_pinned", f"file={registry}/{entry}")
            name, version, checksum = pinned[entry]
            if not checksum:
                raise DigestError("crate_checksum_missing", f"crate={name}-{version}")
            actual = sha256_file(path)
            if actual != checksum:
                raise DigestError(
                    "crate_checksum_mismatch",
                    f"crate={name}-{version} lock={checksum} fetched={actual}",
                )
            lines.add(f"crate {name} {version} {actual}")
    if not lines:
        raise DigestError("no_pinned_crates", f"no .crate archives under {cache}")
    return lines


def tree_digest(root: str) -> str:
    """sha256 over (path, exec bit, content sha256) or (path, symlink target), sorted."""
    records: list[str] = []
    for current, dirs, files in os.walk(root):
        rel_dir = os.path.relpath(current, root)
        names = list(files)
        descend = []
        for name in dirs:
            if name == ".git":
                continue
            # os.walk lists a symlink to a directory in dirs without following it.
            if os.path.islink(os.path.join(current, name)):
                names.append(name)
            else:
                descend.append(name)
        dirs[:] = sorted(descend)
        for name in sorted(names):
            if name == ".git" or (rel_dir == "." and name == ".cargo-ok"):
                continue
            path = os.path.join(current, name)
            rel = os.path.normpath(os.path.join(rel_dir, name))
            if os.path.islink(path):
                records.append(f"l {rel} {os.readlink(path)}")
            elif os.path.isfile(path):
                mode = "x" if os.stat(path).st_mode & 0o111 else "-"
                records.append(f"f {rel} {mode} {sha256_file(path)}")
            else:
                raise DigestError("git_tree_unexpected_file", f"path={path}")
    body = "".join(f"{record}\n" for record in sorted(records))
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def checkout_head(path: str) -> str:
    result = subprocess.run(
        ["git", "-c", "safe.directory=*", "-C", path, "rev-parse", "--verify", "HEAD^{commit}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise DigestError("git_checkout_head_unreadable", f"path={path} error={result.stderr.strip()}")
    return result.stdout.strip()


def repo_ident(url: str) -> str:
    """cargo's checkout directory stem: the last URL path segment without .git."""
    path = url.split("?", 1)[0].rstrip("/")
    last = path.rsplit("/", 1)[-1]
    return last[: -len(".git")] if last.endswith(".git") else last


def git_lines(cargo_home: str, pinned: dict[str, set[str]]) -> set[str]:
    checkouts = os.path.join(cargo_home, "git", "checkouts")
    lines: set[str] = set()
    if not os.path.isdir(checkouts):
        return lines
    for repo_dir in sorted(os.listdir(checkouts)):
        repo_path = os.path.join(checkouts, repo_dir)
        if not os.path.isdir(repo_path):
            continue
        for short in sorted(os.listdir(repo_path)):
            path = os.path.join(repo_path, short)
            if not os.path.isdir(path):
                continue
            head = checkout_head(path)
            urls = pinned.get(head, set())
            if len(urls) > 1:
                urls = {url for url in urls if repo_dir.startswith(f"{repo_ident(url)}-")}
            if len(urls) != 1:
                raise DigestError(
                    "git_rev_not_pinned",
                    f"checkout={repo_dir}/{short} head={head} lock_urls={sorted(pinned.get(head, set()))}",
                )
            (url,) = urls
            lines.add(f"git {url} {head} {tree_digest(path)}")
    return lines


def manifest(cargo_home: str, cargo_lock: str) -> str:
    lock_sha, crates, git_revs = read_lock(cargo_lock)
    body = [SCHEMA, f"cargo_lock_sha256 {lock_sha}"]
    body += sorted(crate_lines(cargo_home, crates))
    body += sorted(git_lines(cargo_home, git_revs))
    return "".join(f"{line}\n" for line in body)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--cargo-home", required=True, help="the CARGO_HOME `cargo fetch --locked` populated")
    parser.add_argument("--cargo-lock", required=True, help="the Cargo.lock that fetch used")
    parser.add_argument("--manifest", help="also write the canonical manifest here")
    args = parser.parse_args(argv)
    try:
        text = manifest(args.cargo_home, args.cargo_lock)
    except (DigestError, OSError) as exc:
        print(f"poolsuite-source-digest: FATAL: {exc}", file=sys.stderr)
        return 1
    if args.manifest:
        with open(args.manifest, "w", encoding="utf-8") as handle:
            handle.write(text)
    print(hashlib.sha256(text.encode("utf-8")).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
