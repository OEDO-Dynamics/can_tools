#!/bin/bash

# tests/fakes/mk_sysfs.sh - Create fake sysfs tree for testing
# Usage: mk_sysfs.sh <scenario_file> <tick>
# Scenario file format: <tick> <if> rx tx rxfifo txfifo ifindex

set -e

scenario_file="$1"
tick="$2"
sysfs_root="${CAN_TOOLS_SYSFS_ROOT:-/sys}"

# Clean previous sysfs
rm -rf "$sysfs_root"/* 2>/dev/null || true

# Create base directories
mkdir -p "$sysfs_root/class/net"
mkdir -p "$sysfs_root/bus/spi/devices"
mkdir -p "$sysfs_root/bus/spi/drivers/mcp251xfd"

# Read scenario file and apply entries for this tick
if [[ -f "$scenario_file" ]]; then
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        # Parse: tick if rx tx rxfifo txfifo ifindex
        local entry_tick if_name rx tx rxfifo txfifo ifindex
        read -r entry_tick if_name rx tx rxfifo txfifo ifindex <<< "$line"

        if [[ "$entry_tick" == "$tick" ]]; then
            # Create interface directory
            mkdir -p "$sysfs_root/class/net/$if_name/statistics"

            # Write statistics
            echo "$rx" > "$sysfs_root/class/net/$if_name/statistics/rx_packets"
            echo "$tx" > "$sysfs_root/class/net/$if_name/statistics/tx_packets"
            echo "$rxfifo" > "$sysfs_root/class/net/$if_name/statistics/rx_fifo_errors"
            echo "$txfifo" > "$sysfs_root/class/net/$if_name/statistics/tx_fifo_errors"
            echo "$ifindex" > "$sysfs_root/class/net/$if_name/ifindex"

            # Create symlink from class/net to device
            # (in real scenario, this would point to /sys/bus/spi/devices/spi0.0 etc)
            mkdir -p "$sysfs_root/bus/spi/devices/spi0.0/net"
            mkdir -p "$sysfs_root/bus/spi/devices/spi1.0/net"

            # Link the device (simplified - in real tests would map spidev to iface)
            if [[ "$if_name" == "can0" ]]; then
                ln -sf "$sysfs_root/bus/spi/devices/spi0.0" "$sysfs_root/class/net/$if_name/device"
                ln -sf "$sysfs_root/class/net/$if_name" "$sysfs_root/bus/spi/devices/spi0.0/net/$if_name"
            elif [[ "$if_name" == "can1" ]]; then
                ln -sf "$sysfs_root/bus/spi/devices/spi1.0" "$sysfs_root/class/net/$if_name/device"
                ln -sf "$sysfs_root/class/net/$if_name" "$sysfs_root/bus/spi/devices/spi1.0/net/$if_name"
            fi
        fi
    done < "$scenario_file"
fi

# Create bind/unbind files in spi drivers
touch "$sysfs_root/bus/spi/drivers/mcp251xfd/bind"
touch "$sysfs_root/bus/spi/drivers/mcp251xfd/unbind"
