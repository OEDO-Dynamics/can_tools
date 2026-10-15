#!/bin/bash

# can_diag.sh - CAN bus error diagnostics
#
# BENCH / MACHINE-STOPPED USE ONLY.
#   Do not run this against a machine that is in operation: it pauses the
#   watchdog and temporarily enables berr-reporting on every CAN interface
#   while it captures error frames. Only use it on a test bench, or on a
#   machine that is mechanically locked out / powered down (hydraulics
#   locked, implement lowered, key state decided).
#
#   Sequence (Issue #9 §6, PR-C): can_pause -> can_lock -> berr-reporting on
#   -> capture (ip -j -d -s link show / sysfs counters / journalctl -k tail /
#   candump -L error-frame classification) for up to 60 s -> always restore
#   the original settings -> can_unpause (guaranteed by an EXIT/TERM/INT/HUP
#   trap). If the pause cannot be acquired, nothing is changed.

# ---------------------------------------------------------------------------
# Error-frame classification (linux/can/error.h), usable standalone
# ---------------------------------------------------------------------------
# These are defined unconditionally (not inside the execution guard below) so
# that test code can `source` this file and call diag_classify_line() / the
# name tables directly, with known candump -L lines, and check exact counts
# -- without running the whole capture pipeline. Sourcing this file has no
# side effects: it does not set -e/-u, does not parse argv, and does not
# touch any interface, lock or pause file.

declare -A error_counts=()

# CAN_ERR_PROT_LOC_* (data[3]): bit-field location of a protocol violation.
_diag_loc_name() {
    local v="$1"
    case "$v" in
        0) echo "UNSPEC" ;;
        2) echo "ID28_21" ;;
        3) echo "SOF" ;;
        4) echo "SRTR" ;;
        5) echo "IDE" ;;
        6) echo "ID20_18" ;;
        7) echo "ID17_13" ;;
        8) echo "CRC_SEQ" ;;
        9) echo "RES1" ;;
        10) echo "RTR" ;;
        11) echo "DLC" ;;
        13) echo "DATA" ;;
        14) echo "ID04_00" ;;
        15) echo "ID12_05" ;;
        18) echo "INTERM" ;;
        24) echo "CRC_DEL" ;;
        25) echo "ACK" ;;
        26) echo "EOF" ;;
        27) echo "ACK_DEL" ;;
        *) printf "UNKNOWN_0x%02X" "$v" ;;
    esac
}

# CAN_ERR_TRX_* (data[4]): transceiver status (CANH nibble low, CANL nibble high).
_diag_trx_name() {
    local v="$1"
    case "$v" in
        0) echo "UNSPEC" ;;
        4) echo "CANH_NO_WIRE" ;;
        5) echo "CANH_SHORT_TO_BAT" ;;
        6) echo "CANH_SHORT_TO_VCC" ;;
        7) echo "CANH_SHORT_TO_GND" ;;
        64) echo "CANL_NO_WIRE" ;;
        80) echo "CANL_SHORT_TO_BAT" ;;
        96) echo "CANL_SHORT_TO_VCC" ;;
        112) echo "CANL_SHORT_TO_GND" ;;
        128) echo "CANL_SHORT_TO_CANH" ;;
        *) printf "UNKNOWN_0x%02X" "$v" ;;
    esac
}

# diag_classify_line <candump -L line>
#
# Parses one line of `candump -L -e any,0~0,#FFFFFFFF` output:
#   (<timestamp>) <iface> <can_id_hex>#<data_hex>
# Returns 1 (and does nothing) for a line that does not parse, or that parses
# but is not an error frame (CAN_ERR_FLAG, 0x20000000, not set in the id) --
# i.e. ordinary data traffic also captured by the "any,0~0" filter.
#
# On an error frame, increments the global error_counts[] associative array,
# one entry per iface/category/name, counting EVERY set bit independently
# (a single frame can carry several simultaneous error indications).
# Categories, straight out of linux/can/error.h:
#   class  - can_id class bits (TX_TIMEOUT/LOSTARB/CRTL/PROT/TRX/ACK/
#            BUSOFF/BUSERROR/RESTARTED/CNT)
#   ctrl   - data[1] CAN_ERR_CRTL_* flags (only when class has CRTL set)
#   prot   - data[2] CAN_ERR_PROT_* flags (only when class has PROT set)
#   loc    - data[3] CAN_ERR_PROT_LOC_* location name (only when class has
#            PROT set and data[3] != 0)
#   trx    - data[4] CAN_ERR_TRX_* name (only when class has TRX set)
diag_classify_line() {
    local line="$1"
    local re_line='^\(([0-9]+(\.[0-9]+)?)\) ([^ ]+) ([0-9A-Fa-f]+)#([0-9A-Fa-f]*)$'

    [[ "$line" =~ $re_line ]] || return 1

    local f_iface="${BASH_REMATCH[3]}"
    local f_id_hex="${BASH_REMATCH[4]}"
    local f_data_hex="${BASH_REMATCH[5]}"

    local can_id=$((16#$f_id_hex))
    # CAN_ERR_FLAG not set -> ordinary data frame, not an error frame.
    (( can_id & 0x20000000 )) || return 1

    while (( ${#f_data_hex} < 16 )); do
        f_data_hex+="0"
    done

    local class=$((can_id & 0x1FFFFFFF))
    local d1=$((16#${f_data_hex:2:2}))
    local d2=$((16#${f_data_hex:4:2}))
    local d3=$((16#${f_data_hex:6:2}))
    local d4=$((16#${f_data_hex:8:2}))

    local k

    (( class & 0x01 )) && { k="$f_iface|class|TX_TIMEOUT"; error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
    (( class & 0x02 )) && { k="$f_iface|class|LOSTARB";    error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
    (( class & 0x04 )) && { k="$f_iface|class|CRTL";       error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
    (( class & 0x08 )) && { k="$f_iface|class|PROT";       error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
    (( class & 0x10 )) && { k="$f_iface|class|TRX";        error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
    (( class & 0x20 )) && { k="$f_iface|class|ACK";        error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
    (( class & 0x40 )) && { k="$f_iface|class|BUSOFF";     error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
    (( class & 0x80 )) && { k="$f_iface|class|BUSERROR";   error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
    (( class & 0x100 )) && { k="$f_iface|class|RESTARTED"; error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
    (( class & 0x1000000 )) && { k="$f_iface|class|CNT";   error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }

    if (( class & 0x04 )); then
        (( d1 & 0x01 )) && { k="$f_iface|ctrl|RX_OVERFLOW"; error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d1 & 0x02 )) && { k="$f_iface|ctrl|TX_OVERFLOW"; error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d1 & 0x04 )) && { k="$f_iface|ctrl|RX_WARNING";  error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d1 & 0x08 )) && { k="$f_iface|ctrl|TX_WARNING";  error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d1 & 0x10 )) && { k="$f_iface|ctrl|RX_PASSIVE";  error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d1 & 0x20 )) && { k="$f_iface|ctrl|TX_PASSIVE";  error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d1 & 0x40 )) && { k="$f_iface|ctrl|ACTIVE";      error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
    fi

    if (( class & 0x08 )); then
        (( d2 & 0x01 )) && { k="$f_iface|prot|BIT";      error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d2 & 0x02 )) && { k="$f_iface|prot|FORM";     error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d2 & 0x04 )) && { k="$f_iface|prot|STUFF";    error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d2 & 0x08 )) && { k="$f_iface|prot|BIT0";     error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d2 & 0x10 )) && { k="$f_iface|prot|BIT1";     error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d2 & 0x20 )) && { k="$f_iface|prot|OVERLOAD"; error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d2 & 0x40 )) && { k="$f_iface|prot|ACTIVE";   error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }
        (( d2 & 0x80 )) && { k="$f_iface|prot|TX";       error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 )); }

        if (( d3 != 0 )); then
            local loc_name
            loc_name=$(_diag_loc_name "$d3")
            k="$f_iface|loc|$loc_name"
            error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 ))
        fi
    fi

    if (( class & 0x10 )); then
        local trx_name
        trx_name=$(_diag_trx_name "$d4")
        k="$f_iface|trx|$trx_name"
        error_counts["$k"]=$(( ${error_counts["$k"]:-0} + 1 ))
    fi

    return 0
}

# diag_render_summary - print one "<iface> <cat>=<name> count=<n>" line per
# key in error_counts, sorted for stable output.
diag_render_summary() {
    if (( ${#error_counts[@]} == 0 )); then
        echo "(no error frames observed)"
        return 0
    fi

    local key iface cat name
    while IFS= read -r key; do
        IFS='|' read -r iface cat name <<<"$key"
        echo "$iface $cat=$name count=${error_counts[$key]}"
    done < <(printf '%s\n' "${!error_counts[@]}" | sort)
}

show_help() {
    cat <<EOF
Usage: $0 [duration_s]

Capture CAN bus error diagnostics. BENCH / MACHINE-STOPPED USE ONLY: this
pauses the watchdog and enables berr-reporting on every CAN interface while
it captures error frames. Use only:
  - On a test bench, or
  - During machine maintenance with mechanical systems locked out / powered
    down (hydraulics locked, implement lowered, key state decided).
Do not run this on a machine that is in operation.

Parameters:
  duration_s    Capture duration in seconds (1-${DIAG_DURATION_MAX}, default: ${DIAG_DURATION_DEFAULT})

Environment Variables (for testing/override):
  CAN_IFACES               Interfaces to monitor (default: can0 can1)
  CAN_TOOLS_RUN_DIR        Runtime directory (default: /run/can_tools)
  CAN_TOOLS_CONF           can_tools.conf path (default: /opt/can_tools/can_tools.conf)
  CAN_TOOLS_SYSFS_ROOT     sysfs root (default: /sys)
  CAN_TOOLS_IP_CMD         ip command override (for testing)
  CAN_TOOLS_CANDUMP_CMD    candump command override (for testing)
  CAN_TOOLS_JOURNALCTL_CMD journalctl command override (for testing)

Output:
  Diagnostics are saved to \$CAN_TOOLS_RUN_DIR/can_diag_TIMESTAMP.log

Examples:
  # Capture for 10 seconds (default)
  $0

  # Capture for 30 seconds
  $0 30

  # Test with fake commands
  CAN_TOOLS_IP_CMD=./tests/fakes/ip \\
  CAN_TOOLS_CANDUMP_CMD=./tests/diag_fakes/candump \\
  $0 5
EOF
}

# ---------------------------------------------------------------------------
# Execution (only when run directly, never when sourced by tests)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail

    # L1: -h/--help is checked before any argument validation, anywhere in argv.
    for _diag_arg in "$@"; do
        if [[ "$_diag_arg" == "-h" || "$_diag_arg" == "--help" ]]; then
            DIAG_DURATION_MAX=60
            DIAG_DURATION_DEFAULT=10
            show_help
            exit 0
        fi
    done

    DIAG_DURATION_MAX=60
    DIAG_DURATION_MIN=1
    DIAG_DURATION_DEFAULT=10
    diag_duration="${1:-$DIAG_DURATION_DEFAULT}"

    # L2: reject 0 (and anything non-numeric / out of range).
    if ! [[ "$diag_duration" =~ ^[0-9]+$ ]] || \
       (( diag_duration < DIAG_DURATION_MIN || diag_duration > DIAG_DURATION_MAX )); then
        echo "Usage: $0 [duration_s]  (${DIAG_DURATION_MIN}-${DIAG_DURATION_MAX}, default: ${DIAG_DURATION_DEFAULT}). Use -h for details." >&2
        exit 1
    fi

    # Source lib for can_lock/can_pause/can_setup_iface/... can_diag.sh MUST
    # use the same lock and pause mechanisms as the watchdog to ensure mutual
    # exclusion; a divergent implementation would break synchronization.
    if [[ -f "$(dirname "$0")/can_tools_lib.bash" ]]; then
        # shellcheck source=/dev/null
        source "$(dirname "$0")/can_tools_lib.bash"
    elif [[ -f "/opt/can_tools/can_tools_lib.bash" ]]; then
        # shellcheck source=/dev/null
        source /opt/can_tools/can_tools_lib.bash
    else
        echo "ERROR: can_tools_lib.bash not found (required for lock/pause)" >&2
        exit 1
    fi

    # can_now() reads this var without a ":-" default; under `set -u` an
    # unset (never exported) var trips "unbound variable". Give it a default
    # here rather than in the lib (lib is out of scope for this change).
    : "${CAN_TOOLS_FAKE_TIME_FILE:=}"

    # Globals read/written by cleanup().
    _pause_file=""
    _pre_existing_pause=""
    _pause_set=0
    _lock_held=0
    _berr_ifaces=()
    declare -A _orig_restart_ms=() _orig_fd=() _orig_berr=() _orig_admin=()
    _candump_pid=""
    _candump_out=""

    # cleanup() restores everything can_diag.sh may have changed, in the
    # reverse order it was acquired, and is wired to EXIT so it always runs
    # (normal return, `exit`, or set -e). TERM/INT/HUP are trapped separately
    # to turn a caught signal into a deterministic `exit`, which then invokes
    # this same EXIT trap exactly once (H2/M1/M2/M4).
    cleanup() {
        local rc=$?
        set +e

        # H2: make sure candump (and the `timeout` wrapping it) are not left
        # running past our own lifetime, holding fd 9 or chewing CPU. `timeout`
        # is started with --kill-after so it SIGKILLs a candump that ignores
        # the forwarded TERM; the loop below just waits for that to happen,
        # and pkill -P / kill as a fallback covers a `timeout` that, for
        # whatever reason, didn't.
        if [[ -n "$_candump_pid" ]] && kill -0 "$_candump_pid" 2>/dev/null; then
            kill -TERM "$_candump_pid" 2>/dev/null
            for _diag_i in $(seq 1 20); do
                kill -0 "$_candump_pid" 2>/dev/null || break
                sleep 0.2
            done
            if kill -0 "$_candump_pid" 2>/dev/null; then
                pkill -KILL -P "$_candump_pid" 2>/dev/null || true
                kill -KILL "$_candump_pid" 2>/dev/null || true
            fi
            wait "$_candump_pid" 2>/dev/null
        fi
        [[ -n "$_candump_out" ]] && rm -f "$_candump_out"

        # H1: restore every interface we touched to its ORIGINAL restart-ms /
        # fd / berr-reporting (txqueuelen/bitrate/dbitrate come from conf,
        # which we never changed). Only attempted if we actually hold the
        # lock (if we never got the lock, we never touched any interface).
        if (( _lock_held )); then
            for _diag_if in "${_berr_ifaces[@]}"; do
                if ! CAN_RESTART_MS="${_orig_restart_ms[$_diag_if]:-${CAN_RESTART_MS:-100}}" \
                   CAN_FD="${_orig_fd[$_diag_if]:-${CAN_FD:-off}}" \
                   CAN_BERR_REPORTING="${_orig_berr[$_diag_if]:-off}" \
                   CAN_BITRATE="${CAN_BITRATE:-250000}" \
                   CAN_DBITRATE="${CAN_DBITRATE:-2000000}" \
                   CAN_TXQUEUELEN="${CAN_TXQUEUELEN:-10}" \
                   can_setup_iface "$_diag_if"; then
                    echo "[can_diag] WARNING: failed to restore $_diag_if to its original settings" >&2
                fi
            done
        fi

        # M1/M2: only ever undo the pause WE set. If one was already active
        # (another can_diag, or an operator), put its exact deadline back
        # instead of deleting it; otherwise remove ours.
        if (( _pause_set )); then
            if [[ -n "$_pre_existing_pause" ]]; then
                echo "$_pre_existing_pause" >"$_pause_file" 2>/dev/null || true
            else
                can_unpause || true
            fi
        fi

        if (( _lock_held )); then
            can_unlock || true
        fi

        if (( rc != 0 )); then
            echo "[can_diag] cleanup ran, exit rc=$rc" >&2
        fi
        exit "$rc"
    }
    trap cleanup EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP

    main() {
        # Conf gives us the "ground truth" for bitrate/dbitrate/txqueuelen,
        # none of which can_iface_states can observe from `ip -d link show`.
        can_read_conf || true

        local run_dir="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
        mkdir -p "$run_dir" 2>/dev/null || true
        _pause_file="$run_dir/watchdog.pause"
        if [[ -f "$_pause_file" ]]; then
            _pre_existing_pause=$(cat "$_pause_file" 2>/dev/null || true)
        fi

        # M1: pause is mandatory. If we cannot get it, abort with NO changes
        # made (we have not touched the lock or any interface yet).
        if ! can_pause 2; then
            echo "ERROR: failed to set watchdog pause; aborting without changes" >&2
            exit 1
        fi
        _pause_set=1

        # §6: pause -> lock.
        if ! can_lock 5; then
            echo "ERROR: failed to acquire can_lock (another can_tools operation in progress?)" >&2
            exit 1
        fi
        _lock_held=1

        local diag_file
        diag_file="${run_dir}/can_diag_$(date +%s).log"
        {
            echo "=== CAN Error Diagnostics ==="
            echo "Timestamp: $(date -Iseconds)"
            echo "Duration: ${diag_duration}s (max: ${DIAG_DURATION_MAX}s)"
            echo ""
        } >"$diag_file"

        # H1: observe the CURRENT (pre-diag) restart-ms/berr/fd/admin for
        # every CAN interface, via the lib's bounded `ip -d link show`.
        local states_file="$run_dir/diag_states_$$.tmp"
        local states_rc=0
        can_iface_states >"$states_file" || states_rc=$?

        if (( states_rc != 0 )); then
            echo "WARNING: could not read interface states (rc=$states_rc); skipping berr-reporting toggle" >>"$diag_file"
        else
            local if_name if_state rest rm_val berr_val fd_val admin_val
            while read -r if_name if_state rest; do
                [[ -z "$if_name" ]] && continue
                rm_val="" berr_val="" fd_val="" admin_val=""
                [[ "$rest" =~ restart_ms=([0-9]+) ]] && rm_val="${BASH_REMATCH[1]}"
                [[ "$rest" =~ berr=([a-z-]+) ]] && berr_val="${BASH_REMATCH[1]}"
                [[ "$rest" =~ fd=([a-z-]+) ]] && fd_val="${BASH_REMATCH[1]}"
                [[ "$rest" =~ admin=([a-z]+) ]] && admin_val="${BASH_REMATCH[1]}"
                _orig_restart_ms[$if_name]="$rm_val"
                _orig_berr[$if_name]="$berr_val"
                _orig_fd[$if_name]="$fd_val"
                _orig_admin[$if_name]="$admin_val"
                : "$if_state"  # state itself not needed beyond having matched a CAN line
            done <"$states_file"
        fi
        rm -f "$states_file"

        echo "=== Interface Setup ===" >>"$diag_file"
        local _diag_if
        for _diag_if in "${!_orig_admin[@]}"; do
            if [[ "${_orig_admin[$_diag_if]}" != "up" ]]; then
                echo "$_diag_if: admin down, skipped (operator-owned)" >>"$diag_file"
                continue
            fi
            if CAN_RESTART_MS="${_orig_restart_ms[$_diag_if]:-100}" \
               CAN_FD="${_orig_fd[$_diag_if]:-off}" \
               CAN_BERR_REPORTING=on \
               CAN_BITRATE="${CAN_BITRATE:-250000}" \
               CAN_DBITRATE="${CAN_DBITRATE:-2000000}" \
               CAN_TXQUEUELEN="${CAN_TXQUEUELEN:-10}" \
               can_setup_iface "$_diag_if"; then
                echo "$_diag_if: berr-reporting enabled for capture" >>"$diag_file"
            else
                # L5: do not silently swallow this - record it and move on.
                echo "$_diag_if: FAILED to enable berr-reporting (continuing with other interfaces)" >>"$diag_file"
            fi
            _berr_ifaces+=("$_diag_if")
        done
        echo "" >>"$diag_file"

        # H3: `ip` goes through can_run_bounded, called as a plain command
        # (never inside $() / < <() / a pipe - see the contract note in
        # can_tools_lib.bash) so WD_RTNL_TIMEOUT_S actually bounds it.
        echo "=== IP Link Show (ip -j -d -s link show type can) ===" >>"$diag_file"
        can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "${CAN_TOOLS_IP_CMD:-ip}" -j -d -s link show type can >>"$diag_file" 2>&1 || true

        # M5: sysfs stats go through the lib's can_read_stats(), which
        # honors CAN_TOOLS_SYSFS_ROOT, instead of a hardcoded /sys/class/net.
        echo "" >>"$diag_file"
        echo "=== sysfs Statistics (root: ${CAN_TOOLS_SYSFS_ROOT:-/sys}) ===" >>"$diag_file"
        local ifaces="${CAN_IFACES:-can0 can1}"
        local sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
        local _diag_stat_if
        for _diag_stat_if in $ifaces; do
            echo "$_diag_stat_if:" >>"$diag_file"
            local stats_line
            if stats_line=$(can_read_stats "$_diag_stat_if"); then
                local rx tx rxfifo txfifo ifindex
                read -r rx tx rxfifo txfifo ifindex <<<"$stats_line"
                {
                    echo "  rx_packets: $rx"
                    echo "  tx_packets: $tx"
                    echo "  rx_fifo_errors: $rxfifo"
                    echo "  tx_fifo_errors: $txfifo"
                    echo "  ifindex: $ifindex"
                } >>"$diag_file"
            else
                echo "  (no sysfs stats available)" >>"$diag_file"
            fi
            local qlen_file="$sysfs_root/class/net/$_diag_stat_if/tx_queue_len"
            [[ -f "$qlen_file" ]] && echo "  tx_queue_len: $(cat "$qlen_file" 2>/dev/null)" >>"$diag_file"
        done

        echo "" >>"$diag_file"
        echo "=== kernel log (last 50 lines) ===" >>"$diag_file"
        # H2: close fd 9 for this child too.
        "${CAN_TOOLS_JOURNALCTL_CMD:-journalctl}" -k -n 50 --no-pager 9>&- >>"$diag_file" 2>&1 || true

        echo "" >>"$diag_file"
        echo "=== CAN Error Frames (candump -L -e any,0~0,#FFFFFFFF, ${diag_duration}s) ===" >>"$diag_file"

        _candump_out=$(mktemp -p "$run_dir" candump_XXXXXX.txt)
        # H2: 9>&- so the lock fd is never visible to candump or the
        # `timeout` wrapping it; backgrounded so a signal to us does not
        # have to wait on `timeout` before cleanup can run. --kill-after
        # makes `timeout` itself SIGKILL candump if it ignores the TERM
        # that `timeout` forwards (its own deadline, or one we send it from
        # cleanup on SIGTERM/SIGINT/SIGHUP).
        timeout --kill-after=2 "$((diag_duration + 1))" \
            "${CAN_TOOLS_CANDUMP_CMD:-candump}" -L -e any,0~0,"#FFFFFFFF" \
            9>&- >"$_candump_out" 2>&1 &
        _candump_pid=$!
        wait "$_candump_pid" || true
        _candump_pid=""

        local line
        while IFS= read -r line; do
            diag_classify_line "$line" && echo "$line" >>"$diag_file"
        done <"$_candump_out"

        echo "" >>"$diag_file"
        echo "=== Error Frame Summary ===" >>"$diag_file"
        diag_render_summary >>"$diag_file"

        echo ""
        echo "Diagnostics saved to: $diag_file"
        echo "To view: cat $diag_file"
        return 0
    }

    main
fi
