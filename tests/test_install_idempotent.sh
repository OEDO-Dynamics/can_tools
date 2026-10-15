#!/bin/bash
# test_install_idempotent.sh - Actually run install.sh against a scratch tree
# (never the real filesystem) and verify its behaviour per Issue #9 §4 and
# the PR-A2 review (C2, H1, H2, M1-M6).

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fakes_dir="$repo_root/tests/fakes"

tmpdir=$(mktemp -d)
cleanup() { rm -rf "$tmpdir"; }
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

# Every call below runs the real install.sh, pointed entirely at a scratch
# tree via env vars - no sudo, no real /opt or /etc touched.
run_install() {
    local opt="$1" systemd="$2" tmpfiles="$3" run="$4" state="$5" fake="$6"
    shift 6
    mkdir -p "$fake"
    env -i PATH="$fakes_dir:/usr/bin:/bin" \
        INSTALL_OPT_DIR="$opt" SYSTEMD_DIR="$systemd" TMPFILES_DIR="$tmpfiles" \
        CAN_TOOLS_RUN_DIR="$run" CAN_TOOLS_STATE_DIR="$state" \
        CAN_TOOLS_FAKE_DIR="$fake" CAN_TOOLS_SYSTEMCTL_CMD="$fakes_dir/systemctl" \
        bash "$repo_root/install.sh" "$@"
}

# ---------------------------------------------------------------------
# Scenario 1: fresh install, then a second install should report no diffs
# via --check (5c-1), and systemctl must never see restart/stop/start for
# the units install.sh manages (M4; can_monitor's stop/disable is a
# separate, deliberate exception checked in scenario 3).
# ---------------------------------------------------------------------
echo "Scenario 1: fresh install + idempotent --check"
s1="$tmpdir/s1"
mkdir -p "$s1/opt" "$s1/systemd" "$s1/tmpfiles" "$s1/run" "$s1/state" "$s1/fake"

run_install "$s1/opt" "$s1/systemd" "$s1/tmpfiles" "$s1/run" "$s1/state" "$s1/fake" >"$tmpdir/s1_install.log" 2>&1
rc=$?
(( rc == 0 )); check $? "first install should succeed (rc=$rc)"

if [[ -f "$s1/opt/can_tools/can_tools_lib.bash" ]]; then rc=0; else rc=1; fi
check "$rc" "lib should be installed"
if [[ -f "$s1/opt/can_tools/can_tools.conf" ]]; then rc=0; else rc=1; fi
check "$rc" "can_tools.conf should be created on first install"
if [[ -f "$s1/opt/can_tools/can_tools.conf.example" ]]; then rc=0; else rc=1; fi
check "$rc" "can_tools.conf.example should be installed under /opt (M6)"
if [[ -f "$s1/systemd/canhat_fd_rename.service" && ! -L "$s1/systemd/canhat_fd_rename.service" ]]; then rc=0; else rc=1; fi
check "$rc" "canhat_fd_rename.service should be a real file"
if [[ -f "$s1/systemd/canhat_fd_setup.service" && ! -L "$s1/systemd/canhat_fd_setup.service" ]]; then rc=0; else rc=1; fi
check "$rc" "canhat_fd_setup.service should be a real file"
if [[ -d "$s1/run" && -d "$s1/state" ]]; then rc=0; else rc=1; fi
check "$rc" "runtime/state directories should exist (M3)"
if [[ -f "$s1/tmpfiles/can_tools.conf" ]]; then rc=0; else rc=1; fi
check "$rc" "tmpfiles.d drop-in should be installed (M3)"

if ! grep -Eq '(^| )(restart|stop|start)( |$)' "$s1/fake/calls.log"; then rc=0; else rc=1; fi
check "$rc" "systemctl must not be asked to restart/stop/start any managed unit on first install (M4): $(cat "$s1/fake/calls.log")"
grep -qx "daemon-reload" "$s1/fake/calls.log"
check $? "systemctl daemon-reload should be called"
daemon_reload_count=$(grep -cx "daemon-reload" "$s1/fake/calls.log")
if [[ "$daemon_reload_count" == "1" ]]; then rc=0; else rc=1; fi
check "$rc" "daemon-reload should be called exactly once, not per unit (M2), got $daemon_reload_count"
grep -q "^enable canhat_fd_setup.service$" "$s1/fake/calls.log"
check $? "canhat_fd_setup.service should be enabled (M2)"
grep -q "^enable canhat_fd_rename.service$" "$s1/fake/calls.log"
check $? "canhat_fd_rename.service should be enabled (M2)"

# Second run: --check must report no differences and rc 0 (5c-1), and must
# not create/modify anything.
before_checksum=$(find "$s1/opt" "$s1/systemd" -type f -exec cat {} + | cksum)
run_install "$s1/opt" "$s1/systemd" "$s1/tmpfiles" "$s1/run" "$s1/state" "$s1/fake" --check >"$tmpdir/s1_check.log" 2>&1
rc=$?
(( rc == 0 )); check $? "second run: --check should exit 0 when nothing differs, got rc=$rc: $(cat "$tmpdir/s1_check.log")"
after_checksum=$(find "$s1/opt" "$s1/systemd" -type f -exec cat {} + | cksum)
if [[ "$before_checksum" == "$after_checksum" ]]; then rc=0; else rc=1; fi
check "$rc" "--check must not modify any installed file"

# ---------------------------------------------------------------------
# Scenario 2: empty destination + --check must report a diff (rc != 0) and
# must not create anything (H1).
# ---------------------------------------------------------------------
echo "Scenario 2: --check against an empty destination"
s2="$tmpdir/s2"
mkdir -p "$s2/opt" "$s2/systemd" "$s2/tmpfiles" "$s2/run" "$s2/state" "$s2/fake"

run_install "$s2/opt" "$s2/systemd" "$s2/tmpfiles" "$s2/run" "$s2/state" "$s2/fake" --check >"$tmpdir/s2_check.log" 2>&1
rc=$?
(( rc != 0 )); check $? "--check against an empty destination should report differences (rc!=0), got $rc"
if [[ ! -e "$s2/opt/can_tools" || -z "$(ls -A "$s2/opt/can_tools" 2>/dev/null)" ]]; then rc=0; else rc=1; fi
check "$rc" "--check must not create any file under an empty destination"
if [[ ! -s "$s2/fake/calls.log" ]]; then rc=0; else rc=1; fi
check "$rc" "--check must not call systemctl at all"

# For a file that already exists but differs, --check must print an actual
# unified diff (H1), not just "would install".
s2b="$tmpdir/s2b"
mkdir -p "$s2b/opt/can_tools" "$s2b/systemd" "$s2b/tmpfiles" "$s2b/run" "$s2b/state" "$s2b/fake"
echo "stale content, not the repo's lib" >"$s2b/opt/can_tools/can_tools_lib.bash"
run_install "$s2b/opt" "$s2b/systemd" "$s2b/tmpfiles" "$s2b/run" "$s2b/state" "$s2b/fake" --check >"$tmpdir/s2b_check.log" 2>&1
rc=$?
(( rc != 0 )); check $? "--check against a changed existing file should report a difference"
grep -q "^-stale content, not the repo's lib$" "$tmpdir/s2b_check.log"
check $? "--check should print a unified diff for a changed file (H1), log was: $(cat "$tmpdir/s2b_check.log")"
grep -qx "stale content, not the repo's lib" "$s2b/opt/can_tools/can_tools_lib.bash"
check $? "--check must not actually overwrite the changed file"

# ---------------------------------------------------------------------
# Scenario 3: existing conf must never be overwritten, even when its
# content differs from the example (§4-2).
# ---------------------------------------------------------------------
echo "Scenario 3: existing can_tools.conf is preserved"
s3="$tmpdir/s3"
mkdir -p "$s3/opt/can_tools" "$s3/systemd" "$s3/tmpfiles" "$s3/run" "$s3/state" "$s3/fake"
echo "CAN_IFACES=can0" >"$s3/opt/can_tools/can_tools.conf"

run_install "$s3/opt" "$s3/systemd" "$s3/tmpfiles" "$s3/run" "$s3/state" "$s3/fake" >/dev/null 2>&1
rc=$?
(( rc == 0 )); check $? "install over an existing conf should still succeed"
grep -qx "CAN_IFACES=can0" "$s3/opt/can_tools/can_tools.conf"
check $? "existing can_tools.conf content must be preserved verbatim"

# ---------------------------------------------------------------------
# Scenario 4: a unit deployed as a symlink straight into /opt/can_tools
# (pre-A2 style) must become a real file, and can_monitor must be removed
# without ever down/up-ing a CAN interface (H2, M1).
# ---------------------------------------------------------------------
echo "Scenario 4: legacy symlinked unit + can_monitor removal"
s4="$tmpdir/s4"
mkdir -p "$s4/opt/can_tools" "$s4/systemd" "$s4/tmpfiles" "$s4/run" "$s4/state" "$s4/fake"
echo "fake unit content" >"$s4/opt/can_tools/canhat_fd_setup.service"
ln -s "$s4/opt/can_tools/canhat_fd_setup.service" "$s4/systemd/canhat_fd_setup.service"

touch "$s4/opt/can_tools/can_monitor.sh"
echo "fake timer" >"$s4/opt/can_tools/can_monitor.timer"
ln -s "$s4/opt/can_tools/can_monitor.timer" "$s4/systemd/can_monitor.timer"
echo "fake monitor service" >"$s4/systemd/can_monitor.service"

run_install "$s4/opt" "$s4/systemd" "$s4/tmpfiles" "$s4/run" "$s4/state" "$s4/fake" >"$tmpdir/s4_install.log" 2>&1
rc=$?
(( rc == 0 )); check $? "install with a legacy symlink + can_monitor present should still succeed"

if [[ -f "$s4/systemd/canhat_fd_setup.service" && ! -L "$s4/systemd/canhat_fd_setup.service" ]]; then rc=0; else rc=1; fi
check "$rc" "symlinked unit must be replaced with a real file (M1)"
cmp -s "$repo_root/canhat_fd_setup.service" "$s4/systemd/canhat_fd_setup.service"
check $? "replaced unit content must match the repo's unit"

if [[ ! -e "$s4/systemd/can_monitor.timer" && ! -L "$s4/systemd/can_monitor.timer" ]]; then rc=0; else rc=1; fi
check "$rc" "can_monitor.timer link must be removed (H2)"
if [[ ! -e "$s4/systemd/can_monitor.service" ]]; then rc=0; else rc=1; fi
check "$rc" "can_monitor.service must be removed (H2)"
if [[ ! -e "$s4/opt/can_tools/can_monitor.sh" ]]; then rc=0; else rc=1; fi
check "$rc" "can_monitor.sh must be removed from /opt/can_tools (H2)"
if [[ ! -e "$s4/opt/can_tools/can_monitor.timer" ]]; then rc=0; else rc=1; fi
check "$rc" "can_monitor.timer must be removed from /opt/can_tools (H2)"

if ! grep -qi "ip link" "$s4/fake/calls.log" 2>/dev/null; then rc=0; else rc=1; fi
check "$rc" "install.sh must never call ip (no CAN down/up), even while removing can_monitor"
grep -q "^stop can_monitor.timer$" "$s4/fake/calls.log"
check $? "can_monitor.timer should be stopped before removal"
grep -q "^disable can_monitor.timer$" "$s4/fake/calls.log"
check $? "can_monitor.timer should be disabled before removal"
grep -q "^stop can_monitor.service$" "$s4/fake/calls.log"
check $? "can_monitor.service should be stopped before removal"

# A second run after scenario 4 should be a clean no-op via --check.
run_install "$s4/opt" "$s4/systemd" "$s4/tmpfiles" "$s4/run" "$s4/state" "$s4/fake" --check >"$tmpdir/s4_check.log" 2>&1
rc=$?
(( rc == 0 )); check $? "scenario 4 should be idempotent after the fix-up, got rc=$rc: $(cat "$tmpdir/s4_check.log")"

# ---------------------------------------------------------------------
# Scenario 5: install.sh refuses to run for real (non-test destinations)
# as a non-root user, but does not require root against a scratch tree
# (M4). We only check the non-destructive, scratch-tree half here -
# running it against the real / is exactly what we must never do in a test.
# ---------------------------------------------------------------------
echo "Scenario 5: root check is skipped for a scratch destination"
[[ "$(id -u)" -ne 0 ]]
if [[ $? -eq 0 ]]; then
    s5="$tmpdir/s5"
    mkdir -p "$s5/opt" "$s5/systemd" "$s5/tmpfiles" "$s5/run" "$s5/state" "$s5/fake"
    run_install "$s5/opt" "$s5/systemd" "$s5/tmpfiles" "$s5/run" "$s5/state" "$s5/fake" >/dev/null 2>&1
    rc=$?
    (( rc == 0 )); check $? "install.sh must not require root when every destination is overridden, got rc=$rc"
else
    echo "  (running as root - skipping non-root-specific assertion)"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
