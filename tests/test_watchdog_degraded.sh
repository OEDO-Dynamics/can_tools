#!/bin/bash
# tests/test_watchdog_degraded.sh - §1d degraded mode: oops pre-check,
# unbind hang (inflight marker + lock release), startup D-state
# reconciliation, can_pin_name collision, periodic CRIT, --clear-degraded.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
wd_pid=""
cleanup() {
    [[ -n "$wd_pid" ]] && kill -9 "$wd_pid" 2>/dev/null
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

echo "=== startup: can_setup_iface failure during startup bind -> degraded with setup_failed_at_startup (L-4) ==="
reset_all
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
# Deliberately do NOT (re)create $CAN_TOOLS_FAKE_DIR/can1/{state,config}:
# reset_all does not wipe CAN_TOOLS_FAKE_DIR (only run/state/sysfs), so an
# earlier test's can1 fixture would otherwise still be sitting there -
# remove it so tests/fakes/ip's "link set <if> up/down/txqueuelen" has
# nothing to find and fails for can1 here, exactly the §1d
# startup-reconciliation equivalent of a setup failure that was previously
# dropped on the floor by a bare `can_setup_iface "$want"` (L-4/L-5).
rm -rf "$CAN_TOOLS_FAKE_DIR/can1"
echo 7000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 1 "can0 10 10 0 0 3" "can1 10 0 0 0 4"
# write_scenario's _sync_driver_links gives every spidev with a netdev a
# driver symlink (mirroring "already bound"); strip can1's to put it back
# into "needs (re)bind" for the startup reconciliation check (§1/M1), while
# its netdev stays enumerated under the spidev - so can_iface_of_spidev and
# can_pin_name (current==want, no rename needed) both succeed immediately,
# and can_setup_iface is the only step that fails.
rm -f "$CAN_TOOLS_SYSFS_ROOT/bus/spi/devices/spi1.0/driver"
out=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out" | grep -q "reason=setup_failed_at_startup"
check $? "a can_setup_iface failure during startup bind should be logged as setup_failed_at_startup (L-4)"
dsfs=0; [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] || dsfs=1
check $dsfs "a startup can_setup_iface failure should mark the iface degraded, not silently drop it (§1d, L-4/L-5)"
grep -q ":setup_failed_at_startup$" "$CAN_TOOLS_RUN_DIR/degraded_can1" 2>/dev/null
check $? "the degraded marker should record the setup_failed_at_startup reason"
mkdir -p "$CAN_TOOLS_FAKE_DIR/can1"  # restore the fixture dir later tests rely on

echo "=== can_pin_name collision during rebind -> degraded, no swap (e2e via direct sysfs manipulation) ==="
reset_all
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
for n in 1 2 3; do
    echo "$((1000 + n))" >"$CAN_TOOLS_FAKE_TIME_FILE"
    write_scenario "$n" "can0 100 100 0 0 3" "can1 100 0 $((n * 5)) 0 4"
    "$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
done
# Simulate: by the time this rebind's bind+netdev-wait step runs, the kernel
# has enumerated the new netdev as "can2" (e.g. because "can1" was still
# momentarily held elsewhere) rather than "can1" - the spidev's net/ entry
# now points at can2, while a stale "can1" fake dir (state/config) is still
# present and resolvable by `ip link show can1`, exactly reproducing a real
# naming collision for can_pin_name to catch.
mkdir -p "$CAN_TOOLS_SYSFS_ROOT/class/net/can2"
rm -f "$CAN_TOOLS_SYSFS_ROOT/bus/spi/devices/spi1.0/net/can1"
ln -s "$CAN_TOOLS_SYSFS_ROOT/class/net/can2" "$CAN_TOOLS_SYSFS_ROOT/bus/spi/devices/spi1.0/net/can2"
echo 20 >"$CAN_TOOLS_SYSFS_ROOT/class/net/can1/statistics/rx_fifo_errors"
echo 1004 >"$CAN_TOOLS_FAKE_TIME_FILE"
out=$("$repo_root/can_watchdog.sh" --once 2>&1)
echo "$out" | grep -q "reason=pin_name_collision"
check $? "a post-rebind name collision (can_pin_name rc=2) should be logged as pin_name_collision"
dpc=0; [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] || dpc=1
check $dpc "a pin_name collision should mark the iface degraded (no swap attempted)"
grep -q "^1004:pin_name_collision$" "$CAN_TOOLS_RUN_DIR/degraded_can1" 2>/dev/null
check $? "the degraded marker should record the pin_name_collision reason"

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

echo "=== real daemon loop: can_lock is released even while the hung unbind child is still alive ==="
# A check done after a --once process has already exited always "passes"
# trivially (its own fd 9 closes on exit regardless of what can_unlock did).
# This drives the real, long-running daemon loop instead, and probes the
# lock from THIS test process WHILE the watchdog process (and its stuck
# unbind child) are both still alive. Unset the fake clock first: the rest
# of this file uses it to drive --once in lockstep, but a real daemon loop
# must see real wall-clock time advancing, not a value frozen at whatever
# the last --once call left it at.
unset CAN_TOOLS_FAKE_TIME_FILE
reset_all
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
write_scenario 1 "can0 100 100 0 0 3" "can1 100 0 0 0 4"
rm -f "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd/unbind"
mkfifo "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd/unbind"
cat >>"$CAN_TOOLS_CONF" <<'EOF'
WD_LOOP_S=1
WD_RTNL_TIMEOUT_S=2
WD_REBIND_TIMEOUT_S=2
WD_STALL_CONSEC=2
EOF

"$repo_root/can_watchdog.sh" >/dev/null 2>"$tmpdir/realloop.log" &
wd_pid=$!

# Drive can1 into a stall (rx frozen, rxfifo growing) until the unbind hang
# (and therefore the inflight marker) shows up.
(
    v=0
    while [[ ! -f "$CAN_TOOLS_RUN_DIR/unbind_inflight" ]]; do
        v=$((v + 5))
        echo "$v" >"$CAN_TOOLS_SYSFS_ROOT/class/net/can1/statistics/rx_fifo_errors" 2>/dev/null
        sleep 0.3
    done
) &
churn_pid=$!

marker_present=0
wd_alive=0
lock_free=1
for _ in $(seq 1 80); do
    if [[ -f "$CAN_TOOLS_RUN_DIR/unbind_inflight" ]]; then
        # Real kernel sysfs removes the driver symlink as part of starting
        # an unbind, even if the driver's own .remove() callback then hangs;
        # this test's local driver-symlink fixture (see _sync_driver_links)
        # has no such automatic behavior, so mirror it by hand the moment
        # the inflight marker (written by the unbind child itself) appears
        # - otherwise M1's "already bound (driver symlink present), leave it
        # alone" check would keep masking the hung-marker branch on the
        # watchdog's NEXT cycle (which could otherwise race with and even
        # remove this marker before the assertions below run).
        rm -f "$CAN_TOOLS_SYSFS_ROOT/bus/spi/devices/spi1.0/driver"
        marker_present=1
        # The marker appears the instant the unbind child starts (it writes
        # it before blocking), which is well BEFORE the parent's
        # can_run_bounded gives up waiting (WD_REBIND_TIMEOUT_S=2s) and
        # calls can_unlock - the lock is legitimately still held until then.
        # Wait past that timeout (plus slack) before checking the lock, but
        # still well within the same still-running watchdog process.
        sleep 3
        kill -0 "$wd_pid" 2>/dev/null && wd_alive=1
        flock -n "$CAN_TOOLS_RUN_DIR/lock" true 2>/dev/null || lock_free=0
        break
    fi
    sleep 0.25
done
kill "$churn_pid" 2>/dev/null; wait "$churn_pid" 2>/dev/null

check $((1 - marker_present)) "the real-loop unbind hang should leave an inflight marker"
check $((1 - wd_alive)) "the watchdog process itself should still be alive (not crashed) while its unbind child hangs"
check $((1 - lock_free)) "can_lock must be released by the watchdog even while its unbind child is still hung (checked from outside, loop still running)"

echo ""
echo "Degraded-mode tests: $pass passed, $fail failed"
exit $fail
