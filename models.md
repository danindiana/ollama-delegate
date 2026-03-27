# Model Selection Reference

This document covers how to pick the right local model for a delegation task,
and how to audit what's available on your host.

## Checking available models

```bash
ollama list                          # all pulled models + size
curl -s localhost:11434/api/tags | jq '[.models[] | {name, size}]'
curl -s localhost:11434/api/ps       # currently loaded (warm) models
```

## Task → Model mapping

### Reasoning / Planning
Use when you need multi-step analysis, trade-off evaluation, or architectural decisions.

| Model | VRAM | Notes |
|-------|------|-------|
| `deepseek-r1:32b` | ~20 GB | Best quality; slow to load |
| `deepseek-r1:14b` | ~9 GB | Best cost/quality ratio for planning |
| `deepseek-r1:8b` | ~5 GB | Fast, weaker on complex chains |
| `AceReason-Nemotron-14B` | ~9 GB | Math/reasoning specialist |

### Sysadmin / Shell / Terminal
Purpose-trained for CLI tasks, script writing, Linux administration.

| Model | VRAM | Notes |
|-------|------|-------|
| `nemotron-terminal-32b` | ~28 GB | Highest quality terminal reasoning |
| `nemotron-terminal-14b` | ~9 GB | Good quality, much faster load |

**Note:** Both nemotron-terminal models are reasoning models — they emit a
`<think>...</think>` block before the answer. Strip it if you need clean output:

```bash
./delegate.sh nemotron-terminal-14b "your question" | sed '/<think>/,/<\/think>/d'
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
| `qwen3.5:9b` | ~6.6 GB | Good general-purpose |
| `ministral-3:8b` | ~6 GB | Fast, clean output, no think block |
| `hermes3:8b` | ~4.7 GB | Instruction-following |

### Embeddings (non-generative)
| Model | VRAM | Notes |
|-------|------|-------|
| `nomic-embed-text` | ~274 MB | Text similarity, RAG pipelines |

## VRAM constraints on this host

Dual NVIDIA GPUs. `OLLAMA_MAX_LOADED_MODELS=1` — only one model warm at a time.
`OLLAMA_KEEP_ALIVE=5m` — model stays loaded 5 minutes after last use.

**Model swap cost:** ~10–30s for 7–14b models, ~30–60s for 30b+ models.

## Warm hit strategy

Request the same model consecutively to avoid swap penalties:

```bash
# Bad: alternates models, triggers swap on every call
./delegate.sh deepseek-r1:14b "plan X"
./delegate.sh nemotron-terminal-14b "how to do Y"
./delegate.sh deepseek-r1:14b "plan Z"   # swap again

# Better: batch by model
./delegate.sh deepseek-r1:14b "plan X"
./delegate.sh deepseek-r1:14b "plan Z"
./delegate.sh nemotron-terminal-14b "how to do Y"
```

## Stripping think blocks

Reasoning models (deepseek-r1, nemotron-terminal, AceReason) emit internal
chain-of-thought wrapped in `<think>` tags. Filter if you need clean output:

```bash
./delegate.sh deepseek-r1:14b "..." | awk '/<\/think>/{found=1; next} found'
```
