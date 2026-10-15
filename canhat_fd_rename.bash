#!/bin/bash
# canhat_fd_rename.bash - Rename CAN FD interfaces from spi0.0/spi1.0 to can0/can1
# Requires: sourcing can_tools_lib.bash and can_tools.conf (if present)
# Called by canhat_fd_rename.service as ExecStart=/opt/can_tools/canhat_fd_rename.bash

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

# Load configuration to get CAN_SPI_MAP (defaults to can_tools.conf in script directory)
can_read_conf "$CONF_PATH" || exit 1

# Parse CAN_SPI_MAP (format: "spi0.0:can0 spi1.0:can1") and rename each
rename_failed=0
for mapping in $CAN_SPI_MAP; do
    IFS=':' read -r spidev want_name <<< "$mapping" || continue
    [[ -n "$spidev" && -n "$want_name" ]] || continue

    # Rename interface (can_pin_name takes lock internally)
    if ! can_pin_name "$spidev" "$want_name"; then
        echo "ERROR: Failed to rename spi device $spidev to $want_name" >&2
        rename_failed=1
    fi
done

exit "$rename_failed"
