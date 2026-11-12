#!/usr/bin/env python3
"""
Build an OpenCode runtime config from a template plus the model definition YAML.

Starts from the repo's OpenCode config template (config/opencode.json.tmpl),
syncs the model's display name, token limits and the provider baseURL into it,
and writes the finished config into the isolated OpenCode home at
.runtime/opencode/.config/opencode/opencode.json (or --output).
start_opencode.sh then launches `opencode serve` with OPENCODE_CONFIG pointed at
that file, so the template + the model YAML are the single source of truth
instead of ~/.config/opencode/opencode.json.

Synced from a model definition in config/models/ (merged with its _global.yaml,
see scripts/model_config.py):
- name:    display name derived from model_key (title-cased)
- context: from --ctx-size in the merged args — OpenCode reports the real window
            instead of its built-in default
- output:  from -n/--predict when present (the per-response max_tokens sent to
            llama-server), otherwise DEFAULT_OUTPUT_LIMIT. Both limit fields are
            REQUIRED by OpenCode's schema — a limit with only `context` fails
            validation and makes the whole model disappear.
- baseURL: http://localhost:<port>, so the provider block tracks the port in
            the model configs instead of drifting from it (no /v1 suffix — see
            the note where it is set).
"""

import yaml
import json
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model_config import load_model_config


# Fallback per-response output limit. llama-server itself is unlimited by default
# (n_predict = -1), so this value only bounds what OpenCode requests per response.
# 16K leaves room for long agentic responses/tool calls; override it by adding
# "-n": <N> (or "--predict") to a model's args mapping in config/models/.
DEFAULT_OUTPUT_LIMIT = 16384

# Where the finished config lands by default: inside the isolated OpenCode home
# that start_opencode.sh re-roots via HOME (REPO_ROOT/.runtime/opencode is $OC_HOME),
# at exactly where OpenCode would look for its own opencode.json. The script sits in
# <repo>/scripts/, so the repo root is one level up from here. Regenerated fresh on
# every new session; start_opencode.sh also passes this path as OPENCODE_CONFIG.
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / '.runtime' / 'opencode' / '.config' / 'opencode' / 'opencode.json'

# The provider entry in the template that this script fills in (id == the key
# OpenCode shows as local/<model_key>).
PROVIDER_KEY = 'local'


def load_model(yaml_path: str):
    """
    Load one model definition (merged with its _global.yaml) for OpenCode.

    Args:
        yaml_path: Path to the model YAML (config/models/*.yaml)

    Returns:
        (model_key, port, entry) where entry is the OpenCode model dict
        ({"name": ..., optionally "limit": {"context": N, "output": M}})
    """
    cfg = load_model_config(yaml_path)
    model_key = cfg['model_key']

    # Display name derived from the key the same way as before (title-cased).
    display_name = model_key.replace('-', ' ').replace('_', ' ').title()
    entry: dict = {"name": display_name}

    args = cfg['args']

    def arg_int(name: str):
        value = args.get(name)
        if value is None:
            return None
        try:
            return int(value)
        except (TypeError, ValueError):
            print(f"Error: args entry '{name}' must be an integer, got {value!r}", file=sys.stderr)
            sys.exit(1)

    # Dict-form args make these direct lookups (no token scanning needed).
    ctx_size = arg_int('--ctx-size')
    out_size = None
    for name in ('-n', '--predict', '--n-predict'):
        if args.get(name) is not None:
            out_size = arg_int(name)
            break

    # OpenCode's schema requires BOTH context and output in a limit block;
    # with no --ctx-size we omit the whole block rather than emit an invalid one.
    if ctx_size is not None:
        entry["limit"] = {"context": ctx_size, "output": out_size or DEFAULT_OUTPUT_LIMIT}
    else:
        print(f"Warning: no --ctx-size found in args for model '{model_key}', "
              f"OpenCode will use its default context limit", file=sys.stderr)

    return model_key, cfg['port'], entry


def update_json_model(json_path: str, model_key: str, port: int, entry: dict,
                      output_path: str = None, host: str = 'localhost') -> None:
    """
    Fill the provider section of an OpenCode config template with the model from YAML.

    Args:
        json_path: Path to the JSON template file (read-only source; never modified)
        model_key: The id under which the model is registered (provider/<key>)
        port: llama-server port — becomes options.baseURL so it tracks the model configs
        entry: OpenCode model dict ({"name": ..., optionally "limit": {...}})
        output_path: Optional output path (default: overwrite input file)
        host: Host for the provider baseURL. 'localhost' for the local instance;
            pass this machine's LAN address to build a config for remote clients
    """
    # Load existing JSON
    with open(json_path, 'r', encoding='utf-8') as f:
        json_data = json.load(f)

    # Check if the expected structure exists
    if 'provider' not in json_data:
        print("Error: 'provider' key not found in JSON file", file=sys.stderr)
        sys.exit(1)

    if PROVIDER_KEY not in json_data['provider']:
        print(f"Error: '{PROVIDER_KEY}' provider not found in JSON file", file=sys.stderr)
        sys.exit(1)

    provider = json_data['provider'][PROVIDER_KEY]
    if 'options' not in provider or 'baseURL' not in provider['options']:
        print(f"Error: 'options.baseURL' not found under provider.{PROVIDER_KEY}", file=sys.stderr)
        sys.exit(1)

    # Sync the endpoint and replace models (entry already shaped for OpenCode).
    # Note: no /v1 suffix — with this llama-server build the openai-compatible
    # provider breaks when it is present.
    provider['options']['baseURL'] = f"http://{host}:{port}"
    provider['models'] = {model_key: entry}

    # Save the updated JSON (template stays untouched; output is a fresh artifact).
    # The default location lives inside .runtime/, which may not exist yet on a
    # first-ever start, so create the parent tree if needed.
    output_file = Path(output_path) if output_path else Path(json_path)
    if output_file != Path(json_path):
        output_file.parent.mkdir(parents=True, exist_ok=True)
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(json_data, f, indent=2, ensure_ascii=False)
        f.write('\n')

    print(f"Successfully updated model '{model_key}' in {output_file} "
          f"(baseURL -> http://{host}:{port})")


def main():
    parser = argparse.ArgumentParser(
        description='Build an OpenCode config from a template plus the model definition YAML'
    )
    parser.add_argument(
        'yaml_file',
        help="Path to the model definition YAML file (e.g. config/models/single.yaml)"
    )
    parser.add_argument(
        'template_file',
        help=f'Path to the OpenCode config template (JSON) to start from'
    )
    parser.add_argument(
        '-o', '--output',
        default=DEFAULT_OUTPUT,
        help=f'Output file path (default: {DEFAULT_OUTPUT})'
    )
    parser.add_argument(
        '--host',
        default='localhost',
        help="Host for the provider baseURL (default: localhost). Pass this "
             "machine's LAN address to build a config for remote clients"
    )

    args = parser.parse_args()

    # Validate input files
    if not Path(args.yaml_file).exists():
        print(f"Error: YAML file '{args.yaml_file}' not found", file=sys.stderr)
        sys.exit(1)

    if not Path(args.template_file).exists():
        print(f"Error: template file '{args.template_file}' not found", file=sys.stderr)
        sys.exit(1)

    try:
        # Load the model from YAML
        print(f"Loading model from {args.yaml_file}...")
        model_key, port, entry = load_model(args.yaml_file)
        print(f"Found model: {model_key}")

        # Fill the template and write the finished config (fresh every run —
        # the template is a read-only source in the repo, so no backup needed)
        print(f"Writing {args.output} from {args.template_file}...")
        update_json_model(args.template_file, model_key, port, entry, args.output, args.host)

        # Display summary
        limit = entry.get('limit')
        if limit:
            suffix = f" (ctx {limit['context']}, out {limit['output']})"
        else:
            suffix = " (no --ctx-size found, default context limit)"
        print(f"\nUpdated model:")
        print(f"  {model_key} -> {entry['name']}{suffix}")

    except yaml.YAMLError as e:
        print(f"Error parsing YAML file: {e}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON file: {e}", file=sys.stderr)
        sys.exit(1)
    except SystemExit:
        raise
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
