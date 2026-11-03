# My Local Agentic LLM Setup

This repo contains scripts and configuration files I use to run LLMs locally for agentic coding. The stack is:

- **llama.cpp** — serves the model (built from source, CUDA), launched directly as a single `llama-server` instance on port 5800
- **OpenCode web server** — agentic coding UI pointed at llama-server

My setup has a Nvidia Tesla V100 (32GB VRAM, sm_70 / Volta — FP16 tensor cores) GPU with 32GB of system memory.

The stack serves `mradermacher/Swift-1.5-Qwen3.8-27b-i1-GGUF:Q4_K_M` (~17GB). Since only one model is used there is no multiplexer in front of the server (llama-swap was dropped for that reason); everything about the launch lives in `config/model_single.yaml` (one agent, full 131K context) or `config/model_multi.yaml` (two concurrent agents on two parallel slots). The args are tuned for the V100 and verified to fit: Swift 1.5 Qwen3.8 is a hybrid SSM/full-attention model (only ~1/4 of layers hold KV), so even an f16 KV cache at 131K context keeps the single-agent server around ~27GiB under load — comfortable headroom on the card's 32GB alongside the weights. Speculative decoding uses the MTP layer shipped inside the GGUF itself (`--spec-type draft-mtp`), no separate draft model needed; the optimal `--spec-draft-n-max` for this GPU and context size was found with `scripts/bench_draft_max.sh`.

## Dependencies

| Component | Requirement | Used by |
|---|---|---|
| C++ toolchain (gcc/g++) + `cmake` (≥ 3.20) | required | building llama.cpp from source |
| git | required | cloning llama.cpp |
| CUDA toolkit with cuBLAS dev libraries (`nvcc`, `libcublas.so` + headers, e.g. Ubuntu's `nvidia-cuda-toolkit`) | required | llama.cpp CUDA build (`-DGGML_CUDA=ON`) |
| GNU screen (`screen` package) | required | running both services in detached sessions |
| Node.js + npm | required | installing OpenCode (`npm install @opencode/cli`, pinned to ^2.0.27 in `lib/opencode/package.json`) |
| Python 3 + PyYAML (`pip install pyyaml`) | required | `scripts/generate_llama_server_cmd.py` (builds the llama-server command line from a mode's model YAML) and `scripts/generate_opencode_json.py` (builds `.runtime/opencode/.config/opencode/opencode.json` from the OpenCode config template and the model YAML) |

## Usage

There are two serving modes, both launched from the repo root. Only one model server can run at a time, so switch modes with `./stop.sh` first:

### Single agent — `start_single.sh`

Full 131K context with an f16 KV cache; the everyday setup:

```sh
./start_single.sh
```

On first run llama.cpp is cloned and compiled with CUDA, which takes a long time. After that it only rebuilds when the `llama-server` binary is missing. Both services then come up in detached screen sessions at the same time and the script returns immediately:

- **llama-server** — the model server on port 5800, launched directly in its own session. The command line is built by `scripts/generate_llama_server_cmd.py` from `config/model_single.yaml` (binary + `--port` + `-hf <model>` + your args); see that file's comments for the V100-specific reasoning behind them.
- **opencode** — OpenCode web server on 0.0.0.0:4096. On each fresh start its config is rebuilt from `config/opencode.json.tmpl` + the mode's model YAML into its own home at `.runtime/opencode/.config/opencode/opencode.json` (syncing the model's display name, token limits and the provider baseURL), which is also passed to it explicitly via `OPENCODE_CONFIG`. The instance also runs fully isolated from the rest of the system: it starts with `HOME` set to `.runtime/opencode/` (gitignored), so OpenCode's entire state — its own config directory, cache, session database and logs — lives under that tree and nothing in your real `~/.config/opencode` or any other OpenCode install on this machine is read or can leak in.

### Two agents — `start_multi.sh`

One llama-server with **two parallel slots** (`-np 2`, 96K context per slot, q8_0 KV cache) plus the same local OpenCode instance on :4096. The second agent runs remotely from another machine and talks to the same llama-server directly over the network (it binds `0.0.0.0:5800`, OpenAI-compatible API). Both agents generate concurrently; while both are active each gets roughly half the single-agent token rate.

```sh
./stop.sh && ./start_multi.sh
```

llama.cpp's slot model is what makes a separate serving engine unnecessary here: two slots give two independent KV caches and concurrent decoding behind the same API OpenCode already speaks, and MTP speculative decoding keeps working per-slot (an earlier vLLM prototype had to drop its draft model entirely just to fit). The 96K/q8_0 budget in `config/model_multi.yaml` is what fits two conversations plus weights on the 32GB card — f16 KV at two slots would not.

Attach to a session with `screen -r llama-server` or `screen -r opencode`; detach again without killing it using Ctrl-A D. List sessions with `screen -ls`.

To stop everything (either mode), run `stop.sh`:

```sh
./stop.sh
```

It terminates both screen sessions and sweeps up any leftover processes, matching them against this repo's component paths so nothing is left holding VRAM (e.g. a llama-server started outside the sessions). It is idempotent: running it when nothing is up just reports that no sessions were found.

The individual scripts can also be run standalone; they are non-blocking and will not re-create a session that is already running:

- `scripts/start_llama_server.sh [model_yaml]`: start the model server in a detached screen session if one doesn't exist (default `config/model_single.yaml`)
- `scripts/start_opencode.sh [model_yaml]`: start the opencode web server in a detached screen session if one doesn't exist (default `config/model_single.yaml`)

Note that running either mode script while *any* model server is up refuses to start — switch modes with `./stop.sh` first, so a stale single-slot server can never keep serving in multi-agent mode (or vice versa).

## Scripts

- `start_single.sh`: build llama.cpp if needed, then start the single-agent stack (llama-server from `config/model_single.yaml` + opencode)
- `start_multi.sh`: same, but with the two-slot multi-agent server (`config/model_multi.yaml`) so a second agent can connect remotely on port 5800 while the local OpenCode instance runs as usual
- `scripts/build_llama_cpp.sh`: clone/pull llama.cpp and build it with CUDA (`-DGGML_CUDA=ON`). No Pascal-specific flags: on Volta the tensor-core FP16 kernels are the fast path, so `GGML_CUDA_FORCE_MMQ` (DP4A) is deliberately not set
- `scripts/bench_draft_max.sh`: A/B benchmark runner for `--spec-draft-n-max`. Stops the stack and waits for VRAM to release, then cycles bare llama-server instances per draft value (args from `config/model_single.yaml`, only `--spec-draft-n-max` swapped), benchmarks each with a fixed prompt, and restores the canonical single-agent stack via `start_single.sh` — even on Ctrl-C. Run it from a separate terminal while OpenCode is idle: `./scripts/bench_draft_max.sh [value ...]`
- `scripts/fetch_opencode.sh`: install OpenCode via npm into `lib/opencode/`
- `scripts/generate_llama_server_cmd.py <model_yaml>`: read a mode's model YAML and print the exact shell-ready command line to run (`llama-server --port <port> -hf <model>` + args, each token quoted so it survives `sh -c`)
- `scripts/generate_opencode_json.py <model_yaml> <template> [-o out]`: build an OpenCode runtime config from the template plus a mode's model YAML — display name (from `model_key`), context limit (from `--ctx-size` in args) and per-response output limit (from `-n`/`--predict`, default 16384), plus the provider baseURL from `port`. Both limit fields are required by OpenCode's schema; without them OpenCode falls back to its built-in defaults. Output lands in the isolated OpenCode home (`.runtime/opencode/.config/opencode/opencode.json`) by default (`-o` overrides)
- `scripts/start_llama_server.sh [model_yaml]`: build the command from a mode's model YAML and start llama-server inside a detached screen session if one doesn't already exist
- `scripts/start_opencode.sh`: build the runtime config from the template into `.runtime/opencode/.config/opencode/opencode.json`, then start the opencode web server in a detached screen session if one doesn't already exist — launched with that file as an explicit `OPENCODE_CONFIG` plus an isolated `HOME` (`.runtime/opencode/`) so it never touches your real OpenCode state

## Configuration

- `config/model_single.yaml` — single-agent mode: what is served (`model_key`, `-hf` repo, port) and how llama-server is launched (full 131K ctx, f16 KV; see the comments in the file for the V100-specific reasoning). Read by both generator scripts via `start_single.sh`
- `config/model_multi.yaml` — two-agent mode: same model, launched with `-np 2`, 96K context per slot and q8_0 KV so two concurrent conversations fit the card. Read by both generator scripts via `start_multi.sh`
- `config/chat_template.jinja` — chat template passed to llama-server via `--chat-template-file` together with `--jinja`
- `config/opencode.json.tmpl` — the OpenCode config template (schema, permissions, disabled providers, plugin, compaction, and the local llama-server provider entry). The model and its baseURL are filled in from the mode's model YAML at startup; edit this file to change any other OpenCode setting
- `.runtime/opencode/` (gitignored) — runtime state root for the opencode instance: its own config directory, cache, session database and logs. Created automatically on first start; delete it if you want a clean slate
