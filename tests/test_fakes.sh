#!/bin/bash

tmpdir=$(mktemp -d)
trap "rm -rf '$tmpdir'" EXIT

passed=0 failed=0

echo "Testing fake ip command..."

export CAN_TOOLS_FAKE_DIR="$tmpdir"

mkdir -p "$tmpdir/can0"
echo "ERROR-ACTIVE" >"$tmpdir/can0/state"
echo "admin=down" >"$tmpdir/can0/config"

$(dirname "$0")/fakes/ip link show can0 >/dev/null 2>&1 && ((passed++)) || ((failed++))

$(dirname "$0")/fakes/ip link set can0 down >/dev/null 2>&1 && ((passed++)) || ((failed++))
grep -q "^admin=down$" "$tmpdir/can0/config" && ((passed++)) || ((failed++))

$(dirname "$0")/fakes/ip link set can0 up type can bitrate 250000 restart-ms 100 berr-reporting on fd on >/dev/null 2>&1 && ((passed++)) || ((failed++))
grep -q "^berr=on$" "$tmpdir/can0/config" && ((passed++)) || ((failed++))
grep -q "^fd=on$" "$tmpdir/can0/config" && ((passed++)) || ((failed++))

output=$($(dirname "$0")/fakes/ip -d link show type can 2>&1)
echo "$output" | grep -q "can0" && ((passed++)) || ((failed++))
echo "$output" | grep -q "state UP mode DEFAULT" && ((passed++)) || ((failed++))
echo "$output" | grep -q "can <" && ((passed++)) || ((failed++))

echo "Testing fake mk_sysfs.sh..."

export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"

mkdir -p "$tmpdir/scenario"
echo "0 can0 100 50 10 2 3" >"$tmpdir/scenario/test.txt"
$(dirname "$0")/fakes/mk_sysfs.sh "$tmpdir/scenario/test.txt" 0 2>/dev/null

[[ -f "$tmpdir/sys/class/net/can0/statistics/rx_packets" ]] && ((passed++)) || ((failed++))
[[ -d "$tmpdir/sys/bus/spi/drivers/mcp251xfd" ]] && ((passed++)) || ((failed++))
[[ -f "$tmpdir/sys/bus/spi/drivers/mcp251xfd/bind" ]] && ((passed++)) || ((failed++))

echo ""
echo "Fake tests: $passed passed, $failed failed"
exit $failed
