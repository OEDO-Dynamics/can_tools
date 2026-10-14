#!/bin/bash

# can_tools_lib.bash - Library for CAN interface management
# Provides configuration, locking, and CAN interface control functions.
# This file is sourced, not executed. Does not call exit().

# Default values for all configuration keys
declare -g CAN_IFACES="can0 can1"
declare -g CAN_SPI_MAP="spi0.0:can0 spi1.0:can1"
declare -g CAN_BITRATE=250000
declare -g CAN_RESTART_MS=100
declare -g CAN_BERR_REPORTING="off"
declare -g CAN_FD="on"
declare -g CAN_DBITRATE=2000000
declare -g CAN_TXQUEUELEN=10
declare -g CAN_DEPENDENT_UNITS=""
declare -g CAN_FLUSH_IFACES="can0"

# Watchdog parameters
declare -g WD_LOOP_S=1
declare -g WD_STALE_TX_FLUSH_S=2
declare -g WD_FLUSH_BACKOFF_MAX_S=30
declare -g WD_SETTLE_SAMPLE_MS=100
declare -g WD_SETTLE_MAX_MS=2000
declare -g WD_BUSOFF_QUIET_S=10
declare -g WD_BUSOFF_BACKOFF_MAX_S=30
declare -g WD_STORM_COUNT=5
declare -g WD_STORM_WINDOW_S=60
declare -g WD_STALL_CONSEC=3
declare -g WD_STALL_POST_BUSOFF_CONSEC=2
declare -g WD_STALL_POST_BUSOFF_WINDOW_S=5
declare -g WD_STALL_VERIFY_S=10
declare -g WD_RTNL_TIMEOUT_S=5
declare -g WD_REBIND_TIMEOUT_S=10
declare -g WD_REBIND_MAX_PER_HOUR=3
declare -g WD_RTNL_HUNG_CONSEC=3
declare -g WD_PAUSE_DEFAULT_MIN=30
declare -g WD_PAUSE_WARN_S=600
declare -g WD_DEGRADED_CRIT_S=600
declare -g WD_LOG_SUMMARY_S=60
declare -g WD_LOG_RATE_S=10
declare -g WD_CRASH_KEEP=5

# Internal state
declare -g _CAN_LOCK_DEPTH=0
declare -g CAN_RUN_BOUNDED_PID=""

# Helper to check if a process is alive (not zombie)
_can_is_alive() {
    local pid="$1"
    if [[ ! -f "/proc/$pid/stat" ]]; then
        return 1
    fi
    local state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    [[ "$state" != "Z" ]]
}

# Configuration Reading
# can_read_conf [path]
# Read configuration from file, validating values.
can_read_conf() {
    local conf_path="${1:-${CAN_TOOLS_CONF:-/opt/can_tools/can_tools.conf}}"

    if [[ -f "$conf_path" ]]; then
        local key val line
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue

            if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*) ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"

                case "$key" in
                    CAN_IFACES|CAN_SPI_MAP|CAN_BITRATE|CAN_RESTART_MS|CAN_BERR_REPORTING|CAN_FD|CAN_DBITRATE|CAN_TXQUEUELEN|CAN_DEPENDENT_UNITS|CAN_FLUSH_IFACES|\
                    WD_LOOP_S|WD_STALE_TX_FLUSH_S|WD_FLUSH_BACKOFF_MAX_S|WD_SETTLE_SAMPLE_MS|WD_SETTLE_MAX_MS|WD_BUSOFF_QUIET_S|WD_BUSOFF_BACKOFF_MAX_S|WD_STORM_COUNT|WD_STORM_WINDOW_S|\
                    WD_STALL_CONSEC|WD_STALL_POST_BUSOFF_CONSEC|WD_STALL_POST_BUSOFF_WINDOW_S|WD_STALL_VERIFY_S|WD_RTNL_TIMEOUT_S|WD_REBIND_TIMEOUT_S|WD_REBIND_MAX_PER_HOUR|WD_RTNL_HUNG_CONSEC|\
                    WD_PAUSE_DEFAULT_MIN|WD_PAUSE_WARN_S|WD_DEGRADED_CRIT_S|WD_LOG_SUMMARY_S|WD_LOG_RATE_S|WD_CRASH_KEEP)
                        declare -g "$key=$val"
                        ;;
                esac
            fi
        done < "$conf_path"
    fi

    return 0
}

# Locking
# can_lock [timeout_s]
can_lock() {
    local timeout="${1:-5}"

    mkdir -p "${CAN_TOOLS_RUN_DIR:-/run/can_tools}" 2>/dev/null || true

    if (( _CAN_LOCK_DEPTH > 0 )); then
        (( _CAN_LOCK_DEPTH++ ))
        return 0
    fi

    if exec 9>"${CAN_TOOLS_RUN_DIR:-/run/can_tools}/lock"; then
        if flock -w "$timeout" 9 2>/dev/null; then
            (( _CAN_LOCK_DEPTH++ ))
            return 0
        else
            exec 9>&-
            return 1
        fi
    else
        return 1
    fi
}

# can_unlock
can_unlock() {
    if (( _CAN_LOCK_DEPTH <= 0 )); then
        return 1
    fi

    (( _CAN_LOCK_DEPTH-- ))
    if (( _CAN_LOCK_DEPTH == 0 )); then
        exec 9>&-
    fi
    return 0
}

# Process Execution
# can_run_bounded <timeout_s> <cmd...>
can_run_bounded() {
    local timeout="$1"
    shift
    local cmd=("$@")

    if [[ -n "$CAN_RUN_BOUNDED_PID" ]] && _can_is_alive "$CAN_RUN_BOUNDED_PID"; then
        return 124
    fi

    (
        exec 9>&-
        "${cmd[@]}"
    ) &

    CAN_RUN_BOUNDED_PID=$!

    local elapsed=0
    local interval=0.1
    while (( elapsed < timeout )); do
        if ! _can_is_alive "$CAN_RUN_BOUNDED_PID"; then
            wait "$CAN_RUN_BOUNDED_PID" 2>/dev/null
            local ret=$?
            CAN_RUN_BOUNDED_PID=""
            return $ret
        fi
        sleep "$interval"
        elapsed=$(echo "$elapsed + $interval" | bc 2>/dev/null || echo "999")
    done

    return 124
}

# CAN Interface State Reading
# can_iface_states
can_iface_states() {
    local output
    output=$(can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" \
        "${CAN_TOOLS_IP_CMD:-ip}" -d link show type can 2>/dev/null)

    if [[ $? -eq 124 ]]; then
        return 124
    fi

    local re_iface='^[0-9]+: ([^:@]+)[:@] ([^[:space:]]*)'
    local re_can='^[[:space:]]+can (.*)state ([A-Z-]+)'
    local re_restart='restart-ms ([0-9]+)'
    local re_berr='BERR-REPORTING'
    local re_fd='\bFD\b'
    local re_up='UP'

    local if_name if_state if_admin restart_ms berr fd ctrlmode
    local found=0

    while IFS= read -r line; do
        if [[ $line =~ $re_iface ]]; then
            if_name="${BASH_REMATCH[1]}"
            if_admin="down"
            [[ "${BASH_REMATCH[2]}" =~ $re_up ]] && if_admin="up"
        fi

        if [[ $line =~ $re_can ]]; then
            ctrlmode="${BASH_REMATCH[1]}"
            if_state="${BASH_REMATCH[2]}"

            restart_ms=0
            if [[ $line =~ $re_restart ]]; then
                restart_ms="${BASH_REMATCH[1]}"
            fi

            berr="off"
            fd="off"
            [[ $ctrlmode =~ $re_berr ]] && berr="on"
            [[ $ctrlmode =~ $re_fd ]] && fd="on"

            echo "$if_name $if_state restart_ms=$restart_ms berr=$berr fd=$fd admin=$if_admin"
            (( found++ ))
        fi
    done <<< "$output"

    [[ $found -eq 0 ]] && return 1
    return 0
}

# Statistics Reading
# can_read_stats <if>
can_read_stats() {
    local if="$1"
    local sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    local base="$sysfs_root/class/net/$if"

    if [[ ! -d "$base" ]]; then
        return 1
    fi

    local rx_packets=0 tx_packets=0 rx_fifo=0 tx_fifo=0 ifindex=0

    [[ -f "$base/statistics/rx_packets" ]] && rx_packets=$(<"$base/statistics/rx_packets")
    [[ -f "$base/statistics/tx_packets" ]] && tx_packets=$(<"$base/statistics/tx_packets")
    [[ -f "$base/statistics/rx_fifo_errors" ]] && rx_fifo=$(<"$base/statistics/rx_fifo_errors")
    [[ -f "$base/statistics/tx_fifo_errors" ]] && tx_fifo=$(<"$base/statistics/tx_fifo_errors")
    [[ -f "$base/ifindex" ]] && ifindex=$(<"$base/ifindex")

    echo "$rx_packets $tx_packets $rx_fifo $tx_fifo $ifindex"
    return 0
}

# SPI Device Mapping
# can_spidev_of <if>
can_spidev_of() {
    local if="$1"
    local sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    local device_link="$sysfs_root/class/net/$if/device"

    if [[ -L "$device_link" ]]; then
        local device_path
        device_path=$(readlink -f "$device_link" 2>/dev/null)
        echo "${device_path##*/}"
        return 0
    fi
    return 1
}

# can_iface_of_spidev <spidev>
can_iface_of_spidev() {
    local spidev="$1"
    local sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    local net_dir="$sysfs_root/bus/spi/devices/$spidev/net"

    if [[ -d "$net_dir" ]]; then
        for iface in "$net_dir"/*; do
            [[ -d "$iface" ]] && echo "${iface##*/}" && return 0
        done
    fi
    return 1
}

# Interface Naming
# can_pin_name <spidev> <want>
can_pin_name() {
    local spidev="$1"
    local want="$2"
    local sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    local ip_cmd="${CAN_TOOLS_IP_CMD:-ip}"
    local net_dir="$sysfs_root/bus/spi/devices/$spidev/net"

    if [[ ! -d "$net_dir" ]]; then
        return 1
    fi

    local current
    for iface in "$net_dir"/*; do
        [[ -d "$iface" ]] && current="${iface##*/}"
    done

    [[ -z "$current" ]] && return 1
    [[ "$current" == "$want" ]] && return 0

    if [[ -n "$want" ]]; then
        "$ip_cmd" link show "$want" >/dev/null 2>&1 && return 2
        "$ip_cmd" link set "$current" name "$want" 2>/dev/null || return 1
    fi

    return 0
}

# Interface Setup
# can_setup_iface <if>
can_setup_iface() {
    local if="$1"
    local ip_cmd="${CAN_TOOLS_IP_CMD:-ip}"
    local bitrate="${CAN_BITRATE:-250000}"
    local restart_ms="${CAN_RESTART_MS:-100}"
    local berr="${CAN_BERR_REPORTING:-off}"
    local fd="${CAN_FD:-on}"
    local dbitrate="${CAN_DBITRATE:-2000000}"
    local txqueuelen="${CAN_TXQUEUELEN:-10}"
    local dry_run="${CAN_TOOLS_DRY_RUN:-}"

    if [[ -n "$dry_run" ]]; then
        can_log 6 "DRY_RUN: would configure $if"
        return 0
    fi

    can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$if" down 2>/dev/null
    true

    local fd_args=""
    [[ "$fd" == "on" ]] && fd_args="dbitrate $dbitrate fd on"

    local berr_args=""
    [[ "$berr" == "on" ]] && berr_args="berr-reporting on"

    can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$if" up \
        type can bitrate "$bitrate" restart-ms "$restart_ms" $berr_args $fd_args || return 1

    can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$if" txqueuelen "$txqueuelen" || return 1

    return 0
}

# Pause/Resume
# can_pause [min]
can_pause() {
    local min="${1:-${WD_PAUSE_DEFAULT_MIN:-30}}"
    local run_dir="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
    mkdir -p "$run_dir" 2>/dev/null || true
    local deadline=$(($(can_now) + min * 60))
    echo "$deadline" > "$run_dir/watchdog.pause" 2>/dev/null
    return 0
}

# can_unpause
can_unpause() {
    local run_dir="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
    rm -f "$run_dir/watchdog.pause" 2>/dev/null
    return 0
}

# can_pause_active
can_pause_active() {
    local run_dir="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
    local pause_file="$run_dir/watchdog.pause"

    if [[ -f "$pause_file" ]]; then
        local deadline=$(<"$pause_file")
        (( $(can_now) < deadline )) && return 0
    fi
    return 1
}

# Logging
# can_log <prio> <key=value...>
can_log() {
    local prio="$1"
    shift
    local log_file="${CAN_TOOLS_LOG_FILE:-}"

    local prefix="$((prio))"
    local msg="$@"

    echo "<$prefix>can_tools[$$]: $msg" >&2

    if [[ -n "$log_file" ]]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] <$prefix> $msg" >> "$log_file"
    fi
}

# Time
# can_now - Get current epoch seconds
can_now() {
    if [[ -n "$CAN_TOOLS_FAKE_TIME_FILE" ]] && [[ -f "$CAN_TOOLS_FAKE_TIME_FILE" ]]; then
        cat "$CAN_TOOLS_FAKE_TIME_FILE"
    else
        date +%s
    fi
}

return 0
