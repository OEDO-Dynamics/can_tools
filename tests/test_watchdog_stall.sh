#!/bin/bash
# tests/test_watchdog_stall.sh - §1c rx-offload stall detection and the
# unbind/bind/pin/setup rebind sequence, rebind quota, and the "3 bus-off
# recoveries with no rx increase" stall path.

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
cat >"$CAN_TOOLS_CONF" <<'EOF'
CAN_RESTART_MS=0
CAN_BERR_REPORTING=off
CAN_FD=off
WD_STALL_CONSEC=3
WD_REBIND_MAX_PER_HOUR=3
WD_REBIND_TIMEOUT_S=2
WD_STALL_VERIFY_S=5
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

echo "=== 2 stall cycles do not trigger a rebind, the 3rd does ==="
reset_all
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
echo 1000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 1 "can0 100 100 0 0 3" "can1 100 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1   # baseline
echo 1001 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 2 "can0 101 101 0 0 3" "can1 100 0 5 0 4"   # can1: rx frozen, rxfifo +5
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
echo 1002 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 3 "can0 102 102 0 0 3" "can1 100 0 10 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
! grep -q "unbind" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "2 consecutive stall cycles (WD_STALL_CONSEC=3) must not trigger a rebind yet"

echo 1003 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 4 "can0 103 103 0 0 3" "can1 100 0 15 0 4"
out=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out" | grep -q "reason=rebind_recovered"
check $? "the 3rd consecutive stall cycle should trigger and complete a rebind"

echo "--- rebind sequence order (down -> unbind -> bind -> pin/setup) ---"
down_line=$(grep -n "^link set can1 down$" "$CAN_TOOLS_FAKE_DIR/calls.log" | tail -1 | cut -d: -f1)
up_line=$(grep -n "^link set can1 up " "$CAN_TOOLS_FAKE_DIR/calls.log" | tail -1 | cut -d: -f1)
unbind_content=$(cat "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd/unbind" 2>/dev/null)
bind_content=$(cat "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd/bind" 2>/dev/null)
cu=0; [[ "$unbind_content" == "spi1.0" ]] || cu=1
check $cu "unbind should have been written with can1's spidev (spi1.0), got '$unbind_content'"
cb=0; [[ "$bind_content" == "spi1.0" ]] || cb=1
check $cb "bind should have been written with can1's spidev (spi1.0), got '$bind_content'"
cond=0; [[ -n "$down_line" && -n "$up_line" && "$down_line" -lt "$up_line" ]] || cond=1
check $cond "down must happen before the post-rebind setup's up"

echo "--- rebind cap: WD_REBIND_MAX_PER_HOUR exceeded -> degraded instead of rebinding again ---"
rm -f "$CAN_TOOLS_FAKE_DIR/calls.log"
for n in 5 6 7 8 9 10; do
    t=$((1003 + n))
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$n" "can0 $((100+n)) $((100+n)) 0 0 3" "can1 100 0 $((20+n)) 0 4"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
done
cd_=0; [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] || cd_=1
check $cd_ "once the rebind quota (3/h) is exhausted, the iface should go degraded instead of rebinding forever"

echo ""
echo "=== --clear-degraded re-arms normal detection ==="
"$repo_root/can_watchdog.sh" --clear-degraded can1 >/dev/null 2>&1
cc=0; [[ ! -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] || cc=1
check $cc "--clear-degraded should remove the degraded marker"

echo ""
echo "=== busoff-recovery-with-no-rx-increase streak (3x) also triggers a rebind ==="
reset_all
echo "BUS-OFF" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
all_out=""
t=5000
for n in 1 2 3; do
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$n" "can0 50 50 0 0 3" "can1 50 0 0 0 4"
    all_out+=$("$repo_root/can_watchdog.sh" --once 2>&1)   # recovers (NAPI dead -> rx never moves)
    # Expire the post-busoff window with rx unchanged (simulated NAPI-dead case).
    t=$((t + 20))  # > WD_STALL_POST_BUSOFF_WINDOW_S(5) and > WD_BUSOFF_QUIET_S(10)
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$n" "can0 50 50 1 0 3" "can1 50 0 0 0 4"
    all_out+=$("$repo_root/can_watchdog.sh" --once 2>&1)
    t=$((t + 1))
done
unbind_content=$(cat "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd/unbind" 2>/dev/null)
cond2=0
{ [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can0" ]] || echo "$all_out" | grep -q "reason=rebind_recovered" || [[ "$unbind_content" == "spi0.0" ]]; } || cond2=1
check $cond2 "3 bus-off recoveries with rx never increasing (NAPI still dead) should eventually force a rebind attempt"

echo ""
echo "Stall tests: $pass passed, $fail failed"
exit $fail
