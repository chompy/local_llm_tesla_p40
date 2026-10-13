#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
OPENCODE_PATH="$BASE_DIR/lib/opencode"
EXEC_PATH="$OPENCODE_PATH/node_modules/.bin/opencode"
SCREEN_SESSION_NAME="opencode"

if [ ! -f $EXEC_PATH ]; then
	$SCRIPT_DIR/fetch_opencode.sh
fi

if ! screen -list | grep -q "$SCREEN_SESSION_NAME"; then
  echo "> Updating opencode.json"
  mkdir -p ~/.config/opencode
  python3 $SCRIPT_DIR/generate_opencode_json.py $BASE_DIR/config/llama_swap.yaml /home/nathan/.config/opencode/opencode.json

  echo "> Starting new $SCREEN_SESSION_NAME session"
  sleep 2
  cd $PROJECT_PATH
  screen -S $SCREEN_SESSION_NAME $EXEC_PATH serve --hostname 0.0.0.0 --port 4096
  exit 1
fi

echo "> $SCREEN_SESSION_NAME session found, re-attaching"
sleep 2
screen -D -r $SCREEN_SESSION_NAME
exit 1
