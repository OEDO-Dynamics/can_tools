#!/bin/bash
# tests/test_watchdog_rtnl.sh - R2: a hung `ip` must not spawn a new D-state
# child every cycle, and 3 consecutive timeouts put every configured iface
# into rtnl_hung degraded mode with no further `ip` calls at all.
#
# can_run_bounded's "don't start a new child while the previous one is still
# alive" guard (CAN_RUN_BOUNDED_PID) is a shell variable scoped to ONE
# process; it only holds across cycles when the SAME long-running watchdog
# process loops internally, not across separate `--once` invocations. So,
# unlike the other test_watchdog_*.sh files, this one runs the real daemon
# loop (no --once) in the background for a bounded, short stretch of real
# time rather than driving ticks with the fake clock.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
wd_pid=""
cleanup() {
    [[ -n "$wd_pid" ]] && kill -9 "$wd_pid" 2>/dev/null
    pkill -9 -f "$repo_root/tests/fakes/ip" 2>/dev/null || true
    pkill -9 -f "$repo_root/can_watchdog.sh" 2>/dev/null || true
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
export CAN_TOOLS_TEST_SPI_MAP="spi0.0:can0 spi1.0:can1"
# No CAN_TOOLS_FAKE_TIME_FILE: this test runs in real time (see header note),
# so can_now() falls back to the real clock.

mkdir -p "$CAN_TOOLS_FAKE_DIR/can0" "$CAN_TOOLS_FAKE_DIR/can1" "$CAN_TOOLS_FAKE_DIR/hang"
cat >"$CAN_TOOLS_CONF" <<'EOF'
CAN_RESTART_MS=0
CAN_BERR_REPORTING=off
CAN_FD=off
WD_LOOP_S=1
WD_RTNL_TIMEOUT_S=1
WD_RTNL_HUNG_CONSEC=3
EOF

echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"
touch "$CAN_TOOLS_FAKE_DIR/hang/ip"

f="$tmpdir/scenario.txt"
cat >"$f" <<'EOF'
1 can0 50 50 0 0 3
1 can1 50 0 0 0 4
EOF
"$repo_root/tests/fakes/mk_sysfs.sh" "$f" 1

# M1: can_watchdog.sh's startup reconciliation now looks for a
# /sys/bus/spi/devices/<spidev>/driver symlink (matching real kernel
# sysfs) to decide an iface is already bound, rather than just checking
# for a visible netdev. tests/fakes/mk_sysfs.sh does not model that
# symlink, so without this both ifaces would look "unbound" every cycle
# and the startup path's own can_setup_iface call (which goes through the
# hung fake ip) would fight the main loop's can_iface_states call for the
# single can_run_bounded slot this test is specifically exercising.
for d in "$CAN_TOOLS_SYSFS_ROOT"/bus/spi/devices/*/; do
    [[ -n "$(ls -A "$d/net" 2>/dev/null)" ]] && ln -sf "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd" "${d}driver"
done

echo "=== real daemon loop: hung ip must not accumulate one D-state child per cycle, and 3 timeouts degrade everything ==="
"$repo_root/can_watchdog.sh" >/dev/null 2>&1 &
wd_pid=$!

# 3 consecutive timeouts x (up to WD_RTNL_TIMEOUT_S wait + WD_LOOP_S sleep)
# plus slack for process start-up and scheduling jitter.
sleep 8

ip_children=$(pgrep -c -f "$repo_root/tests/fakes/ip" 2>/dev/null || echo 0)
cond=0
(( ip_children <= 1 )) || cond=1
check $cond "at most 1 leftover hung ip child should exist at any time, got $ip_children"

d0=0; [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can0" ]] || d0=1
check $d0 "can0 should be degraded (rtnl_hung) after WD_RTNL_HUNG_CONSEC consecutive ip timeouts"
d1=0; [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can1" ]] || d1=1
check $d1 "can1 should be degraded (rtnl_hung) after WD_RTNL_HUNG_CONSEC consecutive ip timeouts"
grep -q "rtnl_hung" "$CAN_TOOLS_RUN_DIR/degraded_can0" 2>/dev/null
check $? "the degraded marker's reason should record rtnl_hung"

echo "=== once rtnl_hung is active, no further ip calls are made at all ==="
: >"$CAN_TOOLS_FAKE_DIR/calls.log"
sleep 3
cond2=0
[[ ! -s "$CAN_TOOLS_FAKE_DIR/calls.log" ]] || cond2=1
check $cond2 "once rtnl_hung is active, ip must not be invoked again (sysfs-only observation), got: $(cat "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null)"

kill -9 "$wd_pid" 2>/dev/null
wd_pid=""

echo ""
echo "RTNL-hung tests: $pass passed, $fail failed"
exit $fail
