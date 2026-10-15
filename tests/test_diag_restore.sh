#!/bin/bash

# Test can_diag.sh properly restores settings on exit (via trap)

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

# Set up test environment
export CAN_TOOLS_RUN_DIR="$tmpdir/run"
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"

fakes_path=$(cd "$(dirname "$0")/fakes" && pwd) || exit 1
export CAN_TOOLS_IP_CMD="$fakes_path/ip"
export CAN_TOOLS_CANDUMP_CMD="$fakes_path/candump"
export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"

mkdir -p "$tmpdir/run" "$tmpdir/fake" "$tmpdir/fake/can0" "$tmpdir/fake/can1"

# Initialize fake interfaces with known state
echo "ERROR-ACTIVE" >"$tmpdir/fake/can0/state"
echo "restart_ms=100 berr=off fd=on admin=up" >"$tmpdir/fake/can0/config"
echo "ERROR-ACTIVE" >"$tmpdir/fake/can1/state"
echo "restart_ms=100 berr=off fd=on admin=up" >"$tmpdir/fake/can1/config"

# Initialize minimal sysfs for candump
mkdir -p "$tmpdir/sys/class/net/can0/statistics"
mkdir -p "$tmpdir/sys/class/net/can1/statistics"
echo "100" >"$tmpdir/sys/class/net/can0/statistics/rx_packets"
echo "50" >"$tmpdir/sys/class/net/can0/statistics/tx_packets"
echo "0" >"$tmpdir/sys/class/net/can0/statistics/rx_fifo_errors"
echo "0" >"$tmpdir/sys/class/net/can0/statistics/tx_fifo_errors"
echo "100" >"$tmpdir/sys/class/net/can1/statistics/rx_packets"
echo "0" >"$tmpdir/sys/class/net/can1/statistics/tx_packets"
echo "0" >"$tmpdir/sys/class/net/can1/statistics/rx_fifo_errors"
echo "0" >"$tmpdir/sys/class/net/can1/statistics/tx_fifo_errors"

export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"

echo "Testing can_diag.sh restore on normal exit..."

cd "$(dirname "$0")/.." || exit 1

# Run can_diag.sh (should complete normally and restore settings)
bash can_diag.sh 3 >/dev/null 2>&1
rc=$?

check "$rc" "can_diag.sh should exit cleanly"

# Verify berr-reporting was set during operation (ip link set ... up did it)
# Then restored to original state (off)
final_can0_config=$(cat "$tmpdir/fake/can0/config")
final_can1_config=$(cat "$tmpdir/fake/can1/config")

# Config should have berr=off after cleanup (trap restores it)
echo "$final_can0_config" | grep -q "berr=off"
check $? "can0 berr-reporting should be restored to off (got: $final_can0_config)"

echo "$final_can1_config" | grep -q "berr=off"
check $? "can1 berr-reporting should be restored to off (got: $final_can1_config)"

# Verify pause file is cleaned up
if [[ ! -f "$tmpdir/run/watchdog.pause" ]]; then
    check 0 "watchdog.pause should be cleaned up on exit"
else
    check 1 "watchdog.pause should be cleaned up on exit"
fi

# Test error path: simulate signal/early exit
echo "Testing can_diag.sh restore on error exit..."

# Reset state
echo "restart_ms=100 berr=off fd=on admin=up" >"$tmpdir/fake/can0/config"
echo "restart_ms=100 berr=off fd=on admin=up" >"$tmpdir/fake/can1/config"
rm -f "$tmpdir/run/watchdog.pause"

# Create a scenario that will cause can_diag.sh to exit early
# (e.g., pass an invalid duration)
bash can_diag.sh "invalid_duration" >/dev/null 2>&1
rc=$?

# Should have exited with error
if [[ $rc -ne 0 ]]; then
    check 0 "can_diag.sh should exit with error on invalid input"
else
    check 1 "can_diag.sh should exit with error on invalid input"
fi

# Verify cleanup still happened
if [[ ! -f "$tmpdir/run/watchdog.pause" ]]; then
    check 0 "watchdog.pause should be cleaned up even on error exit"
else
    check 1 "watchdog.pause should be cleaned up even on error exit"
fi

# berr should still be off (restored by trap)
final_can0_config=$(cat "$tmpdir/fake/can0/config")
if echo "$final_can0_config" | grep -q "berr=off"; then
    check 0 "berr should be restored to off even on error (got: $final_can0_config)"
else
    check 1 "berr should be restored to off even on error (got: $final_can0_config)"
fi

echo ""
echo "Results: $pass passed, $fail failed"

if (( fail > 0 )); then
    exit 1
fi

exit 0
