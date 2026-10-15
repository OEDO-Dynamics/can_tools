# can_watchdog operator runbook

This is the operator-facing companion to
[Issue #9](https://github.com/OEDO-Dynamics/can_tools/issues/9) ("CAN 監視を
常駐ウォッチドッグへ置き換える"), summarizing the design that issue settled on
and documenting exactly how to operate it: reading logs, clearing degraded
mode safely, pausing for diagnostics, and the manual unbind/bind procedure.
Where this file says a script does X, the claim is backed by the specific
`file:line` in this repo - if the two ever disagree, the code is correct and
this file is stale (please file an issue).

`can_watchdog.sh` replaces the old `can_monitor.sh`/`.service`/`.timer`
(removed from this repo). It owns recovery of every interface in
`CAN_IFACES` end to end: TX flush, bus-off recovery, rx-offload stall
detection/recovery, and degraded mode when none of those can recover the
interface. It does **not** automatically reboot the machine - that is
tracked separately in Issue #10.

## Configuration is re-read live (the dangerous part)

**Operating rule, no exceptions: never edit `/opt/can_tools/can_tools.conf`
while the machine is running.** The rest of this section explains *why*, key
by key - it is background for understanding what the watchdog is doing, not
a list of keys that are safe to touch live. There is no such list: even a
key that the watchdog itself applies harmlessly (`WD_*`) can reach a script
that is not harmless (`CAN_FLUSH_IFACES` feeds straight into a down/up of
whatever interface you add to it - see below), and `CAN_IFACES`/
`CAN_SPI_MAP` are read at boot by `canhat_fd_rename.bash`/`enable_canhat_fd.sh`
*and* every cycle by the watchdog (see below), with no mismatch-detection
safety net for them. Edit the conf only with
the machine mechanically stopped, then reboot (or, still stopped, restart
`canhat_fd_setup.service`) right after.

Every cycle (`_wd_cycle`, called every `WD_LOOP_S`, 1 s by default) calls
`can_read_conf` unconditionally (`can_watchdog.sh:1029`) - the watchdog does
**not** wait for a reboot or a service restart to pick up a conf change the
way `install.sh`'s own "config changes apply at the next reboot" message
might suggest for the *interface setup* units. What actually happens per key:

- **`WD_*`, `CAN_FLUSH_IFACES`, `CAN_DEPENDENT_UNITS`**: take effect on the
  very next watchdog cycle, with no mismatch check and no observe-only
  fallback. That immediacy is exactly the danger: adding an interface to
  `CAN_FLUSH_IFACES` while the machine is running means the very next
  ERROR-WARNING/PASSIVE stall-free window on that interface triggers a live
  down/up (TX flush) on it - including an interface that was not being
  flushed a moment ago.
- **`CAN_RESTART_MS` / `CAN_BERR_REPORTING` / `CAN_FD`**: compared every
  cycle against what `ip -d link show type can` reports is *actually running*
  on the kernel side (`can_watchdog.sh:916-920`, using the same
  `restart_ms=`/`berr=`/`fd=` fields `can_iface_states` already parsed out of
  one `ip -d link show` call - `can_tools_lib.bash:380-448`). The moment any
  of these three differs from the conf, that interface flips to
  **observe-only** (`reason=config_mismatch_reboot_required`,
  `can_watchdog.sh:916-920`) and **all** of TX flush, bus-off recovery and
  stall/rebind are suspended for it (`can_watchdog.sh:978-987`) until the
  mismatch clears - normally by rebooting (or, with the machine mechanically
  stopped, restarting `canhat_fd_setup.service`), either of which re-applies
  the interface with the new values so they match the conf again.
  - If the interface was already sitting at `restart-ms 0` (the shipped
    default) when you change `CAN_RESTART_MS`, bus-off on that interface is
    recovered by **nobody** until the mismatch is resolved: the kernel will
    not auto-restart it (`restart-ms 0`), and the watchdog refuses to act on
    a mismatched interface (`can_watchdog.sh:1007-1010`, gated by the
    `observe_only` check at `can_watchdog.sh:987`).
- **`CAN_BITRATE` / `CAN_DBITRATE` / `CAN_TXQUEUELEN`**: **not compared at
  all**. `can_iface_states` never extracts bitrate/dbitrate/txqueuelen from
  `ip -d link show` in the first place (`can_tools_lib.bash:406-442` only
  captures `if_state`/`restart_ms`/`berr`/`fd`/`if_admin`), so there is no
  mismatch to detect and no observe-only fallback for these three keys. The
  practical effect: editing `CAN_BITRATE` (or the other two) in the conf
  does **not** show up as a warning, and the **next time the watchdog calls
  `can_setup_iface` for any reason at all** - a TX flush
  (`can_watchdog.sh:522`), a bus-off recovery (`can_watchdog.sh:439`), or the
  final step of a stall rebind (`can_watchdog.sh:674`) - it is applied live,
  down→up, to an interface that may still be carrying live traffic. This is
  exactly the class of incident this watchdog exists to prevent elsewhere;
  do not let a conf edit reintroduce it here.
- **`CAN_IFACES` / `CAN_SPI_MAP`**: read once at boot by
  `canhat_fd_rename.bash`/`enable_canhat_fd.sh`, and separately by
  `can_watchdog.sh` every cycle (it iterates `CAN_IFACES` to decide which
  interfaces to process, and `_wd_startup_bind_check` reads `CAN_SPI_MAP`
  every cycle too). Changing either live mixes what the watchdog now thinks
  it owns with what was actually renamed/bound at boot - there is no
  mismatch check for this either, it is simply undefined which interface
  gets touched next.

**Operating rule: never edit `/opt/can_tools/can_tools.conf` while the
machine is live. Never run `systemctl restart canhat_fd_setup.service` while
it is live. Never set `CAN_RESTART_MS` to anything other than `0`, and never
run `ip link set canX type can restart-ms N` by hand** - the kernel's own
`restart-ms`-driven auto-restart would then race the watchdog's own recovery
logic and can hit `raspberrypi/linux#6916` (`can_put_echo_skb: BUG! echo_skb
N is occupied!`, escalating to a kernel Oops that has previously required a
reboot to clear; see `can_tools.conf.example`'s own warning on
`CAN_RESTART_MS`). Only ever edit the conf, or restart
`canhat_fd_setup.service`, with the machine mechanically stopped (hydraulics
locked, implement lowered, key state decided), then reboot (or, still
stopped, restart `canhat_fd_setup.service`) right away so the mismatch
window is as short as possible.

## Mechanisms

### TX flush (ERROR-WARNING / ERROR-PASSIVE)

Target: only interfaces listed in `CAN_FLUSH_IFACES` (default `can0`;
`_wd_flush_check` returns immediately for any other interface,
`can_watchdog.sh:481`). Any other time the state is ERROR-WARNING/
ERROR-PASSIVE, the watchdog does not touch the interface at all - this is
deliberate (down/up while in that state only discards traffic without fixing
anything else).

Condition: Δrx, Δtx, Δrx_fifo and Δtx_fifo are **all** zero for
`WD_STALE_TX_FLUSH_S` (2) consecutive cycles (`can_watchdog.sh:483-491`).
Right before acting, it re-reads all four counters twice, 100 ms apart, under
`can_lock`, and aborts the flush if *any* of them moved in that window
(`can_watchdog.sh:501-514`) - this re-check exists because a race here is
exactly the rx-offload lock's own trigger condition.

Action: `can_setup_iface` (a full down→up with the current conf's bitrate/
restart-ms/berr/fd/txqueuelen - the same thing a bus-off recovery or a
startup bind does), logged `reason=tx_flush` (warning) on success or
`reason=tx_flush_failed` (err) on failure (`can_watchdog.sh:539-541`).

Backoff: the first flush for an interface has no extra wait; a second flush
within the backoff window doubles 1→2→4→...→`WD_FLUSH_BACKOFF_MAX_S` (30)
(`can_watchdog.sh:526-536`). 60 continuous seconds of ERROR-ACTIVE resets the
backoff to 0 (`can_watchdog.sh:993-1004`).

### Bus-off recovery

Trigger: `state == BUS-OFF` (`can_watchdog.sh:1007-1010`).

1. **Settle**: sample `rx_packets` every `WD_SETTLE_SAMPLE_MS` (100 ms) until
   it is unchanged across 2 consecutive samples, up to `WD_SETTLE_MAX_MS`
   (2000 ms) (`_wd_settle`, `can_watchdog.sh:356-374`). If it never settles,
   the cycle logs `reason=busoff_settle_timeout` (warning) and tries again
   next cycle - no recovery action is taken this time.
2. **Backoff**: the first recovery attempt after settling has **no extra
   wait**. If a *previous* recovery on this interface completed within the
   last `WD_BUSOFF_QUIET_S` (10 s), the wait doubles: 1→2→4→...→
   `WD_BUSOFF_BACKOFF_MAX_S` (30 s) (`can_watchdog.sh:414-427`). This is
   logged `reason=busoff_recovery_backoff` (warning) while waiting.
3. **Storm detection**: if `WD_STORM_COUNT` (5) or more bus-offs occurred in
   the last `WD_STORM_WINDOW_S` (60 s), one `reason=busoff_storm` CRIT is
   logged (edge-triggered, not repeated every cycle the storm persists) and
   the backoff is pinned to its max - but **recovery keeps running**; a
   storm does **not** mark the interface degraded by itself
   (`can_watchdog.sh:394-412`).
4. **Recovery**: `can_setup_iface` (down→up, same parameters as TX flush
   above). The ifindex does **not** change, so an application's open CAN
   socket stays valid across this (`can_watchdog.sh:420`). Success logs
   `reason=busoff_recovered` (notice); failure logs
   `reason=busoff_recovery_failed` (err) and tries again next cycle, still
   subject to the backoff above.
5. **Post-recovery stall window**: for `WD_STALL_POST_BUSOFF_WINDOW_S` (5 s)
   after a successful recovery, only `WD_STALL_POST_BUSOFF_CONSEC` (2, not
   the normal 3) consecutive stall-signal cycles are needed to treat the
   interface as actually stalled (rx-offload can already have been dead
   before the bus-off, in which case down/up alone never fixes it) - see
   "rx-offload stall" below. Separately, if 3 bus-off recoveries in a row
   each leave `rx_packets` unchanged from what it was right after *that*
   recovery *and* fifo errors have grown since *that same* recovery (the
   baseline is reset after every individual bus-off recovery, not just the
   first one in the streak), that is also treated as a stall
   (`can_watchdog.sh:936-977`).

There is no `reason=busoff_recovery` in the logs - the actual reason strings
are `busoff_recovery_backoff`, `busoff_settle_timeout`, `busoff_storm`,
`busoff_recovery_failed` and `busoff_recovered`.

### rx-offload stall detection and recovery (unbind/bind)

This is the actual fix for the 2026-10-14 incident's root cause (the
kernel's rx-offload queue can self-lock in a way that a plain down/up does
not clear - only an unbind/bind, a module reload, or a reboot does).

Signal: `Δrx_packets == 0` **and** (`Δrx_fifo_errors > 0` **or**
`Δtx_fifo_errors > 0`) (`can_watchdog.sh:896-900`). Evaluated every cycle
except while the interface is in `BUS-OFF` or administratively down. It is
also evaluated (but does **not** trigger recovery) while the interface is in
observe-only mode - see "stall while observe-only" below.

Required consecutive cycles: `WD_STALL_CONSEC` (3) normally, or
`WD_STALL_POST_BUSOFF_CONSEC` (2) within the post-bus-off window described
above (`can_watchdog.sh:902-942`).

Recovery (`_wd_rebind_recover`, `can_watchdog.sh:537-666`), all under
`can_lock`:

1. Check the per-hour rebind quota for this interface
   (`WD_REBIND_MAX_PER_HOUR`, 3, counted across **every** rebind path, not
   just stall-triggered ones, and persisted in
   `/var/lib/can_tools/rebind_times_<if>` so a crash-looping watchdog process
   does not get the quota back). Exceeding it marks the interface degraded
   with `reason=rebind_quota_exceeded` and stops here.
2. **Oops/BUG pre-check**: scan `journalctl -k -b` for `Oops`, `BUG:`, `...
   nobody cared`, `IRQ handler returned`, or `echo_skb ... is occupied`
   (`_wd_precheck_oops`, `can_watchdog.sh:314-328`). If found, the interface
   is marked degraded with `reason=oops_detected` **without attempting
   unbind** - this exact sequence (unbind/bind after an IRQ thread has
   already died) hung the system on 2026-10-06.
3. `ip link set <if> down` (bounded). If *this* times out, rtnl is already
   stuck - mark degraded with `reason=down_timeout` and stop (do not also
   attempt the unbind, which would just be mis-attributed as its own hang).
4. **Unbind** the interface's spidev
   (`/sys/bus/spi/drivers/mcp251xfd/unbind`), via a bounded child that writes
   its own `<spidev>:<pid>` into `/run/can_tools/unbind_inflight` before
   writing the unbind file, so a startup check can recognize an in-flight
   unbind across a watchdog restart. Timeout → `reason=unbind_timeout`,
   degraded, **and the inflight marker is deliberately left in place**
   (the child may still be stuck inside the kernel). A non-timeout failure →
   `reason=unbind_failed`.
5. **Bind** the same spidev back
   (`/sys/bus/spi/drivers/mcp251xfd/bind`). Failure → `reason=bind_failed`.
   Then wait up to 5 s for a netdev to appear under
   `/sys/bus/spi/devices/<spidev>/net/`; none appearing → `reason=bind_no_netdev`.
6. `can_pin_name` the new netdev back to the interface's configured name. A
   name collision (rc=2) → `reason=pin_name_collision`, degraded, **no
   swap attempted** here (unlike the boot-time rename, which does swap).
   Any other pin failure → `reason=pin_name_failed`.
7. `can_setup_iface` on the freshly-bound/renamed interface. Failure →
   `reason=setup_failed`.
8. `can_unlock`, **then** (only after the lock is released) restart whatever
   is listed in `CAN_DEPENDENT_UNITS` (systemd unit names, or `docker:
   <container>`), fully detached so a slow `docker restart` can never occupy
   `can_run_bounded`'s single tracked-child slot and starve the main loop's
   own `ip` calls (`_wd_restart_dependent_units`, `can_watchdog.sh:678-689`).
   Success logs `reason=rebind_recovered` (notice).
9. **Verification window**: for `WD_STALL_VERIFY_S` (10 s) after a
   successful rebind, positive evidence of a stall (`Δrx == 0` with fifo
   errors growing) immediately fails verification →
   `reason=rebind_verify_failed`, degraded. A quiet bus (everything flat,
   e.g. because `can1` is receive-only and the other node has also gone
   quiet) is treated as success and normal detection resumes.

**The ifindex changes across an unbind/bind** - any application with an open
socket on that interface must reopen it. `CAN_DEPENDENT_UNITS` only restarts
what you explicitly list; everything else is expected to reconnect on its
own (ENODEV/ENETDOWN) per Issue #9's 論点 A.

There is no `reason=stall_detected` in the logs - a *detected and acted-on*
stall produces whatever `_wd_rebind_recover` reason fires (most commonly
`rebind_recovered` on success), and a stall detected while the interface is
**not** eligible for action (see next section) produces
`reason=stall_detected_observe_only`.

### Stall detected while observe-only

If the stall signal above fires while the interface is paused,
administratively down, config-mismatched, or has effective
berr-reporting=on, the watchdog does **not** attempt recovery but still logs
`reason=stall_detected_observe_only` at **crit** (rate-limited, not forced)
so the condition is visible to an operator even before a reboot resolves the
underlying mismatch (`can_watchdog.sh:944-946`).

### Startup reconciliation

On every cycle (not just the first), before reading interface states, the
watchdog checks every `CAN_SPI_MAP` entry's spidev for a driver binding
(`_wd_startup_bind_check`, `can_watchdog.sh:707-790`):

- A spidev with no driver bound, and no pause active, and not already
  degraded, gets bound → pinned → set up automatically (this is what
  reconciles a watchdog restart that happened mid-rebind).
- **While a pause is active, a driver-less spidev is left alone** - this is
  what lets you unbind an interface by hand for maintenance without the
  watchdog immediately binding it back (see "Manual unbind/bind" below).
- If the unbind-inflight marker from a timed-out unbind (above) is still
  live (its recorded pid still exists and its `/proc/<pid>/cmdline` still
  matches the unbind child's signature), the interface is marked degraded
  with `reason=unbind_inflight_at_startup` and left alone - the underlying
  unbind may still be running.
- A bind failure here produces `reason=bind_failed_at_startup`; no netdev
  appearing produces `reason=bind_no_netdev`; a name collision produces
  `reason=pin_name_collision`; another pin failure produces
  `reason=pin_name_failed`; a `can_setup_iface` failure on the freshly
  bound/pinned interface produces `reason=setup_failed_at_startup` - all of
  these mark the interface degraded.

### Netlink hangs (`rtnl_hung`) - global, not per-interface

Every cycle calls exactly one bounded `ip -d link show type can` to read
every interface's state (`can_iface_states`). If *that single call* times
out for `WD_RTNL_HUNG_CONSEC` (3) **consecutive cycles**, **every**
configured interface (not just one) is marked degraded with
`reason=rtnl_hung`, and a global `rtnl_hung_active` marker is written so
subsequent cycles skip calling `ip` entirely and only re-announce each
interface's existing degraded state from sysfs
(`can_watchdog.sh:1013-1046`). This is categorically different from an
unbind hanging on a single interface, which instead produces
`reason=unbind_timeout` and degrades only that one interface. There is no
live recovery from a genuinely hung netlink socket - reboot.

## Degraded mode: CRIT triage and `--clear-degraded`

### What "degraded" means

Once `/run/can_tools/degraded_<if>` exists, the watchdog **never touches
that interface again** until it is cleared (by `--clear-degraded` or a
reboot - the marker lives on tmpfs, so a reboot clears it implicitly). It
still re-logs a CRIT every `WD_DEGRADED_CRIT_S` (600 s = 10 min),
`reason=manual_reboot_required`, with the original reason recorded as
`original_reason=...` (`_wd_handle_degraded`, `can_watchdog.sh:279-292`).
This is expected - communication to that interface is now simply absent,
and per the CTO's 2026-10-14 safety decision the application side already
treats stale/absent CAN data as "go neutral", so a degraded interface fails
safe rather than fails active. Bus-off on a degraded interface is **not**
recovered by anyone (the kernel's `restart-ms 0` does nothing, and the
watchdog is not acting on this interface).

### Where to look

- `journalctl -u can_watchdog -p crit` - every CRIT this watchdog has ever
  logged for this process's lifetime (storm, Oops, timeouts, the original
  degrade event, and the periodic `manual_reboot_required` re-announcement).
- `/run/can_tools/degraded_<if>` - contents are `<epoch>:<reason>`, the
  *original* reason that caused the degrade (`_wd_mark_degraded`,
  `can_watchdog.sh:267-277`). Gone after a reboot.
- `/var/lib/can_tools/crash/<timestamp>-<if>.txt` - a snapshot taken at the
  moment of degrading: sysfs counters plus the last 50 lines of
  `journalctl -k` (`_wd_save_crash`, `can_watchdog.sh:245-263`). Rotated to
  keep the newest `WD_CRASH_KEEP` (5) files per the whole directory.

### `--clear-degraded`: reason-dependent safety

```bash
sudo /opt/can_tools/can_watchdog.sh --clear-degraded can0   # or can1
```

This only removes the `degraded_<if>` marker (and, as a side effect, the
global `rtnl_hung_active`/consecutive-timeout markers for **every**
interface, since `rtnl_hung` is a global condition - `can_watchdog.sh:294-308`).
It does **not** reset the rebind-quota counters in `/var/lib/can_tools` -
an interface that degraded on `rebind_quota_exceeded` will likely hit the
same quota again at the next stall within the same hour window.

**Reboot instead of clearing**, for these reasons, because the underlying
condition they represent can still be live and clearing just re-arms the
exact sequence that caused it:

| Reason | Why reboot, not `--clear-degraded` |
|---|---|
| `oops_detected` | The kernel log that triggered this is still there; the next stall would hit the same pre-check again - but if it had *not* been caught, re-attempting unbind against an already-dead IRQ thread is what hung the system on 2026-10-06. |
| `unbind_timeout` | The unbind child's marker was deliberately left in place because it may still be running in the kernel (D state). Clearing degraded does not remove that marker or kill that child; a second concurrent unbind attempt against the same spidev is undefined. |
| `down_timeout` | rtnl was already confirmed stuck before unbind was even attempted. |
| `rtnl_hung` | The underlying hang (if real, not just a slow one-off) reappears identically; clearing only re-arms `ip`-based checking, it does not un-hang anything. |
| `unbind_inflight_at_startup` | Same live child as `unbind_timeout` above - the marker persists across the clear, so the interface is very likely to re-degrade on the next cycle anyway. |

For every other reason (`rebind_quota_exceeded`, `spidev_not_found`,
`unbind_failed`, `bind_failed`, `bind_no_netdev`, `pin_name_collision`,
`pin_name_failed`, `setup_failed`, `bind_failed_at_startup`,
`rebind_verify_failed`, `setup_failed_at_startup`), there is no leftover
in-flight kernel-side state, so `--clear-degraded` followed by normal
operation (or a repaired connection) is fine - the watchdog simply resumes evaluating that interface
from scratch next cycle.

## Complete reason-code table

All reasons as logged by `_wd_log`/`_wd_log_force`/`_wd_mark_degraded` in
`can_watchdog.sh` (grep `reason=` or `_wd_mark_degraded` to re-derive this
table against a future version):

| reason | level | degrades the iface? | meaning / operator action |
|---|---|---|---|
| `tx_flush` | warning | no | TX flush performed (stale queue discarded). Routine. |
| `tx_flush_failed` | err | no | `can_setup_iface` failed during a TX flush; retried with backoff next eligible cycle. |
| `busoff_recovery_backoff` | warning | no | Waiting out the bus-off backoff window before the next recovery attempt. Routine during a bus-off burst. |
| `busoff_settle_timeout` | warning | no | rx-offload did not settle within `WD_SETTLE_MAX_MS`; recovery deferred to next cycle. |
| `busoff_storm` | crit (once per storm) | no | 5+ bus-offs in 60 s. Recovery continues; investigate the electrical cause (see `can_diag.sh`). |
| `busoff_recovery_failed` | err | no | `can_setup_iface` failed during bus-off recovery; retried next cycle. |
| `busoff_recovered` | notice | no | Bus-off recovery succeeded. Routine. |
| `flush_backoff_pending` | warning | no | TX flush deferred, still inside its own backoff window. |
| `flush_aborted_recheck` | warning | no | Counters moved between the two pre-flush re-reads; flush skipped this cycle (the bus is not actually idle). |
| `lock_failed` | err | no | Could not acquire `can_lock` (see `action=` in the message for which operation). Another can_tools operation is likely stuck; investigate if persistent. |
| `oops_detected` | crit | **yes** | Kernel Oops/BUG/IRQ-thread-death signature found; unbind was *not* attempted. **Reboot** (see table above). |
| `spidev_not_found` | crit | **yes** | `/sys/class/net/<if>/device` has no spidev symlink. Hardware/wiring issue. |
| `down_timeout` | crit | **yes** | `ip link set <if> down` itself timed out. **Reboot.** |
| `unbind_timeout` | crit | **yes** | Unbind child did not finish in time; inflight marker left in place. **Reboot.** |
| `unbind_failed` | crit | **yes** | Unbind completed but reported failure. |
| `bind_failed` | crit | **yes** | Bind write failed. |
| `bind_no_netdev` | crit | **yes** | Bind succeeded but no netdev appeared within 5 s. |
| `pin_name_collision` | crit | **yes** | The wanted interface name is already held by another netdev; no swap attempted mid-recovery. |
| `pin_name_failed` | crit | **yes** | Renaming the new netdev failed for another reason. |
| `setup_failed` | crit | **yes** | `can_setup_iface` failed on the freshly bound/renamed interface. |
| `rebind_recovered` | notice | no | Unbind/bind stall recovery succeeded. Routine, but remember the ifindex changed. |
| `rebind_quota_exceeded` | crit | **yes** | `WD_REBIND_MAX_PER_HOUR` (3) hit within the last hour, across all rebind paths. Will very likely re-trigger if cleared before the hour window rolls over. |
| `rebind_verify_failed` | crit | **yes** | Positive stall evidence within the post-rebind verification window. |
| `unbind_inflight_at_startup` | crit | **yes** | An unbind from before a watchdog restart is still (apparently) running. **Reboot.** |
| `bind_failed_at_startup` | crit | **yes** | Startup reconciliation's own bind attempt failed. |
| `setup_failed_at_startup` | crit | **yes** | Startup reconciliation's own `can_setup_iface` call failed after a successful bind/pin. |
| `rtnl_hung` | warning (per cycle) / crit (via mark_degraded once the threshold hits) | **yes, all interfaces** | The `ip -d link show` call itself has timed out `WD_RTNL_HUNG_CONSEC` times in a row. **Reboot** - see the dedicated section above. |
| `stall_detected_observe_only` | crit (rate-limited) | no | Stall signal true, but the interface is in observe-only mode (pause/admin-down/config-mismatch/berr-on), so no recovery was attempted. Resolve the observe-only cause (commonly: finish the pending reboot). |
| `config_mismatch_reboot_required` | warning | no | `CAN_RESTART_MS`/`CAN_BERR_REPORTING`/`CAN_FD` in the conf differ from what the kernel is actually running. Reboot (or, machine-stopped, restart `canhat_fd_setup.service`) to apply. |
| `iface_missing` | warning | no | The interface is configured (`CAN_IFACES`) but did not appear in this cycle's `ip -d link show` output at all - normal transiently during boot/rename, a concern if persistent. |
| `pause_active` | warning (every `WD_PAUSE_WARN_S`, 600 s) | no | A pause is currently in effect; periodic reminder so an operator does not forget hardware is unsupervised. |
| `pause_expired` | warning | no | A pause file exists, its deadline is numeric, and that deadline has passed (normal expiry) - reminder that "a pause file exists" does not mean "paused". A non-numeric/malformed deadline instead produces the lib's own "Invalid pause deadline in file" WARNING from `can_pause_active`, not this reason. |
| `clear_degraded` | notice | n/a | Logged by `--clear-degraded` itself, confirming the action and which interface. |
| `manual_reboot_required` | crit (every `WD_DEGRADED_CRIT_S`, 600 s) | n/a (already degraded) | Periodic re-announcement of an interface that is already degraded; `original_reason=` carries the reason that first caused it. |

Log levels, as actually mapped by `can_log` (`can_tools_lib.bash:746-778`,
syslog-style numbers in the `<N>` prefix systemd expects): `crit` (2) -
manual intervention likely needed; `err` (3) - a recovery action failed and
will be retried; `warning` (4) - routine backoff/observe-only/reminder
conditions; `notice` (5) - successful recovery / state transitions.
`tx_flush`, despite discarding a stale queue, is logged at `warning`, not
`err` - only an actual *failure* to flush is `err`.

The 60 s periodic summary line (`_wd_log_summary`, `can_watchdog.sh:222-235`)
is the **only** place `degraded=` appears in the logs; it has no `reason=`
field at all.

## Pause

`can_pause`/`can_unpause`/`can_pause_active` are **shell functions defined in
`can_tools_lib.bash`**, not standalone executables - nothing under that name
is installed on `$PATH`. Source the lib and call them directly:

```bash
# Pause for 30 minutes (can_pause's own default if you omit the argument):
sudo bash -c '. /opt/can_tools/can_tools_lib.bash; can_read_conf; can_pause 30'

# Check whether a pause is currently active (this is what the watchdog itself
# checks - a plain `cat` would also print an expired or malformed deadline
# file as if it were active, which is not accurate):
sudo bash -c '. /opt/can_tools/can_tools_lib.bash; can_pause_active && echo paused || echo "not paused"'

# Resume immediately:
sudo bash -c '. /opt/can_tools/can_tools_lib.bash; can_unpause'
```

(`can_read_conf` before `can_pause` is not strictly required - `can_pause`
only needs `CAN_TOOLS_RUN_DIR`, which already has a hardcoded fallback - but
it is harmless and keeps the pattern consistent with the other lib
one-liners below, which *do* need the real conf.)

While paused, the watchdog (`can_watchdog.sh:874-877,1000-1001`):
- Treats every interface as observe-only (same code path as
  `config_mismatch_reboot_required` above) - no TX flush, no bus-off
  recovery, no stall rebind.
- Still evaluates stall detection and logs `stall_detected_observe_only` if
  it fires, so a real stall during a pause is still visible.
- Does **not** auto-bind a spidev left unbound by a manual unbind (see
  "Manual unbind/bind" below) - this is what makes pause safe to use before
  manual hardware work.
- Logs `reason=pause_active` once every `WD_PAUSE_WARN_S` (600 s) as a
  standing reminder.

`can_pause` only sets a deadline file; it does **not** take `can_lock`
itself and does not wait for the watchdog to notice - the watchdog picks it
up on its next cycle (within `WD_LOOP_S`, 1 s).

### can_diag.sh

```bash
sudo /opt/can_tools/can_diag.sh [duration_s]   # 1-60, default 10
sudo /opt/can_tools/can_diag.sh -h             # full usage
```

**Bench / machine-stopped use only.** The single argument is a **capture
duration in seconds** (default 10, max 60) - there is no way to name a
single interface; it always captures every configured interface
(`CAN_IFACES`) at once. Passing an interface name (e.g. `can_diag.sh can0`)
is a usage error (exits 1): `can0` does not match `^[0-9]+$`.

Sequence (`can_diag.sh:459-667`, root required): `can_pause 2` (fails fast,
making no changes, if the pause mechanism itself is broken) → `can_lock` →
re-verify the pause is still active now that the lock is held → record each
interface's *current* restart-ms/berr/fd/admin → for each admin-up interface,
`can_setup_iface` with `CAN_BERR_REPORTING=on` (recording it in
`_berr_ifaces` **before** making the call, so a signal mid-call still
restores it) → `ip -j -d -s link show` + sysfs counters + last 50
`journalctl -k` lines → `candump -L -e any,0~0,#FFFFFFFF` for the requested
duration → **restore every touched interface to its original restart-ms/
berr/fd, unlock, and restore the pause to whatever it was before (or
`can_unpause` if there was none)** → classify the captured error frames.

Output: `/run/can_tools/can_diag_<epoch>.log` (tmpfs - **gone after a
reboot**; copy it off the machine if you need to keep it). The classified
summary lives at the bottom of that same file; raw error-frame lines are
capped at `CAN_TOOLS_DIAG_MAX_RAW_LINES` (default 5000) in the file itself,
but the summary counts are always computed from the full capture.

**If `can_diag.sh` is killed with SIGKILL** (or anything its `trap cleanup
EXIT`/TERM/INT/HUP cannot catch) mid-capture, cleanup never runs, and two
things are left behind:
- The watchdog pause it set (2 minutes from when it started) is **not**
  cleared early - it simply expires on its own after up to 2 minutes
  (`_pause_set`/`_our_pause_deadline` bookkeeping never runs, so nothing
  calls `can_unpause`). Wait for it, or run `can_unpause` yourself.
- **Bus-error reporting is left ON** on whichever interfaces it had already
  enabled it on. Because `CAN_BERR_REPORTING=on` differs from the configured
  default (`off`), the watchdog will see this as a config mismatch on its
  next cycle and put that interface into **observe-only** - it stays that
  way until the setting is actually put back, which (per "Configuration is
  re-read live" above) only happens at a reboot or a machine-stopped
  `canhat_fd_setup.service` restart. **Recover by restarting
  `canhat_fd_setup.service` while the machine is still stopped, or by
  rebooting** - do not just wait, and do not toggle berr-reporting by hand
  with `ip link set` (that would itself be exactly the kind of live `ip
  link set ... down/up` this runbook says never to do on a live machine).

## Manual unbind/bind

For hardware work that needs the SPI device detached (board swap, reseating
a HAT, etc.), with the **machine mechanically stopped** (hydraulics locked,
implement lowered, key state decided):

```bash
# 1. Pause the watchdog for longer than the work will take (minutes):
sudo bash -c '. /opt/can_tools/can_tools_lib.bash; can_read_conf; can_pause 30'

# 2. Find the spidev behind the interface you are about to pull:
readlink -f /sys/class/net/can0/device   # -> e.g. .../spi0.0

# 3. Unbind it (the watchdog will NOT rebind this while paused - see
#    "Pause" above):
echo spi0.0 | sudo tee /sys/bus/spi/drivers/mcp251xfd/unbind

# ... do the hardware work ...

# 4. Bind it back:
echo spi0.0 | sudo tee /sys/bus/spi/drivers/mcp251xfd/bind

# 5. Wait for the netdev to reappear, then pin its name and bring it up
#    with the real conf (do not rely on the watchdog to do this while still
#    paused). can_pin_name does NOT take can_lock itself - only
#    can_setup_iface does - so take it explicitly for the pair, and run
#    can_setup_iface only if the pin actually succeeded (can_lock is
#    reentrant, so can_setup_iface's own internal can_lock call nests fine):
ls /sys/bus/spi/devices/spi0.0/net/   # wait until non-empty
sudo bash -c '. /opt/can_tools/can_tools_lib.bash; can_read_conf && can_lock 5 && { can_pin_name spi0.0 can0 && can_setup_iface can0; rc=$?; can_unlock; exit $rc; }'

# 6. Resume the watchdog:
sudo bash -c '. /opt/can_tools/can_tools_lib.bash; can_unpause'
```

Notes:
- Step 1's pause is what stops `_wd_startup_bind_check` from racing you and
  binding the spidev back the moment it notices the driver is gone
  (`can_watchdog.sh:766`, `can_pause_active && continue`).
- Only `can_setup_iface` takes `can_lock` internally
  (`can_tools_lib.bash:620-675`) - `can_pin_name` does **not**
  (`can_tools_lib.bash:535-606` never calls `can_lock`). Step 5 above takes
  the lock explicitly around both calls (the lock is reentrant, so
  `can_setup_iface`'s own internal `can_lock` nests fine inside it) and,
  because the two calls are joined with `&&` inside the `{ }` group, a
  `can_pin_name` failure (e.g. rc=2 on a name collision, below) skips
  `can_setup_iface` instead of running it anyway against a still-misnamed
  interface.
- If the two interfaces' SPI devices can probe in swapped order (rare, but
  the same situation `canhat_fd_rename.bash` handles at boot), `can_pin_name`
  returns rc=2 on a name collision; that is not handled automatically here -
  bind/pin one interface fully before touching the other, or re-run
  `canhat_fd_rename.bash` once both are back (it understands the swap case).
- Do not skip step 6 - a forgotten pause silently keeps the watchdog from
  recovering **every** interface (pause is global, not per-interface - see
  "Pause" above) until it expires.
