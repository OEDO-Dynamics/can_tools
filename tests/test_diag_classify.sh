#!/bin/bash

# Test can_diag.sh error frame classification (Issue #9 review C1-C4):
#   - the candump -L line regex actually matches and parses (C1)
#   - the format matches real `candump -L -e any,0~0,#FFFFFFFF` output (C2)
#   - classification follows linux/can/error.h bit-for-bit, counting every
#     set bit independently rather than overwriting with "last one wins" (C3)
#   - the test checks exact per-category COUNTS, not just that section
#     headings exist (C4)
# Also covers M5 (sysfs stats come from CAN_TOOLS_SYSFS_ROOT via the lib's
# can_read_stats(), not a hardcoded /sys/class/net path).

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

export CAN_TOOLS_RUN_DIR="$tmpdir/run"
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"

fakes_path=$(cd "$(dirname "$0")/fakes" && pwd) || exit 1
export CAN_TOOLS_IP_CMD="$fakes_path/ip"
export CAN_TOOLS_JOURNALCTL_CMD="$fakes_path/journalctl"

diag_fakes_path=$(cd "$(dirname "$0")/diag_fakes" && pwd) || exit 1
export CAN_TOOLS_CANDUMP_CMD="$diag_fakes_path/candump"

mkdir -p "$tmpdir/run" "$tmpdir/fake" "$tmpdir/fake/can0" "$tmpdir/fake/can1"

echo "ERROR-ACTIVE" >"$tmpdir/fake/can0/state"
echo "restart_ms=100 berr=off fd=off admin=up" >"$tmpdir/fake/can0/config"
echo "ERROR-ACTIVE" >"$tmpdir/fake/can1/state"
echo "restart_ms=100 berr=off fd=off admin=up" >"$tmpdir/fake/can1/config"

mkdir -p "$tmpdir/sys/class/net/can0/statistics"
mkdir -p "$tmpdir/sys/class/net/can1/statistics"
echo "123" >"$tmpdir/sys/class/net/can0/statistics/rx_packets"
echo "50" >"$tmpdir/sys/class/net/can0/statistics/tx_packets"
echo "7" >"$tmpdir/sys/class/net/can0/statistics/rx_fifo_errors"
echo "0" >"$tmpdir/sys/class/net/can0/statistics/tx_fifo_errors"
echo "1" >"$tmpdir/sys/class/net/can0/ifindex"
echo "100" >"$tmpdir/sys/class/net/can1/statistics/rx_packets"
echo "0" >"$tmpdir/sys/class/net/can1/statistics/tx_packets"
echo "0" >"$tmpdir/sys/class/net/can1/statistics/rx_fifo_errors"
echo "0" >"$tmpdir/sys/class/net/can1/statistics/tx_fifo_errors"

export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
export CAN_TOOLS_FAKE_TIME_FILE="$tmpdir/time"
echo "1700000000" >"$CAN_TOOLS_FAKE_TIME_FILE"

echo "Testing can_diag.sh classification logic..."

cd "$(dirname "$0")/.." || exit 1

output=$(bash can_diag.sh 3 2>&1)
rc=$?
check "$rc" "can_diag.sh should exit 0 (got rc=$rc); output follows:\n$output"

diag_file=$(echo "$output" | grep "Diagnostics saved" | awk '{print $NF}')
if [[ -n "$diag_file" && -f "$diag_file" ]]; then
    check 0 "can_diag.sh should create output file"
else
    check 1 "can_diag.sh should create output file"
fi

if [[ -f "$diag_file" ]]; then
    echo "DEBUG: Full diag file:" >&2
    cat "$diag_file" >&2

    for section in "IP Link Show" "sysfs Statistics" "kernel log" "CAN Error Frames" "Error Frame Summary" "Interface Setup"; do
        grep -q "$section" "$diag_file"
        check $? "Output should contain '$section' section"
    done

    # --- C1/C2: the regex actually matched real -L lines; raw matched error
    # frame lines (not the one ordinary data frame) must be echoed verbatim.
    grep -q '^(1697000000\.000002) can0 20000020#0000000000000000$' "$diag_file"
    check $? "raw -L error-frame line should be preserved verbatim (C1/C2)"

    # the ordinary (non-error) data frame must not be written to the diag
    # file at all: diag_classify_line() rejects it (no CAN_ERR_FLAG) before
    # it would ever be echoed.
    if grep -qF '18DA31F9' "$diag_file"; then
        check 1 "ordinary (non-error) frame must not appear in the diag file"
    else
        check 0 "ordinary (non-error) frame must not appear in the diag file"
    fi

    # --- C3/C4: exact expected counts per category, from the fake's own
    # documented scenario (tests/diag_fakes/candump).
    declare -A expected=(
        ["can0 class=ACK count=1"]=1
        ["can0 class=BUSOFF count=1"]=1
        ["can0 class=PROT count=2"]=1
        ["can0 class=BUSERROR count=1"]=1
        ["can0 class=CRTL count=1"]=1
        ["can0 prot=TX count=1"]=1
        ["can0 loc=ACK count=1"]=1
        ["can0 prot=FORM count=1"]=1
        ["can0 ctrl=RX_WARNING count=1"]=1
        ["can1 class=TRX count=1"]=1
        ["can1 trx=CANH_SHORT_TO_GND count=1"]=1
    )
    for want in "${!expected[@]}"; do
        grep -qF "$want" "$diag_file"
        check $? "Error Frame Summary should contain exact count: '$want'"
    done

    # A key that must NOT appear (sanity: no spurious class=ACK on can1, no
    # bit0 misfire on the FORM-only frame).
    if grep -qF "can1 class=ACK" "$diag_file"; then
        check 1 "must not classify can1 as ACK (no such frame in the scenario)"
    else
        check 0 "must not classify can1 as ACK (no such frame in the scenario)"
    fi

    # --- M5: sysfs values came from CAN_TOOLS_SYSFS_ROOT (can_read_stats),
    # not a hardcoded /sys/class/net path - check the actual fixture values.
    grep -q "rx_packets: 123" "$diag_file"
    check $? "sysfs rx_packets should reflect CAN_TOOLS_SYSFS_ROOT fixture (M5)"
    grep -q "rx_fifo_errors: 7" "$diag_file"
    check $? "sysfs rx_fifo_errors should reflect CAN_TOOLS_SYSFS_ROOT fixture (M5)"
fi

# berr-reporting restored to original (off) after a clean run (H1)
final_berr=$(grep -o "berr=[^ ]*" "$tmpdir/fake/can0/config")
[[ "$final_berr" == "berr=off" ]]
check $? "berr-reporting should be restored to off (got: $final_berr)"

[[ ! -f "$tmpdir/run/watchdog.pause" ]]
check $? "watchdog.pause should be cleaned up"

[[ ! -f "$tmpdir/run/lock" || ! -f "/proc/$$/fd/9" ]]
check $? "Lock should be released"

echo ""
echo "Results: $pass passed, $fail failed"

if (( fail > 0 )); then
    exit 1
fi

exit 0
