#!/bin/bash

# tests/fakes/mk_sysfs.sh <scenario_file> <tick> - build/update a fake sysfs
# tree for the given tick, per §5a.
#
# Scenario file: one line per (tick, iface) sample:
#   <tick> <if> <rx> <tx> <rxfifo> <txfifo> <ifindex>
#
# spidev mapping: CAN_TOOLS_TEST_SPI_MAP overrides the default
# "spi0.0:can0 spi1.0:can1" (same syntax as CAN_SPI_MAP), so tests can model
# rebind / rename / swap scenarios where an iface moves to a different
# spidev. Only the spidev entries actually seen in the mapping or scenario
# are created.
#
# N-M4: unlike a naive "wipe and rebuild" each tick, this only (re)writes the
# statistics/ifindex files for the ifaces present in this tick and leaves
# bind/unbind (and anything already written to them) untouched across calls,
# so a test can verify a prior tick's "echo spiX.Y > unbind" write survives.

scenario_file="$1"
tick="$2"
sysfs_root="${CAN_TOOLS_SYSFS_ROOT:?}"
[[ "$sysfs_root" == "/sys" ]] && { echo "refusing to touch real /sys" >&2; exit 1; }

mkdir -p "$sysfs_root/class/net"
mkdir -p "$sysfs_root/bus/spi/devices"
mkdir -p "$sysfs_root/bus/spi/drivers/mcp251xfd"

# Only create bind/unbind once; never truncate them again (N-M4).
[[ -f "$sysfs_root/bus/spi/drivers/mcp251xfd/bind" ]] || : >"$sysfs_root/bus/spi/drivers/mcp251xfd/bind"
[[ -f "$sysfs_root/bus/spi/drivers/mcp251xfd/unbind" ]] || : >"$sysfs_root/bus/spi/drivers/mcp251xfd/unbind"

declare -A spi_of_if=()
spi_map="${CAN_TOOLS_TEST_SPI_MAP:-spi0.0:can0 spi1.0:can1}"
for pair in $spi_map; do
    spi="${pair%%:*}"
    ifn="${pair#*:}"
    spi_of_if["$ifn"]="$spi"
done

_link_spidev() {
    local if_name="$1" spidev="$2"
    [[ -n "$spidev" ]] || return 0
    mkdir -p "$sysfs_root/bus/spi/devices/$spidev/net"
    # Drop any stale link to a different spidev for this iface (rebind/swap).
    if [[ -L "$sysfs_root/class/net/$if_name/device" ]]; then
        old_target=$(readlink -f "$sysfs_root/class/net/$if_name/device")
        old_spidev="${old_target##*/}"
        if [[ "$old_spidev" != "$spidev" ]]; then
            rm -f "$sysfs_root/bus/spi/devices/$old_spidev/net/$if_name" 2>/dev/null || true
        fi
    fi
    ln -sf "$sysfs_root/bus/spi/devices/$spidev" "$sysfs_root/class/net/$if_name/device"
    ln -sf "$sysfs_root/class/net/$if_name" "$sysfs_root/bus/spi/devices/$spidev/net/$if_name"
}

if [[ -f "$scenario_file" ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        read -r entry_tick if_name rx tx rxfifo txfifo ifindex <<<"$line"
        [[ "$entry_tick" == "$tick" ]] || continue

        mkdir -p "$sysfs_root/class/net/$if_name/statistics"
        echo "$rx" >"$sysfs_root/class/net/$if_name/statistics/rx_packets"
        echo "$tx" >"$sysfs_root/class/net/$if_name/statistics/tx_packets"
        echo "$rxfifo" >"$sysfs_root/class/net/$if_name/statistics/rx_fifo_errors"
        echo "$txfifo" >"$sysfs_root/class/net/$if_name/statistics/tx_fifo_errors"
        echo "$ifindex" >"$sysfs_root/class/net/$if_name/ifindex"

        _link_spidev "$if_name" "${spi_of_if[$if_name]:-}"
    done <"$scenario_file"
fi
