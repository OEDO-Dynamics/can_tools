#!/bin/bash

# can_watchdog.sh - Resident CAN interface watchdog (Issue #9, PR-B / §1).
#
# Replaces can_monitor.sh/.service/.timer. Owns recovery of can0/can1 end to
# end: TX flush on ERROR-WARNING/PASSIVE (§1a), bus-off recovery (§1b),
# rx-offload stall detection and unbind/bind recovery (§1c), degraded mode
# when recovery is not possible (§1d), logging (§1e) and config-mismatch
# observe-only mode (§1f).
#
# This script only uses can_tools_lib.bash's public contract (§2b) and does
# not duplicate or modify it. Per the Issue's calling convention (added in
# the "契約の追記" comment on #9): can_run_bounded, and any lib function that
# calls it internally (can_iface_states / can_pin_name / can_setup_iface),
# must never be invoked inside $( ), < <( ) or a pipeline - doing so forks a
# subshell and the CAN_RUN_BOUNDED_PID this process tracks would be lost in
# that subshell, silently defeating the "don't start a new rtnl child while
# the previous one is still alive" guard (R2). The same rule applies to the
# bind/unbind helpers in this file that use can_run_bounded directly.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./can_tools_lib.bash
source "$repo_root/can_tools_lib.bash"

# ===========================================================================
# Small file-backed helpers (state survives across --once invocations and
# across Restart=always respawns; this process holds nothing important only
# in memory).
# ===========================================================================

_wd_run_dir() { echo "${CAN_TOOLS_RUN_DIR:-/run/can_tools}"; }
_wd_state_dir() { echo "${CAN_TOOLS_STATE_DIR:-/var/lib/can_tools}"; }

_wd_file_get() {
    local f="$1" default="$2"
    if [[ -f "$f" ]]; then
        cat "$f" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

_wd_file_set() {
    local f="$1" val="$2"
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    echo "$val" >"$f" 2>/dev/null || true
}

# Per-iface ephemeral scratch state (baselines, backoff, consec counters).
# Deliberately under CAN_TOOLS_RUN_DIR (tmpfs): a reboot is the universal
# "start clean" event for this watchdog, same as the degraded_<if> markers.
_wd_state_path() { echo "$(_wd_run_dir)/wd_$1.state"; }

_wd_state_get() {
    local ifn="$1" key="$2" default="$3" f v
    f=$(_wd_state_path "$ifn")
    [[ -f "$f" ]] || { echo "$default"; return; }
    v=$(grep -m1 "^${key}=" "$f" 2>/dev/null)
    v="${v#*=}"
    [[ -n "$v" ]] && echo "$v" || echo "$default"
}

_wd_state_set() {
    local ifn="$1" key="$2" val="$3" f tmp
    f=$(_wd_state_path "$ifn")
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    touch "$f"
    if grep -q "^${key}=" "$f" 2>/dev/null; then
        tmp=$(mktemp "${f}.XXXXXX")
        grep -v "^${key}=" "$f" >"$tmp" 2>/dev/null || true
        echo "${key}=${val}" >>"$tmp"
        mv "$tmp" "$f"
    else
        echo "${key}=${val}" >>"$f"
    fi
}

# Rebind / bus-off occurrence windows. Kept in CAN_TOOLS_STATE_DIR (§1c:
# "回数は /var/lib/can_tools/state に持ち、クラッシュループで枠が戻らない
# ようにする"): a crash-looping watchdog (Restart=always) must not get its
# rebind quota back just because the process restarted.
_wd_rebind_times_path() { echo "$(_wd_state_dir)/rebind_times_$1"; }
_wd_busoff_times_path() { echo "$(_wd_state_dir)/busoff_times_$1"; }

_wd_append_time() {
    local f="$1" now="$2"
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    echo "$now" >>"$f"
}

# Prunes entries older than the window and echoes the remaining count.
_wd_count_times() {
    local f="$1" window="$2" now="$3" cutoff line count=0
    [[ -f "$f" ]] || { echo 0; return; }
    cutoff=$((now - window))
    local kept=()
    while IFS= read -r line; do
        [[ "$line" =~ ^[0-9]+$ ]] || continue
        if (( line >= cutoff )); then
            kept+=("$line")
            count=$((count + 1))
        fi
    done <"$f"
    : >"$f"
    local t
    for t in "${kept[@]}"; do
        echo "$t" >>"$f"
    done
    echo "$count"
}

_wd_in_list() {
    local needle="$1" haystack="$2" item
    for item in $haystack; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

_wd_ms_to_s() {
    local ms="$1"
    printf '%d.%03d' $((ms / 1000)) $((ms % 1000))
}

# ===========================================================================
# Logging (§1e): key=value lines, suppressed per iface+reason, periodic
# summary. can_log (lib) already writes to stderr with the <N> priority
# prefix systemd expects; this just adds rate limiting and suppressed=N.
# ===========================================================================

_wd_log_key() {
    local ifn="$1" reason="$2" key
    key="${ifn}_${reason}"
    echo "${key//[^A-Za-z0-9_]/_}"
}

# _wd_log_rated <prio> <iface> <reason> <rate_s> <msg...>
_wd_log_rated() {
    local prio="$1" ifn="$2" reason="$3" rate="$4"
    shift 4
    local msg="$*"
    local run_dir key ts_file cnt_file now last cnt
    run_dir=$(_wd_run_dir)
    key=$(_wd_log_key "$ifn" "$reason")
    ts_file="$run_dir/log/${key}.ts"
    cnt_file="$run_dir/log/${key}.cnt"
    mkdir -p "$run_dir/log" 2>/dev/null || true
    now=$(can_now)
    last=$(_wd_file_get "$ts_file" 0)
    cnt=$(_wd_file_get "$cnt_file" 0)

    if (( last == 0 )) || (( now - last >= rate )); then
        if (( cnt > 0 )); then
            can_log "$prio" "iface=$ifn reason=$reason $msg suppressed=$cnt"
        else
            can_log "$prio" "iface=$ifn reason=$reason $msg"
        fi
        _wd_file_set "$ts_file" "$now"
        _wd_file_set "$cnt_file" 0
    else
        cnt=$((cnt + 1))
        _wd_file_set "$cnt_file" "$cnt"
    fi
}

# _wd_log <prio> <iface> <reason> <msg...> - rate-limited at WD_LOG_RATE_S.
_wd_log() {
    local prio="$1" ifn="$2" reason="$3"
    shift 3
    _wd_log_rated "$prio" "$ifn" "$reason" "${WD_LOG_RATE_S:-10}" "$@"
}

# _wd_log_force <prio> <iface> <reason> <msg...> - always logs (state
# transitions / recovery actions get a counters snapshot every time, §1e),
# and resets that key's suppression window.
_wd_log_force() {
    local prio="$1" ifn="$2" reason="$3"
    shift 3
    can_log "$prio" "iface=$ifn reason=$reason $*"
    local run_dir key
    run_dir=$(_wd_run_dir)
    key=$(_wd_log_key "$ifn" "$reason")
    mkdir -p "$run_dir/log" 2>/dev/null || true
    _wd_file_set "$run_dir/log/${key}.ts" "$(can_now)"
    _wd_file_set "$run_dir/log/${key}.cnt" 0
}

_wd_log_summary() {
    local now="$1" run_dir last ifn rx tx rxfifo txfifo ifindex
    run_dir=$(_wd_run_dir)
    last=$(_wd_file_get "$run_dir/wd_summary.ts" 0)
    if (( last != 0 )) && (( now - last < ${WD_LOG_SUMMARY_S:-60} )); then
        return 0
    fi
    _wd_file_set "$run_dir/wd_summary.ts" "$now"
    for ifn in $CAN_IFACES; do
        read -r rx tx rxfifo txfifo ifindex <<<"$(can_read_stats "$ifn" 2>/dev/null)"
        can_log info "iface=$ifn rx=${rx:-0} tx=${tx:-0} rxfifo=${rxfifo:-0} txfifo=${txfifo:-0} ifindex=${ifindex:-0} degraded=$(_wd_is_degraded "$ifn" && echo 1 || echo 0)"
    done
}

# ===========================================================================
# Degraded mode (§1d)
# ===========================================================================

_wd_degraded_marker() { echo "$(_wd_run_dir)/degraded_$1"; }

_wd_is_degraded() {
    [[ -f "$(_wd_degraded_marker "$1")" ]]
}

_wd_save_crash() {
    local ifn="$1" reason="$2" dir ts file keep
    dir="$(_wd_state_dir)/crash"
    mkdir -p "$dir" 2>/dev/null || true
    ts=$(can_now)
    file="$dir/${ts}-${ifn}.txt"
    {
        echo "timestamp=$ts iface=$ifn reason=$reason"
        echo "--- stats ---"
        can_read_stats "$ifn" 2>/dev/null
        echo "--- journalctl -k (tail 50) ---"
        "${CAN_TOOLS_JOURNALCTL_CMD:-journalctl}" -k 2>/dev/null | tail -n 50
    } >"$file" 2>/dev/null

    keep="${WD_CRASH_KEEP:-5}"
    # shellcheck disable=SC2012  # fake journalctl/ls environment has no `find -printf`-free equivalent worth the complexity here
    ls -1t "$dir"/*.txt 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r f; do
        rm -f "$f"
    done
}

# _wd_mark_degraded <if> <reason> <now>
_wd_mark_degraded() {
    local ifn="$1" reason="$2" now="$3" marker
    marker=$(_wd_degraded_marker "$ifn")
    if [[ ! -f "$marker" ]]; then
        echo "${now}:${reason}" >"$marker" 2>/dev/null
        _wd_save_crash "$ifn" "$reason"
        _wd_log_force crit "$ifn" "$reason" "degraded=1"
    fi
    _wd_file_set "${marker}.lastcrit" "$now"
}

_wd_handle_degraded() {
    local ifn="$1" now="$2" marker content reason last_crit
    marker=$(_wd_degraded_marker "$ifn")
    [[ -f "$marker" ]] || return 1
    content=$(cat "$marker" 2>/dev/null)
    reason="${content#*:}"
    last_crit=$(_wd_file_get "${marker}.lastcrit" 0)
    if (( now - last_crit >= ${WD_DEGRADED_CRIT_S:-600} )); then
        _wd_log_force crit "$ifn" "manual_reboot_required" "original_reason=$reason"
        _wd_file_set "${marker}.lastcrit" "$now"
    fi
    return 0
}

_wd_clear_degraded() {
    local ifn="$1" run_dir
    if [[ -z "$ifn" ]]; then
        echo "usage: can_watchdog.sh --clear-degraded <if>" >&2
        return 1
    fi
    run_dir=$(_wd_run_dir)
    rm -f "$(_wd_degraded_marker "$ifn")" "$(_wd_degraded_marker "$ifn").lastcrit" 2>/dev/null || true
    # rtnl_hung is a global, all-interface condition; clearing any one
    # iface's degraded marker also re-arms normal ip-based checking so the
    # next cycle can re-establish ground truth for everyone.
    rm -f "$run_dir/rtnl_hung_active" "$run_dir/wd_rtnl_hung_consec" 2>/dev/null || true
    can_log notice "iface=$ifn reason=clear_degraded action=clear"
    return 0
}

# ===========================================================================
# Oops/BUG pre-check (§1c step 1)
# ===========================================================================

_wd_precheck_oops() {
    local jctl="${CAN_TOOLS_JOURNALCTL_CMD:-journalctl}" out line
    out=$("$jctl" -k -b 2>/dev/null)
    while IFS= read -r line; do
        case "$line" in
            *Oops*|*'BUG:'*|*'nobody cared'*|*'IRQ handler returned'*|*'echo_skb'*'is occupied'*)
                echo "$line"
                return 1
                ;;
        esac
    done <<<"$out"
    return 0
}

# ===========================================================================
# bus-off settle (§1b step 2): sample rx_packets until two consecutive
# samples match, bounded by WD_SETTLE_MAX_MS.
# ===========================================================================

_wd_settle() {
    local ifn="$1" sample_ms="${WD_SETTLE_SAMPLE_MS:-100}" max_ms="${WD_SETTLE_MAX_MS:-2000}"
    local sleep_s prev cur elapsed=0
    sleep_s=$(_wd_ms_to_s "$sample_ms")
    read -r prev _ <<<"$(can_read_stats "$ifn")"
    while (( elapsed < max_ms )); do
        sleep "$sleep_s"
        elapsed=$((elapsed + sample_ms))
        read -r cur _ <<<"$(can_read_stats "$ifn")"
        if [[ "$cur" == "$prev" ]]; then
            return 0
        fi
        prev="$cur"
    done
    return 1
}

# ===========================================================================
# §1b: bus-off recovery
# ===========================================================================

_wd_busoff_recover() {
    local ifn="$1" now="$2"
    local pending_ts
    pending_ts=$(_wd_state_get "$ifn" BUSOFF_PENDING_TS 0)

    if (( pending_ts > 0 )) && (( now < pending_ts )); then
        _wd_log warning "$ifn" "busoff_recovery_backoff" "pending_ts=$pending_ts"
        return 1
    fi

    if ! _wd_settle "$ifn"; then
        _wd_log warning "$ifn" "busoff_settle_timeout" "max_ms=${WD_SETTLE_MAX_MS:-2000}"
        return 1
    fi

    if (( pending_ts == 0 )); then
        local last_ts quiet backoff_s max
        last_ts=$(_wd_state_get "$ifn" BUSOFF_LAST_RECOVERY_TS 0)
        quiet="${WD_BUSOFF_QUIET_S:-10}"
        if (( last_ts > 0 )) && (( now - last_ts <= quiet )); then
            backoff_s=$(_wd_state_get "$ifn" BUSOFF_BACKOFF_S 0)
            if (( backoff_s <= 0 )); then backoff_s=1; else backoff_s=$((backoff_s * 2)); fi
            max="${WD_BUSOFF_BACKOFF_MAX_S:-30}"
            (( backoff_s > max )) && backoff_s=$max
            _wd_state_set "$ifn" BUSOFF_BACKOFF_S "$backoff_s"
            _wd_state_set "$ifn" BUSOFF_PENDING_TS "$((now + backoff_s))"
            _wd_log warning "$ifn" "busoff_recovery_backoff" "backoff_s=$backoff_s"
            return 1
        fi
        _wd_state_set "$ifn" BUSOFF_BACKOFF_S 0
    fi
    _wd_state_set "$ifn" BUSOFF_PENDING_TS 0

    local storm_count
    storm_count=$(_wd_count_times "$(_wd_busoff_times_path "$ifn")" "${WD_STORM_WINDOW_S:-60}" "$now")
    if (( storm_count + 1 >= ${WD_STORM_COUNT:-5} )); then
        _wd_log crit "$ifn" "busoff_storm" "count=$((storm_count + 1)) window_s=${WD_STORM_WINDOW_S:-60}"
        _wd_state_set "$ifn" BUSOFF_BACKOFF_S "${WD_BUSOFF_BACKOFF_MAX_S:-30}"
    fi

    if [[ -n "${CAN_TOOLS_DRY_RUN:-}" ]]; then
        can_log info "DRY_RUN: busoff recovery for $ifn (can_setup_iface)"
    fi
    can_setup_iface "$ifn"
    local rc=$?
    _wd_append_time "$(_wd_busoff_times_path "$ifn")" "$now"
    _wd_state_set "$ifn" BUSOFF_LAST_RECOVERY_TS "$now"

    if (( rc != 0 )); then
        _wd_log err "$ifn" "busoff_recovery_failed" "rc=$rc"
        return 1
    fi

    local new_rx
    read -r new_rx _ <<<"$(can_read_stats "$ifn")"
    _wd_state_set "$ifn" POST_BUSOFF_BASELINE_RX "${new_rx:-0}"
    _wd_state_set "$ifn" POST_BUSOFF_UNTIL "$((now + ${WD_STALL_POST_BUSOFF_WINDOW_S:-5}))"
    _wd_log_force notice "$ifn" "busoff_recovered" "rx=${new_rx:-0}"
    return 0
}

# ===========================================================================
# §1a: TX flush on ERROR-WARNING/ERROR-PASSIVE
# ===========================================================================

_wd_flush_check() {
    local ifn="$1" now="$2" drx="$3" dtx="$4" drxfifo="$5" dtxfifo="$6"

    _wd_in_list "$ifn" "${CAN_FLUSH_IFACES:-}" || return 0

    if ! { (( drx == 0 )) && (( dtx == 0 )) && (( drxfifo == 0 )) && (( dtxfifo == 0 )); }; then
        _wd_state_set "$ifn" FLUSH_STALE_SINCE 0
        return 0
    fi

    local stale_since
    stale_since=$(_wd_state_get "$ifn" FLUSH_STALE_SINCE 0)
    if (( stale_since == 0 )); then
        _wd_state_set "$ifn" FLUSH_STALE_SINCE "$now"
        return 0
    fi
    if (( now - stale_since < ${WD_STALE_TX_FLUSH_S:-2} )); then
        return 0
    fi

    local pending_ts
    pending_ts=$(_wd_state_get "$ifn" FLUSH_PENDING_TS 0)
    if (( pending_ts > 0 )) && (( now < pending_ts )); then
        _wd_log warning "$ifn" "flush_backoff_pending" "pending_ts=$pending_ts"
        return 0
    fi

    # N5-3: re-read just before acting, 100 ms x 2, abort if it moved.
    local r1 r2
    read -r r1 _ <<<"$(can_read_stats "$ifn")"
    sleep 0.1
    read -r r2 _ <<<"$(can_read_stats "$ifn")"
    if [[ "$r1" != "$r2" ]]; then
        _wd_log warning "$ifn" "flush_aborted_recheck" "changed_between_reads=1"
        _wd_state_set "$ifn" FLUSH_STALE_SINCE 0
        return 0
    fi

    if [[ -n "${CAN_TOOLS_DRY_RUN:-}" ]]; then
        can_log info "DRY_RUN: TX flush for $ifn (can_setup_iface)"
    fi
    can_setup_iface "$ifn"
    local rc=$?

    local last_ts backoff_s next_backoff max
    last_ts=$(_wd_state_get "$ifn" FLUSH_LAST_TS 0)
    backoff_s=$(_wd_state_get "$ifn" FLUSH_BACKOFF_S 0)
    max="${WD_FLUSH_BACKOFF_MAX_S:-30}"
    if (( last_ts == 0 )); then
        next_backoff=1
    else
        if (( backoff_s <= 0 )); then next_backoff=1; else next_backoff=$((backoff_s * 2)); fi
        (( next_backoff > max )) && next_backoff=$max
    fi
    _wd_state_set "$ifn" FLUSH_BACKOFF_S "$next_backoff"
    _wd_state_set "$ifn" FLUSH_LAST_TS "$now"
    _wd_state_set "$ifn" FLUSH_PENDING_TS "$((now + next_backoff))"
    _wd_state_set "$ifn" FLUSH_STALE_SINCE 0

    if (( rc == 0 )); then
        _wd_log_force warning "$ifn" "tx_flush" "rx=${r1:-0}"
    else
        _wd_log err "$ifn" "tx_flush_failed" "rc=$rc"
    fi
    return 0
}

# ===========================================================================
# §1c: rx-offload stall recovery (unbind/bind)
# ===========================================================================

# _wd_do_unbind - the exec'd child's argv[0] is set to "can_tools_unbind"
# (via `exec -a`), so /proc/<pid>/cmdline contains that string for the
# startup D-state check (L-a). It writes the inflight marker itself, with
# its own real PID (same PID can_run_bounded is timing), before touching the
# unbind sysfs file, exactly as §1c step 3 requires ("子が自分で
# echo "<spidev>:$BASHPID" > marker してから unbind へ書く").
_wd_do_unbind() {
    local spidev="$1" marker="$2" unbind_file="$3" timeout="$4"
    local script='echo "$1:$BASHPID" >"$2"; echo "$1" >"$3"'
    can_run_bounded "$timeout" bash -c \
        'exec -a can_tools_unbind bash -c "$1" -- "$2" "$3" "$4"' \
        _ "$script" "$spidev" "$marker" "$unbind_file"
}

_wd_rebind_recover() {
    local ifn="$1" now="$2"
    local run_dir state_dir
    run_dir=$(_wd_run_dir)
    state_dir=$(_wd_state_dir)

    local count
    count=$(_wd_count_times "$(_wd_rebind_times_path "$ifn")" 3600 "$now")
    if (( count >= ${WD_REBIND_MAX_PER_HOUR:-3} )); then
        _wd_mark_degraded "$ifn" "rebind_quota_exceeded" "$now"
        return 1
    fi

    can_lock "${WD_RTNL_TIMEOUT_S:-5}" || {
        _wd_log err "$ifn" "lock_failed" "action=rebind"
        return 1
    }

    local oops_line
    if ! oops_line=$(_wd_precheck_oops); then
        can_unlock
        _wd_log_force crit "$ifn" "oops_detected" "line=${oops_line}"
        _wd_mark_degraded "$ifn" "oops_detected" "$now"
        return 1
    fi

    local spidev
    if ! spidev=$(can_spidev_of "$ifn"); then
        can_unlock
        _wd_mark_degraded "$ifn" "spidev_not_found" "$now"
        return 1
    fi

    if [[ -n "${CAN_TOOLS_DRY_RUN:-}" ]]; then
        can_log info "DRY_RUN: rebind recovery for $ifn (spidev=$spidev)"
        can_unlock
        return 0
    fi

    # step 2: down first (harmless, already stopped; cuts IRQs / in-flight tx)
    can_run_bounded "${WD_REBIND_TIMEOUT_S:-10}" "${CAN_TOOLS_IP_CMD:-ip}" link set "$ifn" down >/dev/null 2>&1

    # step 3: unbind (bounded, child self-identifies)
    local marker="$run_dir/unbind_inflight"
    local unbind_file="${CAN_TOOLS_SYSFS_ROOT:-/sys}/bus/spi/drivers/mcp251xfd/unbind"
    _wd_do_unbind "$spidev" "$marker" "$unbind_file" "${WD_REBIND_TIMEOUT_S:-10}"
    local unbind_rc=$?

    if (( unbind_rc == 124 )); then
        # Marker intentionally left behind: the child may still be writing
        # or stuck inside the kernel unbind path. can_unlock here (§1d: "1d
        # の手順にcan_unlockする(unbind_inflightマーカーは残す)を明記").
        can_unlock
        _wd_log_force crit "$ifn" "unbind_timeout" "spidev=$spidev"
        _wd_mark_degraded "$ifn" "unbind_timeout" "$now"
        return 1
    fi
    rm -f "$marker" 2>/dev/null || true

    if (( unbind_rc != 0 )); then
        can_unlock
        _wd_mark_degraded "$ifn" "unbind_failed" "$now"
        return 1
    fi

    # step 4: bind
    local bind_file="${CAN_TOOLS_SYSFS_ROOT:-/sys}/bus/spi/drivers/mcp251xfd/bind"
    can_run_bounded "${WD_REBIND_TIMEOUT_S:-10}" bash -c 'echo "$0" >"$1"' "$spidev" "$bind_file"
    local bind_rc=$?
    if (( bind_rc != 0 )); then
        can_unlock
        _wd_mark_degraded "$ifn" "bind_failed" "$now"
        return 1
    fi

    local waited=0
    while (( waited < 5 )); do
        can_iface_of_spidev "$spidev" >/dev/null 2>&1 && break
        sleep 1
        waited=$((waited + 1))
    done
    if ! can_iface_of_spidev "$spidev" >/dev/null 2>&1; then
        can_unlock
        _wd_mark_degraded "$ifn" "bind_no_netdev" "$now"
        return 1
    fi

    can_pin_name "$spidev" "$ifn"
    local pin_rc=$?
    if (( pin_rc == 2 )); then
        can_unlock
        _wd_mark_degraded "$ifn" "pin_name_collision" "$now"
        return 1
    elif (( pin_rc != 0 )); then
        can_unlock
        _wd_mark_degraded "$ifn" "pin_name_failed" "$now"
        return 1
    fi

    can_setup_iface "$ifn"
    local setup_rc=$?
    if (( setup_rc != 0 )); then
        can_unlock
        _wd_mark_degraded "$ifn" "setup_failed" "$now"
        return 1
    fi

    _wd_append_time "$(_wd_rebind_times_path "$ifn")" "$now"
    _wd_state_set "$ifn" STALL_CONSEC 0
    _wd_state_set "$ifn" BUSOFF_NORX_STREAK 0
    _wd_state_set "$ifn" REBIND_VERIFY_UNTIL "$((now + ${WD_STALL_VERIFY_S:-10}))"

    can_unlock
    # §1c step 6: dependent-unit restarts happen AFTER can_unlock.
    _wd_restart_dependent_units
    _wd_log_force notice "$ifn" "rebind_recovered" "spidev=$spidev"
    return 0
}

_wd_restart_dependent_units() {
    local unit container
    for unit in ${CAN_DEPENDENT_UNITS:-}; do
        if [[ "$unit" == docker:* ]]; then
            container="${unit#docker:}"
            can_run_bounded "${WD_REBIND_TIMEOUT_S:-10}" "${CAN_TOOLS_DOCKER_CMD:-docker}" restart "$container" >/dev/null 2>&1
        else
            can_run_bounded "${WD_REBIND_TIMEOUT_S:-10}" "${CAN_TOOLS_SYSTEMCTL_CMD:-systemctl}" restart "$unit" >/dev/null 2>&1
        fi
    done
}

# ===========================================================================
# Startup reconciliation (§1): bind any spidev left driver-less, unless its
# unbind is still in flight on a D-state child (L-a/L-b), or pause is active
# (manual unbind is respected). Cheap and idempotent, so it is run at the
# top of every cycle, not just the first one.
# ===========================================================================

_wd_startup_bind_check() {
    local now="$1" run_dir sysfs_root marker hung_spidev=""
    run_dir=$(_wd_run_dir)
    sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    marker="$run_dir/unbind_inflight"

    if [[ -f "$marker" ]]; then
        local content pid spidev stat_line state cmdline
        content=$(cat "$marker" 2>/dev/null)
        spidev="${content%%:*}"
        pid="${content##*:}"
        if [[ "$pid" =~ ^[0-9]+$ && -f "/proc/$pid/stat" ]]; then
            stat_line=$(cat "/proc/$pid/stat" 2>/dev/null)
            state=$(awk '{print $3}' <<<"$stat_line")
            cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
            if [[ "$state" == "D" && "$cmdline" == *can_tools_unbind* ]]; then
                hung_spidev="$spidev"
            fi
        fi
        [[ -z "$hung_spidev" ]] && rm -f "$marker" 2>/dev/null || true
    fi

    local pair spidev want
    for pair in ${CAN_SPI_MAP:-}; do
        spidev="${pair%%:*}"
        want="${pair#*:}"

        can_iface_of_spidev "$spidev" >/dev/null 2>&1 && continue

        if [[ -n "$hung_spidev" && "$spidev" == "$hung_spidev" ]]; then
            _wd_mark_degraded "$want" "unbind_inflight_at_startup" "$now"
            continue
        fi

        can_pause_active && continue
        _wd_is_degraded "$want" && continue

        if [[ -n "${CAN_TOOLS_DRY_RUN:-}" ]]; then
            can_log info "DRY_RUN: startup bind for $want (spidev=$spidev)"
            continue
        fi

        local bind_file="$sysfs_root/bus/spi/drivers/mcp251xfd/bind"
        can_run_bounded "${WD_REBIND_TIMEOUT_S:-10}" bash -c 'echo "$0" >"$1"' "$spidev" "$bind_file"
        local rc=$?
        if (( rc != 0 )); then
            _wd_mark_degraded "$want" "bind_failed_at_startup" "$now"
            continue
        fi

        local waited=0
        while (( waited < 5 )); do
            can_iface_of_spidev "$spidev" >/dev/null 2>&1 && break
            sleep 1
            waited=$((waited + 1))
        done
        if ! can_iface_of_spidev "$spidev" >/dev/null 2>&1; then
            _wd_mark_degraded "$want" "bind_no_netdev" "$now"
            continue
        fi

        can_pin_name "$spidev" "$want"
        local pin_rc=$?
        if (( pin_rc == 2 )); then
            _wd_mark_degraded "$want" "pin_name_collision" "$now"
            continue
        elif (( pin_rc != 0 )); then
            _wd_mark_degraded "$want" "pin_name_failed" "$now"
            continue
        fi

        can_setup_iface "$want"
    done
}

# ===========================================================================
# Per-iface cycle (§1 priority order: observe-only conditions are evaluated
# alongside stall detection -> stall (§1c) -> bus-off (§1b) -> flush (§1a)).
# ===========================================================================

_wd_process_iface() {
    local ifn="$1" now="$2" state_val="$3" restart_ms_val="$4" berr_val="$5" fd_val="$6" admin_val="$7"

    if _wd_is_degraded "$ifn"; then
        _wd_handle_degraded "$ifn" "$now"
        return 0
    fi

    [[ -z "$state_val" ]] && return 0

    local rx tx rxfifo txfifo ifindex
    read -r rx tx rxfifo txfifo ifindex <<<"$(can_read_stats "$ifn")"
    [[ -z "$ifindex" ]] && return 0

    local prev_seen prev_rx prev_tx prev_rxfifo prev_txfifo prev_ifindex
    prev_seen=$(_wd_state_get "$ifn" PREV_SEEN 0)
    prev_rx=$(_wd_state_get "$ifn" PREV_RX 0)
    prev_tx=$(_wd_state_get "$ifn" PREV_TX 0)
    prev_rxfifo=$(_wd_state_get "$ifn" PREV_RXFIFO 0)
    prev_txfifo=$(_wd_state_get "$ifn" PREV_TXFIFO 0)
    prev_ifindex=$(_wd_state_get "$ifn" PREV_IFINDEX 0)

    local drx=0 dtx=0 drxfifo=0 dtxfifo=0
    if [[ "$prev_seen" == "1" && "$prev_ifindex" == "$ifindex" ]]; then
        drx=$((rx - prev_rx)); (( drx < 0 )) && drx=0
        dtx=$((tx - prev_tx)); (( dtx < 0 )) && dtx=0
        drxfifo=$((rxfifo - prev_rxfifo)); (( drxfifo < 0 )) && drxfifo=0
        dtxfifo=$((txfifo - prev_txfifo)); (( dtxfifo < 0 )) && dtxfifo=0
    fi

    _wd_state_set "$ifn" PREV_SEEN 1
    _wd_state_set "$ifn" PREV_RX "$rx"
    _wd_state_set "$ifn" PREV_TX "$tx"
    _wd_state_set "$ifn" PREV_RXFIFO "$rxfifo"
    _wd_state_set "$ifn" PREV_TXFIFO "$txfifo"
    _wd_state_set "$ifn" PREV_IFINDEX "$ifindex"

    # Post-rebind verification window (§1c step 5): takes priority over
    # everything else while active. Positive evidence of stall -> fail
    # immediately; a quiet bus through the whole window -> success, resume
    # normal detection next cycle.
    local rv_until
    rv_until=$(_wd_state_get "$ifn" REBIND_VERIFY_UNTIL 0)
    if (( rv_until > 0 )); then
        if (( drx == 0 )) && { (( drxfifo > 0 )) || (( dtxfifo > 0 )); }; then
            _wd_state_set "$ifn" REBIND_VERIFY_UNTIL 0
            _wd_mark_degraded "$ifn" "rebind_verify_failed" "$now"
            return 0
        fi
        (( now >= rv_until )) && _wd_state_set "$ifn" REBIND_VERIFY_UNTIL 0
        return 0
    fi

    # Observe-only conditions (§0, §1f): pause / admin-down / config
    # mismatch / effective berr on.
    local observe_only=0 observe_reason=""
    if can_pause_active; then
        observe_only=1
        observe_reason="pause"
    fi
    if [[ "$admin_val" == "down" ]]; then
        observe_only=1
        observe_reason="${observe_reason:+${observe_reason},}admin_down"
    fi
    if [[ "$restart_ms_val" != "${CAN_RESTART_MS}" || "$berr_val" != "${CAN_BERR_REPORTING}" || "$fd_val" != "${CAN_FD}" ]]; then
        observe_only=1
        observe_reason="${observe_reason:+${observe_reason},}config_mismatch_reboot_required"
        _wd_log warning "$ifn" "config_mismatch_reboot_required" \
            "restart_ms=$restart_ms_val/$CAN_RESTART_MS berr=$berr_val/$CAN_BERR_REPORTING fd=$fd_val/$CAN_FD"
    fi
    if [[ "$berr_val" == "on" ]]; then
        observe_only=1
        observe_reason="${observe_reason:+${observe_reason},}berr_on"
    fi

    # §1c: stall detection. Pauses only for BUS-OFF / admin-down; runs even
    # in observe-only mode so stall_detected_observe_only (R5) still fires.
    local stall_signal=0
    if [[ "$state_val" != "BUS-OFF" && "$admin_val" != "down" ]]; then
        if (( drx == 0 )) && { (( drxfifo > 0 )) || (( dtxfifo > 0 )); }; then
            stall_signal=1
        fi
    fi

    local stall_consec
    stall_consec=$(_wd_state_get "$ifn" STALL_CONSEC 0)
    if (( stall_signal )); then
        stall_consec=$((stall_consec + 1))
    else
        stall_consec=0
    fi
    _wd_state_set "$ifn" STALL_CONSEC "$stall_consec"

    local post_until required="${WD_STALL_CONSEC:-3}"
    post_until=$(_wd_state_get "$ifn" POST_BUSOFF_UNTIL 0)
    if (( post_until > 0 && now <= post_until )); then
        required="${WD_STALL_POST_BUSOFF_CONSEC:-2}"
    fi
    if (( post_until > 0 && now >= post_until )); then
        local baseline_rx streak
        baseline_rx=$(_wd_state_get "$ifn" POST_BUSOFF_BASELINE_RX 0)
        streak=$(_wd_state_get "$ifn" BUSOFF_NORX_STREAK 0)
        if (( rx == baseline_rx )); then
            streak=$((streak + 1))
        else
            streak=0
        fi
        _wd_state_set "$ifn" BUSOFF_NORX_STREAK "$streak"
        _wd_state_set "$ifn" POST_BUSOFF_UNTIL 0
    fi

    local norx_streak
    norx_streak=$(_wd_state_get "$ifn" BUSOFF_NORX_STREAK 0)

    local stall_triggered=0
    if (( stall_signal )) && (( stall_consec >= required )); then
        stall_triggered=1
    elif (( norx_streak >= 3 )); then
        stall_triggered=1
    fi

    if (( stall_triggered )); then
        if (( observe_only )); then
            _wd_log crit "$ifn" "stall_detected_observe_only" "rx=$rx rxfifo=$rxfifo txfifo=$txfifo reasons=${observe_reason}"
        else
            _wd_rebind_recover "$ifn" "$now"
        fi
        return 0
    fi

    (( observe_only )) && return 0

    # ERROR-ACTIVE sustained 60s: reset TX-flush backoff (§1a bullet 4). The
    # equivalent bus-off reset falls out naturally from the quiet-window
    # check in _wd_busoff_recover (last recovery will be far outside
    # WD_BUSOFF_QUIET_S by then), so no extra bookkeeping is needed there.
    local active_since
    active_since=$(_wd_state_get "$ifn" ACTIVE_SINCE 0)
    if [[ "$state_val" == "ERROR-ACTIVE" ]]; then
        if (( active_since == 0 )); then
            active_since=$now
            _wd_state_set "$ifn" ACTIVE_SINCE "$now"
        fi
        if (( now - active_since >= 60 )); then
            _wd_state_set "$ifn" FLUSH_BACKOFF_S 0
            _wd_state_set "$ifn" FLUSH_LAST_TS 0
        fi
    else
        (( active_since != 0 )) && _wd_state_set "$ifn" ACTIVE_SINCE 0
    fi

    if [[ "$state_val" == "BUS-OFF" ]]; then
        _wd_busoff_recover "$ifn" "$now"
        return 0
    fi

    if [[ "$state_val" == "ERROR-WARNING" || "$state_val" == "ERROR-PASSIVE" ]]; then
        _wd_flush_check "$ifn" "$now" "$drx" "$dtx" "$drxfifo" "$dtxfifo"
        return 0
    fi

    _wd_state_set "$ifn" FLUSH_STALE_SINCE 0
    return 0
}

# ===========================================================================
# One full watchdog cycle.
# ===========================================================================

_wd_cycle() {
    local run_dir state_dir now
    run_dir=$(_wd_run_dir)
    state_dir=$(_wd_state_dir)
    mkdir -p "$run_dir" "$state_dir" "$run_dir/log" 2>/dev/null || true

    can_read_conf

    now=$(can_now)

    if can_pause_active; then
        _wd_log_rated warning "-" "pause_active" "${WD_PAUSE_WARN_S:-600}" ""
    fi

    _wd_startup_bind_check "$now"

    if [[ -f "$run_dir/rtnl_hung_active" ]]; then
        local ifn
        for ifn in $CAN_IFACES; do
            _wd_handle_degraded "$ifn" "$now"
        done
        _wd_log_summary "$now"
        return 0
    fi

    # can_iface_states MUST be called as a plain command (lib contract /
    # Issue addendum): never $( ) / < <( ), or CAN_RUN_BOUNDED_PID would be
    # lost in a subshell and R2's hang guard would stop working.
    local states_file="$run_dir/wd_states_$$.txt"
    can_iface_states >"$states_file" 2>/dev/null
    local rc=$?

    if (( rc == 124 )); then
        rm -f "$states_file"
        local consec
        consec=$(_wd_file_get "$run_dir/wd_rtnl_hung_consec" 0)
        consec=$((consec + 1))
        _wd_file_set "$run_dir/wd_rtnl_hung_consec" "$consec"
        if (( consec >= ${WD_RTNL_HUNG_CONSEC:-3} )); then
            echo "$now" >"$run_dir/rtnl_hung_active"
            local ifn2
            for ifn2 in $CAN_IFACES; do
                _wd_mark_degraded "$ifn2" "rtnl_hung" "$now"
            done
        fi
        _wd_log warning "-" "rtnl_hung" "consec=$consec"
        return 0
    fi
    _wd_file_set "$run_dir/wd_rtnl_hung_consec" 0

    declare -A st_state=() st_restart=() st_berr=() st_fd=() st_admin=()
    if [[ -f "$states_file" ]]; then
        local line ifn3 s_state s_restart s_berr s_fd s_admin
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            read -r ifn3 s_state s_restart s_berr s_fd s_admin <<<"$line"
            st_state[$ifn3]="$s_state"
            st_restart[$ifn3]="${s_restart#restart_ms=}"
            st_berr[$ifn3]="${s_berr#berr=}"
            st_fd[$ifn3]="${s_fd#fd=}"
            st_admin[$ifn3]="${s_admin#admin=}"
        done <"$states_file"
    fi
    rm -f "$states_file"

    local ifn4
    for ifn4 in $CAN_IFACES; do
        _wd_process_iface "$ifn4" "$now" \
            "${st_state[$ifn4]:-}" "${st_restart[$ifn4]:-}" "${st_berr[$ifn4]:-}" "${st_fd[$ifn4]:-}" "${st_admin[$ifn4]:-}"
    done

    _wd_log_summary "$now"
    return 0
}

# ===========================================================================
# CLI
# ===========================================================================

_wd_usage() {
    cat <<'EOF'
usage: can_watchdog.sh [--once] [--dry-run] [--clear-degraded <if>] [--help]

  --once                 run a single cycle and exit (default: loop at WD_LOOP_S)
  --dry-run              log actions instead of performing them (sets CAN_TOOLS_DRY_RUN=1)
  --clear-degraded <if>  clear the degraded marker for <if> and exit
  --help                 show this message
EOF
}

main() {
    local once=0 clear_degraded=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --once)
                once=1
                shift
                ;;
            --dry-run)
                export CAN_TOOLS_DRY_RUN=1
                shift
                ;;
            --clear-degraded)
                clear_degraded="${2:-}"
                shift 2
                ;;
            --help|-h)
                _wd_usage
                return 0
                ;;
            *)
                echo "can_watchdog.sh: unknown option: $1" >&2
                _wd_usage
                return 1
                ;;
        esac
    done

    if [[ -n "$clear_degraded" ]]; then
        _wd_clear_degraded "$clear_degraded"
        return $?
    fi

    can_read_conf

    if (( once )); then
        _wd_cycle
        return $?
    fi

    while true; do
        _wd_cycle
        sleep "${WD_LOOP_S:-1}"
    done
}

# Allow sourcing (e.g. from tests) without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit $?
fi
