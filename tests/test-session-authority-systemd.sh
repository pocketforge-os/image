#!/usr/bin/env bash
set -euo pipefail

# Docker is intentional here: a privileged container with a private cgroup
# namespace exercises systemd as the actual PID 1 through the same Docker
# interface available to image CI. systemd-nspawn would add a host-only tool
# dependency without covering that boundary.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="${root}/tests/session-authority-systemd"
app_unit="${root}/rootfs-overlay/etc/systemd/system/pf-app@.service"
owner_dropin="${root}/rootfs-overlay/etc/systemd/system/pocketforge-foreground.target.d/10-owner-shell.conf"

runtime_sha=0589fcfa959dca9150563ef0ed18d7d44b420dc5
runtime_repository=https://github.com/pocketforge-os/runtime.git
base_image='debian@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171'
app_unit_sha256=ecf620a219af3ca98760707e111fe301e420a9ba977a98ba149187a3bf6f622f

tmp="$(mktemp -d /tmp/tsp-f3fm-209.XXXXXX)"
runtime="${tmp}/runtime"
prepare_container="tsp-f3fm-209-prepare-$$"
systemd_container="tsp-f3fm-209-systemd-$$"
test_image="tsp-f3fm-209-systemd:${runtime_sha:0:12}-$$"
image_created=0

fail() {
    echo "session-authority real-systemd: FAIL: $*" >&2
    exit 1
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    set +e
    docker rm -f "${systemd_container}" >/dev/null 2>&1
    docker rm -f "${prepare_container}" >/dev/null 2>&1
    if [ "${image_created}" -eq 1 ]; then
        docker image rm -f "${test_image}" >/dev/null 2>&1
    fi
    find "${tmp}" -mindepth 1 -delete >/dev/null 2>&1
    rmdir "${tmp}" >/dev/null 2>&1
    if docker ps -a --format '{{.Names}}' | grep -Fxq "${prepare_container}" \
        || docker ps -a --format '{{.Names}}' | grep -Fxq "${systemd_container}" \
        || docker image inspect "${test_image}" >/dev/null 2>&1; then
        echo 'session-authority real-systemd: FAIL: RESOURCE_CLEANUP_FAILED' >&2
        status=1
    fi
    exit "${status}"
}
trap cleanup EXIT INT TERM

for command_name in cargo docker file git rustup sha256sum; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "MISSING_PREREQUISITE: ${command_name}"
done

[ "$(uname -m)" = x86_64 ] || fail "AMD64_REQUIRED: host architecture is $(uname -m)"
docker info >/dev/null 2>&1 || fail 'DOCKER_UNAVAILABLE: docker server is not reachable'
docker_arch="$(docker info --format '{{.Architecture}}')"
[ "${docker_arch}" = x86_64 ] || [ "${docker_arch}" = amd64 ] \
    || fail "AMD64_REQUIRED: docker architecture is ${docker_arch}"
rustup target list --installed | grep -Fxq x86_64-unknown-linux-musl \
    || fail 'MISSING_PREREQUISITE: rust target x86_64-unknown-linux-musl'

actual_unit_sha256="$(sha256sum "${app_unit}" | awk '{print $1}')"
[ "${actual_unit_sha256}" = "${app_unit_sha256}" ] \
    || fail "APP_UNIT_DRIFT: expected ${app_unit_sha256}, got ${actual_unit_sha256}"

git clone --quiet "${runtime_repository}" "${runtime}"
git -C "${runtime}" checkout --quiet --detach "${runtime_sha}"
[ "$(git -C "${runtime}" rev-parse HEAD)" = "${runtime_sha}" ] \
    || fail 'RUNTIME_SHA_MISMATCH'

CARGO_TARGET_DIR="${tmp}/target" cargo build \
    --manifest-path "${runtime}/Cargo.toml" \
    --release --locked --target x86_64-unknown-linux-musl \
    -p pf-session-authority -p pf-app-launch

authority_binary="${tmp}/target/x86_64-unknown-linux-musl/release/pf-session-authorityd"
app_launch_binary="${tmp}/target/x86_64-unknown-linux-musl/release/pf-app-launch"
for binary in "${authority_binary}" "${app_launch_binary}"; do
    file "${binary}" | grep -Fq 'x86-64' || fail "NON_AMD64_RUNTIME_BINARY: ${binary}"
    file "${binary}" | grep -Fq 'static-pie linked' || fail "NON_STATIC_RUNTIME_BINARY: ${binary}"
done

docker run --detach \
    --name "${prepare_container}" \
    --network host \
    --platform linux/amd64 \
    "${base_image}" \
    /bin/sh -c 'trap : TERM INT; sleep infinity & wait' >/dev/null

docker exec "${prepare_container}" /bin/sh -ceu '
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        systemd systemd-sysv python3 passwd
    rm -rf /var/lib/apt/lists/*
    for group_name in gamer audio input video; do
        getent group "${group_name}" >/dev/null || groupadd --system "${group_name}"
    done
    getent passwd gamer >/dev/null || useradd --system --gid gamer --no-create-home gamer
    usermod -a -G audio,input,video gamer
    install -d -m 0755 \
        /etc/systemd/system/pocketforge-foreground.target.d \
        /etc/systemd/system/multi-user.target.wants \
        /opt/pocketforge/apps/org.pocketforge.fixture \
        /usr/lib/tmpfiles.d \
        /usr/share/pocketforge \
        /usr/local/libexec
'

docker cp "${authority_binary}" "${prepare_container}:/usr/bin/pf-session-authorityd"
docker cp "${app_launch_binary}" "${prepare_container}:/usr/bin/pf-app-launch"
docker cp "${runtime}/systemd/pf-session-authorityd.service" \
    "${prepare_container}:/etc/systemd/system/pf-session-authorityd.service"
docker cp "${runtime}/systemd/pocketforge.conf" \
    "${prepare_container}:/usr/lib/tmpfiles.d/pocketforge.conf"
docker cp "${app_unit}" "${prepare_container}:/etc/systemd/system/pf-app@.service"
docker cp "${fixtures}/pocketforge-foreground.target" \
    "${prepare_container}:/etc/systemd/system/pocketforge-foreground.target"
docker cp "${owner_dropin}" \
    "${prepare_container}:/etc/systemd/system/pocketforge-foreground.target.d/10-owner-shell.conf"
docker cp "${fixtures}/pf-shell-selected.service" \
    "${prepare_container}:/etc/systemd/system/pf-shell-selected.service"
docker cp "${fixtures}/app.toml" \
    "${prepare_container}:/opt/pocketforge/apps/org.pocketforge.fixture/app.toml"
docker cp "${fixtures}/fixture" \
    "${prepare_container}:/opt/pocketforge/apps/org.pocketforge.fixture/fixture"
docker cp "${fixtures}/platform-capabilities.toml" \
    "${prepare_container}:/usr/share/pocketforge/platform-capabilities.toml"
docker cp "${fixtures}/drive.py" "${prepare_container}:/usr/local/libexec/drive.py"

docker exec "${prepare_container}" /bin/sh -ceu '
    chmod 0755 /usr/bin/pf-session-authorityd /usr/bin/pf-app-launch
    chmod 0644 \
        /etc/systemd/system/pf-session-authorityd.service \
        /etc/systemd/system/pf-app@.service \
        /etc/systemd/system/pocketforge-foreground.target \
        /etc/systemd/system/pocketforge-foreground.target.d/10-owner-shell.conf \
        /etc/systemd/system/pf-shell-selected.service \
        /usr/lib/tmpfiles.d/pocketforge.conf \
        /usr/share/pocketforge/platform-capabilities.toml \
        /opt/pocketforge/apps/org.pocketforge.fixture/app.toml
    chmod 0755 /opt/pocketforge/apps/org.pocketforge.fixture/fixture
    chmod 0755 /usr/local/libexec/drive.py
    ln -s ../pf-session-authorityd.service \
        /etc/systemd/system/multi-user.target.wants/pf-session-authorityd.service
    ln -s ../pf-shell-selected.service \
        /etc/systemd/system/multi-user.target.wants/pf-shell-selected.service
'

container_unit_sha256="$(
    docker exec "${prepare_container}" sha256sum /etc/systemd/system/pf-app@.service \
        | awk '{print $1}'
)"
[ "${container_unit_sha256}" = "${app_unit_sha256}" ] \
    || fail "CONTAINER_APP_UNIT_DRIFT: got ${container_unit_sha256}"

test_image_digest="$(docker commit --no-pause "${prepare_container}" "${test_image}")"
image_created=1
docker rm -f "${prepare_container}" >/dev/null

docker run --detach \
    --name "${systemd_container}" \
    --hostname tsp-f3fm-209-systemd \
    --privileged \
    --cgroupns private \
    --network host \
    --platform linux/amd64 \
    --tmpfs /run \
    --tmpfs /run/lock \
    --env container=docker \
    "${test_image}" \
    /sbin/init >/dev/null

systemd_ready=0
for _ in $(seq 1 80); do
    if docker exec "${systemd_container}" /bin/sh -c '
        [ "$(cat /proc/1/comm)" = systemd ] \
            && systemctl show --property Version --value >/dev/null \
            && systemctl is-active --quiet pf-session-authorityd.service \
            && systemctl is-active --quiet pf-shell-selected.service
    ' >/dev/null 2>&1; then
        systemd_ready=1
        break
    fi
    sleep 0.1
done
if [ "${systemd_ready}" -ne 1 ]; then
    docker logs "${systemd_container}" >&2 || true
    fail 'SYSTEMD_PID1_UNAVAILABLE: privileged amd64 container did not boot a usable systemd PID 1'
fi

if ! test_output="$(
    docker exec "${systemd_container}" /usr/local/libexec/drive.py 2>&1
)"; then
    echo "${test_output}" >&2
    docker exec "${systemd_container}" journalctl --no-pager --output short-monotonic \
        --lines 200 \
        --unit pf-session-authorityd.service \
        --unit pf-app@org.pocketforge.fixture.service \
        --unit pf-shell-selected.service >&2 || true
    fail 'INTEGRATION_ASSERTION_FAILED'
fi
echo "${test_output}"
echo "session-authority real-systemd: PASS runtime_sha=${runtime_sha} container_image_digest=${test_image_digest} fail_closed=SYSTEMD_PID1_UNAVAILABLE"
