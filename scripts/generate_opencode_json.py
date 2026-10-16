#!/usr/bin/env python3
"""
Build an OpenCode runtime config from a template plus the model definition YAML.

Starts from the repo's OpenCode config template (config/opencode.json.tmpl),
syncs the model's display name, token limits and the provider baseURL into it,
and writes the finished config to /tmp/opencode.json (or --output).
start_opencode.sh then launches `opencode serve` with OPENCODE_CONFIG pointed at
that file, so the template + model.yaml are the single source of truth instead of
~/.config/opencode/opencode.json.

Synced from config/model.yaml:
- name:    display name derived from model_key (title-cased)
- context: from --ctx-size in args — OpenCode reports the real window instead of
           its built-in default
- output:  from -n/--predict when present (the per-response max_tokens sent to
           llama-server), otherwise DEFAULT_OUTPUT_LIMIT. Both limit fields are
           REQUIRED by OpenCode's schema — a limit with only `context` fails
           validation and makes the whole model disappear.
- baseURL: http://localhost:<port>/v1, so the provider block tracks the port in
           model.yaml instead of drifting from it.
"""

import yaml
import json
import argparse
import re
import shlex
import sys
from pathlib import Path
from typing import List, Optional


# Fallback per-response output limit. llama-server itself is unlimited by default
# (n_predict = -1), so this value only bounds what OpenCode requests per response.
# 16K leaves room for long agentic responses/tool calls; override it by adding
# -n <N> (or --predict) to the args list in model.yaml.
DEFAULT_OUTPUT_LIMIT = 16384

# Where the finished config lands. start_opencode.sh launches `opencode serve`
# with OPENCODE_CONFIG pointing at this file, so OpenCode uses it instead of
# ~/.config/opencode/opencode.json. Regenerated fresh on every new session.
DEFAULT_OUTPUT = '/tmp/opencode.json'

# The provider entry in the template that this script fills in (id == the key
# OpenCode shows as llama-server/<model_key>).
PROVIDER_KEY = 'llama-server'


def extract_flag_value(tokens: List[str], names: List[str]) -> Optional[int]:
    """
    Find an integer flag value in a token list, matching either `--flag 123` or
    `--flag=123` forms. Exact-token matching so e.g. -n never collides with -np.

    Args:
        tokens: Flattened argv of the model's launch command
        names: Flag spellings to look for (e.g. ["-n", "--predict"])

    Returns:
        The value as an int, or None if no matching flag was found
    """
    for i, token in enumerate(tokens):
        if token in names and i + 1 < len(tokens) and tokens[i + 1].isdigit():
            return int(tokens[i + 1])
        match = re.match(r"^(?:" + "|".join(re.escape(n) for n in names) + r")=(\d+)$", token)
        if match:
            return int(match.group(1))
    return None


def load_model(yaml_path: str):
    """
    Load the single model definition from model.yaml.

    Args:
        yaml_path: Path to config/model.yaml

    Returns:
        (model_key, port, entry) where entry is the OpenCode model dict
        ({"name": ..., optionally "limit": {"context": N, "output": M}})
    """
    with open(yaml_path, 'r', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}

    if not isinstance(data, dict):
        print(f"Error: top level of {yaml_path} must be a mapping", file=sys.stderr)
        sys.exit(1)

    missing = [k for k in ('model_key', 'port') if data.get(k) in (None, '')]
    if missing:
        print(f"Error: model.yaml is missing required field(s): {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    try:
        port = int(data['port'])
    except (TypeError, ValueError):
        print(f"Error: 'port' must be an integer, got {data['port']!r}", file=sys.stderr)
        sys.exit(1)

    model_key = str(data['model_key'])
    # Display name derived from the key the same way as before (title-cased).
    display_name = model_key.replace('-', ' ').replace('_', ' ').title()
    entry: dict = {"name": display_name}

    # args entries may carry flag+value pairs ("--ctx-size 131072") or bare
    # flags; flatten each one back into individual tokens.
    tokens: List[str] = []
    for i, arg in enumerate(data.get('args') or []):
        if not isinstance(arg, str):
            print(f"Error: args[{i}] must be a string, got {arg!r}", file=sys.stderr)
            sys.exit(1)
        tokens.extend(shlex.split(arg))

    ctx_size = extract_flag_value(tokens, ['--ctx-size'])
    out_size = extract_flag_value(tokens, ['-n', '--predict', '--n-predict'])

    # OpenCode's schema requires BOTH context and output in a limit block;
    # with no --ctx-size we omit the whole block rather than emit an invalid one.
    if ctx_size is not None:
        entry["limit"] = {"context": ctx_size, "output": out_size or DEFAULT_OUTPUT_LIMIT}
    else:
        print(f"Warning: no --ctx-size found in args for model '{model_key}', "
              f"OpenCode will use its default context limit", file=sys.stderr)

    return model_key, port, entry


def update_json_model(json_path: str, model_key: str, port: int, entry: dict, output_path: str = None) -> None:
    """
    Fill the provider section of an OpenCode config template with the model from YAML.

    Args:
        json_path: Path to the JSON template file (read-only source; never modified)
        model_key: The id under which the model is registered (provider/<key>)
        port: llama-server port — becomes options.baseURL so it tracks model.yaml
        entry: OpenCode model dict ({"name": ..., optionally "limit": {...}})
        output_path: Optional output path (default: overwrite input file)
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

    # Sync the endpoint and replace models (entry already shaped for OpenCode)
    provider['options']['baseURL'] = f"http://localhost:{port}/v1"
    provider['models'] = {model_key: entry}

    # Save the updated JSON (template stays untouched; output is a fresh artifact)
    output_file = output_path if output_path else json_path
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(json_data, f, indent=2, ensure_ascii=False)
        f.write('\n')

    print(f"Successfully updated model '{model_key}' in {output_file} "
          f"(baseURL -> http://localhost:{port}/v1)")


def main():
    parser = argparse.ArgumentParser(
        description='Build an OpenCode config from a template plus the model definition YAML'
    )
    parser.add_argument(
        'yaml_file',
        help='Path to the model definition YAML file (config/model.yaml)'
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
        update_json_model(args.template_file, model_key, port, entry, args.output)

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
