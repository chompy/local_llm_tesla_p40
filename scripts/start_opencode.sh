#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
OPENCODE_PATH="$BASE_DIR/lib/opencode"
EXEC_PATH="$OPENCODE_PATH/node_modules/.bin/opencode"
SCREEN_SESSION_NAME="opencode"
# Isolated state root: opencode's whole home (its config dir, cache, session
# database and logs) is re-rooted here via HOME, so this instance never reads
# or writes the user's real ~/.config/opencode, ~/.cache or ~/.local — nothing
# from other OpenCode installs on this machine can leak in. Persists across
# restarts; it is gitignored. Delete it for a clean slate.
OC_HOME="$BASE_DIR/.runtime/opencode"

if [ ! -f $EXEC_PATH ]; then
	$SCRIPT_DIR/fetch_opencode.sh
fi

cd "$BASE_DIR"

# Non-blocking: create a detached session if one doesn't exist, otherwise leave it alone.
# Attach manually with `screen -r opencode` (detach again with Ctrl-A D).
if screen -list | grep -q "$SCREEN_SESSION_NAME"; then
  echo "> $SCREEN_SESSION_NAME session already running"
else
  # Build the runtime config from the repo template + llama-swap YAML. It lands in
  # /tmp (regenerated on every fresh start) and is passed to opencode via
  # OPENCODE_CONFIG, since `opencode serve` has no --config flag.
  echo "> Building /tmp/opencode.json"
  python3 $SCRIPT_DIR/generate_opencode_json.py $BASE_DIR/config/llama_swap.yaml $BASE_DIR/config/opencode.json.tmpl -o /tmp/opencode.json

  # Launch with HOME pointed at the isolated state root (OC_HOME). OpenCode
  # resolves its whole home — config dir, cache, session database, logs — from
  # $HOME, so pointing it elsewhere means this instance never reads or writes
  # the user's real ~/.config/opencode etc., and nothing installed by other
  # OpenCode usage on this machine can leak in. The explicit OPENCODE_CONFIG
  # file above is then the only config source (verified: /api/model registers
  # exactly the template's models with no global merge). First start populates
  # OC_HOME lazily; deleting it gives a clean slate.
  echo "> Starting new $SCREEN_SESSION_NAME session"
  mkdir -p "$OC_HOME"
  screen -dmS "$SCREEN_SESSION_NAME" env HOME="$OC_HOME" OPENCODE_CONFIG=/tmp/opencode.json "$EXEC_PATH" serve --hostname 0.0.0.0 --port 4096
fi

exit 0
