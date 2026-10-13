#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
LLAMA_SWAP_PATH="$BASE_DIR/lib/llama_swap"
SCREEN_SESSION_NAME="llamaswap"
SCREEN_COMMAND="$LLAMA_SWAP_PATH/llama-swap -listen 0.0.0.0:10080 -config $BASE_DIR/config/llama_swap.yaml"

cd $BASE_DIR

if [ ! -d $LLAMA_SWAP_PATH ]; then
	$SCRIPT_DIR/build_llama_swap.sh
fi

if ! screen -list | grep -q "$SCREEN_SESSION_NAME"; then
  echo "> Starting new $SCREEN_SESSION_NAME session"
  sleep 2
  screen -S $SCREEN_SESSION_NAME sh -c "$SCREEN_COMMAND"
  exit 1
fi

echo "> $SCREEN_SESSION_NAME session found, re-attaching"
sleep 2
screen -D -r $SCREEN_SESSION_NAME
exit 1
