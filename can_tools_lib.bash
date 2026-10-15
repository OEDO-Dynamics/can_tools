#!/bin/bash

# shellcheck disable=SC2034  # Default values are used by sourcing scripts

# can_tools_lib.bash - Library for CAN interface management
# Provides configuration, locking, and CAN interface control functions.
# This file is sourced, not executed. Does not call exit().

# Default values for all configuration keys (§2a)
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
    [[ -f "/proc/$pid/stat" ]] || return 1
    local state
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    [[ "$state" != "Z" ]]
}

# Reset defaults
_can_set_defaults() {
    CAN_IFACES="can0 can1"
    CAN_SPI_MAP="spi0.0:can0 spi1.0:can1"
    CAN_BITRATE=250000
    CAN_RESTART_MS=100
    CAN_BERR_REPORTING="off"
    CAN_FD="on"
    CAN_DBITRATE=2000000
    CAN_TXQUEUELEN=10
    CAN_DEPENDENT_UNITS=""
    CAN_FLUSH_IFACES="can0"
    # WD_* reset to defaults (N-M2)
    WD_LOOP_S=1
    WD_STALE_TX_FLUSH_S=2
    WD_FLUSH_BACKOFF_MAX_S=30
    WD_SETTLE_SAMPLE_MS=100
    WD_SETTLE_MAX_MS=2000
    WD_BUSOFF_QUIET_S=10
    WD_BUSOFF_BACKOFF_MAX_S=30
    WD_STORM_COUNT=5
    WD_STORM_WINDOW_S=60
    WD_STALL_CONSEC=3
    WD_STALL_POST_BUSOFF_CONSEC=2
    WD_STALL_POST_BUSOFF_WINDOW_S=5
    WD_STALL_VERIFY_S=10
    WD_RTNL_TIMEOUT_S=5
    WD_REBIND_TIMEOUT_S=10
    WD_REBIND_MAX_PER_HOUR=3
    WD_RTNL_HUNG_CONSEC=3
    WD_PAUSE_DEFAULT_MIN=30
    WD_PAUSE_WARN_S=600
    WD_DEGRADED_CRIT_S=600
    WD_LOG_SUMMARY_S=60
    WD_LOG_RATE_S=10
    WD_CRASH_KEEP=5
}

# Validate configuration value
_can_validate_value() {
    local key="$1" val="$2"

    case "$key" in
        CAN_BERR_REPORTING|CAN_FD)
            if [[ "$val" == "on" || "$val" == "off" ]]; then
                echo "$val"
            else
                can_log 4 "WARNING: Invalid value for $key: $val (use on/off)"
                return 1
            fi
            ;;
        CAN_BITRATE|CAN_RESTART_MS|CAN_DBITRATE|CAN_TXQUEUELEN|WD_LOOP_S|WD_STALE_TX_FLUSH_S|WD_FLUSH_BACKOFF_MAX_S|WD_SETTLE_SAMPLE_MS|WD_SETTLE_MAX_MS|WD_BUSOFF_QUIET_S|WD_BUSOFF_BACKOFF_MAX_S|WD_STORM_COUNT|WD_STORM_WINDOW_S|WD_STALL_CONSEC|WD_STALL_POST_BUSOFF_CONSEC|WD_STALL_POST_BUSOFF_WINDOW_S|WD_STALL_VERIFY_S|WD_RTNL_TIMEOUT_S|WD_REBIND_TIMEOUT_S|WD_REBIND_MAX_PER_HOUR|WD_RTNL_HUNG_CONSEC|WD_PAUSE_DEFAULT_MIN|WD_PAUSE_WARN_S|WD_DEGRADED_CRIT_S|WD_LOG_SUMMARY_S|WD_LOG_RATE_S|WD_CRASH_KEEP)
            if [[ "$val" =~ ^[0-9]+$ ]]; then
                echo "$val"
            else
                can_log 4 "WARNING: Invalid numeric value for $key: $val"
                return 1
            fi
            ;;
        CAN_IFACES|CAN_FLUSH_IFACES|CAN_SPI_MAP|CAN_DEPENDENT_UNITS)
            # N-M2: name/list keys get character-type validation, not a free pass.
            _can_validate_names "$key" "$val"
            ;;
        *)
            echo "$val"
            ;;
    esac
}

# Configuration Reading (§2b)
# can_read_conf [path]
# N-M2: Validate name keys for character types
can_read_conf() {
    local conf_path="${1:-${CAN_TOOLS_CONF:-/opt/can_tools/can_tools.conf}}"

    # Reset to defaults first (H3 (a))
    _can_set_defaults

    if [[ -f "$conf_path" ]]; then
        local key val line
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue

            if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"

                # Remove quotes (H3 (c))
                val="${val%\"}"
                val="${val#\"}"
                val="${val%\'}"
                val="${val#\'}"

                case "$key" in
                    CAN_IFACES|CAN_SPI_MAP|CAN_BITRATE|CAN_RESTART_MS|CAN_BERR_REPORTING|CAN_FD|CAN_DBITRATE|CAN_TXQUEUELEN|CAN_DEPENDENT_UNITS|CAN_FLUSH_IFACES|\
                    WD_LOOP_S|WD_STALE_TX_FLUSH_S|WD_FLUSH_BACKOFF_MAX_S|WD_SETTLE_SAMPLE_MS|WD_SETTLE_MAX_MS|WD_BUSOFF_QUIET_S|WD_BUSOFF_BACKOFF_MAX_S|WD_STORM_COUNT|WD_STORM_WINDOW_S|\
                    WD_STALL_CONSEC|WD_STALL_POST_BUSOFF_CONSEC|WD_STALL_POST_BUSOFF_WINDOW_S|WD_STALL_VERIFY_S|WD_RTNL_TIMEOUT_S|WD_REBIND_TIMEOUT_S|WD_REBIND_MAX_PER_HOUR|WD_RTNL_HUNG_CONSEC|\
                    WD_PAUSE_DEFAULT_MIN|WD_PAUSE_WARN_S|WD_DEGRADED_CRIT_S|WD_LOG_SUMMARY_S|WD_LOG_RATE_S|WD_CRASH_KEEP)
                        # Validate value (H3 (b))
                        local validated
                        validated=$(_can_validate_value "$key" "$val") && declare -g "$key=$validated"
                        ;;
                esac
            fi
        done < "$conf_path"
    fi

    return 0
}

# Validate name configuration keys for character types (N-M2)
_can_validate_names() {
    local key="$1" val="$2"

    case "$key" in
        CAN_IFACES|CAN_FLUSH_IFACES)
            # Interface names: alphanumeric, -, _ only
            if [[ "$val" =~ ^([a-zA-Z0-9_-]+[[:space:]]*)*$ ]]; then
                echo "$val"
            else
                can_log 4 "WARNING: Invalid interface name in $key: $val"
                return 1
            fi
            ;;
        CAN_SPI_MAP|CAN_DEPENDENT_UNITS)
            # Space-separated pairs/entries, alphanumeric and basic punctuation
            if [[ "$val" =~ ^([a-zA-Z0-9_.:/-]+[[:space:]]*)*$ ]]; then
                echo "$val"
            else
                can_log 4 "WARNING: Invalid value in $key: $val"
                return 1
            fi
            ;;
        *)
            echo "$val"
            ;;
    esac
}

# Locking (§2b)
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

# Process Execution (§2b)
# can_run_bounded <timeout_s> <cmd...>
# Child runs with fd 9 closed. Output to temp file. PID preserved in parent.
# N-H1: Disconnect child's stdio from parent to avoid blocking $( ) calls
can_run_bounded() {
    local timeout="$1"
    shift
    local cmd=("$@")

    # If previous child still alive, don't start new one (R2)
    if [[ -n "$CAN_RUN_BOUNDED_PID" ]] && _can_is_alive "$CAN_RUN_BOUNDED_PID"; then
        return 124
    fi

    # Create temp file for output
    local outfile
    outfile="${CAN_TOOLS_RUN_DIR:-/run/can_tools}/bounded_$$.tmp"
    mkdir -p "${CAN_TOOLS_RUN_DIR:-/run/can_tools}" 2>/dev/null || true

    # Run in background with fd 9 closed, output to file, stdio disconnected (N-H1)
    (
        exec 9>&-
        exec >"$outfile" 2>&1
        "${cmd[@]}"
    ) </dev/null 2>&1 &

    CAN_RUN_BOUNDED_PID=$!

    # Wait with timeout (use integer tick counting, not bc - C1)
    local i=0
    local max=$((timeout * 10))  # 0.1 second intervals

    while (( i < max )); do
        if ! _can_is_alive "$CAN_RUN_BOUNDED_PID"; then
            # Process finished, get its exit code
            wait "$CAN_RUN_BOUNDED_PID" 2>/dev/null
            local ret=$?
            # Output was written to file, cat it if exists
            [[ -f "$outfile" ]] && cat "$outfile" && rm -f "$outfile"
            CAN_RUN_BOUNDED_PID=""
            return $ret
        fi
        sleep 0.1
        (( i++ ))
    done

    # Timeout - child pid remains in CAN_RUN_BOUNDED_PID for caller to track
    # Don't wait for child, just return 124
    rm -f "$outfile"
    return 124
}

# CAN Interface State Reading (§2b)
# can_iface_states
# IMPORTANT: this function must be called as a plain command (e.g.
#   can_iface_states >"$file"; rc=$?; ... read from "$file" ...
# ), never wrapped in $( ) or < <( ). Both of those fork a subshell, and the
# CAN_RUN_BOUNDED_PID this function sets (via can_run_bounded, called below
# with a plain redirection so it stays in the CURRENT shell) would then be
# lost when the subshell exits. That silently defeats can_run_bounded's "do
# not start a new child while the previous one is still alive" guard (R2):
# every call would spawn its own hung `ip`, leaking one D-state-adjacent
# process per watchdog cycle instead of capping at one. Internally this
# function also avoids `< <(can_run_bounded ...)` / `$(can_run_bounded ...)`
# for the exact same reason, reading the captured output from a plain file
# redirect instead.
can_iface_states() {
    # §2b regexes, verbatim:
    #   iface line:  ^[0-9]+: ([^:@]+)[:@] <([^>]*)>
    #   CAN line:    ^[[:space:]]+can (<([^>]*)> )?state ([A-Z-]+)
    #   restart-ms:  restart-ms ([0-9]+)
    local re_iface='^[0-9]+: ([^:@]+)[:@] <([^>]*)>'
    local re_can='^[[:space:]]+can (<([^>]*)> )?state ([A-Z-]+)'
    local re_restart='restart-ms ([0-9]+)'

    local run_dir="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
    mkdir -p "$run_dir" 2>/dev/null || true
    local outfile="$run_dir/iface_states_$$.tmp"

    # N-H1: plain redirection, NOT $( ) / < <( ) - runs in the current shell so
    # CAN_RUN_BOUNDED_PID set by can_run_bounded is preserved for the next call.
    can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "${CAN_TOOLS_IP_CMD:-ip}" -d link show type can >"$outfile" 2>&1
    local rc=$?

    if (( rc == 124 )); then
        rm -f "$outfile"
        return 124
    fi

    local if_name if_state if_admin restart_ms berr fd ctrlmode flags
    local found=0

    if [[ -f "$outfile" ]]; then
        while IFS= read -r line; do
            # Iface line: admin is up only if "UP" is one of the comma-separated
            # flags inside <...> (not a substring match like LOWER_UP).
            if [[ $line =~ $re_iface ]]; then
                if_name="${BASH_REMATCH[1]}"
                flags=",${BASH_REMATCH[2]},"
                if_admin="down"
                [[ "$flags" == *,UP,* ]] && if_admin="up"
            fi

            # CAN state line (group 3 is STATE; do not confuse with operstate's
            # "state UP" on the iface line above)
            if [[ $line =~ $re_can ]]; then
                ctrlmode="${BASH_REMATCH[2]}"
                if_state="${BASH_REMATCH[3]}"

                restart_ms=0
                [[ $line =~ $re_restart ]] && restart_ms="${BASH_REMATCH[1]}"

                # Exact flag match within ctrlmode (comma-delimited), so
                # FD-NON-ISO never matches plain FD.
                berr="off"
                fd="off"
                [[ ",$ctrlmode," == *,BERR-REPORTING,* ]] && berr="on"
                [[ ",$ctrlmode," == *,FD,* ]] && fd="on"

                echo "$if_name $if_state restart_ms=$restart_ms berr=$berr fd=$fd admin=$if_admin"
                (( found++ ))
            fi
        done < "$outfile"
        rm -f "$outfile"
    fi

    [[ $found -eq 0 ]] && return 1
    return 0
}

# Statistics Reading (§2b)
# can_read_stats <if>
can_read_stats() {
    local if="$1"
    local sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    local base="$sysfs_root/class/net/$if"

    [[ -d "$base" ]] || return 1

    local rx_packets=0 tx_packets=0 rx_fifo=0 tx_fifo=0 ifindex=0

    [[ -f "$base/statistics/rx_packets" ]] && rx_packets=$(cat "$base/statistics/rx_packets" 2>/dev/null)
    [[ -f "$base/statistics/tx_packets" ]] && tx_packets=$(cat "$base/statistics/tx_packets" 2>/dev/null)
    [[ -f "$base/statistics/rx_fifo_errors" ]] && rx_fifo=$(cat "$base/statistics/rx_fifo_errors" 2>/dev/null)
    [[ -f "$base/statistics/tx_fifo_errors" ]] && tx_fifo=$(cat "$base/statistics/tx_fifo_errors" 2>/dev/null)
    [[ -f "$base/ifindex" ]] && ifindex=$(cat "$base/ifindex" 2>/dev/null)

    echo "$rx_packets $tx_packets $rx_fifo $tx_fifo $ifindex"
    return 0
}

# SPI Device Mapping (§2b)
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

    [[ -d "$net_dir" ]] || return 1

    for iface in "$net_dir"/*; do
        [[ -d "$iface" ]] && echo "${iface##*/}" && return 0
    done
    return 1
}

# Interface Naming (§2b)
# can_pin_name <spidev> <want>
# Returns 0 if ok/renamed, 2 if name in use (EEXIST), 1 if error
can_pin_name() {
    local spidev="$1"
    local want="$2"
    local sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    local ip_cmd="${CAN_TOOLS_IP_CMD:-ip}"
    local net_dir="$sysfs_root/bus/spi/devices/$spidev/net"

    [[ -d "$net_dir" ]] || return 1

    local current
    for iface in "$net_dir"/*; do
        [[ -d "$iface" ]] && current="${iface##*/}"
    done

    [[ -z "$current" ]] && return 1
    [[ "$current" == "$want" ]] && return 0

    if [[ -n "$want" ]]; then
        # Check if want name is in use (N-C1: split rc branches)
        can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link show "$want" >/dev/null 2>&1
        local check_rc=$?

        if [[ $check_rc -eq 0 ]]; then
            # Name exists (already in use) - name collision
            return 2
        elif [[ $check_rc -eq 1 ]]; then
            # Name doesn't exist, continue to rename
            :
        elif [[ $check_rc -eq 124 ]]; then
            # Timeout/bounded abort
            return 1
        else
            # Other error
            return 1
        fi

        # Down first (M1)
        can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$current" down >/dev/null 2>&1

        # Rename (M1: use bounded)
        can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$current" name "$want" >/dev/null 2>&1
        local rename_rc=$?

        # N-C1: Only return 0 if rename succeeded (rc==0)
        if [[ $rename_rc -eq 0 ]]; then
            return 0
        else
            return 1
        fi
    fi

    return 0
}

# Interface Setup (§2b)
# can_setup_iface <if>
# N-H2: Always explicitly include fd on/off and berr-reporting on/off
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

    # H1: Take lock
    can_lock 5 || return 1

    if [[ -n "$dry_run" ]]; then
        # H1: Log the full command (N-H2: always include fd and berr)
        local fd_args="fd $fd"
        [[ "$fd" == "on" ]] && fd_args="dbitrate $dbitrate fd on" || fd_args="fd off"
        local berr_args="berr-reporting $berr"
        can_log 6 "DRY_RUN: $ip_cmd link set $if down"
        can_log 6 "DRY_RUN: $ip_cmd link set $if up type can bitrate $bitrate restart-ms $restart_ms $berr_args $fd_args"
        can_log 6 "DRY_RUN: $ip_cmd link set $if txqueuelen $txqueuelen"
        can_unlock
        return 0
    fi

    # Down (L-2: log it)
    can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$if" down >/dev/null 2>&1

    # Build parameters (N-H2: always specify berr and fd)
    local berr_args="berr-reporting $berr"
    local fd_args=""
    if [[ "$fd" == "on" ]]; then
        fd_args="dbitrate $dbitrate fd on"
    else
        fd_args="fd off"
    fi

    # Up with parameters
    if ! can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$if" up \
        type can bitrate "$bitrate" restart-ms "$restart_ms" $berr_args $fd_args >/dev/null 2>&1; then
        can_unlock
        return 1
    fi

    # Set txqueuelen
    if ! can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$if" txqueuelen "$txqueuelen" >/dev/null 2>&1; then
        can_unlock
        return 1
    fi

    can_unlock
    return 0
}

# Pause/Resume (§2b)
# can_pause [min]
can_pause() {
    local min="${1:-${WD_PAUSE_DEFAULT_MIN:-30}}"

    # L3: Validate
    [[ ! "$min" =~ ^[0-9]+$ ]] && {
        can_log 4 "WARNING: Invalid pause duration: $min"
        return 1
    }

    local run_dir="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
    mkdir -p "$run_dir" 2>/dev/null || true

    local now deadline
    now=$(can_now)
    deadline=$((now + min * 60))
    echo "$deadline" >"$run_dir/watchdog.pause" 2>/dev/null
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
        local deadline now
        deadline=$(cat "$pause_file" 2>/dev/null)

        # L3: Validate
        [[ ! "$deadline" =~ ^[0-9]+$ ]] && {
            can_log 4 "WARNING: Invalid pause deadline in file"
            return 1
        }

        now=$(can_now)
        (( now < deadline )) && return 0
    fi
    return 1
}

# Logging (§2b)
# can_log <prio> <key=value...>
# N-M1: Map priority names to numbers (case-insensitive), handle either
can_log() {
    local prio="$1"
    shift
    local log_file="${CAN_TOOLS_LOG_FILE:-}"

    # Normalize to lowercase for case-insensitive matching
    prio="${prio,,}"

    # Map priority names to numbers
    case "$prio" in
        emerg) prio=0 ;;
        alert) prio=1 ;;
        crit) prio=2 ;;
        err) prio=3 ;;
        warning) prio=4 ;;
        notice) prio=5 ;;
        info) prio=6 ;;
        debug) prio=7 ;;
        *) [[ ! "$prio" =~ ^[0-7]$ ]] && prio=6 ;;
    esac

    local prefix="$((prio))"
    # Use $* not $@
    local msg="$*"

    echo "<$prefix>can_tools[$$]: $msg" >&2

    if [[ -n "$log_file" ]]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] <$prefix> $msg" >>"$log_file"
    fi
}

# Time (§2b)
# can_now - Get current epoch seconds
# C1: Return integer milliseconds or use EPOCHREALTIME
can_now() {
    if [[ -n "$CAN_TOOLS_FAKE_TIME_FILE" ]] && [[ -f "$CAN_TOOLS_FAKE_TIME_FILE" ]]; then
        cat "$CAN_TOOLS_FAKE_TIME_FILE"
    else
        # Use EPOCHREALTIME if available, otherwise date +%s
        if [[ -n "${EPOCHREALTIME+x}" ]]; then
            echo "${EPOCHREALTIME%.*}"
        else
            date +%s
        fi
    fi
}

return 0
