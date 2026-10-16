# My Local Agentic LLM Setup

This repo contains scripts and configuration files I use to run LLMs locally for agentic coding. The stack is:

- **llama.cpp** — serves the model (built from source, CUDA), launched directly as a single `llama-server` instance on port 5800
- **OpenCode web server** — agentic coding UI pointed at llama-server

My setup has a Nvidia Tesla P40 (24GB VRAM, sm_61 / Pascal — DP4A but no tensor cores) GPU with 32GB of DDR4 system memory.

The stack serves `unsloth/Qwen3.8-27B-GGUF:Q4_K_M` (~17GB). Since only one model is used there is no multiplexer in front of the server (llama-swap was dropped for that reason); everything about the launch lives in `config/model.yaml`. Its args are tuned for the P40 and verified to fit: Qwen3.8 is a hybrid SSM/full-attention model (only ~1/4 of layers hold KV), so q4_0 KV cache at 131K context is only ~2.5GB, leaving headroom under the card's 24GB alongside the weights. Speculative decoding uses the MTP layer shipped inside the GGUF itself (`--spec-type draft-mtp`), no separate draft model needed.

## Dependencies

| Component | Requirement | Used by |
|---|---|---|
| C++ toolchain (gcc/g++) + `cmake` (≥ 3.20) | required | building llama.cpp from source |
| git | required | cloning llama.cpp |
| CUDA toolkit with cuBLAS dev libraries (`nvcc`, `libcublas.so` + headers, e.g. Ubuntu's `nvidia-cuda-toolkit`) | required | llama.cpp CUDA build (`-DGGML_CUDA=ON`) |
| GNU screen (`screen` package) | required | running both services in detached sessions |
| Node.js + npm | required | installing OpenCode (`npm install @opencode/cli`, pinned to ^2.0.27 in `lib/opencode/package.json`) |
| Python 3 + PyYAML (`pip install pyyaml`) | required | `scripts/generate_llama_server_cmd.py` (builds the llama-server command line from `config/model.yaml`) and `scripts/generate_opencode_json.py` (builds `/tmp/opencode.json` from the OpenCode config template and the model YAML) |

## Usage

Run `start.sh` to start everything:

```sh
./start.sh
```

On first run llama.cpp is cloned and compiled with CUDA, which takes a long time. After that it only rebuilds when the `llama-server` binary is missing. Both services then come up in detached screen sessions at the same time and the script returns immediately:

- **llama-server** — the model server on port 5800, launched directly in its own session. The command line is built by `scripts/generate_llama_server_cmd.py` from `config/model.yaml` (binary + `--port` + `-hf <model>` + your args); see that file's comments for the P40-specific reasoning behind them.
- **opencode** — OpenCode web server on 0.0.0.0:4096. On each fresh start its config is rebuilt from `config/opencode.json.tmpl` + `config/model.yaml` into `/tmp/opencode.json` (syncing the model's display name, token limits and the provider baseURL), and the server runs with `OPENCODE_CONFIG` pointed at that file. The instance also runs fully isolated from the rest of the system: it starts with `HOME` set to `.runtime/opencode/` (gitignored), so OpenCode's entire state — its own config directory, cache, session database and logs — lives under that tree and nothing in your real `~/.config/opencode` or any other OpenCode install on this machine is read or can leak in.

Attach to a session with `screen -r llama-server` or `screen -r opencode`; detach again without killing it using Ctrl-A D. List sessions with `screen -ls`.

To stop everything, run `stop.sh`:

```sh
./stop.sh
```

It terminates both screen sessions and sweeps up any leftover processes, matching them against this repo's component paths so nothing is left holding VRAM (e.g. a llama-server started outside the sessions). It is idempotent: running it when nothing is up just reports that no sessions were found.

The individual scripts can also be run standalone; they are non-blocking and will not re-create a session that is already running:

- `scripts/start_llama_server.sh`: start the model server (command built from `config/model.yaml`) in a detached screen session if one doesn't exist
- `scripts/start_opencode.sh`: start the opencode web server in a detached screen session if one doesn't exist

## Scripts

- `start.sh`: build llama.cpp if needed, then start both services simultaneously
- `scripts/build_llama_cpp.sh`: clone/pull llama.cpp and build it with CUDA. Uses `-DGGML_CUDA_FORCE_MMQ=ON` so quantized GEMMs run on Pascal's DP4A units; do not add `-DGGML_CUDA_FORCE_CUBLAS` alongside it (it takes precedence in code and silently disables MMQ)
- `scripts/fetch_opencode.sh`: install OpenCode via npm into `lib/opencode/`
- `scripts/generate_llama_server_cmd.py`: read `config/model.yaml` and print the exact shell-ready command line to run (`llama-server --port <port> -hf <model>` + args, each token quoted so it survives `sh -c`)
- `scripts/generate_opencode_json.py`: build an OpenCode runtime config from `config/opencode.json.tmpl` plus `config/model.yaml` — display name (from `model_key`), context limit (from `--ctx-size` in args) and per-response output limit (from `-n`/`--predict`, default 16384), plus the provider baseURL from `port`. Both limit fields are required by OpenCode's schema; without them OpenCode falls back to its built-in defaults. Output goes to `/tmp/opencode.json` by default (`-o` overrides)
- `scripts/start_llama_server.sh`: build the command from `config/model.yaml` and start llama-server inside a detached screen session if one doesn't already exist
- `scripts/start_opencode.sh`: build `/tmp/opencode.json` from the template, then start the opencode web server in a detached screen session if one doesn't already exist — launched with `OPENCODE_CONFIG=/tmp/opencode.json` and an isolated `HOME` (`.runtime/opencode/`) so it never touches your real OpenCode state

## Configuration

- `config/model.yaml` — the single source of truth for what is served (`model_key`, `-hf` repo, port) and how llama-server is launched (args list; see the comments in the file for the P40-specific reasoning). Both generator scripts read it
- `config/chat_template.jinja` — chat template passed to llama-server via `--chat-template-file` together with `--jinja`
- `config/opencode.json.tmpl` — the OpenCode config template (schema, permissions, disabled providers, plugin, compaction, and the local llama-server provider entry). The model and its baseURL are filled in from `model.yaml` at startup; edit this file to change any other OpenCode setting
- `.runtime/opencode/` (gitignored) — runtime state root for the opencode instance: its own config directory, cache, session database and logs. Created automatically on first start; delete it if you want a clean slate
