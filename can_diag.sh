#!/bin/bash

# can_diag.sh - CAN bus error diagnostics
# ⚠️  BENCH/FIXED-MACHINE MODE ONLY ⚠️
#   Do not use during normal operation. Pauses watchdog, enables error reporting,
#   captures CAN error frames for up to 60 seconds, then restores settings.
#   Uses can_lock to prevent concurrent access.

set -euo pipefail

# Defaults
readonly DIAG_DURATION_MAX=60

# Parse arguments
diag_duration="${1:-10}"

# Validate duration
if ! [[ "$diag_duration" =~ ^[0-9]+$ ]] || (( diag_duration > DIAG_DURATION_MAX )); then
    echo "Usage: $0 [duration_s] (max: $DIAG_DURATION_MAX)" >&2
    exit 1
fi

# Source lib for can_lock, can_pause, can_unpause, can_log
# can_diag.sh MUST use the same lock and pause mechanisms as the watchdog
# to ensure mutual exclusion. Divergent implementations would break synchronization.
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

# Trap to restore settings on exit
cleanup() {
    local rc=$?

    # Always restore berr-reporting and unpause watchdog
    if [[ -n "${_berr_restore_ifaces:-}" ]]; then
        for iface in $_berr_restore_ifaces; do
            ${CAN_TOOLS_IP_CMD:-ip} link set "$iface" down >/dev/null 2>&1 || true
            # Restore original berr-reporting state
            # For now, turn off (known default in env)
            ${CAN_TOOLS_IP_CMD:-ip} link set "$iface" up \
                type can bitrate "${CAN_BITRATE:-250000}" \
                restart-ms "${CAN_RESTART_MS:-100}" \
                berr-reporting off \
                >/dev/null 2>&1 || true
        done
    fi

    can_unpause || true
    can_unlock || true

    [[ $rc -ne 0 ]] && echo "[can_diag] error during cleanup, rc=$rc" >&2
    return $rc
}

trap cleanup EXIT

# Main diagnostic loop
main() {
    local run_dir="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
    local diag_file
    diag_file="${run_dir}/can_diag_$(date +%s).log"
    mkdir -p "$run_dir" 2>/dev/null || true

    # Acquire lock and pause watchdog
    can_lock 5 || {
        echo "ERROR: Failed to acquire CAN lock" >&2
        return 1
    }
    can_pause 2 || {
        echo "WARNING: Failed to set pause" >&2
        # Continue anyway, lock is held
    }

    # Enable berr-reporting on all CAN interfaces
    local ifaces
    ifaces="${CAN_IFACES:-can0 can1}"
    _berr_restore_ifaces="$ifaces"

    echo "=== CAN Error Diagnostics ===" >"$diag_file"
    echo "Timestamp: $(date -Iseconds)" >>"$diag_file"
    echo "Duration: ${diag_duration}s (max: ${DIAG_DURATION_MAX}s)" >>"$diag_file"
    echo "" >>"$diag_file"

    # Set berr-reporting on
    for iface in $ifaces; do
        ${CAN_TOOLS_IP_CMD:-ip} link set "$iface" down >/dev/null 2>&1 || true
        ${CAN_TOOLS_IP_CMD:-ip} link set "$iface" up \
            type can bitrate "${CAN_BITRATE:-250000}" \
            restart-ms "${CAN_RESTART_MS:-100}" \
            berr-reporting on \
            >/dev/null 2>&1 || true
    done

    echo "=== IP Link Show ===" >>"$diag_file"
    ${CAN_TOOLS_IP_CMD:-ip} -j -d -s link show type can 2>/dev/null | jq . >>"$diag_file" 2>/dev/null || \
        ${CAN_TOOLS_IP_CMD:-ip} -d -s link show type can >>"$diag_file" 2>&1

    echo "" >>"$diag_file"
    echo "=== sysfs Statistics ===" >>"$diag_file"
    for iface in $ifaces; do
        echo "$iface:" >>"$diag_file"
        [[ -f "/sys/class/net/$iface/statistics/rx_packets" ]] && \
            echo "  rx_packets: $(cat /sys/class/net/$iface/statistics/rx_packets 2>/dev/null)" >>"$diag_file"
        [[ -f "/sys/class/net/$iface/statistics/tx_packets" ]] && \
            echo "  tx_packets: $(cat /sys/class/net/$iface/statistics/tx_packets 2>/dev/null)" >>"$diag_file"
        [[ -f "/sys/class/net/$iface/statistics/rx_fifo_errors" ]] && \
            echo "  rx_fifo_errors: $(cat /sys/class/net/$iface/statistics/rx_fifo_errors 2>/dev/null)" >>"$diag_file"
        [[ -f "/sys/class/net/$iface/statistics/tx_fifo_errors" ]] && \
            echo "  tx_fifo_errors: $(cat /sys/class/net/$iface/statistics/tx_fifo_errors 2>/dev/null)" >>"$diag_file"
    done

    echo "" >>"$diag_file"
    echo "=== kernel log (last 50 lines) ===" >>"$diag_file"
    ${CAN_TOOLS_JOURNALCTL_CMD:-journalctl} -k -n 50 --no-pager >>"$diag_file" 2>&1 || true

    echo "" >>"$diag_file"
    echo "=== CAN Error Frames (candump, ${diag_duration}s) ===" >>"$diag_file"

    # Classify error frames during capture
    local candump_out
    candump_out=$(mktemp -p "$run_dir" candump_XXXXXX.txt)
    # shellcheck disable=SC2064
    trap "rm -f '$candump_out'; cleanup" EXIT

    # Run candump with timeout, capture error frames
    # Using timeout to ensure we don't wait indefinitely
    timeout "$((diag_duration + 1))" \
        "${CAN_TOOLS_CANDUMP_CMD:-candump}" -e any,0~0,"#FFFFFFFF" >"$candump_out" 2>&1 || true

    # Classify and aggregate error frames
    local -A error_counts
    local -A error_details
    local line

    while IFS= read -r line; do
        # Parse candump error frame: (interface) error_id#data[0]...
        # Example: (can0) C0000104#1800000010000000
        # data[2] bits: 0=bit, 1=form, 2=stuff, 3=bit0, 4=bit1
        # data[3] = position
        # Look for CAN_ERR_* indicators in the frame data

        if [[ "$line" =~ ^'('([^)]+')' ]]; then
            local iface="${BASH_REMATCH[1]}"
            # Extract error flags from remaining line
            # Format: C0000104#DDHH000010000000 where DD=data[2], HH=data[3]
            if [[ "$line" =~ '#'([0-9A-Fa-f]{16}) ]]; then
                local data_hex="${BASH_REMATCH[1]}"
                # Extract data[2] (byte 2)  and data[3] (byte 3)
                local data2="${data_hex:4:2}"
                local data3="${data_hex:6:2}"
                local error_class="unknown"

                # Convert hex bytes to decimal for classification
                local d2_dec=$((16#${data2:-00}))
                local d3_dec=$((16#${data3:-00}))

                # Classify by error type
                if (( d2_dec & 0x01 )); then error_class="bit_error"; fi
                if (( d2_dec & 0x02 )); then error_class="form_error"; fi
                if (( d2_dec & 0x04 )); then error_class="stuff_error"; fi
                if (( d2_dec & 0x08 )); then error_class="bit0_error"; fi
                if (( d2_dec & 0x10 )); then error_class="bit1_error"; fi

                # Check for ACK/PROT errors
                if (( d2_dec & 0x20 )); then error_class="ack_error"; fi
                if (( d2_dec & 0x40 )); then error_class="prot_error"; fi

                local key="${iface}_${error_class}"
                (( error_counts[$key]++ )) || error_counts[$key]=1
                error_details[$key]="position=$d3_dec"
            fi
            echo "$line" >>"$diag_file"
        fi
    done <"$candump_out"

    # Write error summary
    echo "" >>"$diag_file"
    echo "=== Error Frame Summary ===" >>"$diag_file"
    for key in "${!error_counts[@]}"; do
        echo "$key: ${error_counts[$key]} (${error_details[$key]:-})" >>"$diag_file"
    done

    # Output file path
    echo ""
    echo "Diagnostics saved to: $diag_file"
    echo "To view: cat $diag_file"
    return 0
}

# Show help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<EOF
Usage: $0 [duration_s]

Capture CAN bus error diagnostics (bench/fixed-machine mode only).

⚠️  WARNING: This script pauses watchdog monitoring, enables error reporting,
    and captures CAN error frames for diagnostic analysis. Use only:
    - During machine maintenance (mechanical systems locked/powered down)
    - On test benches
    - With caution in production environments (watchdog is paused)

Parameters:
  duration_s    Capture duration in seconds (1-60, default: 10)

Environment Variables (for testing/override):
  CAN_IFACES              Interfaces to monitor (default: can0 can1)
  CAN_BITRATE             CAN bitrate (default: 250000)
  CAN_RESTART_MS          Restart timeout (default: 100)
  CAN_TOOLS_RUN_DIR       Runtime directory (default: /run/can_tools)
  CAN_TOOLS_IP_CMD        ip command override (for testing)
  CAN_TOOLS_CANDUMP_CMD   candump command override (for testing)
  CAN_TOOLS_JOURNALCTL_CMD journalctl command override (for testing)

Output:
  Diagnostics are saved to /run/can_tools/can_diag_TIMESTAMP.log

Examples:
  # Capture for 10 seconds (default)
  $0

  # Capture for 30 seconds
  $0 30

  # Test with fake commands
  CAN_TOOLS_IP_CMD=./tests/fakes/ip \\
  CAN_TOOLS_CANDUMP_CMD=./tests/fakes/candump \\
  $0 5
EOF
    exit 0
fi

main "$@"
