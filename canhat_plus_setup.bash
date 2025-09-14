#!/bin/bash
sudo ip link set $1 down
sudo ip link set $1 up type can bitrate $2 restart-ms 1000
sudo ip link set $1 name $1
sudo ifconfig $1 txqueuelen 65536

