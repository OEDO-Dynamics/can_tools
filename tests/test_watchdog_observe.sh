#!/bin/bash
# tests/test_watchdog_observe.sh - §1f config-mismatch / berr-on / pause /
# admin-down observe-only behavior, and CAN_FLUSH_IFACES scoping (R6).

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

# NOTE: can_read_conf() resets every WD_*/CAN_* key from the lib's defaults
# on every call; it never reads the process environment for them. All
# tuning for the watchdog under test must live in this conf FILE.
reset_env() {
    rm -rf "$CAN_TOOLS_RUN_DIR" "$CAN_TOOLS_STATE_DIR" "$CAN_TOOLS_SYSFS_ROOT"
    rm -f "$CAN_TOOLS_FAKE_DIR/calls.log"
    cat >"$CAN_TOOLS_CONF" <<'EOF'
CAN_RESTART_MS=0
CAN_BERR_REPORTING=off
CAN_FD=off
WD_LOG_RATE_S=10
WD_PAUSE_WARN_S=600
EOF
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
}

echo "=== config mismatch -> observe-only (no recovery action, WARNING logged) ==="
reset_env
echo 1000 >"$CAN_TOOLS_FAKE_TIME_FILE"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=100 berr=off fd=on admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"  # lib defaults, conf wants 0/off/off
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
write_scenario 1 "can0 100 100 0 0 3" "can1 100 0 0 0 4"
out=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out" | grep -q "reason=config_mismatch_reboot_required"
check $? "mismatched can0 should log config_mismatch_reboot_required"
! grep -q "link set can0" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "mismatched iface must not be touched (no ip link set call)"

echo "=== berr=on (effective) -> observe-only even if restart_ms/fd match ==="
reset_env
echo 1000 >"$CAN_TOOLS_FAKE_TIME_FILE"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=on fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
write_scenario 1 "can0 100 100 0 0 3" "can1 100 0 0 0 4"
out=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out" | grep -q "reason=config_mismatch_reboot_required"
check $? "berr=on (mismatched vs conf) should also be flagged via config_mismatch"

echo "=== pause active -> no recovery action anywhere, periodic WARNING ==="
reset_env
echo 1000 >"$CAN_TOOLS_FAKE_TIME_FILE"
echo "ERROR-PASSIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
mkdir -p "$CAN_TOOLS_RUN_DIR"
echo "999999999999" >"$CAN_TOOLS_RUN_DIR/watchdog.pause"
write_scenario 1 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
write_scenario 2 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
write_scenario 3 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
echo 1002 >"$CAN_TOOLS_FAKE_TIME_FILE"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
echo 1004 >"$CAN_TOOLS_FAKE_TIME_FILE"
out=$("$repo_root/can_watchdog.sh" --once 2>&1)
! grep -q "link set can0" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "pause active must prevent any iface mutation (no TX flush despite stale Δ)"

echo "=== admin down -> left alone ==="
reset_env
echo 1000 >"$CAN_TOOLS_FAKE_TIME_FILE"
echo "STOPPED" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=down" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
write_scenario 1 "can0 0 0 5 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
! grep -q "link set can0" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "admin-down iface must not be touched"

echo "=== CAN_FLUSH_IFACES scoping (R6): can1 not in list, must not be flushed ==="
reset_env
echo 1000 >"$CAN_TOOLS_FAKE_TIME_FILE"
echo "ERROR-PASSIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-PASSIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
for t in 1 2 3; do
    ts=$((999 + t))
    echo "$ts" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$t" "can0 50 50 0 0 3" "can1 50 0 0 0 4"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
done
! grep -q "link set can1" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "can1 is not in default CAN_FLUSH_IFACES (can0) and must never be flushed"
grep -q "link set can0 up" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "sanity: can0 (in CAN_FLUSH_IFACES) should have been flushed under the same stale condition"

echo ""
echo "Observe-only tests: $pass passed, $fail failed"
exit $fail
