#!/bin/bash

# shellcheck disable=SC2034  # Default values are used by sourcing scripts

# can_tools_lib.bash - Library for CAN interface management
# Provides configuration, locking, and CAN interface control functions.
# This file is sourced, not executed. Does not call exit().
#
# Call convention (errexit safety, §2b addendum): every function in this file
# is safe to source and call under a caller's `set -euo pipefail` WITHOUT
# itself aborting mid-body on a normal, expected failure branch (e.g. an
# interface that doesn't exist yet, a name collision, a bounded command that
# times out). A function's own non-zero return value is still the CALLER's
# responsibility to check -- this file does not change what each function
# returns, only guarantees it reaches a `return` instead of dying partway
# through on an internal statement. Because of that, call a function that can
# return non-zero on its own (anything other than can_log/can_now) inside an
# `if`/`||`/`&&` so your *own* `set -e` does the right thing with ITS result:
#     if can_lock 5; then ...; fi
#     can_setup_iface can0 || handle_failure
# A bare, unguarded call is fine too (bash does not abort on the call itself),
# but then you must inspect "$?" yourself if you care about the outcome.

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
# Set by can_pin_name on every call (cleared on success) to let a caller tell
# apart the reasons behind its rc=1 without changing the §2b return contract
# (0/1/2). Not part of the contract itself -- an informational extra. One of:
# "" (success / not yet called), "no_net_dir" (spidev has no net/ dir),
# "no_iface" (net/ dir exists but is empty -- no netdev registered yet),
# "timeout" (the `ip link show <want>` collision check hit WD_RTNL_TIMEOUT_S),
# "ip_check_failed" (that same check failed for some other reason),
# "ip_rename_failed" (the down/rename `ip` calls themselves failed).
declare -g CAN_PIN_NAME_REASON=""

# Helper to check if a process is alive (not zombie, L-b semantics).
# can_run_bounded polls this every 0.1s while waiting on its child, so it
# must not fork: no `awk`/`cat`/`ps`. `read` is a bash builtin, and a plain
# `<` redirect on it does not fork a subshell either.
_can_is_alive() {
    local pid="$1"
    local stat_line=""
    # Redirect stderr before the `<` so a vanished-pid ENOENT (process already
    # reaped -- the common, expected case) is silently swallowed instead of
    # printing "No such file or directory" to the real stderr: bash applies
    # redirections left-to-right, so `2>/dev/null` must come first here.
    if ! read -r stat_line 2>/dev/null <"/proc/$pid/stat"; then
        return 1
    fi
    # /proc/<pid>/stat is "<pid> (<comm>) <state> ...". comm can itself
    # contain spaces or ')', so anchor on the LAST ')' rather than splitting
    # on whitespace from the start -- the state char is the field right
    # after it.
    local after="${stat_line##*) }"
    local state="${after%% *}"
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
# Always returns 0 (invalid values just fall back to defaults + a WARNING);
# safe to call bare under the caller's `set -e`.
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
# Reentrant. Returns 0 (lock held) / 1 (could not take it within timeout_s).
# Call it inside if/|| under the caller's `set -e` -- see the file header.
can_lock() {
    local timeout="${1:-5}"

    mkdir -p "${CAN_TOOLS_RUN_DIR:-/run/can_tools}" 2>/dev/null || true

    if (( _CAN_LOCK_DEPTH > 0 )); then
        # N.B. plain `(( x++ ))` returns the PRE-increment value as the
        # command's exit status; at depth 0 that is 0 -> exit 1 -> would
        # abort a bare `can_lock` call under the caller's `set -e`. Use
        # assignment form instead so this statement always succeeds.
        _CAN_LOCK_DEPTH=$((_CAN_LOCK_DEPTH + 1))
        return 0
    fi

    if exec 9>"${CAN_TOOLS_RUN_DIR:-/run/can_tools}/lock"; then
        if flock -w "$timeout" 9 2>/dev/null; then
            _CAN_LOCK_DEPTH=$((_CAN_LOCK_DEPTH + 1))
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
# Returns 0 (unlocked one level) / 1 (was not locked). See the file header
# for the `set -e` call convention.
can_unlock() {
    if (( _CAN_LOCK_DEPTH <= 0 )); then
        return 1
    fi

    _CAN_LOCK_DEPTH=$((_CAN_LOCK_DEPTH - 1))
    if (( _CAN_LOCK_DEPTH == 0 )); then
        exec 9>&-
    fi
    return 0
}

# Process Execution (§2b)
# can_run_bounded <timeout_s> <cmd...>
# Child runs with fd 9 closed. Output to temp file. PID preserved in parent.
# N-H1: Disconnect child's stdio from parent to avoid blocking $( ) calls
#
# IMPORTANT: Do not call this function inside $( ), < <( ), or pipes (e.g.
# can_iface_states | while ...). These create subshells that lose
# CAN_RUN_BOUNDED_PID, defeating the guard that prevents multiple hung children
# (R2). Capture output via file redirection: can_run_bounded ... >"$file"; then
# read from "$file". Same applies to functions that call can_run_bounded:
# can_iface_states, can_pin_name, can_setup_iface.
# Returns the wrapped command's own exit code, or 124 on timeout / while a
# previous bounded child is still alive (R2). Call it inside if/|| under the
# caller's `set -e` -- see the file header.
can_run_bounded() {
    local timeout="$1"
    shift
    local cmd=("$@")

    # If previous child still alive, don't start new one (R2)
    if [[ -n "$CAN_RUN_BOUNDED_PID" ]] && _can_is_alive "$CAN_RUN_BOUNDED_PID"; then
        return 124
    fi

    # Create temp file for output using BASHPID for uniqueness across subshells (低-4)
    local outfile
    outfile="${CAN_TOOLS_RUN_DIR:-/run/can_tools}/bounded_$$.${BASHPID}.tmp"
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
            # Process finished, get its exit code. `wait` itself exits with
            # that (often non-zero) code, so it must not be a bare statement:
            # under the caller's `set -e` a bare failing `wait` would abort
            # can_run_bounded right here, before `ret` is even captured.
            local ret=0
            wait "$CAN_RUN_BOUNDED_PID" 2>/dev/null || ret=$?
            # Output was written to file, cat it if exists
            [[ -f "$outfile" ]] && cat "$outfile" && rm -f "$outfile"
            CAN_RUN_BOUNDED_PID=""
            return "$ret"
        fi
        sleep 0.1
        # Plain `(( i++ ))` is the pre-increment value as exit status; at
        # i=0 that's 0 -> exit 1 -> would abort this loop's first tick under
        # the caller's `set -e`. Assignment form always succeeds.
        i=$((i + 1))
    done

    # Timeout - child pid remains in CAN_RUN_BOUNDED_PID for caller to track
    # Don't wait for child, just return 124
    rm -f "$outfile" || true
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
# Returns 0 (found >=1 CAN iface) / 1 (none found) / 124 (the bounded `ip`
# call timed out). Call it inside if/|| under the caller's `set -e`.
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
    # A bare call here would abort under the caller's `set -e` whenever `ip`
    # itself exits non-zero (e.g. no CAN ifaces at all) -- guard with `|| rc=$?`
    # so we can inspect the timeout case below instead of dying mid-function.
    local rc=0
    can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "${CAN_TOOLS_IP_CMD:-ip}" -d link show type can >"$outfile" 2>&1 || rc=$?

    if (( rc == 124 )); then
        rm -f "$outfile" || true
        return 124
    fi

    local if_name="" if_state="" if_admin="" restart_ms="" berr="" fd="" ctrlmode="" flags=""
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
                # Assignment form: plain `(( found++ ))` returns the
                # pre-increment value as exit status, which is 0 (-> exit 1)
                # on the very first match and would abort here under `set -e`.
                found=$((found + 1))
            fi
        done < "$outfile"
        rm -f "$outfile" || true
    fi

    [[ $found -eq 0 ]] && return 1
    return 0
}

# Statistics Reading (§2b)
# can_read_stats <if>
# Called once per iface per watchdog tick (WD_LOOP_S), so this avoids forking
# `cat` per file -- `read` is a builtin; a plain `<` redirect on it forks
# nothing. Always returns 0 once past the iface-exists check; safe to call
# bare under the caller's `set -e`.
can_read_stats() {
    local if="$1"
    local sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    local base="$sysfs_root/class/net/$if"

    [[ -d "$base" ]] || return 1

    local rx_packets=0 tx_packets=0 rx_fifo=0 tx_fifo=0 ifindex=0

    # `read`'s own failure (e.g. a file vanishing mid-read) just leaves the
    # "=0" default above in place, same as the previous `cat`-on-missing-file
    # behavior; `2>/dev/null` before `<` so that failure's stderr (if any)
    # doesn't leak, matching _can_is_alive's reasoning.
    [[ -f "$base/statistics/rx_packets" ]] && { read -r rx_packets 2>/dev/null <"$base/statistics/rx_packets" || true; }
    [[ -f "$base/statistics/tx_packets" ]] && { read -r tx_packets 2>/dev/null <"$base/statistics/tx_packets" || true; }
    [[ -f "$base/statistics/rx_fifo_errors" ]] && { read -r rx_fifo 2>/dev/null <"$base/statistics/rx_fifo_errors" || true; }
    [[ -f "$base/statistics/tx_fifo_errors" ]] && { read -r tx_fifo 2>/dev/null <"$base/statistics/tx_fifo_errors" || true; }
    [[ -f "$base/ifindex" ]] && { read -r ifindex 2>/dev/null <"$base/ifindex" || true; }

    echo "$rx_packets $tx_packets $rx_fifo $tx_fifo $ifindex"
    return 0
}

# SPI Device Mapping (§2b)
# can_spidev_of <if>
# Returns 0 (printed the spidev) / 1 (no device symlink). Safe to call bare.
can_spidev_of() {
    local if="$1"
    local sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    local device_link="$sysfs_root/class/net/$if/device"

    if [[ -L "$device_link" ]]; then
        local device_path=""
        # Guard: a bare failing `readlink` (symlink vanishes mid-race) would
        # otherwise abort here under the caller's `set -e`.
        device_path=$(readlink -f "$device_link" 2>/dev/null) || true
        echo "${device_path##*/}"
        return 0
    fi
    return 1
}

# can_iface_of_spidev <spidev>
# Returns 0 (printed the iface name) / 1 (no net/ dir, or it's empty). Safe
# to call bare.
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
# Returns 0 if ok/renamed, 2 if name in use (EEXIST), 1 if error. On rc=1,
# CAN_PIN_NAME_REASON is also set (see its declaration near the top of this
# file) so a caller that needs to tell apart "no netdev yet" from "the ip
# call itself failed" can do so without a new return value, keeping the §2b
# contract (0/1/2) unchanged; it is cleared ("") whenever this returns 0 or 2.
#
# IMPORTANT: Do not call this function inside $( ), < <( ), or pipes.
# This function calls can_run_bounded internally, which needs CAN_RUN_BOUNDED_PID
# to survive in the parent shell. Capture output via file redirection; see
# can_run_bounded for details. Call it inside if/|| under the caller's
# `set -e` -- see the file header.
can_pin_name() {
    local spidev="$1"
    local want="$2"
    local sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    local ip_cmd="${CAN_TOOLS_IP_CMD:-ip}"
    local net_dir="$sysfs_root/bus/spi/devices/$spidev/net"

    CAN_PIN_NAME_REASON=""

    if [[ ! -d "$net_dir" ]]; then
        CAN_PIN_NAME_REASON="no_net_dir"
        return 1
    fi

    # N-M2 follow-up: must be initialized. Under the caller's `set -u`, an
    # uninitialized `local` that the loop below never assigns (net_dir exists
    # but is empty, e.g. mid-unbind/bind) is unbound, not merely empty, and
    # referencing it below would abort with "current: unbound variable".
    local current=""
    for iface in "$net_dir"/*; do
        [[ -d "$iface" ]] && current="${iface##*/}"
    done

    if [[ -z "$current" ]]; then
        CAN_PIN_NAME_REASON="no_iface"
        return 1
    fi
    [[ "$current" == "$want" ]] && return 0

    if [[ -n "$want" ]]; then
        # Check if want name is in use (N-C1: split rc branches). Guard with
        # `|| check_rc=$?`: a bare call here would abort under the caller's
        # `set -e` whenever `ip link show` exits non-zero, which is the
        # expected/common branch (the name is free).
        local check_rc=0
        can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link show "$want" >/dev/null 2>&1 || check_rc=$?

        if [[ $check_rc -eq 0 ]]; then
            # Name exists (already in use) - name collision
            return 2
        elif [[ $check_rc -eq 1 ]]; then
            # Name doesn't exist, continue to rename
            :
        elif [[ $check_rc -eq 124 ]]; then
            # Timeout/bounded abort
            CAN_PIN_NAME_REASON="timeout"
            return 1
        else
            # Other error
            CAN_PIN_NAME_REASON="ip_check_failed"
            return 1
        fi

        # Down first (M1). Best-effort: its outcome isn't checked (the
        # rename attempt below is the real signal), so `|| true` rather than
        # a bare statement that would abort this function under `set -e` if
        # `ip link set down` itself fails.
        can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$current" down >/dev/null 2>&1 || true

        # Rename (M1: use bounded). Guard the same way as check_rc above.
        local rename_rc=0
        can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$current" name "$want" >/dev/null 2>&1 || rename_rc=$?

        # N-C1: Only return 0 if rename succeeded (rc==0)
        if [[ $rename_rc -eq 0 ]]; then
            return 0
        else
            CAN_PIN_NAME_REASON="ip_rename_failed"
            return 1
        fi
    fi

    return 0
}

# Interface Setup (§2b)
# can_setup_iface <if>
# N-H2: Always explicitly include fd on/off and berr-reporting on/off
#
# IMPORTANT: Do not call this function inside $( ), < <( ), or pipes.
# This function calls can_run_bounded internally, which needs CAN_RUN_BOUNDED_PID
# to survive in the parent shell. Capture output via file redirection; see
# can_run_bounded for details. Returns 0 on success, 1 on failure (including
# CAN_TOOLS_DRY_RUN's early return, which is still 0). Call it inside if/||
# under the caller's `set -e` -- see the file header.
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

    # Down (L-2: log it). Best-effort, like can_pin_name's down: a bare
    # statement here would abort under the caller's `set -e` if `ip` fails
    # (e.g. already down), so ignore its result with `|| true`.
    can_run_bounded "${WD_RTNL_TIMEOUT_S:-5}" "$ip_cmd" link set "$if" down >/dev/null 2>&1 || true

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
# Returns 0 on success, 1 on an invalid duration. Safe to call bare.
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
    # Bare write before `return 0`: a failure here (e.g. disk full,
    # permission) must not abort under the caller's `set -e`.
    echo "$deadline" >"$run_dir/watchdog.pause" 2>/dev/null || true
    return 0
}

# can_unpause
# Always returns 0; safe to call bare.
can_unpause() {
    local run_dir="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
    rm -f "$run_dir/watchdog.pause" 2>/dev/null || true
    return 0
}

# can_pause_active
# Returns 0 if a pause is in effect, 1 otherwise (including "no pause file" /
# "corrupt pause file"). Safe to call bare.
can_pause_active() {
    local run_dir="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
    local pause_file="$run_dir/watchdog.pause"

    if [[ -f "$pause_file" ]]; then
        local deadline="" now
        # Builtin `read` instead of `cat` (no fork); guard with `|| true`
        # since a bare failing read here (file vanished mid-race) would
        # otherwise abort this function under the caller's `set -e` before
        # the validation below even runs.
        read -r deadline 2>/dev/null <"$pause_file" || true

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
# Always returns 0 (a failed write to CAN_TOOLS_LOG_FILE is swallowed rather
# than propagated -- logging must never be the reason a caller's `set -e`
# aborts). Safe to call bare.
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

    echo "<$prefix>can_tools[$$]: $msg" >&2 || true

    if [[ -n "$log_file" ]]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] <$prefix> $msg" >>"$log_file" || true
    fi

    return 0
}

# Time (§2b)
# can_now - Get current epoch seconds
# Returns integer seconds (from EPOCHREALTIME if available, else date +%s).
# Always returns 0; safe to call bare under the caller's `set -e`/`set -u`.
can_now() {
    # ${CAN_TOOLS_FAKE_TIME_FILE:-}: under the caller's `set -u`, a bare
    # $CAN_TOOLS_FAKE_TIME_FILE reference is an unbound-variable error when
    # the caller never set it (the normal, non-test case) -- this is the
    # errexit/nounset bug this whole PR exists to fix.
    if [[ -n "${CAN_TOOLS_FAKE_TIME_FILE:-}" ]] && [[ -f "$CAN_TOOLS_FAKE_TIME_FILE" ]]; then
        # `read` is a builtin; avoids forking `cat` on every call (can_pause /
        # can_pause_active call this every watchdog tick).
        local fake_now=""
        read -r fake_now 2>/dev/null <"$CAN_TOOLS_FAKE_TIME_FILE" || true
        echo "$fake_now"
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
