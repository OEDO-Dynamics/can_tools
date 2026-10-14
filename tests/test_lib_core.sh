#!/bin/bash

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$tmpdir'" EXIT

pass=0 fail=0

# ========== can_read_conf tests ==========
echo "Testing can_read_conf..."
export CAN_TOOLS_CONF="$tmpdir/empty.conf"
touch "$tmpdir/empty.conf"
can_read_conf
if [[ -n "$CAN_BITRATE" ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_read_conf empty sets defaults"
fi

# Test: invalid berr value (H3)
cat >"$tmpdir/invalid.conf" <<EOF
CAN_BERR_REPORTING=maybe
EOF
can_read_conf "$tmpdir/invalid.conf"
if [[ "$CAN_BERR_REPORTING" == "off" ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_read_conf invalid berr should default to off, got $CAN_BERR_REPORTING"
fi

# Test: quotes removed (H3)
cat >"$tmpdir/quoted.conf" <<EOF
CAN_IFACES="can0 can1"
EOF
can_read_conf "$tmpdir/quoted.conf"
if [[ "$CAN_IFACES" == "can0 can1" && "$CAN_IFACES" != *'"'* ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_read_conf quotes not removed, got: $CAN_IFACES"
fi

# Test: reset defaults between reads
export CAN_TOOLS_CONF="$tmpdir/empty.conf"
can_read_conf
old_bitrate="$CAN_BITRATE"
touch "$tmpdir/missing.conf"
can_read_conf "$tmpdir/missing.conf"
if [[ "$CAN_BITRATE" == "$old_bitrate" ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_read_conf should reset defaults before reading"
fi

# ========== can_lock/can_unlock tests (reentrant) ==========
echo "Testing can_lock/can_unlock..."
export CAN_TOOLS_RUN_DIR="$tmpdir/run"
_CAN_LOCK_DEPTH=0

can_lock 5
if [[ $_CAN_LOCK_DEPTH -eq 1 ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_lock depth should be 1, got $_CAN_LOCK_DEPTH"
fi

can_lock 5
if [[ $_CAN_LOCK_DEPTH -eq 2 ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_lock depth should be 2 (reentrant), got $_CAN_LOCK_DEPTH"
fi

can_unlock
if [[ $_CAN_LOCK_DEPTH -eq 1 ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_unlock depth should be 1, got $_CAN_LOCK_DEPTH"
fi

can_unlock
if [[ $_CAN_LOCK_DEPTH -eq 0 ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_unlock depth should be 0, got $_CAN_LOCK_DEPTH"
fi

# Test: lock contention from another process (H4)
can_lock 5
# Try to lock from another process (should fail)
timeout 1 bash -c "flock -w 1 9 2>/dev/null" 9>"$tmpdir/run/lock" 2>/dev/null
if [[ $? -ne 0 ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: lock should prevent other processes from acquiring it"
fi
can_unlock

# ========== can_run_bounded tests ==========
echo "Testing can_run_bounded..."

# Test: fd 9 closure (H4)
can_run_bounded 1 bash -c "[[ ! -f /proc/self/fd/9 ]]" >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_run_bounded should not pass fd 9 to child"
fi

# Test: timeout works correctly (C1 - requires fixing bc issue)
# This test verifies that bounded call doesn't timeout immediately
can_run_bounded 2 sleep 0.1 >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_run_bounded 2 sleep 0.1 should succeed"
fi

# Test: child exits with error
can_run_bounded 1 bash -c "exit 5" >/dev/null 2>&1
if [[ $? -eq 5 ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_run_bounded should return child exit code, got $?"
fi

# ========== can_pin_name tests (N-C1: use tests/fakes/ip) ==========
echo "Testing can_pin_name..."

# Set up sysfs for can_pin_name
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sysfs_pin"
export CAN_TOOLS_IP_CMD="$repo_root/tests/fakes/ip"

# Create fake dir structure
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake_pin"
mkdir -p "$tmpdir/sysfs_pin/bus/spi/devices/spi0.0/net/can0"
mkdir -p "$tmpdir/fake_pin"

# Test: success (name already correct)
can_pin_name "spi0.0" "can0" >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_pin_name should succeed when name matches"
fi

# Test: empty name is available, should rename successfully (N-C1)
# can7 doesn't exist in fake_pin, so rename should succeed
rm -f "$tmpdir/fake_pin/calls.log"
mkdir -p "$tmpdir/sysfs_pin2/bus/spi/devices/spi0.0/net/can0"
# Create can0 directory in fake_pin for the fake ip to use
mkdir -p "$tmpdir/fake_pin/can0"
echo "admin=down" >"$tmpdir/fake_pin/can0/config"
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sysfs_pin2"
can_pin_name "spi0.0" "can7" >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    # Verify rename was called
    if grep -q "name can7" "$tmpdir/fake_pin/calls.log"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: can_pin_name should call rename for can7"
    fi
else
    fail=$((fail+1))
    echo "FAIL: can_pin_name should succeed when name is available"
fi

# Test: collision (name already taken, should return 2, no rename) (N-C1)
# First, ensure fake_pin has both eth0 (already exists) and can0
mkdir -p "$tmpdir/fake_pin/eth0"
echo "admin=down" >"$tmpdir/fake_pin/eth0/config"
mkdir -p "$tmpdir/fake_pin/can0"
echo "admin=down" >"$tmpdir/fake_pin/can0/config"
rm -f "$tmpdir/fake_pin/calls.log"
mkdir -p "$tmpdir/sysfs_pin3/bus/spi/devices/spi0.0/net/can0"
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sysfs_pin3"

can_pin_name "spi0.0" "eth0" >/dev/null 2>&1
if [[ $? -eq 2 ]]; then
    # Verify rename was NOT called
    if ! grep -q "link set can0 name eth0" "$tmpdir/fake_pin/calls.log"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: can_pin_name should not call rename on collision"
    fi
else
    fail=$((fail+1))
    echo "FAIL: can_pin_name should return 2 on collision, got $?"
fi

# ========== can_pause tests ==========
echo "Testing can_pause..."
export CAN_TOOLS_FAKE_TIME_FILE="$tmpdir/time.txt"
echo "1000" >"$CAN_TOOLS_FAKE_TIME_FILE"

can_pause 1
local_deadline=$(cat "$tmpdir/run/watchdog.pause" 2>/dev/null)
if [[ "$local_deadline" == "1060" ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_pause deadline should be 1060, got $local_deadline"
fi

if can_pause_active 2>/dev/null; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_pause_active should return true within deadline"
fi

echo "2000" >"$CAN_TOOLS_FAKE_TIME_FILE"
if ! can_pause_active 2>/dev/null; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_pause_active should return false after deadline"
fi

echo ""
echo "Core tests: $pass passed, $fail failed"
exit $fail
