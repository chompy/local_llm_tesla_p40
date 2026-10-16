#!/usr/bin/env bash
# A/B benchmark for --spec-draft-n-max (MTP speculative decoding) on this stack.
#
# Usage:  ./scripts/bench_draft_max.sh [value ...]     (default: 2 3 5 7)
#
# Run it from a separate terminal, NOT while using OpenCode:
#   cd /home/nathan/local_llm_tools && ./scripts/bench_draft_max.sh
#
# What it does, in order:
#   1. Stops the whole stack (stop.sh) and waits until the GPU is actually idle
#      (VRAM released), so nothing interferes with the measurements.
#   2. For each draft value: launches llama-server on port 5800 exactly as
#      config/model.yaml defines it (only --spec-draft-n-max changed), waits
#      for model load, sends one warmup request + three measured requests
#      (fixed ~6K-token prompt, temperature=0, max_tokens=100).
#   3. Restores the canonical stack with start.sh and prints a results table.
#
# Expected duration: ~15-20 minutes for four values.
# Results land in /tmp/opencode/draft_ab/ (results.tsv, report.md, per-value
# server logs). The script always attempts to restore the stack on exit, even
# if interrupted with Ctrl-C.

set -u

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE="$SCRIPT_DIR/.."
WORK=/tmp/opencode/draft_ab
BIN="$BASE/lib/llama_cpp/build/bin/llama-server"
PORT=5800
VALUES="$*"
if [ -z "$VALUES" ]; then VALUES="2 3 5 7"; fi

RESTORED=0
mkdir -p "$WORK"
rm -f "$WORK"/results.tsv "$WORK"/report.md "$WORK"/req.json "$WORK"/resp.json \
      "$WORK"/server.pid "$WORK"/server_*.log "$WORK"/preflight.log \
      "$WORK"/specstats_*.txt 2>/dev/null

banner() { printf '\n============================================================\n  %s\n============================================================\n' "$*"; }
# log() goes to stderr so that command-substitution capture of bench_value's
# stdout picks up only the final TSV row.
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# ---------- helpers ----------

port_free() {
	ss -tln 2>/dev/null | grep -q ":$PORT " && return 1 || return 0
}

wait_port_free() {
	local i=0
	while [ "$i" -lt 60 ]; do
		port_free && return 0
		sleep 1; i=$((i+1))
	done
	log "FATAL: port $PORT still occupied after 60s"
	return 1
}

wait_ready() { # $1 = pid, $2 = max seconds, $3 = log file to tail on failure
	local pid="$1" max="$2" lf="$3" i=0
	while [ "$i" -lt "$max" ]; do
		if ! kill -0 "$pid" 2>/dev/null; then
			log "FATAL: server process died during load; last lines of $lf:"
			tail -n 8 "$lf" 2>/dev/null >&2
			return 1
		fi
		if curl -s --max-time 3 "http://127.0.0.1:$PORT/v1/models" | grep -q '"data"'; then
			return 0
		fi
		sleep 3; i=$((i+3))
	done
	log "FATAL: server not ready after ${max}s; last lines of $lf:"
	tail -n 8 "$lf" 2>/dev/null >&2
	return 1
}

start_test_server() { # $1 = command line, $2 = log file; sets SERVER_PID
	local cmd="$1" lf="$2" i=0
	rm -f "$WORK/server.pid"
	# The inner bash writes its OWN pid (the one that becomes llama-server after
	# exec). Capturing $! in the outer shell is NOT safe: it can be an
	# intermediate wrapper subshell, and killing that orphans the real server.
	( cd "$BASE" && nohup bash -c "echo \$\$ > '$WORK/server.pid'; exec $cmd" > "$lf" 2>&1 & )
	while [ ! -s "$WORK/server.pid" ]; do
		i=$((i+1))
		if [ "$i" -gt 30 ]; then log "FATAL: server pidfile never appeared"; return 1; fi
		sleep 0.5
	done
	SERVER_PID=$(cat "$WORK/server.pid")
}

port_pid() { # pid of whatever currently listens on $PORT (empty if none)
	ss -tlnp 2>/dev/null | grep ":$PORT " | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2
}

kill_test_server() { # $1 = pid
	local pid="$1" i=0 lp
	[ -z "${pid:-}" ] && return 0
	kill "$pid" 2>/dev/null
	while [ "$i" -lt 30 ]; do
		kill -0 "$pid" 2>/dev/null || break
		sleep 1; i=$((i+1))
	done
	if ! port_free; then
		lp=$(port_pid)
		if [ -n "${lp:-}" ] && [ "$lp" != "$pid" ]; then
			log "recorded pid $pid was not the listener; killing actual listener pid $lp"
			kill "$lp" 2>/dev/null; sleep 3
		fi
	fi
	kill -9 "$pid" 2>/dev/null
	if ! port_free; then
		lp=$(port_pid)
		[ -n "${lp:-}" ] && kill -9 "$lp" 2>/dev/null
	fi
	wait_port_free || return 1
	return 0
}

cmd_for() { # $1 = draft value; port stays 5800 (what opencode points at)
	python3 "$BASE/scripts/generate_llama_server_cmd.py" "$BASE/config/model.yaml" "$BIN" \
		| sed "s/--spec-draft-n-max [0-9]*/--spec-draft-n-max $1/"
}

bench_value() { # $1 = draft value; prints ONE TSV row to stdout: n run1 run2 run3 median
	local n="$1" cmd pid t tok rps r1="" r2="" r3="" i med t0 t1 lf
	cmd=$(cmd_for "$n") || return 1
	lf="$WORK/server_${n}.log"
	log "starting llama-server --spec-draft-n-max $n (log: $lf)"
	start_test_server "$cmd" "$lf" || return 1
	pid=$SERVER_PID
	t0=$(date +%s)

	if ! wait_ready "$pid" 300 "$lf"; then
		kill_test_server "$pid" || true
		printf '%s\t%s\t%s\t%s\t%s\n' "$n" FAIL FAIL FAIL FAIL
		return 1
	fi
	t1=$(date +%s); log "model loaded in $((t1 - t0))s (pid $pid); warming up"

	# warmup: first request after load pays one-off costs; discard it
	if ! curl -s --max-time 600 -o /dev/null http://127.0.0.1:$PORT/v1/chat/completions \
			-H 'Content-Type: application/json' -d @"$WORK/req.json"; then
		log "FATAL: warmup request failed"
		kill_test_server "$pid" || true
		printf '%s\t%s\t%s\t%s\t%s\n' "$n" FAIL FAIL FAIL FAIL
		return 1
	fi

	for i in 1 2 3; do
		if ! t=$(curl -s --max-time 600 -o "$WORK/resp.json" -w '%{time_total}' \
				http://127.0.0.1:$PORT/v1/chat/completions \
				-H 'Content-Type: application/json' -d @"$WORK/req.json"); then
			rps="ERR"
		else
			tok=$(python3 -c "import json;print(json.load(open('$WORK/resp.json'))['usage']['completion_tokens'])" 2>/dev/null) || tok=""
			if [ -z "${tok:-}" ]; then rps="ERR"; else
				rps=$(python3 -c 'import sys; t=float(sys.argv[1]); tok=int(sys.argv[2]); print(f"{tok/t:.2f}")' "$t" "$tok")
			fi
		fi
		case "$i" in 1) r1=$rps;; 2) r2=$rps;; 3) r3=$rps;; esac
	done

	med=$(printf '%s\n%s\n%s\n' "${r1}" "${r2}" "${r3}" | grep -E '^[0-9]' \
		| python3 -c "import sys; v=sorted(float(x) for x in sys.stdin); print(f'{v[len(v)//2]:.2f}')" 2>/dev/null || echo "?")

	printf '%s\t%s\t%s\t%s\t%s\n' "$n" "${r1}" "${r2}" "${r3}" "${med}"

	# informational: any spec/acceptance stats the server logged?
	grep -iE 'spec|accept' "$lf" | tail -n 3 > "$WORK/specstats_${n}.txt" || true

	if ! kill_test_server "$pid"; then
		log "WARNING: port may still be busy before next value"
	fi
	log "value $n done (median ${med} tok/s)"
	return 0
}

gpu_idle() { # returns 0 once VRAM usage is below the idle threshold
	local i=0 used
	while [ "$i" -lt 45 ]; do
		used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -n1 | tr -d '[:space:]')
		if [[ "${used:-}" =~ ^[0-9]+$ ]] && [ "$used" -lt 50 ]; then return 0; fi
		sleep 2; i=$((i+1))
	done
	return 1
}

restore() {
	[ "${RESTORED:-0}" -eq 1 ] && return 0
	RESTORED=1
	banner "restoring the stack with start.sh"
	local pids zsp i
	pids=$(pgrep -f 'llama_cpp/build/bin/llama-server' || true)
	if [ -n "$pids" ]; then
		log "killing leftover llama-server pid(s): $pids"
		kill $pids 2>/dev/null; sleep 3
		pids=$(pgrep -f 'llama_cpp/build/bin/llama-server' || true)
		[ -n "$pids" ] && kill -9 $pids 2>/dev/null
	fi
	# Clear a zombie screen session (no child left) so start_llama_server.sh
	# creates a fresh one instead of skipping.
	zsp=$(screen -ls | grep -E '\.llama-server[[:space:]]' | head -n1 | awk '{print $1}' | cut -d. -f1 || true)
	if [ -n "${zsp:-}" ]; then
		log "quitting zombie screen session $zsp"
		screen -S "$zsp" -X quit 2>/dev/null; sleep 1
	fi
	wait_port_free || { log "FATAL: port busy, cannot restore"; return 1; }
	cd "$BASE" && ./start.sh || { log "FATAL: start.sh failed — run it manually"; return 1; }
	i=0
	while [ "$i" -lt 300 ]; do
		if curl -s --max-time 3 "http://127.0.0.1:$PORT/v1/models" | grep -q '"data"'; then
			banner "stack restored — you can go back to OpenCode"; return 0
		fi
		sleep 3; i=$((i+3))
	done
	log "FATAL: server not ready after start.sh (check screen sessions)"
	return 1
}

on_signal() { restore || true; exit 1; }
trap on_signal INT TERM HUP
trap 'restore' EXIT

# ---------- phase 0: stop the stack and wait for a clean GPU ----------

banner "stopping the stack — do not use OpenCode until this finishes"
cd "$BASE" && ./stop.sh || log "WARNING: stop.sh reported an error; continuing"

if ! gpu_idle; then
	log "FATAL: GPU still busy after stop.sh. Compute apps holding VRAM:"
	nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv >&2 || true
	exit 1
fi
log "GPU idle (VRAM released)"

# ---------- build the fixed benchmark request (~6K token prefill, temp=0) ----------

python3 - "$WORK/req.json" <<'PYEOF'
import json, sys
pad = "\n".join(
    f"const ctx_value_{i:04d} = {i}; // context padding line to reach a realistic agentic depth"
    for i in range(420)
)
msgs = [
    {"role": "system", "content": "You are an expert coding agent working inside a terminal. Be precise and concise."},
    {"role": "user", "content": pad + "\n\nIgnoring the code above: write a Python function `chunked_read(path, size=65536)` that yields binary chunks of a file without loading it fully into memory, then list its edge cases briefly."},
]
req = {
    "model": "local",  # patched to the real id after the first server is up
    "messages": msgs,
    "temperature": 0,
    "max_tokens": 100,
    "stream": False,
}
json.dump(req, open(sys.argv[1], "w"))
PYEOF

echo -e "draft_max\trun1\trun2\trun3\tmedian_tok_s" > "$WORK/results.tsv"

# Preflight: llama-server validates the request's model name against what it
# serves; start one server, read its /v1/models id into req.json, kill it.
first_value="${VALUES%% *}"
log "== preflight: fetching real model id (using draft value $first_value) =="
cmd=$(cmd_for "$first_value") || exit 1
start_test_server "$cmd" "$WORK/preflight.log" || exit 1
if ! wait_ready "$SERVER_PID" 300 "$WORK/preflight.log"; then exit 1; fi
mid=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/v1/models" \
	| python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])") || exit 1
python3 - "$WORK/req.json" "$mid" <<'PYEOF'
import json, sys
p = sys.argv[1]
r = json.load(open(p))
r["model"] = sys.argv[2]
json.dump(r, open(p, "w"))
print(f"> patched req model -> {sys.argv[2]}")
PYEOF
kill_test_server "$SERVER_PID" || exit 1

# ---------- benchmark loop ----------

banner "benchmarking draft values: $VALUES"
for n in $VALUES; do
	row=$(bench_value "$n") || row="$(printf '%s\t%s\t%s\t%s\t%s\n' "$n" FAIL FAIL FAIL FAIL)"
	printf '%s\n' "$row" >> "$WORK/results.tsv"
done

# ---------- report (printed before the EXIT trap restores the stack) ----------

{
	echo "# --spec-draft-n-max A/B results ($(basename "$BIN") model from config/model.yaml)"
	echo
	echo "- temperature=0, max_tokens=100, prefill ~6K tokens, 3 measured runs after 1 warmup"
	echo "- last column is the median tok/s; per-value server logs in $WORK/"
	echo
	cat "$WORK/results.tsv"
} > "$WORK/report.md"

banner "pass complete — results below (stack restores next)"
cat "$WORK/report.md"
echo "> Full report: $WORK/report.md   Results: $WORK/results.tsv"
exit 0
