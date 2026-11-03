#!/usr/bin/env bash
# fan_guard — automatic GPU fan control.
#
# Watches GPU utilization and drives ~/bin/set_fan: as soon as the GPU is in
# use (utilization > 0%) the fan goes to ON_SPEED, and once the GPU has been
# idle (0%) for GRACE_SECONDS straight it goes back off — replacing the manual
# `set_fan 128` / `set_fan 0` dance. A brief spike of usage during the grace
# period cancels the pending shutdown.
#
# Runs as a detached screen session ("fan-guard"), like the other long-lived
# services in this repo:
#   scripts/fan_guard.sh     start it (idempotent — safe to re-run)
#   screen -r fan-guard      watch its transition log (Ctrl-A D detaches)
#
# ~/bin/set_fan must be callable without a password prompt (it is: sudoers has
# NOPASSWD for /root/set_fan). Single-GPU machine assumed.

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
SCREEN_SESSION_NAME="fan-guard"

FAN_CMD="${FAN_CMD:-$HOME/bin/set_fan}"    # speed setter (sudo inside)
ON_SPEED="${ON_SPEED:-128}"                # fan speed while the GPU is in use
OFF_SPEED="${OFF_SPEED:-0}"                # fan speed when done
GRACE_SECONDS="${GRACE_SECONDS:-300}"      # idle time required before fan off
POLL_INTERVAL="${POLL_INTERVAL:-5}"        # utilization poll period (seconds)
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"     # override for testing

cd "$BASE_DIR"

# Launcher mode: create a detached session if one doesn't exist, then return.
if [ -z "${FAN_GUARD_RUNNING:-}" ]; then
	if screen -list | grep -q "$SCREEN_SESSION_NAME"; then
		echo "> $SCREEN_SESSION_NAME session already running"
	else
		echo "> Starting new $SCREEN_SESSION_NAME session"
		screen -dmS "$SCREEN_SESSION_NAME" env FAN_GUARD_RUNNING=1 bash "$SCRIPT_DIR/fan_guard.sh"
	fi
	exit 0
fi

# Loop mode (inside the screen session).
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

fan_state="off"   # assumed at startup: a fan that was turned on manually while
                  # the GPU is idle simply shuts off after the grace period,
                  # which matches the policy anyway
zero_since=""

log "fan guard started (on=$ON_SPEED, off=$OFF_SPEED, grace=${GRACE_SECONDS}s, poll=${POLL_INTERVAL}s)"

while true; do
	usage=$("$NVIDIA_SMI" --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1)
	# Skip iterations where the query failed (driver hiccup): keep current state.
	case "$usage" in
		''|*[!0-9]*) sleep "$POLL_INTERVAL"; continue ;;
	esac

	if [ "$usage" -gt 0 ]; then
		zero_since=""
		if [ "$fan_state" = off ]; then
			if "$FAN_CMD" "$ON_SPEED"; then
				fan_state="on"
				log "GPU in use (${usage}%) — fan ON ($ON_SPEED)"
			else
				log "WARNING: set_fan $ON_SPEED failed (will retry while GPU is busy)"
			fi
		fi
	else
		if [ "$fan_state" = on ]; then
			now=$(date +%s)
			if [ -z "$zero_since" ]; then
				zero_since=$now
			elif [ $(( now - zero_since )) -ge "$GRACE_SECONDS" ]; then
				if "$FAN_CMD" "$OFF_SPEED"; then
					fan_state="off"
					zero_since=""
					log "GPU idle for ${GRACE_SECONDS}s — fan OFF ($OFF_SPEED)"
				fi
			fi
		fi
	fi

	sleep "$POLL_INTERVAL"
done
