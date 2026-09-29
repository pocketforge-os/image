#!/usr/bin/env python3
"""Hermetic test for scripts/poolsuite-source-digest.py (bd tsp-mc9m.41.984.20.1).

Builds a fixture CARGO_HOME in the layout `cargo fetch --locked` leaves (cargo
1.91: registry/cache, registry/index sparse cache, registry/src, git/db,
git/checkouts/<repo>-<hash>/<short-rev>/ with .git and .cargo-ok, .global-cache)
around a fixture Cargo.lock, then checks that:

  * the digest is unchanged by fetch bookkeeping churn (index cache, git object
    databases, checkout .git, .global-cache, mtimes and permission bits), while
    the previous whole-CARGO_HOME tar digest changes under the same churn (the
    control that proves the churn reaches what the old digest recorded);
  * the manifest names exactly the fetched crates and git trees, and nothing
    Cargo.lock pins but fetch skipped;
  * any change to pinned source content, an exec bit, or Cargo.lock changes it;
  * it refuses an unpinned crate, a checksum mismatch, a crate without a lock
    checksum, a checkout at an unpinned commit, an unpinned git source and an
    empty registry cache.

Needs python3 (3.11+), git and GNU tar. No network, no Docker.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "scripts", "poolsuite-source-digest.py")
REGISTRY = "index.crates.io-1949cf8c6b5b557f"
CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"
GIT_URL = "https://example.invalid/org/gdep.git"
GIT_ENV = {
    "GIT_AUTHOR_NAME": "fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
    "GIT_AUTHOR_DATE": "@1700000000 +0000",
    "GIT_COMMITTER_DATE": "@1700000000 +0000",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
}

failures: list[str] = []


def check(condition: bool, label: str) -> None:
    print(f"{'ok  ' if condition else 'FAIL'} {label}")
    if not condition:
        failures.append(label)


def git(*args: str, cwd: str | None = None) -> str:
    env = dict(os.environ, **GIT_ENV)
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True,
                          capture_output=True, text=True).stdout.strip()


def write(path: str, data: bytes | str, mode: int | None = None) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data.encode() if isinstance(data, str) else data)
    if mode is not None:
        os.chmod(path, mode)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_digest(home: str, lock: str, manifest: str | None = None) -> subprocess.CompletedProcess:
    cmd = [sys.executable, "-B", SCRIPT, "--cargo-home", home, "--cargo-lock", lock]
    if manifest:
        cmd += ["--manifest", manifest]
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def digest(home: str, lock: str) -> str:
    result = run_digest(home, lock)
    if result.returncode != 0:
        raise AssertionError(f"digest failed: {result.stderr.strip()}")
    return result.stdout.strip()


def old_tar_digest(home: str) -> str:
    """The digest build/Dockerfile.pf recorded before this change."""
    tar = subprocess.run(["tar", "--sort=name", "--mtime=@0", "--owner=0", "--group=0",
                          "--numeric-owner", "-cf", "-", "."], cwd=home, check=True,
                         capture_output=True).stdout
    return sha(tar)


class Fixture:
    def __init__(self, root: str) -> None:
        self.root = root
        self.src = os.path.join(root, "src", "gdep")
        os.makedirs(self.src)
        git("init", "-q", "-b", "main", self.src)
        write(os.path.join(self.src, "Cargo.toml"), '[package]\nname = "gdep"\nversion = "0.1.0"\n')
        write(os.path.join(self.src, "src", "lib.rs"), "pub fn f() {}\n")
        write(os.path.join(self.src, "tools", "gen.sh"), "#!/bin/sh\necho gen\n", 0o755)
        os.symlink("src/lib.rs", os.path.join(self.src, "lib-link.rs"))
        git("add", "-A", cwd=self.src)
        git("commit", "-q", "-m", "one", cwd=self.src)
        self.rev1 = git("rev-parse", "HEAD", cwd=self.src)
        write(os.path.join(self.src, "src", "lib.rs"), "pub fn f() { /* two */ }\n")
        git("commit", "-q", "-am", "two", cwd=self.src)
        self.rev2 = git("rev-parse", "HEAD", cwd=self.src)

        self.crates = {
            ("foo", "1.0.0"): b"foo crate archive bytes\n",
            ("bar-baz", "0.2.0-beta.1"): b"bar-baz crate archive bytes\n",
        }
        self.lock = os.path.join(root, "Cargo.lock")
        self.write_lock()
        self.home = os.path.join(root, "cargo-home")
        self.populate(self.home)

    def write_lock(self, extra: str = "", foo_checksum: str | None = None) -> None:
        text = "# fixture\nversion = 4\n\n[[package]]\nname = \"app\"\nversion = \"0.1.0\"\n"
        for (name, version), data in sorted(self.crates.items()):
            checksum = foo_checksum if name == "foo" and foo_checksum is not None else sha(data)
            text += (f"\n[[package]]\nname = \"{name}\"\nversion = \"{version}\"\n"
                     f"source = \"{CRATES_IO}\"\nchecksum = \"{checksum}\"\n")
        text += (f"\n[[package]]\nname = \"unfetched\"\nversion = \"9.9.9\"\n"
                 f"source = \"{CRATES_IO}\"\nchecksum = \"{sha(b'never fetched')}\"\n")
        text += (f"\n[[package]]\nname = \"gdep\"\nversion = \"0.1.0\"\n"
                 f"source = \"git+{GIT_URL}?rev={self.rev1}#{self.rev1}\"\n")
        write(self.lock, text + extra)

    def populate(self, home: str) -> None:
        for (name, version), data in self.crates.items():
            write(os.path.join(home, "registry", "cache", REGISTRY, f"{name}-{version}.crate"), data)
            write(os.path.join(home, "registry", "src", REGISTRY, f"{name}-{version}", ".cargo-ok"), '{"v":1}')
            write(os.path.join(home, "registry", "src", REGISTRY, f"{name}-{version}", "src", "lib.rs"), name)
        write(os.path.join(home, "registry", "index", REGISTRY, ".cache", "3", "f", "foo"),
              b"\x03etag: \"v1\"\x00foo 1.0.0\n")
        write(os.path.join(home, "registry", "CACHEDIR.TAG"), "Signature: 8a477f597d28d172789f06886806bc55\n")
        write(os.path.join(home, ".global-cache"), os.urandom(64))
        write(os.path.join(home, ".package-cache"), "")
        db = os.path.join(home, "git", "db", "gdep-0123456789abcdef")
        git("clone", "-q", "--bare", self.src, db)
        checkout = os.path.join(home, "git", "checkouts", "gdep-0123456789abcdef", self.rev1[:7])
        git("clone", "-q", "--no-checkout", db, checkout)
        git("-c", "advice.detachedHead=false", "checkout", "-q", self.rev1, cwd=checkout)
        write(os.path.join(checkout, ".cargo-ok"), "")
        self.checkout = checkout


def churn(fx: Fixture, home: str) -> None:
    """Change only fetch bookkeeping, as a second fetch of the same lock does."""
    write(os.path.join(home, "registry", "index", REGISTRY, ".cache", "3", "f", "foo"),
          b"\x03etag: \"v2\"\x00foo 1.0.0\nfoo 1.0.1\n")
    write(os.path.join(home, ".global-cache"), os.urandom(64))
    db = os.path.join(home, "git", "db", "gdep-0123456789abcdef")
    git("fetch", "-q", fx.src, "main:refs/heads/later", cwd=db)
    git("gc", "-q", "--prune=now", cwd=db)
    checkout = os.path.join(home, "git", "checkouts", "gdep-0123456789abcdef", fx.rev1[:7])
    git("fetch", "-q", db, "later", cwd=checkout)
    os.utime(os.path.join(checkout, "src", "lib.rs"), (1, 1))
    git("update-index", "-q", "--really-refresh", cwd=checkout)
    os.chmod(os.path.join(checkout, "Cargo.toml"), 0o600)
    for current, _dirs, files in os.walk(home):
        for name in files:
            path = os.path.join(current, name)
            if not os.path.islink(path):
                os.utime(path, (1234567890, 1234567890))


def refused(fx: Fixture, name: str, mutate, reason: str) -> None:
    home = os.path.join(fx.root, f"case-{name}")
    shutil.copytree(fx.home, home, symlinks=True)
    lock = mutate(home) or fx.lock
    result = run_digest(home, lock)
    check(result.returncode == 1 and f"reason={reason}" in result.stderr,
          f"refuses {name} with reason={reason} (rc={result.returncode}: {result.stderr.strip()[:160]})")


def main() -> int:
    root = tempfile.mkdtemp(prefix="poolsuite-source-digest-")
    try:
        fx = Fixture(root)
        manifest_path = os.path.join(root, "manifest")
        result = run_digest(fx.home, fx.lock, manifest_path)
        check(result.returncode == 0, f"digest succeeds on a pinned closure ({result.stderr.strip()})")
        base = result.stdout.strip()
        check(len(base) == 64 and all(c in "0123456789abcdef" for c in base), f"prints one sha256 ({base})")
        with open(manifest_path, encoding="utf-8") as handle:
            manifest = handle.read()
        check(sha(manifest.encode()) == base, "digest is the sha256 of the written manifest")
        with open(fx.lock, "rb") as handle:
            lock_sha = sha(handle.read())
        lines = manifest.splitlines()
        check(lines[0] == "pocketforge.poolsuite-fetched-source/v1", "manifest schema line")
        check(lines[1] == f"cargo_lock_sha256 {lock_sha}", "manifest records the Cargo.lock sha256")
        expected_crates = sorted(f"crate {n} {v} {sha(d)}" for (n, v), d in fx.crates.items())
        check([line for line in lines if line.startswith("crate ")] == expected_crates,
              "manifest lists exactly the fetched crates, with their archive sha256")
        git_lines = [line for line in lines if line.startswith("git ")]
        check(len(git_lines) == 1 and git_lines[0].startswith(f"git {GIT_URL}?rev={fx.rev1} {fx.rev1} "),
              "manifest lists the git checkout at its Cargo.lock url and rev")
        check("unfetched" not in manifest, "a pinned package that fetch skipped is not listed")

        # Bookkeeping churn: new digest stable; the old whole-CARGO_HOME digest is not.
        churned = os.path.join(root, "churned")
        shutil.copytree(fx.home, churned, symlinks=True)
        old_before = old_tar_digest(churned)
        churn(fx, churned)
        check(old_tar_digest(churned) != old_before,
              "control: the previous tar-over-CARGO_HOME digest changes under bookkeeping churn")
        check(digest(churned, fx.lock) == base, "digest is unchanged by bookkeeping churn")

        # Pinned-source changes must change the digest.
        edited = os.path.join(root, "edited")
        shutil.copytree(fx.home, edited, symlinks=True)
        checkout = os.path.join(edited, os.path.relpath(fx.checkout, fx.home))
        write(os.path.join(checkout, "src", "lib.rs"), "pub fn f() { /* edited */ }\n")
        check(digest(edited, fx.lock) != base, "a git working-tree content change changes the digest")
        shutil.rmtree(edited)
        shutil.copytree(fx.home, edited, symlinks=True)
        checkout = os.path.join(edited, os.path.relpath(fx.checkout, fx.home))
        os.chmod(os.path.join(checkout, "tools", "gen.sh"), 0o644)
        check(digest(edited, fx.lock) != base, "a git working-tree exec-bit change changes the digest")
        shutil.rmtree(edited)
        shutil.copytree(fx.home, edited, symlinks=True)
        checkout = os.path.join(edited, os.path.relpath(fx.checkout, fx.home))
        os.remove(os.path.join(checkout, "lib-link.rs"))
        os.symlink("Cargo.toml", os.path.join(checkout, "lib-link.rs"))
        check(digest(edited, fx.lock) != base, "a git working-tree symlink target change changes the digest")
        lock2 = os.path.join(root, "Cargo.lock.2")
        with open(fx.lock, encoding="utf-8") as src, open(lock2, "w", encoding="utf-8") as dst:
            dst.write(src.read() + "\n# changed\n")
        check(digest(fx.home, lock2) != base, "a Cargo.lock change changes the digest")

        # Refusals.
        def corrupt_crate(home: str) -> None:
            write(os.path.join(home, "registry", "cache", REGISTRY, "foo-1.0.0.crate"), b"tampered\n")
        refused(fx, "checksum-mismatch", corrupt_crate, "crate_checksum_mismatch")

        def extra_crate(home: str) -> None:
            write(os.path.join(home, "registry", "cache", REGISTRY, "qux-1.0.0.crate"), b"qux\n")
        refused(fx, "unpinned-crate", extra_crate, "crate_not_pinned")

        def no_checksum(home: str) -> str:
            path = os.path.join(home, "Cargo.lock")
            with open(fx.lock, encoding="utf-8") as handle:
                text = handle.read()
            text = text.replace(f'checksum = "{sha(fx.crates[("foo", "1.0.0")])}"\n', "")
            write(path, text)
            return path
        refused(fx, "missing-lock-checksum", no_checksum, "crate_checksum_missing")

        def unpinned_rev(home: str) -> None:
            checkout = os.path.join(home, os.path.relpath(fx.checkout, fx.home))
            db = os.path.join(home, "git", "db", "gdep-0123456789abcdef")
            git("fetch", "-q", fx.src, "main:refs/heads/later", cwd=db)
            git("fetch", "-q", db, "later", cwd=checkout)
            git("-c", "advice.detachedHead=false", "checkout", "-q", fx.rev2, cwd=checkout)
        refused(fx, "checkout-at-unpinned-rev", unpinned_rev, "git_rev_not_pinned")

        def branch_source(home: str) -> str:
            path = os.path.join(home, "Cargo.lock")
            with open(fx.lock, encoding="utf-8") as handle:
                text = handle.read()
            write(path, text.replace(f"#{fx.rev1}", ""))
            return path
        refused(fx, "unpinned-git-source", branch_source, "git_source_unpinned")

        def empty_cache(home: str) -> None:
            shutil.rmtree(os.path.join(home, "registry", "cache"))
        refused(fx, "empty-registry-cache", empty_cache, "no_pinned_crates")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    if failures:
        print(f"poolsuite source digest: FAIL ({len(failures)} failed)")
        return 1
    print("poolsuite source digest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
