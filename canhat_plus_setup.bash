#!/bin/bash
# canhat_plus_setup.bash - Setup CAN (non-FD) interface using can_tools_lib
# Requires: sourcing can_tools_lib.bash and can_tools.conf (if present)
# Called by canhat_plus_setup.service as ExecStart=/opt/can_tools/canhat_plus_setup.bash

set -euo pipefail

# shellcheck disable=SC2155
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_PATH="$SCRIPT_DIR/can_tools_lib.bash"
readonly CONF_PATH="${CAN_TOOLS_CONF:-$SCRIPT_DIR/can_tools.conf}"

# Source library (die on error)
[[ -f "$LIB_PATH" ]] || {
    echo "ERROR: can_tools_lib.bash not found at $LIB_PATH" >&2
    exit 1
}
# shellcheck source=can_tools_lib.bash
source "$LIB_PATH" || exit 1

# For CAN HAT Plus: disable CAN FD
export CAN_FD="off"

# Load configuration (defaults to can_tools.conf in script directory)
can_read_conf "$CONF_PATH" || exit 1

# Setup all configured CAN interfaces
setup_failed=0
for iface in $CAN_IFACES; do
    if ! can_setup_iface "$iface"; then
        echo "ERROR: Failed to setup CAN interface $iface" >&2
        setup_failed=1
    fi
done

exit "$setup_failed"

