#!/bin/bash

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$tmpdir'" EXIT

pass=0 fail=0

echo "Testing can_iface_states with real format..."

mkdir -p "$tmpdir/fakes"
cat >"$tmpdir/fakes/ip" <<'EOFIP'
#!/bin/bash
if [[ "$1" == "-d" && "$2" == "link" && "$3" == "show" && "$4" == "type" && "$5" == "can" ]]; then
    cat <<"EOF"
3: can0: <NOARP,UP,LOWER_UP,ECHO> mtu 72 qdisc pfifo_fast state UP mode DEFAULT group default qlen 10
    can <BERR-REPORTING,FD,TDC-AUTO> state ERROR-ACTIVE (berr-counter tx 0 rx 0) restart-ms 100
4: can1: <NOARP,UP,LOWER_UP> mtu 72 qdisc pfifo_fast state UP mode DEFAULT group default qlen 10
    can <FD,TDC-AUTO> state ERROR-PASSIVE (berr-counter tx 0 rx 0) restart-ms 0
EOF
fi
exit 0
EOFIP
chmod +x "$tmpdir/fakes/ip"

export CAN_TOOLS_IP_CMD="$tmpdir/fakes/ip"
export WD_RTNL_TIMEOUT_S=1
export CAN_TOOLS_RUN_DIR="$tmpdir/run"

output=$(can_iface_states)

# Test: real format parsing (can0 ERROR-ACTIVE)
if echo "$output" | grep -q "can0 ERROR-ACTIVE"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_iface_states output missing can0 ERROR-ACTIVE"
fi

# Test: real format parsing (can1 ERROR-PASSIVE)
if echo "$output" | grep -q "can1 ERROR-PASSIVE"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_iface_states output missing can1 ERROR-PASSIVE"
fi

# Test: UP flag confusion (H4 - operstate state UP not confused with admin UP)
if echo "$output" | grep "can0" | grep -q "admin=up"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_iface_states should extract admin=up"
fi

# Test: berr flag parsing
if echo "$output" | grep "can0" | grep -q "berr=on"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_iface_states should parse berr=on for can0"
fi

if echo "$output" | grep "can1" | grep -q "berr=off"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_iface_states should parse berr=off for can1"
fi

# Test: fd flag parsing
if echo "$output" | grep "can0" | grep -q "fd=on"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_iface_states should parse fd=on for can0"
fi

if echo "$output" | grep "can1" | grep -q "fd=on"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_iface_states should parse fd=on for can1"
fi

# Test: restart_ms parsing
if echo "$output" | grep "can0" | grep -q "restart_ms=100"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_iface_states should parse restart_ms=100 for can0"
fi

if echo "$output" | grep "can1" | grep -q "restart_ms=0"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_iface_states should parse restart_ms=0 for can1"
fi

# Test: LOWER_UP not confused with UP (H4)
if ! echo "$output" | grep "can0" | grep -q "admin=lower_up"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: can_iface_states should not confuse LOWER_UP with admin"
fi

# Test: FD-NON-ISO not confused with FD (H4/L1)
# Add test case with FD-NON-ISO scenario if needed
# For now, verify that FD alone is recognized correctly

echo ""
echo "Iface tests: $pass passed, $fail failed"
exit $fail
