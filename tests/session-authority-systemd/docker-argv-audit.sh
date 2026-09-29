#!/usr/bin/env bash
# Caller-owned audit context is required before audit_docker_argv is invoked.
# shellcheck disable=SC2154

reject_host_bind() {
    local value="$1"
    local source_path="${value%%:*}"
    case "${source_path}" in
        /dev|/dev/*) fail "UNSAFE_CONTAINER_ARGV: host device bind=${value}" ;;
        /sys/fs/cgroup|/sys/fs/cgroup/*)
            fail "UNSAFE_CONTAINER_ARGV: host cgroup bind=${value}"
            ;;
    esac
}

argv_has() {
    local expected="$1"
    shift
    local item
    for item in "$@"; do
        [ "${item}" != "${expected}" ] || return 0
    done
    return 1
}

argv_has_option_value() {
    local option="$1" expected="$2"
    shift 2
    local -a argv=("$@")
    local index
    for ((index = 0; index < ${#argv[@]}; index++)); do
        case "${argv[index]}" in
            "${option}") [ "${argv[index + 1]-}" = "${expected}" ] && return 0 ;;
            "${option}=${expected}") return 0 ;;
        esac
    done
    return 1
}

audit_docker_argv() {
    local -a argv=("$@")
    local dashdash=--
    local privileged_option="${dashdash}privileged"
    local volume_option="${dashdash}volume"
    local mount_option="${dashdash}mount"
    local device_option="${dashdash}device"
    local capability_option="${dashdash}cap-add"
    local security_option="${dashdash}security-opt"
    local pid_option="${dashdash}pid"
    local network_option="${dashdash}network"
    local network_alias="${dashdash}net"
    local cgroupns_option="${dashdash}cgroupns"
    local userns_option="${dashdash}userns"
    local entrypoint_option="${dashdash}entrypoint"
    local short_volume=-v
    local arg value index last_index command_name="${argv[0]-}"
    local capability_count=0 apparmor_unconfined_count=0 entrypoint_count=0

    [ -n "${command_name}" ] || fail 'UNSCOPED_CONTAINER_ARGV: empty Docker argv'
    for ((index = 0; index < ${#argv[@]}; index++)); do
        arg="${argv[index]}"
        case "${arg}" in
            "${privileged_option}"|"${privileged_option}="*)
                fail "UNSAFE_CONTAINER_ARGV: ${arg}"
                ;;
            "${device_option}"|"${device_option}="*)
                fail 'UNSAFE_CONTAINER_ARGV: host device option'
                ;;
            "${capability_option}")
                value="${argv[index + 1]-}"
                [ "${value}" = SYS_ADMIN ] \
                    || fail "UNSAFE_CONTAINER_ARGV: added capability=${value:-missing}"
                capability_count=$((capability_count + 1))
                ;;
            "${capability_option}="*)
                value="${arg#*=}"
                [ "${value}" = SYS_ADMIN ] \
                    || fail "UNSAFE_CONTAINER_ARGV: added capability=${value:-missing}"
                capability_count=$((capability_count + 1))
                ;;
            "${security_option}")
                value="${argv[index + 1]-}"
                [ "${value}" = apparmor=unconfined ] \
                    || fail "UNSAFE_CONTAINER_ARGV: security option=${value:-missing}"
                apparmor_unconfined_count=$((apparmor_unconfined_count + 1))
                ;;
            "${security_option}="*)
                value="${arg#*=}"
                [ "${value}" = apparmor=unconfined ] \
                    || fail "UNSAFE_CONTAINER_ARGV: security option=${value:-missing}"
                apparmor_unconfined_count=$((apparmor_unconfined_count + 1))
                ;;
            "${pid_option}")
                value="${argv[index + 1]-}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host pid namespace'
                ;;
            "${pid_option}="*)
                value="${arg#*=}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host pid namespace'
                ;;
            "${network_option}"|"${network_alias}")
                value="${argv[index + 1]-}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host network namespace'
                ;;
            "${network_option}="*|"${network_alias}="*)
                value="${arg#*=}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host network namespace'
                ;;
            "${cgroupns_option}")
                value="${argv[index + 1]-}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host cgroup namespace'
                ;;
            "${cgroupns_option}="*)
                value="${arg#*=}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host cgroup namespace'
                ;;
            "${userns_option}"|"${userns_option}="*)
                fail 'UNSAFE_CONTAINER_ARGV: user namespace option'
                ;;
            "${entrypoint_option}")
                value="${argv[index + 1]-}"
                [ "${value}" = /bin/sleep ] \
                    || fail "UNSAFE_CONTAINER_ARGV: entrypoint=${value:-missing}"
                entrypoint_count=$((entrypoint_count + 1))
                ;;
            "${entrypoint_option}="*)
                value="${arg#*=}"
                [ "${value}" = /bin/sleep ] \
                    || fail "UNSAFE_CONTAINER_ARGV: entrypoint=${value:-missing}"
                entrypoint_count=$((entrypoint_count + 1))
                ;;
            "${volume_option}"|"${short_volume}")
                reject_host_bind "${argv[index + 1]-}"
                ;;
            "${volume_option}="*)
                reject_host_bind "${arg#*=}"
                ;;
            "${short_volume}"?*)
                reject_host_bind "${arg#"${short_volume}"}"
                ;;
            "${mount_option}")
                value="${argv[index + 1]-}"
                case ",${value}," in
                    *,source=/dev,*|*,source=/dev/*,*|*,src=/dev,*|*,src=/dev/*,*)
                        fail 'UNSAFE_CONTAINER_ARGV: host device mount'
                        ;;
                    *,source=/sys/fs/cgroup,*|*,source=/sys/fs/cgroup/*,*|*,src=/sys/fs/cgroup,*|*,src=/sys/fs/cgroup/*,*)
                        fail 'UNSAFE_CONTAINER_ARGV: host cgroup mount'
                        ;;
                esac
                ;;
            "${mount_option}="*)
                value="${arg#*=}"
                case ",${value}," in
                    *,source=/dev,*|*,source=/dev/*,*|*,src=/dev,*|*,src=/dev/*,*)
                        fail 'UNSAFE_CONTAINER_ARGV: host device mount'
                        ;;
                    *,source=/sys/fs/cgroup,*|*,source=/sys/fs/cgroup/*,*|*,src=/sys/fs/cgroup,*|*,src=/sys/fs/cgroup/*,*)
                        fail 'UNSAFE_CONTAINER_ARGV: host cgroup mount'
                        ;;
                esac
                ;;
        esac
    done

    if { [ "${capability_count}" -ne 0 ] \
        || [ "${apparmor_unconfined_count}" -ne 0 ]; } \
        && [ "${command_name}" != run ]; then
        fail 'UNSAFE_CONTAINER_ARGV: owner exception is valid only for Docker run'
    fi

    case "${command_name}" in
        build)
            argv_has_option_value --label "${run_label}" "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker build lacks run label'
            argv_has_option_value --tag "${test_image}" "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker build lacks run image tag'
            ;;
        run)
            argv_has_option_value --label "${run_label}" "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks run label'
            argv_has_option_value --name "${systemd_container}" "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks run container name'
            argv_has_option_value --cgroupns private "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks private cgroup namespace'
            argv_has_option_value --network none "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks isolated network'
            argv_has_option_value --tmpfs '/run:rw,nosuid,nodev,mode=755' "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks /run tmpfs'
            argv_has_option_value --tmpfs '/run/lock:rw,nosuid,nodev,mode=755' "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks /run/lock tmpfs'
            argv_has --tty "${argv[@]}" || argv_has -t "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks PTY'
            [ "${ephemeral_admitted}" -eq 1 ] \
                || fail 'UNSAFE_CONTAINER_ARGV: Docker run lacks verified ephemeral admission'
            last_index=$((${#argv[@]} - 1))
            case "${docker_run_profile:-}" in
                baseline-systemd)
                    [ "${capability_count}" -eq 0 ] \
                        && [ "${apparmor_unconfined_count}" -eq 0 ] \
                        && [ "${entrypoint_count}" -eq 0 ] \
                        || fail 'UNSAFE_CONTAINER_ARGV: baseline profile contains owner exception'
                    [ "${last_index}" -ge 1 ] \
                        && [ "${argv[last_index - 1]}" = "${test_image}" ] \
                        && [ "${argv[last_index]}" = /sbin/init ] \
                        || fail 'UNSCOPED_CONTAINER_ARGV: baseline run lacks exact systemd command'
                    ;;
                positive-control)
                    [ "${capability_count}" -eq 0 ] \
                        && [ "${apparmor_unconfined_count}" -eq 0 ] \
                        || fail 'UNSAFE_CONTAINER_ARGV: positive control contains owner exception'
                    [ "${entrypoint_count}" -eq 1 ] \
                        || fail 'UNSCOPED_CONTAINER_ARGV: positive control entrypoint count drifted'
                    argv_has_option_value --entrypoint /bin/sleep "${argv[@]}" \
                        || fail 'UNSCOPED_CONTAINER_ARGV: positive control lacks sleep entrypoint'
                    [ "${last_index}" -ge 1 ] \
                        && [ "${argv[last_index - 1]}" = "${test_image}" ] \
                        && [ "${argv[last_index]}" = infinity ] \
                        || fail 'UNSCOPED_CONTAINER_ARGV: positive control lacks exact sleep command'
                    ;;
                owner-exception)
                    [ "${capability_count}" -eq 1 ] \
                        && [ "${apparmor_unconfined_count}" -eq 1 ] \
                        && [ "${entrypoint_count}" -eq 0 ] \
                        || fail 'UNSCOPED_CONTAINER_ARGV: owner exception is incomplete or duplicated'
                    [ "${last_index}" -ge 1 ] \
                        && [ "${argv[last_index - 1]}" = "${test_image}" ] \
                        && [ "${argv[last_index]}" = /usr/local/libexec/remount-cgroup-systemd ] \
                        || fail 'UNSCOPED_CONTAINER_ARGV: owner exception lacks exact cgroup-remount command'
                    ;;
                *) fail 'UNSCOPED_CONTAINER_ARGV: unknown Docker run profile' ;;
            esac
            ;;
        exec|logs|rm)
            argv_has "${systemd_container}" "${argv[@]}" \
                || fail "UNSCOPED_CONTAINER_ARGV: ${command_name} target is not run container"
            ;;
        container)
            case "${argv[1]-}" in
                inspect)
                    argv_has "${systemd_container}" "${argv[@]}" \
                        || fail 'UNSCOPED_CONTAINER_ARGV: container inspect target mismatch'
                    ;;
                ls)
                    argv_has_option_value --filter "label=${run_label}" "${argv[@]}" \
                        || fail 'UNSCOPED_CONTAINER_ARGV: container list lacks run label filter'
                    ;;
            esac
            ;;
        image)
            case "${argv[1]-}" in
                rm|inspect)
                    argv_has "${test_image}" "${argv[@]}" \
                        || fail "UNSCOPED_CONTAINER_ARGV: image ${argv[1]} target mismatch"
                    ;;
                ls)
                    argv_has_option_value --filter "label=${run_label}" "${argv[@]}" \
                        || fail 'UNSCOPED_CONTAINER_ARGV: image list lacks run label filter'
                    ;;
            esac
            ;;
        buildx)
            if [ "${argv[1]-}" = prune ]; then
                value=
                for ((index = 0; index < ${#argv[@]}; index++)); do
                    if [ "${argv[index]}" = --filter ]; then
                        value="${argv[index + 1]-}"
                    fi
                done
                case "${value}" in
                    id=*) ;;
                    *)
                        if [ "${allow_full_cache_prune}" -eq 1 ] \
                            && argv_has --all "${argv[@]}"; then
                            :
                        else
                            fail 'UNSCOPED_CONTAINER_ARGV: build-cache prune lacks record id'
                        fi
                        ;;
                esac
                argv_has --force "${argv[@]}" \
                    || fail 'UNSCOPED_CONTAINER_ARGV: build-cache prune is interactive'
            fi
            ;;
    esac
}
