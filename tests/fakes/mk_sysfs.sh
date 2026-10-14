#!/bin/bash

# tests/fakes/mk_sysfs.sh - Create fake sysfs tree for testing

scenario_file="$1"
tick="$2"
sysfs_root="${CAN_TOOLS_SYSFS_ROOT:?}"  # H5: Require explicit setting

# Clean previous sysfs
rm -rf "$sysfs_root"/* 2>/dev/null || true

mkdir -p "$sysfs_root/class/net"
mkdir -p "$sysfs_root/bus/spi/devices"
mkdir -p "$sysfs_root/bus/spi/drivers/mcp251xfd"

# Touch bind/unbind files (M4: preserve these)
touch "$sysfs_root/bus/spi/drivers/mcp251xfd/bind"
touch "$sysfs_root/bus/spi/drivers/mcp251xfd/unbind"

# Read scenario and apply for this tick
if [[ -f "$scenario_file" ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        read -r entry_tick if_name rx tx rxfifo txfifo ifindex <<<"$line"

        if [[ "$entry_tick" == "$tick" ]]; then
            mkdir -p "$sysfs_root/class/net/$if_name/statistics"
            echo "$rx" >"$sysfs_root/class/net/$if_name/statistics/rx_packets"
            echo "$tx" >"$sysfs_root/class/net/$if_name/statistics/tx_packets"
            echo "$rxfifo" >"$sysfs_root/class/net/$if_name/statistics/rx_fifo_errors"
            echo "$txfifo" >"$sysfs_root/class/net/$if_name/statistics/tx_fifo_errors"
            echo "$ifindex" >"$sysfs_root/class/net/$if_name/ifindex"

            mkdir -p "$sysfs_root/bus/spi/devices/spi0.0/net"
            mkdir -p "$sysfs_root/bus/spi/devices/spi1.0/net"

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
