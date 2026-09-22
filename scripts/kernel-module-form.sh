#!/usr/bin/env bash

# Resolve a kernel dependency from one modules_install release tree.  Print a
# machine-readable form followed by the evidence path.  A built-in dependency
# is recorded by modules.builtin and does not have a loadable .ko.
kernel_module_form() {
    local release_dir="$1"
    local module="$2"
    local module_path
    local builtin_file="${release_dir}/modules.builtin"

    module_path="$(find "${release_dir}" -name "${module}.ko" -type f -print -quit)"
    if [ -n "${module_path}" ]; then
        printf 'module\t%s\n' "${module_path}"
        return 0
    fi

    if [ -f "${builtin_file}" ] \
        && awk -F/ -v leaf="${module}.ko" '$NF == leaf { found=1 } END { exit !found }' "${builtin_file}"; then
        printf 'builtin\t%s\n' "${builtin_file}"
        return 0
    fi

    printf 'FATAL: %s not found as a module under %s or as a built-in in %s\n' \
        "${module}.ko" "${release_dir}" "${builtin_file}" >&2
    return 1
}
