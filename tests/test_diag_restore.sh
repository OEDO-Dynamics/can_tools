#!/bin/bash

# Test can_diag.sh's restore-on-exit guarantees (Issue #9 review H1, H2, H3,
# M1, M2, M4): original restart-ms/berr/fd restored, pause ownership is
# respected, forced-termination (SIGTERM/SIGINT) still restores and cleans
# up its candump child, and a hanging `ip` is bounded rather than hanging
# the whole script.

pass=0 fail=0

check() {
    if [[ "$1" == "0" ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: $2"
    fi
}

fakes_path=$(cd "$(dirname "$0")/fakes" && pwd) || exit 1
diag_fakes_path=$(cd "$(dirname "$0")/diag_fakes" && pwd) || exit 1
repo_dir=$(cd "$(dirname "$0")/.." && pwd) || exit 1

# ---------------------------------------------------------------------------
# Test 1: normal run restores berr-reporting and cleans up pause/lock (H1)
# ---------------------------------------------------------------------------
run_normal() {
    local tmpdir
    tmpdir=$(mktemp -d)

    export CAN_TOOLS_RUN_DIR="$tmpdir/run"
    export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
    export CAN_TOOLS_IP_CMD="$fakes_path/ip"
    export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"
    export CAN_TOOLS_CANDUMP_CMD="$diag_fakes_path/candump"
    export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
    export CAN_TOOLS_FAKE_TIME_FILE="$tmpdir/time"
    echo "1700000000" >"$CAN_TOOLS_FAKE_TIME_FILE"

    mkdir -p "$tmpdir/run" "$tmpdir/fake/can0" "$tmpdir/fake/can1"
    echo "ERROR-ACTIVE" >"$tmpdir/fake/can0/state"
    echo "restart_ms=0 berr=off fd=on admin=up" >"$tmpdir/fake/can0/config"
    echo "ERROR-ACTIVE" >"$tmpdir/fake/can1/state"
    echo "restart_ms=0 berr=off fd=on admin=up" >"$tmpdir/fake/can1/config"

    mkdir -p "$tmpdir/sys/class/net/can0/statistics" "$tmpdir/sys/class/net/can1/statistics"
    for f in rx_packets tx_packets rx_fifo_errors tx_fifo_errors; do
        echo "0" >"$tmpdir/sys/class/net/can0/statistics/$f"
        echo "0" >"$tmpdir/sys/class/net/can1/statistics/$f"
    done

    echo "Testing can_diag.sh restore on normal exit..."
    ( cd "$repo_dir" && bash can_diag.sh 3 >/dev/null 2>&1 )
    local rc=$?
    check "$rc" "can_diag.sh should exit cleanly (got rc=$rc)"

    # restart_ms=0 and fd=on must survive the round trip (PR-B sets
    # restart-ms 0 as the lib default; a diag run must not flip it back to
    # 100, nor drop fd - that is exactly the regression H1 guards against).
    local cfg0 cfg1
    cfg0=$(cat "$tmpdir/fake/can0/config")
    cfg1=$(cat "$tmpdir/fake/can1/config")

    echo "$cfg0" | grep -q "berr=off"
    check $? "can0 berr-reporting should be restored to off (got: $cfg0)"
    echo "$cfg0" | grep -q "restart_ms=0"
    check $? "can0 restart_ms should be restored to its ORIGINAL value 0, not a default (got: $cfg0)"
    echo "$cfg0" | grep -q "fd=on"
    check $? "can0 fd should be restored to its ORIGINAL value on (got: $cfg0)"

    echo "$cfg1" | grep -q "berr=off"
    check $? "can1 berr-reporting should be restored to off (got: $cfg1)"
    echo "$cfg1" | grep -q "restart_ms=0"
    check $? "can1 restart_ms should be restored to 0 (got: $cfg1)"

    [[ ! -f "$tmpdir/run/watchdog.pause" ]]
    check $? "watchdog.pause should be cleaned up on exit"

    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 2: invalid duration / help exit before any change is made
# ---------------------------------------------------------------------------
run_invalid_args() {
    local tmpdir
    tmpdir=$(mktemp -d)
    export CAN_TOOLS_RUN_DIR="$tmpdir/run"
    export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
    export CAN_TOOLS_IP_CMD="$fakes_path/ip"
    export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"
    export CAN_TOOLS_CANDUMP_CMD="$diag_fakes_path/candump"
    export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
    mkdir -p "$tmpdir/run" "$tmpdir/fake/can0"
    echo "ERROR-ACTIVE" >"$tmpdir/fake/can0/state"
    echo "restart_ms=0 berr=off fd=on admin=up" >"$tmpdir/fake/can0/config"

    echo "Testing can_diag.sh rejects bad input without touching anything..."

    for bad in "invalid_duration" "0" "61" "-1"; do
        ( cd "$repo_dir" && bash can_diag.sh "$bad" >/dev/null 2>&1 )
        local rc=$?
        if [[ $rc -ne 0 ]]; then check 0 "can_diag.sh $bad should exit non-zero (got rc=$rc)"
        else check 1 "can_diag.sh $bad should exit non-zero (got rc=$rc)"; fi
    done

    # L1: --help must work even mixed with other args, and before validation.
    ( cd "$repo_dir" && bash can_diag.sh --help >/dev/null 2>&1 )
    check $? "can_diag.sh --help should exit 0"
    ( cd "$repo_dir" && bash can_diag.sh 61 --help >/dev/null 2>&1 )
    check $? "can_diag.sh 61 --help should still print help (checked before duration validation)"

    local _no_pause_rc=0
    [[ ! -f "$tmpdir/run/watchdog.pause" ]] || _no_pause_rc=1
    check "$_no_pause_rc" "no pause should have been created for invalid/help invocations"

    local cfg0
    cfg0=$(cat "$tmpdir/fake/can0/config")
    [[ "$cfg0" == "restart_ms=0 berr=off fd=on admin=up" ]]
    check $? "can0 config must be untouched by invalid/help invocations (got: $cfg0)"

    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 3: forced termination (SIGTERM) mid-capture (H1, H2, M4)
# ---------------------------------------------------------------------------
run_sigterm() {
    local tmpdir
    tmpdir=$(mktemp -d)
    export CAN_TOOLS_RUN_DIR="$tmpdir/run"
    export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
    export CAN_TOOLS_IP_CMD="$fakes_path/ip"
    export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"
    export CAN_TOOLS_CANDUMP_CMD="$diag_fakes_path/candump"
    export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
    export CAN_TOOLS_DIAG_CANDUMP_HANG=1

    mkdir -p "$tmpdir/run" "$tmpdir/fake/can0"
    echo "ERROR-ACTIVE" >"$tmpdir/fake/can0/state"
    echo "restart_ms=0 berr=off fd=on admin=up" >"$tmpdir/fake/can0/config"
    mkdir -p "$tmpdir/sys/class/net/can0/statistics"
    for f in rx_packets tx_packets rx_fifo_errors tx_fifo_errors; do
        echo "0" >"$tmpdir/sys/class/net/can0/statistics/$f"
    done

    echo "Testing can_diag.sh restores state on SIGTERM mid-capture..."

    ( cd "$repo_dir" && exec bash can_diag.sh 30 >"$tmpdir/out.log" 2>&1 ) &
    local diag_pid=$!
    sleep 1.5

    # the fake candump (CAN_TOOLS_DIAG_CANDUMP_HANG=1) should now be running
    pgrep -f "$diag_fakes_path/candump" >/dev/null 2>&1
    check $? "fake candump should be running before we signal can_diag.sh"

    kill -TERM "$diag_pid" 2>/dev/null
    wait "$diag_pid" 2>/dev/null
    local rc=$?
    local _term_rc=0
    [[ $rc -ne 0 ]] || _term_rc=1
    check "$_term_rc" "can_diag.sh killed by SIGTERM should exit non-zero (got rc=$rc)"

    # H2: the candump child must not survive the parent (give --kill-after
    # + our own escalation a little time to land).
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$diag_fakes_path/candump" >/dev/null 2>&1 || break
        sleep 0.3
    done
    if pgrep -f "$diag_fakes_path/candump" >/dev/null 2>&1; then
        check 1 "fake candump must not survive can_diag.sh being SIGTERM'd (H2)"
        pkill -KILL -f "$diag_fakes_path/candump" 2>/dev/null || true
    else
        check 0 "fake candump must not survive can_diag.sh being SIGTERM'd (H2)"
    fi

    # H1: restart_ms=0/fd=on must still be restored even on a forced kill.
    local cfg0
    cfg0=$(cat "$tmpdir/fake/can0/config")
    echo "$cfg0" | grep -q "berr=off"
    check $? "can0 berr-reporting should be restored to off after SIGTERM (got: $cfg0)"
    echo "$cfg0" | grep -q "restart_ms=0"
    check $? "can0 restart_ms should be restored to 0 after SIGTERM (got: $cfg0)"

    [[ ! -f "$tmpdir/run/watchdog.pause" ]]
    check $? "watchdog.pause should be cleaned up after SIGTERM"

    # lock must be released: we should be able to grab it ourselves, now.
    exec 8>"$tmpdir/run/lock"
    flock -n 8
    check $? "lock should be released after SIGTERM (flock -n should succeed)"
    exec 8>&-

    unset CAN_TOOLS_DIAG_CANDUMP_HANG
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 4: forced termination (SIGINT) mid-capture (M4)
# ---------------------------------------------------------------------------
run_sigint() {
    local tmpdir
    tmpdir=$(mktemp -d)
    export CAN_TOOLS_RUN_DIR="$tmpdir/run"
    export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
    export CAN_TOOLS_IP_CMD="$fakes_path/ip"
    export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"
    export CAN_TOOLS_CANDUMP_CMD="$diag_fakes_path/candump"
    export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
    export CAN_TOOLS_DIAG_CANDUMP_HANG=1

    mkdir -p "$tmpdir/run" "$tmpdir/fake/can0"
    echo "ERROR-ACTIVE" >"$tmpdir/fake/can0/state"
    echo "restart_ms=0 berr=off fd=on admin=up" >"$tmpdir/fake/can0/config"
    mkdir -p "$tmpdir/sys/class/net/can0/statistics"
    for f in rx_packets tx_packets rx_fifo_errors tx_fifo_errors; do
        echo "0" >"$tmpdir/sys/class/net/can0/statistics/$f"
    done

    echo "Testing can_diag.sh restores state on SIGINT mid-capture..."

    ( cd "$repo_dir" && exec bash can_diag.sh 30 >"$tmpdir/out.log" 2>&1 ) &
    local diag_pid=$!
    sleep 1.5
    kill -INT "$diag_pid" 2>/dev/null
    wait "$diag_pid" 2>/dev/null
    local rc=$?
    [[ $rc -ne 0 ]]
    check $? "can_diag.sh killed by SIGINT should exit non-zero (got rc=$rc)"

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$diag_fakes_path/candump" >/dev/null 2>&1 || break
        sleep 0.3
    done
    if pgrep -f "$diag_fakes_path/candump" >/dev/null 2>&1; then
        check 1 "fake candump must not survive can_diag.sh being SIGINT'd (H2/M4)"
        pkill -KILL -f "$diag_fakes_path/candump" 2>/dev/null || true
    else
        check 0 "fake candump must not survive can_diag.sh being SIGINT'd (H2/M4)"
    fi

    [[ ! -f "$tmpdir/run/watchdog.pause" ]]
    check $? "watchdog.pause should be cleaned up after SIGINT"

    unset CAN_TOOLS_DIAG_CANDUMP_HANG
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 5: lock held by someone else -> fail WITHOUT touching their pause (M2a)
# ---------------------------------------------------------------------------
run_lock_contention() {
    local tmpdir
    tmpdir=$(mktemp -d)
    export CAN_TOOLS_RUN_DIR="$tmpdir/run"
    export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
    export CAN_TOOLS_IP_CMD="$fakes_path/ip"
    export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"
    export CAN_TOOLS_CANDUMP_CMD="$diag_fakes_path/candump"
    export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
    export CAN_TOOLS_FAKE_TIME_FILE="$tmpdir/time"
    echo "1700000000" >"$CAN_TOOLS_FAKE_TIME_FILE"

    mkdir -p "$tmpdir/run" "$tmpdir/fake/can0"
    echo "ERROR-ACTIVE" >"$tmpdir/fake/can0/state"
    echo "restart_ms=0 berr=off fd=on admin=up" >"$tmpdir/fake/can0/config"

    echo "Testing can_diag.sh does not clobber another holder's pause when it can't get the lock (M2a)..."

    # Simulate "instance 1": already holding the lock AND an active pause
    # with a known deadline, well beyond our can_lock timeout (5s default).
    local original_deadline=1700009999
    echo "$original_deadline" >"$tmpdir/run/watchdog.pause"
    (
        exec 9>"$tmpdir/run/lock"
        flock -x 9
        sleep 8
    ) &
    local holder_pid=$!
    sleep 0.3  # let the holder actually acquire the flock first

    ( cd "$repo_dir" && bash can_diag.sh 3 >"$tmpdir/out.log" 2>&1 )
    local rc=$?
    local _lockfail_rc=0
    [[ $rc -ne 0 ]] || _lockfail_rc=1
    check "$_lockfail_rc" "can_diag.sh should fail when it cannot acquire the lock (got rc=$rc)"

    local final_pause
    final_pause=$(cat "$tmpdir/run/watchdog.pause" 2>/dev/null)
    local _pause_match_rc=0
    [[ "$final_pause" == "$original_deadline" ]] || _pause_match_rc=1
    check "$_pause_match_rc" "the other holder's pause deadline must be restored exactly, not deleted or left extended (got: $final_pause, want: $original_deadline)"

    local cfg0
    cfg0=$(cat "$tmpdir/fake/can0/config")
    [[ "$cfg0" == "restart_ms=0 berr=off fd=on admin=up" ]]
    check $? "can0 config must be untouched when the lock could not be acquired (got: $cfg0)"

    wait "$holder_pid" 2>/dev/null
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 6: a hanging `ip` must not hang can_diag.sh (H3)
# ---------------------------------------------------------------------------
run_ip_hang() {
    local tmpdir
    tmpdir=$(mktemp -d)
    export CAN_TOOLS_RUN_DIR="$tmpdir/run"
    export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
    export CAN_TOOLS_IP_CMD="$fakes_path/ip"
    export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"
    export CAN_TOOLS_CANDUMP_CMD="$diag_fakes_path/candump"
    export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
    export WD_RTNL_TIMEOUT_S=1

    mkdir -p "$tmpdir/run" "$tmpdir/fake/hang" "$tmpdir/fake/can0"
    touch "$tmpdir/fake/hang/ip"
    echo "ERROR-ACTIVE" >"$tmpdir/fake/can0/state"
    echo "restart_ms=0 berr=off fd=on admin=up" >"$tmpdir/fake/can0/config"
    mkdir -p "$tmpdir/sys/class/net/can0/statistics"
    for f in rx_packets tx_packets rx_fifo_errors tx_fifo_errors; do
        echo "0" >"$tmpdir/sys/class/net/can0/statistics/$f"
    done

    echo "Testing can_diag.sh bounds a hanging ip via can_run_bounded (H3)..."

    local start end elapsed
    start=$(date +%s)
    ( cd "$repo_dir" && timeout 20 bash can_diag.sh 2 >"$tmpdir/out.log" 2>&1 )
    local rc=$?
    end=$(date +%s)
    elapsed=$((end - start))

    [[ $rc -ne 124 ]]
    check $? "can_diag.sh itself must not be the one timing out (rc=124 would mean it hung; got rc=$rc)"
    (( elapsed < 15 ))
    check $? "can_diag.sh should finish well inside 15s despite a hanging ip (took ${elapsed}s)"

    # Clean up the leaked fake `ip` processes can_run_bounded intentionally
    # does not wait for (that is its documented contract: abandon on 124).
    pkill -KILL -f "$fakes_path/ip" 2>/dev/null || true

    unset WD_RTNL_TIMEOUT_S
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 7: SIGTERM while a can_setup_iface(berr on) call is still in flight
# must still end up with the interface fully restored (Issue #9 2nd review,
# H2): the iface must be registered for restore BEFORE the call that can
# block, and cleanup must wait (bounded) for that call's outstanding bounded
# child before trying to restore - otherwise it is abandoned half-up/down,
# with berr-reporting whatever can_setup_iface's down/up cycle happened to
# leave it as, and no pause protecting it.
# ---------------------------------------------------------------------------
run_sigterm_during_berr_setup() {
    local tmpdir
    tmpdir=$(mktemp -d)
    export CAN_TOOLS_RUN_DIR="$tmpdir/run"
    export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
    export CAN_TOOLS_IP_CMD="$diag_fakes_path/ip_slow_berr_on"
    export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"
    export CAN_TOOLS_CANDUMP_CMD="$diag_fakes_path/candump"
    export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
    export CAN_TOOLS_DIAG_IP_SLEEP=3

    mkdir -p "$tmpdir/run" "$tmpdir/fake/can0" "$tmpdir/fake/can1"
    for i in can0 can1; do
        echo "ERROR-ACTIVE" >"$tmpdir/fake/$i/state"
        echo "restart_ms=0 berr=off fd=on admin=up" >"$tmpdir/fake/$i/config"
        mkdir -p "$tmpdir/sys/class/net/$i/statistics"
        for f in rx_packets tx_packets rx_fifo_errors tx_fifo_errors; do
            echo "0" >"$tmpdir/sys/class/net/$i/statistics/$f"
        done
    done

    echo "Testing can_diag.sh restores the interface even when SIGTERM'd mid berr-on setup (H2)..."

    ( cd "$repo_dir" && exec bash can_diag.sh 30 >"$tmpdir/out.log" 2>&1 ) &
    local diag_pid=$!
    sleep 1

    kill -TERM "$diag_pid" 2>/dev/null
    wait "$diag_pid" 2>/dev/null
    local rc=$?
    local _rc_nonzero=0
    [[ $rc -ne 0 ]] || _rc_nonzero=1
    check "$_rc_nonzero" "can_diag.sh killed mid berr-on setup should exit non-zero (got rc=$rc)"

    for i in can0 can1; do
        local cfg
        cfg=$(cat "$tmpdir/fake/$i/config")
        [[ "$cfg" == "restart_ms=0 berr=off fd=on admin=up" ]]
        check $? "$i must be fully restored (admin=up, berr=off, restart_ms=0, fd=on) after SIGTERM mid berr-on setup (H2) (got: $cfg)"
    done

    [[ ! -f "$tmpdir/run/watchdog.pause" ]]
    check $? "watchdog.pause should be cleaned up after SIGTERM mid berr-on setup"

    exec 8>"$tmpdir/run/lock"
    flock -n 8
    check $? "lock should be released after SIGTERM mid berr-on setup"
    exec 8>&-

    pkill -KILL -f "$diag_fakes_path/ip_slow_berr_on" 2>/dev/null || true
    unset CAN_TOOLS_DIAG_IP_SLEEP
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 8: a SECOND signal arriving while cleanup/restore is itself still in
# progress must not abort cleanup partway through (Issue #9 2nd review, H3) -
# e.g. an operator pressing Ctrl-C twice, or systemd stop -> kill.
# ---------------------------------------------------------------------------
run_double_sigterm() {
    local tmpdir
    tmpdir=$(mktemp -d)
    export CAN_TOOLS_RUN_DIR="$tmpdir/run"
    export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
    export CAN_TOOLS_IP_CMD="$diag_fakes_path/ip_slow_berr_off"
    export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"
    export CAN_TOOLS_CANDUMP_CMD="$diag_fakes_path/candump"
    export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
    export CAN_TOOLS_DIAG_IP_SLEEP=2
    export CAN_TOOLS_DIAG_CANDUMP_HANG=1

    mkdir -p "$tmpdir/run" "$tmpdir/fake/can0" "$tmpdir/fake/can1"
    for i in can0 can1; do
        echo "ERROR-ACTIVE" >"$tmpdir/fake/$i/state"
        echo "restart_ms=0 berr=off fd=on admin=up" >"$tmpdir/fake/$i/config"
        mkdir -p "$tmpdir/sys/class/net/$i/statistics"
        for f in rx_packets tx_packets rx_fifo_errors tx_fifo_errors; do
            echo "0" >"$tmpdir/sys/class/net/$i/statistics/$f"
        done
    done

    echo "Testing can_diag.sh ignores a second TERM while cleanup/restore is in progress (H3)..."

    ( cd "$repo_dir" && exec bash can_diag.sh 30 >"$tmpdir/out.log" 2>&1 ) &
    local diag_pid=$!
    sleep 1.5
    kill -TERM "$diag_pid" 2>/dev/null
    sleep 1
    # at this point cleanup is in the H1 restore loop, blocked in the slow
    # "berr-reporting off" ip call - a second TERM here must be ignored.
    kill -TERM "$diag_pid" 2>/dev/null
    wait "$diag_pid" 2>/dev/null
    local rc=$?
    local _rc_nonzero=0
    [[ $rc -ne 0 ]] || _rc_nonzero=1
    check "$_rc_nonzero" "can_diag.sh double-SIGTERM'd should still exit non-zero (got rc=$rc)"

    for i in can0 can1; do
        local cfg
        cfg=$(cat "$tmpdir/fake/$i/config")
        [[ "$cfg" == "restart_ms=0 berr=off fd=on admin=up" ]]
        check $? "$i must still be fully restored despite the second TERM during cleanup (H3) (got: $cfg)"
    done

    [[ ! -f "$tmpdir/run/watchdog.pause" ]]
    check $? "watchdog.pause should be cleaned up despite the second TERM during cleanup (H3)"

    exec 8>"$tmpdir/run/lock"
    flock -n 8
    check $? "lock should be released despite the second TERM during cleanup (H3)"
    exec 8>&-

    pkill -KILL -f "$diag_fakes_path/candump" 2>/dev/null || true
    unset CAN_TOOLS_DIAG_IP_SLEEP CAN_TOOLS_DIAG_CANDUMP_HANG
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 9: two concurrent runs - the second must never sample/capture with
# berr-reporting on while unpaused (Issue #9 2nd review, M2): the probe-to-
# lock gap is not protected by can_lock, so re-assert the pause once the
# lock is actually held, before touching any interface.
# ---------------------------------------------------------------------------
run_concurrent_pause() {
    local tmpdir
    tmpdir=$(mktemp -d)
    export CAN_TOOLS_RUN_DIR="$tmpdir/run"
    export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
    export CAN_TOOLS_IP_CMD="$fakes_path/ip"
    export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"
    export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"

    mkdir -p "$tmpdir/run" "$tmpdir/fake/can0"
    echo "ERROR-ACTIVE" >"$tmpdir/fake/can0/state"
    echo "restart_ms=0 berr=off fd=on admin=up" >"$tmpdir/fake/can0/config"
    mkdir -p "$tmpdir/sys/class/net/can0/statistics"
    for f in rx_packets tx_packets rx_fifo_errors tx_fifo_errors; do
        echo "0" >"$tmpdir/sys/class/net/can0/statistics/$f"
    done

    cat >"$tmpdir/candump_A" <<'EOF'
#!/bin/bash
sleep 2
exit 0
EOF
    chmod +x "$tmpdir/candump_A"
    cat >"$tmpdir/candump_B" <<'EOF'
#!/bin/bash
sleep 1
exit 0
EOF
    chmod +x "$tmpdir/candump_B"

    echo "Testing can_diag.sh never samples with berr on while unpaused, under concurrency (M2)..."

    ( cd "$repo_dir" && CAN_TOOLS_CANDUMP_CMD="$tmpdir/candump_A" exec bash can_diag.sh 10 >"$tmpdir/out.A" 2>&1 ) &
    local pidA=$!
    sleep 0.3
    ( cd "$repo_dir" && CAN_TOOLS_CANDUMP_CMD="$tmpdir/candump_B" exec bash can_diag.sh 10 >"$tmpdir/out.B" 2>&1 ) &
    local pidB=$!

    local violation=0
    local i
    for i in $(seq 1 40); do
        local pause berr
        pause=$(cat "$tmpdir/run/watchdog.pause" 2>/dev/null || echo "")
        berr=$(grep -o 'berr=[a-z]*' "$tmpdir/fake/can0/config" 2>/dev/null)
        if [[ -z "$pause" && "$berr" == "berr=on" ]]; then
            violation=1
            echo "  VIOLATION at poll $i: pause file missing while berr=on"
        fi
        kill -0 "$pidA" 2>/dev/null || kill -0 "$pidB" 2>/dev/null || break
        sleep 0.15
    done

    check "$violation" "berr-reporting must never be on while the pause file is absent, even with two concurrent runs (M2 - N7)"

    wait "$pidA" 2>/dev/null; local rcA=$?
    wait "$pidB" 2>/dev/null; local rcB=$?
    local _ab_ok=0
    [[ $rcA -eq 0 && $rcB -eq 0 ]] || _ab_ok=1
    check "$_ab_ok" "both concurrent runs should exit cleanly, not crash or leave the other hanging (rcA=$rcA rcB=$rcB)"

    local final_berr
    final_berr=$(grep -o 'berr=[a-z]*' "$tmpdir/fake/can0/config")
    [[ "$final_berr" == "berr=off" ]]
    check $? "berr-reporting should be off once both concurrent runs have finished (got: $final_berr)"

    rm -rf "$tmpdir"
}

run_normal
run_invalid_args
run_sigterm
run_sigint
run_lock_contention
run_ip_hang
run_sigterm_during_berr_setup
run_double_sigterm
run_concurrent_pause

echo ""
echo "Results: $pass passed, $fail failed"

if (( fail > 0 )); then
    exit 1
fi

exit 0
