#!/usr/bin/env bash
# A-CTS one-hop CTS-profile boot. gpu-14 owns live execution.
set -euo pipefail
export LC_ALL=C

usage() {
    echo 'usage: direct-boot.sh RECEIPT ((--list NAME ... | --caselist FILE) | --probe-only default|etc-matrix|discriminate-layout|vk-copy-layout|vk-compute-layout|vk-compute-etc1|all) [--render-only|--offline-only]' >&2
    exit 2
}

[[ $# -ge 2 ]] || usage
R=$1; shift
K=$(cd "$(dirname "$0")" && pwd)
ID=${PF_ACTS_BEAD_ID:?PF_ACTS_BEAD_ID is required}
IMAGE=${PF_ACTS_IMAGE:?PF_ACTS_IMAGE is required}
MODE=live
(cd "$K" && sha256sum -c --quiet SHA256SUMS) || { echo 'A_CTS_ERROR reason=kit_manifest' >&2; exit 1; }
declare -a REQUEST=()
custom_file=
probe_only=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) [[ $# -ge 2 ]] || usage; REQUEST+=("list" "$2"); shift 2 ;;
        --caselist) [[ $# -ge 2 ]] || usage; [[ -z "$custom_file" && ${#REQUEST[@]} -eq 0 ]] || usage; custom_file=$2; REQUEST+=("caselist" "$(basename "$2")"); shift 2 ;;
        --probe-only) [[ $# -ge 2 && -z $probe_only ]] || usage; probe_only=$2; shift 2 ;;
        --render-only) MODE=render; shift ;;
        --offline-only) MODE=offline; shift ;;
        *) usage ;;
    esac
done
if [[ -n $probe_only ]]; then
    [[ ${#REQUEST[@]} -eq 0 ]] || usage
    case "$probe_only" in
        default) PROBES=(default) ;;
        etc-matrix) PROBES=(etc-matrix) ;;
        discriminate-layout) PROBES=(discriminate-layout) ;;
        vk-copy-layout|vk-compute-layout|vk-compute-etc1) PROBES=("$probe_only") ;;
        all) PROBES=(default etc-matrix discriminate-layout vk-copy-layout vk-compute-layout vk-compute-etc1) ;;
        *) usage ;;
    esac
else
    [[ ${#REQUEST[@]} -gt 0 ]] || usage
    PROBES=(default etc-matrix discriminate-layout vk-copy-layout vk-compute-layout vk-compute-etc1)
fi

if [[ -n "$custom_file" ]]; then
    [[ -s "$custom_file" ]] || { echo 'A_CTS_ERROR reason=caselist_missing' >&2; exit 1; }
    if [[ $(sort "$custom_file" | uniq -d | wc -l) -ne 0 ]]; then
        echo 'A_CTS_ERROR reason=caselist_duplicate' >&2
        exit 1
    fi
    if grep -Eq '(^[[:space:]]*$|[[:space:]])' "$custom_file"; then
        echo 'A_CTS_ERROR reason=caselist_syntax' >&2
        exit 1
    fi
fi

mkdir -p "$R"/{cmds,dut,results/probes,results/egl-preflight,smoke,identity,console,ladder,felboot,teardown,chunks}
request_file=$R/request.tsv
: >"$request_file"
declare -a expanded=()
for ((i=0; i<${#REQUEST[@]}; i+=2)); do
    kind=${REQUEST[i]}; value=${REQUEST[i+1]}
    printf '%s\t%s\n' "$kind" "$value" >>"$request_file"
    if [[ $kind == list && $value == noctx ]]; then
        expanded+=(gles2-khr-noctx-main gles32-khr-noctx-main)
    elif [[ $kind == caselist ]]; then
        expanded+=("caselist:$value")
    else
        expanded+=("$value")
    fi
done
if [[ ${#expanded[@]} -eq 0 ]]; then order=none; else order=$(IFS=,; echo "${expanded[*]}"); fi
probe_order=$(IFS=,; echo "${PROBES[*]}")

render() {
    local name=$1 action=$2 arg=${3:-}
    local encoded
    encoded=$(gzip -n -9 -c "$K/a-cts-dut" | base64 -w0)
    printf "t=\$(mktemp -d /dev/shm/pf-a-cts.XXXXXX) || exit 70; printf '%%s' '%s' | base64 -d | gzip -d > \"\$t/s\" || exit 71; chmod 0755 \"\$t/s\"; PF_ACTS_ROOT=/run/pf-a-cts \"\$t/s\" '%s' '%s'; rc=\$?; find \"\$t\" -mindepth 1 -delete; rmdir \"\$t\"; exit \$rc\n" \
        "$encoded" "$action" "$arg" >"$R/cmds/$name.txt"
}

request_b64=$(base64 -w0 "$request_file")
script_b64=$(gzip -n -9 -c "$K/a-cts-dut" | base64 -w0)
printf "sudo -n install -d -m 0755 /run/pf-a-cts /run/pf-probes; sudo -n find /run/pf-a-cts -mindepth 1 -delete; sudo -n find /run/pf-probes -mindepth 1 -delete; printf '%%s' '%s' | base64 -d | gzip -d | sudo -n tee /run/pf-a-cts/a-cts-dut >/dev/null; sudo -n chmod 0755 /run/pf-a-cts/a-cts-dut; printf '%%s' '%s' | base64 -d | sudo -n tee /run/pf-a-cts/request.tsv >/dev/null; sudo -n chown -R debug:\$(id -g debug) /run/pf-a-cts /run/pf-probes; printf 'A_CTS_STAGE_RESET state=complete owner=debug\\n'\n" \
    "$script_b64" "$request_b64" >"$R/cmds/stage-reset.txt"

split -b 36000 -d -a 4 "$K/pf-surfaceless-gles-probe" "$R/chunks/eglprobe."
for chunk in "$R"/chunks/eglprobe.*; do
    index=${chunk##*.}; sha=$(sha256sum "$chunk" | cut -d' ' -f1); bytes=$(stat -c %s "$chunk")
    printf "t=\$(mktemp -d /dev/shm/pf-a-cts-eglprobe.XXXXXX) || exit 70; printf '%%s' '%s' | base64 -d > \"\$t/c\"; [ \"\$(sha256sum \"\$t/c\" | cut -d' ' -f1)\" = '%s' ] || exit 72; [ \"\$(wc -c <\"\$t/c\")\" = '%s' ] || exit 73; sudo -n tee -a /run/pf-probes/pf-surfaceless-gles-probe <\"\$t/c\" >/dev/null; printf 'A_CTS_EGL_PROBE_CHUNK index=%s sha256=%s bytes=%s\\n'; find \"\$t\" -mindepth 1 -delete; rmdir \"\$t\"\n" \
        "$(base64 -w0 "$chunk")" "$sha" "$bytes" "$index" "$sha" "$bytes" >"$R/cmds/eglprobe-chunk-$index.txt"
done
printf "[ \"\$(sha256sum /run/pf-probes/pf-surfaceless-gles-probe | cut -d' ' -f1)\" = '8c5a5d3f009af537e0f4a3358de9ed19dcaf5f6b4b1fecec5cac2d463880e35b' ] || { printf 'A_CTS_ERROR mode=egl-probe-stage reason=binary_sha\\n' >&2; exit 74; }; sudo -n chmod 0755 /run/pf-probes/pf-surfaceless-gles-probe; printf 'A_CTS_EGL_PROBE_STAGE state=complete sha256=8c5a5d3f009af537e0f4a3358de9ed19dcaf5f6b4b1fecec5cac2d463880e35b bytes=86736\\n'\n" \
    >"$R/cmds/eglprobe-finalize.txt"

split -b 36000 -d -a 4 "$K/pf-pvr-texcomp-probe" "$R/chunks/probe."
for chunk in "$R"/chunks/probe.*; do
    index=${chunk##*.}; sha=$(sha256sum "$chunk" | cut -d' ' -f1); bytes=$(stat -c %s "$chunk")
    printf "t=\$(mktemp -d /dev/shm/pf-a-cts-probe.XXXXXX) || exit 70; printf '%%s' '%s' | base64 -d > \"\$t/c\"; [ \"\$(sha256sum \"\$t/c\" | cut -d' ' -f1)\" = '%s' ] || exit 72; [ \"\$(wc -c <\"\$t/c\")\" = '%s' ] || exit 73; sudo -n tee -a /run/pf-a-cts/pf-pvr-texcomp-probe <\"\$t/c\" >/dev/null; printf 'A_CTS_PROBE_CHUNK index=%s sha256=%s bytes=%s\\n'; find \"\$t\" -mindepth 1 -delete; rmdir \"\$t\"\n" \
        "$(base64 -w0 "$chunk")" "$sha" "$bytes" "$index" "$sha" "$bytes" >"$R/cmds/probe-chunk-$index.txt"
done
printf "[ \"\$(sha256sum /run/pf-a-cts/pf-pvr-texcomp-probe | cut -d' ' -f1)\" = '993aabc47acb52c4d8af61113507091097c6cb1b84dc4d06b312c96f508dbab8' ] || { printf 'A_CTS_ERROR mode=probe-stage reason=binary_sha\\n' >&2; exit 74; }; sudo -n chmod 0755 /run/pf-a-cts/pf-pvr-texcomp-probe; printf 'A_CTS_PROBE_STAGE state=complete sha256=993aabc47acb52c4d8af61113507091097c6cb1b84dc4d06b312c96f508dbab8 bytes=217048\\n'\n" \
    >"$R/cmds/probe-finalize.txt"

split -b 36000 -d -a 4 "$K/pf-pvr-texcomp-discrim-probe" "$R/chunks/discrim."
for chunk in "$R"/chunks/discrim.*; do
    index=${chunk##*.}; sha=$(sha256sum "$chunk" | cut -d' ' -f1); bytes=$(stat -c %s "$chunk")
    printf "t=\$(mktemp -d /dev/shm/pf-a-cts-discrim.XXXXXX) || exit 70; printf '%%s' '%s' | base64 -d > \"\$t/c\"; [ \"\$(sha256sum \"\$t/c\" | cut -d' ' -f1)\" = '%s' ] || exit 72; [ \"\$(wc -c <\"\$t/c\")\" = '%s' ] || exit 73; sudo -n tee -a /run/pf-probes/pf-pvr-texcomp-probe <\"\$t/c\" >/dev/null; printf 'A_CTS_DISCRIM_CHUNK index=%s sha256=%s bytes=%s\\n'; find \"\$t\" -mindepth 1 -delete; rmdir \"\$t\"\n" \
        "$(base64 -w0 "$chunk")" "$sha" "$bytes" "$index" "$sha" "$bytes" >"$R/cmds/discrim-chunk-$index.txt"
done
printf "[ \"\$(sha256sum /run/pf-probes/pf-pvr-texcomp-probe | cut -d' ' -f1)\" = '97e87bce16b827099811d2c428606caf1dd009bf176e235fc42686d54dd0d413' ] || { printf 'A_CTS_ERROR mode=discrim-stage reason=binary_sha\\n' >&2; exit 74; }; sudo -n chmod 0755 /run/pf-probes/pf-pvr-texcomp-probe; printf 'A_CTS_DISCRIM_STAGE state=complete sha256=97e87bce16b827099811d2c428606caf1dd009bf176e235fc42686d54dd0d413 bytes=237656\\n'\n" \
    >"$R/cmds/discrim-finalize.txt"

split -b 36000 -d -a 4 "$K/pf-pvr-vk-tex-discriminator" "$R/chunks/vkprobe."
for chunk in "$R"/chunks/vkprobe.*; do
    index=${chunk##*.}; sha=$(sha256sum "$chunk" | cut -d' ' -f1); bytes=$(stat -c %s "$chunk")
    printf "t=\$(mktemp -d /dev/shm/pf-a-cts-vkprobe.XXXXXX) || exit 70; printf '%%s' '%s' | base64 -d > \"\$t/c\"; [ \"\$(sha256sum \"\$t/c\" | cut -d' ' -f1)\" = '%s' ] || exit 72; [ \"\$(wc -c <\"\$t/c\")\" = '%s' ] || exit 73; sudo -n tee -a /run/pf-probes/pf-pvr-vk-tex-discriminator <\"\$t/c\" >/dev/null; printf 'A_CTS_VK_PROBE_CHUNK index=%s sha256=%s bytes=%s\\n'; find \"\$t\" -mindepth 1 -delete; rmdir \"\$t\"\n" \
        "$(base64 -w0 "$chunk")" "$sha" "$bytes" "$index" "$sha" "$bytes" >"$R/cmds/vkprobe-chunk-$index.txt"
done
printf "[ \"\$(sha256sum /run/pf-probes/pf-pvr-vk-tex-discriminator | cut -d' ' -f1)\" = '2a56e1c8f2e9b9933c495494bfa6dad42785494d5abd91bfaec247f0e3e14102' ] || { printf 'A_CTS_ERROR mode=vkprobe-stage reason=binary_sha\\n' >&2; exit 74; }; sudo -n chmod 0755 /run/pf-probes/pf-pvr-vk-tex-discriminator; printf 'A_CTS_VK_PROBE_STAGE state=complete sha256=2a56e1c8f2e9b9933c495494bfa6dad42785494d5abd91bfaec247f0e3e14102 bytes=308160\\n'\n" \
    >"$R/cmds/vkprobe-finalize.txt"

if [[ -n "$custom_file" ]]; then
    split -b 36000 -d -a 4 "$custom_file" "$R/chunks/caselist."
    for chunk in "$R"/chunks/caselist.*; do
        index=${chunk##*.}; sha=$(sha256sum "$chunk" | cut -d' ' -f1); bytes=$(stat -c %s "$chunk")
        printf "t=\$(mktemp -d /dev/shm/pf-a-cts-list.XXXXXX) || exit 70; printf '%%s' '%s' | base64 -d > \"\$t/c\"; [ \"\$(sha256sum \"\$t/c\" | cut -d' ' -f1)\" = '%s' ] || exit 72; [ \"\$(wc -c <\"\$t/c\")\" = '%s' ] || exit 73; cat \"\$t/c\" >>/run/pf-a-cts/input.caselist; printf 'A_CTS_LIST_CHUNK index=%s sha256=%s bytes=%s\\n'; find \"\$t\" -mindepth 1 -delete; rmdir \"\$t\"\n" \
            "$(base64 -w0 "$chunk")" "$sha" "$bytes" "$index" "$sha" "$bytes" >"$R/cmds/list-chunk-$index.txt"
    done
fi
for probe in "${PROBES[@]}"; do
    render "probe-$probe-start" probe-start "$probe"
    render "probe-$probe-poll" probe-poll "$probe"
    render "probe-$probe-receipt" probe-receipt "$probe"
done
render gpu-health-baseline gpu-health baseline
for probe in "${PROBES[@]}"; do render "gpu-health-$probe" gpu-health "$probe"; done
render egl-preflight egl-preflight
render egl-preflight-receipt egl-preflight-receipt
render smoke-collect-egl-preflight-chunk-0 egl-preflight-chunk 0
render smoke-collect-probe-chunk-0 probe-chunk default:0
render smoke-collect-archive-chunk-0 archive-chunk 0
for action in prepare worker-start worker-poll worker-finalize archive-receipt cleanup; do render "$action" "$action"; done
printf '/usr/bin/id\n' >"$R/cmds/identity.txt"
printf 'ls -1 /sys/class/drm\n' >"$R/cmds/drm-class.txt"
(cd "$R/cmds" && sha256sum ./*.txt >../cmds.sha256)

for command in "$R"/cmds/*.txt; do
    [[ $(wc -c <"$command") -lt 60000 ]] || { echo "A_CTS_ERROR reason=request_too_large file=$command" >&2; exit 1; }
done

if [[ $MODE == offline ]]; then
    printf 'A_CTS_OFFLINE state=pass selectors=%s order=%s probes=%s\n' "${#expanded[@]}" "$order" "$probe_order"
    exit 0
fi

smoke_line=$(env -u PF_BEAD -u LG_USERNAME "$K/smoke.sh" "$IMAGE" "$R" 2>"$R/smoke/stderr" | tail -1)
[[ $smoke_line == 'SMOKE PASS'* ]] || { echo "A_CTS_ERROR reason=smoke line=$smoke_line" >&2; exit 1; }
if [[ $MODE == render ]]; then
    printf 'A_CTS_RENDER_ONLY state=pass order=%s probes=%s no_device_actions=yes\n' "$order" "$probe_order"
    exit 0
fi

F=http://pf-node-01.lan:8095
SYS=$F/redfish/v1/Systems/tsp-base
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 matt@pf-node-01.lan)
export PF_HOLD_ID=$ID
STAGE=preconditions; VERDICT=na; TEARDOWN=not_needed; HELD=0
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$R/run.log"; }
headers() { printf 'Authorization: Bearer %s\nX-PocketForge-Agent: %s\nContent-Type: application/json\n' "$(pf-secret get lab/pf-redfish-node-01)" "$ID"; }
post() {
    local url=$1 body=$2 prefix=$3 timeout=${4:-90}
    curl -sS -m "$timeout" -D "$prefix.headers" -o "$prefix.json" -w '%{http_code}' \
        -X POST -H @<(headers) --data-binary @"$body" "$url" 2>"$prefix.curl-stderr" || echo curl_fail
}
dutexec() {
    local name=$1 timeout=$2 command=$3 code identity_pattern stdout_file
    if (( timeout < 1 || timeout > 300 )); then
        printf 'A_CTS_ERROR stage=%s reason=redfish_timeout_bound timeout=%s\n' "$name" "$timeout" >&2
        return 64
    fi
    {
        # shellcheck disable=SC2016
        printf 'printf '\''A_CTS_DUTEXEC_IDENTITY step=%s user=%%s uid=%%s\\n'\'' "$(/usr/bin/id -un)" "$(/usr/bin/id -u)"\n' "$name"
        cat "$command"
    } | jq -Rs --argjson t "$timeout" '{Command:.,TimeoutSeconds:$t}' \
        >"$R/dut/$name.body.json"
    code=$(post "$SYS/Actions/Oem/PocketForge.DutExec" "$R/dut/$name.body.json" "$R/dut/$name" "$((timeout + 40))")
    echo "$code" >"$R/dut/$name.http"
    [[ $code == 200 ]] || return 1
    stdout_file=$R/dut/$name.stdout
    jq -j '.Stdout // ""' "$R/dut/$name.json" | tr -d '\r' >"$stdout_file"
    jq -j '.Stderr // ""' "$R/dut/$name.json" | tr -d '\r' >"$R/dut/$name.stderr"
    identity_pattern="^A_CTS_DUTEXEC_IDENTITY step=$name user=debug uid=1001$"
    "$K/response-select" "dutexec-$name-identity" "$identity_pattern" "$stdout_file" \
        >"$R/dut/$name.identity" || return 1
    jq -e '.ExitCode == 0 and .TimedOut == false' "$R/dut/$name.json" >/dev/null \
        || return 1
}
pull_egl_preflight() {
    local remote archive_sha archive_bytes count index chunk_name archive producer_rc verify_rc
    STAGE=egl-preflight
    set +e
    dutexec egl-preflight 300 "$R/cmds/egl-preflight.txt"
    producer_rc=$?
    set -e
    if [[ -r $R/dut/egl-preflight.stdout && -r $R/dut/egl-preflight.stderr ]]; then
        cp "$R/dut/egl-preflight.stdout" "$R/results/egl-preflight/run.stdout"
        cp "$R/dut/egl-preflight.stderr" "$R/results/egl-preflight/run.stderr"
    else
        printf 'unavailable\n' >"$R/results/egl-preflight/run.stdout"
        printf 'unavailable\n' >"$R/results/egl-preflight/run.stderr"
    fi

    STAGE=egl-preflight-receipt
    dutexec egl-preflight-receipt 30 "$R/cmds/egl-preflight-receipt.txt" \
        || stop egl-preflight-receipt
    remote=$R/results/egl-preflight/archive.receipt.remote
    cp "$R/dut/egl-preflight-receipt.stdout" "$remote"
    archive_sha=$("$K/response-select" egl-preflight-receipt-sha \
        '^sha256=[0-9a-f]{64}$' "$remote") || stop egl-preflight-receipt-format
    archive_bytes=$("$K/response-select" egl-preflight-receipt-bytes \
        '^bytes=[0-9]+$' "$remote") || stop egl-preflight-receipt-format
    archive_sha=${archive_sha#sha256=}
    archive_bytes=${archive_bytes#bytes=}
    count=$(((archive_bytes + 35999) / 36000))
    archive=$R/results/egl-preflight/results.tar.gz
    : >"$archive"
    for ((index=0; index<count; index++)); do
        chunk_name=egl-preflight-chunk-$index
        render "$chunk_name" egl-preflight-chunk "$index"
        STAGE=$chunk_name
        dutexec "$chunk_name" 30 "$R/cmds/$chunk_name.txt" || stop "$chunk_name"
        cp "$R/dut/$chunk_name.stdout" "$R/results/egl-preflight/chunk.remote"
        "$K/collect-response-chunk" "$chunk_name" \
            "$R/results/egl-preflight/chunk.remote" \
            "$R/results/egl-preflight/chunk.bin" \
            >"$R/results/egl-preflight/chunk.host-result" \
            || stop egl-preflight-chunk-parse
        cat "$R/results/egl-preflight/chunk.bin" >>"$archive"
    done
    find "$R/results/egl-preflight/chunk.bin" "$R/results/egl-preflight/chunk.remote" \
        -maxdepth 0 -type f -delete
    [[ $(wc -c <"$archive") == "$archive_bytes" ]] || stop egl-preflight-archive-bytes
    [[ $(sha256sum "$archive" | cut -d' ' -f1) == "$archive_sha" ]] \
        || stop egl-preflight-archive-sha
    mkdir -p "$R/results/egl-preflight/unpacked"
    tar -xzf "$archive" -C "$R/results/egl-preflight/unpacked" \
        || stop egl-preflight-archive-unpack
    set +e
    "$K/verify-egl-preflight.sh" "$R/results/egl-preflight/unpacked" \
        >"$R/results/egl-preflight/host-result.txt" \
        2>"$R/results/egl-preflight/host-verifier.stderr"
    verify_rc=$?
    set -e
    tee -a "$R/run.log" <"$R/results/egl-preflight/host-result.txt"
    if [[ $producer_rc -ne 0 ]]; then
        stop "egl-preflight-producer-status rc=$producer_rc evidence=verified"
    fi
    case "$verify_rc" in
        0) ;;
        42) stop 'egl-preflight-candidate-failed evidence=verified' ;;
        *) stop "egl-preflight-host-verification rc=$verify_rc" ;;
    esac
}

collect_worker_results() {
    local expected_outcome=$1 remote archive_sha archive_bytes chunks index outcome_line outcome verify_rc
    STAGE=worker-finalize
    dutexec worker-finalize 300 "$R/cmds/worker-finalize.txt" || stop worker-finalize
    # This is a stage label, not arithmetic.
    # shellcheck disable=SC2100
    STAGE=archive-receipt
    dutexec archive-receipt 30 "$R/cmds/archive-receipt.txt" || stop archive-receipt
    remote=$R/results/archive.receipt.remote
    cp "$R/dut/archive-receipt.stdout" "$remote"
    archive_sha=$("$K/response-select" archive-receipt-sha \
        '^sha256=[0-9a-f]{64}$' "$remote") || stop archive-receipt-format
    archive_bytes=$("$K/response-select" archive-receipt-bytes \
        '^bytes=[0-9]+$' "$remote") || stop archive-receipt-format
    archive_sha=${archive_sha#sha256=}
    archive_bytes=${archive_bytes#bytes=}
    chunks=$(((archive_bytes + 35999) / 36000))
    : >"$R/results/results.tar.gz"
    for ((index=0; index<chunks; index++)); do
        render "archive-chunk-$index" archive-chunk "$index"
        STAGE="archive-chunk-$index"
        dutexec "archive-chunk-$index" 30 "$R/cmds/archive-chunk-$index.txt" \
            || stop "$STAGE"
        cp "$R/dut/archive-chunk-$index.stdout" "$R/results/chunk.remote"
        "$K/collect-response-chunk" "archive-chunk-$index" \
            "$R/results/chunk.remote" "$R/results/chunk.bin" \
            >"$R/results/chunk.host-result" || stop chunk-parse
        cat "$R/results/chunk.bin" >>"$R/results/results.tar.gz"
    done
    find "$R/results/chunk.bin" "$R/results/chunk.remote" -maxdepth 0 -type f -delete
    [[ $(wc -c <"$R/results/results.tar.gz") == "$archive_bytes" ]] || stop archive-bytes
    [[ $(sha256sum "$R/results/results.tar.gz" | cut -d' ' -f1) == "$archive_sha" ]] \
        || stop archive-sha
    mkdir -p "$R/results/unpacked"
    tar -xzf "$R/results/results.tar.gz" -C "$R/results/unpacked" || stop archive-unpack
    set +e
    "$K/verify-results.sh" "$R/results/unpacked" \
        >"$R/results/host-verifier.txt" 2>"$R/results/host-verifier.stderr"
    verify_rc=$?
    set -e
    if [[ $verify_rc -ne 0 ]]; then
        tee -a "$R/run.log" <"$R/results/host-verifier.txt"
        tee -a "$R/run.log" <"$R/results/host-verifier.stderr" >&2
        stop "worker-verdict-invalid rc=$verify_rc archive_sha256=$archive_sha archive_bytes=$archive_bytes evidence=collected"
    fi
    outcome_line=$("$K/response-select" worker-run-outcome \
        '^outcome=(complete|complete_with_harness_error|partial)( .*)?$' \
        "$R/results/unpacked/run-outcome.txt") || stop worker-outcome-cardinality
    outcome=${outcome_line#outcome=}; outcome=${outcome%% *}
    case "$expected_outcome:$outcome" in
        complete:complete|complete:complete_with_harness_error|partial:partial) ;;
        *) stop "worker-outcome expected=$expected_outcome actual=$outcome evidence=verified" ;;
    esac
    printf 'A_CTS_RESULTS_HOST expected=%s outcome=%s sha256=%s bytes=%s evidence=verified\n' \
        "$expected_outcome" "$outcome" "$archive_sha" "$archive_bytes" | tee -a "$R/run.log"
}
probe_host_invalid() {
    local probe=$1 reason=$2
    printf 'A_CTS_PROBE_HOST probe=%s verdict=invalid reason=%s continued=yes\n' "$probe" "$reason" \
        | tee "$R/results/probes/$probe.host-result.txt" | tee -a "$R/run.log"
}
pull_probe() {
    local probe=$1 budget=$2 start_name=probe-$1-start poll_name=probe-$1-poll receipt_name=probe-$1-receipt
    local remote archive_sha archive_bytes count index chunk_name result_file value file field pair state deadline summary_status summary_layers progress_line
    STAGE=$start_name
    if ! dutexec "$start_name" 30 "$R/cmds/$start_name.txt"; then
        if [[ -r $R/dut/$start_name.stdout && -r $R/dut/$start_name.stderr ]]; then
            cp "$R/dut/$start_name.stdout" "$R/results/probes/$probe.run.stdout"
            cp "$R/dut/$start_name.stderr" "$R/results/probes/$probe.run.stderr"
        fi
        probe_host_invalid "$probe" start_transport
        return 0
    fi
    cp "$R/dut/$start_name.stdout" "$R/results/probes/$probe.run.stdout"
    cp "$R/dut/$start_name.stderr" "$R/results/probes/$probe.run.stderr"
    deadline=$((SECONDS + budget + 60))
    state=running
    while (( SECONDS < deadline )); do
        sleep 5
        STAGE=$poll_name
        if ! dutexec "$poll_name" 30 "$R/cmds/$poll_name.txt"; then
            probe_host_invalid "$probe" poll_transport
            return 0
        fi
        cp "$R/dut/$poll_name.stdout" "$R/results/probes/$probe.poll.stdout"
        if ! progress_line=$("$K/response-select" "$poll_name-progress" \
            "^A_CTS_PROBE_PROGRESS probe=$probe state=(running|complete) timeout_s=[0-9]+$" \
            "$R/results/probes/$probe.poll.stdout"); then
            probe_host_invalid "$probe" poll_response_cardinality
            return 0
        fi
        state=${progress_line#* state=}; state=${state%% *}
        [[ $state == complete ]] && break
        [[ $state == running ]] || { probe_host_invalid "$probe" poll_state; return 0; }
    done
    if [[ $state != complete ]]; then
        probe_host_invalid "$probe" host_deadline
        return 0
    fi

    STAGE=$receipt_name
    if ! dutexec "$receipt_name" 30 "$R/cmds/$receipt_name.txt"; then
        probe_host_invalid "$probe" receipt_transport
        return 0
    fi
    remote=$R/results/probes/$probe.receipt.remote
    cp "$R/dut/$receipt_name.stdout" "$remote"
    if ! archive_sha=$("$K/response-select" "$receipt_name-sha" \
        '^sha256=[0-9a-f]{64}$' "$remote") ||
       ! archive_bytes=$("$K/response-select" "$receipt_name-bytes" \
        '^bytes=[0-9]+$' "$remote"); then
        probe_host_invalid "$probe" receipt_format
        return 0
    fi
    archive_sha=${archive_sha#sha256=}
    archive_bytes=${archive_bytes#bytes=}
    count=$(((archive_bytes + 35999) / 36000))
    archive=$R/results/probes/$probe.results.tar.gz
    : >"$archive"
    for ((index=0; index<count; index++)); do
        chunk_name=probe-$probe-chunk-$index
        render "$chunk_name" probe-chunk "$probe:$index"
        STAGE=$chunk_name
        if ! dutexec "$chunk_name" 30 "$R/cmds/$chunk_name.txt"; then
            probe_host_invalid "$probe" chunk_transport_$index
            return 0
        fi
        cp "$R/dut/$chunk_name.stdout" "$R/results/probes/$probe.chunk.remote"
        if ! "$K/collect-response-chunk" "$chunk_name" \
            "$R/results/probes/$probe.chunk.remote" \
            "$R/results/probes/$probe.chunk.bin" \
            >"$R/results/probes/$probe.chunk.host-result"; then
            probe_host_invalid "$probe" chunk_parse_$index
            return 0
        fi
        cat "$R/results/probes/$probe.chunk.bin" >>"$archive"
    done
    find "$R/results/probes/$probe.chunk.bin" "$R/results/probes/$probe.chunk.remote" \
        -maxdepth 0 -type f -delete
    if [[ $(wc -c <"$archive") != "$archive_bytes" ||
          $(sha256sum "$archive" | cut -d' ' -f1) != "$archive_sha" ]]; then
        probe_host_invalid "$probe" archive_identity
        return 0
    fi
    mkdir -p "$R/results/probes/$probe"
    if ! tar -xzf "$archive" -C "$R/results/probes/$probe"; then
        probe_host_invalid "$probe" archive_unpack
        return 0
    fi
    result_file=$R/results/probes/$probe/result.txt
    if [[ ! -s $result_file || ! -s $R/results/probes/$probe/maps ||
          ! -s $R/results/probes/$probe/counters.pre || ! -s $R/results/probes/$probe/counters.post ]]; then
        probe_host_invalid "$probe" evidence_missing
        return 0
    fi
    for pair in stdout:stdout_sha256 stderr:stderr_sha256 environment:environment_sha256 maps:maps_sha256 \
                counters.pre:counters_pre_sha256 counters.post:counters_post_sha256; do
        file=${pair%%:*}; field=${pair#*:}
        value=$(sed -n "s/.* $field=\\([0-9a-f]\\{64\\}\\).*/\\1/p" "$result_file")
        if [[ $(sha256sum "$R/results/probes/$probe/$file" | cut -d' ' -f1) != "$value" ]]; then
            probe_host_invalid "$probe" "evidence_sha_$file"
            return 0
        fi
    done
    case "$probe" in
        discriminate-layout) expected_binary_sha=97e87bce16b827099811d2c428606caf1dd009bf176e235fc42686d54dd0d413 ;;
        vk-copy-layout|vk-compute-layout|vk-compute-etc1) expected_binary_sha=2a56e1c8f2e9b9933c495494bfa6dad42785494d5abd91bfaec247f0e3e14102 ;;
        *) expected_binary_sha=993aabc47acb52c4d8af61113507091097c6cb1b84dc4d06b312c96f508dbab8 ;;
    esac
    if ! grep -q " binary_sha256=$expected_binary_sha " "$result_file"; then
        probe_host_invalid "$probe" binary_sha
        return 0
    fi
    if [[ $probe == discriminate-layout ]]; then
        if [[ $(grep -Ec '^TEXCOMP_DISCRIM verdict=(readback_wrong|sampling_wrong|both_wrong|both_ok|unmeasured) fixtures=10 fixtures_completed=[0-9]+ layers=[0-9]+ readback_failures=[0-9]+ sampling_failures=[0-9]+ runtime_ms=[0-9]+ runtime_bound_ms=30000 status=(complete|invalid|timeout)$' \
                    "$R/results/probes/$probe/stdout") -ne 1 ]]; then
            if ! grep -Eq ' discrim=(blocked|unmeasured) reason=(missing_summary|timeout) ' "$result_file"; then
                probe_host_invalid "$probe" discriminator_incomplete
                return 0
            fi
        fi
        if ! grep -Eq ' discrim=(blocked|unmeasured|readback_wrong|sampling_wrong|both_wrong|both_ok) reason=(none|timeout|missing_summary|status_(invalid|timeout)|verdict_unmeasured|layers_zero|exit_[0-9]+) ' "$result_file"; then
            probe_host_invalid "$probe" discriminator_result
            return 0
        fi
        summary_status=$(sed -n 's/^TEXCOMP_DISCRIM .* status=\([^ ]*\)$/\1/p' "$R/results/probes/$probe/stdout")
        summary_layers=$(sed -n 's/^TEXCOMP_DISCRIM .* layers=\([0-9][0-9]*\) .*/\1/p' "$R/results/probes/$probe/stdout")
        if [[ -n $summary_status && ( $summary_status != complete || $summary_layers == 0 ) ]]; then
            if ! grep -Eq ' discrim=unmeasured .* observed_discrim=unmeasured ' "$result_file"; then
                probe_host_invalid "$probe" discriminator_hypothesis_without_measurement
                return 0
            fi
        fi
    elif [[ $probe == vk-copy-layout || $probe == vk-compute-layout || $probe == vk-compute-etc1 ]]; then
        mode=${probe#vk-}
        if [[ $(grep -Ec "^PVR_VK_PROBE mode=$mode verdict=(pass|fail|unmeasured) fixtures=[0-9]+ passed=[0-9]+ failed=[0-9]+ status=(complete|invalid)$" \
                    "$R/results/probes/$probe/stdout") -ne 1 ]] &&
           ! grep -Eq ' discrim=unmeasured reason=(timeout|missing_summary) ' "$result_file"; then
            probe_host_invalid "$probe" vk_summary
            return 0
        fi
    elif [[ $probe == etc-matrix ]]; then
        if [[ $(grep -c '^PF_TEXCOMP_MATRIX_CASE ' "$R/results/probes/$probe/stdout") -ne 396 ]] ||
           ! grep -Eq '^PF_TEXCOMP_MATRIX_SUMMARY passed=[0-9]+ failed=[0-9]+ total=396 tolerance=1 reference_self=(pass|fail) seeded_negative=(pass|fail)$' \
               "$R/results/probes/$probe/stdout"; then
            probe_host_invalid "$probe" matrix_incomplete
            return 0
        fi
    elif ! grep -Eq '^PF_TEXCOMP_RESULT verdict=(pass|fail) controls_passed=-?[0-9]+ controls_required=5$' \
        "$R/results/probes/$probe/stdout"; then
        probe_host_invalid "$probe" default_incomplete
        return 0
    fi
    tee "$R/results/probes/$probe.host-result.txt" <"$result_file" | tee -a "$R/run.log"
    printf 'A_CTS_PROBE_HOST probe=%s transport=pass continued=yes\n' "$probe" | tee -a "$R/run.log"
}
record_gpu_health() {
    local after=$1 name=gpu-health-$1 health_line
    STAGE=$name
    if ! dutexec "$name" 30 "$R/cmds/$name.txt"; then
        printf 'A_CTS_GPU_HEALTH after=%s verdict=check_transport_failed continued=yes\n' "$after" | tee -a "$R/run.log"
        return 0
    fi
    cp "$R/dut/$name.stdout" "$R/results/$name.txt"
    if ! health_line=$("$K/response-select" "$name-result" \
        "^A_CTS_GPU_HEALTH after=$after reset_fault_delta=([0-9]+|unknown) device_lost=[0-9]+ verdict=(clean|fault_seen) continued=yes$" \
        "$R/results/$name.txt"); then
        printf 'A_CTS_GPU_HEALTH after=%s verdict=invalid_check_output continued=yes\n' "$after" | tee -a "$R/run.log"
    else
        printf '%s\n' "$health_line" | tee -a "$R/run.log"
    fi
}
run_selected_probes() {
    local probe
    record_gpu_health baseline
    for probe in "${PROBES[@]}"; do
        case "$probe" in
            default) pull_probe "$probe" 180 ;;
            etc-matrix) pull_probe "$probe" 600 ;;
            discriminate-layout) pull_probe "$probe" 35 ;;
            vk-copy-layout|vk-compute-layout|vk-compute-etc1) pull_probe "$probe" 5 ;;
        esac
        record_gpu_health "$probe"
    done
}
finish() { log "RESULT stage=$STAGE verdict=$VERDICT teardown=$TEARDOWN"; }
teardown() {
    [[ $HELD == 1 ]] || { finish; return; }
    set +e
    TEARDOWN=ok; log "teardown: begin stage=$STAGE"
    echo '{"ResetType":"GracefulShutdown"}' >"$R/teardown/graceful.body"
    log "graceful http=$(post "$SYS/Actions/ComputerSystem.Reset" "$R/teardown/graceful.body" "$R/teardown/graceful")"
    sleep 40
    echo '{"ResetType":"ForceOff"}' >"$R/teardown/forceoff.body"
    code=$(post "$SYS/Actions/ComputerSystem.Reset" "$R/teardown/forceoff.body" "$R/teardown/forceoff")
    log "forceoff http=$code"; [[ $code == 20? ]] || TEARDOWN="WARN_forceoff_$code"
    "${SSH[@]}" "PF_BEAD=$ID LG_USERNAME=$ID /usr/local/bin/pf-power off" >"$R/teardown/pf-power-off.txt" 2>&1 || TEARDOWN=WARN_pf_power_off
    sleep 5
    PF_BEAD=$ID LG_USERNAME=$ID pf-automation-tool pf-device.sh release tsp >"$R/teardown/place-release.txt" 2>&1
    release_rc=$?
    case "$release_rc" in 0|75) ;; *) TEARDOWN="WARN_place_release_$release_rc" ;; esac
    HELD=0; finish
}
trap teardown EXIT
stop() { log "STOP at $STAGE: $*"; exit 1; }

"$K/status-gate" "$R/identity/place-status.txt" "$R/identity/place-status.stderr" \
    'labgrid place : FREE' pf-automation-tool pf-device.sh status tsp \
    >"$R/identity/place-status-gate.txt" || stop 'place status failed or place not FREE'
[[ $(curl -sS -m 10 "$SYS/Oem/PocketForge/Lease" | jq -r .Held) == false ]] || stop 'lease held'
"$K/status-gate" "$R/identity/power-status.txt" "$R/identity/power-status.stderr" \
    'vbus=cut batt=cut' "${SSH[@]}" 'pf-power status' \
    >"$R/identity/power-status-gate.txt" || stop 'power status failed or relays not cut'

STAGE=hold
PF_BEAD=$ID LG_USERNAME=$ID pf-automation-tool pf-device.sh acquire tsp >"$R/identity/acquire.txt" 2>&1
grep -q "acquired tsp-base as pf-node-01/$ID" "$R/identity/acquire.txt" || stop acquire
HELD=1
PF_BEAD=$ID LG_USERNAME=$ID pf-automation-tool pf-device.sh verify tsp >"$R/identity/verify.txt" 2>&1 || stop verify
echo '{}' >"$R/identity/lease.body"
code=$(post "$SYS/Actions/Oem/PocketForge.LeaseAcquire" "$R/identity/lease.body" "$R/identity/lease-acquire")
[[ $(curl -sS -m 10 "$SYS/Oem/PocketForge/Lease" | jq -r '"\(.Held) \(.Holder)"') == "true $ID" ]] || stop "lease http=$code"

STAGE=ladder
"$K/status-gate" "$R/ladder/stdout" "$R/ladder/stderr" 'LADDER1 OK' \
    "$K/ladder1.sh" "$R/ladder" ladder 75 >"$R/ladder/status-gate.txt" || stop ladder
STAGE=felboot
code=$(post "$SYS/Actions/Oem/PocketForge.FelBoot" "$K/felboot-request.json" "$R/felboot/post" 120)
[[ $code == 202 ]] || stop "felboot http=$code"
location=$(jq -r '."@odata.id"' "$R/felboot/post.json")
terminal=
for _ in $(seq 1 100); do
    sleep 20; curl -sS -m 30 "$F$location" >"$R/felboot/task.json" || continue
    terminal=$(jq -r .TaskState "$R/felboot/task.json")
    [[ $terminal =~ ^(Completed|Exception|Killed|Cancelled|Interrupted)$ ]] && break
done
[[ $terminal == Completed ]] || stop "felboot $terminal"

STAGE=login
if login_gate_out=$("$K/login-gate" "$R" "$ID" "${SSH[@]}" 2>&1); then
    log "$login_gate_out"
else
    login_gate_rc=$?; log "$login_gate_out"; stop "login gate rc=$login_gate_rc"
fi
dutexec identity 15 "$R/cmds/identity.txt" || stop identity
STAGE=identity-receipt
cp "$R/dut/identity.stdout" "$R/identity/dutexec-id.txt"
"$K/response-select" identity-marker \
    '^A_CTS_DUTEXEC_IDENTITY step=identity user=debug uid=1001$' \
    "$R/identity/dutexec-id.txt" >"$R/identity/dutexec-marker.txt" \
    || stop identity-marker
"$K/response-select" identity-value \
    '^uid=1001\(debug\) gid=1001\(debug\) groups=.*' \
    "$R/identity/dutexec-id.txt" >"$R/identity/dutexec-value.txt" \
    || stop identity-value
sha256sum "$R/identity/dutexec-id.txt" >"$R/identity/dutexec-id.sha256"
STAGE=drm-class; dutexec drm-class 15 "$R/cmds/drm-class.txt" || stop drm-class
cp "$R/dut/drm-class.stdout" "$R/identity/drm-class.txt"
sha256sum "$R/identity/drm-class.txt" >"$R/identity/drm-class.sha256"
STAGE=stage-reset; dutexec stage-reset 30 "$R/cmds/stage-reset.txt" || stop stage-reset
for chunk in "$R"/cmds/eglprobe-chunk-*.txt; do
    name=${chunk##*/}; name=${name%.txt}; STAGE=$name
    dutexec "$name" 40 "$chunk" || stop "$name"
done
STAGE='eglprobe-finalize'; dutexec eglprobe-finalize 30 "$R/cmds/eglprobe-finalize.txt" \
    || stop eglprobe-finalize
pull_egl_preflight
for chunk in "$R"/cmds/probe-chunk-*.txt; do
    name=${chunk##*/}; name=${name%.txt}; STAGE=$name
    dutexec "$name" 40 "$chunk" || stop "$name"
done
STAGE='probe-finalize'; dutexec probe-finalize 30 "$R/cmds/probe-finalize.txt" || stop probe-finalize
for chunk in "$R"/cmds/discrim-chunk-*.txt; do
    name=${chunk##*/}; name=${name%.txt}; STAGE=$name
    dutexec "$name" 40 "$chunk" || stop "$name"
done
STAGE='discrim-finalize'; dutexec discrim-finalize 30 "$R/cmds/discrim-finalize.txt" || stop discrim-finalize
for chunk in "$R"/cmds/vkprobe-chunk-*.txt; do
    name=${chunk##*/}; name=${name%.txt}; STAGE=$name
    dutexec "$name" 40 "$chunk" || stop "$name"
done
STAGE='vkprobe-finalize'; dutexec vkprobe-finalize 30 "$R/cmds/vkprobe-finalize.txt" || stop vkprobe-finalize
for chunk in "$R"/cmds/list-chunk-*.txt; do
    [[ -e $chunk ]] || break
    name=${chunk##*/}; name=${name%.txt}; STAGE=$name
    dutexec "$name" 40 "$chunk" || stop "$name"
done
if [[ ${#REQUEST[@]} -eq 0 ]]; then
    run_selected_probes
    STAGE=cleanup; dutexec cleanup 45 "$R/cmds/cleanup.txt" || stop cleanup
    VERDICT="a-cts_probe_only_complete $probe_order"
    STAGE='done'
    exit 0
fi
STAGE=prepare; dutexec prepare 300 "$R/cmds/prepare.txt" || stop prepare
STAGE=worker-start
if ! dutexec worker-start 30 "$R/cmds/worker-start.txt"; then
    collect_worker_results partial
    stop 'worker-start evidence=verified'
fi

complete=no
for poll in $(seq 1 600); do
    sleep 60; STAGE="poll-$poll"
    if ! dutexec worker-poll 25 "$R/cmds/worker-poll.txt"; then
        collect_worker_results partial
        stop 'worker-poll evidence=verified'
    fi
    cp "$R/dut/worker-poll.stdout" "$R/results/progress.txt"
    if ! progress_line=$("$K/response-select" worker-progress \
        '^A_CTS_PROGRESS state=(complete|complete_with_harness_error|partial|running)( .*)?$' \
        "$R/results/progress.txt"); then
        collect_worker_results partial
        stop 'worker-progress-cardinality evidence=verified'
    fi
    state=${progress_line#A_CTS_PROGRESS state=}; state=${state%% *}
    case "$state" in
        complete|complete_with_harness_error) complete=yes; break ;;
        partial) collect_worker_results partial; stop 'worker state=partial evidence=verified' ;;
        running) ;;
        *) collect_worker_results partial; stop "worker state=$state evidence=verified" ;;
    esac
done
if [[ $complete != yes ]]; then
    collect_worker_results partial
    stop 'worker-wall-deadline evidence=verified'
fi
collect_worker_results complete

run_selected_probes
STAGE=cleanup; dutexec cleanup 45 "$R/cmds/cleanup.txt" || stop cleanup
VERDICT="a-cts_complete $order"
STAGE='done'
