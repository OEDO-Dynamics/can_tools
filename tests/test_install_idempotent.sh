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
#
# CAN_TOOLS_MONITOR_STOP_TIMEOUT_S=0: belt-and-suspenders against a slow
# test - `_wait_inactive` reads `systemctl show -p ActiveState --value`,
# which tests/fakes/systemctl doesn't model (empty stdout), so it already
# falls through to "not activating" and returns immediately without
# sleeping; forcing the timeout to 0 just makes that explicit. It is still
# never a `stop`, which is the property M-new2 cares about.
run_install() {
    local opt="$1" systemd="$2" tmpfiles="$3" run="$4" state="$5" fake="$6"
    shift 6
    mkdir -p "$fake"
    env -i PATH="$fakes_dir:/usr/bin:/bin" \
        INSTALL_OPT_DIR="$opt" SYSTEMD_DIR="$systemd" TMPFILES_DIR="$tmpfiles" \
        CAN_TOOLS_RUN_DIR="$run" CAN_TOOLS_STATE_DIR="$state" \
        CAN_TOOLS_FAKE_DIR="$fake" CAN_TOOLS_SYSTEMCTL_CMD="$fakes_dir/systemctl" \
        CAN_TOOLS_MONITOR_STOP_TIMEOUT_S=0 \
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
# --check does call systemctl is-enabled now (L-new1: read-only, reports
# enable-state diffs), but must never mutate anything (enable/disable/
# stop/start/daemon-reload).
if [[ ! -s "$s2/fake/calls.log" ]] || ! grep -qvx "is-enabled .*" "$s2/fake/calls.log"; then rc=0; else rc=1; fi
check "$rc" "--check must only call systemctl is-enabled (read-only), never mutate anything: $(cat "$s2/fake/calls.log" 2>/dev/null)"

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

# M-new2: can_monitor.service is a oneshot that itself down/up's an
# interface; install.sh must wait for it to go inactive instead of sending
# it a stop (which could land mid-down/up and leave the interface down).
if ! grep -q "^stop can_monitor.service$" "$s4/fake/calls.log"; then rc=0; else rc=1; fi
check "$rc" "can_monitor.service must NEVER be sent a stop (M-new2): $(cat "$s4/fake/calls.log")"
grep -q "^show -p ActiveState --value can_monitor.service$" "$s4/fake/calls.log"
check $? "can_monitor.service's ActiveState should be polled before disabling it (M-new2/L-r3a)"
grep -q "^disable can_monitor.service$" "$s4/fake/calls.log"
check $? "can_monitor.service should still be disabled"

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
if [[ "$(id -u)" -ne 0 ]]; then
    s5="$tmpdir/s5"
    mkdir -p "$s5/opt" "$s5/systemd" "$s5/tmpfiles" "$s5/run" "$s5/state" "$s5/fake"
    run_install "$s5/opt" "$s5/systemd" "$s5/tmpfiles" "$s5/run" "$s5/state" "$s5/fake" >/dev/null 2>&1
    rc=$?
    (( rc == 0 )); check $? "install.sh must not require root when every destination is overridden, got rc=$rc"
else
    echo "  (running as root - skipping non-root-specific assertion)"
fi

# ---------------------------------------------------------------------
# Scenario 6 (C-new1/M-r3): canhat_plus_* units must NEVER be installed or
# enabled by this script, under any invocation - §4-3 only lists
# canhat_fd_rename/setup and (once it exists) can_watchdog as install/enable
# targets, and canhat_plus_setup.service has no After=/Before=/lock
# relationship with canhat_fd_setup.service, so enabling both on one
# machine lets them race (an earlier --plus flag that installed+enabled
# both side by side was removed for exactly this reason - M-r3). HAT+ is
# out of scope for Issue #9 §2b; it has no flag here at all, not even a
# no-op one, so a stray "--plus" on the command line is just an unrecognized
# argument (ignored, like any other).
# ---------------------------------------------------------------------
echo "Scenario 6: canhat_plus_* is never installed or enabled, under any invocation (C-new1/M-r3)"
for extra_arg in "" "--plus" "--check"; do
    s6="$tmpdir/s6_${extra_arg:-none}"
    mkdir -p "$s6/opt" "$s6/systemd" "$s6/tmpfiles" "$s6/run" "$s6/state" "$s6/fake"

    if [[ -n "$extra_arg" ]]; then
        run_install "$s6/opt" "$s6/systemd" "$s6/tmpfiles" "$s6/run" "$s6/state" "$s6/fake" "$extra_arg" >/dev/null 2>&1
    else
        run_install "$s6/opt" "$s6/systemd" "$s6/tmpfiles" "$s6/run" "$s6/state" "$s6/fake" >/dev/null 2>&1
    fi

    if [[ ! -e "$s6/systemd/canhat_plus_setup.service" ]]; then rc=0; else rc=1; fi
    check "$rc" "canhat_plus_setup.service must never be installed (invocation: install.sh $extra_arg) (C-new1/M-r3)"
    if [[ ! -e "$s6/systemd/canhat_plus_rename.service" ]]; then rc=0; else rc=1; fi
    check "$rc" "canhat_plus_rename.service must never be installed (invocation: install.sh $extra_arg) (C-new1/M-r3)"
    if ! grep -qi "canhat_plus" "$s6/fake/calls.log" 2>/dev/null; then rc=0; else rc=1; fi
    check "$rc" "systemctl must never be told about canhat_plus_* (invocation: install.sh $extra_arg) (C-new1/M-r3): $(cat "$s6/fake/calls.log" 2>/dev/null)"
done

s6c="$tmpdir/s6c"
mkdir -p "$s6c/opt" "$s6c/systemd" "$s6c/tmpfiles" "$s6c/run" "$s6c/state" "$s6c/fake"
run_install "$s6c/opt" "$s6c/systemd" "$s6c/tmpfiles" "$s6c/run" "$s6c/state" "$s6c/fake" >/dev/null 2>&1
if [[ -f "$s6c/opt/can_tools/canhat_plus_setup.bash" ]]; then rc=0; else rc=1; fi
check "$rc" "the canhat_plus_* scripts themselves are still copied (harmless, never run on their own)"

# ---------------------------------------------------------------------
# Scenario 7 (L-new1): --check should also flag a unit that is installed
# but not enabled, not just file-content differences.
# ---------------------------------------------------------------------
echo "Scenario 7: --check reports a not-yet-enabled unit (L-new1)"
s7="$tmpdir/s7"
mkdir -p "$s7/opt" "$s7/systemd" "$s7/tmpfiles" "$s7/run" "$s7/state" "$s7/fake"
# A systemctl stub whose is-enabled always fails (disabled), everything else
# behaves like tests/fakes/systemctl (log + succeed) - this is a small,
# self-contained stub for this one test, not a change to tests/fakes/.
cat >"$tmpdir/systemctl_disabled" <<EOF
#!/bin/bash
fake_dir="\${CAN_TOOLS_FAKE_DIR:-.}"
echo "\$@" >>"\$fake_dir/calls.log" 2>/dev/null || true
[[ "\$1" == "is-enabled" ]] && exit 1
exit 0
EOF
chmod +x "$tmpdir/systemctl_disabled"

env -i PATH="$fakes_dir:/usr/bin:/bin" \
    INSTALL_OPT_DIR="$s7/opt" SYSTEMD_DIR="$s7/systemd" TMPFILES_DIR="$s7/tmpfiles" \
    CAN_TOOLS_RUN_DIR="$s7/run" CAN_TOOLS_STATE_DIR="$s7/state" \
    CAN_TOOLS_FAKE_DIR="$s7/fake" CAN_TOOLS_SYSTEMCTL_CMD="$tmpdir/systemctl_disabled" \
    CAN_TOOLS_MONITOR_STOP_TIMEOUT_S=0 \
    bash "$repo_root/install.sh" >/dev/null 2>&1
rc=$?
(( rc == 0 )); check $? "first (real) install with the always-disabled stub should still succeed"

run_check_log="$tmpdir/s7_check.log"
env -i PATH="$fakes_dir:/usr/bin:/bin" \
    INSTALL_OPT_DIR="$s7/opt" SYSTEMD_DIR="$s7/systemd" TMPFILES_DIR="$s7/tmpfiles" \
    CAN_TOOLS_RUN_DIR="$s7/run" CAN_TOOLS_STATE_DIR="$s7/state" \
    CAN_TOOLS_FAKE_DIR="$s7/fake" CAN_TOOLS_SYSTEMCTL_CMD="$tmpdir/systemctl_disabled" \
    CAN_TOOLS_MONITOR_STOP_TIMEOUT_S=0 \
    bash "$repo_root/install.sh" --check >"$run_check_log" 2>&1
rc=$?
(( rc != 0 )); check $? "--check should report a difference when a managed unit is not enabled (L-new1), got rc=$rc: $(cat "$run_check_log")"
grep -qi "would enable" "$run_check_log"
check $? "--check should explicitly mention the unit needs enabling (L-new1): $(cat "$run_check_log")"

# ---------------------------------------------------------------------
# Scenario 8 (M-r4a): an unrecognized argument must never fall through
# into a normal install (or into --check's "just show a diff" path
# either) - a stale "--plus" (removed in M-r3, but it was in an earlier
# README/PR comment and could still be muscle memory) or a typo like
# "--chek" must be rejected outright, before anything is touched.
# ---------------------------------------------------------------------
echo "Scenario 8: unknown arguments are rejected before anything runs (M-r4a)"
for bad_arg in "--plus" "--chek"; do
    s8="$tmpdir/s8_${bad_arg//-/}"
    mkdir -p "$s8/opt" "$s8/systemd" "$s8/tmpfiles" "$s8/run" "$s8/state" "$s8/fake"

    run_install "$s8/opt" "$s8/systemd" "$s8/tmpfiles" "$s8/run" "$s8/state" "$s8/fake" "$bad_arg" >"$tmpdir/s8_${bad_arg//-/}.log" 2>&1
    rc=$?
    (( rc != 0 )); check $? "install.sh $bad_arg must exit non-zero (M-r4a), got rc=$rc"

    if [[ ! -e "$s8/opt/can_tools" || -z "$(ls -A "$s8/opt/can_tools" 2>/dev/null)" ]]; then rc=0; else rc=1; fi
    check "$rc" "install.sh $bad_arg must not create any file under /opt (M-r4a)"
    if [[ ! -e "$s8/systemd" || -z "$(ls -A "$s8/systemd" 2>/dev/null)" ]]; then rc=0; else rc=1; fi
    check "$rc" "install.sh $bad_arg must not create any systemd unit (M-r4a)"
    if [[ ! -s "$s8/fake/calls.log" ]]; then rc=0; else rc=1; fi
    check "$rc" "install.sh $bad_arg must never call systemctl at all (M-r4a): $(cat "$s8/fake/calls.log" 2>/dev/null)"
done

# -h/--help prints usage and exits 0, without touching anything either.
s8h="$tmpdir/s8_help"
mkdir -p "$s8h/opt" "$s8h/systemd" "$s8h/tmpfiles" "$s8h/run" "$s8h/state" "$s8h/fake"
run_install "$s8h/opt" "$s8h/systemd" "$s8h/tmpfiles" "$s8h/run" "$s8h/state" "$s8h/fake" --help >"$tmpdir/s8_help.log" 2>&1
rc=$?
(( rc == 0 )); check $? "install.sh --help should exit 0, got rc=$rc"
grep -qi "usage" "$tmpdir/s8_help.log"
check $? "install.sh --help should print a usage message"
if [[ ! -e "$s8h/opt/can_tools" || -z "$(ls -A "$s8h/opt/can_tools" 2>/dev/null)" ]]; then rc=0; else rc=1; fi
check "$rc" "install.sh --help must not create any file under /opt"

# ---------------------------------------------------------------------
# Scenario 9 (PR#18 review C1): every installed unit's ExecStart binary
# must actually exist under INSTALL_OPT_DIR/can_tools and be executable -
# can_watchdog.service's ExecStart=/opt/can_tools/can_watchdog.sh was
# previously left unsatisfied because can_watchdog.sh (and can_diag.sh)
# were missing from files_to_install, so the unit would crash-loop on
# every boot.
# ---------------------------------------------------------------------
echo "Scenario 9: every installed unit's ExecStart target exists and is executable (C1)"
s9="$tmpdir/s9"
mkdir -p "$s9/opt" "$s9/systemd" "$s9/tmpfiles" "$s9/run" "$s9/state" "$s9/fake"

run_install "$s9/opt" "$s9/systemd" "$s9/tmpfiles" "$s9/run" "$s9/state" "$s9/fake" >"$tmpdir/s9_install.log" 2>&1
rc=$?
(( rc == 0 )); check $? "install for scenario 9 should succeed (rc=$rc): $(cat "$tmpdir/s9_install.log")"

for unit_file in "$s9/systemd"/*.service; do
    [[ -f "$unit_file" ]] || continue
    exec_line=$(grep -m1 '^ExecStart=' "$unit_file" || true)
    [[ -n "$exec_line" ]] || continue
    exec_path="${exec_line#ExecStart=}"
    exec_path="${exec_path%% *}"
    exec_name="${exec_path##*/}"
    installed_path="$s9/opt/can_tools/$exec_name"

    if [[ -f "$installed_path" ]]; then rc=0; else rc=1; fi
    check "$rc" "$(basename "$unit_file")'s ExecStart target ($exec_name) should be installed at $installed_path"
    if [[ -x "$installed_path" ]]; then rc=0; else rc=1; fi
    check "$rc" "$(basename "$unit_file")'s ExecStart target ($exec_name) should be executable"
done

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
