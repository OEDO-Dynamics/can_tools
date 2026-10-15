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
fifo_val=0
# H1: each successful busoff recovery re-baselines
# POST_BUSOFF_BASELINE_RXFIFO to whatever rxfifo is AT THAT MOMENT (since
# the iface is still in BUS-OFF every cycle in this test and recovers again
# each time backoff allows it) - so rxfifo must keep climbing monotonically
# across every single write_scenario call, not just jump once and plateau,
# or a later window-expiry check would compare against a baseline already
# equal to the current value and wrongly conclude "fifo did not grow".
for n in 1 2 3; do
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$n" "can0 50 50 $fifo_val 0 3" "can1 50 0 0 0 4"
    all_out+=$("$repo_root/can_watchdog.sh" --once 2>&1)   # recovers (NAPI dead -> rx never moves)
    fifo_val=$((fifo_val + 5))
    # Expire the post-busoff window with rx unchanged (simulated NAPI-dead case).
    t=$((t + 20))  # > WD_STALL_POST_BUSOFF_WINDOW_S(5) and > WD_BUSOFF_QUIET_S(10)
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$n" "can0 50 50 $fifo_val 0 3" "can1 50 0 0 0 4"
    all_out+=$("$repo_root/can_watchdog.sh" --once 2>&1)
    fifo_val=$((fifo_val + 5))
    t=$((t + 1))
done
unbind_content=$(cat "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd/unbind" 2>/dev/null)
cond2=0
{ [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can0" ]] || echo "$all_out" | grep -q "reason=rebind_recovered" || [[ "$unbind_content" == "spi0.0" ]]; } || cond2=1
check $cond2 "3 bus-off recoveries with rx never increasing (NAPI still dead) should eventually force a rebind attempt"

echo ""
echo "=== post-rebind verification window: a quiet bus is treated as success ==="
reset_all
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
t=2000
for n in 1 2 3 4; do
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$n" "can0 100 100 0 0 3" "can1 100 0 $((n * 5)) 0 4"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1   # n=4 completes the rebind
    t=$((t + 1))
done
rv=$(grep -m1 "^REBIND_VERIFY_UNTIL=" "$CAN_TOOLS_RUN_DIR/wd_can1.state" 2>/dev/null | cut -d= -f2)
rvok=0; [[ -n "$rv" && "$rv" != "0" ]] || rvok=1
check $rvok "a successful rebind should open a REBIND_VERIFY_UNTIL window, got '$rv'"
# Keep the bus quiet (Δ all zero) through the whole WD_STALL_VERIFY_S window.
for s in 1 2 3 4 5; do
    t=$((t + 1))
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$((4 + s))" "can0 100 100 0 0 3" "can1 100 0 $((20)) 0 4"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
done
qok=0; [[ ! -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] || qok=1
check $qok "a quiet bus through the whole verification window must be treated as success (no degrade)"
rv2=$(grep -m1 "^REBIND_VERIFY_UNTIL=" "$CAN_TOOLS_RUN_DIR/wd_can1.state" 2>/dev/null | cut -d= -f2)
rv2ok=0; [[ "$rv2" == "0" ]] || rv2ok=1
check $rv2ok "the verification window should have cleared itself once it quietly expired, got '$rv2'"

echo "=== post-rebind verification window: stall evidence inside it fails immediately ==="
reset_all
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
t=3000
for n in 1 2 3 4; do
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$n" "can0 100 100 0 0 3" "can1 100 0 $((n * 5)) 0 4"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1   # n=4 completes the rebind
    t=$((t + 1))
done
# Immediately inject positive evidence of stall (Δrx=0, Δrxfifo>0) within
# the verification window - this should fail right away, not wait for 3
# consecutive cycles like the normal stall detector.
t=$((t + 1))
echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 5 "can0 100 100 0 0 3" "can1 100 0 999 0 4"
out=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out" | grep -q "reason=rebind_verify_failed"
check $? "stall evidence inside the verification window should fail immediately with rebind_verify_failed"
vfd=0; [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] || vfd=1
check $vfd "a failed verification window should mark the iface degraded"

echo "=== ifindex change resets the Δ baseline (no bogus deltas, e.g. after an external rebind) ==="
reset_all
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
echo 4000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 1 "can0 100 100 0 0 3" "can1 5000 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1   # baseline: PREV_RX=5000, PREV_IFINDEX=4
echo 4001 >"$CAN_TOOLS_FAKE_TIME_FILE"
# ifindex changes (e.g. a rebind outside this watchdog's control) AND rx
# resets to a small number - without a baseline reset this would compute a
# huge negative Δ that gets clamped to 0 anyway, but more importantly must
# not accidentally look like a multi-thousand-packet Δrx>0 (which would
# itself be a false "healthy" signal masking a real problem) or corrupt
# STALL_CONSEC accounting.
write_scenario 2 "can0 100 100 0 0 3" "can1 10 0 3 0 9"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
sc_after=$(grep -m1 "^STALL_CONSEC=" "$CAN_TOOLS_RUN_DIR/wd_can1.state" 2>/dev/null | cut -d= -f2)
scok=0; [[ "${sc_after:-0}" == "0" ]] || scok=1
check $scok "an ifindex change must reset the Δ baseline (Δ forced to 0 this cycle), got STALL_CONSEC=$sc_after"
pi_after=$(grep -m1 "^PREV_IFINDEX=" "$CAN_TOOLS_RUN_DIR/wd_can1.state" 2>/dev/null | cut -d= -f2)
piok=0; [[ "$pi_after" == "9" ]] || piok=1
check $piok "the new ifindex should become the baseline for subsequent cycles, got PREV_IFINDEX=$pi_after"

echo "=== log suppression: repeated config_mismatch within WD_LOG_RATE_S carries suppressed=N ==="
reset_all
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=999 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"   # mismatched vs conf (0)
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
t=6000
for n in 1 2 3; do
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$n" "can0 100 100 0 0 3" "can1 100 0 0 0 4"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1   # within WD_LOG_RATE_S: suppressed, not emitted
    t=$((t + 1))
done
t=$((t + 20))   # past WD_LOG_RATE_S(10): the next occurrence emits with the accumulated count
echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 4 "can0 100 100 0 0 3" "can1 100 0 0 0 4"
last_out=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$last_out" | grep -q "reason=config_mismatch_reboot_required.*suppressed="
check $? "a config_mismatch warning repeated within WD_LOG_RATE_S should accumulate suppressed=N on the next emission"

echo ""
echo "Stall tests: $pass passed, $fail failed"
exit $fail
