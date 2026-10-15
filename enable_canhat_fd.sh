#!/bin/bash
# enable_canhat_fd.sh - Bring up every interface listed in CAN_IFACES.
# Called by canhat_fd_setup.service as ExecStart=/opt/can_tools/enable_canhat_fd.sh
#
# Per Issue #9 §2b: canhat_fd_setup.bash only handles a single "$1" and must
# not be sourced (it calls `exit`, which would terminate this script after
# the first interface if sourced) - each interface is run as its own
# subprocess instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LIB_PATH="$SCRIPT_DIR/can_tools_lib.bash"
readonly CONF_PATH="${CAN_TOOLS_CONF:-$SCRIPT_DIR/can_tools.conf}"

[[ -f "$LIB_PATH" ]] || {
    echo "ERROR: can_tools_lib.bash not found at $LIB_PATH" >&2
    exit 1
}
# shellcheck source=can_tools_lib.bash
source "$LIB_PATH" || exit 1

can_read_conf "$CONF_PATH" || exit 1

failed=0
for iface in $CAN_IFACES; do
    if ! "$SCRIPT_DIR/canhat_fd_setup.bash" "$iface"; then
        echo "ERROR: Failed to setup CAN interface $iface" >&2
        failed=1
    fi
done

exit "$failed"
