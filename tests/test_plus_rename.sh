#!/bin/bash
# Exercise Plus rename using only fake sysfs and tests/fakes/ip.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
pass=0 fail=0
check() {
    if [[ "$1" == 0 ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: $2"
    fi
}
fixture() {
    case_dir="$tmpdir/$1"
    sysfs="$case_dir/sysfs"
    fake="$case_dir/fake"
    mkdir -p "$sysfs/class/net" "$fake/run"
    shift
    while (( $# )); do
        dev="$1" iface="$2"
        shift 2
        mkdir -p "$sysfs/bus/spi/devices/$dev/net" "$sysfs/class/net/$iface" "$fake/$iface"
        ln -s "$sysfs/bus/spi/devices/$dev" "$sysfs/class/net/$iface/device"
        ln -s "$sysfs/class/net/$iface" "$sysfs/bus/spi/devices/$dev/net/$iface"
        echo 'restart_ms=0 berr=off fd=off admin=up' >"$fake/$iface/config"
        echo ERROR-ACTIVE >"$fake/$iface/state"
    done
}
run_rename() {
    env -i PATH="/usr/bin:/bin" \
        CAN_TOOLS_SYSFS_ROOT="$sysfs" CAN_TOOLS_FAKE_DIR="$fake" \
        CAN_TOOLS_RUN_DIR="$fake/run" CAN_TOOLS_CONF="$tmpdir/conf" \
        CAN_TOOLS_IP_CMD="${ip_cmd:-$repo_root/tests/fakes/ip}" \
        REAL_FAKE_IP="$repo_root/tests/fakes/ip" FAIL_ON="${fail_on:-0}" \
        FAIL_AFTER="${fail_after:-0}" \
        bash "$repo_root/canhat_plus_rename.bash" >"$case_dir/log" 2>&1
}
name_is() {
    [[ -e "$sysfs/bus/spi/devices/$1/net/$2" ]]
}
# Even an FD mapping in the shared conf must not select the wrong hardware.
echo 'CAN_SPI_MAP=spi0.0:can0 spi1.0:can1' >"$tmpdir/conf"

fixture correct spi1.1 can0 spi1.2 can1
run_rename
check $? 'correct names must succeed'
[[ ! -s "$fake/calls.log" ]]
check $? 'correct names must not call ip'
grep -q admin=up "$fake/can0/config"
check $? 'correct names must leave admin state unchanged'

fixture swapped spi1.1 can1 spi1.2 can0
run_rename
check $? 'swapped names must succeed'
name_is spi1.1 can0 && name_is spi1.2 can1
check $? 'swap must map both physical Plus ports correctly'
[[ -z "$(find "$sysfs/class/net" -name 'can_tmp_*' -print)" ]]
check $? 'successful swap must leave no temporary name'

fixture third_iface spi1.1 can1 spi1.2 can0
mkdir -p "$sysfs/class/net/can9" "$fake/can9"
echo ERROR-ACTIVE >"$fake/can9/state"
echo 'restart_ms=0 berr=off fd=off admin=up' >"$fake/can9/config"
run_rename
check $? 'swapping HAT with a third CAN present must succeed'
name_is spi1.1 can0 && name_is spi1.2 can1
check $? 'third CAN must not interfere with HAT ownership'
! grep -q 'link set can9' "$fake/calls.log"
check $? 'noncolliding third CAN must not be touched'
grep -q admin=up "$fake/can9/config"
check $? 'third CAN must remain up'

fixture free_names spi1.1 can2 spi1.2 can3
run_rename
check $? 'free target names must succeed'
name_is spi1.1 can0 && name_is spi1.2 can1
check $? 'free names must be assigned without a swap'
! grep -q can_tmp_ "$fake/calls.log"
check $? 'free names must not use a temporary interface'

fixture missing spi1.1 can0
start=$SECONDS
run_rename
check $? 'missing netdev must retain warning/exit 0 policy'
(( SECONDS - start < 15 ))
check $? 'missing netdev wait must be bounded'
grep -q '^<4>.*missing_netdev' "$case_dir/log"
check $? 'missing netdev must log WARNING'
[[ ! -s "$fake/calls.log" ]]
check $? 'missing netdev must not change the correctly named channel'

fixture usb spi1.1 can1 spi1.2 can2
mkdir -p "$sysfs/class/net/can0" "$fake/can0"
echo ERROR-ACTIVE >"$fake/can0/state"
echo 'restart_ms=0 berr=off fd=off admin=up' >"$fake/can0/config"
run_rename
rc=$?
[[ "$rc" == 1 ]]; check $? 'USB name collision must fail visibly'
grep -q '^<3>.*name_owned_by_non_hat_device' "$case_dir/log"
check $? 'USB name collision must log ERROR'
[[ ! -s "$fake/calls.log" ]]
check $? 'USB collision must not change ANY interface'
name_is spi1.1 can1 && name_is spi1.2 can2
check $? 'USB collision must preserve HAT names'
grep -q admin=up "$fake/can0/config"
check $? 'USB collision must preserve USB admin state'

# Fail individual mutation steps, including the last swap rename. Let
# rollback succeed except in the final scenario, where it also fails.
cat >"$tmpdir/flaky_ip" <<'SH'
#!/bin/bash
if [[ "$1 $2" == 'link set' ]]; then
    count_file="$CAN_TOOLS_FAKE_DIR/count"
    n=0
    [[ ! -f "$count_file" ]] || read -r n <"$count_file"
    n=$((n+1))
    echo "$n" >"$count_file"
    if (( n == FAIL_ON || (FAIL_AFTER > 0 && n >= FAIL_AFTER) )); then
        echo "$*" >>"$CAN_TOOLS_FAKE_DIR/calls.log"
        exit 1
    fi
fi
exec "$REAL_FAKE_IP" "$@"
SH
chmod +x "$tmpdir/flaky_ip"
ip_cmd="$tmpdir/flaky_ip"
for fail_on in 1 2 3 4 5; do
    fixture "failure_$fail_on" spi1.1 can1 spi1.2 can0
    run_rename
    rc=$?
    [[ "$rc" == 1 ]]; check $? "swap step $fail_on must exit 1"
    grep -q '^<3>.*swap_failed' "$case_dir/log"
    check $? "swap step $fail_on must log ERROR for potentially down interfaces"
    [[ -z "$(find "$sysfs/class/net" -name 'can_tmp_*' -print)" ]]
    check $? "swap step $fail_on must roll back temporary names"
    name_is spi1.1 can1 && name_is spi1.2 can0
    check $? "swap step $fail_on must preserve original ownership after rollback"
    if (( fail_on > 1 )); then
        grep -q admin=down "$fake/can1/config"
        check $? "swap step $fail_on must exercise the reported down-interface failure"
    fi
done
fail_on=2
fixture free_rename_failure spi1.1 can2 spi1.2 can3
run_rename
rc=$?
[[ "$rc" == 1 ]]; check $? 'free-name rename failure must exit 1'
grep -q '^<3>.*pin_name_op_failed' "$case_dir/log"
check $? 'free-name rename failure must log ERROR'
name_is spi1.1 can2 && name_is spi1.2 can3
check $? 'free-name failure must stop before changing the other HAT port'

fail_on=4 fail_after=4
fixture rollback_failure spi1.1 can1 spi1.2 can0
run_rename
rc=$?
[[ "$rc" == 1 ]]; check $? 'failed rollback must exit 1'
grep -q '^<3>.*swap_failed' "$case_dir/log"
check $? 'failed rollback must log ERROR'
[[ -n "$(find "$sysfs/class/net" -name 'can_tmp_*' -print)" ]]
check $? 'fixture must actually exercise a leftover temporary name'

echo "Plus rename tests: $pass passed, $fail failed"
exit "$fail"
