#!/bin/bash
# test_setup_lib_usage.sh - Actually run canhat_fd_rename.bash and
# canhat_fd_setup.bash against the tests/fakes/ip + fake sysfs, per Issue #9
# §2b and the PR-A2 review (C1, H3).
#
# canhat_plus_* is intentionally untouched by PR-A2 (H4) and is not exercised
# here beyond a static "still matches develop" check (PR-C owns it).

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fakes_dir="$repo_root/tests/fakes"

tmpdir=$(mktemp -d)
cleanup() {
    pkill -9 -f "$fakes_dir/ip" 2>/dev/null || true
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

# Build a fake sysfs where $1 is at $2 and $3 is at $4 (spidev:iface pairs),
# plus matching tests/fakes/ip state/config entries (both admin=down, so the
# rename script's own down calls are the only ones that matter).
_setup_fake_devices() {
    local sysfs_root="$1" fake_dir="$2"
    shift 2
    mkdir -p "$sysfs_root/class/net" "$sysfs_root/bus/spi/devices"
    mkdir -p "$fake_dir"
    while [[ $# -gt 0 ]]; do
        local spidev="$1" iface="$2"
        shift 2
        mkdir -p "$sysfs_root/bus/spi/devices/$spidev/net"
        mkdir -p "$sysfs_root/class/net/$iface"
        ln -sf "$sysfs_root/bus/spi/devices/$spidev" "$sysfs_root/class/net/$iface/device"
        ln -sf "$sysfs_root/class/net/$iface" "$sysfs_root/bus/spi/devices/$spidev/net/$iface"
        mkdir -p "$fake_dir/$iface"
        echo "restart_ms=0 berr=off fd=off admin=down" >"$fake_dir/$iface/config"
        echo "ERROR-ACTIVE" >"$fake_dir/$iface/state"
    done
}

run_rename() {
    local sysfs_root="$1" fake_dir="$2" conf="$3"
    mkdir -p "$fake_dir/run"
    env -i PATH="/usr/bin:/bin" \
        CAN_TOOLS_SYSFS_ROOT="$sysfs_root" \
        CAN_TOOLS_IP_CMD="$fakes_dir/ip" \
        CAN_TOOLS_FAKE_DIR="$fake_dir" \
        CAN_TOOLS_RUN_DIR="$fake_dir/run" \
        CAN_TOOLS_CONF="$conf" \
        WD_RTNL_TIMEOUT_S=2 \
        bash "$repo_root/canhat_fd_rename.bash"
}

empty_conf="$tmpdir/empty.conf"
: >"$empty_conf"

# ---------------------------------------------------------------------
# C1 a: probe order swapped at boot (spi0.0 ended up can1, spi1.0 ended up
# can0) -> rename must swap them back to spi0.0=can0 / spi1.0=can1.
# ---------------------------------------------------------------------
echo "Testing canhat_fd_rename.bash: swap from a swapped boot state (C1)"
sysfs1="$tmpdir/sysfs1" fake1="$tmpdir/fake1"
_setup_fake_devices "$sysfs1" "$fake1" spi0.0 can1 spi1.0 can0

run_rename "$sysfs1" "$fake1" "$empty_conf" >"$tmpdir/rename1.log" 2>&1
rc=$?
(( rc == 0 )); check $? "rename should exit 0 after a successful swap, got $rc: $(cat "$tmpdir/rename1.log")"

readlink -f "$sysfs1/bus/spi/devices/spi0.0/net"/* 2>/dev/null | grep -q "/can0$"
check $? "after swap, spi0.0's netdev should be can0"
readlink -f "$sysfs1/bus/spi/devices/spi1.0/net"/* 2>/dev/null | grep -q "/can1$"
check $? "after swap, spi1.0's netdev should be can1"
grep -q "link set can_tmp_" "$fake1/calls.log"
check $? "swap should go through a temporary name"
down_count=$(grep -c "link set .* down" "$fake1/calls.log")
(( down_count == 2 )); check $? "swap should bring down exactly the two swapped ifaces, got $down_count downs"

# ---------------------------------------------------------------------
# C1 b: already correctly named -> can_pin_name takes the "rc=0, no-op"
# branch and the rename script must not call `ip link set` at all.
# ---------------------------------------------------------------------
echo "Testing canhat_fd_rename.bash: already correct (no ip link set calls)"
sysfs2="$tmpdir/sysfs2" fake2="$tmpdir/fake2"
_setup_fake_devices "$sysfs2" "$fake2" spi0.0 can0 spi1.0 can1

run_rename "$sysfs2" "$fake2" "$empty_conf" >"$tmpdir/rename2.log" 2>&1
rc=$?
(( rc == 0 )); check $? "rename should exit 0 when already correctly named, got $rc"
if [[ ! -f "$fake2/calls.log" ]] || [[ ! -s "$fake2/calls.log" ]]; then rc=0; else rc=1; fi
check "$rc" "rename must not call 'ip link set' at all when nothing needs renaming, got: $(cat "$fake2/calls.log" 2>/dev/null)"

# ---------------------------------------------------------------------
# C1 c: only one of the two spidevs ever gets a netdev (L4) -> rename must
# not crash, should warn, and (per the documented policy) exits 0 so the
# oneshot unit is not left permanently failed over missing hardware.
# ---------------------------------------------------------------------
echo "Testing canhat_fd_rename.bash: only one interface present (L4)"
sysfs3="$tmpdir/sysfs3" fake3="$tmpdir/fake3"
_setup_fake_devices "$sysfs3" "$fake3" spi0.0 can0
# spi1.0 is never created: can_iface_of_spidev(spi1.0) will fail forever.

t0=$SECONDS
run_rename "$sysfs3" "$fake3" "$empty_conf" >"$tmpdir/rename3.log" 2>&1
rc=$?
elapsed=$((SECONDS - t0))
(( rc == 0 )); check $? "rename with one missing interface should still exit 0 (L4 policy), got $rc: $(cat "$tmpdir/rename3.log")"
(( elapsed < 15 )); check $? "the 10s wait-for-both-interfaces loop must not hang past its bound (took ${elapsed}s)"
grep -q "^<4>" "$tmpdir/rename3.log"
check $? "rename should log a WARNING (priority 4) about the missing interface: $(cat "$tmpdir/rename3.log")"

# ---------------------------------------------------------------------
# H3: canhat_fd_setup.bash must only touch the interface given as $1.
# ---------------------------------------------------------------------
echo "Testing canhat_fd_setup.bash: only touches \$1 (H3)"
fake4="$tmpdir/fake4"
mkdir -p "$fake4/can0" "$fake4/can1"
echo "restart_ms=0 berr=off fd=off admin=down" >"$fake4/can0/config"
echo "ERROR-ACTIVE" >"$fake4/can0/state"
echo "restart_ms=0 berr=off fd=off admin=down" >"$fake4/can1/config"
echo "ERROR-ACTIVE" >"$fake4/can1/state"

mkdir -p "$fake4/run"
env -i PATH="/usr/bin:/bin" \
    CAN_TOOLS_IP_CMD="$fakes_dir/ip" \
    CAN_TOOLS_FAKE_DIR="$fake4" \
    CAN_TOOLS_RUN_DIR="$fake4/run" \
    CAN_TOOLS_CONF="$empty_conf" \
    WD_RTNL_TIMEOUT_S=2 \
    bash "$repo_root/canhat_fd_setup.bash" can0 >"$tmpdir/setup4.log" 2>&1
rc=$?
(( rc == 0 )); check $? "canhat_fd_setup.bash can0 should succeed, got $rc: $(cat "$tmpdir/setup4.log")"
grep -q "link set can0 " "$fake4/calls.log"
check $? "setup should operate on can0"
if ! grep -q "link set can1 " "$fake4/calls.log"; then rc=0; else rc=1; fi
check "$rc" "setup can0 must NOT touch can1 (H3): $(cat "$fake4/calls.log")"

# Usage error: no interface given.
env -i PATH="/usr/bin:/bin" CAN_TOOLS_CONF="$empty_conf" bash "$repo_root/canhat_fd_setup.bash" >/dev/null 2>&1
rc=$?
(( rc != 0 )); check $? "canhat_fd_setup.bash with no argument should fail, got $rc"

# ---------------------------------------------------------------------
# H3: the ip arguments must include restart-ms 100, fd on (+ dbitrate), and
# txqueuelen 10 (current repo defaults, preserved from the incident).
# ---------------------------------------------------------------------
echo "Testing canhat_fd_setup.bash: ip arguments (restart-ms/fd/txqueuelen)"
grep "link set can0 up" "$fake4/calls.log" | grep -q "restart-ms 100"
check $? "setup should request restart-ms 100"
grep "link set can0 up" "$fake4/calls.log" | grep -q "fd on"
check $? "setup should request fd on"
grep "link set can0 up" "$fake4/calls.log" | grep -q "dbitrate 2000000"
check $? "setup should request dbitrate 2000000 when fd is on"
grep -q "link set can0 txqueuelen 10" "$fake4/calls.log"
check $? "setup should set txqueuelen 10"

# ---------------------------------------------------------------------
# H3: enable_canhat_fd.sh must loop CAN_IFACES (default can0 can1) and run
# canhat_fd_setup.bash as a subprocess per interface (not source it - a
# sourced script's `exit` would otherwise abort the loop after can0).
# ---------------------------------------------------------------------
echo "Testing enable_canhat_fd.sh: loops CAN_IFACES (H3)"
fake5="$tmpdir/fake5"
mkdir -p "$fake5/can0" "$fake5/can1"
echo "restart_ms=0 berr=off fd=off admin=down" >"$fake5/can0/config"
echo "ERROR-ACTIVE" >"$fake5/can0/state"
echo "restart_ms=0 berr=off fd=off admin=down" >"$fake5/can1/config"
echo "ERROR-ACTIVE" >"$fake5/can1/state"

mkdir -p "$fake5/run"
env -i PATH="/usr/bin:/bin" \
    CAN_TOOLS_IP_CMD="$fakes_dir/ip" \
    CAN_TOOLS_FAKE_DIR="$fake5" \
    CAN_TOOLS_RUN_DIR="$fake5/run" \
    CAN_TOOLS_CONF="$empty_conf" \
    WD_RTNL_TIMEOUT_S=2 \
    bash "$repo_root/enable_canhat_fd.sh" >"$tmpdir/enable5.log" 2>&1
rc=$?
(( rc == 0 )); check $? "enable_canhat_fd.sh should succeed, got $rc: $(cat "$tmpdir/enable5.log")"
grep -q "link set can0 up" "$fake5/calls.log"
check $? "enable_canhat_fd.sh should bring up can0"
grep -q "link set can1 up" "$fake5/calls.log"
check $? "enable_canhat_fd.sh should bring up can1 too (both interfaces reached, unlike a sourced double-exit script)"

echo ""
echo "Setup/rename tests: $pass passed, $fail failed"
exit "$fail"
