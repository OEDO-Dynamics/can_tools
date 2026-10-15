#!/bin/bash
# install.sh - Install can_tools to /opt/can_tools (idempotent)
# Environment variables (for testing):
#   INSTALL_ROOT     - root directory (default: /)
#   INSTALL_OPT_DIR  - /opt equivalent (default: /opt)
#   SYSTEMD_DIR      - systemd units directory (default: /etc/systemd/system)
#   CHECK_MODE       - if 1, show diff and exit without making changes

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration from environment (for testing)
readonly INSTALL_ROOT="${INSTALL_ROOT:-/}"
readonly INSTALL_OPT_DIR="${INSTALL_OPT_DIR:-/opt}"
readonly SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
readonly CHECK_MODE="${CHECK_MODE:-0}"
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

# Check if a file differs from source
_file_differs() {
    local src="$1"
    local dst="$2"

    # If destination doesn't exist, it differs
    [[ -f "$dst" ]] || return 0

    # Compare contents
    ! cmp -s "$src" "$dst"
}

# Install a file (skip if identical and not in check mode)
_install_file() {
    local src="$1"
    local dst="$2"
    local mode="${3:-0644}"

    if _file_differs "$src" "$dst"; then
        if (( CHECK_MODE )); then
            _log "DIFF" "Would install: $src -> $dst"
            return 1
        fi
        _log "INSTALL" "Installing: $src -> $dst"
        cp "$src" "$dst"
        chmod "$mode" "$dst"
        return 0
    else
        if (( VERBOSE )); then
            _log "SKIP" "Already installed: $dst (identical)"
        fi
        return 0
    fi
}

# Install configuration (never overwrite existing)
_install_conf() {
    local src="$1"
    local dst="$2"

    if [[ -f "$dst" ]]; then
        _log "SKIP" "Configuration exists, not overwriting: $dst"
        return 0
    fi

    if (( CHECK_MODE )); then
        _log "DIFF" "Would create config: $src -> $dst"
        return 1
    fi

    _log "CREATE" "Creating configuration: $dst"
    cp "$src" "$dst"
}

# Main installation
main() {
    local diff_found=0

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

    # List of files to install (non-configuration, non-service)
    local files_to_install=(
        "can_tools_lib.bash:0644"
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
        "can_monitor.sh:0755"
        "record_can.bash:0755"
        "play_can.bash:0755"
    )

    # Install regular files
    for file_entry in "${files_to_install[@]}"; do
        IFS=':' read -r fname fmode <<< "$file_entry" || continue
        src="$SCRIPT_DIR/$fname"
        dst="$INSTALL_CAN_TOOLS_DIR/$fname"

        [[ -f "$src" ]] || {
            _log "WARN" "Source file not found: $src"
            continue
        }

        if _install_file "$src" "$dst" "$fmode"; then
            diff_found=1
        fi
    done

    # Install configuration (never overwrite)
    src="$SCRIPT_DIR/can_tools.conf.example"
    if [[ -f "$src" ]]; then
        if _install_conf "$src" "$INSTALL_CONF_PATH"; then
            diff_found=1
        fi
    else
        _log "WARN" "Configuration example not found: $src"
    fi

    # Install systemd units (non-timer, do not restart running services)
    local units_to_install=(
        "canhat_fd_setup.service"
        "canhat_fd_rename.service"
        "canhat_plus_setup.service"
        "canhat_plus_rename.service"
        "can_monitor.service"
    )

    for unit in "${units_to_install[@]}"; do
        src="$SCRIPT_DIR/$unit"
        dst="$SYSTEMD_DIR/$unit"

        [[ -f "$src" ]] || {
            _log "WARN" "Unit file not found: $src"
            continue
        }

        if _install_file "$src" "$dst" "0644"; then
            diff_found=1
            if (( ! CHECK_MODE )); then
                # Notify systemd of the new unit (but do not restart active services)
                systemctl daemon-reload 2>/dev/null || true
            fi
        fi
    done

    # Handle can_monitor.timer (legacy, may need to be disabled if present)
    local timer_unit="can_monitor.timer"
    local timer_path="$SYSTEMD_DIR/$timer_unit"
    if [[ -f "$timer_path" ]]; then
        _log "INFO" "Legacy timer unit found: $timer_path"
        # Per Issue #9: log but do not delete or modify (admin decision)
        if (( ! CHECK_MODE )); then
            _log "INFO" "To disable: sudo systemctl disable --now $timer_unit"
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
    return 0
}

# Entry point
if (( CHECK_MODE )); then
    _log "INFO" "Running in CHECK mode (no changes)"
fi

main "$@"
