#!/bin/sh
# Run the product image's capability-based KMS selector and return exactly the
# validated DRM node path. Arguments are explicit so hermetic tests can supply
# a private sysfs/dev tree without weakening the production launch contract.
set -eu

if test "$#" -ne 3; then
    echo "input-harness KMS selection: invalid arguments" >&2
    exit 2
fi
selector=$1
env_file=$2
dev_root=${3%/}

test -x "$selector" || {
    echo "input-harness KMS selection: product selector absent" >&2
    exit 1
}

# Preserve the product selector's typed PASS/REFUSED receipt in the session
# log while reserving stdout for the single validated node consumed below.
PF_GAMESCOPE_KMS_ENV="$env_file" "$selector" >&2

unset selected_node
line_count=0
while IFS= read -r line || test -n "$line"; do
    line_count=$((line_count + 1))
    case "$line" in
        PF_GAMESCOPE_KMS_NODE=*)
            test -z "${selected_node+x}" || {
                echo "input-harness KMS selection: duplicate nodes" >&2
                exit 1
            }
            selected_node=${line#PF_GAMESCOPE_KMS_NODE=}
            ;;
        *)
            echo "input-harness KMS selection: malformed selector data" >&2
            exit 1
            ;;
    esac
done <"$env_file"

if test "$line_count" -ne 1 || test -z "${selected_node:-}"; then
    echo "input-harness KMS selection: no unique node" >&2
    exit 1
fi
case "$selected_node" in
    "$dev_root"/card*)
        suffix=${selected_node#"$dev_root"/card}
        case "$suffix" in
            ''|*[!0-9]*)
                echo "input-harness KMS selection: invalid node" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "input-harness KMS selection: invalid node" >&2
        exit 1
        ;;
esac
test -e "$selected_node" || {
    echo "input-harness KMS selection: selected node absent" >&2
    exit 1
}

printf '%s\n' "$selected_node"
