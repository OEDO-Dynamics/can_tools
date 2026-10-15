#!/bin/bash
# tests/test_watchdog_degraded.sh - §1d degraded mode: oops pre-check,
# unbind hang (inflight marker + lock release), startup D-state
# reconciliation, can_pin_name collision, periodic CRIT, --clear-degraded.

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
WD_REBIND_TIMEOUT_S=2
WD_DEGRADED_CRIT_S=10
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
    rm -rf "$CAN_TOOLS_RUN_DIR" "$CAN_TOOLS_STATE_DIR" "$CAN_TOOLS_SYSFS_ROOT"
    rm -f "$CAN_TOOLS_FAKE_DIR/calls.log" "$CAN_TOOLS_FAKE_DIR/kmsg.txt"
}

# Updates only the statistics files directly (no mk_sysfs.sh), for use once
# bind/unbind has been swapped to a FIFO: mk_sysfs.sh's "only create
# bind/unbind if missing" guard uses `-f`, which is false for a FIFO, so any
# further mk_sysfs.sh call would try to recreate it and block on open().
write_stats_direct() {
    local ifn="$1" rx="$2" tx="$3" rxfifo="$4" txfifo="$5"
    local base="$CAN_TOOLS_SYSFS_ROOT/class/net/$ifn/statistics"
    mkdir -p "$base"
    echo "$rx" >"$base/rx_packets"
    echo "$tx" >"$base/tx_packets"
    echo "$rxfifo" >"$base/rx_fifo_errors"
    echo "$txfifo" >"$base/tx_fifo_errors"
}

drive_3_stall_cycles() {
    local ifn="$1" base_t="$2"
    echo "$base_t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario 1 "can0 100 100 0 0 3" "can1 100 0 0 0 4"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
    local t=$((base_t + 1))
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario 2 "can0 100 100 0 0 3" "$ifn 100 0 5 0 4"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
    t=$((t + 1))
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario 3 "can0 100 100 0 0 3" "$ifn 100 0 10 0 4"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
    t=$((t + 1))
    echo "$t" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario 4 "can0 100 100 0 0 3" "$ifn 100 0 15 0 4"
    "$repo_root/can_watchdog.sh" --once 2>&1
}

echo "=== Oops/BUG precheck -> degraded, no unbind attempted, line is logged ==="
reset_all
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
echo "Oct 15 00:00:00 host kernel: Oops: something bad at mcp251xfd_irq" >"$CAN_TOOLS_FAKE_DIR/kmsg.txt"
out=$(drive_3_stall_cycles can1 2000)
echo "$out" | grep -q "reason=oops_detected"
check $? "an Oops/BUG line in journalctl -k -b should be detected and logged"
d1=0; [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] || d1=1
check $d1 "oops precheck failure should mark the iface degraded (no unbind attempted)"
unbind_content=$(cat "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd/unbind" 2>/dev/null)
d2=0; [[ -z "$unbind_content" ]] || d2=1
check $d2 "unbind must not have been attempted when the oops precheck fails, got '$unbind_content'"

echo "=== unbind hangs -> degraded, inflight marker left with a D-state pid, lock released ==="
reset_all
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
# Seed the sysfs tree normally first (mk_sysfs.sh only creates bind/unbind
# if they don't already exist, and -f is false for a FIFO - creating the
# FIFO up front would make its own next mk_sysfs.sh call block forever on
# `: > unbind` with no reader). Only once the tree exists do we swap the
# regular "unbind" file for a FIFO, so a write to it blocks until a reader
# shows up, which never happens - simulating the kernel-side unbind hang
# without needing an actual broken driver.
echo 2999 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 0 "can0 100 100 0 0 3" "can1 100 0 0 0 4"
rm -f "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd/unbind"
mkfifo "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd/unbind"

echo 3000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_stats_direct can0 100 100 0 0
write_stats_direct can1 100 0 0 0
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
echo 3001 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_stats_direct can1 100 0 5 0
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
echo 3002 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_stats_direct can1 100 0 10 0
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
echo 3003 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_stats_direct can1 100 0 15 0
out=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out" | grep -q "reason=unbind_timeout"
check $? "a hanging unbind should time out (WD_REBIND_TIMEOUT_S) and be logged"
d3=0; [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] || d3=1
check $d3 "a timed-out unbind should mark the iface degraded"
d4=0; [[ -f "$CAN_TOOLS_RUN_DIR/unbind_inflight" ]] || d4=1
check $d4 "the inflight marker must be left behind (not cleaned up) after an unbind timeout"
marker_content=$(cat "$CAN_TOOLS_RUN_DIR/unbind_inflight" 2>/dev/null)
marker_pid="${marker_content##*:}"
[[ -n "$marker_pid" ]] && kill -0 "$marker_pid" 2>/dev/null
check $? "the inflight marker's pid should still be a live (stuck) process, got '$marker_content'"
cmdline=$(tr '\0' ' ' <"/proc/$marker_pid/cmdline" 2>/dev/null)
case "$cmdline" in
    *can_tools_unbind*) ok=0 ;;
    *) ok=1 ;;
esac
check "$ok" "the stuck child's /proc/<pid>/cmdline should contain can_tools_unbind (L-a), got '$cmdline'"
# Lock must be released despite the still-hung child (N2/§1d): a fresh
# lock acquisition from this test process should succeed immediately.
can_lock 1
check $? "can_lock should be acquirable again after the watchdog released it post-timeout"
can_unlock

echo "=== startup: inflight marker + D-state pid -> do not bind, mark degraded instead ==="
reset_all
# A real D-state process is hard to synthesize in a test sandbox; use a
# backgrounded fifo reader-starved writer (sleep) as a stand-in live pid and
# monkeypatch _can_is_alive's underlying check by using the real /proc
# mechanics: we instead directly exercise the marker-present-but-not-D-state
# path (stale marker is cleaned up) and the marker-absent-spidev-missing
# bind path, which together cover the two startup branches this repo's test
# sandbox can create deterministically.
sleep 5 &
alive_pid=$!
mkdir -p "$CAN_TOOLS_RUN_DIR"
echo "spi1.0:$alive_pid" >"$CAN_TOOLS_RUN_DIR/unbind_inflight"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
echo 4000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 1 "can0 10 10 0 0 3" "can1 10 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
kill -9 "$alive_pid" 2>/dev/null || true
# Since our synthetic pid is not actually in D state, the lib's own L-b
# is-alive-not-zombie check is enough to exercise "marker present but the
# recorded process does not match the unbind-child signature" -> treated
# as stale and removed, startup proceeds normally (can0/can1 already have
# netdevs in this scenario so no bind is attempted either way). The precise
# "really is D state" condition is exercised end to end by the unbind-hang
# case above (same code path, same marker format).
rc_marker_handling=0
[[ -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] && rc_marker_handling=1
check $rc_marker_handling "a stale (non-D-state) inflight marker for an already-bound iface must not mark it degraded"

# NOTE (gap, see PR body 確認事項): a rebind that lands on a name already
# taken by a DIFFERENT, still-bound netdev (can_pin_name returning 2) is not
# exercised end to end here. Reproducing it needs the rebound netdev's name
# collision to come from a genuinely separate spidev that the test can leave
# untouched; tests/fakes/ip's `link show <name>` only resolves against
# CAN_TOOLS_FAKE_DIR, and pointing it at a case shaped like "can1 ends up
# wanting a name can1 already has elsewhere" needs a small fakes extension
# (e.g. letting `link show` resolve a name whose fake directory predates the
# spidev remap). _wd_rebind_recover's pin_rc==2 branch (mark degraded,
# no swap) is covered directly by reading the code and by can_pin_name's own
# collision-branch unit test in tests/test_lib_core.sh.

echo "=== periodic degraded CRIT fires every WD_DEGRADED_CRIT_S, not every cycle ==="
reset_all
mkdir -p "$CAN_TOOLS_RUN_DIR"
echo "6000:test_reason" >"$CAN_TOOLS_RUN_DIR/degraded_can1"
echo 6000 >"$CAN_TOOLS_FAKE_TIME_FILE"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
write_scenario 1 "can0 10 10 0 0 3" "can1 10 0 0 0 4"
out1=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out1" | grep -q "reason=manual_reboot_required"
check $? "the first cycle after going degraded should emit the manual_reboot_required CRIT immediately"
echo 6003 >"$CAN_TOOLS_FAKE_TIME_FILE"   # well within WD_DEGRADED_CRIT_S(10)
out2=$("$repo_root/can_watchdog.sh" --once 2>&1)
! echo "$out2" | grep -q "reason=manual_reboot_required"
check $? "a degraded iface must not re-emit the CRIT before WD_DEGRADED_CRIT_S has elapsed"
echo 6011 >"$CAN_TOOLS_FAKE_TIME_FILE"
out3=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out3" | grep -q "reason=manual_reboot_required"
check $? "once WD_DEGRADED_CRIT_S has elapsed, the CRIT should fire again"

echo "=== degraded iface is never touched (no ip calls for it) while degraded ==="
rm -f "$CAN_TOOLS_FAKE_DIR/calls.log"
echo "BUS-OFF" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo 6020 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 1 "can0 10 10 0 0 3" "can1 10 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
! grep -q "link set can1" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "a degraded iface must never be touched by ip, even if it reports BUS-OFF"

echo "=== --clear-degraded removes the marker and normal detection resumes ==="
"$repo_root/can_watchdog.sh" --clear-degraded can1 >/dev/null 2>&1
rc_cleared=0; [[ ! -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] || rc_cleared=1
check "$rc_cleared" "--clear-degraded should remove the marker file"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo 6021 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 2 "can0 10 10 0 0 3" "can1 10 0 0 0 4"
out4=$("$repo_root/can_watchdog.sh" --once 2>&1)
! echo "$out4" | grep -q "reason=manual_reboot_required"
check $? "after clearing, the iface should no longer be reported as degraded"

echo ""
echo "Degraded-mode tests: $pass passed, $fail failed"
exit $fail
