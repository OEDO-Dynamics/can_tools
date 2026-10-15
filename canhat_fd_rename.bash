#!/bin/bash
# canhat_fd_rename.bash - Pin CAN FD interface names to their physical SPI
# devices (default CAN_SPI_MAP: spi0.0 -> can0, spi1.0 -> can1).
# Called once at boot by canhat_fd_rename.service, before docker.service and
# canhat_fd_setup.service.
#
# Per Issue #9 §2b:
#   1. can_lock
#   2. wait up to 10s for every mapped spidev to have a netdev (probe order
#      at boot is not guaranteed)
#   3. can_pin_name for each mapping
#   4. rc==2 (the wanted name is already held by the *other* iface - i.e. the
#      two ifaces probed in swapped order) -> swap both names via a
#      temporary one
#   5. can_unlock
#
# Exit status (L4, disambiguated at the call site per L-new2): a spidev that
# never gets a netdev within the 10s wait (missing hardware, or probe taking
# longer than 10s) is logged as a WARNING and does not fail the unit -
# Before=canhat_fd_setup.service docker.service is ordering only, not a
# dependency on success, and a permanently-failed oneshot unit for "one CAN
# HAT channel is still probing" is not actionable here (the watchdog's
# degraded-iface reporting covers it). Any other failure - the down/rename
# `ip` call itself failing once the netdev is confirmed present, or a swap
# failing partway (best-effort rolled back so no interface is left named
# "can_tmp_<pid>", L-new3) - is a real operational failure and is reported
# as exit 1, so the oneshot unit shows failed and the condition is visible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LIB_PATH="$SCRIPT_DIR/can_tools_lib.bash"
readonly CONF_PATH="${CAN_TOOLS_CONF:-$SCRIPT_DIR/can_tools.conf}"

[[ -f "$LIB_PATH" ]] || {
    echo "ERROR: can_tools_lib.bash not found at $LIB_PATH" >&2
    exit 1
}
# shellcheck source=can_tools_lib.bash
source "$LIB_PATH" || exit 1

# can_now() reads $CAN_TOOLS_FAKE_TIME_FILE without a safe ${VAR:-} default;
# under this script's `set -u`, calling it while that variable was never set
# anywhere in the environment (the normal case under systemd) would abort
# with "unbound variable" before anything useful happens. Give it a
# definition (lib and tests/fakes are out of scope for this PR; see the
# accompanying PR comment).
: "${CAN_TOOLS_FAKE_TIME_FILE:=}"

can_read_conf "$CONF_PATH" || exit 1

# Parse CAN_SPI_MAP ("spi0.0:can0 spi1.0:can1") into parallel arrays.
declare -a spidevs=() wants=()
for mapping in $CAN_SPI_MAP; do
    spidev="${mapping%%:*}"
    want="${mapping#*:}"
    [[ -n "$spidev" && -n "$want" && "$spidev" != "$mapping" ]] || continue
    spidevs+=("$spidev")
    wants+=("$want")
done

if [[ ${#spidevs[@]} -eq 0 ]]; then
    echo "ERROR: CAN_SPI_MAP is empty or malformed: $CAN_SPI_MAP" >&2
    exit 1
fi

can_lock || {
    echo "ERROR: Failed to acquire can_lock" >&2
    exit 1
}

# Wait up to 10s for every mapped spidev to show a netdev. can_iface_of_spidev
# only reads sysfs (no can_run_bounded involved), so it is safe to call in a
# command substitution here.
deadline=$(( $(can_now) + 10 ))
while :; do
    all_present=1
    for spidev in "${spidevs[@]}"; do
        if ! can_iface_of_spidev "$spidev" >/dev/null 2>&1; then
            all_present=0
            break
        fi
    done
    (( all_present )) && break
    (( $(can_now) >= deadline )) && break
    sleep 0.1
done

ip_cmd="${CAN_TOOLS_IP_CMD:-ip}"
timeout="${WD_RTNL_TIMEOUT_S:-5}"
rename_failed=0
missing_warned=0

for i in "${!spidevs[@]}"; do
    spidev="${spidevs[$i]}"
    want="${wants[$i]}"

    # L-new2: can_pin_name returns rc=1 both when the spidev has no netdev
    # at all (missing hardware - should just WARNING and exit 0 per L4) and
    # when the netdev exists but the down/rename `ip` call itself failed
    # (a real operational failure - should ERROR and exit 1). The lib does
    # not distinguish these itself (tracked as a lib-side follow-up; see the
    # PR comment), so disambiguate here by checking presence ourselves
    # first, before calling can_pin_name at all.
    if ! can_iface_of_spidev "$spidev" >/dev/null 2>&1; then
        can_log WARNING "iface=$spidev want=$want reason=missing_netdev"
        missing_warned=1
        continue
    fi

    # can_pin_name itself calls can_run_bounded; call it as a plain command
    # (never inside $( )), per the lib's calling contract. It is wrapped in
    # `if` (rather than a bare statement + $?) so that this script's
    # `set -e` does not abort mid-function on one of can_pin_name's own
    # internal, expected-nonzero probes (e.g. "ip link show <free name>"
    # returning 1) - `if`/`while`/`until` conditions are the one place bash
    # suspends errexit for the whole nested call, including can_run_bounded.
    if can_pin_name "$spidev" "$want"; then
        pin_rc=0
    else
        pin_rc=$?
    fi

    case "$pin_rc" in
        0)
            : # already named $want, or renamed cleanly
            ;;
        2)
            # Collision: $spidev's current name is not $want, and $want is
            # already held by the other iface -> probe-order swap.
            current=""
            if ! current=$(can_iface_of_spidev "$spidev" 2>/dev/null); then
                can_log WARNING "iface=$spidev reason=collision_but_no_netdev"
                missing_warned=1
                continue
            fi

            # L-new3: track how far the swap got so a failure partway
            # through can be rolled back - the oneshot unit will fail
            # either way (visible), but the interfaces should not be left
            # stuck under the temporary name.
            tmp_name="can_tmp_$$"
            swap_step=0
            swap_ok=0
            if can_run_bounded "$timeout" "$ip_cmd" link set "$current" down >/dev/null 2>&1; then
                swap_step=1
                if can_run_bounded "$timeout" "$ip_cmd" link set "$want" down >/dev/null 2>&1; then
                    swap_step=2
                    if can_run_bounded "$timeout" "$ip_cmd" link set "$want" name "$tmp_name" >/dev/null 2>&1; then
                        swap_step=3
                        if can_run_bounded "$timeout" "$ip_cmd" link set "$current" name "$want" >/dev/null 2>&1; then
                            swap_step=4
                            if can_run_bounded "$timeout" "$ip_cmd" link set "$tmp_name" name "$current" >/dev/null 2>&1; then
                                swap_ok=1
                            fi
                        fi
                    fi
                fi
            fi

            if (( swap_ok )); then
                can_log INFO "action=swap from=$current to=$want"
            else
                can_log ERR "action=swap_failed from=$current to=$want step=$swap_step"
                # Best-effort rollback so a failed swap never leaves an
                # interface stuck under "$tmp_name" (L-new3). Each branch
                # undoes exactly the renames that succeeded before the
                # failing step; the two bare "downs" (steps 1-2) need no
                # undo since no name changed yet.
                case "$swap_step" in
                    3)
                        can_run_bounded "$timeout" "$ip_cmd" link set "$tmp_name" name "$want" >/dev/null 2>&1 || true
                        ;;
                    4)
                        can_run_bounded "$timeout" "$ip_cmd" link set "$want" name "$current" >/dev/null 2>&1 || true
                        can_run_bounded "$timeout" "$ip_cmd" link set "$tmp_name" name "$want" >/dev/null 2>&1 || true
                        ;;
                    *)
                        : # steps 0-2: nothing renamed yet, nothing to undo
                        ;;
                esac
                rename_failed=1
            fi
            ;;
        *)
            # The netdev exists (checked above) but the down/rename `ip`
            # call itself failed - a real operational failure, not a
            # missing-hardware condition (L-new2).
            can_log ERR "iface=$spidev want=$want reason=pin_name_op_failed_rc_$pin_rc"
            rename_failed=1
            ;;
    esac
done

can_unlock

if (( rename_failed )); then
    exit 1
fi

if (( missing_warned )); then
    can_log WARNING "rename completed with a missing/unconfirmed interface; not failing the oneshot unit (L4)"
fi

exit 0
