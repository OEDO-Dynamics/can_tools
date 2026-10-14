#!/bin/bash

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
trap "rm -rf '$tmpdir'" EXIT

passed=0 failed=0

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

echo "$output" | grep -q "can0 ERROR-ACTIVE" && ((passed++)) || ((failed++))
echo "$output" | grep -q "can1 ERROR-PASSIVE" && ((passed++)) || ((failed++))
echo "$output" | grep "can0" | grep -q "berr=on" && ((passed++)) || ((failed++))
echo "$output" | grep "can1" | grep -q "berr=off" && ((passed++)) || ((failed++))
echo "$output" | grep "can0" | grep -q "fd=on" && ((passed++)) || ((failed++))
echo "$output" | grep "can1" | grep -q "fd=on" && ((passed++)) || ((failed++))
echo "$output" | grep "can0" | grep -q "restart_ms=100" && ((passed++)) || ((failed++))
echo "$output" | grep "can1" | grep -q "restart_ms=0" && ((passed++)) || ((failed++))
echo "$output" | grep "can0" | grep -q "admin=up" && ((passed++)) || ((failed++))

echo ""
echo "Iface tests: $passed passed, $failed failed"
exit $failed
