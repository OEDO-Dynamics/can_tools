#!/bin/bash

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

pass=0 fail=0

# Test can_read_conf
export CAN_TOOLS_CONF="$tmpdir/empty.conf"
touch "$tmpdir/empty.conf"
can_read_conf
[[ -n "$CAN_BITRATE" ]] && ((pass++)) || ((fail++))

# Test can_lock reentrant
export CAN_TOOLS_RUN_DIR="$tmpdir/run"
_CAN_LOCK_DEPTH=0
can_lock 5
[[ $_CAN_LOCK_DEPTH -eq 1 ]] && ((pass++)) || ((fail++))
can_unlock
[[ $_CAN_LOCK_DEPTH -eq 0 ]] && ((pass++)) || ((fail++))

# Test fd 9 closure  
can_run_bounded 1 bash -c '[[ ! -f /proc/self/fd/9 ]]' >/dev/null 2>&1 && ((pass++)) || ((fail++))

# Test can_iface_states
mkdir -p "$tmpdir/fakes"
cat >"$tmpdir/fakes/ip" << 'EOFIP'
#!/bin/bash
[[ "$1" == "-d" ]] && echo "3: can0: <NOARP,UP,LOWER_UP,ECHO> mtu 72 qdisc pfifo_fast state UP mode DEFAULT group default qlen 10" && echo "    can <BERR-REPORTING,FD,TDC-AUTO> state ERROR-ACTIVE (berr-counter tx 0 rx 0) restart-ms 100"
exit 0
EOFIP
chmod +x "$tmpdir/fakes/ip"
export CAN_TOOLS_IP_CMD="$tmpdir/fakes/ip"
export WD_RTNL_TIMEOUT_S=1
output=$(can_iface_states)
echo "$output" | grep -q "can0 ERROR-ACTIVE" && ((pass++)) || ((fail++))

echo "All tests: $pass passed, $fail failed"
exit $fail
