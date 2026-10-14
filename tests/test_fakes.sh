#!/bin/bash

tmpdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$tmpdir'" EXIT

pass=0 fail=0

echo "Testing fake ip command..."

export CAN_TOOLS_FAKE_DIR="$tmpdir"

mkdir -p "$tmpdir/can0"
echo "ERROR-ACTIVE" >"$tmpdir/can0/state"
echo "admin=down" >"$tmpdir/can0/config"

# Test: link show
if "$(dirname "$0")"/fakes/ip link show can0 >/dev/null 2>&1; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: fake ip link show can0 should succeed"
fi

# Test: link set down (C3 - local declaration bug)
if "$(dirname "$0")"/fakes/ip link set can0 down >/dev/null 2>&1; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: fake ip link set can0 down should succeed (C3 bug check)"
fi

if grep -q "^admin=down$" "$tmpdir/can0/config"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: fake ip link set down should write admin=down to config"
fi

# Test: link set up with options (C3 - local declaration bug)
if "$(dirname "$0")"/fakes/ip link set can0 up type can bitrate 250000 restart-ms 100 berr-reporting on fd on >/dev/null 2>&1; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: fake ip link set can0 up type can ... should succeed (C3 bug check)"
fi

if grep -q "berr=on" "$tmpdir/can0/config"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: fake ip should write berr=on to config"
fi

if grep -q "fd=on" "$tmpdir/can0/config"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: fake ip should write fd=on to config"
fi

# Test: ip -d link show type can (H4 - real format test)
output=$("$(dirname "$0")"/fakes/ip -d link show type can 2>&1)
if echo "$output" | grep -q "can0"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: fake ip -d link show should output can0"
fi

if echo "$output" | grep -q "state UP mode DEFAULT"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: fake ip -d link show should output 'state UP mode DEFAULT'"
fi

if echo "$output" | grep -q "can <"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: fake ip -d link show should output CAN config line"
fi

# Test: link set name (H4 - add test for rename)
if "$(dirname "$0")"/fakes/ip link set can0 name vcan0 >/dev/null 2>&1; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: fake ip link set ... name should work"
fi

echo "Testing fake mk_sysfs.sh..."

export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"

mkdir -p "$tmpdir/scenario"
echo "0 can0 100 50 10 2 3" >"$tmpdir/scenario/test.txt"

# Test: mk_sysfs.sh with CAN_TOOLS_SYSFS_ROOT set (C3 - local declaration bug)
if "$(dirname "$0")"/fakes/mk_sysfs.sh "$tmpdir/scenario/test.txt" 0 2>/dev/null; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: mk_sysfs.sh should succeed with CAN_TOOLS_SYSFS_ROOT set"
fi

if [[ -f "$tmpdir/sys/class/net/can0/statistics/rx_packets" ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: mk_sysfs.sh should create rx_packets file"
fi

if [[ -d "$tmpdir/sys/bus/spi/drivers/mcp251xfd" ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: mk_sysfs.sh should create driver directory"
fi

if [[ -f "$tmpdir/sys/bus/spi/drivers/mcp251xfd/bind" ]]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: mk_sysfs.sh should create bind file"
fi

# Test: mk_sysfs.sh without CAN_TOOLS_SYSFS_ROOT set (H5 - safety check)
unset CAN_TOOLS_SYSFS_ROOT
if ! "$(dirname "$0")"/fakes/mk_sysfs.sh "$tmpdir/scenario/test.txt" 0 2>/dev/null; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: mk_sysfs.sh should fail without CAN_TOOLS_SYSFS_ROOT"
fi

echo ""
echo "Fake tests: $pass passed, $fail failed"
exit $fail
