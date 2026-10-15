#!/bin/bash
# tests/test_watchdog_flush.sh - §1a TX flush on ERROR-WARNING/ERROR-PASSIVE.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/can_tools_lib.bash"

tmpdir=$(mktemp -d)
cleanup() {
    pkill -9 -f can_tools_unbind 2>/dev/null || true
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

export CAN_TOOLS_RUN_DIR="$tmpdir/run"
export CAN_TOOLS_STATE_DIR="$tmpdir/state"
export CAN_TOOLS_SYSFS_ROOT="$tmpdir/sysfs"
export CAN_TOOLS_FAKE_DIR="$tmpdir/fake"
export CAN_TOOLS_IP_CMD="$repo_root/tests/fakes/ip"
export CAN_TOOLS_JOURNALCTL_CMD="$repo_root/tests/fakes/journalctl"
export CAN_TOOLS_SYSTEMCTL_CMD="$repo_root/tests/fakes/systemctl"
export CAN_TOOLS_DOCKER_CMD="$repo_root/tests/fakes/docker"
export CAN_TOOLS_CONF="$tmpdir/conf"
export CAN_TOOLS_FAKE_TIME_FILE="$tmpdir/time"
export CAN_TOOLS_TEST_SPI_MAP="spi0.0:can0 spi1.0:can1"

mkdir -p "$CAN_TOOLS_FAKE_DIR/can0" "$CAN_TOOLS_FAKE_DIR/can1"
# NOTE: can_read_conf() resets every WD_*/CAN_* key from the lib's defaults
# on every call; it never reads the process environment for them. All
# tuning for the watchdog under test must live in this conf FILE.
cat >"$CAN_TOOLS_CONF" <<'EOF'
CAN_RESTART_MS=0
CAN_BERR_REPORTING=off
CAN_FD=off
WD_STALE_TX_FLUSH_S=2
WD_FLUSH_BACKOFF_MAX_S=30
EOF

# M1: can_watchdog.sh's startup reconciliation now decides "needs bind"
# from the presence/absence of a /sys/bus/spi/devices/<spidev>/driver
# symlink (matching real kernel sysfs), not from whether a netdev happens
# to be visible yet. tests/fakes/mk_sysfs.sh (shared, not modified by this
# PR) does not model that symlink, so each write_scenario call here
# synthesizes it itself for every spidev that currently has a netdev under
# it - exactly mirroring what the real kernel does for an actually-bound
# device. This is local test fixture setup, not a change to tests/fakes/.
_sync_driver_links() {
    local d
    for d in "$CAN_TOOLS_SYSFS_ROOT"/bus/spi/devices/*/; do
        [[ -d "$d" ]] || continue
        if [[ -n "$(ls -A "$d/net" 2>/dev/null)" ]]; then
            [[ -e "${d}driver" ]] || ln -s "$CAN_TOOLS_SYSFS_ROOT/bus/spi/drivers/mcp251xfd" "${d}driver"
        fi
    done
}

write_scenario() {
    local tick="$1"
    shift
    local f="$tmpdir/scenario.txt"
    : >"$f"
    local line
    for line in "$@"; do
        echo "$tick $line" >>"$f"
    done
    "$repo_root/tests/fakes/mk_sysfs.sh" "$f" "$tick"
    _sync_driver_links
}

echo "=== quiet Δ for < WD_STALE_TX_FLUSH_S does not flush ==="
echo "ERROR-PASSIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo "ERROR-ACTIVE" >"$CAN_TOOLS_FAKE_DIR/can1/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can1/config"

# L3: WD_STALE_TX_FLUSH_S is a CYCLE count (§5b: "全 Δ=0 が 2 周続くと TX
# flush"), not an elapsed-seconds threshold. The very first time an iface is
# ever processed, Δ is forced to 0 (no baseline yet), which itself counts as
# the 1st quiet cycle - so only 1 cycle of genuine quiet has been observed
# after this first call, not yet the 2 the default WD_STALE_TX_FLUSH_S=2
# requires.
echo 1000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 1 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1   # 1st quiet cycle (baseline + forced Δ=0)
! grep -q "link set can0" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "flush must not fire before WD_STALE_TX_FLUSH_S quiet cycles have elapsed"

echo "=== Δ=0 held for >= WD_STALE_TX_FLUSH_S cycles -> flush fires (first time, no backoff wait) ==="
echo 1001 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 2 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1   # 2nd quiet cycle -> threshold reached
grep -q "link set can0 down" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "first flush should execute once the stale threshold is reached"
grep -q "link set can0 up" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "flush brings the iface back up"

echo "=== fifo activity takes priority over flush (stall path, not flush) ==="
rm -f "$CAN_TOOLS_FAKE_DIR/calls.log"
rm -rf "$CAN_TOOLS_RUN_DIR" "$CAN_TOOLS_STATE_DIR"
echo "ERROR-PASSIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"
echo 2000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 10 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
echo 2001 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 11 "can0 50 50 5 0 3" "can1 50 0 0 0 4"   # rxfifo growing, rx frozen
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
echo 2003 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 12 "can0 50 50 10 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
! grep -q "link set can0" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "flush condition requires Δrxfifo=Δtxfifo=0; with fifo activity it must not flush (stall path owns this instead)"

echo "=== flush backoff gating: a pending backoff window blocks the next flush until it elapses ==="
# WD_STALE_TX_FLUSH_S (2 cycles) is itself longer than the first backoff
# step (1s), so the gate only becomes observable once backoff has escalated
# past the natural re-accumulation time. Rather than looping real flushes
# to reach that point (slow and timing-fragile), seed the per-iface state
# FILE directly (the same wd_<if>.state file can_watchdog.sh's own
# _wd_state_load/_wd_state_dump read and write - see can_watchdog.sh's H4
# comment); each --once invocation is a fresh process, so there is no
# shared in-memory array to poke, only the file.
_seed_state() {
    local ifn="$1" key="$2" val="$3"
    local f="$CAN_TOOLS_RUN_DIR/wd_${ifn}.state"
    mkdir -p "$(dirname "$f")"
    touch "$f"
    grep -v "^${key}=" "$f" >"$f.tmp" 2>/dev/null || true
    echo "${key}=${val}" >>"$f.tmp"
    mv "$f.tmp" "$f"
}

rm -f "$CAN_TOOLS_FAKE_DIR/calls.log"
rm -rf "$CAN_TOOLS_RUN_DIR" "$CAN_TOOLS_STATE_DIR"
echo "ERROR-PASSIVE" >"$CAN_TOOLS_FAKE_DIR/can0/state"
echo "restart_ms=0 berr=off fd=off admin=up" >"$CAN_TOOLS_FAKE_DIR/can0/config"

echo 4000 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 30 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1   # seed PREV_* baseline

# Simulate "we already flushed once, backoff for the NEXT one is 4s, and
# that happened 2s ago" - i.e. 2s still remain before the gate opens.
_seed_state can0 FLUSH_LAST_TS 4000
_seed_state can0 FLUSH_BACKOFF_S 4
_seed_state can0 FLUSH_PENDING_TS 4007

echo 4004 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 31 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
echo 4006 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 32 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
! grep -q "link set can0 up" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "flush must stay gated while now < FLUSH_PENDING_TS, even once the stale threshold is independently met"

echo 4007 >"$CAN_TOOLS_FAKE_TIME_FILE"
write_scenario 33 "can0 50 50 0 0 3" "can1 50 0 0 0 4"
"$repo_root/can_watchdog.sh" --once >/dev/null 2>&1
grep -q "link set can0 up" "$CAN_TOOLS_FAKE_DIR/calls.log" 2>/dev/null
check $? "flush should fire once now >= FLUSH_PENDING_TS"

echo ""
echo "Flush tests: $pass passed, $fail failed"
exit $fail
