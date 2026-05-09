#!/bin/bash
set -euo pipefail

CAN_SPI11=""
CAN_SPI12=""

for iface in /sys/class/net/can*; do
    name=$(basename "$iface")
    dev=$(readlink "$iface/device" 2>/dev/null || true)
    case "$dev" in
        *spi1.1) CAN_SPI11="$name" ;;
        *spi1.2) CAN_SPI12="$name" ;;
    esac
done

if [ -z "$CAN_SPI11" ] || [ -z "$CAN_SPI12" ]; then
    echo "ERROR: CAN interfaces for spi1.1/spi1.2 not found" >&2
    exit 1
fi

if [ "$CAN_SPI11" = "can0" ] && [ "$CAN_SPI12" = "can1" ]; then
    echo "CAN interfaces already correctly named"
    exit 0
fi

sudo ip link set "$CAN_SPI11" down
sudo ip link set "$CAN_SPI12" down
sudo ip link set "$CAN_SPI12" name can_tmp
sudo ip link set "$CAN_SPI11" name can0
sudo ip link set can_tmp name can1
echo "Renamed: spi1.1=${CAN_SPI11}->can0, spi1.2=${CAN_SPI12}->can1"
