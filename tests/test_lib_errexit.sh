#!/bin/bash

# tests/test_lib_errexit.sh - verify every can_tools_lib.bash function can be
# called BARE (no surrounding if/||) from a caller running `set -euo
# pipefail`, on its normal/success-path branches, without aborting mid-body.
#
# This is a distinct concern from a function's own return value (which is
# always the caller's responsibility per the file header's call convention):
# here we are checking that no INTERNAL statement -- an uninitialized
# `local` under `set -u`, an unbound env var reference, a plain `(( x++ ))`
# whose pre-increment value is 0, a `cmd; rc=$?` pair where `cmd` is allowed
# to fail -- kills the function (and the caller's whole script) before it
# ever reaches its own `return`.
#
# Each scenario below runs can_tools_lib.bash in a genuinely separate bash
# subprocess with `set -euo pipefail` (so a crash cannot be masked by this
# test script's own, more lenient, shell options), and checks that the
# subprocess exits 0 and prints the trailing ERREXIT_OK marker -- proving it
# ran to completion rather than dying partway through.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

pass=0 fail=0
check() {
    if [[ "$1" == "0" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $2"
    fi
}

# run_errexit <description> <env assignments...> -- <bash script body>
# The body is executed as `bash -c 'set -euo pipefail; source "$lib"; <body>'`
# with the given env assignments applied to that subprocess only. The body
# must end by echoing ERREXIT_OK on success.
run_errexit() {
    local desc="$1"
    shift
    local -a envs=()
    while [[ "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    shift # drop --
    local body="$1"

    local out rc=0
    out=$(env "${envs[@]}" bash -c "set -euo pipefail
source \"$lib\"
$body" 2>&1) || rc=$?

    if [[ $rc -eq 0 && "$out" == *"ERREXIT_OK"* ]]; then
        check 0 "$desc"
    else
        check 1 "$desc (rc=$rc, output: $out)"
    fi
}

# ========== can_lock / can_unlock: 0 -> 1 -> 0, reentrant ==========
echo "Testing can_lock/can_unlock under set -euo pipefail (bare calls)..."

run_errexit "can_lock depth 0->1 (bare) must not abort on the 0->1 arithmetic step" \
    "CAN_TOOLS_RUN_DIR=$tmpdir/lock1" -- '
can_lock 5
[[ "$_CAN_LOCK_DEPTH" == "1" ]] || { echo "depth=$_CAN_LOCK_DEPTH"; exit 1; }
can_unlock
[[ "$_CAN_LOCK_DEPTH" == "0" ]] || { echo "depth=$_CAN_LOCK_DEPTH"; exit 1; }
echo ERREXIT_OK
'

run_errexit "can_lock reentrant (depth 0->1->2->1->0, bare)" \
    "CAN_TOOLS_RUN_DIR=$tmpdir/lock2" -- '
can_lock 5
can_lock 5
[[ "$_CAN_LOCK_DEPTH" == "2" ]] || { echo "depth=$_CAN_LOCK_DEPTH"; exit 1; }
can_unlock
[[ "$_CAN_LOCK_DEPTH" == "1" ]] || { echo "depth=$_CAN_LOCK_DEPTH"; exit 1; }
can_unlock
[[ "$_CAN_LOCK_DEPTH" == "0" ]] || { echo "depth=$_CAN_LOCK_DEPTH"; exit 1; }
echo ERREXIT_OK
'

# can_unlock called more times than can_lock returns 1 -- exercise that
# branch guarded, per the file's own call convention for a non-zero return.
run_errexit "can_unlock at depth 0 returns 1 without aborting (guarded)" \
    "CAN_TOOLS_RUN_DIR=$tmpdir/lock3" -- '
if can_unlock; then echo "should not succeed"; exit 1; fi
echo ERREXIT_OK
'

# ========== can_now: fake clock present / absent, under env -i ==========
echo "Testing can_now under set -euo pipefail, with and without a fake clock..."

# Without CAN_TOOLS_FAKE_TIME_FILE set AT ALL (not even empty) -- env -i
# strips the whole environment so there is no way a leftover empty var from
# this test script's own shell can mask the `set -u` unbound-variable bug.
out=$(env -i PATH="$PATH" bash -c "set -euo pipefail
source \"$lib\"
v=\$(can_now)
[[ \"\$v\" =~ ^[0-9]+\$ ]] || { echo \"bad value: \$v\"; exit 1; }
echo ERREXIT_OK" 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *"ERREXIT_OK"* ]]; then
    check 0 "can_now under env -i (no CAN_TOOLS_FAKE_TIME_FILE at all) must not abort on \$-u"
else
    check 1 "can_now under env -i (no CAN_TOOLS_FAKE_TIME_FILE at all) must not abort on \$-u (rc=$rc, output: $out)"
fi

# With a fake clock file present and pointed to.
fake_time_file="$tmpdir/fake_time"
echo 1700000000 >"$fake_time_file"
out=$(env -i PATH="$PATH" CAN_TOOLS_FAKE_TIME_FILE="$fake_time_file" bash -c "set -euo pipefail
source \"$lib\"
v=\$(can_now)
[[ \"\$v\" == \"1700000000\" ]] || { echo \"got: \$v\"; exit 1; }
echo ERREXIT_OK" 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *"ERREXIT_OK"* ]]; then
    check 0 "can_now with CAN_TOOLS_FAKE_TIME_FILE set must return its content"
else
    check 1 "can_now with CAN_TOOLS_FAKE_TIME_FILE set must return its content (rc=$rc, output: $out)"
fi

# ========== can_pin_name: 0 / 2 / empty net dir ==========
echo "Testing can_pin_name branches under set -euo pipefail..."

# branch: name already correct -> rc=0, bare call must not abort.
sysfs0="$tmpdir/sysfs_pin0"
mkdir -p "$sysfs0/bus/spi/devices/spi0.0/net/can0"
run_errexit "can_pin_name rc=0 (name already matches, bare)" \
    "CAN_TOOLS_SYSFS_ROOT=$sysfs0" "CAN_TOOLS_IP_CMD=$repo_root/tests/fakes/ip" -- '
can_pin_name spi0.0 can0
echo ERREXIT_OK
'

# branch: want name collides with a different netdev -> rc=2 (guarded, since
# this is a deliberate non-zero return -- the N-C1/§2b contract value, not an
# internal abort).
sysfs2="$tmpdir/sysfs_pin2"
fakedir2="$tmpdir/fakeip_pin2"
mkdir -p "$sysfs2/bus/spi/devices/spi0.0/net/can0" "$fakedir2/can0" "$fakedir2/eth0"
echo "restart_ms=0 berr=off fd=off admin=down" >"$fakedir2/can0/config"
echo "restart_ms=0 berr=off fd=off admin=down" >"$fakedir2/eth0/config"
run_errexit "can_pin_name rc=2 on name collision (guarded)" \
    "CAN_TOOLS_SYSFS_ROOT=$sysfs2" "CAN_TOOLS_IP_CMD=$repo_root/tests/fakes/ip" "CAN_TOOLS_FAKE_DIR=$fakedir2" -- '
rc=0
can_pin_name spi0.0 eth0 || rc=$?
[[ $rc -eq 2 ]] || { echo "rc=$rc"; exit 1; }
echo ERREXIT_OK
'

# branch: net/ dir exists but is EMPTY (M-new1: in-flight unbind/bind window)
# -> rc=1, CAN_PIN_NAME_REASON=no_iface. This is exactly the scenario that
# used to crash with "current: unbound variable" under the caller's set -u.
sysfs_empty="$tmpdir/sysfs_pin_empty"
mkdir -p "$sysfs_empty/bus/spi/devices/spi0.0/net"
run_errexit "can_pin_name with an empty net/ dir returns 1, not an unbound-variable abort (guarded)" \
    "CAN_TOOLS_SYSFS_ROOT=$sysfs_empty" "CAN_TOOLS_IP_CMD=$repo_root/tests/fakes/ip" -- '
rc=0
can_pin_name spi0.0 can0 || rc=$?
[[ $rc -eq 1 ]] || { echo "rc=$rc"; exit 1; }
[[ "$CAN_PIN_NAME_REASON" == "no_iface" ]] || { echo "reason=$CAN_PIN_NAME_REASON"; exit 1; }
echo ERREXIT_OK
'

# branch: spidev has no net/ dir at all -> rc=1, CAN_PIN_NAME_REASON=no_net_dir
run_errexit "can_pin_name with no net/ dir at all returns 1 (guarded)" \
    "CAN_TOOLS_SYSFS_ROOT=$tmpdir/sysfs_pin_missing" "CAN_TOOLS_IP_CMD=$repo_root/tests/fakes/ip" -- '
rc=0
can_pin_name spi0.0 can0 || rc=$?
[[ $rc -eq 1 ]] || { echo "rc=$rc"; exit 1; }
[[ "$CAN_PIN_NAME_REASON" == "no_net_dir" ]] || { echo "reason=$CAN_PIN_NAME_REASON"; exit 1; }
echo ERREXIT_OK
'

# ========== can_iface_states ==========
echo "Testing can_iface_states under set -euo pipefail..."

fakedir_states="$tmpdir/fakeip_states"
mkdir -p "$fakedir_states/can0"
echo "ERROR-ACTIVE" >"$fakedir_states/can0/state"
echo "restart_ms=100 berr=off fd=on admin=up" >"$fakedir_states/can0/config"
run_errexit "can_iface_states with one iface present, bare call (found++ from 0)" \
    "CAN_TOOLS_IP_CMD=$repo_root/tests/fakes/ip" "CAN_TOOLS_FAKE_DIR=$fakedir_states" "CAN_TOOLS_RUN_DIR=$tmpdir/run_states" -- '
out=$(can_iface_states)
[[ "$out" == *"can0"* ]] || { echo "out=$out"; exit 1; }
echo ERREXIT_OK
'

fakedir_states_empty="$tmpdir/fakeip_states_empty"
mkdir -p "$fakedir_states_empty"
run_errexit "can_iface_states with no ifaces returns 1 (guarded)" \
    "CAN_TOOLS_IP_CMD=$repo_root/tests/fakes/ip" "CAN_TOOLS_FAKE_DIR=$fakedir_states_empty" "CAN_TOOLS_RUN_DIR=$tmpdir/run_states_empty" -- '
rc=0
can_iface_states >/dev/null || rc=$?
[[ $rc -eq 1 ]] || { echo "rc=$rc"; exit 1; }
echo ERREXIT_OK
'

# ========== can_setup_iface DRY_RUN ==========
echo "Testing can_setup_iface (DRY_RUN) under set -euo pipefail..."

run_errexit "can_setup_iface with CAN_TOOLS_DRY_RUN=1, bare call" \
    "CAN_TOOLS_IP_CMD=$repo_root/tests/fakes/ip" "CAN_TOOLS_RUN_DIR=$tmpdir/run_dryrun" "CAN_TOOLS_DRY_RUN=1" -- '
can_setup_iface can0
[[ "$_CAN_LOCK_DEPTH" == "0" ]] || { echo "depth=$_CAN_LOCK_DEPTH"; exit 1; }
echo ERREXIT_OK
'

# ========== can_read_conf ==========
echo "Testing can_read_conf under set -euo pipefail..."

run_errexit "can_read_conf with a missing conf path, bare call (always returns 0)" \
    "CAN_TOOLS_CONF=$tmpdir/does_not_exist.conf" -- '
can_read_conf
[[ "$CAN_BITRATE" == "250000" ]] || { echo "bitrate=$CAN_BITRATE"; exit 1; }
echo ERREXIT_OK
'

conf_invalid="$tmpdir/invalid.conf"
echo "CAN_BITRATE=not_a_number" >"$conf_invalid"
run_errexit "can_read_conf with an invalid value falls back to default, bare call" \
    -- "
can_read_conf '$conf_invalid' 2>/dev/null
[[ \"\$CAN_BITRATE\" == \"250000\" ]] || { echo \"bitrate=\$CAN_BITRATE\"; exit 1; }
echo ERREXIT_OK
"

# ========== can_pause / can_pause_active / can_unpause ==========
echo "Testing can_pause family under set -euo pipefail..."

run_errexit "can_pause then can_pause_active (active), then can_unpause, all bare" \
    "CAN_TOOLS_RUN_DIR=$tmpdir/run_pause1" -- '
can_pause 30
can_pause_active
can_unpause
echo ERREXIT_OK
'

# can_pause_active on an EXPIRED pause file returns 1 -- this is exactly the
# `(( now < deadline )) && return 0` tail statement the task flagged; guard
# it like any other function that can legitimately return non-zero.
run_dir_expired="$tmpdir/run_pause_expired"
mkdir -p "$run_dir_expired"
echo "1" >"$run_dir_expired/watchdog.pause" # epoch 1 is always in the past
run_errexit "can_pause_active on an expired pause returns 1, not an abort (guarded)" \
    "CAN_TOOLS_RUN_DIR=$run_dir_expired" -- '
rc=0
can_pause_active || rc=$?
[[ $rc -eq 1 ]] || { echo "rc=$rc"; exit 1; }
echo ERREXIT_OK
'

run_errexit "can_pause_active with no pause file returns 1, not an abort (guarded)" \
    "CAN_TOOLS_RUN_DIR=$tmpdir/run_pause_none" -- '
rc=0
can_pause_active || rc=$?
[[ $rc -eq 1 ]] || { echo "rc=$rc"; exit 1; }
echo ERREXIT_OK
'

# can_pause with an invalid duration returns 1 -- guarded.
run_errexit "can_pause with an invalid duration returns 1, not an abort (guarded)" \
    "CAN_TOOLS_RUN_DIR=$tmpdir/run_pause_bad" -- '
rc=0
can_pause "not_a_number" || rc=$?
[[ $rc -eq 1 ]] || { echo "rc=$rc"; exit 1; }
echo ERREXIT_OK
'

echo ""
echo "Errexit tests: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
