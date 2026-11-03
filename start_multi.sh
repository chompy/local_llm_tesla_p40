#!/usr/bin/env bash
# Start the two-agent stack: one llama-server with two parallel slots
# (config/model_multi.yaml — -np 2, 96K context per slot, q8_0 KV) + the local
# OpenCode web server on :4096. The second agent runs remotely and talks to the
# same llama-server directly over the network (--host 0.0.0.0, port 5800).
# For a single agent with full 131K context use start_single.sh instead.

BASE_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
LLAMA_SERVER_BIN="$BASE_DIR/lib/llama_cpp/build/bin/llama-server"

if [ ! -x "$LLAMA_SERVER_BIN" ]; then
	echo "> llama-server not found, building llama.cpp (this takes a while)"
	"$BASE_DIR/scripts/build_llama_cpp.sh" || exit 1
fi

# A server left over from the other mode would keep serving with the wrong args;
# switching modes always goes through stop.sh.
if screen -list | grep -q "llama-server"; then
	echo "> A llama-server is already running — run ./stop.sh first." >&2
	exit 1
fi

echo "> Starting llama-server (two slots) and opencode web server"
"$BASE_DIR/scripts/start_llama_server.sh" "$BASE_DIR/config/model_multi.yaml" || exit 1
"$BASE_DIR/scripts/start_opencode.sh" "$BASE_DIR/config/model_multi.yaml" || exit 1
