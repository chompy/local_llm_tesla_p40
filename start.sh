#!/usr/bin/env bash

BASE_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
LLAMA_SERVER_BIN="$BASE_DIR/lib/llama_cpp/build/bin/llama-server"

# Only build llama.cpp if the binary is missing. A full CUDA rebuild takes a long
# time, so don't do it on every startup (the old check also looked for the wrong
# directory: llama.cpp lives in lib/llama_cpp).
if [ ! -x "$LLAMA_SERVER_BIN" ]; then
	echo "> llama-server not found, building llama.cpp (this takes a while)"
	"$BASE_DIR/scripts/build_llama_cpp.sh" || exit 1
fi

echo "> Starting llama-swap and opencode web servers"
# Both sub-scripts are non-blocking: they create detached screen sessions if the
# session doesn't exist yet, then return. Attach later with `screen -r <name>`.
"$BASE_DIR/scripts/start_llama_swap.sh" || exit 1
"$BASE_DIR/scripts/start_opencode.sh" || exit 1
