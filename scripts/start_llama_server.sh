#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
LLAMA_SERVER_BIN="$BASE_DIR/lib/llama_cpp/build/bin/llama-server"
SCREEN_SESSION_NAME="llama-server"

cd "$BASE_DIR"

if [ ! -x $LLAMA_SERVER_BIN ]; then
	$SCRIPT_DIR/build_llama_cpp.sh || exit 1
fi

# Non-blocking: create a detached session if one doesn't exist, otherwise leave it alone.
# Attach manually with `screen -r llama-server` (detach again with Ctrl-A D).
if screen -list | grep -q "$SCREEN_SESSION_NAME"; then
  echo "> $SCREEN_SESSION_NAME session already running"
else
  # Build the command from config/model.yaml: binary + --port + -hf + args,
  # each token shell-quoted so it survives `sh -c`. The server runs with the
  # repo root as its working directory (args may use relative paths).
  CMD=$(python3 $SCRIPT_DIR/generate_llama_server_cmd.py $BASE_DIR/config/model.yaml "$LLAMA_SERVER_BIN") || exit 1
  echo "> Command: $CMD"

  echo "> Starting new $SCREEN_SESSION_NAME session"
  screen -dmS "$SCREEN_SESSION_NAME" sh -c "cd '$BASE_DIR' && exec $CMD"
fi

exit 0
