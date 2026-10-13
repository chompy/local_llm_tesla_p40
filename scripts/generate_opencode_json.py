#!/usr/bin/env python3
"""
Script to replace model configurations in a JSON file based on a YAML definition file.
"""

import yaml
import json
import argparse
import sys
from pathlib import Path
from typing import Dict, Any


def load_yaml_models(yaml_path: str) -> Dict[str, str]:
    """
    Load model names from YAML file.
    
    Args:
        yaml_path: Path to the YAML file
        
    Returns:
        Dictionary mapping model IDs to their display names
    """
    with open(yaml_path, 'r', encoding='utf-8') as f:
        yaml_data = yaml.safe_load(f)
    
    models = {}
    if 'models' in yaml_data:
        for model_key in yaml_data['models'].keys():
            # Create a user-friendly display name from the model key
            display_name = model_key.replace('-', ' ').replace('_', ' ').title()
            models[model_key] = display_name
    
    return models


def update_json_models(json_path: str, yaml_models: Dict[str, str], output_path: str = None) -> None:
    """
    Update the models section in a JSON file with models from YAML.
    
    Args:
        json_path: Path to the JSON file
        yaml_models: Dictionary of model IDs and their display names from YAML
        output_path: Optional output path (if different from input)
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
    
    # Replace models
    new_models = {}
    for model_id, display_name in yaml_models.items():
        new_models[model_id] = {"name": display_name}
    
    json_data['provider']['llama-swap']['models'] = new_models
    
    # Save the updated JSON
    output_file = output_path if output_path else json_path
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(json_data, f, indent=2, ensure_ascii=False)
    
    print(f"Successfully updated {len(yaml_models)} models in {output_file}")


def backup_json_file(json_path: str) -> Path:
    """
    Create a backup of the JSON file before modifying it.
    
    Args:
        json_path: Path to the JSON file
        
    Returns:
        Path to the backup file
    """
    json_file = Path(json_path)
    backup_path = json_file.with_suffix('.backup')
    
    import shutil
    shutil.copy2(json_path, backup_path)
    print(f"Backup created at {backup_path}")
    
    return backup_path


def main():
    parser = argparse.ArgumentParser(
        description='Replace model configurations in a JSON file with models from a YAML file'
    )
    parser.add_argument(
        'yaml_file',
        help='Path to the YAML file containing model definitions'
    )
    parser.add_argument(
        'json_file',
        help='Path to the JSON file to update'
    )
    parser.add_argument(
        '-o', '--output',
        help='Output file path (default: overwrite input file)'
    )
    parser.add_argument(
        '--no-backup',
        action='store_true',
        help='Skip creating a backup of the JSON file'
    )
    parser.add_argument(
        '--pretty',
        action='store_true',
        help='Pretty print the display names'
    )
    
    args = parser.parse_args()
    
    # Validate input files
    if not Path(args.yaml_file).exists():
        print(f"Error: YAML file '{args.yaml_file}' not found", file=sys.stderr)
        sys.exit(1)
    
    if not Path(args.json_file).exists():
        print(f"Error: JSON file '{args.json_file}' not found", file=sys.stderr)
        sys.exit(1)
    
    try:
        # Load models from YAML
        print(f"Loading models from {args.yaml_file}...")
        yaml_models = load_yaml_models(args.yaml_file)
        
        if not yaml_models:
            print("Warning: No models found in YAML file", file=sys.stderr)
            sys.exit(1)
        
        print(f"Found {len(yaml_models)} models: {', '.join(yaml_models.keys())}")
        
        # Create backup if requested
        if not args.no_backup:
            backup_json_file(args.json_file)
        
        # Update JSON file
        print(f"Updating {args.json_file}...")
        update_json_models(args.json_file, yaml_models, args.output)
        
        # Display summary
        print("\nUpdated models:")
        for model_id, display_name in yaml_models.items():
            print(f"  {model_id} -> {display_name}")
            
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
