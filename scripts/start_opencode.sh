#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
OPENCODE_PATH="$BASE_DIR/lib/opencode"
EXEC_PATH="$OPENCODE_PATH/node_modules/.bin/opencode"
SCREEN_SESSION_NAME="opencode"

if [ ! -f $EXEC_PATH ]; then
	$SCRIPT_DIR/fetch_opencode.sh
fi

cd "$BASE_DIR"

# Non-blocking: create a detached session if one doesn't exist, otherwise leave it alone.
# Attach manually with `screen -r opencode` (detach again with Ctrl-A D).
if screen -list | grep -q "$SCREEN_SESSION_NAME"; then
  echo "> $SCREEN_SESSION_NAME session already running"
else
  echo "> Updating opencode.json"
  mkdir -p ~/.config/opencode
  python3 $SCRIPT_DIR/generate_opencode_json.py $BASE_DIR/config/llama_swap.yaml "$HOME/.config/opencode/opencode.json"

  echo "> Starting new $SCREEN_SESSION_NAME session"
  screen -dmS "$SCREEN_SESSION_NAME" "$EXEC_PATH" serve --hostname 0.0.0.0 --port 4096
fi

exit 0
