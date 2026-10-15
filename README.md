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

```bash
git clone --recursive https://github.com/OEDO-Dynamics/can_tools.git
cd can_tools
sudo ./install.sh
```

This installs can_tools to `/opt/can_tools`, copies the `canhat_fd_rename`/
`canhat_fd_setup` systemd units into `/etc/systemd/system` and enables them,
and creates `/run/can_tools` and `/var/lib/can_tools` (plus a `tmpfiles.d`
drop-in so they survive a reboot). `canhat_plus_*` (CAN HAT **Plus**
hardware) is never installed or enabled by `install.sh`, under any flag -
see "CAN HAT Plus" below for the manual setup. It is **idempotent** and
**non-destructive**:
- Files are only written if their contents changed.
- Existing configuration (`/opt/can_tools/can_tools.conf`) is never
  overwritten; `install.sh` creates it (empty) only on first install, and
  `can_tools.conf.example` is always refreshed alongside it so the two never
  drift apart.
- Running services are never stopped or restarted by `install.sh` - **not
  even `canhat_fd_setup.service`**. Bringing CAN interfaces down/up while the
  machine is live was the trigger for a prior field incident (see the
  "Applying configuration changes" note below).
- A legacy unit that was deployed as a symlink straight into
  `/opt/can_tools/*.service` is replaced with a real copy (same no-restart
  guarantee).
- The retired `can_monitor.timer`/`can_monitor.service` are stopped,
  disabled and removed if still present from an older install;
  `/var/log/can_monitor.log` itself is left alone.

To see what would change without touching anything:
```bash
sudo ./install.sh --check
```
It prints a `diff -u` for every file that would change and exits non-zero if
there is anything to install; running it twice in a row should show no
differences and exit 0.

### Configuration

`/opt/can_tools/can_tools.conf` is read if it exists, otherwise built-in
defaults apply. `install.sh` already creates an empty copy (all lines
commented out) on first install - write only the keys you want to override:
```bash
sudo nano /opt/can_tools/can_tools.conf
```

**Key settings:**
- `CAN_IFACES` - Space-separated interface names (default: `can0 can1`)
- `CAN_SPI_MAP` - SPI device to interface name mapping (default: `spi0.0:can0 spi1.0:can1`)
- `CAN_BITRATE` - Bitrate in bps (default: `250000`)
- `CAN_FD` - Enable CAN FD (default: `off` - the edge apps don't use FD; see Issue #9 論点 C)
- `CAN_RESTART_MS` - kernel auto-restart on bus-off, in ms, `0` disables it (default: `0` - the resident watchdog (`can_watchdog.service`) owns bus-off recovery instead; see Issue #9)
- `CAN_TXQUEUELEN` - TX queue length (default: `10`)

For full option details, see `/opt/can_tools/can_tools.conf.example`.

#### Applying configuration changes

A conf edit (or a reinstall that updates a script) only takes effect:
- at the **next reboot**, or
- by running `sudo systemctl restart canhat_fd_setup.service` while the
  **machine is stopped** (hydraulics locked, implement down, key state
  decided).

Never restart it, or run `ip link set ... down/up`, while the machine is
live - bringing CAN down/up while the controller is sending/receiving is
what caused the 2026-10-14 incident. Until the next reboot (or that manual,
machine-stopped restart), the running `canhat_fd_setup.service` keeps using
the previously-applied settings.

### Systemd Services

**CAN HAT FD** (supports CAN FD at 2 Mbps data rate): `install.sh` already
installs and enables these units; they are started by systemd itself at boot
(`WantedBy=multi-user.target`). Use `systemctl status`/`journalctl -u` to
check them - don't `systemctl start`/`restart` them manually on a live
machine (see above).
```bash
sudo systemctl status canhat_fd_rename.service canhat_fd_setup.service
```

**CAN HAT Plus** (standard CAN only, different hardware from CAN HAT FD) is
out of scope for `install.sh` - it is never installed or enabled, under any
flag. `canhat_plus_*` has no ordering or locking relationship with
`canhat_fd_setup.service`, so enabling both on the same machine lets them
race each other (and overwrite each other's `txqueuelen`/`restart-ms`, or
leave an interface down if the FD parameters land on CAN HAT Plus/MCP2515
hardware, which doesn't support CAN FD). On an actual CAN HAT Plus machine,
set it up by hand instead:
```bash
# Make sure the FD units are not also enabled on this machine:
sudo systemctl disable canhat_fd_rename.service canhat_fd_setup.service

# Install the plus units yourself (install.sh never does this):
sudo cp canhat_plus_rename.service canhat_plus_setup.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now canhat_plus_rename.service canhat_plus_setup.service
```
`canhat_plus_setup.bash`/`canhat_plus_rename.bash`/`enable_canhat_plus.sh`
are copied to `/opt/can_tools` by `install.sh` regardless (harmless - they
are never run unless a unit or you invoke them). Note that `can_watchdog`
(once it exists) is FD-only for now - it is not meant to run on a CAN HAT
Plus machine.

**Do not run `install.sh` on a CAN HAT Plus machine once it is set up this
way.** `install.sh` unconditionally (re-)enables `canhat_fd_rename.service`/
`canhat_fd_setup.service` on every run, which would undo the `systemctl
disable` above and put the machine back into the FD/Plus race this section
exists to avoid. Update a CAN HAT Plus machine by hand too - copy over the
changed files/units yourself instead of running `install.sh`.

## Operation

### System Architecture

The CAN subsystem starts in this boot sequence order:

1. `canhat_fd_rename.service` - Detects CAN HAT FD hardware and renames
   kernel device nodes to user-facing interface names (`can0`, `can1`).
2. `canhat_fd_setup.service` - Configures interface bitrate, bus-off handling,
   CAN FD support, and other kernel settings via `ethtool` / sysfs.
3. `can_watchdog.service` - Resident watchdog (systemd `Type=notify`) that
   monitors interface health and recovers from error conditions.

`can_watchdog` is **FD-only**: it is never enabled on a CAN HAT Plus machine.
The watchdog starts only after both interfaces are set up (implied by the
systemd dependency chain), and before any application or container that
speaks CAN begins.

### Deployment Workflow

**Step 1: Verify what would change (optional but recommended)**

Before installing, see what files would be updated:
```bash
sudo ./install.sh --check
```

This prints a unified diff for every file that would change and exits
non-zero if there is anything to do. Running it twice in a row should show no
differences and exit 0.

**Step 2: Install or upgrade**

```bash
sudo ./install.sh
```

`install.sh` is **idempotent and non-destructive**:
- Files are only written if their contents differ from what is installed.
- Running services are never stopped or restarted; CAN interfaces stay up.
- Existing configuration (`/opt/can_tools/can_tools.conf`) is never
  overwritten; `can_tools.conf.example` is always refreshed so the two never
  drift apart.

**Step 3: Apply new settings**

A configuration change (edit to `/opt/can_tools/can_tools.conf`, or a
reinstall that updates a script) only takes effect at the **next reboot**.
Do not restart `canhat_fd_setup.service` or run `ip link set ... down/up`
while the machine is live—this will disconnect the CAN bus while the
controller is running, risking lost commands. Until the next reboot:

- The `can_watchdog` continues using the previous settings.
- Any new settings (e.g., `CAN_RESTART_MS=0`, `CAN_BERR_REPORTING=off`,
  `CAN_FD=off`) are observed by the watchdog as a **mismatch** (`reason=config_mismatch_reboot_required`
  in the logs). The watchdog reports it but does not apply changes.

**To apply settings safely:** Shut down the machine (hydraulics locked,
implement lowered, key state decided), then reboot. Never restart services
on a live machine.

### Watchdog Behavior and Logging

Once running, `can_watchdog.service` monitors each CAN interface for faults
and recovers autonomously from most error conditions. **It does not
automatically reboot the machine** (see Issue #10).

#### ERROR-WARNING and ERROR-PASSIVE (TX flush)

When an interface enters ERROR-WARNING or ERROR-PASSIVE state, the watchdog
flushes pending TX frames on that interface to prevent stale commands from
resending indefinitely after recovery. (This is critical for interfaces where
the ECU only listens—old commands must not re-execute after a transient error.)

The watchdog **does not** modify the interface state itself or clear error
counters; the kernel does that.

#### Bus-Off Recovery

If bus-off is detected (`state_val == BUS-OFF`), the watchdog:
1. Waits for an exponential backoff period (starting at 1 second, max 30 s).
2. Performs an unbind/bind cycle (removes and re-probes the CAN interface).
3. Increments a per-hour rebind quota (max 3 rebinds per hour per interface).
4. Logs the action with `reason=busoff_recovery`.

If the bus-off repeats too frequently (storm), or rebinds hit the quota, the
interface enters **degraded mode** (see below).

#### RX-Offload Stall Detection (rx-offload)

On some hardware (CAN HAT FD), the kernel's rx-offload queue can stall,
leaving received frames buffered in hardware but not surfaced to the
application. The watchdog detects this by monitoring interface statistics:

- If `rx_packets` is not increasing but `rx_fifo_errors` or `tx_fifo_errors`
  is increasing, a stall is suspected.

When a stall is detected, the watchdog performs an unbind/bind cycle to
unblock the queue. This is logged with `reason=stall_detected`.

#### Degraded Mode

If recovery is not possible—e.g., after several rebind failures, or a
persistent hardware fault—the interface is marked as degraded
(`/run/can_tools/degraded_<iface>`). In degraded mode:

- The watchdog **logs CRIT** (critical level) every 10 minutes with
  `reason=manual_reboot_required`.
- The watchdog only **observes and reports**; it does not attempt further
  recovery actions.

To manually clear degraded mode after repair:
```bash
can_watchdog.sh --clear-degraded can0  # or can1
```

#### Reading Watchdog Logs

View logs with:
```bash
journalctl -u can_watchdog -n 50 -f  # last 50 lines, follow
```

**Common log format:**
```
iface=can0 reason=<reason> <details> degraded=0 rx=... tx=... rxfifo=... txfifo=...
```

**Reason codes you may see:**
- `stall_detected` - rx-offload stall detected, unbind/bind in progress.
- `busoff_recovery` - bus-off detected, recovering with unbind/bind.
- `busoff_storm` - bus-off repeated too often; now in degraded mode.
- `config_mismatch_reboot_required` - Configuration differs from running
  settings. Reboot to apply.
- `admin_down` - Interface manually brought down (`ip link set ... down`).
- `pause` - Watchdog paused (see "Pause and Diagnostics" below).
- `berr_on` - Bus-error reporting is ON (usually temporary during diagnostics).
- `manual_reboot_required` - Degraded mode; manual intervention needed.
- `rtnl_hung` - The netlink socket is blocked (unbind/bind command did not
  complete). See "Netlink Hangs" below.

**Log levels:**
- `crit` - Manual intervention likely needed (degraded, storm, timeout, OOPs).
- `err` - Error condition (flush, rebind attempt, etc.).
- `warn` - Informational warnings.
- `notice` - State transitions and routine actions.

#### Diagnosing a Stopped Interface

If frames are not flowing, check sysfs counters:
```bash
cat /sys/class/net/can0/statistics/rx_packets     # should be increasing
cat /sys/class/net/can0/statistics/rx_fifo_errors # usually 0
cat /sys/class/net/can0/statistics/tx_fifo_errors # usually 0
```

**Stopped condition:** `rx_packets` is not increasing *and*
`rx_fifo_errors` or `tx_fifo_errors` is increasing. The watchdog will
detect and attempt recovery; if it fails, the interface goes degraded.

Note: `ip -s link show can0` shows different fields and does not include
fifo errors. Use sysfs directly (above).

**Manual recovery:** Shut down the machine (hydraulics locked, implement
lowered) and reboot.

### Pause and Diagnostics

#### Pause (watchdog temporary suspension)

The watchdog can be temporarily paused:
```bash
can_pause [MINUTES]       # pause for MINUTES (default: 30 min)
can_unpause               # resume immediately
```

While paused, the watchdog:
- Continues running but enters observe-only mode (`reason=pause`).
- Does not perform recovery actions (unbind/bind, TX flush).
- Does not attempt to clear degraded state.

Pause is useful when intentionally disconnecting hardware or running
diagnostics without watchdog interference.

#### can_diag.sh (CAN Bus Diagnostics)

**BENCH / MACHINE-STOPPED USE ONLY.** Do not run this on a live machine.

The diagnostic tool captures error frames and bus statistics for up to 60
seconds to help debug electrical issues:

```bash
can_diag.sh        # start capturing (uses all interfaces)
can_diag.sh can0   # capture on a single interface
```

Sequence:
1. Pauses the watchdog (via `can_pause`).
2. Temporarily enables bus-error reporting on all interfaces.
3. Captures error frames with `candump -L` and sysfs snapshots.
4. Always restores original settings, even if interrupted.
5. Resumes the watchdog (via `can_unpause`).

After `can_diag.sh` exits, the watchdog may remain paused for up to 2
minutes (pause duration is part of the diagnostic lock). Wait for it to
resume automatically, or run `can_unpause` to return to normal operation
immediately.

### Netlink Hangs (rtnl_hung)

When performing unbind/bind recovery, the watchdog uses the netlink socket
to communicate with the kernel. If an unbind command hangs (e.g., due to a
hardware issue or kernel bug), the netlink socket remains blocked.

**If a single interface's unbind hangs:**
- Only that interface is affected (`reason=rtnl_hung`).
- It enters degraded mode (manual reboot required).

**If unbind affects multiple interfaces or is system-wide:**
- The netlink lock is held by the blocked unbind command.
- All CAN interfaces show `reason=rtnl_hung`, even healthy ones.
- The watchdog logs CRIT and waits for manual recovery.

**Manual recovery:** Shut down the machine and reboot. There is no way to
recover without a reboot when the netlink socket is hung.

### CAN HAT Plus (Standard CAN)

The notes in the "Systemd Services" section about CAN HAT Plus still apply:

- `install.sh` does not install or enable `canhat_plus_*` units.
- `can_watchdog` is FD-only and will not run on a CAN HAT Plus machine.
- Set up CAN HAT Plus by hand (see the "Systemd Services" section).

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
