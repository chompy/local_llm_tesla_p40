#!/usr/bin/env python3
"""
Build an OpenCode runtime config from a template plus a YAML definition file.

Starts from the repo's OpenCode config template (config/opencode.json.tmpl),
syncs each model's display name and token limits into it, and writes the
finished config to /tmp/opencode.json (or --output). start_opencode.sh then
launches `opencode serve` with OPENCODE_CONFIG pointed at that file, so the
template is the single source of truth instead of ~/.config/opencode/opencode.json.

Token limits are synced so OpenCode reports the real context window instead of
its built-in default:

- context: from --ctx-size in the model's llama-server cmd
- output:  from -n/--predict when present (the per-response max_tokens that gets
           sent to llama-server), otherwise DEFAULT_OUTPUT_LIMIT. Both fields are
           REQUIRED by OpenCode's config schema — a limit with only `context`
           fails validation and makes the whole model disappear.
"""

import yaml
import json
import argparse
import re
import sys
from pathlib import Path
from typing import Dict, Any, Optional


def expand_macros(cmd: str, macros: Dict[str, Any]) -> str:
    """
    Expand ${macro} references in a command the same way llama-swap does.

    Unknown references (e.g. ${PORT}, filled in by llama-swap at runtime) are left as-is.
    """
    result = cmd or ""
    for name, value in macros.items():
        result = result.replace("${" + str(name) + "}", str(value))
    return result


def extract_ctx_size(cmd: str, macros: Dict[str, Any]) -> Optional[int]:
    """
    Find the --ctx-size value in a model's (macro-expanded) command.

    Args:
        cmd: The raw cmd string from the YAML model definition
        macros: The 'macros' section of the YAML file

    Returns:
        The context size as an int, or None if no --ctx-size was found
    """
    tokens = expand_macros(cmd, macros).split()
    for i, token in enumerate(tokens):
        if token == "--ctx-size" and i + 1 < len(tokens) and tokens[i + 1].isdigit():
            return int(tokens[i + 1])
        match = re.match(r"^--ctx-size=(\d+)$", token)
        if match:
            return int(match.group(1))
    return None


# Fallback per-response output limit. llama-server itself is unlimited by default
# (n_predict = -1), so this value only bounds what OpenCode requests per response.
# 16K leaves room for long agentic responses/tool calls; override it by adding
# -n <N> (or --predict) to the model's cmd in llama_swap.yaml.
DEFAULT_OUTPUT_LIMIT = 16384

# Where the finished config lands. start_opencode.sh launches `opencode serve`
# with OPENCODE_CONFIG pointing at this file, so OpenCode uses it instead of
# ~/.config/opencode/opencode.json. Regenerated fresh on every new session.
DEFAULT_OUTPUT = '/tmp/opencode.json'


def extract_output_limit(cmd: str, macros: Dict[str, Any]) -> Optional[int]:
    """
    Find the per-response token limit (-n/--predict/--n-predict) in a model's
    (macro-expanded) command. Exact-token matching so it never collides with -np.

    Args:
        cmd: The raw cmd string from the YAML model definition
        macros: The 'macros' section of the YAML file

    Returns:
        The output limit as an int, or None if no predict flag was found
    """
    tokens = expand_macros(cmd, macros).split()
    for i, token in enumerate(tokens):
        if token in ("-n", "--predict", "--n-predict") and i + 1 < len(tokens) and tokens[i + 1].isdigit():
            return int(tokens[i + 1])
        match = re.match(r"^(?:-n|--predict|--n-predict)=(\d+)$", token)
        if match:
            return int(match.group(1))
    return None


def load_yaml_models(yaml_path: str) -> Dict[str, dict]:
    """
    Load model definitions from YAML file.

    Args:
        yaml_path: Path to the YAML file

    Returns:
        Dictionary mapping model IDs to their OpenCode model entries
        (display name plus context limit taken from --ctx-size in the cmd)
    """
    with open(yaml_path, 'r', encoding='utf-8') as f:
        yaml_data = yaml.safe_load(f)

    models = {}
    if 'models' in yaml_data:
        macros = yaml_data.get('macros', {}) or {}
        for model_key, model_def in yaml_data['models'].items():
            # Create a user-friendly display name from the model key
            display_name = model_key.replace('-', ' ').replace('_', ' ').title()
            entry: dict = {"name": display_name}

            ctx_size = None
            out_size = None
            if isinstance(model_def, dict):
                cmd = model_def.get('cmd', '')
                ctx_size = extract_ctx_size(cmd, macros)
                out_size = extract_output_limit(cmd, macros)

            # OpenCode's schema requires BOTH context and output in a limit block;
            # with no --ctx-size we omit the whole block rather than emit an invalid one.
            if ctx_size is not None:
                entry["limit"] = {"context": ctx_size, "output": out_size or DEFAULT_OUTPUT_LIMIT}
            else:
                print(f"Warning: no --ctx-size found for model '{model_key}', "
                      f"OpenCode will use its default context limit", file=sys.stderr)

            models[model_key] = entry

    return models


def update_json_models(json_path: str, yaml_models: Dict[str, dict], output_path: str = None) -> None:
    """
    Fill the models section of an OpenCode config template with models from YAML.

    Args:
        json_path: Path to the JSON template file (read-only source; never modified)
        yaml_models: Dictionary of model IDs and their OpenCode entries
            ({"name": ..., optionally "limit": {"context": N}})
        output_path: Optional output path (default: overwrite input file)
    """
    # Load existing JSON
    with open(json_path, 'r', encoding='utf-8') as f:
        json_data = json.load(f)
    
    # Check if the expected structure exists
    if 'provider' not in json_data:
        print("Error: 'provider' key not found in JSON file", file=sys.stderr)
        sys.exit(1)
    
    if 'llama-swap' not in json_data['provider']:
        print("Error: 'llama-swap' provider not found in JSON file", file=sys.stderr)
        sys.exit(1)
    
    if 'models' not in json_data['provider']['llama-swap']:
        print("Error: 'models' key not found under provider.llama-swap", file=sys.stderr)
        sys.exit(1)
    
    # Replace models (entries already shaped for OpenCode by load_yaml_models)
    json_data['provider']['llama-swap']['models'] = dict(yaml_models)
    
    # Save the updated JSON (template stays untouched; output is a fresh artifact)
    output_file = output_path if output_path else json_path
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(json_data, f, indent=2, ensure_ascii=False)
        f.write('\n')
    
    print(f"Successfully updated {len(yaml_models)} models in {output_file}")


def main():
    parser = argparse.ArgumentParser(
        description='Build an OpenCode config from a template plus model definitions in a YAML file'
    )
    parser.add_argument(
        'yaml_file',
        help='Path to the YAML file containing model definitions'
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
        # Load models from YAML
        print(f"Loading models from {args.yaml_file}...")
        yaml_models = load_yaml_models(args.yaml_file)
        
        if not yaml_models:
            print("Warning: No models found in YAML file", file=sys.stderr)
            sys.exit(1)
        
        print(f"Found {len(yaml_models)} models: {', '.join(yaml_models.keys())}")
        
        # Fill the template and write the finished config (fresh every run —
        # the template is a read-only source in the repo, so no backup needed)
        print(f"Writing {args.output} from {args.template_file}...")
        update_json_models(args.template_file, yaml_models, args.output)
        
        # Display summary
        print("\nUpdated models:")
        for model_id, entry in yaml_models.items():
            limit = entry.get('limit')
            if limit:
                suffix = f" (ctx {limit['context']}, out {limit['output']})"
            else:
                suffix = " (no --ctx-size found, default context limit)"
            print(f"  {model_id} -> {entry['name']}{suffix}")
            
    except yaml.YAMLError as e:
        print(f"Error parsing YAML file: {e}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON file: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
