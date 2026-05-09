#!/bin/bash
set -euo pipefail

CAN_SPI00=""
CAN_SPI10=""

for iface in /sys/class/net/can*; do
    name=$(basename "$iface")
    dev=$(readlink "$iface/device" 2>/dev/null || true)
    case "$dev" in
        *spi0.0) CAN_SPI00="$name" ;;
        *spi1.0) CAN_SPI10="$name" ;;
    esac
done

if [ -z "$CAN_SPI00" ] || [ -z "$CAN_SPI10" ]; then
    echo "ERROR: CAN interfaces for spi0.0/spi1.0 not found" >&2
    return 0
fi

if [ "$CAN_SPI00" = "can0" ] && [ "$CAN_SPI10" = "can1" ]; then
    echo "CAN interfaces already correctly named"
    return 0
fi

sudo ip link set "$CAN_SPI00" down
sudo ip link set "$CAN_SPI10" down
sudo ip link set "$CAN_SPI10" name can_tmp
sudo ip link set "$CAN_SPI00" name can0
sudo ip link set can_tmp name can1
echo "Renamed: spi0.0=${CAN_SPI00}->can0, spi1.0=${CAN_SPI10}->can1"
