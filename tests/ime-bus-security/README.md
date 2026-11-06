# IME bus security test container

The image build reaches the Debian snapshot over https with a public-CA store taken from a
digest-pinned image, with apt `Acquire::Retries` 0 (CVE-2026-109518), a fail-closed
`apt-get update` and bounded steps, all in `install-tools.sh`. A pf-public-ci runner is fenced
from the NAS apt cache, so there is no cache in front of snapshot.debian.org: a 503/504 from it
fails the step with a named reason, and `tests/test-ime-bus-security.sh` bounds the whole build
(`PF_IME_BUILD_TIMEOUT`, 1200 s). `tests/test-ime-apt-install.sh` proves this hermetically.

The container uses the image build's Debian snapshot and carries only the tools
needed by the real-binary private-bus harness. It does not depend on nested user namespaces:
the image records the invoking runner uid/gid as `pf-ime`, while two
disposable Docker containers provide the writable runtime and app-visible mount
views.

Before building the image, the wrapper rejects root, reserved system identities,
and the `nobody` identity used by the negative control. This keeps both containers
non-root even if a self-hosted runner service is accidentally configured as root.

Both containers are non-root and networkless, have a read-only root filesystem,
drop every capability, and are removed on exit. The checkout is mounted read-only.
The main harness receives only disposable `/run` and `/tmp` tmpfs mounts; the app
view receives a read-only fixture containing only its own door. No AppArmor or
seccomp policy is disabled.
