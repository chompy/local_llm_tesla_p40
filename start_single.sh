#!/usr/bin/env bash
# Start the single-agent stack: one llama-server (config/model_single.yaml —
# full 131K context, f16 KV) + the OpenCode web server on :4096.
# For two concurrent agents use start_multi.sh instead.

BASE_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
LLAMA_SERVER_BIN="$BASE_DIR/lib/llama_cpp/build/bin/llama-server"

# Only build llama.cpp if the binary is missing. A full CUDA rebuild takes a long
# time, so don't do it on every startup (the old check also looked for the wrong
# directory: llama.cpp lives in lib/llama_cpp).
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

echo "> Starting llama-server and opencode web server"
# Both sub-scripts are non-blocking: they create detached screen sessions if the
# session doesn't exist yet, then return. Attach later with `screen -r <name>`.
"$BASE_DIR/scripts/start_llama_server.sh" || exit 1
"$BASE_DIR/scripts/start_opencode.sh" || exit 1
