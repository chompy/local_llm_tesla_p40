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
# The generated runtime config lives inside the isolated home, at exactly where
# OpenCode would look for its own opencode.json (passed explicitly as
# OPENCODE_CONFIG too — belt and suspenders).
OC_CONFIG="$OC_HOME/.config/opencode/opencode.json"
# Model definition to build the provider entry from (required): one of
# config/models/*.yaml, passed by start.sh (so this instance sees the
# context limit of whichever model is serving). No default on purpose.
if [ -z "${1:-}" ]; then
	echo "Usage: $0 <model_yaml>   (e.g. $BASE_DIR/config/models/single.yaml)" >&2
	exit 1
fi
MODEL_YAML="$1"

if [ ! -f $EXEC_PATH ]; then
	$SCRIPT_DIR/fetch_opencode.sh
fi

cd "$BASE_DIR"

# Non-blocking: create a detached session if one doesn't exist, otherwise leave it alone.
# Attach manually with `screen -r opencode` (detach again with Ctrl-A D).
if screen -list | grep -q "$SCREEN_SESSION_NAME"; then
  echo "> $SCREEN_SESSION_NAME session already running"
else
  # Build the runtime config from the repo template + model YAML. It lands in
  # the isolated home (regenerated on every fresh start) and is passed to
  # opencode via OPENCODE_CONFIG, since `opencode serve` has no --config flag.
  echo "> Building $OC_CONFIG"
  python3 $SCRIPT_DIR/generate_opencode_json.py "$MODEL_YAML" $BASE_DIR/config/opencode.json.tmpl -o "$OC_CONFIG"

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

  # Web app password (Basic auth; the username is always "opencode"). opencode
  # serve has no option to disable auth, but a fixed known password reduces it to
  # a one-time browser prompt — browsers remember Basic auth credentials per
  # origin. Generated once into the isolated home (gitignored) and reused on every
  # restart; changing it would sign all existing browser sessions out. An
  # OPENCODE_PASSWORD in the environment overrides the stored value.
  SERVER_PW_FILE="$OC_HOME/.server_password"
  if [ -z "${OPENCODE_PASSWORD:-}" ] && [ ! -f "$SERVER_PW_FILE" ]; then
    head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 20 > "$SERVER_PW_FILE"
    chmod 600 "$SERVER_PW_FILE"
  fi
  SERVER_PW="${OPENCODE_PASSWORD:-$(cat "$SERVER_PW_FILE" 2>/dev/null)}"
  echo "> Web app password: $SERVER_PW   (stored in $SERVER_PW_FILE)"

  screen -dmS "$SCREEN_SESSION_NAME" env HOME="$OC_HOME" OPENCODE_CONFIG="$OC_CONFIG" OPENCODE_PASSWORD="$SERVER_PW" "$EXEC_PATH" serve --hostname 0.0.0.0 --port 4096
fi

exit 0
