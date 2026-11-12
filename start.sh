#!/usr/bin/env bash
# Start the stack from a model config in config/models/: one llama-server (args
# merged with config/models/_global.yaml) + the OpenCode web server on :4096.
#
# Usage: ./start.sh [model_name]
#   model_name — base name of a file in config/models/, with or without .yaml
#                (e.g. "model_single"). With no argument, pick one interactively
#                from a menu instead.

BASE_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
MODELS_DIR="$BASE_DIR/config/models"
LLAMA_SERVER_BIN="$BASE_DIR/lib/llama_cpp/build/bin/llama-server"

# A server left over from another model config would keep serving with the wrong
# args; switching configs always goes through stop.sh. Checked first so a forgot-
# to-stop failure is reported before any prompt or long build.
if screen -list | grep -q "llama-server"; then
	echo "> A llama-server is already running — run ./stop.sh first." >&2
	exit 1
fi

list_models() { # print "<name><TAB><description>" per model config, sorted by name
	python3 - "$MODELS_DIR" <<'PYEOF'
import sys
from pathlib import Path
import yaml

models_dir = Path(sys.argv[1])
for f in sorted(models_dir.glob('*.yaml')):
	if f.name.startswith('_'):      # _global.yaml & friends are not model configs
		continue
	data = yaml.safe_load(f.read_text(encoding='utf-8')) or {}
	print(f"{f.stem}\t{data.get('description', '')}")
PYEOF
}

resolve_model() { # $1 = optional name; sets MODEL_YAML on success
	local name="${1:-}" line n=0 choice
	if [ -z "$name" ]; then
		# Interactive selection: accept a menu number or a config name, and
		# re-prompt on anything that matches neither.
		local lines=()
		mapfile -t lines < <(list_models)
		if [ "${#lines[@]}" -eq 0 ]; then
			echo "Error: no model configs found in $MODELS_DIR" >&2
			exit 1
		fi
		echo "Available model configs ($MODELS_DIR):"
		for line in "${lines[@]}"; do
			n=$((n+1))
			printf '  [%d] %-16s %s\n' "$n" "${line%%$'\t'*}" "${line#*$'\t'}"
		done
		while true; do
			if ! read -r -p "Select a model config (number or name): " choice; then
				echo "" >&2
				echo "Error: no selection made." >&2
				exit 1
			fi
			name=""
			case "$choice" in
				'') : ;;                        # blank: re-prompt below
				*[!0-9]*)                       # typed as a name
					local cand="${choice%.yaml}"
					[ -f "$MODELS_DIR/$cand.yaml" ] && name="$cand" ;;
				*)                              # menu number
					if [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
						line="${lines[$((choice-1))]}"
						name="${line%%$'\t'*}"
					fi ;;
			esac
			if [ -z "$name" ]; then
				echo "Invalid choice: '$choice' (expected 1-$n or a config name)" >&2
				continue
			fi
			break
		done
	fi

	case "$name" in *.yaml) name="${name%.yaml}";; esac
	MODEL_YAML="$MODELS_DIR/$name.yaml"
	if [ ! -f "$MODEL_YAML" ]; then
		echo "Error: no model config named '$name' in $MODELS_DIR. Available:" >&2
		list_models | cut -f1 | sed 's/^/  /' >&2
		exit 1
	fi
}

resolve_model "${1:-}"
echo "> Using model config: ${MODEL_YAML#"$BASE_DIR"/}"

# Only build llama.cpp if the binary is missing. A full CUDA rebuild takes a long
# time, so don't do it on every startup (the old check also looked for the wrong
# directory: llama.cpp lives in lib/llama_cpp).
if [ ! -x "$LLAMA_SERVER_BIN" ]; then
	echo "> llama-server not found, building llama.cpp (this takes a while)"
	"$BASE_DIR/scripts/build_llama_cpp.sh" || exit 1
fi

echo "> Starting llama-server and opencode web server"
# Both sub-scripts are non-blocking: they create detached screen sessions if the
# session doesn't exist yet, then return. Attach later with `screen -r <name>`.
"$BASE_DIR/scripts/start_llama_server.sh" "$MODEL_YAML" || exit 1
"$BASE_DIR/scripts/start_opencode.sh" "$MODEL_YAML" || exit 1
