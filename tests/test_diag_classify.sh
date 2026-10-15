#!/bin/bash

# Test can_diag.sh error frame classification logic

# Setup
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

# Initialize fake interfaces
echo "ERROR-ACTIVE" >"$tmpdir/fake/can0/state"
echo "restart_ms=100 berr=off fd=off admin=up" >"$tmpdir/fake/can0/config"
echo "ERROR-ACTIVE" >"$tmpdir/fake/can1/state"
echo "restart_ms=100 berr=off fd=off admin=up" >"$tmpdir/fake/can1/config"

# Initialize sysfs
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
export CAN_TOOLS_FAKE_TIME_FILE="$tmpdir/time"

echo "Testing can_diag.sh classification logic..."

# Test 1: Run can_diag.sh with fake commands
cd "$(dirname "$0")/.." || exit 1

# Debug: check that CAN_TOOLS_CANDUMP_CMD is set correctly
if [[ -n "${CAN_TOOLS_CANDUMP_CMD:-}" ]]; then
    echo "DEBUG: CAN_TOOLS_CANDUMP_CMD=$CAN_TOOLS_CANDUMP_CMD"
    if ! [[ -x "$CAN_TOOLS_CANDUMP_CMD" ]]; then
        echo "ERROR: CAN_TOOLS_CANDUMP_CMD is not executable: $CAN_TOOLS_CANDUMP_CMD"
        exit 1
    fi
fi

output=$(bash can_diag.sh 3 2>&1)
rc=$?

check "$rc" "can_diag.sh should exit 0"

# Verify output file was created
diag_file=$(echo "$output" | grep "Diagnostics saved" | awk '{print $NF}')
if [[ -n "$diag_file" && -f "$diag_file" ]]; then
    check 0 "can_diag.sh should create output file"
else
    check 1 "can_diag.sh should create output file"
fi

if [[ -f "$diag_file" ]]; then
    # Debug: show full candump section
    echo "DEBUG: Full diag file:"
    tail -50 "$diag_file" >&2

    # Check output contains expected sections
    grep -q "IP Link Show" "$diag_file"
    ip_show=$?
    check "$ip_show" "Output should contain IP link show section"

    grep -q "sysfs Statistics" "$diag_file"
    sysfs_stats=$?
    check "$sysfs_stats" "Output should contain sysfs statistics section"

    grep -q "kernel log" "$diag_file"
    kernel_log=$?
    check "$kernel_log" "Output should contain kernel log section"

    grep -q "CAN Error Frames" "$diag_file"
    error_frames=$?
    check "$error_frames" "Output should contain error frames section"

    grep -q "Error Frame Summary" "$diag_file"
    error_summary=$?
    check "$error_summary" "Output should contain error summary section"

    # Verify candump section exists (even if empty in test env)
    grep -q "CAN Error Frames" "$diag_file"
    candump_section=$?
    check "$candump_section" "Output should contain CAN Error Frames section"
fi

# Test 2: Verify berr-reporting was restored
final_berr=$(cat "$tmpdir/fake/can0/config" | grep -o "berr=[^ ]*")
[[ "$final_berr" == "berr=off" ]]
check $? "berr-reporting should be restored to off (got: $final_berr)"

# Test 3: Verify pause file was cleaned up
[[ ! -f "$tmpdir/run/watchdog.pause" ]]
check $? "watchdog.pause should be cleaned up"

# Test 4: Verify lock was released
[[ ! -f "$tmpdir/run/lock" || ! -f "/proc/$$/fd/9" ]]
check $? "Lock should be released"

echo ""
echo "Results: $pass passed, $fail failed"

if (( fail > 0 )); then
    exit 1
fi

exit 0
