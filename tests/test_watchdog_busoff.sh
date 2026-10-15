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
backoff_val=$(_wd_state_get can0 BUSOFF_BACKOFF_S 0)
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

echo ""
echo "Bus-off tests: $pass passed, $fail failed"
exit $fail
