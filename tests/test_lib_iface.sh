#!/bin/bash

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
cleanup() {
    pkill -9 -f "$repo_root/tests/fakes/ip" 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

pass=0 fail=0
check() {
    if [[ "$1" == "0" ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: $2"
    fi
}

echo "Testing can_iface_states with tests/fakes/ip..."

export CAN_TOOLS_IP_CMD="$repo_root/tests/fakes/ip"
export CAN_TOOLS_RUN_DIR="$tmpdir/run"
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
export WD_RTNL_TIMEOUT_S=1
mkdir -p "$CAN_TOOLS_FAKE_DIR"

# can0: up, berr on, fd on, ERROR-ACTIVE
mkdir -p "$CAN_TOOLS_FAKE_DIR/can0"
echo "restart_ms=100 berr=on fd=on admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"

# can1: administratively down (admin=down) but CAN controller still reports
# STOPPED - §2b: "STOPPED は up していない CAN コントローラの状態で、admin=down
# と併存し得る". The fake always writes operstate "state UP" on the iface
# line (mirroring real hardware where operstate can lag/differ), so this
# also exercises not confusing that with admin or with the CAN STATE.
mkdir -p "$CAN_TOOLS_FAKE_DIR/can1"
echo "restart_ms=0 berr=off fd=off admin=down" >"$CAN_TOOLS_FAKE_DIR/can1/config"
echo "STOPPED" >"$CAN_TOOLS_FAKE_DIR/can1/state"

# can_iface_states must be called as a plain command (not $( ) / < <( )) per
# the contract documented above it in the lib - verify the documented usage
# actually works and captures output correctly via a plain redirect.
outfile="$tmpdir/states.txt"
can_iface_states >"$outfile" 2>&1
rc=$?
output=$(cat "$outfile")

if [[ $rc -eq 0 ]]; then check 0 "can_iface_states should return 0 when ifaces are found, got $rc"; else check 1 "can_iface_states should return 0 when ifaces are found, got $rc"; fi

echo "$output" | grep -q "^can0 ERROR-ACTIVE "
check $? "can_iface_states output missing 'can0 ERROR-ACTIVE'"
echo "$output" | grep "^can0 " | grep -q "admin=up"
check $? "can_iface_states should report admin=up for can0"
echo "$output" | grep "^can0 " | grep -q "berr=on"
check $? "can_iface_states should parse berr=on for can0"
echo "$output" | grep "^can0 " | grep -q "fd=on"
check $? "can_iface_states should parse fd=on for can0"
echo "$output" | grep "^can0 " | grep -q "restart_ms=100"
check $? "can_iface_states should parse restart_ms=100 for can0"

echo "$output" | grep -q "^can1 STOPPED "
check $? "can_iface_states output missing 'can1 STOPPED'"
echo "$output" | grep "^can1 " | grep -q "admin=down"
check $? "can_iface_states should report admin=down for can1 even though operstate says UP (STOPPED+admin=down coexistence, §2b)"
echo "$output" | grep "^can1 " | grep -q "berr=off"
check $? "can_iface_states should parse berr=off for can1"

# FD-NON-ISO must not be read as plain fd=on when a bare ",FD," token is not
# present (L1): a hand-built ip line is used here to pin down the exact
# ctrlmode text, independent of how the fake happens to build it.
cat >"$tmpdir/raw_ip" <<'EOF'
#!/bin/bash
echo "2: can0: <NOARP,UP,LOWER_UP,ECHO> mtu 72 qdisc pfifo_fast state UP mode DEFAULT group default qlen 10"
echo "    can <BERR-REPORTING,FD-NON-ISO,TDC-AUTO> state ERROR-ACTIVE (berr-counter tx 0 rx 0) restart-ms 100"
exit 0
EOF
chmod +x "$tmpdir/raw_ip"
export CAN_TOOLS_IP_CMD="$tmpdir/raw_ip"
can_iface_states >"$outfile" 2>&1
grep "^can0 " "$outfile" | grep -q "fd=off"
check $? "can_iface_states must NOT read a lone FD-NON-ISO token as fd=on (L1)"
grep "^can0 " "$outfile" | grep -q "berr=on"
check $? "can_iface_states should still read berr=on alongside FD-NON-ISO"
export CAN_TOOLS_IP_CMD="$repo_root/tests/fakes/ip"

# --- hang safety (R2/N-H1): must not block, must call ip exactly once, and
# must refuse to start a second ip while the first is still hung. This is
# the same property test_lib_core.sh proves for can_run_bounded directly;
# here we prove can_iface_states (the actual caller used by the watchdog)
# does not lose that property through an internal subshell. ---
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake_hang"
mkdir -p "$CAN_TOOLS_FAKE_DIR/hang"
touch "$CAN_TOOLS_FAKE_DIR/hang/ip"

CAN_RUN_BOUNDED_PID=""
t0=$SECONDS
can_iface_states >"$outfile" 2>&1
rc=$?
elapsed=$((SECONDS - t0))
if [[ $rc -eq 124 ]]; then check 0 "can_iface_states on a hung ip should return 124, got $rc"; else check 1 "can_iface_states on a hung ip should return 124, got $rc"; fi
(( elapsed <= 3 )); check $? "can_iface_states must not block on a hung ip (took ${elapsed}s)"
calls=$(wc -l <"$CAN_TOOLS_FAKE_DIR/calls.log")
if [[ "$calls" == "1" ]]; then check 0 "can_iface_states should invoke ip exactly once (got $calls calls)"; else check 1 "can_iface_states should invoke ip exactly once (got $calls calls)"; fi

t0=$SECONDS
can_iface_states >"$outfile" 2>&1
rc2=$?
elapsed2=$((SECONDS - t0))
if [[ $rc2 -eq 124 ]]; then check 0 "a second can_iface_states call must also return 124 while the hung ip is still alive"; else check 1 "a second can_iface_states call must also return 124 while the hung ip is still alive"; fi
(( elapsed2 <= 1 )); check $? "the second call must return immediately (no new wait), took ${elapsed2}s"
calls2=$(wc -l <"$CAN_TOOLS_FAKE_DIR/calls.log")
if [[ "$calls2" == "1" ]]; then check 0 "a second can_iface_states call must NOT spawn a new hung ip process (R2) - calls.log still $calls2"; else check 1 "a second can_iface_states call must NOT spawn a new hung ip process (R2) - calls.log still $calls2"; fi

echo ""
echo "Iface tests: $pass passed, $fail failed"
exit $fail
