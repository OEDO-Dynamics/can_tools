#!/bin/bash

# Tests for the fakes themselves (tests/fakes/ip, tests/fakes/mk_sysfs.sh),
# per the §5a contract. These must be correct on their own, independent of
# the lib, since PR-B (and A1's own lib tests) rely on them being faithful.

tmpdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$tmpdir'" EXIT

pass=0 fail=0
check() {
    if [[ "$1" == "0" ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: $2"
    fi
}

fakes_dir="$(cd "$(dirname "$0")/fakes" && pwd)"

echo "Testing fake ip command..."

export CAN_TOOLS_FAKE_DIR="$tmpdir/fake1"
mkdir -p "$CAN_TOOLS_FAKE_DIR/can0"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=100 berr=off fd=off admin=down" >"$CAN_TOOLS_FAKE_DIR/can0/config"

"$fakes_dir/ip" link show can0 >/dev/null 2>&1
check $? "fake ip link show can0 should succeed when iface exists"

"$fakes_dir/ip" link show can9 >/dev/null 2>&1
if [[ $? -eq 1 ]]; then check 0 "fake ip link show should fail (rc=1) for a nonexistent iface"; else check 1 "fake ip link show should fail (rc=1) for a nonexistent iface"; fi

# down must flip admin to down while PRESERVING restart_ms/berr/fd (the
# previous implementation silently left admin=up in the 1-line format - a
# real bug that would make "admin down" scenarios untestable).
echo "restart_ms=100 berr=on fd=on admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
"$fakes_dir/ip" link set can0 down >/dev/null 2>&1
check $? "fake ip link set can0 down should succeed"
cfg=$(cat "$CAN_TOOLS_FAKE_DIR/can0/config")
if [[ "$cfg" == "restart_ms=100 berr=on fd=on admin=down" ]]; then check 0 "fake ip down should flip admin to down and keep restart_ms/berr/fd (got: $cfg)"; else check 1 "fake ip down should flip admin to down and keep restart_ms/berr/fd (got: $cfg)"; fi

# up with explicit args must overwrite restart_ms/berr/fd and set admin=up
"$fakes_dir/ip" link set can0 up type can bitrate 250000 restart-ms 0 berr-reporting off fd off >/dev/null 2>&1
check $? "fake ip link set can0 up ... should succeed"
cfg=$(cat "$CAN_TOOLS_FAKE_DIR/can0/config")
if [[ "$cfg" == "restart_ms=0 berr=off fd=off admin=up" ]]; then check 0 "fake ip up should record restart_ms/berr/fd/admin from args (got: $cfg)"; else check 1 "fake ip up should record restart_ms/berr/fd/admin from args (got: $cfg)"; fi

"$fakes_dir/ip" link set can0 up type can bitrate 250000 restart-ms 100 berr-reporting on fd on >/dev/null 2>&1
cfg=$(cat "$CAN_TOOLS_FAKE_DIR/can0/config")
if [[ "$cfg" == "restart_ms=100 berr=on fd=on admin=up" ]]; then check 0 "fake ip up with fd on/berr on should record them (got: $cfg)"; else check 1 "fake ip up with fd on/berr on should record them (got: $cfg)"; fi

# -d link show type can: real-machine-shaped 2-line output (§2b example)
output=$("$fakes_dir/ip" -d link show type can 2>&1)
echo "$output" | grep -q "can0"
check $? "fake ip -d link show should mention can0"
echo "$output" | grep -q "state UP mode DEFAULT"
check $? "fake ip -d link show iface line should include operstate 'state UP' (to test it is NOT the CAN state)"
echo "$output" | grep -q "^    can <.*> state ERROR-ACTIVE"
check $? "fake ip -d link show should emit the CAN state line with ctrlmode and STATE"

# rename
mkdir -p "$CAN_TOOLS_FAKE_DIR/can1"
echo "restart_ms=0 berr=off fd=off admin=down" >"$CAN_TOOLS_FAKE_DIR/can1/config"
"$fakes_dir/ip" link set can1 name vcan1 >/dev/null 2>&1
check $? "fake ip link set ... name should succeed when target name is free"
if [[ -d "$CAN_TOOLS_FAKE_DIR/vcan1" && ! -d "$CAN_TOOLS_FAKE_DIR/can1" ]]; then check 0 "fake ip rename should move the iface directory"; else check 1 "fake ip rename should move the iface directory"; fi

# rename with sysfs (低-3): fake ip should update sysfs when CAN_TOOLS_SYSFS_ROOT is set
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/fake_sysfs_rename"
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake_rename"
mkdir -p "$CAN_TOOLS_FAKE_DIR/test_can0"
mkdir -p "$CAN_TOOLS_SYSFS_ROOT/class/net/test_can0/statistics"
mkdir -p "$CAN_TOOLS_SYSFS_ROOT/bus/spi/devices/spi0.0/net"
echo "restart_ms=0 berr=off fd=off admin=down" >"$CAN_TOOLS_FAKE_DIR/test_can0/config"
ln -sf "$CAN_TOOLS_SYSFS_ROOT/bus/spi/devices/spi0.0" "$CAN_TOOLS_SYSFS_ROOT/class/net/test_can0/device"
ln -sf "$CAN_TOOLS_SYSFS_ROOT/class/net/test_can0" "$CAN_TOOLS_SYSFS_ROOT/bus/spi/devices/spi0.0/net/test_can0"
"$fakes_dir/ip" link set test_can0 name test_renamed >/dev/null 2>&1
check $? "fake ip rename should succeed and update sysfs"
if [[ -d "$CAN_TOOLS_SYSFS_ROOT/class/net/test_renamed" && ! -d "$CAN_TOOLS_SYSFS_ROOT/class/net/test_can0" ]]; then check 0 "fake ip rename should move iface in /sys/class/net (低-3)"; else check 1 "fake ip rename should move iface in /sys/class/net (低-3)"; fi
if [[ -L "$CAN_TOOLS_SYSFS_ROOT/bus/spi/devices/spi0.0/net/test_renamed" ]]; then check 0 "fake ip rename should update spidev net symlink (低-3)"; else check 1 "fake ip rename should update spidev net symlink (低-3)"; fi
unset CAN_TOOLS_SYSFS_ROOT

# rename collision
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake1"
mkdir -p "$CAN_TOOLS_FAKE_DIR/can2" "$CAN_TOOLS_FAKE_DIR/eth0"
"$fakes_dir/ip" link set can2 name eth0 >/dev/null 2>&1
if [[ $? -eq 1 ]]; then check 0 "fake ip rename should fail (rc=1) when the target name is already in use"; else check 1 "fake ip rename should fail (rc=1) when the target name is already in use"; fi
if [[ -d "$CAN_TOOLS_FAKE_DIR/can2" ]]; then check 0 "fake ip rename should leave the source iface alone on collision"; else check 1 "fake ip rename should leave the source iface alone on collision"; fi

# fail/ip and hang/ip
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake2"
mkdir -p "$CAN_TOOLS_FAKE_DIR/fail"
touch "$CAN_TOOLS_FAKE_DIR/fail/ip"
"$fakes_dir/ip" link show can0 >/dev/null 2>&1
if [[ $? -eq 1 ]]; then check 0 "fake ip with fail/ip present should exit 1 regardless of args"; else check 1 "fake ip with fail/ip present should exit 1 regardless of args"; fi
grep -q "link show can0" "$CAN_TOOLS_FAKE_DIR/calls.log"
check $? "fake ip should log the call even when failing"

export CAN_TOOLS_FAKE_DIR="$tmpdir/fake3"
mkdir -p "$CAN_TOOLS_FAKE_DIR/hang"
touch "$CAN_TOOLS_FAKE_DIR/hang/ip"
timeout 2 "$fakes_dir/ip" link show can0 >/dev/null 2>&1
if [[ $? -eq 124 ]]; then check 0 "fake ip with hang/ip present should never exit on its own"; else check 1 "fake ip with hang/ip present should never exit on its own"; fi
pkill -9 -f "$fakes_dir/ip" 2>/dev/null || true

echo "Testing fake mk_sysfs.sh..."

export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
mkdir -p "$tmpdir/scenario"
cat >"$tmpdir/scenario/test.txt" <<EOF
0 can0 100 50 10 2 3
1 can0 110 55 10 2 3
EOF

"$fakes_dir/mk_sysfs.sh" "$tmpdir/scenario/test.txt" 0 2>/dev/null
check $? "mk_sysfs.sh should succeed with CAN_TOOLS_SYSFS_ROOT set"
if [[ -f "$tmpdir/sys/class/net/can0/statistics/rx_packets" ]]; then check 0 "mk_sysfs.sh should create rx_packets file"; else check 1 "mk_sysfs.sh should create rx_packets file"; fi
if [[ "$(cat "$tmpdir/sys/class/net/can0/statistics/rx_packets")" == "100" ]]; then check 0 "mk_sysfs.sh tick 0 rx_packets should be 100"; else check 1 "mk_sysfs.sh tick 0 rx_packets should be 100"; fi
if [[ -d "$tmpdir/sys/bus/spi/drivers/mcp251xfd" ]]; then check 0 "mk_sysfs.sh should create driver directory"; else check 1 "mk_sysfs.sh should create driver directory"; fi
if [[ -f "$tmpdir/sys/bus/spi/drivers/mcp251xfd/bind" ]]; then check 0 "mk_sysfs.sh should create bind file"; else check 1 "mk_sysfs.sh should create bind file"; fi
if [[ -L "$tmpdir/sys/class/net/can0/device" ]]; then check 0 "mk_sysfs.sh should link can0 to its spidev (default map spi0.0:can0)"; else check 1 "mk_sysfs.sh should link can0 to its spidev (default map spi0.0:can0)"; fi

# N-M4: writes to unbind (simulating the watchdog's unbind step) must survive
# into the next tick's mk_sysfs.sh call, not be wiped by a blanket rm -rf.
echo "spi0.0" >"$tmpdir/sys/bus/spi/drivers/mcp251xfd/unbind"
"$fakes_dir/mk_sysfs.sh" "$tmpdir/scenario/test.txt" 1 2>/dev/null
if [[ "$(cat "$tmpdir/sys/bus/spi/drivers/mcp251xfd/unbind")" == "spi0.0" ]]; then check 0 "mk_sysfs.sh must not erase a prior tick's write to unbind (N-M4)"; else check 1 "mk_sysfs.sh must not erase a prior tick's write to unbind (N-M4)"; fi
if [[ "$(cat "$tmpdir/sys/class/net/can0/statistics/rx_packets")" == "110" ]]; then check 0 "mk_sysfs.sh tick 1 should update rx_packets to 110"; else check 1 "mk_sysfs.sh tick 1 should update rx_packets to 110"; fi

# N-M4: spidev mapping must be configurable (to model rebind onto a
# different spidev / name swap), not hardcoded to can0->spi0.0, can1->spi1.0.
rm -rf "$tmpdir/sys2"
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys2"
export CAN_TOOLS_TEST_SPI_MAP="spi1.0:can0"
cat >"$tmpdir/scenario/swap.txt" <<EOF
0 can0 1 1 0 0 9
EOF
"$fakes_dir/mk_sysfs.sh" "$tmpdir/scenario/swap.txt" 0 2>/dev/null
target=$(readlink -f "$tmpdir/sys2/class/net/can0/device" 2>/dev/null)
if [[ "${target##*/}" == "spi1.0" ]]; then check 0 "mk_sysfs.sh should honor CAN_TOOLS_TEST_SPI_MAP for the spidev<->iface link (got: $target)"; else check 1 "mk_sysfs.sh should honor CAN_TOOLS_TEST_SPI_MAP for the spidev<->iface link (got: $target)"; fi
unset CAN_TOOLS_TEST_SPI_MAP

# Remove interface when it disappears from a tick (低-3): mk_sysfs.sh should
# clean up /sys/class/net/<if> and spidev links when an iface no longer appears
# in the scenario, simulating unbind scenarios.
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys_remove"
mkdir -p "$tmpdir/scenario_remove"
cat >"$tmpdir/scenario_remove/remove_test.txt" <<'ENDSCENARIO'
0 can0 1 1 0 0 3
1 can1 2 2 0 0 4
2 can1 3 3 0 0 4
ENDSCENARIO

# Tick 0: can0 present
"$fakes_dir/mk_sysfs.sh" "$tmpdir/scenario_remove/remove_test.txt" 0 2>/dev/null
if [[ -d "$tmpdir/sys_remove/class/net/can0" ]]; then check 0 "mk_sysfs.sh tick 0 should create can0"; else check 1 "mk_sysfs.sh tick 0 should create can0"; fi

# Tick 1: can0 disappears, can1 appears
"$fakes_dir/mk_sysfs.sh" "$tmpdir/scenario_remove/remove_test.txt" 1 2>/dev/null
if [[ ! -d "$tmpdir/sys_remove/class/net/can0" ]]; then check 0 "mk_sysfs.sh tick 1 should remove can0 (not in scenario, 低-3)"; else check 1 "mk_sysfs.sh tick 1 should remove can0 (not in scenario, 低-3)"; fi
if [[ -d "$tmpdir/sys_remove/class/net/can1" ]]; then check 0 "mk_sysfs.sh tick 1 should create can1"; else check 1 "mk_sysfs.sh tick 1 should create can1"; fi

# Tick 2: can1 persists
"$fakes_dir/mk_sysfs.sh" "$tmpdir/scenario_remove/remove_test.txt" 2 2>/dev/null
if [[ ! -d "$tmpdir/sys_remove/class/net/can0" ]]; then check 0 "mk_sysfs.sh tick 2 can0 should still be gone"; else check 1 "mk_sysfs.sh tick 2 can0 should still be gone"; fi
if [[ -d "$tmpdir/sys_remove/class/net/can1" ]]; then check 0 "mk_sysfs.sh tick 2 can1 should persist"; else check 1 "mk_sysfs.sh tick 2 can1 should persist"; fi
unset CAN_TOOLS_SYSFS_ROOT

# H5 safety check
unset CAN_TOOLS_SYSFS_ROOT
"$fakes_dir/mk_sysfs.sh" "$tmpdir/scenario/test.txt" 0 2>/dev/null
if [[ $? -ne 0 ]]; then check 0 "mk_sysfs.sh should fail without CAN_TOOLS_SYSFS_ROOT set"; else check 1 "mk_sysfs.sh should fail without CAN_TOOLS_SYSFS_ROOT set"; fi

CAN_TOOLS_SYSFS_ROOT=/sys "$fakes_dir/mk_sysfs.sh" "$tmpdir/scenario/test.txt" 0 2>/dev/null
if [[ $? -ne 0 ]]; then check 0 "mk_sysfs.sh should refuse to run against the real /sys"; else check 1 "mk_sysfs.sh should refuse to run against the real /sys"; fi

echo ""
echo "Fake tests: $pass passed, $fail failed"
exit $fail
