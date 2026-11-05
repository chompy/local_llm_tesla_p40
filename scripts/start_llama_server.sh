#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
LLAMA_SERVER_BIN="$BASE_DIR/lib/llama_cpp/build/bin/llama-server"
SCREEN_SESSION_NAME="llama-server"
# Model definition to launch from: model_single.yaml (full 131K ctx) by default,
# or model_multi.yaml (-np 2, 96K per slot) when start_multi.sh passes it.
MODEL_YAML="${1:-$BASE_DIR/config/model_single.yaml}"

cd "$BASE_DIR"

if [ ! -x $LLAMA_SERVER_BIN ]; then
	$SCRIPT_DIR/build_llama_cpp.sh || exit 1
fi

# Non-blocking: create a detached session if one doesn't exist, otherwise leave it alone.
# Attach manually with `screen -r llama-server` (detach again with Ctrl-A D).
if screen -list | grep -q "$SCREEN_SESSION_NAME"; then
  echo "> $SCREEN_SESSION_NAME session already running"
else
  # Build the command from the model YAML: binary + --port + -hf + args,
  # each token shell-quoted so it survives `sh -c`. The server runs with the
  # repo root as its working directory (args may use relative paths).
  CMD=$(python3 $SCRIPT_DIR/generate_llama_server_cmd.py "$MODEL_YAML" "$LLAMA_SERVER_BIN") || exit 1
  echo "> Command: $CMD"

  echo "> Starting new $SCREEN_SESSION_NAME session"
  screen -dmS "$SCREEN_SESSION_NAME" sh -c "cd '$BASE_DIR' && exec $CMD"

  # Also drop a ready-to-copy config for remote OpenCode clients at the repo
  # root: same provider entry, but baseURL pointing at this machine's LAN
  # address (first 192.168.x.x from ifconfig) instead of localhost. A remote
  # client copies opencode.json into its own OpenCode config location. Skipped
  # with a warning when no such address exists (not on the LAN right now).
  LAN_IP=$(ifconfig -a 2>/dev/null | awk '$1=="inet" || $1=="inet:" {ip=$2; if (ip ~ /^192\.168\./) {print ip; exit}}')
  if [ -n "$LAN_IP" ]; then
    echo "> Building LAN config opencode.json for remote clients (host $LAN_IP)"
    python3 $SCRIPT_DIR/generate_opencode_json.py "$MODEL_YAML" $BASE_DIR/config/opencode.json.tmpl --host "$LAN_IP" -o "$BASE_DIR/opencode.json" \
      || echo "> WARNING: failed to build LAN opencode.json (server started anyway)"
  else
    echo "> No 192.168.x.x address found — skipping LAN opencode.json"
  fi
fi

exit 0
