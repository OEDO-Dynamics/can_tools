#!/bin/bash

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

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

echo "Testing can_setup_iface..."

export CAN_TOOLS_IP_CMD="$repo_root/tests/fakes/ip"
export CAN_TOOLS_RUN_DIR="$tmpdir/run"
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sys"
mkdir -p "$CAN_TOOLS_FAKE_DIR/can0"
echo "restart_ms=100 berr=off fd=off admin=down" >"$CAN_TOOLS_FAKE_DIR/can0/config"

# --- fd on: must always emit BOTH berr-reporting and fd explicitly (the
# statute from the maintainers: "berr-reporting と fd は常に on|off を明示する"),
# since the kernel only clears the ctrlmode bits actually named in the mask -
# an omitted "fd off" leaves a previously-on FD iface stuck on FD. ---
rm -f "$CAN_TOOLS_FAKE_DIR/calls.log"
CAN_BITRATE=250000 CAN_RESTART_MS=100 CAN_BERR_REPORTING=on CAN_FD=on CAN_DBITRATE=2000000 CAN_TXQUEUELEN=10 \
    can_setup_iface can0 >/dev/null 2>&1
check $? "can_setup_iface (fd on) should succeed"
up_line=$(grep "link set can0 up" "$CAN_TOOLS_FAKE_DIR/calls.log")
if [[ "$up_line" == *"berr-reporting on"* ]]; then check 0 "can_setup_iface (fd on) must pass berr-reporting on explicitly: $up_line"; else check 1 "can_setup_iface (fd on) must pass berr-reporting on explicitly: $up_line"; fi
if [[ "$up_line" == *"dbitrate 2000000 fd on"* ]]; then check 0 "can_setup_iface (fd on) must pass dbitrate+fd on: $up_line"; else check 1 "can_setup_iface (fd on) must pass dbitrate+fd on: $up_line"; fi
cfg=$(cat "$CAN_TOOLS_FAKE_DIR/can0/config")
if [[ "$cfg" == "restart_ms=100 berr=on fd=on admin=up" ]]; then check 0 "can_setup_iface (fd on) resulting config should show berr=on fd=on admin=up, got: $cfg"; else check 1 "can_setup_iface (fd on) resulting config should show berr=on fd=on admin=up, got: $cfg"; fi

# --- fd off: must explicitly clear a previously-on FD/berr iface ---
CAN_BITRATE=250000 CAN_RESTART_MS=0 CAN_BERR_REPORTING=off CAN_FD=off CAN_TXQUEUELEN=10 \
    can_setup_iface can0 >/dev/null 2>&1
check $? "can_setup_iface (fd off) should succeed"
up_line=$(grep "link set can0 up" "$CAN_TOOLS_FAKE_DIR/calls.log" | tail -n1)
if [[ "$up_line" == *"berr-reporting off"* ]]; then check 0 "can_setup_iface (fd off) must pass berr-reporting off explicitly: $up_line"; else check 1 "can_setup_iface (fd off) must pass berr-reporting off explicitly: $up_line"; fi
if [[ "$up_line" == *"fd off"* && "$up_line" != *"dbitrate"* ]]; then check 0 "can_setup_iface (fd off) must pass fd off and NOT dbitrate: $up_line"; else check 1 "can_setup_iface (fd off) must pass fd off and NOT dbitrate: $up_line"; fi
cfg=$(cat "$CAN_TOOLS_FAKE_DIR/can0/config")
if [[ "$cfg" == "restart_ms=0 berr=off fd=off admin=up" ]]; then check 0 "can_setup_iface (fd off) must actually turn berr/fd off on an iface that was on, got: $cfg"; else check 1 "can_setup_iface (fd off) must actually turn berr/fd off on an iface that was on, got: $cfg"; fi

# txqueuelen is set after up
grep -q "link set can0 txqueuelen 10" "$CAN_TOOLS_FAKE_DIR/calls.log"
check $? "can_setup_iface should set txqueuelen"

# --- idempotent / lock released on success ---
_CAN_LOCK_DEPTH=0
can_setup_iface can0 >/dev/null 2>&1
if [[ $_CAN_LOCK_DEPTH -eq 0 ]]; then check 0 "can_setup_iface must release can_lock on success, depth=$_CAN_LOCK_DEPTH"; else check 1 "can_setup_iface must release can_lock on success, depth=$_CAN_LOCK_DEPTH"; fi

# --- lock released even when the command fails ---
mkdir -p "$CAN_TOOLS_FAKE_DIR/fail"
touch "$CAN_TOOLS_FAKE_DIR/fail/ip"
_CAN_LOCK_DEPTH=0
can_setup_iface can0 >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then check 0 "can_setup_iface should report failure when ip fails, got rc=$rc"; else check 1 "can_setup_iface should report failure when ip fails, got rc=$rc"; fi
if [[ $_CAN_LOCK_DEPTH -eq 0 ]]; then check 0 "can_setup_iface must release can_lock even on failure (H1), depth=$_CAN_LOCK_DEPTH"; else check 1 "can_setup_iface must release can_lock even on failure (H1), depth=$_CAN_LOCK_DEPTH"; fi
rm -f "$CAN_TOOLS_FAKE_DIR/fail/ip"

# --- DRY_RUN: must not touch the fake and must log the fd/berr args ---
rm -f "$CAN_TOOLS_FAKE_DIR/calls.log"
export CAN_TOOLS_DRY_RUN=1
CAN_BERR_REPORTING=on CAN_FD=off can_setup_iface can0 2>"$tmpdir/dry.log" >/dev/null
check $? "can_setup_iface with CAN_TOOLS_DRY_RUN=1 should return 0"
if [[ ! -f "$CAN_TOOLS_FAKE_DIR/calls.log" ]]; then check 0 "CAN_TOOLS_DRY_RUN must not actually invoke ip"; else check 1 "CAN_TOOLS_DRY_RUN must not actually invoke ip"; fi
grep -q "berr-reporting on" "$tmpdir/dry.log"
check $? "CAN_TOOLS_DRY_RUN log should include the berr-reporting arg"
grep -q "fd off" "$tmpdir/dry.log"
check $? "CAN_TOOLS_DRY_RUN log should include the fd off arg"
grep -q "link set can0 down" "$tmpdir/dry.log"
check $? "CAN_TOOLS_DRY_RUN log should include the down command too"
unset CAN_TOOLS_DRY_RUN

echo ""
echo "Setup tests: $pass passed, $fail failed"
exit $fail
