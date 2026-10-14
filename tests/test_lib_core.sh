#!/bin/bash

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
trap "rm -rf '$tmpdir'" EXIT

passed=0 failed=0

echo "Testing can_read_conf..."
export CAN_TOOLS_CONF="$tmpdir/empty.conf"
touch "$tmpdir/empty.conf"
can_read_conf
[[ -n "$CAN_BITRATE" ]] && ((passed++)) || ((failed++))

# Test: invalid berr value
cat >"$tmpdir/invalid.conf" <<EOF
CAN_BERR_REPORTING=maybe
EOF
can_read_conf "$tmpdir/invalid.conf"
[[ "$CAN_BERR_REPORTING" == "off" ]] && ((passed++)) || ((failed++))

# Test: quotes removed
cat >"$tmpdir/quoted.conf" <<EOF
CAN_IFACES="can0 can1"
EOF
can_read_conf "$tmpdir/quoted.conf"
if [[ "$CAN_IFACES" == "can0 can1" && "$CAN_IFACES" != *'"'* ]]; then
    ((passed++))
else
    ((failed++))
fi

echo "Testing can_lock/can_unlock..."
export CAN_TOOLS_RUN_DIR="$tmpdir/run"
_CAN_LOCK_DEPTH=0

can_lock 5
[[ $_CAN_LOCK_DEPTH -eq 1 ]] && ((passed++)) || ((failed++))

can_lock 5
[[ $_CAN_LOCK_DEPTH -eq 2 ]] && ((passed++)) || ((failed++))

can_unlock
[[ $_CAN_LOCK_DEPTH -eq 1 ]] && ((passed++)) || ((failed++))

can_unlock
[[ $_CAN_LOCK_DEPTH -eq 0 ]] && ((passed++)) || ((failed++))

echo "Testing fd 9 closure..."
can_run_bounded 1 bash -c "[[ ! -f /proc/self/fd/9 ]]" 2>&1 >/dev/null
[[ $? -eq 0 ]] && ((passed++)) || ((failed++))

echo "Testing can_pause..."
export CAN_TOOLS_FAKE_TIME_FILE="$tmpdir/time.txt"
echo "1000" >"$CAN_TOOLS_FAKE_TIME_FILE"

can_pause 1
local_deadline=$(cat "$tmpdir/run/watchdog.pause" 2>/dev/null)
[[ "$local_deadline" == "1060" ]] && ((passed++)) || ((failed++))

can_pause_active && ((passed++)) || ((failed++))

echo "2000" >"$CAN_TOOLS_FAKE_TIME_FILE"
! can_pause_active && ((passed++)) || ((failed++))

echo ""
echo "Core tests: $passed passed, $failed failed"
exit $failed
