#!/bin/bash

# Unit tests for can_diag.sh's classification tables, sourcing the script
# directly and calling diag_classify_line()/diag_render_summary() on known
# input, with no fakes and no full capture pipeline involved. This isolates
# the exact bit tables from Issue #9's 2nd review:
#   H1 - every CAN_ERR_PROT_LOC_* (data[3]) code, straight from
#        /usr/include/linux/can/error.h, not just the ones a prior test
#        happened to exercise.
#   M1 - CAN_ERR_CNT is 0x200 (not 0x1000000), and data[6]/data[7] (TX/RX
#        error counters) are tracked as a per-iface high-water mark.
#   L1 - a CAN-FD line (`id##data`, double '#') must be excluded, not crash.
#   L2 - CAN_ERR_TRX_* (data[4]) combo faults (CANH + CANL at once).

pass=0 fail=0

check() {
    if [[ "$1" == "0" ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: $2"
    fi
}

repo_dir=$(cd "$(dirname "$0")/.." && pwd) || exit 1
# shellcheck source=/dev/null
source "$repo_dir/can_diag.sh"
# can_diag.sh only sources can_tools_lib.bash inside its own execution guard
# (main(), never reached when merely sourced like this); the L-3 regression
# guard below needs the lib's real CAN_RESTART_MS default, so source it here.
# shellcheck source=/dev/null
source "$repo_dir/can_tools_lib.bash"

mk_line() {
    # mk_line <iface> <can_id_hex> <data_hex (<=16 hex chars, zero-padded)>
    printf '(1700000000.0) %s %s#%s' "$1" "$2" "$3"
}

# --- H1: every CAN_ERR_PROT_LOC_* code from the header (data[3]), each on
# its own PROT-class frame (can_id class bits = 0x08 only), decimal value ->
# expected name.
declare -A loc_cases=(
    [0]="UNSPEC" [2]="ID28_21" [3]="SOF" [4]="SRTR" [5]="IDE" [6]="ID20_18"
    [7]="ID17_13" [8]="CRC_SEQ" [9]="RES0" [10]="DATA" [11]="DLC" [12]="RTR"
    [13]="RES1" [14]="ID04_00" [15]="ID12_05" [18]="INTERM" [24]="CRC_DEL"
    [25]="ACK" [26]="EOF" [27]="ACK_DEL"
)
for loc_dec in "${!loc_cases[@]}"; do
    error_counts=()
    loc_hex=$(printf '%02X' "$loc_dec")
    # data[2]=0x01 (BIT, so the PROT byte is never 0) data[3]=<loc_hex>
    line=$(mk_line can0 20000008 "000001${loc_hex}00000000")
    diag_classify_line "$line"
    want="can0|loc|${loc_cases[$loc_dec]}"
    if (( loc_dec == 0 )); then
        # data[3] == 0 is explicitly skipped (§ "only when ... data[3] != 0")
        if [[ -z "${error_counts[$want]:-}" ]]; then check 0 "LOC 0x00 (UNSPEC) must NOT be recorded (data[3]==0 is skipped)"
        else check 1 "LOC 0x00 (UNSPEC) must NOT be recorded (data[3]==0 is skipped)"
        fi
    else
        if [[ "${error_counts[$want]:-}" == "1" ]]; then check 0 "data[3]=0x$(printf '%02X' "$loc_dec") should classify as loc=${loc_cases[$loc_dec]} (H1) (got: ${!error_counts[*]})"
        else check 1 "data[3]=0x$(printf '%02X' "$loc_dec") should classify as loc=${loc_cases[$loc_dec]} (H1) (got: ${!error_counts[*]})"
        fi
    fi
done

# A location code the header does NOT define must fall back to a readable
# UNKNOWN_0xNN, not silently misclassify as something else.
error_counts=()
diag_classify_line "$(mk_line can0 20000008 "0000010100000000")" # loc byte 0x01, undefined
if [[ "${error_counts[can0|loc|UNKNOWN_0x01]:-}" == "1" ]]; then check 0 "an undefined LOC byte should render as UNKNOWN_0xNN, not a wrong name"
else check 1 "an undefined LOC byte should render as UNKNOWN_0xNN, not a wrong name"
fi

# --- L1: a CAN-FD line (double '#') must be rejected cleanly, not crash and
# not get counted as anything.
error_counts=()
diag_classify_line "(1700000000.0) can0 00000123##1AABBCCDDEEFF0011"
rc=$?
if [[ $rc -ne 0 ]]; then check 0 "an FD-format line (##) must not match (rc should be non-zero)"
else check 1 "an FD-format line (##) must not match (rc should be non-zero)"
fi
(( ${#error_counts[@]} == 0 ))
check $? "an FD-format line must not add any classification entries"

# A plain, non-FD, non-error data frame mixed into the stream (regression
# guard alongside the FD case): must also be excluded.
error_counts=()
diag_classify_line "(1700000000.0) can0 18DA31F9#0011223344556677"
rc=$?
if [[ $rc -ne 0 ]]; then check 0 "an ordinary (non-error) data frame must not match"
else check 1 "an ordinary (non-error) data frame must not match"
fi

# --- L2: CAN_ERR_TRX_* combo faults - CANH and CANL set at the same time.
error_counts=()
diag_classify_line "$(mk_line can0 20000010 "0000000044000000")" # data[4]=0x44
if [[ "${error_counts[can0|trx|CANH_NO_WIRE+CANL_NO_WIRE]:-}" == "1" ]]; then check 0 "data[4]=0x44 should decode as the CANH_NO_WIRE+CANL_NO_WIRE combo (L2)"
else check 1 "data[4]=0x44 should decode as the CANH_NO_WIRE+CANL_NO_WIRE combo (L2)"
fi

error_counts=()
diag_classify_line "$(mk_line can0 20000010 "0000000087000000")" # data[4]=0x87
if [[ "${error_counts[can0|trx|CANH_SHORT_TO_GND+CANL_SHORT_TO_CANH]:-}" == "1" ]]; then check 0 "data[4]=0x87 should decode as CANH_SHORT_TO_GND+CANL_SHORT_TO_CANH (L2)"
else check 1 "data[4]=0x87 should decode as CANH_SHORT_TO_GND+CANL_SHORT_TO_CANH (L2)"
fi

error_counts=()
diag_classify_line "$(mk_line can0 20000010 "0000000007000000")" # CANH only
if [[ "${error_counts[can0|trx|CANH_SHORT_TO_GND]:-}" == "1" ]]; then check 0 "a CANH-only TRX byte must not grow a spurious '+' suffix"
else check 1 "a CANH-only TRX byte must not grow a spurious '+' suffix"
fi

error_counts=()
diag_classify_line "$(mk_line can0 20000010 "0000000000000000")" # data[4]=0x00
if [[ "${error_counts[can0|trx|UNSPEC]:-}" == "1" ]]; then check 0 "data[4]=0x00 should classify as trx=UNSPEC"
else check 1 "data[4]=0x00 should classify as trx=UNSPEC"
fi

# --- M1: CAN_ERR_CNT is 0x200, and data[6]/data[7] (TEC/REC) are tracked as
# a per-iface maximum, not just a frame count.
error_counts=()
_cnt_tec_max=()
_cnt_rec_max=()
diag_classify_line "$(mk_line can0 20000200 "0000000000000A05")" # tec=0x0A rec=0x05
diag_classify_line "$(mk_line can0 20000200 "0000000000001405")" # tec=0x14 rec=0x05 (new tec max)
diag_classify_line "$(mk_line can0 20000200 "000000000000140A")" # rec=0x0A (new rec max)
if [[ "${error_counts[can0|class|CNT]:-}" == "3" ]]; then check 0 "CAN_ERR_CNT (0x200) should be counted 3 times for 3 CNT frames (M1)"
else check 1 "CAN_ERR_CNT (0x200) should be counted 3 times for 3 CNT frames (M1)"
fi
if [[ "${_cnt_tec_max[can0]:-}" == "20" ]]; then check 0 "TEC high-water mark should be 20 (0x14) across the 3 CNT frames (M1)"
else check 1 "TEC high-water mark should be 20 (0x14) across the 3 CNT frames (M1)"
fi
if [[ "${_cnt_rec_max[can0]:-}" == "10" ]]; then check 0 "REC high-water mark should be 10 (0x0A) across the 3 CNT frames (M1)"
else check 1 "REC high-water mark should be 10 (0x0A) across the 3 CNT frames (M1)"
fi

summary=$(diag_render_summary)
echo "$summary" | grep -qF "can0 cnt tec_max=20 rec_max=10"
check $? "diag_render_summary should report the CNT high-water marks (M1)"

# the old (wrong) 0x1000000 mask must NOT be what triggers CNT.
error_counts=()
_cnt_tec_max=()
_cnt_rec_max=()
diag_classify_line "$(mk_line can0 21000000 "0000000000000000")" # bit 24 (0x1000000) set, 0x200 NOT set
if [[ -z "${error_counts[can0|class|CNT]:-}" ]]; then check 0 "bit 0x1000000 alone (the old wrong CNT mask) must NOT be classified as CNT"
else check 1 "bit 0x1000000 alone (the old wrong CNT mask) must NOT be classified as CNT"
fi

# --- L-3: _diag_resolve_restart_ms() picks the original restart-ms when
# known, and falls back to the lib's CAN_RESTART_MS (reflecting conf) -
# never a hardcoded guess - when it could not be read, flagging the
# fallback via _DIAG_RESTART_MS_FELL_BACK.
_diag_resolve_restart_ms "0" "50"
if [[ "$_DIAG_RESTART_MS_RESULT" == "0" && "$_DIAG_RESTART_MS_FELL_BACK" == "0" ]]; then
    check 0 "a known original restart-ms (0) should be used as-is, not replaced by CAN_RESTART_MS"
else
    check 1 "a known original restart-ms (0) should be used as-is, not replaced by CAN_RESTART_MS (got result=$_DIAG_RESTART_MS_RESULT fell_back=$_DIAG_RESTART_MS_FELL_BACK)"
fi

_diag_resolve_restart_ms "" "50"
if [[ "$_DIAG_RESTART_MS_RESULT" == "50" && "$_DIAG_RESTART_MS_FELL_BACK" == "1" ]]; then
    check 0 "an unreadable original restart-ms should fall back to the lib's CAN_RESTART_MS (L-3), not a hardcoded 100"
else
    check 1 "an unreadable original restart-ms should fall back to the lib's CAN_RESTART_MS (L-3), not a hardcoded 100 (got result=$_DIAG_RESTART_MS_RESULT fell_back=$_DIAG_RESTART_MS_FELL_BACK)"
fi

# Regression guard for the exact bug: with the lib's actual default
# (CAN_RESTART_MS=0, declared in can_tools_lib.bash), an unreadable
# original must resolve to 0, never the old hardcoded 100.
_diag_resolve_restart_ms "" "$CAN_RESTART_MS"
if [[ "$_DIAG_RESTART_MS_RESULT" == "0" ]]; then
    check 0 "with the lib's default CAN_RESTART_MS=0, an unreadable original must resolve to 0, not 100"
else
    check 1 "with the lib's default CAN_RESTART_MS=0, an unreadable original must resolve to 0, not 100 (got: $_DIAG_RESTART_MS_RESULT)"
fi

echo ""
echo "Classify-unit tests: $pass passed, $fail failed"

if (( fail > 0 )); then
    exit 1
fi

exit 0
