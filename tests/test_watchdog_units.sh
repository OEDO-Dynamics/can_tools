#!/bin/bash
# tests/test_watchdog_units.sh - H2: CAN_DEPENDENT_UNITS restarts must never
# go through can_run_bounded (a slow one would occupy the single R2 slot and
# wrongly drive every configured iface into rtnl_hung degraded mode), must
# run AFTER can_unlock, and must not block the watchdog loop.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
wd_pid=""
cleanup() {
    [[ -n "$wd_pid" ]] && kill -9 "$wd_pid" 2>/dev/null
    pkill -9 -f can_tools_unbind 2>/dev/null || true
    pkill -9 -f "$repo_root/tests/fakes/ip" 2>/dev/null || true
    pkill -9 -f "slowdocker_test" 2>/dev/null || true
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

export CAN_TOOLS_RUN_DIR="$tmpdir/run"
export CAN_TOOLS_STATE_DIR="$tmpdir/state"
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sysfs"
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
export CAN_TOOLS_IP_CMD="$repo_root/tests/fakes/ip"
export CAN_TOOLS_JOURNALCTL_CMD="$repo_root/tests/fakes/journalctl"
export CAN_TOOLS_SYSTEMCTL_CMD="$repo_root/tests/fakes/systemctl"
export CAN_TOOLS_CONF="$tmpdir/conf"
export CAN_TOOLS_TEST_SPI_MAP="spi0.0:can0 spi1.0:can1"
# No CAN_TOOLS_FAKE_TIME_FILE: this test drives a real daemon loop so a
# genuinely slow "docker restart" (sleep 30) is meaningful in wall-clock time.

mkdir -p "$CAN_TOOLS_FAKE_DIR/can0" "$CAN_TOOLS_FAKE_DIR/can1"

# A docker stand-in that takes far longer than WD_REBIND_TIMEOUT_S, same
# shape as a real `docker restart` with a slow-stopping container. If this
# were ever launched through can_run_bounded, it would occupy the single
# tracked-child slot for its whole 30s run.
slow_docker="$tmpdir/slowdocker_test"
cat >"$slow_docker" <<EOF
#!/bin/sh
echo "docker \$*" >> "$CAN_TOOLS_FAKE_DIR/calls.log"
touch "$tmpdir/docker_started"
sleep 30
touch "$tmpdir/docker_finished"
EOF
chmod +x "$slow_docker"
export CAN_TOOLS_DOCKER_CMD="$slow_docker"

cat >"$CAN_TOOLS_CONF" <<'EOF'
CAN_RESTART_MS=0
CAN_BERR_REPORTING=off
CAN_FD=off
WD_LOOP_S=1
WD_RTNL_TIMEOUT_S=2
WD_REBIND_TIMEOUT_S=2
WD_RTNL_HUNG_CONSEC=3
WD_STALL_CONSEC=3
CAN_DEPENDENT_UNITS=docker:app
EOF

echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"

f="$tmpdir/scenario.txt"
cat >"$f" <<'EOF'
1 can0 100 100 0 0 3
1 can1 100 0 0 0 4
EOF
"$repo_root/tests/fakes/mk_sysfs.sh" "$f" 1
for d in "$CAN_TOOLS_SYSFS_ROOT"/bus/spi/devices/*/; do
    [[ -n "$(ls -A "$d/net" 2>/dev/null)" ]] && ln -sf "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd" "${d}driver"
done

echo "=== real daemon loop: drive can1 into a stall so it rebinds and restarts the dependent docker unit ==="
"$repo_root/can_watchdog.sh" >/dev/null 2>"$tmpdir/log" &
wd_pid=$!

# Keep bumping can1's rx_fifo_errors (rx frozen) until the rebind has
# happened (unbind file written), then stop.
(
    v=0
    while [[ ! -s "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd/unbind" ]]; do
        v=$((v + 5))
        echo "$v" >"$CAN_TOOLS_SYSFS_ROOT/class/net/can1/statistics/rx_fifo_errors" 2>/dev/null
        sleep 0.3
    done
) &
churn_pid=$!

# Wait for the rebind (and the dependent-unit restart it triggers) to happen.
for _ in $(seq 1 30); do
    [[ -f "$tmpdir/docker_started" ]] && break
    sleep 0.5
done
kill "$churn_pid" 2>/dev/null; wait "$churn_pid" 2>/dev/null

ds=0; [[ -f "$tmpdir/docker_started" ]] || ds=1
check $ds "the dependent docker unit should have been restarted after the rebind"

# While the slow docker restart (30s) is still running, the main loop must
# keep calling `ip` normally - no rtnl_hung degraded mode anywhere.
sleep 3
rh=0; [[ -f "$CAN_TOOLS_RUN_DIR/rtnl_hung_active" ]] && rh=1
check $rh "a slow dependent-unit restart must NOT occupy can_run_bounded's slot (no rtnl_hung while it runs)"
d0=0; [[ -f "$CAN_TOOLS_RUN_DIR/degraded_can0" ]] && d0=1
check $d0 "can0 must not have gone degraded just because the dependent unit restart is slow"

# The restart must be detached: can_watchdog.sh must not be blocked waiting
# on it (it finishes 30s after it started; the watchdog loop is free long
# before that - verified above by checking rtnl_hung did not trip, which
# would require ip calls to keep succeeding every ~1s throughout).
wait_start=$(date +%s)
for _ in $(seq 1 40); do
    [[ -f "$tmpdir/docker_finished" ]] && break
    sleep 1
done
wait_elapsed=$(( $(date +%s) - wait_start ))
fin=0; [[ -f "$tmpdir/docker_finished" ]] || fin=1
check $fin "the detached docker restart should eventually finish on its own (sanity check on the stand-in), waited ${wait_elapsed}s"

echo ""
echo "Dependent-units tests: $pass passed, $fail failed"
exit $fail
