#!/bin/bash
# install.sh - Install can_tools to /opt/can_tools (idempotent, root).
#
# Usage: sudo ./install.sh [--check] [--plus]
#
#   --plus   also install and enable the canhat_plus_* units (HAT+ hardware).
#            Without it, the canhat_plus_* scripts are still copied to
#            /opt/can_tools (harmless, never run on their own), but the
#            units are neither installed nor enabled - §4-3 only lists
#            canhat_fd_rename/setup and (once it exists) can_watchdog as
#            install/enable targets; canhat_plus_* is explicitly "do not
#            change the behavior" (§2b), and enabling it unconditionally on
#            every machine would let it race/override the FD setup on a
#            boot where its ordering (After=network.target only - no lock,
#            no After=/Before= relationship with canhat_fd_*) lets it run
#            concurrently with or after canhat_fd_setup.service.
#
# Environment variables (mainly for testing against a scratch tree instead of
# the real filesystem):
#   INSTALL_ROOT             - root directory (default: /) - currently
#                               informational only; every other *_DIR below
#                               is the actual override point for tests.
#   INSTALL_OPT_DIR           - /opt equivalent (default: /opt)
#   SYSTEMD_DIR                - systemd units directory (default: /etc/systemd/system)
#   TMPFILES_DIR                - tmpfiles.d directory (default: /etc/tmpfiles.d)
#   CAN_TOOLS_RUN_DIR         - /run/can_tools equivalent (default: /run/can_tools)
#   CAN_TOOLS_STATE_DIR      - /var/lib/can_tools equivalent (default: /var/lib/can_tools)
#   CAN_TOOLS_SYSTEMCTL_CMD - systemctl replacement (default: systemctl)
#   CHECK_MODE                  - if 1 (or --check given), show diffs and make no changes
#   CAN_TOOLS_INSTALL_PLUS - if 1 (or --plus given), also install/enable canhat_plus_*
#   VERBOSE                      - if 1, also log unchanged files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# --check and --plus are accepted as arguments (§4); CHECK_MODE=1 /
# CAN_TOOLS_INSTALL_PLUS=1 in the environment still work too, for scripted
# callers.
CHECK_MODE="${CHECK_MODE:-0}"
PLUS_MODE="${CAN_TOOLS_INSTALL_PLUS:-0}"
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_MODE=1 ;;
        --plus) PLUS_MODE=1 ;;
    esac
done
readonly CHECK_MODE
readonly PLUS_MODE

# Configuration from environment (for testing)
readonly INSTALL_ROOT="${INSTALL_ROOT:-/}"
readonly INSTALL_OPT_DIR="${INSTALL_OPT_DIR:-/opt}"
readonly SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
readonly TMPFILES_DIR="${TMPFILES_DIR:-/etc/tmpfiles.d}"
readonly CAN_TOOLS_RUN_DIR="${CAN_TOOLS_RUN_DIR:-/run/can_tools}"
readonly CAN_TOOLS_STATE_DIR="${CAN_TOOLS_STATE_DIR:-/var/lib/can_tools}"
readonly SYSTEMCTL_CMD="${CAN_TOOLS_SYSTEMCTL_CMD:-systemctl}"
readonly VERBOSE="${VERBOSE:-0}"

# Installation directories
readonly INSTALL_CAN_TOOLS_DIR="$INSTALL_OPT_DIR/can_tools"
readonly INSTALL_CONF_PATH="$INSTALL_CAN_TOOLS_DIR/can_tools.conf"

# Log helper
_log() {
    local level="$1"
    shift
    echo "[install.sh] [$level] $*" >&2
}

# Any destination overridden from its real-filesystem default means this is
# a test run against a scratch tree, not the real machine - skip the root
# check in that case (M4).
_is_test_mode() {
    [[ "$INSTALL_OPT_DIR" != "/opt" || "$SYSTEMD_DIR" != "/etc/systemd/system" \
        || "$TMPFILES_DIR" != "/etc/tmpfiles.d" ]]
}

# Check if a file differs from source
_file_differs() {
    local src="$1"
    local dst="$2"

    # A destination that doesn't exist, or exists but is a dangling/foreign
    # symlink (M1: legacy link-unit deployments), counts as "differs".
    [[ -e "$dst" && ! -L "$dst" ]] || return 0

    ! cmp -s "$src" "$dst"
}

# Install a regular file. Returns 0 if a change was made/would be made
# (CHECK_MODE), 1 if the destination already matches.
_install_file() {
    local src="$1"
    local dst="$2"
    local mode="${3:-0644}"

    if ! _file_differs "$src" "$dst"; then
        (( VERBOSE )) && _log "SKIP" "Already installed: $dst (identical)"
        return 1
    fi

    if (( CHECK_MODE )); then
        _log "DIFF" "Would install: $src -> $dst"
        if [[ -f "$dst" && ! -L "$dst" ]]; then
            diff -u "$dst" "$src" || true
        else
            _log "DIFF" "  (new file, or replacing a symlink)"
        fi
        return 0
    fi

    _log "INSTALL" "Installing: $src -> $dst"
    # M1: a destination that is a symlink (legacy "link straight into
    # /opt/can_tools" unit deployment) must be removed first, or cp would
    # follow it and write through to the link target instead of replacing it.
    [[ -L "$dst" ]] && rm -f "$dst"
    cp "$src" "$dst"
    chmod "$mode" "$dst"
    return 0
}

# Install configuration (never overwrite an existing file's content, but
# always enforce ownership/mode on it). Returns 0 if the file was created
# (CHECK_MODE: would be created), 1 if it already existed.
_install_conf() {
    local src="$1"
    local dst="$2"

    if [[ -f "$dst" ]]; then
        (( VERBOSE )) && _log "SKIP" "Configuration exists, not overwriting: $dst"
        if (( ! CHECK_MODE )); then
            chmod 0644 "$dst" 2>/dev/null || true
            chown root:root "$dst" 2>/dev/null || true
        fi
        return 1
    fi

    if (( CHECK_MODE )); then
        _log "DIFF" "Would create config: $dst"
        return 0
    fi

    _log "CREATE" "Creating configuration: $dst"
    cp "$src" "$dst"
    chmod 0644 "$dst"
    chown root:root "$dst" 2>/dev/null || true
    return 0
}

# Install a systemd unit, handling the M1 symlink case (a pre-A2 deployment
# with /etc/systemd/system/<unit> symlinked straight into /opt/can_tools).
# daemon-reload/enable happen once at the end for every unit present (M2),
# not here.
_install_unit() {
    local unit="$1"
    local src="$SCRIPT_DIR/$unit"
    local dst="$SYSTEMD_DIR/$unit"

    [[ -f "$src" ]] || return 1

    if [[ -L "$dst" ]] && (( ! CHECK_MODE )); then
        _log "INFO" "Replacing legacy symlinked unit: $dst (M1)"
        "$SYSTEMCTL_CMD" disable "$unit" >/dev/null 2>&1 || true
    fi

    _install_file "$src" "$dst" "0644"
}

# Stop, disable and remove the legacy can_monitor unit/links/files (§4-4,
# H2). can_monitor itself triggered the 2026-10-14 incident; it is never
# installed by this script. /var/log/can_monitor.log is left alone.
# Bounded wait for a unit to report inactive (M-new2). Checks at least once
# even with timeout 0. Returns 0 once inactive, 1 on timeout.
_wait_inactive() {
    local unit="$1" timeout_s="$2"
    local max_ticks=$(( timeout_s * 10 )) ticks=0
    while :; do
        "$SYSTEMCTL_CMD" is-active "$unit" >/dev/null 2>&1 || return 0
        (( ticks >= max_ticks )) && return 1
        sleep 0.1
        (( ticks++ ))
    done
}

_remove_can_monitor() {
    local did_change=1
    local monitor_stop_timeout="${CAN_TOOLS_MONITOR_STOP_TIMEOUT_S:-15}"

    for unit in can_monitor.timer can_monitor.service; do
        local dst="$SYSTEMD_DIR/$unit"
        [[ -e "$dst" || -L "$dst" ]] || continue
        did_change=0

        if (( CHECK_MODE )); then
            _log "DIFF" "Would stop/disable/remove legacy unit: $dst"
            continue
        fi

        if [[ "$unit" == "can_monitor.service" ]]; then
            # M-new2: can_monitor.service is a oneshot that itself runs
            # `ip link set down; sleep 0.5; up`. A plain `systemctl stop`
            # sends SIGTERM mid-run and can leave the interface down. Wait
            # (bounded) for it to finish on its own instead - never send it
            # a stop.
            _log "INFO" "Disabling legacy unit: $unit (waiting up to ${monitor_stop_timeout}s for it to finish, never stopping it)"
            if ! _wait_inactive "$unit" "$monitor_stop_timeout"; then
                _log "WARN" "$unit did not become inactive within ${monitor_stop_timeout}s; disabling/removing it anyway without stopping it"
            fi
        else
            _log "INFO" "Stopping and disabling legacy unit: $unit"
            "$SYSTEMCTL_CMD" stop "$unit" >/dev/null 2>&1 || true
        fi
        "$SYSTEMCTL_CMD" disable "$unit" >/dev/null 2>&1 || true
        rm -f "$dst"
    done

    for f in can_monitor.sh can_monitor.timer can_monitor.service; do
        local path="$INSTALL_CAN_TOOLS_DIR/$f"
        [[ -e "$path" ]] || continue
        did_change=0

        if (( CHECK_MODE )); then
            _log "DIFF" "Would remove legacy file: $path"
        else
            _log "INFO" "Removing legacy file: $path"
            rm -f "$path"
        fi
    done

    return $did_change
}

# Create /run/can_tools and /var/lib/can_tools immediately (M3), and install
# the tmpfiles.d drop-in so they are recreated on every boot without relying
# on this script having run again.
_install_runtime_dirs() {
    local did_change=1

    for d in "$CAN_TOOLS_RUN_DIR" "$CAN_TOOLS_STATE_DIR"; do
        if [[ ! -d "$d" ]]; then
            did_change=0
            if (( CHECK_MODE )); then
                _log "DIFF" "Would create directory: $d"
            else
                _log "INSTALL" "Creating directory: $d"
                mkdir -p "$d"
                chmod 0755 "$d"
            fi
        fi
    done

    local src="$SCRIPT_DIR/can_tools.tmpfiles.conf"
    local dst="$TMPFILES_DIR/can_tools.conf"
    if [[ -f "$src" ]]; then
        (( ! CHECK_MODE )) && mkdir -p "$TMPFILES_DIR"
        if _install_file "$src" "$dst" "0644"; then
            did_change=0
        fi
    else
        _log "WARN" "can_tools.tmpfiles.conf not found: $src"
    fi

    return $did_change
}

# Main installation
main() {
    local diff_found=0

    if (( ! CHECK_MODE )) && ! _is_test_mode && [[ "$(id -u)" -ne 0 ]]; then
        _log "ERROR" "install.sh must be run as root (use sudo); re-run with sudo, or set INSTALL_OPT_DIR/SYSTEMD_DIR/TMPFILES_DIR to a scratch tree for testing"
        return 1
    fi

    # Ensure target directories exist
    if (( ! CHECK_MODE )); then
        mkdir -p "$INSTALL_CAN_TOOLS_DIR" || {
            _log "ERROR" "Failed to create $INSTALL_CAN_TOOLS_DIR"
            return 1
        }
        mkdir -p "$SYSTEMD_DIR" || {
            _log "ERROR" "Failed to create $SYSTEMD_DIR"
            return 1
        }
    fi

    _log "INFO" "Installing can_tools from $SCRIPT_DIR"

    # List of files to install (non-configuration, non-unit). can_monitor.sh
    # is deliberately excluded (H2): it is removed, never installed.
    local files_to_install=(
        "can_tools_lib.bash:0644"
        "can_tools.conf.example:0644"
        "canhat_fd_setup.bash:0755"
        "canhat_fd_rename.bash:0755"
        "canhat_plus_setup.bash:0755"
        "canhat_plus_rename.bash:0755"
        "enable_canhat_fd.sh:0755"
        "enable_canhat_plus.sh:0755"
        "can_setup.bash:0755"
        "can_down.bash:0755"
        "peakcan_setup.bash:0755"
        "vcan_setup.bash:0755"
        "vcan_down.bash:0755"
        "record_can.bash:0755"
        "play_can.bash:0755"
    )

    for file_entry in "${files_to_install[@]}"; do
        local fname="${file_entry%%:*}" fmode="${file_entry##*:}"
        local src="$SCRIPT_DIR/$fname"
        local dst="$INSTALL_CAN_TOOLS_DIR/$fname"

        [[ -f "$src" ]] || {
            _log "WARN" "Source file not found: $src"
            continue
        }

        if _install_file "$src" "$dst" "$fmode"; then
            diff_found=1
        fi
    done

    # Configuration: create can_tools.conf if missing, never overwrite it
    # (§4-2). can_tools.conf.example above is always kept up to date.
    local conf_src="$SCRIPT_DIR/can_tools.conf.example"
    if [[ -f "$conf_src" ]]; then
        if _install_conf "$conf_src" "$INSTALL_CONF_PATH"; then
            diff_found=1
        fi
    else
        _log "WARN" "Configuration example not found: $conf_src"
    fi

    # Systemd units (§4-3): copied, never symlinked; replaces any pre-A2
    # link-unit deployment (M1). can_watchdog.service does not exist yet in
    # this PR (PR-B) - installed automatically once it does.
    #
    # canhat_plus_* is deliberately NOT in the default list (C-new1): §4-3
    # names only canhat_fd_rename/setup and can_watchdog as install/enable
    # targets, and canhat_plus_setup.service has no After=/Before=/lock
    # relationship with canhat_fd_setup.service - enabling it on every
    # machine would let it race the FD setup (and overwrite txqueuelen
    # 10/restart-ms 100 with its own 65536/1000) on any boot where both
    # happen to be enabled. It is only added to the list with --plus, for a
    # machine that is actually a HAT+ board.
    local units_to_install=(
        "canhat_fd_rename.service"
        "canhat_fd_setup.service"
        "can_watchdog.service"
    )
    if (( PLUS_MODE )); then
        units_to_install+=("canhat_plus_rename.service" "canhat_plus_setup.service")
    fi

    for unit in "${units_to_install[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$unit" ]]; then
            continue
        fi
        if _install_unit "$unit"; then
            diff_found=1
        fi
    done

    # §4-4 / H2: can_monitor is retired, not installed.
    if _remove_can_monitor; then
        diff_found=1
    fi

    # §4-5 / M3: runtime/state directories + tmpfiles.d drop-in.
    if _install_runtime_dirs; then
        diff_found=1
    fi

    if (( CHECK_MODE )); then
        # L-new1: --check only compared file contents, so a unit that is
        # installed but not enabled (e.g. a hand-disabled unit, or this
        # being the first run before the real `systemctl enable` below ever
        # happened) showed no diff. Report enable-state too, read-only
        # (is-enabled makes no change).
        for unit in "${units_to_install[@]}"; do
            [[ -f "$SCRIPT_DIR/$unit" ]] || continue
            if ! "$SYSTEMCTL_CMD" is-enabled "$unit" >/dev/null 2>&1; then
                _log "DIFF" "Would enable: $unit"
                diff_found=1
            fi
        done
    else
        # M2/M4: a single daemon-reload (via the replaceable systemctl
        # command), then enable every unit this script manages. Enabling an
        # already-enabled unit is a no-op; none of this starts/restarts
        # anything that might be running (§4-6/§0: no down/up of a live CAN
        # interface, ever, from install.sh).
        local any_unit_present=0
        for unit in "${units_to_install[@]}"; do
            [[ -f "$SCRIPT_DIR/$unit" ]] && any_unit_present=1
        done

        if (( any_unit_present )); then
            if ! "$SYSTEMCTL_CMD" daemon-reload; then
                _log "ERROR" "systemctl daemon-reload failed"
            fi
            for unit in "${units_to_install[@]}"; do
                [[ -f "$SCRIPT_DIR/$unit" ]] || continue
                if ! "$SYSTEMCTL_CMD" enable "$unit" >/dev/null 2>&1; then
                    _log "ERROR" "systemctl enable $unit failed"
                fi
            done
        fi
    fi

    if (( CHECK_MODE )); then
        if (( diff_found )); then
            _log "INFO" "Check mode: differences found"
            return 1
        else
            _log "INFO" "Check mode: no differences"
            return 0
        fi
    fi

    _log "INFO" "Installation complete"
    _log "INFO" "Config changes only take effect on reboot, or after 'systemctl restart canhat_fd_setup.service' while the machine is stopped (§0/§4-7) - never while it is running."
    _log "INFO" "Until then, the watchdog (once installed) observes only and does not act on a mismatched configuration."
    return 0
}

# Entry point
if (( CHECK_MODE )); then
    _log "INFO" "Running in CHECK mode (no changes)"
fi

main "$@"
