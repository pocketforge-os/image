#!/usr/bin/env bash

# The caller must provide build_cache_docker(), which applies any local Docker
# argv audit before invoking Docker.  Structured buildx output is required: the
# default ID-only view omits the parent graph needed for dependency-safe prune
# ordering.

capture_build_cache_records() {
    local destination="$1" raw="${1}.jsonl"

    build_cache_docker buildx du --format json >"${raw}" 2>/dev/null || return 1
    python3 - "${raw}" "${destination}" <<'PY'
import json
from pathlib import Path
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
records = {}
for line_number, line in enumerate(source.read_text().splitlines(), 1):
    if not line.strip():
        continue
    record = json.loads(line)
    record_id = record.get("ID")
    parents = record.get("Parents", [])
    if parents is None:
        parents = []
    if not isinstance(record_id, str) or not record_id or any(c.isspace() for c in record_id):
        raise ValueError(f"invalid cache record ID at line {line_number}")
    if not isinstance(parents, list) or not all(
        isinstance(parent, str) and parent and not any(c.isspace() for c in parent)
        for parent in parents
    ):
        raise ValueError(f"invalid cache record parents at line {line_number}")
    normalized = tuple(sorted(set(parents)))
    if record_id in records and records[record_id] != normalized:
        raise ValueError(f"conflicting duplicate cache record ID {record_id}")
    records[record_id] = normalized

with destination.open("w") as output:
    for record_id in sorted(records):
        output.write(f"{record_id}\t{';'.join(records[record_id])}\n")
PY
}

build_cache_record_ids() {
    awk -F '\t' 'NF { print $1 }' "$1" | sort -u >"$2"
}

order_build_cache_prune_ids() {
    local records="$1" created_ids="$2" destination="$3"

    python3 - "${records}" "${created_ids}" "${destination}" <<'PY'
from pathlib import Path
import sys

record_path, created_path, destination_path = map(Path, sys.argv[1:])
created = {line.strip() for line in created_path.read_text().splitlines() if line.strip()}
parents = {}
for line in record_path.read_text().splitlines():
    if not line:
        continue
    record_id, _, parent_text = line.partition("\t")
    parents[record_id] = {item for item in parent_text.split(";") if item}

children = {record_id: set() for record_id in created}
for child in created:
    for parent in parents.get(child, set()):
        if parent in created:
            children[parent].add(child)

ordered = []
visiting = set()
visited = set()

def visit(record_id):
    if record_id in visited:
        return
    if record_id in visiting:
        raise ValueError("cycle in build-cache parent graph")
    visiting.add(record_id)
    for child in sorted(children[record_id]):
        visit(child)
    visiting.remove(record_id)
    visited.add(record_id)
    ordered.append(record_id)

for record_id in sorted(created):
    visit(record_id)

destination_path.write_text("".join(f"{record_id}\n" for record_id in ordered))
PY
}

build_cache_ids_csv() {
    paste -sd, "$1"
}

if ! declare -F build_cache_cleanup_pause >/dev/null 2>&1; then
    build_cache_cleanup_pause() {
        sleep 0.2
    }
fi

cleanup_run_build_cache() {
    local baseline_records="$1" scratch="$2"
    local before_ids="${scratch}-before-ids"
    local current_records="${scratch}-current-records"
    local current_ids="${scratch}-current-ids"
    local created_ids="${scratch}-created-ids"
    local missing_ids="${scratch}-missing-ids"
    local prune_order="${scratch}-prune-order"
    local all_created_ids="${scratch}-all-created-ids"
    local cache_id attempt

    : >"${all_created_ids}"
    build_cache_record_ids "${baseline_records}" "${before_ids}" || return 1

    # Keep observing through the same two-second settling window used for
    # Docker's aggregate accounting. This catches records published after
    # image removal or after an earlier buildx disk-usage snapshot.
    for ((attempt = 1; attempt <= 10; attempt++)); do
        capture_build_cache_records "${current_records}" || return 1
        build_cache_record_ids "${current_records}" "${current_ids}" || return 1
        comm -13 "${before_ids}" "${current_ids}" >"${created_ids}"
        comm -23 "${before_ids}" "${current_ids}" >"${missing_ids}"
        if [ -s "${created_ids}" ]; then
            sort -u "${all_created_ids}" "${created_ids}" \
                >"${all_created_ids}.next" || return 1
            mv "${all_created_ids}.next" "${all_created_ids}" || return 1
            order_build_cache_prune_ids \
                "${current_records}" "${created_ids}" "${prune_order}" || return 1
            while IFS= read -r cache_id; do
                [ -n "${cache_id}" ] || continue
                # Every prune is exact-ID scoped. Baseline IDs are never placed
                # in created_ids, including when a new record has one as parent.
                build_cache_docker buildx prune --force --filter "id=${cache_id}" \
                    >/dev/null 2>&1 || true
            done <"${prune_order}"
        fi
        build_cache_cleanup_pause
    done

    capture_build_cache_records "${current_records}" || return 1
    build_cache_record_ids "${current_records}" "${current_ids}" || return 1
    comm -13 "${before_ids}" "${current_ids}" >"${created_ids}"
    comm -23 "${before_ids}" "${current_ids}" >"${missing_ids}"
    # shellcheck disable=SC2034 # Output consumed by the sourcing script's receipt.
    build_cache_records_removed="$(awk 'NF { count++ } END { print count + 0 }' \
        "${all_created_ids}")"
    build_cache_leftover_ids="$(build_cache_ids_csv "${created_ids}")"
    build_cache_missing_ids="$(build_cache_ids_csv "${missing_ids}")"

    [ ! -s "${created_ids}" ] && [ ! -s "${missing_ids}" ]
}

build_cache_drift_reason() {
    printf 'BUILD_CACHE_USAGE_DRIFT:leftover_ids=%s;missing_ids=%s\n' \
        "${build_cache_leftover_ids:-none}" "${build_cache_missing_ids:-none}"
}
