#!/bin/bash

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
hang_pids=()
cleanup() {
    for p in "${hang_pids[@]}"; do
        kill -9 "$p" 2>/dev/null || true
    done
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

# ========== can_read_conf tests ==========
echo "Testing can_read_conf..."
export CAN_TOOLS_CONF="$tmpdir/empty.conf"
touch "$tmpdir/empty.conf"
can_read_conf
if [[ -n "$CAN_BITRATE" ]]; then check 0 "can_read_conf empty sets defaults"; else check 1 "can_read_conf empty sets defaults"; fi
if [[ "$CAN_BITRATE" == "250000" ]]; then check 0 "can_read_conf empty: CAN_BITRATE should be the lib default 250000"; else check 1 "can_read_conf empty: CAN_BITRATE should be the lib default 250000"; fi

# invalid enum value falls back to default + WARNING
cat >"$tmpdir/invalid.conf" <<EOF
CAN_BERR_REPORTING=maybe
EOF
can_read_conf "$tmpdir/invalid.conf" 2>"$tmpdir/warn.log"
if [[ "$CAN_BERR_REPORTING" == "off" ]]; then check 0 "can_read_conf invalid berr should default to off, got $CAN_BERR_REPORTING"; else check 1 "can_read_conf invalid berr should default to off, got $CAN_BERR_REPORTING"; fi
grep -qi "warn" "$tmpdir/warn.log"
check $? "can_read_conf invalid value should log a WARNING"

# invalid numeric value falls back to default
cat >"$tmpdir/invalid_num.conf" <<EOF
CAN_BITRATE=abc
EOF
can_read_conf "$tmpdir/invalid_num.conf" 2>/dev/null
if [[ "$CAN_BITRATE" == "250000" ]]; then check 0 "can_read_conf invalid numeric CAN_BITRATE should default to 250000, got $CAN_BITRATE"; else check 1 "can_read_conf invalid numeric CAN_BITRATE should default to 250000, got $CAN_BITRATE"; fi

# unknown key is ignored (no crash, no stray global)
cat >"$tmpdir/unknown.conf" <<EOF
CAN_BITRATE=500000
CAN_TOTALLY_UNKNOWN_KEY=nonsense
EOF
unset CAN_TOTALLY_UNKNOWN_KEY
can_read_conf "$tmpdir/unknown.conf" 2>/dev/null
rc=$?
if [[ $rc -eq 0 ]]; then check 0 "can_read_conf should return 0 even with an unknown key present"; else check 1 "can_read_conf should return 0 even with an unknown key present"; fi
if [[ "$CAN_BITRATE" == "500000" ]]; then check 0 "can_read_conf should still apply known keys alongside an unknown one"; else check 1 "can_read_conf should still apply known keys alongside an unknown one"; fi
if [[ -z "${CAN_TOTALLY_UNKNOWN_KEY:-}" ]]; then check 0 "can_read_conf should not create a variable for an unknown key"; else check 1 "can_read_conf should not create a variable for an unknown key"; fi

# N-M2: name/list keys must actually be validated for character type, not
# silently accepted (the validation function existed but was never wired
# into can_read_conf's dispatcher - verify it rejects a dangerous value).
cat >"$tmpdir/bad_name.conf" <<'EOF'
CAN_IFACES=can0;rm -rf /tmp
EOF
can_read_conf "$tmpdir/bad_name.conf" 2>"$tmpdir/warn2.log"
if [[ "$CAN_IFACES" == "can0 can1" ]]; then check 0 "can_read_conf should reject a CAN_IFACES value with invalid characters and fall back to default, got: $CAN_IFACES"; else check 1 "can_read_conf should reject a CAN_IFACES value with invalid characters and fall back to default, got: $CAN_IFACES"; fi
grep -qi "warn" "$tmpdir/warn2.log"
check $? "can_read_conf should log a WARNING for an invalid CAN_IFACES value"

cat >"$tmpdir/good_name.conf" <<'EOF'
CAN_IFACES=can0 can2
CAN_DEPENDENT_UNITS=myservice docker:mycontainer
EOF
can_read_conf "$tmpdir/good_name.conf" 2>/dev/null
if [[ "$CAN_IFACES" == "can0 can2" ]]; then check 0 "can_read_conf should accept a well-formed CAN_IFACES value, got: $CAN_IFACES"; else check 1 "can_read_conf should accept a well-formed CAN_IFACES value, got: $CAN_IFACES"; fi
if [[ "$CAN_DEPENDENT_UNITS" == "myservice docker:mycontainer" ]]; then check 0 "can_read_conf should accept a well-formed CAN_DEPENDENT_UNITS value, got: $CAN_DEPENDENT_UNITS"; else check 1 "can_read_conf should accept a well-formed CAN_DEPENDENT_UNITS value, got: $CAN_DEPENDENT_UNITS"; fi

# quotes removed
cat >"$tmpdir/quoted.conf" <<EOF
CAN_IFACES="can0 can1"
EOF
can_read_conf "$tmpdir/quoted.conf"
if [[ "$CAN_IFACES" == "can0 can1" && "$CAN_IFACES" != *'"'* ]]; then check 0 "can_read_conf quotes not removed, got: $CAN_IFACES"; else check 1 "can_read_conf quotes not removed, got: $CAN_IFACES"; fi

# defaults are reset BEFORE each read, not just carried over from a previous
# empty read (H3(a)): go from a non-default value back to default.
cat >"$tmpdir/override.conf" <<EOF
CAN_BITRATE=500000
EOF
can_read_conf "$tmpdir/override.conf"
if [[ "$CAN_BITRATE" == "500000" ]]; then check 0 "can_read_conf should apply CAN_BITRATE=500000 from file"; else check 1 "can_read_conf should apply CAN_BITRATE=500000 from file"; fi
touch "$tmpdir/missing.conf"
can_read_conf "$tmpdir/missing.conf"
if [[ "$CAN_BITRATE" == "250000" ]]; then check 0 "can_read_conf must reset CAN_BITRATE to the default (250000) when the next file doesn't override it, got $CAN_BITRATE"; else check 1 "can_read_conf must reset CAN_BITRATE to the default (250000) when the next file doesn't override it, got $CAN_BITRATE"; fi

# ========== can_lock/can_unlock tests (reentrant) ==========
echo "Testing can_lock/can_unlock..."
export CAN_TOOLS_RUN_DIR="$tmpdir/run"
_CAN_LOCK_DEPTH=0

can_lock 5
if [[ $_CAN_LOCK_DEPTH -eq 1 ]]; then check 0 "can_lock depth should be 1, got $_CAN_LOCK_DEPTH"; else check 1 "can_lock depth should be 1, got $_CAN_LOCK_DEPTH"; fi

can_lock 5
if [[ $_CAN_LOCK_DEPTH -eq 2 ]]; then check 0 "can_lock depth should be 2 (reentrant), got $_CAN_LOCK_DEPTH"; else check 1 "can_lock depth should be 2 (reentrant), got $_CAN_LOCK_DEPTH"; fi

can_unlock
if [[ $_CAN_LOCK_DEPTH -eq 1 ]]; then check 0 "can_unlock depth should be 1, got $_CAN_LOCK_DEPTH"; else check 1 "can_unlock depth should be 1, got $_CAN_LOCK_DEPTH"; fi

can_unlock
if [[ $_CAN_LOCK_DEPTH -eq 0 ]]; then check 0 "can_unlock depth should be 0, got $_CAN_LOCK_DEPTH"; else check 1 "can_unlock depth should be 0, got $_CAN_LOCK_DEPTH"; fi

# inner can_unlock must NOT release a lock held by an outer caller (the
# nested can_setup_iface-inside-a-rebind-procedure scenario from the design).
can_lock 5
(
    can_lock 5
    can_unlock
)
if [[ $_CAN_LOCK_DEPTH -eq 1 ]]; then check 0 "an inner can_lock/can_unlock pair (depth 2->1) must not drop the outer holder's lock"; else check 1 "an inner can_lock/can_unlock pair (depth 2->1) must not drop the outer holder's lock"; fi
can_unlock

# lock contention from another process
can_lock 5
timeout 1 bash -c 'flock -w 1 9 2>/dev/null' 9>"$tmpdir/run/lock" 2>/dev/null
if [[ $? -ne 0 ]]; then check 0 "lock should prevent other processes from acquiring it"; else check 1 "lock should prevent other processes from acquiring it"; fi
can_unlock

# once released, another process CAN acquire it
timeout 1 bash -c 'flock -w 1 9 2>/dev/null' 9>"$tmpdir/run/lock" 2>/dev/null
if [[ $? -eq 0 ]]; then check 0 "lock should be acquirable by another process once released"; else check 1 "lock should be acquirable by another process once released"; fi

# ========== can_run_bounded tests ==========
echo "Testing can_run_bounded..."

CAN_RUN_BOUNDED_PID=""

# fd 9 is not inherited by the child, including while the CALLER holds the
# lock (the earlier version of this test ran without the lock held, so it
# proved nothing about fd 9 actually being closed for a locked caller).
can_lock 5
can_run_bounded 2 bash -c '[[ ! -e /proc/self/fd/9 ]]' >/dev/null 2>&1
check $? "can_run_bounded child must not inherit fd 9 even while the caller holds can_lock"
can_unlock

# normal (fast) command succeeds and returns its exit code
can_run_bounded 2 sleep 0.1 >/dev/null 2>&1
check $? "can_run_bounded 2 sleep 0.1 should succeed (not time out)"

can_run_bounded 1 bash -c "exit 5" >/dev/null 2>&1
if [[ $? -eq 5 ]]; then check 0 "can_run_bounded should return the child's exit code"; else check 1 "can_run_bounded should return the child's exit code"; fi

# --- hang behavior (C1/C2/R2): the core safety property for the watchdog ---
CAN_RUN_BOUNDED_PID=""
t0=$SECONDS
can_run_bounded 1 sleep 100 >/dev/null 2>&1
rc=$?
elapsed=$((SECONDS - t0))
if [[ $rc -eq 124 ]]; then check 0 "can_run_bounded on a hanging child should return 124, got $rc"; else check 1 "can_run_bounded on a hanging child should return 124, got $rc"; fi
(( elapsed <= 3 )); check $? "can_run_bounded must not wait for the hung child (took ${elapsed}s for a 1s timeout)"
if [[ -n "$CAN_RUN_BOUNDED_PID" ]]; then check 0 "can_run_bounded must leave the hung child's pid in CAN_RUN_BOUNDED_PID for the caller to track"; else check 1 "can_run_bounded must leave the hung child's pid in CAN_RUN_BOUNDED_PID for the caller to track"; fi
_can_is_alive "$CAN_RUN_BOUNDED_PID"
check $? "the hung child (CAN_RUN_BOUNDED_PID) should still be alive (not reaped) right after the timeout"
hang_pids+=("$CAN_RUN_BOUNDED_PID")
prev_pid="$CAN_RUN_BOUNDED_PID"

# while that child is still alive, a second call must NOT spawn a new one -
# it returns 124 immediately and leaves CAN_RUN_BOUNDED_PID unchanged.
t0=$SECONDS
can_run_bounded 1 true >/dev/null 2>&1
rc=$?
elapsed=$((SECONDS - t0))
if [[ $rc -eq 124 ]]; then check 0 "can_run_bounded must refuse to start while the previous hung child is alive, got rc=$rc"; else check 1 "can_run_bounded must refuse to start while the previous hung child is alive, got rc=$rc"; fi
(( elapsed <= 1 )); check $? "can_run_bounded's refusal to start must be immediate (took ${elapsed}s)"
if [[ "$CAN_RUN_BOUNDED_PID" == "$prev_pid" ]]; then check 0 "can_run_bounded must not replace CAN_RUN_BOUNDED_PID while the old child is still alive"; else check 1 "can_run_bounded must not replace CAN_RUN_BOUNDED_PID while the old child is still alive"; fi

kill -9 "$prev_pid" 2>/dev/null || true
wait "$prev_pid" 2>/dev/null
# give the kernel a moment to reap/mark the process gone
for _ in 1 2 3 4 5; do _can_is_alive "$prev_pid" || break; sleep 0.2; done
! _can_is_alive "$prev_pid"
check $? "the hung child should be dead after being killed directly (test cleanup sanity check)"

# after the old child is gone, a new call is allowed to start
CAN_RUN_BOUNDED_PID=""
can_run_bounded 2 true >/dev/null 2>&1
check $? "can_run_bounded should be able to start a new child once the old hung one is gone"

# BASHPID collision test (低-4): concurrent subshells should not collide on
# temp file names. Each subshell has a unique BASHPID, so temp files should
# be named uniquely even when $$ is the same.
tmpdir_bashpid="$tmpdir/run_bashpid"
mkdir -p "$tmpdir_bashpid"
saved_run_dir="$CAN_TOOLS_RUN_DIR"
export CAN_TOOLS_RUN_DIR="$tmpdir_bashpid"

# Run two subshells in parallel, each calling can_run_bounded
(
    can_run_bounded 1 bash -c 'echo "subshell 1"' >"$tmpdir/out1.txt" 2>&1
)&
pid1=$!
(
    can_run_bounded 1 bash -c 'echo "subshell 2"' >"$tmpdir/out2.txt" 2>&1
)&
pid2=$!

wait "$pid1" "$pid2" 2>/dev/null

# Check that both subshells completed successfully and didn't collide
rc1=$(cat "$tmpdir/out1.txt" 2>/dev/null | grep -c "subshell 1")
rc2=$(cat "$tmpdir/out2.txt" 2>/dev/null | grep -c "subshell 2")
if [[ $rc1 -eq 1 ]]; then check 0 "can_run_bounded in subshell 1 should complete"; else check 1 "can_run_bounded in subshell 1 should complete"; fi
if [[ $rc2 -eq 1 ]]; then check 0 "can_run_bounded in subshell 2 should complete"; else check 1 "can_run_bounded in subshell 2 should complete"; fi

# Verify temp files don't collide by checking if only unique files exist
temp_files=$(ls -1 "$tmpdir_bashpid"/bounded_*.tmp 2>/dev/null | wc -l)
if [[ $temp_files -le 2 ]]; then check 0 "can_run_bounded should not create excessive temp files from collision (found $temp_files, expected 0-2 cleaned up)"; else check 1 "can_run_bounded created too many temp files (found $temp_files)"; fi

# Restore the original CAN_TOOLS_RUN_DIR for can_pause tests
export CAN_TOOLS_RUN_DIR="$saved_run_dir"

# ========== can_pin_name tests (tests/fakes/ip) ==========
echo "Testing can_pin_name..."

export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sysfs_pin"
export CAN_TOOLS_IP_CMD="$repo_root/tests/fakes/ip"
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake_pin"
mkdir -p "$tmpdir/sysfs_pin/bus/spi/devices/spi0.0/net/can0"
mkdir -p "$tmpdir/fake_pin/can0"
echo "restart_ms=100 berr=off fd=off admin=down" >"$tmpdir/fake_pin/can0/config"

# branch 1: name already correct -> 0, no ip calls needed beyond nothing
rm -f "$tmpdir/fake_pin/calls.log"
can_pin_name "spi0.0" "can0" >/dev/null 2>&1
check $? "can_pin_name should succeed (0) when the name already matches"

# branch 2: want is free -> rename (down then name), rc=0
rm -f "$tmpdir/fake_pin/calls.log"
mkdir -p "$tmpdir/sysfs_pin2/bus/spi/devices/spi0.0/net/can0"
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sysfs_pin2"
can_pin_name "spi0.0" "can7" >/dev/null 2>&1
check $? "can_pin_name should succeed (0) when the target name is free"
grep -q "link set can0 down" "$tmpdir/fake_pin/calls.log"
check $? "can_pin_name should bring the iface down before renaming (M1)"
grep -q "name can7" "$tmpdir/fake_pin/calls.log"
check $? "can_pin_name should call rename for can7"

# branch 3: want is taken by a different netdev -> collision, rc=2, no rename
mkdir -p "$tmpdir/fake_pin/eth0" "$tmpdir/fake_pin/can0"
echo "restart_ms=0 berr=off fd=off admin=down" >"$tmpdir/fake_pin/eth0/config"
echo "restart_ms=0 berr=off fd=off admin=down" >"$tmpdir/fake_pin/can0/config"
rm -f "$tmpdir/fake_pin/calls.log"
mkdir -p "$tmpdir/sysfs_pin3/bus/spi/devices/spi0.0/net/can0"
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sysfs_pin3"
can_pin_name "spi0.0" "eth0" >/dev/null 2>&1
if [[ $? -eq 2 ]]; then check 0 "can_pin_name should return 2 on name collision"; else check 1 "can_pin_name should return 2 on name collision"; fi
! grep -q "name eth0" "$tmpdir/fake_pin/calls.log"
check $? "can_pin_name should not call rename on collision"

# branch 4: rename itself fails (e.g. ip error) -> rc=1
mkdir -p "$tmpdir/fake_pin/fail"
touch "$tmpdir/fake_pin/fail/ip"
mkdir -p "$tmpdir/sysfs_pin4/bus/spi/devices/spi0.0/net/can0"
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sysfs_pin4"
can_pin_name "spi0.0" "can11" >/dev/null 2>&1
if [[ $? -eq 1 ]]; then check 0 "can_pin_name should return 1 when the rename command itself fails"; else check 1 "can_pin_name should return 1 when the rename command itself fails"; fi
rm -f "$tmpdir/fake_pin/fail/ip"

unset CAN_TOOLS_IP_CMD CAN_TOOLS_FAKE_DIR

# ========== can_pause tests ==========
echo "Testing can_pause..."
export CAN_TOOLS_FAKE_TIME_FILE="$tmpdir/time.txt"
echo "1000" >"$CAN_TOOLS_FAKE_TIME_FILE"

can_pause 1
local_deadline=$(cat "$tmpdir/run/watchdog.pause" 2>/dev/null)
if [[ "$local_deadline" == "1060" ]]; then check 0 "can_pause deadline should be 1060, got $local_deadline"; else check 1 "can_pause deadline should be 1060, got $local_deadline"; fi

can_pause_active 2>/dev/null
check $? "can_pause_active should return true within deadline"

echo "2000" >"$CAN_TOOLS_FAKE_TIME_FILE"
! can_pause_active 2>/dev/null
check $? "can_pause_active should return false after deadline"

# L3: validation of pause duration / deadline contents
can_pause "notanumber" 2>/dev/null
if [[ $? -ne 0 ]]; then check 0 "can_pause should reject a non-numeric duration"; else check 1 "can_pause should reject a non-numeric duration"; fi

echo "garbage" >"$tmpdir/run/watchdog.pause"
can_pause_active 2>/dev/null
if [[ $? -ne 0 ]]; then check 0 "can_pause_active should treat a non-numeric pause file as inactive, not crash"; else check 1 "can_pause_active should treat a non-numeric pause file as inactive, not crash"; fi

echo ""
echo "Core tests: $pass passed, $fail failed"
exit $fail
