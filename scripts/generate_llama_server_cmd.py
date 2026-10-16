#!/usr/bin/env python3
"""
Build the llama-server command line from config/model.yaml.

Usage: generate_llama_server_cmd.py <model_yaml> [binary]

Prints one shell-ready line on stdout (each token shlex-quoted so spaces and
special characters survive `sh -c`):

    <binary> --port <port> -hf <hf_model> <args...>

start_llama_server.sh runs that line with the working directory set to the
repo root, so relative paths in args (e.g. --chat-template-file) resolve there.
"""

import shlex
import sys
from pathlib import Path

import yaml


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <model_yaml> [binary]", file=sys.stderr)
        sys.exit(1)

    yaml_path = Path(sys.argv[1])
    if not yaml_path.exists():
        print(f"Error: YAML file '{yaml_path}' not found", file=sys.stderr)
        sys.exit(1)

    try:
        data = yaml.safe_load(yaml_path.read_text(encoding='utf-8')) or {}
    except yaml.YAMLError as e:
        print(f"Error parsing YAML file {yaml_path}: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(data, dict):
        print(f"Error: top level of {yaml_path} must be a mapping", file=sys.stderr)
        sys.exit(1)

    missing = [k for k in ('model_key', 'hf_model', 'port') if data.get(k) in (None, '')]
    if missing:
        print(f"Error: model.yaml is missing required field(s): {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    port = data['port']
    try:
        port = int(port)
    except (TypeError, ValueError):
        print(f"Error: 'port' must be an integer, got {port!r}", file=sys.stderr)
        sys.exit(1)
    if not 0 < port < 65536:
        print(f"Error: 'port' out of range: {port}", file=sys.stderr)
        sys.exit(1)

    # args entries may carry flag+value pairs ("--ctx-size 131072") or bare
    # flags; flatten each one back into individual tokens.
    argv = []
    for entry in data.get('args') or []:
        if not isinstance(entry, str):
            print(f"Error: every args entry must be a string, got {entry!r}", file=sys.stderr)
            sys.exit(1)
        argv.extend(shlex.split(entry))

    binary = sys.argv[2] if len(sys.argv) > 2 else 'llama-server'
    full_argv = [binary, '--port', str(port), '-hf', str(data['hf_model']), *argv]
    print(shlex.join(full_argv))


if __name__ == '__main__':
    main()
