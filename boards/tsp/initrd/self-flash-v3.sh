#!/bin/sh
# PocketForge self-flash v3 initrd engine.
#
# This file is sourced by /init and directly by the hermetic tests. Definitions
# therefore have no boot-time side effects. The caller validates the arm/card
# contract before populating the SF_V3_* values consumed here.

SF_V3_TRANSFER_BYTES=4194304

sf_v3_require_pipefail() {
    (set -o pipefail) >/dev/null 2>&1
}

sf_v3_read_stage() {
    dd if="$SF_V3_SD" bs="$SF_V3_TRANSFER_BYTES" \
        skip="$SF_V3_STAGE_OFFSET" count="$SF_V3_COMPRESSED_BYTES" \
        iflag=skip_bytes,count_bytes,fullblock status=none
}

sf_v3_write_sink() {
    dd of="$SF_V3_SD" bs="$SF_V3_TRANSFER_BYTES" \
        count="$SF_V3_TARGET_RAW_BYTES" iflag=count_bytes,fullblock \
        conv=notrunc,fsync status=none
}

sf_v3_clean_work() {
    [ -d "$SF_V3_WORK" ] || return 0
    find "$SF_V3_WORK" -mindepth 1 -delete || return 1
}

sf_v3_stream_write() {
    SF_V3_XZ_RESULT=fail
    SF_V3_RAW_STREAM_BYTES=unknown
    SF_V3_RAW_STREAM_SHA256=unknown
    SF_V3_RAW_STREAM_COUNT_MATCH=fail
    SF_V3_RAW_STREAM_HASH_MATCH=fail
    SF_V3_WRITE_RESULT=fail
    SF_V3_FULL_DEVICE_READBACK=not-performed
    export SF_V3_XZ_RESULT SF_V3_RAW_STREAM_BYTES SF_V3_RAW_STREAM_SHA256
    export SF_V3_RAW_STREAM_COUNT_MATCH SF_V3_RAW_STREAM_HASH_MATCH
    export SF_V3_WRITE_RESULT SF_V3_FULL_DEVICE_READBACK

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
