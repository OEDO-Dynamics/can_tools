# can\_tools

## Installation

### Prerequisites

- Linux system (Raspberry Pi with CAN HAT, PCAN interface, or virtual CAN)
- Optional: `can-utils` (for development/debugging)
  ```bash
  # Build and install can-utils (optional)
  cd can-utils
  mkdir build && cd build
  cmake .. && make -j$(nproc) && sudo make install
  ```

### Quick Install

Install can_tools to `/opt/can_tools`:
```bash
cd can_tools
sudo bash install.sh
```

The installer is **idempotent** and **non-destructive**:
- Files are only updated if changed
- Existing configuration (`/opt/can_tools/can_tools.conf`) is never overwritten
- Running services are not restarted

### Configuration

Configuration is read from `/opt/can_tools/can_tools.conf` (if it exists) or uses built-in defaults. Create a configuration file by copying the example:
```bash
sudo cp /opt/can_tools/can_tools.conf.example /opt/can_tools/can_tools.conf
sudo nano /opt/can_tools/can_tools.conf
```

**Key settings:**
- `CAN_IFACES` - Space-separated interface names (default: `can0 can1`)
- `CAN_SPI_MAP` - SPI device to interface name mapping (default: `spi0.0:can0 spi1.0:can1`)
- `CAN_BITRATE` - Bitrate in kbps (default: `250000`)
- `CAN_FD` - Enable CAN FD (default: `on`)
- `CAN_TXQUEUELEN` - TX queue length (default: `10`)

For full option details, see `/opt/can_tools/can_tools.conf.example`.

### Systemd Services

After installation, enable the appropriate setup service for your hardware:

**CAN HAT FD** (supports CAN FD at 2 Mbps data rate):
```bash
sudo systemctl enable canhat_fd_rename.service canhat_fd_setup.service
sudo systemctl start canhat_fd_rename.service canhat_fd_setup.service
sudo systemctl status canhat_fd_setup.service
```

**CAN HAT Plus** (standard CAN only):
```bash
sudo systemctl enable canhat_plus_rename.service canhat_plus_setup.service
sudo systemctl start canhat_plus_rename.service canhat_plus_setup.service
sudo systemctl status canhat_plus_setup.service
```

**CAN Monitor Service** (optional, watches interface health):
```bash
sudo systemctl enable can_monitor.service
sudo systemctl start can_monitor.service
sudo journalctl -u can_monitor.service -f  # View logs
```

### Check for Installation Changes

To see what would be changed without making any changes:
```bash
sudo CHECK_MODE=1 bash install.sh
```

## CAN Interface Setup

### PCAN setup
```bash
cd <workspace>/can_tools
# interface: can0, bitrate: 250000
./peakcan_setup.bash can0 250000
```

### CAN Hat setup (Raspberry Pi)
```bash
cd <workspace>/can_tools
# Setup can0 and can1 with bitrate 250000
./enable_can_hat.sh

# Or manually for single interface
./can_hat_setup.bash can0 250000
```

### Virtual CAN setup (for testing)
```bash
cd <workspace>/can_tools
# Create virtual CAN interface
./vcan_setup.bash vcan0
```

### Serial Line CAN setup
```bash
cd <workspace>/can_tools
# Setup CAN via serial device
./can_setup.bash can0 [baud_rate] [device_path]
```

## CAN Traffic Monitoring

### Monitor CAN traffic with candump
```bash
# Basic monitoring
candump can0

# With timestamps
candump -t a can0        # absolute timestamp
candump -t d can0        # delta timestamp

# Save to log file
candump -l can0          # auto-save to file
candump -L can0          # log format to stdout

# With filters
candump can0,123:7FF     # only ID 123
candump can0,100~700     # exclude range 100-700
candump can0,#FFFFFFFF   # only error frames

# Colored output and other options
candump -c can0          # colored output
candump -a can0          # show ASCII data
candump -n 100 can0      # stop after 100 frames
candump any              # monitor all CAN interfaces
```

### Record CAN traffic
```bash
cd <workspace>/can_tools
# Use included script to record CAN traffic
./record_can.bash can0
```

## Sending CAN Data

### Send individual CAN frames with cansend
```bash
# Basic frame sending
cansend can0 123#DEADBEEF           # standard frame with data
cansend can0 5A1#11.22.33.44        # formatted data bytes
cansend can0 123#                   # empty frame
cansend can0 123#R                  # RTR frame
cansend can0 123##1122              # CAN FD frame

# Extended frames (29-bit IDs)
cansend can0 12345678#112233        # extended ID frame
```

### Generate CAN traffic
```bash
# Random traffic generation
cangen can0                         # random frames
cangen -g 100 can0                  # 100ms intervals
cangen -I 123 can0                  # specific CAN ID

# Sequential frames
cansequence can0                    # incrementing sequence numbers
```

### Protocol-specific tools
```bash
# ISO-TP (ISO 15765-2) communication
echo "test data" | isotpsend can0

# J1939 protocol examples
testj1939 -s can0:0x80 can0:0x40,0x12300    # unicast
testj1939 -B -s can0:0x80 :,0x3ffff         # broadcast

# Replay recorded CAN traffic
canplayer -I candump.log can0=can0
```

## OpenIMU Configuration

### Set OpenIMU unit address via CAN
```bash
cd <workspace>/can_tools/openimu
# Change unit address from 0x81 to 0x90 on can0
./set_sa.bash 81 90 can0
```

## Troubleshooting

### Check CAN interface status
```bash
ip link show can0                   # check interface status
ifconfig can0                       # detailed interface info
```

### Bring CAN interface down
```bash
cd <workspace>/can_tools
./can_down.bash can0
```

### Common issues
- **Permission denied**: Make sure scripts are executable (`chmod +x script.bash`)
- **Interface not found**: Check if CAN hardware is properly connected
- **No frames received**: Verify bitrate matches other CAN devices
- **Service fails to start**: Check systemd service logs with `systemctl status can_hat_setup.service`
