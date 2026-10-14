#!/bin/bash

# tests/test_lib_conf.sh - Test configuration and lib functions

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
trap "rm -rf '$tmpdir'" EXIT

passed=0
failed=0

# Test helpers
assert_eq() {
    local got="$1"
    local want="$2"
    local msg="${3:-assertion failed}"
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $msg (got: '$got', want: '$want')"
        (( failed++ ))
        return 1
    fi
    (( passed++ ))
    return 0
}

echo "Testing can_read_conf..."

# Test 1: Empty conf file - should use defaults
touch "$tmpdir/empty.conf"
can_read_conf "$tmpdir/empty.conf"
assert_eq "$CAN_BITRATE" "250000" "Default bitrate"
assert_eq "$CAN_RESTART_MS" "100" "Default restart-ms"
assert_eq "$CAN_FD" "on" "Default FD"

# Test 2: Override some keys
cat > "$tmpdir/custom.conf" << 'EOF'
CAN_BITRATE=500000
CAN_RESTART_MS=0
EOF
can_read_conf "$tmpdir/custom.conf"
assert_eq "$CAN_BITRATE" "500000" "Override bitrate"
assert_eq "$CAN_RESTART_MS" "0" "Override restart-ms"

# Test 3: Unknown key should be ignored
cat > "$tmpdir/unknown.conf" << 'EOF'
UNKNOWN_KEY=value
CAN_BITRATE=250000
EOF
can_read_conf "$tmpdir/unknown.conf"
assert_eq "$CAN_BITRATE" "250000" "Known key"

echo "Testing can_lock/can_unlock..."

export CAN_TOOLS_RUN_DIR="$tmpdir/run"

# Reset lock state
_CAN_LOCK_DEPTH=0

assert_eq "$_CAN_LOCK_DEPTH" "0" "Initial lock depth"

can_lock 5
assert_eq "$_CAN_LOCK_DEPTH" "1" "After first lock"

can_lock 5
assert_eq "$_CAN_LOCK_DEPTH" "2" "After second lock"

can_unlock
assert_eq "$_CAN_LOCK_DEPTH" "1" "After first unlock"

can_unlock
assert_eq "$_CAN_LOCK_DEPTH" "0" "After second unlock"

echo "Testing can_pause/can_unpause..."

export CAN_TOOLS_FAKE_TIME_FILE="$tmpdir/time.txt"
echo "1000" > "$CAN_TOOLS_FAKE_TIME_FILE"

can_pause 1
# Should have written epoch + 60s
deadline=$(cat "$tmpdir/run/watchdog.pause" 2>/dev/null || echo "0")
assert_eq "$deadline" "1060" "Pause deadline"

can_pause_active
ret=$?
assert_eq "$ret" "0" "Pause is active"

# Advance time past deadline
echo "2000" > "$CAN_TOOLS_FAKE_TIME_FILE"
can_pause_active
ret=$?
assert_eq "$ret" "1" "Pause expired"

can_unpause
if [[ -f "$tmpdir/run/watchdog.pause" ]]; then
    echo "FAIL: Pause file should be removed"
    (( failed++ ))
else
    (( passed++ ))
fi

echo ""
echo "Results: $passed passed, $failed failed"
exit $failed
