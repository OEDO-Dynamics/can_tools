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

> [!WARNING]
> **Never edit `/opt/can_tools/can_tools.conf` while the machine is live, and
> never run `systemctl restart canhat_fd_setup.service` or `ip link set ...
> down/up` by hand while it is live.** `can_watchdog.service` re-reads the
> conf file on **every cycle** (every `WD_LOOP_S`, 1 s by default) - it does
> **not** wait for a reboot the way this used to be documented. See
> [`docs/can_watchdog.md`](docs/can_watchdog.md#configuration-is-re-read-live-the-dangerous-part)
> for exactly which keys take effect immediately, which ones only pause the
> watchdog (safe), and which ones get applied live to a running interface the
> next time the watchdog happens to flush/recover it (dangerous - this is how
> the 2026-10-14 incident happened). Only edit the conf with the machine
> mechanically stopped (hydraulics locked, implement lowered, key state
> decided), and reboot (or restart `canhat_fd_setup.service`, still with the
> machine stopped) right after.

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

This section is an overview; the full operator runbook (complete reason-code
table, CRIT triage, `--clear-degraded` caveats, the exact `can_pause`/
`can_diag.sh` invocations, and the manual unbind/bind procedure) is in
[`docs/can_watchdog.md`](docs/can_watchdog.md). Read that before touching a
machine that is in operation.

### System Architecture

The CAN subsystem starts in this boot sequence order:

1. `canhat_fd_rename.service` (`Type=oneshot`, `After=network.target`) -
   pins `can0`/`can1` to their physical SPI devices per `CAN_SPI_MAP`
   (default `spi0.0:can0 spi1.0:can1`) using the lib's `can_pin_name`
   (`ip link set <iface> down` then `... name <want>`, with a probe-order
   swap if the two SPI devices enumerate in the opposite order).
2. `canhat_fd_setup.service` (`Type=oneshot`, `After=canhat_fd_rename.service`)
   - brings each interface up via the lib's `can_setup_iface`: `ip link set
   <if> down` then `up type can bitrate ... restart-ms ... berr-reporting ...
   [dbitrate ... fd on | fd off]`, then `ip link set <if> txqueuelen ...`.
   **No `ethtool` is used or installed** on the machine - everything goes
   through `ip link set` / sysfs.
3. `can_watchdog.service` (`Type=simple`, `Restart=always`,
   `Wants=canhat_fd_setup.service`, `After=canhat_fd_setup.service`) - the
   resident watchdog described below.

There is **no `Before=` ordering** from `canhat_fd_setup.service` or
`can_watchdog.service` onto whatever application or container speaks CAN -
only the `After=` chain above between the three can_tools units themselves.
If an app or container needs to start strictly after the interfaces are up
and the watchdog is running, that has to be arranged on the consumer's own
unit (or handled by the app's own reconnect-on-ENETDOWN logic; see
`CAN_DEPENDENT_UNITS` in `docs/can_watchdog.md`).

`can_watchdog` is **FD-only**: `install.sh` only ever installs/enables it
alongside the FD units, and it is never enabled on a CAN HAT Plus machine
(see "CAN HAT Plus" below).

### Deployment Workflow

**Step 1: Verify what would change (optional but recommended)**

```bash
sudo ./install.sh --check
```

Prints a unified diff for every file that would change and exits non-zero if
there is anything to do. `install.sh --check` run again right after a plain
`install.sh` should show no differences and exit 0 (running `--check` twice
in a row with **no** `install.sh` in between shows the same diff both times -
`--check` itself never changes anything).

**Step 2: Install or upgrade**

```bash
sudo ./install.sh
```

Idempotent and non-destructive: files are only written if their contents
differ, running services are never stopped/restarted/bounced, and an
existing `/opt/can_tools/can_tools.conf` is never overwritten. The legacy
`can_monitor.timer`/`can_monitor.service` units **are** stopped, disabled and
removed by this step if still present - that is the one "stops a service"
exception, and it is intentional (`can_monitor` is retired).

**Step 3: Apply new settings - machine stopped, not live**

See the warning in "Applying configuration changes" above and
[`docs/can_watchdog.md`](docs/can_watchdog.md#configuration-is-re-read-live-the-dangerous-part):
`can_watchdog` re-reads the conf **every cycle**, not at reboot. Some keys
(`WD_*`, `CAN_FLUSH_IFACES`, `CAN_DEPENDENT_UNITS`) take effect immediately
and safely. Changing `CAN_RESTART_MS` / `CAN_BERR_REPORTING` / `CAN_FD` makes
the watchdog detect a mismatch against the still-running kernel settings and
switch that interface to **observe-only** (`reason=config_mismatch_reboot_required`)
until a reboot (or a machine-stopped `canhat_fd_setup.service` restart)
actually applies them. Changing `CAN_BITRATE` / `CAN_DBITRATE` /
`CAN_TXQUEUELEN` is **not** checked for a mismatch at all, so it is applied
live, to a running interface, the next time the watchdog calls
`can_setup_iface` for any reason (a TX flush, a bus-off recovery, a stall
rebind) - with the machine still operating. Only ever edit the conf with the
machine mechanically stopped, then reboot (or restart
`canhat_fd_setup.service`, still stopped) right away.

### Watchdog Behavior and Logging

Once running, `can_watchdog.service` monitors each CAN interface every
`WD_LOOP_S` (1 s default) and recovers autonomously from most error
conditions. **It does not automatically reboot the machine** (see Issue #10).
A one-paragraph summary of each mechanism follows; see
[`docs/can_watchdog.md`](docs/can_watchdog.md) for the exact conditions,
backoff schedules and the complete reason-code table.

- **TX flush** (ERROR-WARNING/ERROR-PASSIVE, `CAN_FLUSH_IFACES`, default
  `can0` only): if all of rx/tx/rx_fifo/tx_fifo stay unchanged for 2
  consecutive cycles, the watchdog re-runs `can_setup_iface` (a down/up) to
  discard stale queued TX frames so they are not resent once the ECU comes
  back. Any other time the interface is in ERROR-WARNING/ERROR-PASSIVE, the
  watchdog does not touch it at all.
- **Bus-off recovery**: on `BUS-OFF`, the watchdog waits for the rx-offload
  queue to settle, then re-runs `can_setup_iface` (down/up; the ifindex does
  not change, so application sockets stay valid). Repeated bus-off within a
  short window backs off exponentially (1 s up to 30 s); a storm (5+ within
  60 s) logs one CRIT but recovery keeps running.
- **rx-offload stall detection**: if `rx_packets` is flat while
  `rx_fifo_errors`/`tx_fifo_errors` keep growing for 3 consecutive cycles
  (or 2 cycles right after a bus-off recovery, or 3 bus-off recoveries in a
  row with no rx progress), the watchdog performs an **unbind/bind** cycle
  (not a down/up - the rx-offload lock this works around survives a plain
  down/up). This changes the ifindex, so any application holding an open CAN
  socket must reopen it; see `CAN_DEPENDENT_UNITS` in
  `docs/can_watchdog.md` to restart specific units/containers afterward.
- **Degraded mode**: if a step above cannot complete (Oops/BUG detected in
  the kernel log, an unbind/bind timeout, a rebind-quota overrun, 3
  consecutive `ip` timeouts system-wide, ...), the affected interface(s) are
  marked degraded (`/run/can_tools/degraded_<iface>`) and the watchdog stops
  touching them - it only re-logs a CRIT every 10 minutes
  (`reason=manual_reboot_required`). See `docs/can_watchdog.md` for which
  reasons are safe to clear with `can_watchdog.sh --clear-degraded <if>` and
  which genuinely require a reboot.

#### Reading Watchdog Logs

```bash
journalctl -u can_watchdog -n 50 -f      # last 50 lines, follow
journalctl -u can_watchdog -p crit       # CRIT lines only (degraded/storm/Oops/etc.)
```

Common log line shape: `iface=<if> reason=<reason> <details...>` (a repeated
`iface+reason` pair is rate-limited to one line per `WD_LOG_RATE_S`, with
`suppressed=N` on the next line that does get through). The 60 s periodic
INFO summary line (`iface=.. rx=.. tx=.. rxfifo=.. txfifo=.. ifindex=..
degraded=0|1`) has no `reason=` field - that is the only line with
`degraded=`. See `docs/can_watchdog.md` for the full reason-code table and
what each one means operationally.

#### Diagnosing a Stopped Interface

```bash
cat /sys/class/net/can0/statistics/rx_packets     # should be increasing
cat /sys/class/net/can0/statistics/rx_fifo_errors # usually 0 / not growing
cat /sys/class/net/can0/statistics/tx_fifo_errors # usually 0 / not growing
```

`rx_packets` flat while `rx_fifo_errors`/`tx_fifo_errors` grow, for 3
consecutive watchdog cycles, is exactly the rx-offload stall signal above -
the watchdog is already acting on it; you do not need to intervene unless it
shows up as degraded. `ip -s link show can0` does not expose the fifo
counters - use sysfs as above.

### Pause and Diagnostics

See [`docs/can_watchdog.md`](docs/can_watchdog.md#pause) for the working
`can_pause`/`can_unpause`/`can_diag.sh` invocations and for `can_diag.sh`'s
actual argument (a duration in seconds, not an interface name), output path,
and what to do if it was killed with SIGKILL mid-capture. In short:
- `can_pause`/`can_unpause` are **shell functions in `can_tools_lib.bash`**,
  not standalone commands - there is nothing on `$PATH` called `can_pause`.
- `can_diag.sh` is **bench / machine-stopped use only**: it pauses the
  watchdog and turns on bus-error reporting on every interface while it
  captures.

### Netlink Hangs (rtnl_hung)

`rtnl_hung` is a **global, all-interface** condition, not a per-interface
one: every watchdog cycle calls one bounded `ip -d link show type can` to
read interface state; if *that call itself* (not an unbind/bind) times out
for `WD_RTNL_HUNG_CONSEC` (3) consecutive cycles, **every** configured
interface is marked degraded with `reason=rtnl_hung`, and the watchdog stops
calling `ip` at all - it falls back to sysfs-only observation for everything
until a reboot. A single interface's unbind hanging instead produces
`reason=unbind_timeout` on just that interface (see
`docs/can_watchdog.md`). Either way, recovery is **manual reboot only** -
there is no live recovery from a genuinely hung netlink socket.

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
