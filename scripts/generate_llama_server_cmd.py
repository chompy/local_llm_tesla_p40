#!/usr/bin/env python3
"""
Build the llama-server command line from a model definition in config/models/.

Usage: generate_llama_server_cmd.py <model_yaml> [binary]

The model YAML is merged on top of its directory's _global.yaml (see
scripts/model_config.py): global args first, then the model's own args (which
override globals when a key repeats). A null arg value renders as a bare flag.

Prints one shell-ready line on stdout (each token shlex-quoted so spaces and
special characters survive `sh -c`):

    <binary> --port <port> -hf <hf_model> <args...>

start_llama_server.sh runs that line with the working directory set to the
repo root, so relative paths in args (e.g. --chat-template-file) resolve there.
"""

import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model_config import load_model_config, render_argv


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <model_yaml> [binary]", file=sys.stderr)
        sys.exit(1)

    cfg = load_model_config(sys.argv[1])

    binary = sys.argv[2] if len(sys.argv) > 2 else 'llama-server'
    full_argv = [binary, '--port', str(cfg['port']), '-hf', cfg['hf_model'],
                 *render_argv(cfg['args'])]
    print(shlex.join(full_argv))


if __name__ == '__main__':
    main()
