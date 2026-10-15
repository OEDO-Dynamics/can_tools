#!/bin/bash
# tests/test_watchdog_busoff.sh - §1b bus-off recovery: settle, backoff,
# storm detection, and the short post-recovery stall window (§1c bullet 6).

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
cleanup() {
    pkill -9 -f can_tools_unbind 2>/dev/null || true
    pkill -9 -f "$repo_root/tests/fakes/ip" 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

pass=0 fail=0
check() {
    if [[ "$1" == "0" ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: $2"
    fi
}

export CAN_TOOLS_RUN_DIR="$tmpdir/run"
export CAN_TOOLS_STATE_DIR="$tmpdir/state"
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sysfs"
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
export CAN_TOOLS_IP_CMD="$repo_root/tests/fakes/ip"
export CAN_TOOLS_JOURNALCTL_CMD="$repo_root/tests/fakes/journalctl"
export CAN_TOOLS_SYSTEMCTL_CMD="$repo_root/tests/fakes/systemctl"
export CAN_TOOLS_DOCKER_CMD="$repo_root/tests/fakes/docker"
export CAN_TOOLS_CONF="$tmpdir/conf"
export CAN_TOOLS_FAKE_TIME_FILE="$tmpdir/time"
export CAN_TOOLS_TEST_SPI_MAP="spi0.0:can0 spi1.0:can1"

mkdir -p "$CAN_TOOLS_FAKE_DIR/can0" "$CAN_TOOLS_FAKE_DIR/can1"
# NOTE: can_read_conf() resets every WD_*/CAN_* key to the lib's default on
# every call (it does not look at the process environment), so all tuning
# for the watchdog under test must live in the conf FILE, not in exported
# env vars (only the CAN_TOOLS_* plumbing vars - *_CMD, *_DIR, *_FAKE_* -
# are read directly from the environment by the lib).
cat >"$CAN_TOOLS_CONF" <<'EOF'
CAN_RESTART_MS=0
CAN_BERR_REPORTING=off
CAN_FD=off
WD_SETTLE_SAMPLE_MS=5
WD_SETTLE_MAX_MS=20
WD_BUSOFF_QUIET_S=10
WD_BUSOFF_BACKOFF_MAX_S=30
WD_STORM_COUNT=3
WD_STORM_WINDOW_S=60
WD_STALL_POST_BUSOFF_WINDOW_S=5
WD_STALL_POST_BUSOFF_CONSEC=2
EOF
# shellcheck source=/dev/null
source "$repo_root/can_watchdog.sh"

# M1: can_watchdog.sh's startup reconciliation now decides "needs bind"
# from the presence/absence of a /sys/bus/spi/devices/<spidev>/driver
# symlink (matching real kernel sysfs), not from whether a netdev happens
# to be visible yet. tests/fakes/mk_sysfs.sh (shared, not modified by this
# PR) does not model that symlink, so each write_scenario call here
# synthesizes it itself for every spidev that currently has a netdev under
# it - exactly mirroring what the real kernel does for an actually-bound
# device. This is local test fixture setup, not a change to tests/fakes/.
_sync_driver_links() {
    local d
    for d in "$CAN_TOOLS_SYSFS_ROOT"/bus/spi/devices/*/; do
        [[ -d "$d" ]] || continue
        if [[ -n "$(ls -A "$d/net" 2>/dev/null)" ]]; then
            [[ -e "${d}driver" ]] || ln -s "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd" "${d}driver"
        fi
    done
}

write_scenario() {
    local tick="$1"
    shift
    local f="$tmpdir/scenario.txt"
    : >"$f"
    local line
    for line in "$@"; do
        echo "$tick $line" >>"$f"
    done
    "$repo_root/tests/fakes/mk_sysfs.sh" "$f" "$tick"
    _sync_driver_links
}

reset_all() {
    rm -rf "$CAN_TOOLS_RUN_DIR" "$CAN_TOOLS_STATE_DIR"
    rm -f "$CAN_TOOLS_FAKE_DIR/calls.log"
}

echo "=== BUS-OFF -> settle completes (static rx) -> recovery (down/up) fires ==="
reset_all
echo "BUS-OFF" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
echo 1000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 1 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
grep -q "link set can0 down" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "bus-off recovery should bring the iface down first"
grep -q "link set can0 up" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "bus-off recovery should bring the iface back up"

echo "=== repeat bus-off within WD_BUSOFF_QUIET_S -> backoff gates the next recovery ==="
reset_all
echo "BUS-OFF" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo 2000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 10 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
up_count_1=$(grep -c "link set can0 up" "$CAN_TOOLS_FAKE_DIR/calls.log")
echo 2002 >"$CAN_TOOLS_FAKE_TIME_FILE"   # within WD_BUSOFF_QUIET_S of the first recovery
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
up_count_2=$(grep -c "link set can0 up" "$CAN_TOOLS_FAKE_DIR/calls.log")
cond1=0; [[ "$up_count_1" == "1" && "$up_count_2" == "1" ]] || cond1=1
check $cond1 "a 2nd bus-off right after the 1st should not execute down/up immediately (1s backoff pending), got $up_count_1 then $up_count_2"
backoff_val=$(grep -m1 "^BUSOFF_BACKOFF_S=" "$CAN_TOOLS_RUN_DIR/wd_can0.state" 2>/dev/null | cut -d= -f2)
backoff_val="${backoff_val:-0}"
cond2=0; [[ "$backoff_val" == "1" ]] || cond2=1
check $cond2 "backoff should have escalated to 1s for the pending recovery, got $backoff_val"

echo 2003 >"$CAN_TOOLS_FAKE_TIME_FILE"   # backoff elapsed
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
up_count_3=$(grep -c "link set can0 up" "$CAN_TOOLS_FAKE_DIR/calls.log")
cond3=0; [[ "$up_count_3" == "2" ]] || cond3=1
check $cond3 "once the backoff window elapses, the deferred recovery should execute, got count=$up_count_3"

echo "=== storm: WD_STORM_COUNT bus-offs in the window -> CRIT logged ==="
reset_all
echo "BUS-OFF" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
t=3000
for i in 1 2 3; do
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$i" "can0 50 50 0 0 3" "can1 50 0 0 0 4"
    out=$("$repo_root/can_watchdog.sh" --once 2>&1)
    t=$((t + 15))  # outside WD_BUSOFF_QUIET_S(10) so each one executes immediately
done
echo "$out" | grep -q "reason=busoff_storm"
check $? "the 3rd bus-off within WD_STORM_WINDOW_S (with WD_STORM_COUNT=3) should log busoff_storm CRIT"

# L10(a): the CRIT must not repeat on every subsequent occurrence while the
# storm condition persists (it is edge-triggered, not just rate-limited).
t=$((t + 15))
echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 4 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
out4=$("$repo_root/can_watchdog.sh" --once 2>&1)
nr=0; echo "$out4" | grep -q "reason=busoff_storm" && nr=1
check $nr "a 4th bus-off, storm still active, must NOT log busoff_storm again (L10: once per storm, not per occurrence)"

# L10(b): the forced max backoff must persist even though this 4th
# occurrence falls OUTSIDE WD_BUSOFF_QUIET_S of the 3rd - previously the
# normal quiet-window reset (last_ts far enough away -> backoff_s=0)
# silently undid the storm cap.
got_backoff4=$(grep -m1 "^BUSOFF_BACKOFF_S=" "$CAN_TOOLS_RUN_DIR/wd_can0.state" 2>/dev/null | cut -d= -f2)
cb4=0; [[ "$got_backoff4" == "30" ]] || cb4=1
check $cb4 "the storm's forced max backoff must persist across a later out-of-quiet-window bus-off, got BUSOFF_BACKOFF_S=$got_backoff4"

echo "=== L-5: busoff_total_<if> is a true cumulative count, surviving the storm-window prune ==="
# The 3 storm-test recoveries above each ran outside WD_BUSOFF_QUIET_S, so
# each one reached the real down/up recovery path (not just a deferred
# backoff) and should have bumped the cumulative counter once.
total_after_3=$(cat "$CAN_TOOLS_STATE_DIR/busoff_total_can0" 2>/dev/null || echo 0)
cond_total1=0; [[ "$total_after_3" == "3" ]] || cond_total1=1
check $cond_total1 "busoff_total_can0 should be 3 after 3 real recoveries (got: $total_after_3)"
# The 4th occurrence (storm still active -> forced max backoff) only ARMS a
# deferred recovery this cycle (same as the normal backoff-gating test
# above); it must not double-count a bus-off that has not actually been
# recovered yet, same as busoff_times_<if> itself only growing on the real
# down/up path.
total_after_4=$(cat "$CAN_TOOLS_STATE_DIR/busoff_total_can0" 2>/dev/null || echo 0)
cond_total2=0; [[ "$total_after_4" == "3" ]] || cond_total2=1
check $cond_total2 "busoff_total_can0 must not increment for a bus-off deferred by the storm backoff, not yet actually recovered (got: $total_after_4)"

echo "=== L-5: _wd_snapshot reports both the storm-windowed busoff= and the cumulative busoff_total= ==="
# _wd_snapshot (like every other _wd_* helper here) reads the process-global
# _WD_STATE_DIR, which is only populated by _wd_init_dirs - never called yet
# in THIS shell, since every can_watchdog.sh invocation above ran as its own
# subprocess. Call it directly, exactly as _wd_cycle itself does.
_wd_init_dirs
mkdir -p "$CAN_TOOLS_STATE_DIR"
echo "100" >"$CAN_TOOLS_STATE_DIR/busoff_total_can0"
# Seed busoff_times_can0 directly so busoff= (read with the effectively
# unbounded window _wd_snapshot itself uses) is independently verifiable,
# decoupled from busoff_total_can0 - the two must NOT be forced equal.
printf '9000\n9001\n' >"$CAN_TOOLS_STATE_DIR/busoff_times_can0"
snap=$(_wd_snapshot can0 9500)
echo "$snap" | grep -q "busoff=2 "
check $? "the snapshot's busoff= should reflect busoff_times_can0 (got: $snap)"
echo "$snap" | grep -q "busoff_total=100$"
check $? "the snapshot should also report the cumulative busoff_total=, decoupled from busoff= (L-5) (got: $snap)"

echo "=== post-recovery short stall window: only WD_STALL_POST_BUSOFF_CONSEC cycles needed ==="
reset_all
echo "BUS-OFF" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo 4000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 1 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1   # recovers, opens POST_BUSOFF window (5s)
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"  # NAPI stayed dead: no new rx despite ERROR-ACTIVE
echo 4001 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 2 "can0 50 50 2 0 3" "can1 50 0 0 0 4"   # rx frozen, rxfifo growing
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
echo 4002 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 3 "can0 50 50 4 0 3" "can1 50 0 0 0 4"
out=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out" | grep -q "reason=rebind_recovered"
check $? "within the 5s post-busoff window, only 2 (not 3) consecutive stall cycles should trigger a rebind"

echo "=== settle not converging -> no down/up this cycle, deferred to the next ==="
# Deterministic (no real-time race): WD_SETTLE_MAX_MS smaller than one full
# WD_SETTLE_SAMPLE_MS interval means _wd_settle structurally cannot observe
# 2 consecutive equal samples before its budget runs out, regardless of
# whether rx_packets is actually stable - directly exercising the "settle
# never converges" path without depending on timing-sensitive background
# churn to keep the value moving.
reset_all
cat >>"$CAN_TOOLS_CONF" <<'EOF'
WD_SETTLE_SAMPLE_MS=50
WD_SETTLE_MAX_MS=10
EOF
echo "BUS-OFF" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo 6000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 1 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
out=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out" | grep -q "reason=busoff_settle_timeout"
check $? "settle exceeding WD_SETTLE_MAX_MS should log busoff_settle_timeout"
cnd=0; grep -q "link set can0 down" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null && cnd=1
check $cnd "a bus-off whose settle does not converge must not be brought down/up this cycle"
# Restore the fast settle params the rest of this file relies on.
cat >"$CAN_TOOLS_CONF" <<'EOF'
CAN_RESTART_MS=0
CAN_BERR_REPORTING=off
CAN_FD=off
WD_SETTLE_SAMPLE_MS=5
WD_SETTLE_MAX_MS=20
WD_BUSOFF_QUIET_S=10
WD_BUSOFF_BACKOFF_MAX_S=30
WD_STORM_COUNT=3
WD_STORM_WINDOW_S=60
WD_STALL_POST_BUSOFF_WINDOW_S=5
WD_STALL_POST_BUSOFF_CONSEC=2
EOF

echo "=== bus-off backoff sequence: 0 (settle only), then 1, 2, 4, ..., capped at WD_BUSOFF_BACKOFF_MAX_S ==="
# Each doubling step is verified in isolation by seeding
# BUSOFF_BACKOFF_S/BUSOFF_LAST_RECOVERY_TS directly (same technique as the
# flush backoff gating test above) rather than threading one continuous
# multi-cycle simulation through real --once calls: with a persistently
# BUS-OFF iface, every single cycle (including the "wait and recheck" ones)
# is itself another busoff occurrence, so the wall-clock bookkeeping for a
# long chained sequence gets entangled with itself. Seeding isolates exactly
# "given backoff was N and the last recovery was within the quiet window,
# what does the NEXT escalation compute" for each step independently.
_seed_busoff_state() {
    local ifn="$1" key="$2" val="$3"
    local f="$CAN_TOOLS_RUN_DIR/wd_${ifn}.state"
    mkdir -p "$(dirname "$f")"
    touch "$f"
    grep -v "^${key}=" "$f" >"$f.tmp" 2>/dev/null || true
    echo "${key}=${val}" >>"$f.tmp"
    mv "$f.tmp" "$f"
}
reset_all
echo "BUS-OFF" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
seq_ok=1
prev_backoff=0
now_ts=10000
for expect_next in 1 2 4 8 16 30 30; do
    write_scenario "y$now_ts" "can0 50 50 0 0 3" "can1 50 0 0 0 4"
    echo "$now_ts" >"$CAN_TOOLS_FAKE_TIME_FILE"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1   # establish PREV_* / settle baseline
    _seed_busoff_state can0 BUSOFF_BACKOFF_S "$prev_backoff"
    _seed_busoff_state can0 BUSOFF_LAST_RECOVERY_TS "$((now_ts - 1))"  # within WD_BUSOFF_QUIET_S
    _seed_busoff_state can0 BUSOFF_PENDING_TS 0
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
    got_backoff=$(grep -m1 "^BUSOFF_BACKOFF_S=" "$CAN_TOOLS_RUN_DIR/wd_can0.state" 2>/dev/null | cut -d= -f2)
    got_pending=$(grep -m1 "^BUSOFF_PENDING_TS=" "$CAN_TOOLS_RUN_DIR/wd_can0.state" 2>/dev/null | cut -d= -f2)
    if [[ "$got_backoff" != "$expect_next" || "$got_pending" != "$((now_ts + expect_next))" ]]; then
        seq_ok=0
        echo "  mismatch: prev=$prev_backoff -> got backoff=$got_backoff pending=$got_pending, expected backoff=$expect_next pending=$((now_ts + expect_next))"
    fi
    prev_backoff=$expect_next
    now_ts=$((now_ts + 1000))  # far apart, each step independent of storm/quiet accumulation
done
check $((1 - seq_ok)) "bus-off backoff doubling should follow 1,2,4,8,16,30,30 (capped at WD_BUSOFF_BACKOFF_MAX_S)"

echo ""
echo "Bus-off tests: $pass passed, $fail failed"
exit $fail
