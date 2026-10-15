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
# CAN_DEPENDENT_UNITS restarts are the one exception that deliberately does
# NOT go through can_run_bounded at all - see _wd_restart_dependent_units.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./can_tools_lib.bash
source "$repo_root/can_tools_lib.bash"

# ===========================================================================
# Small file-backed helpers (state survives across --once invocations and
# across Restart=always respawns; this process holds nothing important only
# in memory, EXCEPT the per-iface scratch state in _WD_IFSTATE below, which
# is loaded from / dumped to disk exactly once per iface per cycle - see the
# H4 performance note above _wd_state_load.
#
# _WD_RUN_DIR / _WD_STATE_DIR are resolved ONCE per process invocation by
# _wd_init_dirs (called at the top of _wd_cycle and in the one-shot CLI
# paths) and read as plain variables everywhere else, instead of being
# recomputed via a $(...) helper call (each of which forks a subshell) on
# every single use - previously tens of times per iface per second (H4).
# ===========================================================================

declare -g _WD_RUN_DIR=""
declare -g _WD_STATE_DIR=""

_wd_init_dirs() {
    _WD_RUN_DIR="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
    _WD_STATE_DIR="${CAN_TOOLS_STATE_DIR:-/var/lib/can_tools}"
}

_wd_file_get() {
    local f="$1" default="$2"
    if [[ -f "$f" ]]; then
        cat "$f" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# Caller is expected to have already mkdir -p'd $_WD_RUN_DIR/$_WD_STATE_DIR
# once per cycle (_wd_cycle does); re-running `mkdir -p` (a fork) on every
# single write was a measurable share of H4's CPU cost.
_wd_file_set() {
    local f="$1" val="$2"
    echo "$val" >"$f" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Per-iface ephemeral scratch state (baselines, backoff, consec counters).
# Deliberately under CAN_TOOLS_RUN_DIR (tmpfs): a reboot is the universal
# "start clean" event for this watchdog, same as the degraded_<if> markers.
#
# H4 fix: this used to be one KEY=VALUE file, read/written via
# _wd_state_get/_wd_state_set calling `grep`+`touch`+`mktemp`+`mv` on every
# single key access - over 20 forked processes per iface per cycle just for
# bookkeeping, dominating CPU usage on a loaded Pi. It is now a single
# associative array (_WD_IFSTATE) loaded from one file with a native `while
# read` loop (no fork) at the START of processing one iface, mutated in
# memory with plain array accesses (${_WD_IFSTATE[KEY]:-default} / assignment,
# no forks at all), and written back with exactly one `mv` (the only
# unavoidable fork) at the END - regardless of how many fields are touched
# in between. _wd_process_iface (the only caller) wraps its early-return
# -heavy inner logic (_wd_process_iface_inner) so this load/dump happens
# exactly once per iface per cycle no matter which code path runs.
# ---------------------------------------------------------------------------
declare -g -A _WD_IFSTATE=()

_wd_state_load() {
    local ifn="$1" k v
    local f="$_WD_RUN_DIR/wd_${ifn}.state"
    _WD_IFSTATE=()
    [[ -f "$f" ]] || return 0
    while IFS='=' read -r k v; do
        [[ -n "$k" ]] && _WD_IFSTATE[$k]="$v"
    done <"$f"
}

_wd_state_dump() {
    local ifn="$1" tmp k
    local f="$_WD_RUN_DIR/wd_${ifn}.state"
    tmp="${f}.tmp.$$"
    {
        for k in "${!_WD_IFSTATE[@]}"; do
            printf '%s=%s\n' "$k" "${_WD_IFSTATE[$k]}"
        done
    } >"$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
}

# Rebind / bus-off occurrence windows. Kept in CAN_TOOLS_STATE_DIR (§1c:
# "回数は /var/lib/can_tools/state に持ち、クラッシュループで枠が戻らない
# ようにする"): a crash-looping watchdog (Restart=always) must not get its
# rebind quota back just because the process restarted.
_wd_rebind_times_path() { printf '%s/rebind_times_%s' "$_WD_STATE_DIR" "$1"; }
_wd_busoff_times_path() { printf '%s/busoff_times_%s' "$_WD_STATE_DIR" "$1"; }

_wd_append_time() {
    local f="$1" now="$2"
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
# `now` is always passed in by the caller (it already has it from the
# current cycle) rather than re-read via can_now, to avoid an extra fork per
# log call.
# ===========================================================================

# _wd_log_rated <prio> <iface> <reason> <rate_s> <now> <msg...>
_wd_log_rated() {
    local prio="$1" ifn="$2" reason="$3" rate="$4" now="$5"
    shift 5
    local msg="$*"
    local key ts_file cnt_file last cnt
    key="${ifn}_${reason}"
    key="${key//[^A-Za-z0-9_]/_}"
    ts_file="$_WD_RUN_DIR/log/${key}.ts"
    cnt_file="$_WD_RUN_DIR/log/${key}.cnt"
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

# _wd_log <prio> <iface> <reason> <now> <msg...> - rate-limited at WD_LOG_RATE_S.
_wd_log() {
    local prio="$1" ifn="$2" reason="$3" now="$4"
    shift 4
    _wd_log_rated "$prio" "$ifn" "$reason" "${WD_LOG_RATE_S:-10}" "$now" "$@"
}

# _wd_log_force <prio> <iface> <reason> <now> <msg...> - always logs (state
# transitions / recovery actions get a counters snapshot every time, §1e),
# and resets that key's suppression window.
_wd_log_force() {
    local prio="$1" ifn="$2" reason="$3" now="$4"
    shift 4
    can_log "$prio" "iface=$ifn reason=$reason $*"
    local key
    key="${ifn}_${reason}"
    key="${key//[^A-Za-z0-9_]/_}"
    _wd_file_set "$_WD_RUN_DIR/log/${key}.ts" "$now"
    _wd_file_set "$_WD_RUN_DIR/log/${key}.cnt" 0
}

# Formats "rx=.. tx=.. rxfifo=.. txfifo=.. ifindex=.. busoff=.." for CRIT /
# NOTICE lines (§1d-1, §1e: "カウンタの snapshot"), reading current sysfs
# counters fresh (these calls are all on rare/important-event paths, not the
# per-second hot loop, so one extra can_read_stats fork each is fine).
_wd_snapshot() {
    local ifn="$1" now="$2" rx tx rxfifo txfifo ifindex busoff_n
    read -r rx tx rxfifo txfifo ifindex <<<"$(can_read_stats "$ifn" 2>/dev/null)"
    busoff_n=$(_wd_count_times "$(_wd_busoff_times_path "$ifn")" 315360000 "$now")
    printf 'rx=%s tx=%s rxfifo=%s txfifo=%s ifindex=%s busoff=%s' \
        "${rx:-0}" "${tx:-0}" "${rxfifo:-0}" "${txfifo:-0}" "${ifindex:-0}" "${busoff_n:-0}"
}

_wd_log_summary() {
    local now="$1" last ifn rx tx rxfifo txfifo ifindex deg
    last=$(_wd_file_get "$_WD_RUN_DIR/wd_summary.ts" 0)
    if (( last != 0 )) && (( now - last < ${WD_LOG_SUMMARY_S:-60} )); then
        return 0
    fi
    _wd_file_set "$_WD_RUN_DIR/wd_summary.ts" "$now"
    for ifn in $CAN_IFACES; do
        read -r rx tx rxfifo txfifo ifindex <<<"$(can_read_stats "$ifn" 2>/dev/null)"
        deg=0
        _wd_is_degraded "$ifn" && deg=1
        can_log info "iface=$ifn rx=${rx:-0} tx=${tx:-0} rxfifo=${rxfifo:-0} txfifo=${txfifo:-0} ifindex=${ifindex:-0} degraded=$deg"
    done
}

# ===========================================================================
# Degraded mode (§1d)
# ===========================================================================

_wd_is_degraded() {
    [[ -f "$_WD_RUN_DIR/degraded_$1" ]]
}

_wd_save_crash() {
    local ifn="$1" reason="$2" now="$3" dir file keep
    dir="$_WD_STATE_DIR/crash"
    mkdir -p "$dir" 2>/dev/null || true
    file="$dir/${now}-${ifn}.txt"
    {
        echo "timestamp=$now iface=$ifn reason=$reason"
        echo "--- stats ---"
        can_read_stats "$ifn" 2>/dev/null
        echo "--- journalctl -k (tail 50) ---"
        "${CAN_TOOLS_JOURNALCTL_CMD:-journalctl}" -k 9>&- 2>/dev/null | tail -n 50
    } >"$file" 2>/dev/null

    keep="${WD_CRASH_KEEP:-5}"
    # shellcheck disable=SC2012  # fake journalctl/ls environment has no `find -printf`-free equivalent worth the complexity here
    ls -1t "$dir"/*.txt 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r f; do
        rm -f "$f"
    done
}

# _wd_mark_degraded <if> <reason> <now>
# Always attaches a counters snapshot to the CRIT line (§1d-1/§1e, L6).
_wd_mark_degraded() {
    local ifn="$1" reason="$2" now="$3" marker snap
    marker="$_WD_RUN_DIR/degraded_$ifn"
    if [[ ! -f "$marker" ]]; then
        snap=$(_wd_snapshot "$ifn" "$now")
        echo "${now}:${reason}" >"$marker" 2>/dev/null
        _wd_save_crash "$ifn" "$reason" "$now"
        _wd_log_force crit "$ifn" "$reason" "$now" "degraded=1 $snap"
    fi
    _wd_file_set "${marker}.lastcrit" "$now"
}

_wd_handle_degraded() {
    local ifn="$1" now="$2" marker content reason last_crit snap
    marker="$_WD_RUN_DIR/degraded_$ifn"
    [[ -f "$marker" ]] || return 1
    content=$(cat "$marker" 2>/dev/null)
    reason="${content#*:}"
    last_crit=$(_wd_file_get "${marker}.lastcrit" 0)
    if (( now - last_crit >= ${WD_DEGRADED_CRIT_S:-600} )); then
        snap=$(_wd_snapshot "$ifn" "$now")
        _wd_log_force crit "$ifn" "manual_reboot_required" "$now" "original_reason=$reason $snap"
        _wd_file_set "${marker}.lastcrit" "$now"
    fi
    return 0
}

_wd_clear_degraded() {
    local ifn="$1"
    if [[ -z "$ifn" ]]; then
        echo "usage: can_watchdog.sh --clear-degraded <if>" >&2
        return 1
    fi
    _wd_init_dirs
    rm -f "$_WD_RUN_DIR/degraded_$ifn" "$_WD_RUN_DIR/degraded_$ifn.lastcrit" 2>/dev/null || true
    # rtnl_hung is a global, all-interface condition; clearing any one
    # iface's degraded marker also re-arms normal ip-based checking so the
    # next cycle can re-establish ground truth for everyone.
    rm -f "$_WD_RUN_DIR/rtnl_hung_active" "$_WD_RUN_DIR/wd_rtnl_hung_consec" 2>/dev/null || true
    can_log notice "iface=$ifn reason=clear_degraded action=clear"
    return 0
}

# ===========================================================================
# Oops/BUG pre-check (§1c step 1)
# ===========================================================================

_wd_precheck_oops() {
    local jctl="${CAN_TOOLS_JOURNALCTL_CMD:-journalctl}" out line
    # L7: close fd 9 for this call - it runs while can_lock is held, and
    # must not hand the lock's fd down into a child the caller doesn't track.
    out=$("$jctl" -k -b 9>&- 2>/dev/null)
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
# bus-off settle (§1b step 2): sample rx_packets until it is unchanged across
# 2 CONSECUTIVE sampling intervals (L2: 3 total samples, 2 deltas, matching
# the PR's own "2回続けて変化しなければ" wording precisely), bounded by
# WD_SETTLE_MAX_MS.
# ===========================================================================

_wd_settle() {
    local ifn="$1" sample_ms="${WD_SETTLE_SAMPLE_MS:-100}" max_ms="${WD_SETTLE_MAX_MS:-2000}"
    local sleep_s prev cur elapsed=0 unchanged=0
    sleep_s=$(_wd_ms_to_s "$sample_ms")
    read -r prev _ <<<"$(can_read_stats "$ifn")"
    while (( elapsed < max_ms )); do
        sleep "$sleep_s"
        elapsed=$((elapsed + sample_ms))
        read -r cur _ <<<"$(can_read_stats "$ifn")"
        if [[ "$cur" == "$prev" ]]; then
            unchanged=$((unchanged + 1))
            (( unchanged >= 2 )) && return 0
        else
            unchanged=0
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
    local pending_ts=${_WD_IFSTATE[BUSOFF_PENDING_TS]:-0}

    if (( pending_ts > 0 )) && (( now < pending_ts )); then
        _wd_log warning "$ifn" busoff_recovery_backoff "$now" "pending_ts=$pending_ts"
        return 1
    fi

    if ! _wd_settle "$ifn"; then
        _wd_log warning "$ifn" busoff_settle_timeout "$now" "max_ms=${WD_SETTLE_MAX_MS:-2000}"
        return 1
    fi

    # Storm detection (prunes the window as a side effect) BEFORE deciding
    # on backoff, so a forced cap can override the normal escalate/reset
    # calculation either way (L10: the cap must not be undone by a later
    # bus-off that happens to fall outside WD_BUSOFF_QUIET_S).
    local storm_window="${WD_STORM_WINDOW_S:-60}" storm_threshold="${WD_STORM_COUNT:-5}"
    local storm_count storm_was_active storm_active max="${WD_BUSOFF_BACKOFF_MAX_S:-30}"
    storm_count=$(_wd_count_times "$(_wd_busoff_times_path "$ifn")" "$storm_window" "$now")
    storm_was_active=${_WD_IFSTATE[STORM_ACTIVE]:-0}
    if (( storm_count + 1 >= storm_threshold )); then
        storm_active=1
        # L10: log the storm CRIT exactly once (edge-triggered), not every
        # time WD_LOG_RATE_S allows a repeat while the condition persists.
        if (( storm_was_active != 1 )); then
            _wd_log_force crit "$ifn" busoff_storm "$now" "count=$((storm_count + 1)) window_s=$storm_window"
        fi
    else
        storm_active=0
    fi
    _WD_IFSTATE[STORM_ACTIVE]=$storm_active

    local backoff_s=0
    if (( pending_ts == 0 )); then
        local last_ts=${_WD_IFSTATE[BUSOFF_LAST_RECOVERY_TS]:-0} quiet="${WD_BUSOFF_QUIET_S:-10}"
        if (( last_ts > 0 )) && (( now - last_ts <= quiet )); then
            backoff_s=${_WD_IFSTATE[BUSOFF_BACKOFF_S]:-0}
            if (( backoff_s <= 0 )); then backoff_s=1; else backoff_s=$((backoff_s * 2)); fi
            (( backoff_s > max )) && backoff_s=$max
        fi
    fi
    (( storm_active )) && backoff_s=$max

    if (( backoff_s > 0 )) && (( pending_ts == 0 )); then
        # Only (re-)arm a NEW wait on a fresh decision; if pending_ts was
        # already set and we got here, that wait has already been paid.
        _WD_IFSTATE[BUSOFF_BACKOFF_S]=$backoff_s
        _WD_IFSTATE[BUSOFF_PENDING_TS]=$((now + backoff_s))
        _wd_log warning "$ifn" busoff_recovery_backoff "$now" "backoff_s=$backoff_s"
        return 1
    fi
    _WD_IFSTATE[BUSOFF_BACKOFF_S]=$backoff_s
    _WD_IFSTATE[BUSOFF_PENDING_TS]=0

    if [[ -n "${CAN_TOOLS_DRY_RUN:-}" ]]; then
        can_log info "DRY_RUN: busoff recovery for $ifn (can_setup_iface)"
    fi
    can_setup_iface "$ifn"
    local rc=$?
    _wd_append_time "$(_wd_busoff_times_path "$ifn")" "$now"
    _WD_IFSTATE[BUSOFF_LAST_RECOVERY_TS]=$now

    if (( rc != 0 )); then
        _wd_log err "$ifn" busoff_recovery_failed "$now" "rc=$rc"
        return 1
    fi

    local new_rx new_tx new_rxfifo new_txfifo
    read -r new_rx new_tx new_rxfifo new_txfifo _ <<<"$(can_read_stats "$ifn")"
    # H1: baseline includes fifo counters too - the "3 recoveries with no rx
    # increase" stall path (evaluated in _wd_process_iface_inner) must also
    # require fifo errors to have grown since this point, not just
    # rx_packets being unchanged (§1c: "...かつ fifo エラーが出ている").
    _WD_IFSTATE[POST_BUSOFF_BASELINE_RX]=${new_rx:-0}
    _WD_IFSTATE[POST_BUSOFF_BASELINE_RXFIFO]=${new_rxfifo:-0}
    _WD_IFSTATE[POST_BUSOFF_BASELINE_TXFIFO]=${new_txfifo:-0}
    _WD_IFSTATE[POST_BUSOFF_UNTIL]=$((now + ${WD_STALL_POST_BUSOFF_WINDOW_S:-5}))
    _wd_log_force notice "$ifn" busoff_recovered "$now" "rx=${new_rx:-0} tx=${new_tx:-0} rxfifo=${new_rxfifo:-0} txfifo=${new_txfifo:-0}"
    return 0
}

# ===========================================================================
# §1a: TX flush on ERROR-WARNING/ERROR-PASSIVE
#
# L3: the "stale" condition is a CYCLE count (WD_STALE_TX_FLUSH_S cycles of
# Δ=0), matching §5b's literal "全 Δ=0 が 2 周続くと TX flush" wording -
# previously it compared elapsed wall-clock seconds against the same
# parameter, which needed 3 cycles (not 2) to fire at WD_LOOP_S=1.
# ===========================================================================

_wd_flush_check() {
    local ifn="$1" now="$2" drx="$3" dtx="$4" drxfifo="$5" dtxfifo="$6"

    _wd_in_list "$ifn" "${CAN_FLUSH_IFACES:-}" || return 0

    if ! { (( drx == 0 )) && (( dtx == 0 )) && (( drxfifo == 0 )) && (( dtxfifo == 0 )); }; then
        _WD_IFSTATE[FLUSH_STALE_CONSEC]=0
        return 0
    fi

    local stale_consec=${_WD_IFSTATE[FLUSH_STALE_CONSEC]:-0}
    stale_consec=$((stale_consec + 1))
    _WD_IFSTATE[FLUSH_STALE_CONSEC]=$stale_consec
    if (( stale_consec < ${WD_STALE_TX_FLUSH_S:-2} )); then
        return 0
    fi

    local pending_ts=${_WD_IFSTATE[FLUSH_PENDING_TS]:-0}
    if (( pending_ts > 0 )) && (( now < pending_ts )); then
        _wd_log warning "$ifn" flush_backoff_pending "$now" "pending_ts=$pending_ts"
        return 0
    fi

    # M3/N5-3: re-read ALL FOUR counters just before acting, under the lock,
    # and abort if ANY of them moved (not just rx_packets) - a race here is
    # exactly the rx-offload lock's trigger condition.
    can_lock "${WD_RTNL_TIMEOUT_S:-5}" || {
        _wd_log err "$ifn" lock_failed "$now" "action=flush"
        return 0
    }
    local r1 t1 rf1 tf1 r2 t2 rf2 tf2
    read -r r1 t1 rf1 tf1 _ <<<"$(can_read_stats "$ifn")"
    sleep 0.1
    read -r r2 t2 rf2 tf2 _ <<<"$(can_read_stats "$ifn")"
    if [[ "$r1" != "$r2" || "$t1" != "$t2" || "$rf1" != "$rf2" || "$tf1" != "$tf2" ]]; then
        can_unlock
        _wd_log warning "$ifn" flush_aborted_recheck "$now" "changed_between_reads=1"
        _WD_IFSTATE[FLUSH_STALE_CONSEC]=0
        return 0
    fi

    if [[ -n "${CAN_TOOLS_DRY_RUN:-}" ]]; then
        can_log info "DRY_RUN: TX flush for $ifn (can_setup_iface)"
    fi
    can_setup_iface "$ifn"
    local rc=$?
    can_unlock

    local last_ts=${_WD_IFSTATE[FLUSH_LAST_TS]:-0} backoff_s=${_WD_IFSTATE[FLUSH_BACKOFF_S]:-0}
    local next_backoff max="${WD_FLUSH_BACKOFF_MAX_S:-30}"
    if (( last_ts == 0 )); then
        next_backoff=1
    else
        if (( backoff_s <= 0 )); then next_backoff=1; else next_backoff=$((backoff_s * 2)); fi
        (( next_backoff > max )) && next_backoff=$max
    fi
    _WD_IFSTATE[FLUSH_BACKOFF_S]=$next_backoff
    _WD_IFSTATE[FLUSH_LAST_TS]=$now
    _WD_IFSTATE[FLUSH_PENDING_TS]=$((now + next_backoff))
    _WD_IFSTATE[FLUSH_STALE_CONSEC]=0

    if (( rc == 0 )); then
        _wd_log_force warning "$ifn" tx_flush "$now" "rx=${r1:-0} tx=${t1:-0} rxfifo=${rf1:-0} txfifo=${tf1:-0}"
    else
        _wd_log err "$ifn" tx_flush_failed "$now" "rc=$rc"
    fi
    return 0
}

# ===========================================================================
# §1c: rx-offload stall recovery (unbind/bind)
# ===========================================================================

# _wd_unbind_child_body - this function's NAME (not its body) is what gets
# baked into the exec'd child's argv[0] below, so /proc/<pid>/cmdline
# contains "can_tools_unbind" for the startup inflight check (L-a).
_wd_do_unbind() {
    local spidev="$1" marker="$2" unbind_file="$3" timeout="$4"
    local script='echo "$1:$BASHPID" >"$2"; echo "$1" >"$3"'
    can_run_bounded "$timeout" bash -c \
        'exec -a can_tools_unbind bash -c "$1" -- "$2" "$3" "$4"' \
        _ "$script" "$spidev" "$marker" "$unbind_file"
}

_wd_rebind_recover() {
    local ifn="$1" now="$2"

    local count
    count=$(_wd_count_times "$(_wd_rebind_times_path "$ifn")" 3600 "$now")
    if (( count >= ${WD_REBIND_MAX_PER_HOUR:-3} )); then
        _wd_mark_degraded "$ifn" "rebind_quota_exceeded" "$now"
        return 1
    fi
    # M2: record the ATTEMPT now, before taking the lock or touching
    # anything, so a watchdog crash/kill partway through (Restart=always)
    # does not refund this slot. tests/test_watchdog_stall.sh asserts this
    # entry exists even when a LATER step (e.g. bind) fails.
    _wd_append_time "$(_wd_rebind_times_path "$ifn")" "$now"

    can_lock "${WD_RTNL_TIMEOUT_S:-5}" || {
        _wd_log err "$ifn" lock_failed "$now" "action=rebind"
        return 1
    }

    local oops_line
    if ! oops_line=$(_wd_precheck_oops); then
        can_unlock
        _wd_log_force crit "$ifn" oops_detected "$now" "line=${oops_line}"
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

    # step 2: down first (harmless, already stopped; cuts IRQs / in-flight
    # tx). L8: if THIS times out, rtnl is already clearly stuck - do not
    # proceed to unbind (whose own 124 would then be mis-attributed as an
    # unbind hang) and do not consume a 2nd timeout window for nothing.
    local down_rc
    can_run_bounded "${WD_REBIND_TIMEOUT_S:-10}" "${CAN_TOOLS_IP_CMD:-ip}" link set "$ifn" down >/dev/null 2>&1
    down_rc=$?
    if (( down_rc == 124 )); then
        can_unlock
        _wd_log_force crit "$ifn" down_timeout "$now" "spidev=$spidev"
        _wd_mark_degraded "$ifn" "down_timeout" "$now"
        return 1
    fi

    # step 3: unbind (bounded, child self-identifies)
    local marker="$_WD_RUN_DIR/unbind_inflight"
    local unbind_file="${CAN_TOOLS_SYSFS_ROOT:-/sys}/bus/spi/drivers/mcp251xfd/unbind"
    _wd_do_unbind "$spidev" "$marker" "$unbind_file" "${WD_REBIND_TIMEOUT_S:-10}"
    local unbind_rc=$?

    if (( unbind_rc == 124 )); then
        # Marker intentionally left behind: the child may still be writing
        # or stuck inside the kernel unbind path. can_unlock here (§1d: "1d
        # の手順にcan_unlockする(unbind_inflightマーカーは残す)を明記").
        can_unlock
        _wd_log_force crit "$ifn" unbind_timeout "$now" "spidev=$spidev"
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

    _WD_IFSTATE[STALL_CONSEC]=0
    _WD_IFSTATE[BUSOFF_NORX_STREAK]=0
    _WD_IFSTATE[REBIND_VERIFY_UNTIL]=$((now + ${WD_STALL_VERIFY_S:-10}))

    can_unlock
    # §1c step 6: dependent-unit restarts happen AFTER can_unlock.
    _wd_restart_dependent_units
    _wd_log_force notice "$ifn" rebind_recovered "$now" "spidev=$spidev"
    return 0
}

# H2 fix: dependent-unit restarts must NEVER go through can_run_bounded.
# docker/systemd operations can legitimately take longer than
# WD_REBIND_TIMEOUT_S (§1c step 6 already calls this out for docker); if
# bounded, a slow one occupies can_run_bounded's single tracked-child slot
# (CAN_RUN_BOUNDED_PID) for its whole duration, so every can_iface_states
# call made by the main loop in the meantime returns 124 and - after
# WD_RTNL_HUNG_CONSEC cycles - every configured iface is wrongly put into
# rtnl_hung degraded mode. These are launched fully detached instead
# (setsid, new session, fd 9 closed, stdio to /dev/null, backgrounded and
# never waited on) so they cannot interact with can_run_bounded at all.
_wd_restart_dependent_units() {
    local unit container cmd
    for unit in ${CAN_DEPENDENT_UNITS:-}; do
        if [[ "$unit" == docker:* ]]; then
            container="${unit#docker:}"
            cmd=("${CAN_TOOLS_DOCKER_CMD:-docker}" restart "$container")
        else
            cmd=("${CAN_TOOLS_SYSTEMCTL_CMD:-systemctl}" --no-block restart "$unit")
        fi
        ( setsid "${cmd[@]}" </dev/null >/dev/null 2>&1 & ) 9>&-
    done
}

# ===========================================================================
# Startup reconciliation (§1): bind any spidev left driver-less, unless its
# unbind is still in flight on a live child whose cmdline matches the
# unbind-child signature (L-a; L1: the marker is only ever discarded when
# the recorded pid is gone or its cmdline no longer matches - never merely
# because it is not currently sampled as D state, which is an unreliable
# instant in a scheduler's eye), or pause is active (manual unbind is
# respected). Cheap and idempotent, so it is run at the top of every cycle,
# not just the first one. M1: the whole thing runs under can_lock (§0: "ロッ
# ク無しの操作経路を残さない"), and decides whether to act from the
# presence/absence of the kernel driver binding for the spidev, not from
# whether a netdev happens to be visible yet - a spidev that has not been
# probed at all, or one that is already bound but whose netdev enumeration
# is merely racing this check, must not be treated as "needs bind".
# ===========================================================================

_wd_startup_bind_check() {
    local now="$1" sysfs_root marker hung_spidev=""
    sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"
    marker="$_WD_RUN_DIR/unbind_inflight"

    if [[ -f "$marker" ]]; then
        local content pid spidev cmdline still_inflight=0
        content=$(cat "$marker" 2>/dev/null)
        spidev="${content%%:*}"
        pid="${content##*:}"
        if [[ "$pid" =~ ^[0-9]+$ && -f "/proc/$pid/stat" ]]; then
            cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
            if [[ "$cmdline" == *can_tools_unbind* ]]; then
                still_inflight=1
                hung_spidev="$spidev"
            fi
        fi
        (( still_inflight == 0 )) && rm -f "$marker" 2>/dev/null || true
    fi

    local pair spidev want
    for pair in ${CAN_SPI_MAP:-}; do
        spidev="${pair%%:*}"
        want="${pair#*:}"

        local spidev_path="$sysfs_root/bus/spi/devices/$spidev"
        [[ -d "$spidev_path" ]] || continue
        [[ -e "$spidev_path/driver" ]] && continue

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

        can_lock "${WD_RTNL_TIMEOUT_S:-5}" || {
            _wd_log err "$want" lock_failed "$now" "action=startup_bind"
            continue
        }

        local bind_file="$sysfs_root/bus/spi/drivers/mcp251xfd/bind"
        can_run_bounded "${WD_REBIND_TIMEOUT_S:-10}" bash -c 'echo "$0" >"$1"' "$spidev" "$bind_file"
        local rc=$?
        if (( rc != 0 )); then
            can_unlock
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
            can_unlock
            _wd_mark_degraded "$want" "bind_no_netdev" "$now"
            continue
        fi

        can_pin_name "$spidev" "$want"
        local pin_rc=$?
        if (( pin_rc == 2 )); then
            can_unlock
            _wd_mark_degraded "$want" "pin_name_collision" "$now"
            continue
        elif (( pin_rc != 0 )); then
            can_unlock
            _wd_mark_degraded "$want" "pin_name_failed" "$now"
            continue
        fi

        can_setup_iface "$want"
        can_unlock
    done
}

# ===========================================================================
# Per-iface cycle (§1 priority order: observe-only conditions are evaluated
# alongside stall detection -> stall (§1c) -> bus-off (§1b) -> flush (§1a)).
#
# H4: _wd_process_iface is a thin wrapper that loads/dumps _WD_IFSTATE
# exactly once (skipped entirely for a degraded or absent iface, which need
# no per-cycle scratch state at all); _wd_process_iface_inner holds the
# actual (early-return-heavy) decision logic and operates purely on the
# in-memory array.
# ===========================================================================

_wd_process_iface() {
    local ifn="$1" now="$2" state_val="$3"

    if _wd_is_degraded "$ifn"; then
        _wd_handle_degraded "$ifn" "$now"
        return 0
    fi

    if [[ -z "$state_val" ]]; then
        # L4: the iface is configured but did not appear in this cycle's
        # `ip -d link show type can` output at all (renamed, not yet
        # probed, etc). Rate-limited, not forced: this can be a normal,
        # temporary condition during startup.
        _wd_log warning "$ifn" iface_missing "$now" ""
        return 0
    fi

    _wd_state_load "$ifn"
    _wd_process_iface_inner "$@"
    local rc=$?
    _wd_state_dump "$ifn"
    return $rc
}

_wd_process_iface_inner() {
    local ifn="$1" now="$2" state_val="$3" restart_ms_val="$4" berr_val="$5" fd_val="$6" admin_val="$7"

    local rx tx rxfifo txfifo ifindex
    read -r rx tx rxfifo txfifo ifindex <<<"$(can_read_stats "$ifn")"
    [[ -z "$ifindex" ]] && return 0

    local prev_seen=${_WD_IFSTATE[PREV_SEEN]:-0}
    local prev_rx=${_WD_IFSTATE[PREV_RX]:-0}
    local prev_tx=${_WD_IFSTATE[PREV_TX]:-0}
    local prev_rxfifo=${_WD_IFSTATE[PREV_RXFIFO]:-0}
    local prev_txfifo=${_WD_IFSTATE[PREV_TXFIFO]:-0}
    local prev_ifindex=${_WD_IFSTATE[PREV_IFINDEX]:-0}

    local drx=0 dtx=0 drxfifo=0 dtxfifo=0
    if [[ "$prev_seen" == "1" && "$prev_ifindex" == "$ifindex" ]]; then
        drx=$((rx - prev_rx)); (( drx < 0 )) && drx=0
        dtx=$((tx - prev_tx)); (( dtx < 0 )) && dtx=0
        drxfifo=$((rxfifo - prev_rxfifo)); (( drxfifo < 0 )) && drxfifo=0
        dtxfifo=$((txfifo - prev_txfifo)); (( dtxfifo < 0 )) && dtxfifo=0
    fi

    _WD_IFSTATE[PREV_SEEN]=1
    _WD_IFSTATE[PREV_RX]=$rx
    _WD_IFSTATE[PREV_TX]=$tx
    _WD_IFSTATE[PREV_RXFIFO]=$rxfifo
    _WD_IFSTATE[PREV_TXFIFO]=$txfifo
    _WD_IFSTATE[PREV_IFINDEX]=$ifindex

    # Post-rebind verification window (§1c step 5): takes priority over
    # everything else while active. Positive evidence of stall -> fail
    # immediately; a quiet bus through the whole window -> success, resume
    # normal detection next cycle.
    local rv_until=${_WD_IFSTATE[REBIND_VERIFY_UNTIL]:-0}
    if (( rv_until > 0 )); then
        if (( drx == 0 )) && { (( drxfifo > 0 )) || (( dtxfifo > 0 )); }; then
            _WD_IFSTATE[REBIND_VERIFY_UNTIL]=0
            _wd_mark_degraded "$ifn" "rebind_verify_failed" "$now"
            return 0
        fi
        (( now >= rv_until )) && _WD_IFSTATE[REBIND_VERIFY_UNTIL]=0
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
        _wd_log warning "$ifn" config_mismatch_reboot_required "$now" \
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

    local stall_consec=${_WD_IFSTATE[STALL_CONSEC]:-0}
    if (( stall_signal )); then
        stall_consec=$((stall_consec + 1))
    else
        stall_consec=0
    fi
    _WD_IFSTATE[STALL_CONSEC]=$stall_consec

    local post_until=${_WD_IFSTATE[POST_BUSOFF_UNTIL]:-0} required="${WD_STALL_CONSEC:-3}"
    if (( post_until > 0 && now <= post_until )); then
        required="${WD_STALL_POST_BUSOFF_CONSEC:-2}"
    fi
    if (( post_until > 0 && now >= post_until )); then
        # H1: "3 bus-off recoveries with no rx increase" ALSO requires
        # positive evidence that fifo errors grew since the recovery
        # (§1c: "...一度も増えず、かつ fifo エラーが出ている"). Without this,
        # a genuinely quiet/shorted bus (rx AND fifo both static) was
        # wrongly treated as a stall and rebound every ~3 busoff cycles.
        local baseline_rx=${_WD_IFSTATE[POST_BUSOFF_BASELINE_RX]:-0}
        local baseline_rxfifo=${_WD_IFSTATE[POST_BUSOFF_BASELINE_RXFIFO]:-0}
        local baseline_txfifo=${_WD_IFSTATE[POST_BUSOFF_BASELINE_TXFIFO]:-0}
        local streak=${_WD_IFSTATE[BUSOFF_NORX_STREAK]:-0}
        local fifo_grew=0
        { (( rxfifo > baseline_rxfifo )) || (( txfifo > baseline_txfifo )); } && fifo_grew=1
        if (( rx == baseline_rx )) && (( fifo_grew )); then
            streak=$((streak + 1))
        else
            streak=0
        fi
        _WD_IFSTATE[BUSOFF_NORX_STREAK]=$streak
        _WD_IFSTATE[POST_BUSOFF_UNTIL]=0
    fi

    local norx_streak=${_WD_IFSTATE[BUSOFF_NORX_STREAK]:-0}

    local stall_triggered=0
    if (( stall_signal )) && (( stall_consec >= required )); then
        stall_triggered=1
    elif (( norx_streak >= 3 )); then
        stall_triggered=1
    fi

    if (( stall_triggered )); then
        if (( observe_only )); then
            _wd_log crit "$ifn" stall_detected_observe_only "$now" "rx=$rx rxfifo=$rxfifo txfifo=$txfifo reasons=${observe_reason}"
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
    local active_since=${_WD_IFSTATE[ACTIVE_SINCE]:-0}
    if [[ "$state_val" == "ERROR-ACTIVE" ]]; then
        if (( active_since == 0 )); then
            active_since=$now
            _WD_IFSTATE[ACTIVE_SINCE]=$now
        fi
        if (( now - active_since >= 60 )); then
            _WD_IFSTATE[FLUSH_BACKOFF_S]=0
            _WD_IFSTATE[FLUSH_LAST_TS]=0
        fi
    else
        (( active_since != 0 )) && _WD_IFSTATE[ACTIVE_SINCE]=0
    fi

    if [[ "$state_val" == "BUS-OFF" ]]; then
        _wd_busoff_recover "$ifn" "$now"
        return 0
    fi

    if [[ "$state_val" == "ERROR-WARNING" || "$state_val" == "ERROR-PASSIVE" ]]; then
        _wd_flush_check "$ifn" "$now" "$drx" "$dtx" "$drxfifo" "$dtxfifo"
        return 0
    fi

    _WD_IFSTATE[FLUSH_STALE_CONSEC]=0
    return 0
}

# ===========================================================================
# One full watchdog cycle.
# ===========================================================================

_wd_cycle() {
    _wd_init_dirs
    mkdir -p "$_WD_RUN_DIR" "$_WD_STATE_DIR" "$_WD_RUN_DIR/log" 2>/dev/null || true

    can_read_conf

    local now
    now=$(can_now)

    if can_pause_active; then
        _wd_log_rated warning "-" pause_active "${WD_PAUSE_WARN_S:-600}" "$now" ""
    elif [[ -f "$_WD_RUN_DIR/watchdog.pause" ]]; then
        # L5: a pause file exists but can_pause_active says it is not
        # active - either malformed or (far more commonly) simply expired.
        # Warn so an operator doesn't assume "no pause file = never paused".
        local deadline
        deadline=$(_wd_file_get "$_WD_RUN_DIR/watchdog.pause" "")
        if [[ "$deadline" =~ ^[0-9]+$ ]]; then
            _wd_log warning "-" pause_expired "$now" "deadline=$deadline"
        fi
    fi

    _wd_startup_bind_check "$now"

    if [[ -f "$_WD_RUN_DIR/rtnl_hung_active" ]]; then
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
    local states_file="$_WD_RUN_DIR/wd_states_$$.txt"
    can_iface_states >"$states_file" 2>/dev/null
    local rc=$?

    if (( rc == 124 )); then
        rm -f "$states_file"
        local consec
        consec=$(_wd_file_get "$_WD_RUN_DIR/wd_rtnl_hung_consec" 0)
        consec=$((consec + 1))
        _wd_file_set "$_WD_RUN_DIR/wd_rtnl_hung_consec" "$consec"
        if (( consec >= ${WD_RTNL_HUNG_CONSEC:-3} )); then
            echo "$now" >"$_WD_RUN_DIR/rtnl_hung_active"
            local ifn2
            for ifn2 in $CAN_IFACES; do
                _wd_mark_degraded "$ifn2" "rtnl_hung" "$now"
            done
        fi
        _wd_log warning "-" rtnl_hung "$now" "consec=$consec"
        return 0
    fi
    _wd_file_set "$_WD_RUN_DIR/wd_rtnl_hung_consec" 0

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
