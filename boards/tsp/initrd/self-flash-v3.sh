#!/bin/sh
# PocketForge self-flash v3 initrd engine.
#
# This file is sourced by /init and directly by the hermetic tests. Definitions
# therefore have no boot-time side effects. The caller validates the arm/card
# contract before populating the SF_V3_* values consumed here.

SF_V3_TRANSFER_BYTES=4194304
SF_V3_ALIGNMENT_BYTES=4194304
SF_V3_RESERVE_BYTES=1073741824
SF_V3_GUARD_BYTES=4194304
SF_V3_CONTROL_BYTES=4194304
SF_V3_SEED_MAX_BYTES=16777216
SF_V3_SLOT_BYTES=65536
SF_V3_LOGICAL_SECTOR_BYTES=512
SF_V3_CONTROLLER=04020000
SF_V3_SYS_CLASS_BLOCK="${SF_V3_SYS_CLASS_BLOCK:-/sys/class/block}"
SF_V3_DEV_ROOT="${SF_V3_DEV_ROOT:-/dev}"
SF_V3_MARKER="${SF_V3_MARKER:-/etc/pocketforge-selfflash-v3}"
SF_V3_UPTIME="${SF_V3_UPTIME:-/proc/uptime}"
SF_V3_MOUNTINFO_FILE="${SF_V3_MOUNTINFO_FILE:-${SF_MOUNTINFO_FILE:-/proc/self/mountinfo}}"
SF_V3_EXPECTED_CONTRACT_SHA256="${SF_V3_EXPECTED_CONTRACT_SHA256:-@SELF_FLASH_V3_CONTRACT_SHA256@}"

sf_v3_sha() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

sf_v3_uint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -gt 0 ] 2>/dev/null
}

sf_v3_get_line() {
    sed -n "${2}s/^[^=]*=//p" "$1"
}

sf_v3_controller_path() {
    case "$1" in
        *'/4020000.mmc/'*|*'/04020000.mmc/'*|*'/sdmmc@04020000/'*) return 0 ;;
        *) return 1 ;;
    esac
}

sf_v3_card_type() {
    sf_v3_card_device=$1
    sf_v3_primary_type="$(cat "$sf_v3_card_device/type" 2>/dev/null)" \
        || sf_v3_primary_type=""
    sf_v3_alternate_type=""
    if [ -e "$sf_v3_card_device/uevent" ]; then
        sf_v3_alternate_type="$(awk '
            BEGIN { count = 0 }
            /^MMC_TYPE=/ { count += 1; value = substr($0, 10) }
            END {
                if (count == 0) exit 2
                if (count != 1 || value == "") exit 1
                print value
            }
        ' "$sf_v3_card_device/uevent" 2>/dev/null)"
        sf_v3_type_status=$?
        [ "$sf_v3_type_status" -eq 0 ] \
            || [ "$sf_v3_type_status" -eq 2 ] || return 1
    fi
    if [ -n "$sf_v3_primary_type" ] && [ -n "$sf_v3_alternate_type" ]; then
        [ "$sf_v3_primary_type" = "$sf_v3_alternate_type" ] || return 1
    fi
    sf_v3_card_type_value=${sf_v3_primary_type:-$sf_v3_alternate_type}
    [ -n "$sf_v3_card_type_value" ] || return 1
    printf '%s\n' "$sf_v3_card_type_value"
}

sf_v3_card_serial() {
    sf_v3_card_device=$1
    sf_v3_primary_serial="$(cat "$sf_v3_card_device/serial" 2>/dev/null)" \
        || sf_v3_primary_serial=""
    if [ -n "$sf_v3_primary_serial" ]; then
        printf '%s\n' "$sf_v3_primary_serial"
        return 0
    fi
    sf_v3_cid="$(cat "$sf_v3_card_device/cid" 2>/dev/null)" || return 1
    [ "${#sf_v3_cid}" -eq 32 ] || return 1
    case "$sf_v3_cid" in *[!0-9a-fA-F]*) return 1 ;; esac
    printf 'cid:%s\n' "$sf_v3_cid" | tr A-F a-f
}

sf_v3_validate_marker() {
    [ -f "$SF_V3_MARKER" ] && [ ! -L "$SF_V3_MARKER" ] || return 1
    [ "$(wc -l <"$SF_V3_MARKER")" -eq 9 ] || return 1
    [ "$(sf_v3_get_line "$SF_V3_MARKER" 1)" = pocketforge.self-flash-initrd-capability/v3 ] \
        || return 1
    SF_V3_CONTRACT_SHA256="$(sf_v3_get_line "$SF_V3_MARKER" 2)"
    sf_v3_sha "$SF_V3_CONTRACT_SHA256" || return 1
    [ "$SF_V3_CONTRACT_SHA256" = "$SF_V3_EXPECTED_CONTRACT_SHA256" ] || return 1
    [ "$(sf_v3_get_line "$SF_V3_MARKER" 3)" = "$SF_V3_CONTROLLER" ] || return 1
    [ "$(sf_v3_get_line "$SF_V3_MARKER" 4)" = "$SF_V3_ALIGNMENT_BYTES" ] || return 1
    [ "$(sf_v3_get_line "$SF_V3_MARKER" 5)" = "$SF_V3_RESERVE_BYTES" ] || return 1
    [ "$(sf_v3_get_line "$SF_V3_MARKER" 6)" = "$SF_V3_GUARD_BYTES" ] || return 1
    [ "$(sf_v3_get_line "$SF_V3_MARKER" 7)" = "$SF_V3_CONTROL_BYTES" ] || return 1
    [ "$(sf_v3_get_line "$SF_V3_MARKER" 8)" = "$SF_V3_SEED_MAX_BYTES" ] || return 1
    [ "$(sf_v3_get_line "$SF_V3_MARKER" 9)" = "$SF_V3_SLOT_BYTES" ] || return 1
    SF_V3_MARKER_KEYS="$(sed 's/=.*//' "$SF_V3_MARKER")"
    SF_V3_EXPECTED_MARKER_KEYS="$(printf '%s\n' \
        Schema ContractSHA256 CardController AlignmentBytes ReserveBytes \
        GuardBytes ControlBytes SeedMaxBytes SlotBytes)"
    [ "$SF_V3_MARKER_KEYS" = "$SF_V3_EXPECTED_MARKER_KEYS" ] || return 1
}

sf_v3_discover_sd() {
    sf_v3_root_major_minor="${SF_V3_ROOT_MAJOR_MINOR:-}"
    if [ -z "$sf_v3_root_major_minor" ] && [ -n "${SF_ROOTPART:-}" ]; then
        sf_v3_root_major_minor="$(cat "$SF_V3_SYS_CLASS_BLOCK/${SF_ROOTPART##*/}/dev" 2>/dev/null)"
    fi
    [ -n "$sf_v3_root_major_minor" ] || return 1
    sf_v3_match_count=0
    SF_V3_SD=""
    for sf_v3_entry in "$SF_V3_SYS_CLASS_BLOCK"/*; do
        [ -e "$sf_v3_entry" ] || continue
        [ -e "$sf_v3_entry/device" ] || continue
        [ ! -e "$sf_v3_entry/partition" ] || continue
        sf_v3_physical="$(readlink -f "$sf_v3_entry/device" 2>/dev/null)"
        sf_v3_controller_path "$sf_v3_physical" || continue
        [ "$(sf_v3_card_type "$sf_v3_entry/device")" = SD ] || continue
        sf_v3_serial="$(sf_v3_card_serial "$sf_v3_entry/device")" || continue
        sf_v3_sectors="$(cat "$sf_v3_entry/size" 2>/dev/null)"
        sf_v3_logical="$(cat "$sf_v3_entry/queue/logical_block_size" 2>/dev/null)"
        sf_v3_uint "$sf_v3_sectors" && [ "$sf_v3_logical" = 512 ] \
            && [ -n "$sf_v3_serial" ] || continue
        sf_v3_whole_real="$(readlink -f "$sf_v3_entry" 2>/dev/null)"
        sf_v3_has_root=0
        for sf_v3_possible in "$SF_V3_SYS_CLASS_BLOCK"/*; do
            [ -e "$sf_v3_possible/partition" ] || continue
            sf_v3_possible_real="$(readlink -f "$sf_v3_possible" 2>/dev/null)"
            case "$sf_v3_possible_real" in
                "$sf_v3_whole_real"/*) ;;
                *) continue ;;
            esac
            [ "$(cat "$sf_v3_possible/partition" 2>/dev/null)" = 5 ] || continue
            [ "$(cat "$sf_v3_possible/dev" 2>/dev/null)" = "$sf_v3_root_major_minor" ] \
                || continue
            sf_v3_has_root=1
        done
        [ "$sf_v3_has_root" -eq 1 ] || continue
        sf_v3_device="$SF_V3_DEV_ROOT/${sf_v3_entry##*/}"
        if [ "$SF_V3_DEV_ROOT" = /dev ]; then
            [ -b "$sf_v3_device" ] || continue
        else
            [ -f "$sf_v3_device" ] || continue
        fi
        sf_v3_match_count=$((sf_v3_match_count + 1))
        SF_V3_SD="$sf_v3_device"
        SF_V3_SD_SYS="$sf_v3_entry"
        SF_V3_CARD_SERIAL="$sf_v3_serial"
        SF_V3_CARD_BYTES=$((sf_v3_sectors * sf_v3_logical))
    done
    [ "$sf_v3_match_count" -eq 1 ] || return 1

    SF_V3_TAIL_START=$(( (SF_V3_CARD_BYTES - SF_V3_RESERVE_BYTES) \
        / SF_V3_ALIGNMENT_BYTES * SF_V3_ALIGNMENT_BYTES ))
    SF_V3_CONTROL_END=$(( (SF_V3_CARD_BYTES - SF_V3_GUARD_BYTES) \
        / SF_V3_ALIGNMENT_BYTES * SF_V3_ALIGNMENT_BYTES ))
    SF_V3_ARM_OFFSET=$((SF_V3_CONTROL_END - SF_V3_CONTROL_BYTES))
    SF_V3_RECEIPT_OFFSET=$((SF_V3_ARM_OFFSET + SF_V3_SLOT_BYTES))
    [ "$SF_V3_TAIL_START" -gt 0 ] && [ "$SF_V3_ARM_OFFSET" -gt "$SF_V3_TAIL_START" ] \
        && [ $((SF_V3_RECEIPT_OFFSET + SF_V3_SLOT_BYTES)) -le "$SF_V3_CONTROL_END" ] \
        || return 1

    sf_v3_whole_real="$(readlink -f "$SF_V3_SD_SYS" 2>/dev/null)"
    sf_v3_partition_file="$SF_V3_WORK/live-partitions"
    : >"$sf_v3_partition_file" || return 1
    SF_V3_ROOT_START_SECTOR=""
    SF_V3_ROOT_SECTORS=""
    sf_v3_root_end_bytes=""
    sf_v3_layout_within_tail=1
    for sf_v3_possible in "$SF_V3_SYS_CLASS_BLOCK"/*; do
        [ -e "$sf_v3_possible/partition" ] || continue
        sf_v3_possible_real="$(readlink -f "$sf_v3_possible" 2>/dev/null)"
        case "$sf_v3_possible_real" in "$sf_v3_whole_real"/*) ;; *) continue ;; esac
        sf_v3_number="$(cat "$sf_v3_possible/partition" 2>/dev/null)"
        sf_v3_start="$(cat "$sf_v3_possible/start" 2>/dev/null)"
        sf_v3_size="$(cat "$sf_v3_possible/size" 2>/dev/null)"
        sf_v3_uint "$sf_v3_number" && sf_v3_uint "$sf_v3_start" \
            && sf_v3_uint "$sf_v3_size" || return 1
        sf_v3_end_bytes=$(( (sf_v3_start + sf_v3_size) * 512 ))
        [ "$sf_v3_end_bytes" -le "$SF_V3_TAIL_START" ] \
            || sf_v3_layout_within_tail=0
        printf '%s:%s:%s\n' "$sf_v3_number" "$sf_v3_start" "$sf_v3_size" \
            >>"$sf_v3_partition_file" || return 1
        if [ "$sf_v3_number" = 5 ]; then
            [ -z "$SF_V3_ROOT_START_SECTOR" ] || return 1
            SF_V3_ROOT_START_SECTOR="$sf_v3_start"
            SF_V3_ROOT_SECTORS="$sf_v3_size"
            sf_v3_root_end_bytes="$sf_v3_end_bytes"
        fi
    done
    [ -n "$SF_V3_ROOT_START_SECTOR" ] || return 1
    if [ "$sf_v3_root_end_bytes" -ne "$SF_V3_TAIL_START" ]; then
        sf_v3_root_delta=$((sf_v3_root_end_bytes - SF_V3_TAIL_START))
        [ "$sf_v3_root_delta" -ge 0 ] \
            || sf_v3_root_delta=$((-sf_v3_root_delta))
        if [ "$sf_v3_root_delta" -ge "$SF_V3_ALIGNMENT_BYTES" ]; then
            # A raw-image write has the baked partition table, not the capped
            # card-relative geometry required by the typed staging operation.
            # It cannot be an armed v3 transaction. Do not touch its arbitrary
            # tail; let the normal-root grow unit validate and initialize it.
            SF_V3_LOAD_STATE=uninitialized
            export SF_V3_LOAD_STATE
        fi
        return 1
    fi
    [ "$sf_v3_layout_within_tail" -eq 1 ] || return 1
    sort -t: -k1,1n "$sf_v3_partition_file" >"$sf_v3_partition_file.sorted" \
        || return 1
    SF_V3_PARTITION_LAYOUT_SHA256="$(sha256sum "$sf_v3_partition_file.sorted" \
        | awk '{print $1}')"
}

sf_v3_read_slot() {
    dd if="$SF_V3_SD" of="$2" bs="$SF_V3_TRANSFER_BYTES" \
        skip="$1" count="$SF_V3_SLOT_BYTES" \
        iflag=skip_bytes,count_bytes,fullblock status=none \
        || return 1
    [ "$(stat -c %s "$2" 2>/dev/null)" = "$SF_V3_SLOT_BYTES" ]
}

sf_v3_decode_slot() {
    sf_v3_slot="$1"
    sf_v3_record="$2"
    sf_v3_prefix_lines="$3"
    sf_v3_digest_key="$4"
    tr -d '\000' <"$sf_v3_slot" >"$sf_v3_record" || return 1
    sf_v3_record_bytes="$(wc -c <"$sf_v3_record")"
    [ "$sf_v3_record_bytes" -gt 2 ] \
        && [ "$sf_v3_record_bytes" -lt "$SF_V3_SLOT_BYTES" ] || return 1
    dd if="$sf_v3_slot" bs=1 count="$sf_v3_record_bytes" status=none \
        | cmp -s - "$sf_v3_record" || return 1
    sf_v3_nonzero_padding="$(dd if="$sf_v3_slot" bs=1 skip="$sf_v3_record_bytes" \
        status=none | tr -d '\000' | wc -c)"
    [ "$sf_v3_nonzero_padding" -eq 0 ] || return 1
    [ "$(wc -l <"$sf_v3_record")" -eq $((sf_v3_prefix_lines + 2)) ] || return 1
    sf_v3_newline_sha="$(tail -c 2 "$sf_v3_record" | sha256sum | awk '{print $1}')"
    sf_v3_expected_newline_sha="$(printf '\n\n' | sha256sum | awk '{print $1}')"
    [ "$sf_v3_newline_sha" = "$sf_v3_expected_newline_sha" ] || return 1
    sf_v3_stored_digest="$(sf_v3_get_line "$sf_v3_record" $((sf_v3_prefix_lines + 1)))"
    sf_v3_digest_name="$(sed -n "$((sf_v3_prefix_lines + 1))s/=.*//p" "$sf_v3_record")"
    [ "$sf_v3_digest_name" = "$sf_v3_digest_key" ] \
        && sf_v3_sha "$sf_v3_stored_digest" || return 1
    sf_v3_calculated_digest="$(head -n "$sf_v3_prefix_lines" "$sf_v3_record" \
        | sha256sum | awk '{print $1}')"
    [ "$sf_v3_stored_digest" = "$sf_v3_calculated_digest" ] || return 1
}

sf_v3_validate_arm() {
    sf_v3_arm="$1"
    SF_V3_ARM_KEYS="$(head -n 27 "$sf_v3_arm" | sed 's/=.*//')"
    SF_V3_EXPECTED_ARM_KEYS="$(printf '%s\n' Schema State Generation \
        BaseDescriptorSHA256 BaseRawSHA256 BaseRawBytes TargetDescriptorSHA256 \
        TargetRawSHA256 TargetRawBytes CompressedSHA256 CompressedBytes \
        SeedSHA256 SeedBytes CardController CardType CardSerial CardBytes \
        LogicalSectorBytes RootPartitionStartSector RootPartitionSectors \
        PartitionLayoutSHA256 TailStart StageOffset SeedOffset ArmOffset \
        ReceiptOffset ReceiptBytes)"
    [ "$SF_V3_ARM_KEYS" = "$SF_V3_EXPECTED_ARM_KEYS" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 1)" = pocketforge.self-flash-arm/v3 ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 2)" = armed ] || return 1
    SF_V3_GENERATION="$(sf_v3_get_line "$sf_v3_arm" 3)"
    [ "${#SF_V3_GENERATION}" -eq 32 ] || return 1
    case "$SF_V3_GENERATION" in *[!0-9a-f]*) return 1 ;; esac
    SF_V3_BASE_DESCRIPTOR_SHA256="$(sf_v3_get_line "$sf_v3_arm" 4)"
    SF_V3_BASE_RAW_SHA256="$(sf_v3_get_line "$sf_v3_arm" 5)"
    SF_V3_BASE_RAW_BYTES="$(sf_v3_get_line "$sf_v3_arm" 6)"
    SF_V3_TARGET_DESCRIPTOR_SHA256="$(sf_v3_get_line "$sf_v3_arm" 7)"
    SF_V3_TARGET_RAW_SHA256="$(sf_v3_get_line "$sf_v3_arm" 8)"
    SF_V3_TARGET_RAW_BYTES="$(sf_v3_get_line "$sf_v3_arm" 9)"
    SF_V3_COMPRESSED_SHA256="$(sf_v3_get_line "$sf_v3_arm" 10)"
    SF_V3_COMPRESSED_BYTES="$(sf_v3_get_line "$sf_v3_arm" 11)"
    SF_V3_SEED_SHA256="$(sf_v3_get_line "$sf_v3_arm" 12)"
    SF_V3_SEED_BYTES="$(sf_v3_get_line "$sf_v3_arm" 13)"
    for sf_v3_value in "$SF_V3_BASE_DESCRIPTOR_SHA256" "$SF_V3_BASE_RAW_SHA256" \
            "$SF_V3_TARGET_DESCRIPTOR_SHA256" "$SF_V3_TARGET_RAW_SHA256" \
            "$SF_V3_COMPRESSED_SHA256" "$SF_V3_SEED_SHA256"; do
        sf_v3_sha "$sf_v3_value" || return 1
    done
    for sf_v3_value in "$SF_V3_BASE_RAW_BYTES" "$SF_V3_TARGET_RAW_BYTES" \
            "$SF_V3_COMPRESSED_BYTES" "$SF_V3_SEED_BYTES"; do
        sf_v3_uint "$sf_v3_value" || return 1
    done
    [ "$SF_V3_BASE_RAW_SHA256" != "$SF_V3_TARGET_RAW_SHA256" ] || return 1
    [ "$SF_V3_SEED_BYTES" -le "$SF_V3_SEED_MAX_BYTES" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 14)" = "$SF_V3_CONTROLLER" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 15)" = SD ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 16)" = "$SF_V3_CARD_SERIAL" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 17)" = "$SF_V3_CARD_BYTES" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 18)" = 512 ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 19)" = "$SF_V3_ROOT_START_SECTOR" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 20)" = "$SF_V3_ROOT_SECTORS" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 21)" = "$SF_V3_PARTITION_LAYOUT_SHA256" ] \
        || return 1
    SF_V3_STAGE_OFFSET=$((SF_V3_TAIL_START + SF_V3_GUARD_BYTES))
    SF_V3_STAGE_END=$((SF_V3_STAGE_OFFSET + SF_V3_COMPRESSED_BYTES))
    SF_V3_SEED_OFFSET=$(( (SF_V3_STAGE_END + 4095) / 4096 * 4096 ))
    SF_V3_SEED_END=$((SF_V3_SEED_OFFSET + SF_V3_SEED_BYTES))
    [ "$SF_V3_SEED_END" -le "$SF_V3_ARM_OFFSET" ] || return 1
    sf_v3_image_max="$SF_V3_BASE_RAW_BYTES"
    [ "$SF_V3_TARGET_RAW_BYTES" -le "$sf_v3_image_max" ] \
        || sf_v3_image_max="$SF_V3_TARGET_RAW_BYTES"
    sf_v3_image_floor=$(( (sf_v3_image_max + SF_V3_ALIGNMENT_BYTES - 1) \
        / SF_V3_ALIGNMENT_BYTES * SF_V3_ALIGNMENT_BYTES ))
    [ "$sf_v3_image_floor" -le "$SF_V3_TAIL_START" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 22)" = "$SF_V3_TAIL_START" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 23)" = "$SF_V3_STAGE_OFFSET" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 24)" = "$SF_V3_SEED_OFFSET" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 25)" = "$SF_V3_ARM_OFFSET" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 26)" = "$SF_V3_RECEIPT_OFFSET" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_arm" 27)" = "$SF_V3_SLOT_BYTES" ] || return 1
}

sf_v3_validate_ready_receipt() {
    sf_v3_receipt="$1"
    SF_V3_RECEIPT_KEYS="$(head -n 29 "$sf_v3_receipt" | sed 's/=.*//')"
    SF_V3_EXPECTED_RECEIPT_KEYS="$(printf '%s\n' Schema State Generation \
        TargetDescriptorSHA256 TargetRawSHA256 TargetRawBytes \
        CompressedExpectedSHA256 CompressedExpectedBytes CompressedVerifiedHost \
        CompressedHostVerification DUTCompressedHash XzIntegrity RawStreamSHA256 \
        RawStreamBytes RawStreamHashMatch RawStreamCountMatch WriteMethod \
        WriteResult FullDeviceReadback SeedResult StampResult FailurePhase \
        FailureReason InitrdStartMonotonicMs WriteStartMonotonicMs \
        WriteEndMonotonicMs SeedEndMonotonicMs StampEndMonotonicMs \
        ReceiptWrittenMonotonicMs)"
    [ "$SF_V3_RECEIPT_KEYS" = "$SF_V3_EXPECTED_RECEIPT_KEYS" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 1)" = pocketforge.self-flash-receipt/v3 ] \
        || return 1
    SF_V3_RECEIPT_STATE="$(sf_v3_get_line "$sf_v3_receipt" 2)"
    [ "$SF_V3_RECEIPT_STATE" = ready ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 3)" = "$SF_V3_GENERATION" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 4)" = "$SF_V3_TARGET_DESCRIPTOR_SHA256" ] \
        || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 5)" = "$SF_V3_TARGET_RAW_SHA256" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 6)" = "$SF_V3_TARGET_RAW_BYTES" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 7)" = "$SF_V3_COMPRESSED_SHA256" ] \
        || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 8)" = "$SF_V3_COMPRESSED_BYTES" ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 9)" = matt-laptop ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 10)" = sha256-and-byte-count-before-arm ] \
        || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 11)" = not-performed ] || return 1
    sf_v3_line=12
    while [ "$sf_v3_line" -le 21 ]; do
        case "$sf_v3_line" in
            14) sf_v3_expected=unknown ;;
            19) sf_v3_expected=not-performed ;;
            *) sf_v3_expected=not-run ;;
        esac
        [ "$(sf_v3_get_line "$sf_v3_receipt" "$sf_v3_line")" = "$sf_v3_expected" ] \
            || return 1
        sf_v3_line=$((sf_v3_line + 1))
    done
    [ "$(sf_v3_get_line "$sf_v3_receipt" 22)" = none ] || return 1
    [ "$(sf_v3_get_line "$sf_v3_receipt" 23)" = none ] || return 1
    sf_v3_line=24
    while [ "$sf_v3_line" -le 29 ]; do
        [ "$(sf_v3_get_line "$sf_v3_receipt" "$sf_v3_line")" = unknown ] || return 1
        sf_v3_line=$((sf_v3_line + 1))
    done
}

sf_v3_now_ms() {
    sf_v3_milliseconds="$(awk '
        NR == 1 {
            split($1, value, ".")
            fraction = value[2] "000"
            printf "%s%s\n", value[1], substr(fraction, 1, 3)
            exit
        }
    ' "$SF_V3_UPTIME" 2>/dev/null)"
    case "$sf_v3_milliseconds" in
        ''|*[!0-9]*) printf '%s\n' unknown ;;
        *) printf '%s\n' "$sf_v3_milliseconds" ;;
    esac
}

sf_v3_receipt_defaults() {
    SF_V3_XZ_RESULT=not-run
    SF_V3_RAW_STREAM_SHA256=not-run
    SF_V3_RAW_STREAM_BYTES=unknown
    SF_V3_RAW_STREAM_HASH_MATCH=not-run
    SF_V3_RAW_STREAM_COUNT_MATCH=not-run
    SF_V3_WRITE_METHOD=not-run
    SF_V3_WRITE_RESULT=not-run
    SF_V3_FULL_DEVICE_READBACK=not-performed
    SF_V3_SEED_RESULT=not-run
    SF_V3_STAMP_RESULT=not-run
    SF_V3_INITRD_START_MS=unknown
    SF_V3_WRITE_START_MS=unknown
    SF_V3_WRITE_END_MS=unknown
    SF_V3_SEED_END_MS=unknown
    SF_V3_STAMP_END_MS=unknown
}

sf_v3_write_receipt() {
    sf_v3_state="$1"
    sf_v3_failure_phase="$2"
    sf_v3_failure_reason="$3"
    case "$sf_v3_state" in started|failed|pass) ;; *) return 1 ;; esac
    case "$sf_v3_failure_phase" in
        none|eligibility|arm|xz|raw-count|raw-hash|write|seed|stamp|receipt) ;;
        *) return 1 ;;
    esac
    [ "${#sf_v3_failure_reason}" -le 64 ] || return 1
    case "$sf_v3_failure_reason" in ''|*[!a-z0-9-]*) return 1 ;; esac
    if [ "$sf_v3_state" = pass ]; then
        [ "$sf_v3_failure_phase:$sf_v3_failure_reason" = none:none ] || return 1
        [ "$SF_V3_XZ_RESULT" = pass ] \
            && [ "$SF_V3_RAW_STREAM_SHA256" = "$SF_V3_TARGET_RAW_SHA256" ] \
            && [ "$SF_V3_RAW_STREAM_BYTES" = "$SF_V3_TARGET_RAW_BYTES" ] \
            && [ "$SF_V3_RAW_STREAM_HASH_MATCH" = pass ] \
            && [ "$SF_V3_RAW_STREAM_COUNT_MATCH" = pass ] \
            && [ "$SF_V3_WRITE_RESULT" = pass ] \
            && [ "$SF_V3_SEED_RESULT" = pass ] \
            && [ "$SF_V3_STAMP_RESULT" = pass ] || return 1
        case "$SF_V3_WRITE_METHOD" in dd-direct-fsync|dd-fsync) ;; *) return 1 ;; esac
    fi

    sf_v3_receipt_written_ms="$(sf_v3_now_ms)"
    sf_v3_receipt_prefix="$SF_V3_WORK/receipt-write.prefix"
    sf_v3_receipt_record="$SF_V3_WORK/receipt-write.record"
    sf_v3_receipt_slot="$SF_V3_WORK/receipt-write.slot"
    sf_v3_receipt_readback="$SF_V3_WORK/receipt-write.readback"
    {
        printf 'Schema=pocketforge.self-flash-receipt/v3\n'
        printf 'State=%s\n' "$sf_v3_state"
        printf 'Generation=%s\n' "$SF_V3_GENERATION"
        printf 'TargetDescriptorSHA256=%s\n' "$SF_V3_TARGET_DESCRIPTOR_SHA256"
        printf 'TargetRawSHA256=%s\n' "$SF_V3_TARGET_RAW_SHA256"
        printf 'TargetRawBytes=%s\n' "$SF_V3_TARGET_RAW_BYTES"
        printf 'CompressedExpectedSHA256=%s\n' "$SF_V3_COMPRESSED_SHA256"
        printf 'CompressedExpectedBytes=%s\n' "$SF_V3_COMPRESSED_BYTES"
        printf 'CompressedVerifiedHost=matt-laptop\n'
        printf 'CompressedHostVerification=sha256-and-byte-count-before-arm\n'
        printf 'DUTCompressedHash=not-performed\n'
        printf 'XzIntegrity=%s\n' "$SF_V3_XZ_RESULT"
        printf 'RawStreamSHA256=%s\n' "$SF_V3_RAW_STREAM_SHA256"
        printf 'RawStreamBytes=%s\n' "$SF_V3_RAW_STREAM_BYTES"
        printf 'RawStreamHashMatch=%s\n' "$SF_V3_RAW_STREAM_HASH_MATCH"
        printf 'RawStreamCountMatch=%s\n' "$SF_V3_RAW_STREAM_COUNT_MATCH"
        printf 'WriteMethod=%s\n' "$SF_V3_WRITE_METHOD"
        printf 'WriteResult=%s\n' "$SF_V3_WRITE_RESULT"
        printf 'FullDeviceReadback=%s\n' "$SF_V3_FULL_DEVICE_READBACK"
        printf 'SeedResult=%s\n' "$SF_V3_SEED_RESULT"
        printf 'StampResult=%s\n' "$SF_V3_STAMP_RESULT"
        printf 'FailurePhase=%s\n' "$sf_v3_failure_phase"
        printf 'FailureReason=%s\n' "$sf_v3_failure_reason"
        printf 'InitrdStartMonotonicMs=%s\n' "$SF_V3_INITRD_START_MS"
        printf 'WriteStartMonotonicMs=%s\n' "$SF_V3_WRITE_START_MS"
        printf 'WriteEndMonotonicMs=%s\n' "$SF_V3_WRITE_END_MS"
        printf 'SeedEndMonotonicMs=%s\n' "$SF_V3_SEED_END_MS"
        printf 'StampEndMonotonicMs=%s\n' "$SF_V3_STAMP_END_MS"
        printf 'ReceiptWrittenMonotonicMs=%s\n' "$sf_v3_receipt_written_ms"
    } >"$sf_v3_receipt_prefix" || return 1
    SF_V3_RECEIPT_RECORD_SHA256="$(sha256sum "$sf_v3_receipt_prefix" \
        | awk '{print $1}')"
    {
        cat "$sf_v3_receipt_prefix"
        printf 'ReceiptRecordSHA256=%s\n\n' "$SF_V3_RECEIPT_RECORD_SHA256"
    } >"$sf_v3_receipt_record" || return 1
    [ "$(stat -c %s "$sf_v3_receipt_record" 2>/dev/null)" -lt "$SF_V3_SLOT_BYTES" ] \
        || return 1
    dd if=/dev/zero of="$sf_v3_receipt_slot" bs="$SF_V3_SLOT_BYTES" count=1 \
        status=none || return 1
    dd if="$sf_v3_receipt_record" of="$sf_v3_receipt_slot" conv=notrunc \
        status=none || return 1
    dd if="$sf_v3_receipt_slot" of="$SF_V3_SD" bs="$SF_V3_TRANSFER_BYTES" \
        seek="$SF_V3_RECEIPT_OFFSET" count="$SF_V3_SLOT_BYTES" \
        iflag=count_bytes,fullblock oflag=seek_bytes conv=notrunc,fsync status=none \
        || return 1
    sf_v3_read_slot "$SF_V3_RECEIPT_OFFSET" "$sf_v3_receipt_readback" || return 1
    cmp -s "$sf_v3_receipt_slot" "$sf_v3_receipt_readback" || return 1
}

sf_v3_install_stamp() {
    sf_v3_fat="$1"
    [ -d "$sf_v3_fat" ] && [ ! -L "$sf_v3_fat" ] || return 1
    [ -f "$SF_V3_WORK/receipt-write.slot" ] || return 1
    sf_v3_fresh_receipt="$SF_V3_WORK/receipt-stamp.readback"
    sf_v3_read_slot "$SF_V3_RECEIPT_OFFSET" "$sf_v3_fresh_receipt" || return 1
    cmp -s "$SF_V3_WORK/receipt-write.slot" "$sf_v3_fresh_receipt" || return 1
    SF_V3_RECEIPT_PADDED_SHA256="$(sha256sum "$sf_v3_fresh_receipt" \
        | awk '{print $1}')"
    sf_v3_sha "$SF_V3_RECEIPT_PADDED_SHA256" || return 1
    sf_v3_stamp_expected="$SF_V3_WORK/stamp.expected"
    sf_v3_stamp_temporary="$sf_v3_fat/.pocketforge-self-flash-v3-$SF_V3_GENERATION.tmp"
    sf_v3_stamp_final="$sf_v3_fat/pocketforge-self-flash-v3"
    [ ! -e "$sf_v3_stamp_temporary" ] || return 1
    {
        printf 'Schema=pocketforge.self-flash-stamp/v3\n'
        printf 'Generation=%s\n' "$SF_V3_GENERATION"
        printf 'TargetDescriptorSHA256=%s\n' "$SF_V3_TARGET_DESCRIPTOR_SHA256"
        printf 'TargetRawSHA256=%s\n' "$SF_V3_TARGET_RAW_SHA256"
        printf 'TargetRawBytes=%s\n' "$SF_V3_TARGET_RAW_BYTES"
        printf 'TailReceiptSHA256=%s\n' "$SF_V3_RECEIPT_PADDED_SHA256"
    } >"$sf_v3_stamp_expected" || return 1
    cp "$sf_v3_stamp_expected" "$sf_v3_stamp_temporary" || return 1
    sync || return 1
    cmp -s "$sf_v3_stamp_expected" "$sf_v3_stamp_temporary" || return 1
    mv -f "$sf_v3_stamp_temporary" "$sf_v3_stamp_final" || return 1
    sync || return 1
    [ -f "$sf_v3_stamp_final" ] && [ ! -L "$sf_v3_stamp_final" ] || return 1
    cmp -s "$sf_v3_stamp_expected" "$sf_v3_stamp_final" || return 1
    SF_V3_STAMP_END_MS="$(sf_v3_now_ms)"
    export SF_V3_RECEIPT_PADDED_SHA256 SF_V3_STAMP_END_MS
}

sf_v3_load_armed_transaction() {
    SF_V3_LOAD_STATE=refused
    export SF_V3_LOAD_STATE
    mkdir -p "$SF_V3_WORK" || return 1
    sf_v3_clean_work || return 1
    sf_v3_validate_marker || { sf_v3_clean_work; return 1; }
    sf_v3_discover_sd || { sf_v3_clean_work; return 1; }
    sf_v3_arm_slot="$SF_V3_WORK/arm.slot"
    sf_v3_receipt_slot="$SF_V3_WORK/receipt.slot"
    sf_v3_arm_record="$SF_V3_WORK/arm.record"
    sf_v3_receipt_record="$SF_V3_WORK/receipt.record"
    sf_v3_read_slot "$SF_V3_ARM_OFFSET" "$sf_v3_arm_slot" \
        || { sf_v3_clean_work; return 1; }
    if [ "$(tr -d '\000' <"$sf_v3_arm_slot" | wc -c)" -eq 0 ]; then
        SF_V3_LOAD_STATE=absent
        export SF_V3_LOAD_STATE
        sf_v3_clean_work
        return 1
    fi
    sf_v3_decode_slot "$sf_v3_arm_slot" "$sf_v3_arm_record" 27 ArmRecordSHA256 \
        && sf_v3_validate_arm "$sf_v3_arm_record" \
        || { sf_v3_clean_work; return 1; }
    sf_v3_read_slot "$SF_V3_RECEIPT_OFFSET" "$sf_v3_receipt_slot" \
        && sf_v3_decode_slot "$sf_v3_receipt_slot" "$sf_v3_receipt_record" 29 ReceiptRecordSHA256 \
        || { sf_v3_clean_work; return 1; }
    SF_V3_RECEIPT_STATE="$(sf_v3_get_line "$sf_v3_receipt_record" 2)"
    if [ "$SF_V3_RECEIPT_STATE" != ready ]; then
        case "$SF_V3_RECEIPT_STATE" in
            started|failed|pass) SF_V3_LOAD_STATE=stale ;;
            *) SF_V3_LOAD_STATE=refused ;;
        esac
        export SF_V3_LOAD_STATE
        sf_v3_clean_work
        return 1
    fi
    sf_v3_validate_ready_receipt "$sf_v3_receipt_record" \
        || { sf_v3_clean_work; return 1; }
    SF_V3_LOAD_STATE=ready
    export SF_V3_LOAD_STATE
    sf_v3_clean_work
}

sf_v3_require_pipefail() {
    (set -o pipefail) >/dev/null 2>&1
}

sf_v3_read_stage() {
    dd if="$SF_V3_SD" bs="$SF_V3_TRANSFER_BYTES" \
        skip="$SF_V3_STAGE_OFFSET" count="$SF_V3_COMPRESSED_BYTES" \
        iflag=skip_bytes,count_bytes,fullblock status=none
}

sf_v3_read_seed() {
    dd if="$SF_V3_SD" bs="$SF_V3_TRANSFER_BYTES" \
        skip="$SF_V3_SEED_OFFSET" count="$SF_V3_SEED_BYTES" \
        iflag=skip_bytes,count_bytes,fullblock status=none
}

sf_v3_remove_seed_temporary() {
    sf_v3_seed_temporary="$1"
    [ ! -d "$sf_v3_seed_temporary" ] \
        || rm -r "$sf_v3_seed_temporary"
}

sf_v3_install_seed() {
    sf_v3_fat="$1"
    SF_V3_SEED_RESULT=fail
    SF_V3_SEED_STREAM_BYTES=unknown
    SF_V3_SEED_STREAM_SHA256=unknown
    export SF_V3_SEED_RESULT SF_V3_SEED_STREAM_BYTES SF_V3_SEED_STREAM_SHA256
    [ -d "$sf_v3_fat" ] && [ ! -L "$sf_v3_fat" ] || return 1
    sf_v3_require_pipefail || return 1
    set -o pipefail || return 1
    sf_v3_seed_temporary="$sf_v3_fat/.pf-self-flash-v3-$SF_V3_GENERATION-seed"
    [ ! -e "$sf_v3_seed_temporary" ] || return 1
    mkdir "$sf_v3_seed_temporary" || return 1
    sf_v3_seed_hash_fifo="$SF_V3_WORK/seed-hash.fifo"
    sf_v3_seed_count_fifo="$SF_V3_WORK/seed-count.fifo"
    sf_v3_seed_hash_result="$SF_V3_WORK/seed-hash.result"
    sf_v3_seed_count_result="$SF_V3_WORK/seed-count.result"
    mkfifo "$sf_v3_seed_hash_fifo" "$sf_v3_seed_count_fifo" \
        || { sf_v3_remove_seed_temporary "$sf_v3_seed_temporary"; return 1; }
    sha256sum <"$sf_v3_seed_hash_fifo" >"$sf_v3_seed_hash_result" &
    sf_v3_seed_hash_pid=$!
    wc -c <"$sf_v3_seed_count_fifo" >"$sf_v3_seed_count_result" &
    sf_v3_seed_count_pid=$!
    if sf_v3_read_seed \
        | tee "$sf_v3_seed_hash_fifo" "$sf_v3_seed_count_fifo" \
        | tar -xf - -C "$sf_v3_seed_temporary"; then
        sf_v3_seed_pipeline_rc=0
    else
        sf_v3_seed_pipeline_rc=$?
    fi
    if wait "$sf_v3_seed_hash_pid"; then sf_v3_seed_hash_rc=0; \
        else sf_v3_seed_hash_rc=$?; fi
    if wait "$sf_v3_seed_count_pid"; then sf_v3_seed_count_rc=0; \
        else sf_v3_seed_count_rc=$?; fi
    if [ "$sf_v3_seed_hash_rc" -eq 0 ]; then
        read -r SF_V3_SEED_STREAM_SHA256 sf_v3_seed_hash_name \
            <"$sf_v3_seed_hash_result" || SF_V3_SEED_STREAM_SHA256=unknown
    fi
    if [ "$sf_v3_seed_count_rc" -eq 0 ]; then
        read -r SF_V3_SEED_STREAM_BYTES <"$sf_v3_seed_count_result" \
            || SF_V3_SEED_STREAM_BYTES=unknown
    fi
    export SF_V3_SEED_STREAM_BYTES SF_V3_SEED_STREAM_SHA256
    if [ "$sf_v3_seed_pipeline_rc" -ne 0 ] \
            || [ "$sf_v3_seed_hash_rc" -ne 0 ] \
            || [ "$sf_v3_seed_count_rc" -ne 0 ] \
            || [ "$SF_V3_SEED_STREAM_BYTES" != "$SF_V3_SEED_BYTES" ] \
            || [ "$SF_V3_SEED_STREAM_SHA256" != "$SF_V3_SEED_SHA256" ]; then
        sf_v3_remove_seed_temporary "$sf_v3_seed_temporary"
        return 1
    fi

    sf_v3_seed_members="$SF_V3_WORK/seed-members"
    (cd "$sf_v3_seed_temporary" && find . -mindepth 1 -print \
        | sed 's#^\./##' | sort) >"$sf_v3_seed_members" || return 1
    printf '%s\n' meta-data network-config user-data \
        | sort >"$SF_V3_WORK/seed-members.expected" || return 1
    cmp -s "$sf_v3_seed_members" "$SF_V3_WORK/seed-members.expected" \
        || { sf_v3_remove_seed_temporary "$sf_v3_seed_temporary"; return 1; }
    for sf_v3_seed_name in meta-data network-config user-data; do
        sf_v3_seed_source="$sf_v3_seed_temporary/$sf_v3_seed_name"
        [ -f "$sf_v3_seed_source" ] && [ ! -L "$sf_v3_seed_source" ] \
            || { sf_v3_remove_seed_temporary "$sf_v3_seed_temporary"; return 1; }
        sf_v3_seed_staged="$sf_v3_fat/.pf-self-flash-v3-$SF_V3_GENERATION-$sf_v3_seed_name.tmp"
        rm -f "$sf_v3_seed_staged" || return 1
        mv "$sf_v3_seed_source" "$sf_v3_seed_staged" || return 1
    done
    rmdir "$sf_v3_seed_temporary" || return 1
    sync || return 1
    for sf_v3_seed_name in meta-data network-config user-data; do
        sf_v3_seed_staged="$sf_v3_fat/.pf-self-flash-v3-$SF_V3_GENERATION-$sf_v3_seed_name.tmp"
        mv -f "$sf_v3_seed_staged" "$sf_v3_fat/$sf_v3_seed_name" || return 1
    done
    sync || return 1
    for sf_v3_seed_name in meta-data network-config user-data; do
        [ -f "$sf_v3_fat/$sf_v3_seed_name" ] \
            && [ ! -L "$sf_v3_fat/$sf_v3_seed_name" ] || return 1
    done
    SF_V3_SEED_RESULT=pass
    SF_V3_SEED_END_MS="$(sf_v3_now_ms)"
    export SF_V3_SEED_RESULT SF_V3_SEED_END_MS
}

sf_v3_write_sink() {
    dd of="$SF_V3_SD" bs="$SF_V3_TRANSFER_BYTES" \
        count="$SF_V3_TARGET_RAW_BYTES" iflag=count_bytes,fullblock \
        conv=notrunc,fsync status=none
}

sf_v3_resolve_selected_card_sys() {
    SF_V3_CARD_IDENTITY_REASON=no_card_identity
    SF_V3_SELECTED_CARD_SYS=""
    [ -n "${SF_V3_SD:-}" ] || return 1
    sf_v3_selected_name="${SF_V3_SD##*/}"
    [ -n "$sf_v3_selected_name" ] \
        && [ "$SF_V3_SD" = "$SF_V3_DEV_ROOT/$sf_v3_selected_name" ] || return 1
    sf_v3_selected_class="$SF_V3_SYS_CLASS_BLOCK/$sf_v3_selected_name"
    [ -e "$sf_v3_selected_class" ] || return 1
    SF_V3_SELECTED_CARD_SYS="$(readlink -f "$sf_v3_selected_class" 2>/dev/null)"
    [ -n "$SF_V3_SELECTED_CARD_SYS" ] || return 1
    SF_V3_CARD_IDENTITY_REASON=resolved
    export SF_V3_CARD_IDENTITY_REASON SF_V3_SELECTED_CARD_SYS
}

sf_v3_partition_on_selected_card() {
    sf_v3_partition="$1"
    sf_v3_resolve_selected_card_sys || return 1
    sf_v3_partition_sys="$SF_V3_SYS_CLASS_BLOCK/${sf_v3_partition##*/}"
    [ -e "$sf_v3_partition_sys" ] || return 1
    sf_v3_partition_real="$(readlink -f "$sf_v3_partition_sys" 2>/dev/null)"
    case "$sf_v3_partition_real" in
        "$SF_V3_SELECTED_CARD_SYS"/*) return 0 ;;
    esac
    return 1
}

sf_v3_selected_card_unmounted() {
    SF_V3_UNMOUNT_REASON=no_card_identity
    SF_V3_MOUNTED_DEV=""
    SF_V3_MOUNTED_PATH=""
    export SF_V3_UNMOUNT_REASON SF_V3_MOUNTED_DEV SF_V3_MOUNTED_PATH
    sf_v3_resolve_selected_card_sys || return 1
    sf_v3_dev_count=0
    for sf_v3_dev_file in \
            "$SF_V3_SELECTED_CARD_SYS/dev" "$SF_V3_SELECTED_CARD_SYS"/*/dev; do
        [ -f "$sf_v3_dev_file" ] || continue
        sf_v3_dev_count=$((sf_v3_dev_count + 1))
        sf_v3_major_minor="$(cat "$sf_v3_dev_file" 2>/dev/null)"
        if [ -z "$sf_v3_major_minor" ]; then
            SF_V3_UNMOUNT_REASON=mount_state_unavailable
            export SF_V3_UNMOUNT_REASON
            return 1
        fi
        sf_v3_mount_path="$(awk -v dev="$sf_v3_major_minor" \
            '$3 == dev { print $5; exit }' "$SF_V3_MOUNTINFO_FILE")" || {
                SF_V3_UNMOUNT_REASON=mount_state_unavailable
                export SF_V3_UNMOUNT_REASON
                return 1
            }
        if [ -n "$sf_v3_mount_path" ]; then
            SF_V3_UNMOUNT_REASON=mounted
            SF_V3_MOUNTED_DEV="$sf_v3_major_minor"
            SF_V3_MOUNTED_PATH="$sf_v3_mount_path"
            export SF_V3_UNMOUNT_REASON SF_V3_MOUNTED_DEV SF_V3_MOUNTED_PATH
            return 1
        fi
    done
    if [ "$sf_v3_dev_count" -eq 0 ]; then
        SF_V3_UNMOUNT_REASON=no_card_identity
        export SF_V3_UNMOUNT_REASON
        return 1
    fi
    SF_V3_UNMOUNT_REASON=unmounted
    export SF_V3_UNMOUNT_REASON
    return 0
}

sf_v3_mount_target_fat() {
    blockdev --rereadpt "$SF_V3_SD" || return 1
    sf_drop_cache
    SF_V3_FAT_DEVICE="$(findfs LABEL=POCKETFORGE 2>/dev/null)"
    [ -n "$SF_V3_FAT_DEVICE" ] \
        && sf_v3_partition_on_selected_card "$SF_V3_FAT_DEVICE" || return 1
    SF_V3_FAT=/sf-v3-fat
    mkdir -p "$SF_V3_FAT" || return 1
    mount -t vfat -o rw,flush "$SF_V3_FAT_DEVICE" "$SF_V3_FAT" 2>/dev/null
}

sf_v3_unmount_target_fat() {
    umount "$SF_V3_FAT" 2>/dev/null
}

sf_v3_record_failure() {
    sf_v3_failure_phase="$1"
    sf_v3_failure_reason="$2"
    sf_v3_write_receipt failed "$sf_v3_failure_phase" "$sf_v3_failure_reason"
}

sf_v3_run_armed_transaction() {
    sf_v3_receipt_defaults || return 1
    SF_V3_INITRD_START_MS="$(sf_v3_now_ms)"
    SF_V3_WRITE_START_MS="$(sf_v3_now_ms)"
    export SF_V3_INITRD_START_MS SF_V3_WRITE_START_MS
    sf_v3_write_receipt started none none || return 1

    if ! sf_v3_stream_write; then
        SF_V3_WRITE_END_MS="$(sf_v3_now_ms)"
        export SF_V3_WRITE_END_MS
        if ! sf_v3_record_failure xz stream-failed; then
            printf 'self-flash-v3: failure receipt write failed after stream\n' >&2
        fi
        return 1
    fi
    SF_V3_WRITE_END_MS="$(sf_v3_now_ms)"
    export SF_V3_WRITE_END_MS

    if ! sf_v3_mount_target_fat; then
        if ! sf_v3_record_failure seed fat-mount-failed; then
            printf 'self-flash-v3: failure receipt write failed after FAT mount\n' >&2
        fi
        return 1
    fi
    if ! sf_v3_install_seed "$SF_V3_FAT"; then
        if ! sf_v3_record_failure seed seed-install-failed; then
            printf 'self-flash-v3: failure receipt write failed after seed\n' >&2
        fi
        if ! sf_v3_unmount_target_fat; then
            printf 'self-flash-v3: FAT cleanup unmount failed after seed\n' >&2
        fi
        return 1
    fi

    # The pass record is deliberately durable before the stamp. StampResult is
    # optimistic for this short interval; any stamp failure replaces the pass
    # record with failed, and the runner also requires the receipt-bound stamp.
    SF_V3_STAMP_RESULT=pass
    export SF_V3_STAMP_RESULT
    if ! sf_v3_write_receipt pass none none; then
        SF_V3_STAMP_RESULT=fail
        export SF_V3_STAMP_RESULT
        if ! sf_v3_record_failure receipt pass-receipt-failed; then
            printf 'self-flash-v3: failure receipt write failed after pass receipt\n' >&2
        fi
        if ! sf_v3_unmount_target_fat; then
            printf 'self-flash-v3: FAT cleanup unmount failed after pass receipt\n' >&2
        fi
        return 1
    fi
    if ! sf_v3_install_stamp "$SF_V3_FAT"; then
        rm -f "$SF_V3_FAT/pocketforge-self-flash-v3" \
            "$SF_V3_FAT/.pocketforge-self-flash-v3-$SF_V3_GENERATION.tmp"
        if ! sync; then
            printf 'self-flash-v3: stamp cleanup sync failed\n' >&2
        fi
        SF_V3_STAMP_RESULT=fail
        export SF_V3_STAMP_RESULT
        if ! sf_v3_record_failure stamp stamp-install-failed; then
            printf 'self-flash-v3: failure receipt write failed after stamp\n' >&2
        fi
        if ! sf_v3_unmount_target_fat; then
            printf 'self-flash-v3: FAT cleanup unmount failed after stamp\n' >&2
        fi
        return 1
    fi
    if ! sf_v3_unmount_target_fat; then
        if ! rm -f "$SF_V3_FAT/pocketforge-self-flash-v3"; then
            printf 'self-flash-v3: stamp removal failed after FAT unmount\n' >&2
        fi
        if ! sync; then
            printf 'self-flash-v3: stamp removal sync failed after FAT unmount\n' >&2
        fi
        SF_V3_STAMP_RESULT=fail
        export SF_V3_STAMP_RESULT
        if ! sf_v3_record_failure stamp fat-unmount-failed; then
            printf 'self-flash-v3: failure receipt write failed after FAT unmount\n' >&2
        fi
        return 1
    fi
}

sf_v3_clean_work() {
    [ -d "$SF_V3_WORK" ] || return 0
    rm -r "$SF_V3_WORK" || return 1
    mkdir -p "$SF_V3_WORK" || return 1
}

sf_v3_stream_write() {
    SF_V3_XZ_RESULT=fail
    SF_V3_RAW_STREAM_BYTES=unknown
    SF_V3_RAW_STREAM_SHA256=unknown
    SF_V3_RAW_STREAM_COUNT_MATCH=fail
    SF_V3_RAW_STREAM_HASH_MATCH=fail
    SF_V3_WRITE_RESULT=fail
    SF_V3_WRITE_METHOD=dd-fsync
    SF_V3_FULL_DEVICE_READBACK=not-performed
    export SF_V3_XZ_RESULT SF_V3_RAW_STREAM_BYTES SF_V3_RAW_STREAM_SHA256
    export SF_V3_RAW_STREAM_COUNT_MATCH SF_V3_RAW_STREAM_HASH_MATCH
    export SF_V3_WRITE_RESULT SF_V3_FULL_DEVICE_READBACK
    export SF_V3_WRITE_METHOD

    sf_v3_require_pipefail || return 1
    set -o pipefail || return 1
    case "$SF_V3_STAGE_OFFSET:$SF_V3_COMPRESSED_BYTES:$SF_V3_TARGET_RAW_BYTES" in
        *[!0-9:]*|:*|*::*|*:) return 1 ;;
    esac
    [ "$SF_V3_STAGE_OFFSET" -gt 0 ] 2>/dev/null || return 1
    [ "$SF_V3_COMPRESSED_BYTES" -gt 0 ] 2>/dev/null || return 1
    [ "$SF_V3_TARGET_RAW_BYTES" -gt 0 ] 2>/dev/null || return 1
    [ "${#SF_V3_TARGET_RAW_SHA256}" -eq 64 ] || return 1
    case "$SF_V3_TARGET_RAW_SHA256" in *[!0-9a-f]*) return 1 ;; esac
    [ -n "$SF_V3_SD" ] && [ -n "$SF_V3_WORK" ] || return 1

    mkdir -p "$SF_V3_WORK" || return 1
    sf_v3_clean_work || return 1
    sf_v3_hash_fifo="$SF_V3_WORK/raw-hash.fifo"
    sf_v3_count_fifo="$SF_V3_WORK/raw-count.fifo"
    sf_v3_hash_result="$SF_V3_WORK/raw-hash.result"
    sf_v3_count_result="$SF_V3_WORK/raw-count.result"
    mkfifo "$sf_v3_hash_fifo" "$sf_v3_count_fifo" || return 1

    sha256sum <"$sf_v3_hash_fifo" >"$sf_v3_hash_result" &
    sf_v3_hash_pid=$!
    wc -c <"$sf_v3_count_fifo" >"$sf_v3_count_result" &
    sf_v3_count_pid=$!

    if sf_v3_read_stage \
        | unxz \
        | tee "$sf_v3_hash_fifo" "$sf_v3_count_fifo" \
        | sf_v3_write_sink; then
        sf_v3_pipeline_rc=0
    else
        sf_v3_pipeline_rc=$?
    fi
    if wait "$sf_v3_hash_pid"; then sf_v3_hash_rc=0; else sf_v3_hash_rc=$?; fi
    if wait "$sf_v3_count_pid"; then sf_v3_count_rc=0; else sf_v3_count_rc=$?; fi

    if [ "$sf_v3_hash_rc" -eq 0 ]; then
        read -r SF_V3_RAW_STREAM_SHA256 sf_v3_hash_name <"$sf_v3_hash_result" \
            || SF_V3_RAW_STREAM_SHA256=unknown
    fi
    if [ "$sf_v3_count_rc" -eq 0 ]; then
        read -r SF_V3_RAW_STREAM_BYTES <"$sf_v3_count_result" \
            || SF_V3_RAW_STREAM_BYTES=unknown
    fi
    export SF_V3_RAW_STREAM_BYTES SF_V3_RAW_STREAM_SHA256

    # The hash/count side consumers observe the complete decompressed producer
    # stream, while count_bytes prevents the sink from crossing TargetRawBytes.
    # Thus even a buffered one-byte overrun is detected without writing it.
    if [ "$SF_V3_RAW_STREAM_BYTES" = "$SF_V3_TARGET_RAW_BYTES" ]; then
        SF_V3_RAW_STREAM_COUNT_MATCH=pass
    fi
    if [ "$SF_V3_RAW_STREAM_SHA256" = "$SF_V3_TARGET_RAW_SHA256" ]; then
        SF_V3_RAW_STREAM_HASH_MATCH=pass
    fi
    export SF_V3_RAW_STREAM_COUNT_MATCH SF_V3_RAW_STREAM_HASH_MATCH

    [ "$sf_v3_pipeline_rc" -eq 0 ] || { sf_v3_clean_work; return 1; }
    [ "$sf_v3_hash_rc" -eq 0 ] || { sf_v3_clean_work; return 1; }
    [ "$sf_v3_count_rc" -eq 0 ] || { sf_v3_clean_work; return 1; }
    [ "$SF_V3_RAW_STREAM_COUNT_MATCH" = pass ] \
        || { sf_v3_clean_work; return 1; }
    [ "$SF_V3_RAW_STREAM_HASH_MATCH" = pass ] \
        || { sf_v3_clean_work; return 1; }

    SF_V3_XZ_RESULT=pass
    SF_V3_WRITE_RESULT=pass
    export SF_V3_XZ_RESULT SF_V3_WRITE_RESULT
    sf_v3_clean_work
}

# The final receipt always records this literal. No v3 function reads the
# written image back; FEL recovery retains its separate full-readback contract.
sf_v3_receipt_readback_field() {
    printf '%s\n' 'FullDeviceReadback=not-performed'
}
