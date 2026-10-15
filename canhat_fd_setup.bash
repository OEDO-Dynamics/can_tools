#!/bin/bash
# canhat_fd_setup.bash - Bring up a single CAN FD interface using can_tools_lib.
# Requires: sourcing can_tools_lib.bash and can_tools.conf (if present)
# Called per-interface, e.g. by enable_canhat_fd.sh as
# ExecStart=/opt/can_tools/canhat_fd_setup.bash can0
#
# Per Issue #9 §2b: this script only calls can_read_conf -> can_setup_iface
# "$1". It must not loop over CAN_IFACES itself (that is enable_canhat_fd.sh's
# job) so that a manual run against one interface never touches the other.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LIB_PATH="$SCRIPT_DIR/can_tools_lib.bash"
readonly CONF_PATH="${CAN_TOOLS_CONF:-$SCRIPT_DIR/can_tools.conf}"

if [[ $# -lt 1 || -z "$1" ]]; then
    echo "Usage: $0 <iface>" >&2
    exit 1
fi
iface="$1"

# Source library (die on error)
[[ -f "$LIB_PATH" ]] || {
    echo "ERROR: can_tools_lib.bash not found at $LIB_PATH" >&2
    exit 1
}
# shellcheck source=can_tools_lib.bash
source "$LIB_PATH" || exit 1

# Load configuration (defaults to can_tools.conf in script directory)
can_read_conf "$CONF_PATH" || exit 1

# Wrapped in `if` (not a bare statement + $?): can_setup_iface's own body has
# an unguarded `ip link set ... down` whose failure (e.g. the interface not
# existing yet) must not abort this script via `set -e` before can_unlock
# runs - `if`'s condition is the one place bash suspends errexit for the
# whole nested call.
if can_setup_iface "$iface"; then
    exit 0
else
    exit $?
fi
