"""
Shared loader for model definitions in config/models/.

A model definition is one YAML file (e.g. config/models/single.yaml) that
is merged on top of the directory's _global.yaml when present:

- `args` is a MAPPING of arg name -> value in both files (not a list). The merge
  starts from the global args and updates them with the model's, so a key the
  model repeats overrides the global value in place (keeping its position) and
  new keys are appended at the end. A null value (~) marks a bare flag with no
  argument ("--jinja": ~ renders as just --jinja).
- Any other field the model defines (e.g. port) overrides the one from _global.yaml;
  fields only in _global.yaml (like port today) apply to every model.

Files whose name starts with `_` are not model configs — start.sh skips them.
"""

import sys
from pathlib import Path
from typing import Any, Dict, Optional

import yaml


GLOBAL_FILENAME = '_global.yaml'


def fail(msg: str) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def _load_yaml_mapping(path: Path) -> dict:
    try:
        data = yaml.safe_load(path.read_text(encoding='utf-8')) or {}
    except yaml.YAMLError as e:
        fail(f"parsing YAML file {path}: {e}")
    if not isinstance(data, dict):
        fail(f"top level of {path} must be a mapping")
    return data


def _validate_args(args: Any, source: str) -> Dict[str, Any]:
    """Check an args block is a name->value mapping with renderable values."""
    if args is None:
        return {}
    if not isinstance(args, dict):
        fail(f"'args' in {source} must be a mapping of arg name to value "
             f"(e.g. \"--ctx-size\": 131072), got {type(args).__name__}")
    for key, value in args.items():
        if not isinstance(key, str):
            fail(f"'args' keys in {source} must be strings, got {key!r}")
        # bool is a subclass of int — reject it explicitly: unquoted on/off/yes/no
        # values silently become booleans under YAML 1.1 (PyYAML).
        if isinstance(value, bool):
            fail(f"args value for '{key}' in {source} parsed as a boolean — "
                 f"quote the value (e.g. \"on\") so it stays a string")
        if value is not None and not isinstance(value, (str, int, float)):
            fail(f"args value for '{key}' in {source} must be null or a scalar, got {value!r}")
    return args


def load_model_config(model_path: str) -> dict:
    """
    Load one model definition with its global settings merged in.

    Args:
        model_path: Path to the model YAML (config/models/*.yaml)

    Returns:
        {'model_key': str, 'hf_model': str, 'port': int,
         'args': {arg name: value or None}}  # args = global merged with model's
    """
    path = Path(model_path)
    if not path.exists():
        fail(f"model YAML '{path}' not found")

    data = _load_yaml_mapping(path)

    missing = [k for k in ('model_key', 'hf_model') if data.get(k) in (None, '')]
    if missing:
        fail(f"{path} is missing required field(s): {', '.join(missing)}")

    # Global settings live next to the model file; optional by design so a
    # directory without one still works (the model then carries everything).
    global_data = {}
    global_path = path.parent / GLOBAL_FILENAME
    if global_path.exists():
        global_data = _load_yaml_mapping(global_path)

    # port: global default, overridable per model.
    port = data.get('port', global_data.get('port'))
    if port in (None, ''):
        fail(f"no 'port' defined in {path} or its {GLOBAL_FILENAME}")
    try:
        port = int(port)
    except (TypeError, ValueError):
        fail(f"'port' must be an integer, got {port!r}")
    if not 0 < port < 65536:
        fail(f"'port' out of range: {port}")

    # args: globals first (in their listed order), model entries added/overriding.
    global_args = _validate_args(global_data.get('args'), str(global_path))
    model_args = _validate_args(data.get('args'), str(path))
    merged_args: Dict[str, Any] = dict(global_args)
    merged_args.update(model_args)

    return {
        'model_key': str(data['model_key']),
        'hf_model': str(data['hf_model']),
        'port': port,
        'args': merged_args,
    }


def render_argv(args: Dict[str, Any]) -> list:
    """Flatten a merged args mapping into command-line tokens (one per arg/value)."""
    argv = []
    for key, value in args.items():
        if value is None:
            argv.append(key)          # bare flag ("--jinja": ~)
        else:
            argv.extend([key, str(value)])
    return argv
