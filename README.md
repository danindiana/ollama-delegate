# ollama-delegate

A shell-based workflow pattern for delegating reasoning, planning, and code tasks from Claude Code to local Ollama models — reducing API token cost, latency, and data egress for tasks that don't require frontier-model capability.

## Concept

Claude Code runs as an AI CLI against Anthropic's API. Every reasoning step burns tokens and adds round-trip latency. Many subtasks — outlining a plan, summarizing a log, drafting a first-pass function, answering a sysadmin question — can be handled adequately by a capable local model. `delegate.sh` is the glue: pipe context in, get output back, use it as a scaffold.

```
User → Claude Code (orchestrator)
              │
              ├─ Simple subtask? → delegate.sh → local Ollama model → result
              │
              └─ Frontier reasoning needed? → Claude API
```

## System Requirements

- Ollama running at `localhost:11434` (or set `OLLAMA_HOST`)
- `curl`, `jq` in PATH
- At least one Ollama model pulled

## Usage

```bash
# Inline prompt
./delegate.sh <model> "your prompt"

# Stdin prompt (use - as second arg)
echo "your prompt" | ./delegate.sh <model> -
cat file.txt | ./delegate.sh <model> -

# Wait until Ollama is fully idle before sending (avoids interrupting active generations)
./delegate.sh --wait <model> "your prompt"

# Wait with custom timeout (seconds)
./delegate.sh --wait --max-wait 120 <model> "your prompt"

# Suppress status/warning messages (stdout = model response only)
./delegate.sh --quiet <model> "your prompt"
```

## Busy-Wait Behavior

`OLLAMA_MAX_LOADED_MODELS=1` means only one model lives in VRAM at a time. When another client (OpenWebUI, a concurrent Claude session, etc.) is using Ollama, `delegate.sh` handles it gracefully:

| Scenario | Default behavior | With `--wait` |
|----------|-----------------|---------------|
| Requested model already loaded (warm) | Send immediately | Send immediately |
| No model loaded (cold start) | Send immediately | Send immediately |
| Different model loaded, **idle** (keep-alive window) | Warn + send (Ollama swaps after current keep-alive) | Wait for unload, then send |
| Different model loaded, **likely generating** (expires_at just reset) | Warn + queue (Ollama queues, swaps after generation finishes) | Wait for unload, then send |

The `--wait` flag is appropriate when you need the result immediately and would rather wait than compete for VRAM. Without it, Ollama's own request queue handles serialization — your request lands when the current generation finishes.

## Model Selection Guide

Models available on this host and their delegation roles:

| Model | Size | Best for |
|-------|------|----------|
| `deepseek-r1:32b` | 19 GB | Complex multi-step reasoning, architectural decisions |
| `deepseek-r1:14b` | 9 GB | General reasoning, planning, analysis — best cost/quality ratio |
| `deepseek-r1:8b` | 5.2 GB | Fast reasoning when 14b is overkill |
| `nemotron-terminal-32b` | 28 GB | Sysadmin, shell scripting, CLI task planning |
| `nemotron-terminal-14b` | 9 GB | Sysadmin at lower VRAM cost |
| `devstral:24b` | 14 GB | Code generation, review, refactor |
| `qwen3-coder:30b` | 18 GB | Heavy code tasks |
| `qwen2.5-coder:14b` | 9 GB | Code generation, fast and capable |
| `qwen2.5-coder:7b` | 4.7 GB | Lightweight code tasks |
| `qwen3.5:9b` | 6.6 GB | General-purpose fast drafts, Q&A |
| `ministral-3:8b` | 6 GB | Summarization, quick answers |
| `nomic-embed-text` | 274 MB | Embeddings only (not generative) |

**Rule of thumb:** Use the smallest model that produces adequate output for the task. Model swaps cost ~10–30s of load time on this hardware (dual NVIDIA, `OLLAMA_MAX_LOADED_MODELS=1`).

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama API endpoint |
| `OLLAMA_DELEGATE_VERBOSE` | `1` | Set to `0` to suppress status messages (same as `--quiet`) |

## Examples

See `examples/` for ready-to-run delegation patterns:

- `plan_task.sh` — pre-plan a multi-step task before acting
- `summarize_log.sh` — compress a log file before Claude reads it
- `draft_code.sh` — generate a first-pass implementation
- `sysadmin_query.sh` — ask a terminal-specialized model a shell/sysadmin question

## Integration with Claude Code

Claude Code can call `delegate.sh` via its Bash tool to offload subtasks. Typical pattern:

```bash
# Get a reasoning scaffold before acting
PLAN=$(./delegate.sh deepseek-r1:14b "Plan the steps to migrate this cron job to systemd. Be concise.")
# Then act on $PLAN rather than burning Claude API tokens on the reasoning pass
```

The latency tradeoff: a local 14b model at ~25 tok/s takes 2–8 seconds for most planning prompts, vs. a Claude API round-trip that also burns tokens. For multi-step tasks this compounds quickly.

## Limitations

- `OLLAMA_NUM_PARALLEL=1` means no concurrent generations. Requests queue.
- `OLLAMA_KEEP_ALIVE=5m` — models stay warm for 5 minutes after last use. A warm hit skips the ~15s load penalty.
- Large models (32b+) take longer to load and may swap out smaller models that were warm.
- Response quality is lower than frontier models — use for scaffolding, not final output.
