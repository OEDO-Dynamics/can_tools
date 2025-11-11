#!/bin/bash
# CAN Interface Monitor and Auto-Recovery Script
# Monitors CAN interfaces for ERROR-PASSIVE or BUS-OFF state and resets them

LOG_FILE="/var/log/can_monitor.log"
CAN_INTERFACES=("can0" "can1")

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to check and reset CAN interface if needed
check_and_reset_can() {
    local interface=$1

    # Check if interface exists
    if ! ip link show "$interface" &>/dev/null; then
        log_message "WARNING: Interface $interface does not exist"
        return
    fi

    # Get CAN state
    local can_state=$(ip -details link show "$interface" | grep -oP 'can state \K[^ ]+')

    if [[ -z "$can_state" ]]; then
        log_message "WARNING: Could not determine state for $interface"
        return
    fi

    log_message "INFO: $interface state is $can_state"

    # Check if interface is in ERROR-PASSIVE or BUS-OFF state
    if [[ "$can_state" == "ERROR-PASSIVE" ]] || [[ "$can_state" == "BUS-OFF" ]]; then
        log_message "ALERT: $interface is in $can_state state - initiating reset"

        # Reset the interface
        if ip link set "$interface" down && sleep 0.5 && ip link set "$interface" up; then
            log_message "SUCCESS: $interface has been reset"

            # Wait a moment and check new state
            sleep 1
            local new_state=$(ip -details link show "$interface" | grep -oP 'can state \K[^ ]+')
            log_message "INFO: $interface new state is $new_state"
        else
            log_message "ERROR: Failed to reset $interface"
        fi
    fi
}

# Main execution
log_message "===== CAN Monitor Check Started ====="

for interface in "${CAN_INTERFACES[@]}"; do
    check_and_reset_can "$interface"
done

log_message "===== CAN Monitor Check Completed ====="
