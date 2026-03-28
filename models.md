# Model Selection Reference

How to pick the right local model for a delegation task, and how to audit
what's available on your host.

## Checking available models

```bash
ollama list                          # all pulled models + size
curl -s localhost:11434/api/tags | jq '[.models[] | {name, size}]'
curl -s localhost:11434/api/ps       # currently loaded (warm) models
./peek.sh                            # full operator view
```

## Task → Model mapping

### Reasoning / Planning
Multi-step analysis, trade-off evaluation, architectural decisions, pre-planning
before Claude acts.

| Model | VRAM | Notes |
|-------|------|-------|
| `deepseek-r1:32b` | ~20 GB | Best quality; slow to load (~45s) |
| `deepseek-r1:14b` | ~9 GB | **Best all-round choice** — cost/quality/speed |
| `deepseek-r1:8b` | ~5 GB | Fast, weaker on complex chains |
| `AceReason-Nemotron-14B` | ~9 GB | Math/reasoning specialist |

All emit `<think>…</think>` blocks. Strip with:
```bash
./delegate.sh deepseek-r1:14b "..." | awk '/<\/think>/{found=1; next} found'
```

### Sysadmin / Shell / Terminal
Purpose-trained for CLI tasks, script writing, Linux administration. Use for
concrete sysadmin questions with clear factual answers.

| Model | VRAM | Notes |
|-------|------|-------|
| `nemotron-terminal-32b` | ~28 GB | Highest quality terminal reasoning |
| `nemotron-terminal-14b` | ~9 GB | Good quality, faster load |

**Known limitation:** Both nemotron-terminal models enter infinite repetition
loops on meta-prompts about their own constraints (e.g. "use only bash
builtins…" or self-referential instructions). Use `deepseek-r1:14b` instead for
any planning or abstract reasoning task. Nemotron is good at: "how do I do X on
Linux", "write a systemd unit for Y", "what command checks Z".

Strip think blocks:
```bash
./delegate.sh nemotron-terminal-14b "..." | sed '/<think>/,/<\/think>/d'
```

### Code Generation / Review
| Model | VRAM | Notes |
|-------|------|-------|
| `devstral:24b` | ~14 GB | Strong general code gen |
| `qwen3-coder:30b` | ~18 GB | Heavy tasks, best code quality |
| `qwen2.5-coder:14b` | ~9 GB | Fast, reliable |
| `qwen2.5-coder:7b` | ~4.7 GB | Lightest code model |

### Fast Summarization / Q&A
| Model | VRAM | Notes |
|-------|------|-------|
| `qwen3.5:9b` | ~6.6 GB | Good general-purpose, clean output |
| `ministral-3:8b` | ~6 GB | Fast, no think block, good for log compression |
| `hermes3:8b` | ~4.7 GB | Instruction-following |

### Embeddings (non-generative)
| Model | VRAM | Notes |
|-------|------|-------|
| `nomic-embed-text` | ~274 MB | Text similarity, RAG pipelines |

## VRAM constraints on this host

Dual NVIDIA (RTX 3080 10GB + RTX 3060 12GB = ~22GB usable).
`OLLAMA_MAX_LOADED_MODELS=1` — only one model warm at a time.
`OLLAMA_KEEP_ALIVE=5m` — model stays loaded 5 minutes after last use.
`OLLAMA_NUM_PARALLEL=1` — one generation at a time; additional requests queue.

**Model load cost (approximate):**
- 4–8b models: ~5–15s
- 14b models: ~15–25s
- 24–32b models: ~30–60s

A warm hit (same model, within keep-alive window) skips the load entirely.

## Warm hit strategy

Batch calls by model family to minimize swap penalties:

```bash
# Bad: three swaps
./delegate.sh deepseek-r1:14b "plan X"
./delegate.sh nemotron-terminal-14b "shell command for Y"
./delegate.sh deepseek-r1:14b "plan Z"

# Good: one swap
./delegate.sh deepseek-r1:14b "plan X"
./delegate.sh deepseek-r1:14b "plan Z"
./delegate.sh nemotron-terminal-14b "shell command for Y"
```

## Streaming vs batch by model

Use `--stream` for models where you'd otherwise stare at a blank terminal:

```bash
# Streaming makes sense: long reasoning chains, verbose code output
./delegate.sh --stream deepseek-r1:14b "Explain the tradeoffs of RAID-0 vs RAID-1 in depth"
./delegate.sh --stream devstral:24b "Write a Python HTTP server with auth middleware"

# Batch makes sense: short factual answers, output captured into a variable
ANSWER=$(./delegate.sh --quiet ministral-3:8b "What is the default SSH port?")
```

Note: streaming output cannot be cleanly captured into a shell variable. Use
batch mode (`stream: false`, the default) when storing the response.

## Stripping think blocks

Reasoning models (deepseek-r1, nemotron-terminal, AceReason-Nemotron) emit
internal chain-of-thought wrapped in `<think>` tags before the answer.

```bash
# Strip everything up to and including </think>
./delegate.sh deepseek-r1:14b "..." | awk '/<\/think>/{found=1; next} found'

# Alternative with sed
./delegate.sh nemotron-terminal-14b "..." | sed '/<think>/,/<\/think>/d'
```

`ministral-3:8b`, `qwen3.5:9b`, `hermes3:8b`, and the qwen-coder family do
**not** emit think blocks — output is ready to use directly.
