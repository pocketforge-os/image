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

audit_docker_run_argv() {
    # Docker run is an exact allowlist: an option not parsed below is unsafe,
    # even when Docker itself would otherwise accept it.
    local -a argv=("$@")
    local arg value index=1 image_index=-1 last_index
    local detach_count=0 tty_count=0 name_count=0 label_count=0
    local hostname_count=0 cgroupns_count=0 network_count=0
    local run_tmpfs_count=0 lock_tmpfs_count=0 pids_count=0 env_count=0
    local capability_count=0 apparmor_unconfined_count=0 entrypoint_count=0

    [ "${ephemeral_admitted}" -eq 1 ] \
        || fail 'UNSAFE_CONTAINER_ARGV: Docker run lacks verified ephemeral admission'

    while [ "${index}" -lt "${#argv[@]}" ]; do
        arg="${argv[index]}"
        if [ "${arg}" = "${test_image}" ]; then
            image_index="${index}"
            break
        fi
        case "${arg}" in
            --detach)
                detach_count=$((detach_count + 1))
                ;;
            --tty|-t)
                tty_count=$((tty_count + 1))
                ;;
            --name)
                index=$((index + 1))
                value="${argv[index]-}"
                [ "${value}" = "${systemd_container}" ] \
                    || fail "UNSCOPED_CONTAINER_ARGV: Docker run container name=${value:-missing}"
                name_count=$((name_count + 1))
                ;;
            --label)
                index=$((index + 1))
                value="${argv[index]-}"
                [ "${value}" = "${run_label}" ] \
                    || fail "UNSCOPED_CONTAINER_ARGV: Docker run label=${value:-missing}"
                label_count=$((label_count + 1))
                ;;
            --hostname)
                index=$((index + 1))
                value="${argv[index]-}"
                [ "${value}" = tsp-f3fm-211-systemd ] \
                    || fail "UNSAFE_CONTAINER_ARGV: Docker run hostname=${value:-missing}"
                hostname_count=$((hostname_count + 1))
                ;;
            --cgroupns=private)
                cgroupns_count=$((cgroupns_count + 1))
                ;;
            --network=none)
                network_count=$((network_count + 1))
                ;;
            --network)
                index=$((index + 1))
                value="${argv[index]-}"
                [ "${value}" = none ] \
                    || fail "UNSAFE_CONTAINER_ARGV: Docker run network=${value:-missing}"
                network_count=$((network_count + 1))
                ;;
            --tmpfs)
                index=$((index + 1))
                value="${argv[index]-}"
                case "${value}" in
                    /run:rw,nosuid,nodev,mode=755)
                        run_tmpfs_count=$((run_tmpfs_count + 1))
                        ;;
                    /run/lock:rw,nosuid,nodev,mode=755)
                        lock_tmpfs_count=$((lock_tmpfs_count + 1))
                        ;;
                    *)
                        fail "UNSAFE_CONTAINER_ARGV: Docker run tmpfs=${value:-missing}"
                        ;;
                esac
                ;;
            --pids-limit=512)
                pids_count=$((pids_count + 1))
                ;;
            --env=container=docker)
                env_count=$((env_count + 1))
                ;;
            --security-opt)
                index=$((index + 1))
                value="${argv[index]-}"
                [ "${value}" = apparmor=unconfined ] \
                    || fail "UNSAFE_CONTAINER_ARGV: security option=${value:-missing}"
                apparmor_unconfined_count=$((apparmor_unconfined_count + 1))
                ;;
            --cap-add)
                index=$((index + 1))
                value="${argv[index]-}"
                [ "${value}" = SYS_ADMIN ] \
                    || fail "UNSAFE_CONTAINER_ARGV: added capability=${value:-missing}"
                capability_count=$((capability_count + 1))
                ;;
            --cap-add=SYS_ADMIN)
                capability_count=$((capability_count + 1))
                ;;
            --entrypoint)
                index=$((index + 1))
                value="${argv[index]-}"
                [ "${value}" = /bin/sleep ] \
                    || fail "UNSAFE_CONTAINER_ARGV: entrypoint=${value:-missing}"
                entrypoint_count=$((entrypoint_count + 1))
                ;;
            *)
                fail "UNSAFE_CONTAINER_ARGV: unapproved Docker run option=${arg}"
                ;;
        esac
        index=$((index + 1))
    done

    [ "${image_index}" -ge 0 ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: Docker run image is missing or mismatched'
    [ "${detach_count}" -eq 1 ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: Docker run detach count drifted'
    [ "${tty_count}" -eq 1 ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: Docker run PTY count drifted'
    [ "${name_count}" -eq 1 ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: Docker run name count drifted'
    [ "${label_count}" -eq 1 ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: Docker run label count drifted'
    [ "${cgroupns_count}" -eq 1 ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: Docker run private cgroup namespace count drifted'
    [ "${network_count}" -eq 1 ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: Docker run isolated network count drifted'
    [ "${run_tmpfs_count}" -eq 1 ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: Docker run /run tmpfs count drifted'
    [ "${lock_tmpfs_count}" -eq 1 ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: Docker run /run/lock tmpfs count drifted'
    [ "${hostname_count}" -le 1 ] \
        && [ "${pids_count}" -le 1 ] \
        && [ "${env_count}" -le 1 ] \
        || fail 'UNSAFE_CONTAINER_ARGV: Docker run safe option duplicated'

    last_index=$((${#argv[@]} - 1))
    [ "${image_index}" -eq "$((last_index - 1))" ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks exact image and command tail'
    case "${docker_run_profile:-}" in
        baseline-systemd)
            [ "${capability_count}" -eq 0 ] \
                && [ "${apparmor_unconfined_count}" -eq 0 ] \
                && [ "${entrypoint_count}" -eq 0 ] \
                && [ "${hostname_count}" -eq 0 ] \
                && [ "${pids_count}" -eq 0 ] \
                && [ "${env_count}" -eq 0 ] \
                || fail 'UNSAFE_CONTAINER_ARGV: baseline profile contains an unapproved option'
            [ "${argv[last_index]}" = /sbin/init ] \
                || fail 'UNSCOPED_CONTAINER_ARGV: baseline run lacks exact systemd command'
            ;;
        positive-control)
            [ "${capability_count}" -eq 0 ] \
                && [ "${apparmor_unconfined_count}" -eq 0 ] \
                && [ "${entrypoint_count}" -eq 1 ] \
                && [ "${hostname_count}" -eq 0 ] \
                && [ "${pids_count}" -eq 0 ] \
                && [ "${env_count}" -eq 0 ] \
                || fail 'UNSAFE_CONTAINER_ARGV: positive-control profile drifted'
            [ "${argv[last_index]}" = infinity ] \
                || fail 'UNSCOPED_CONTAINER_ARGV: positive control lacks exact sleep command'
            ;;
        owner-exception)
            [ "${capability_count}" -eq 1 ] \
                && [ "${apparmor_unconfined_count}" -eq 1 ] \
                && [ "${entrypoint_count}" -eq 0 ] \
                || fail 'UNSCOPED_CONTAINER_ARGV: owner exception is incomplete or duplicated'
            if [ "${hostname_count}" -eq 0 ] \
                && [ "${pids_count}" -eq 0 ] \
                && [ "${env_count}" -eq 0 ]; then
                :
            elif [ "${hostname_count}" -eq 1 ] \
                && [ "${pids_count}" -eq 1 ] \
                && [ "${env_count}" -eq 1 ]; then
                :
            else
                fail 'UNSCOPED_CONTAINER_ARGV: owner-exception run shape drifted'
            fi
            [ "${argv[last_index]}" = /usr/local/libexec/remount-cgroup-systemd ] \
                || fail 'UNSCOPED_CONTAINER_ARGV: owner exception lacks exact cgroup-remount command'
            ;;
        *) fail 'UNSCOPED_CONTAINER_ARGV: unknown Docker run profile' ;;
    esac
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
    if [ "${command_name}" = run ]; then
        audit_docker_run_argv "${argv[@]}"
        return 0
    fi
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
            if [ "${argv[1]-}" = du ]; then
                if [ "${#argv[@]}" -ne 4 ] \
                    || [ "${argv[2]-}" != --format ] \
                    || [ "${argv[3]-}" != json ]; then
                    fail 'UNSCOPED_CONTAINER_ARGV: build-cache audit is not exact JSON listing'
                fi
            elif [ "${argv[1]-}" = prune ]; then
                if [ "${#argv[@]}" -ne 5 ] \
                    || [ "${argv[2]-}" != --force ] \
                    || [ "${argv[3]-}" != --filter ]; then
                    fail 'UNSCOPED_CONTAINER_ARGV: build-cache prune argv drifted'
                fi
                value=
                for ((index = 0; index < ${#argv[@]}; index++)); do
                    if [ "${argv[index]}" = --filter ]; then
                        value="${argv[index + 1]-}"
                    fi
                done
                case "${value}" in
                    id=*) ;;
                    *) fail 'UNSCOPED_CONTAINER_ARGV: build-cache prune lacks record id' ;;
                esac
                argv_has --force "${argv[@]}" \
                    || fail 'UNSCOPED_CONTAINER_ARGV: build-cache prune is interactive'
            fi
            ;;
    esac
}
