#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
header_sha=eef274664360cac95c7087a3a1ac0be960710eee8eea77768340fa1f80ba79ef
fixture_sha=538fce952f5de6cb901c46c1919aedc44dcd436e753f7786c1a6e5fe21ad2fb9
[[ "$(sha256sum "$root/tools/pf_uinput_domain_guard.h" | awk '{print $1}')" == "$header_sha" ]]
[[ "$(sha256sum "$root/selftest/uinput-domain-v1.tsv" | awk '{print $1}')" == "$fixture_sha" ]]
grep -Fqx 'runtime_commit=bb923b328eced983daef2210aded6febe3ce2fdf' "$root/selftest/uinput-domain-v1.SOURCE"
grep -Fqx "guard_sha256=$header_sha" "$root/selftest/uinput-domain-v1.SOURCE"
grep -Fqx "fixture_sha256=$fixture_sha" "$root/selftest/uinput-domain-v1.SOURCE"

tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/fake-input-guard.XXXXXX")"
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT
cc -std=c11 -Wall -Wextra -Werror -Wno-unused-function \
  -I"$root/tools" "$root/selftest/fake_input_guard_test.c" -o "$tmp/test"
"$tmp/test" "$root/selftest/uinput-domain-v1.tsv"
