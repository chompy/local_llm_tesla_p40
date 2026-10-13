# My Local Agentic LLM Setup

This repo contains scripts and configuration files I use to run LLMs locally for agentic coding. Specifically the scripts here build
llama.cpp, build and run llama-swap, and runs an opencode web server.

My setup has a Nvidia Tesla P40 (24GB VRAM) GPU with 32GB of DDR4 system memory.

The included llama-swap config includes the Qwen 3.8 27B model and what I believe are optimal settings for running it on the Tesla P40.

## Usage

Run `start.sh` to fetch the needed applications and to start the OpenCode web server.

On first run llama.cpp will need to compile, this takes a long time.

## Scripts

- `scripts/build_llama_cpp.sh`: Clone/pull the llama.cpp repo and build using flags needed for the Tesla P40
- `scripts/fetch_llama_swap.sh`: Fetch the latest llama-swap release
- `scripts/fetch_opencode.sh`: Fetch the latest OpenCode release
- `scripts/generate_opencode_json.py`: Sync models defined in llama-swap config to OpenCode
- `scripts/start_llama_swap.sh`: Start llama-swap inside a screen session if session doesn't already exist
- `scripts/start_opencode.sh`: Start opencode web server inside a screen session if session doesn't already exist
