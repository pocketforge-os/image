#!/bin/sh
set -eu

# A successful workload after this gate is direct evidence that it fits the
# smallest pf-public VM. Refuse a larger machine so success cannot accidentally
# rely on resources that the committed public class does not promise.
cpu_limit=4
memory_limit_kib=8388608
disk_limit_kib=54525952

fail()
{
    printf 'public_ci_fit=FAIL reason=%s\n' "$1" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail 'docker_missing'
docker buildx version >/dev/null 2>&1 || fail 'docker_buildx_missing'

cpus=$(getconf _NPROCESSORS_ONLN)
memory_kib=$(awk '$1 == "MemTotal:" { print $2; exit }' /proc/meminfo)
runner_temp=${RUNNER_TEMP:-/tmp}
disk_kib=$(df -Pk "$runner_temp" | awk 'NR == 2 { print $2; exit }')

case "$cpus:$memory_kib:$disk_kib" in
    *[!0-9:]* | *::* | :* | *:) fail 'resource_probe_invalid' ;;
esac
test "$cpus" -le "$cpu_limit" || fail "cpu_exceeds_${cpu_limit}"
test "$memory_kib" -le "$memory_limit_kib" || fail "memory_exceeds_${memory_limit_kib}kib"
test "$disk_kib" -le "$disk_limit_kib" || fail "disk_exceeds_${disk_limit_kib}kib"

printf '%s\n' \
    "public_ci_fit=PASS cpus=$cpus memory_kib=$memory_kib disk_kib=$disk_kib limits=4vcpu,8gib,52gib tools=docker,buildx persistent_cache=none"
