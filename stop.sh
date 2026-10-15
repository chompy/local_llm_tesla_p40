#!/usr/bin/env bash
# Stop the llama-swap and opencode services started by start.sh (and any
# leftover processes from them), in reverse order of startup.

BASE_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

stop_session() {
	local name="$1" screen_pid child_pid
	# `screen -ls` line format: "  <pid>.<name>\t(date)\t(Detached)"
	screen_pid=$(screen -ls | grep -E "\\.${name}[[:space:]]" | head -n1 | awk '{print $1}' | cut -d. -f1)
	if [ -z "$screen_pid" ]; then
		echo "> No '$name' screen session found"
		return 0
	fi
	child_pid=$(ps --ppid "$screen_pid" -o pid= | tr -d ' ')
	if [ -n "$child_pid" ]; then
		# TERM the window's top-level process; the empty session goes away with it.
		kill $child_pid 2>/dev/null
	else
		kill "$screen_pid" 2>/dev/null
	fi
	echo "> Stopped $name (session $screen_pid)"
}

stop_session opencode
stop_session llamaswap

# Sweep for survivors. llama-swap spawns its llama-server instances in their own
# process groups, so they outlive the session kill and must be matched by name.
# Patterns are scoped to this repo's component paths (as they appear in cmdline).
sleep 2
sweep() {
	local pattern="$1" pids
	pids=$(pgrep -f "$pattern")
	if [ -n "$pids" ]; then
		echo "> Force-stopping leftover: $(echo $pids | tr '\n' ' ')"
		kill -9 $pids 2>/dev/null
	fi
}
sweep "llama_cpp/build/bin/llama-server"
sweep "lib/llama_swap/llama-swap"
sweep "lib/opencode/node_modules/.bin/opencode"

echo "> Done. Check VRAM with: nvidia-smi, sessions with: screen -ls"
