#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
LLAMA_SWAP_PATH="$BASE_DIR/lib/llama_swap"
SCREEN_SESSION_NAME="llamaswap"
SCREEN_COMMAND="$LLAMA_SWAP_PATH/llama-swap -listen 0.0.0.0:10080 -config $BASE_DIR/config/llama_swap.yaml"

cd "$BASE_DIR"

if [ ! -d $LLAMA_SWAP_PATH ]; then
	$SCRIPT_DIR/build_llama_swap.sh
fi

# Non-blocking: create a detached session if one doesn't exist, otherwise leave it alone.
# Attach manually with `screen -r llamaswap` (detach again with Ctrl-A D).
if screen -list | grep -q "$SCREEN_SESSION_NAME"; then
  echo "> $SCREEN_SESSION_NAME session already running"
else
  echo "> Starting new $SCREEN_SESSION_NAME session"
  screen -dmS "$SCREEN_SESSION_NAME" sh -c "cd '$BASE_DIR' && exec $SCREEN_COMMAND"
fi

exit 0
