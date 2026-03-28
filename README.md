# ollama-delegate

A shell-based workflow for delegating reasoning, planning, and code tasks from
Claude Code to local Ollama models — reducing API token cost, latency, and data
egress for tasks that don't require frontier-model capability.

## Concept

Claude Code runs as an AI CLI against Anthropic's API. Every reasoning step
burns tokens and adds round-trip latency. Many subtasks — outlining a plan,
summarizing a log, drafting a function, answering a sysadmin question — can be
handled adequately by a capable local model. `delegate.sh` is the glue: pipe
context in, get output back, use it as a scaffold.

```
User → Claude Code (orchestrator)
              │
              ├─ Simple subtask? → delegate.sh → local Ollama model → result
              │
              └─ Frontier reasoning needed? → Claude API
```

## Files

| File | Purpose |
|------|---------|
| `delegate.sh` | Core delegation script — prompt routing, busy-wait, streaming |
| `peek.sh` | Operator snapshot: loaded model, GPU util, pending requests, stuck heuristic |
| `reset.sh` | Graduated recovery: API unload → kill runner → service restart |
| `test_models.sh` | Three-tier test suite + concurrent queue stress test |
| `models.md` | Model selection reference, VRAM constraints, think-block handling |
| `examples/plan_task.sh` | Pre-plan a task with deepseek-r1:14b before acting |
| `examples/summarize_log.sh` | Compress a log through ministral-3:8b before Claude reads it |
| `examples/draft_code.sh` | First-pass code generation via devstral:24b |
| `examples/sysadmin_query.sh` | Shell/sysadmin Q&A via nemotron-terminal-14b |
| `examples/syshealth.sh` | Full system health snapshot (SMART, RAID, GPU, Ollama, disk) |

## Requirements

- Ollama running at `localhost:11434` (or set `$OLLAMA_HOST`)
- `curl`, `jq`, `date`, `sed` in PATH
- At least one Ollama model pulled

## delegate.sh — usage

```bash
# Inline prompt (batch — waits for full response)
./delegate.sh <model> "your prompt"

# Streaming — tokens printed as they arrive, Ctrl-C to interrupt cleanly
./delegate.sh --stream <model> "your prompt"

# Stdin (use - as second arg)
echo "your prompt" | ./delegate.sh <model> -
cat large_file.txt | ./delegate.sh --stream qwen3.5:9b -

# Block until Ollama is fully idle before sending (avoids swap mid-generation)
./delegate.sh --wait <model> "your prompt"
./delegate.sh --wait --max-wait 120 <model> "your prompt"

# Suppress status/warn messages — stdout = model response only (good for capture)
./delegate.sh --quiet <model> "your prompt"
PLAN=$(./delegate.sh --quiet deepseek-r1:14b "Plan X")
```

## --stream vs batch

| Mode | When to use |
|------|-------------|
| Batch (default) | Capture output into a variable; short prompts where wall time is similar |
| `--stream` | Long generations (reasoning chains, code, explanations) where you want live feedback; interactive use |

Streaming uses `stream:true` on the Ollama API. Tokens arrive as newline-delimited
JSON chunks; the read loop extracts `.response` and prints immediately. A SIGINT
trap kills the curl child cleanly.

## Busy-wait behavior

`OLLAMA_MAX_LOADED_MODELS=1` means one model in VRAM at a time. `delegate.sh`
detects the current state and handles contention:

| Scenario | Default | With `--wait` |
|----------|---------|---------------|
| Requested model warm | Send immediately | Send immediately |
| No model loaded (cold start) | Send immediately | Send immediately |
| Different model loaded, **idle** | Warn + send (Ollama swaps) | Wait for unload |
| Different model loaded, **active** (keep-alive just reset or lapsed with pending requests) | Warn + queue | Wait for unload |

Without `--wait`, Ollama's own queue serializes requests — your prompt lands
when the current generation finishes. Use `--wait` when you need the result
promptly and want to avoid sharing VRAM with another in-flight generation.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama API endpoint |
| `OLLAMA_DELEGATE_VERBOSE` | `1` | Set `0` to suppress status messages globally |
| `OLLAMA_DELEGATE_MAX_BYTES` | `65536` | Max prompt size in bytes; fails loudly above this to prevent silent empty responses |

## peek.sh — operator monitoring

```bash
./peek.sh              # single snapshot
./peek.sh --watch      # refresh every 3s
./peek.sh --watch 5    # custom interval
```

Shows: loaded model + quant + context length + VRAM, per-GPU compute/memory
utilization, runner PID uptime + CPU%, pending request count, keep-alive expiry
(negative = model held by active request past keep-alive), and a **stuck
heuristic**: GPU ~0% with pending requests flagged with suggested fix.

## reset.sh — recovery

```bash
./reset.sh --status                         # read-only state dump
./reset.sh --unload <model>                 # API force-unload (won't work mid-generation)
./reset.sh --unload-all                     # unload all loaded models
./reset.sh --kill-runner                    # SIGTERM runner process (sudo); service recovers
./reset.sh --restart                        # systemctl restart ollama (prompts for confirm)
```

**Escalation order:** `--unload` → `--kill-runner` → `--restart`

> **Warning:** `--restart` drops all in-flight connections. Any background
> `delegate.sh` calls will get empty responses and must be re-run.

## test_models.sh — test suite

```bash
./test_models.sh --tier1        # small models, smoke + busy-wait tests
./test_models.sh --tier2        # medium models, quality spot-check
./test_models.sh --tier3        # heavy models, inference quality
./test_models.sh --concurrent [N] [model]   # N parallel requests, queue stress
./test_models.sh --all          # everything
```

Tier 1 (7 tests) verified: basic Q&A, stdin pipe, code snippet, `--quiet`,
`--wait`, model swap, busy-wait warn path — all passing.
Concurrent/4 verified: 4 simultaneous requests serialize correctly in ~5s wall time.

## Operational lessons (from live testing)

**Prompt quoting:** Never embed large file content via `$()` substitution in a
shell prompt argument. Special characters (backticks, braces, quotes) corrupt the
JSON payload silently. Always pipe large inputs via stdin:
```bash
# Bad — breaks on shell metacharacters, hits byte limit
./delegate.sh model "$(cat bigfile.sh)"

# Good
cat bigfile.sh | ./delegate.sh model -
```

**`--restart` orphans queued jobs.** Background `delegate.sh` calls holding a
curl connection to `/api/generate` get empty responses when the service restarts.
Re-run them afterward. Prefer `--kill-runner` for softer recovery.

**`expires_at` is static.** `/api/ps` sets `expires_at` once at load time (or
on request completion), not per-token. It is NOT a generation progress indicator.
Use GPU utilization (`nvidia-smi`) as the real heartbeat.

**Reasoning models loop on meta-prompts.** `nemotron-terminal-14b` (and likely
`-32b`) will enter infinite repetition loops when asked to reason about its own
constraints ("use only bash builtins…"). Use `deepseek-r1:14b` for meta/planning
tasks; use nemotron models only for concrete sysadmin questions with clear answers.

**Model swap cost:** ~15s for 7–14b swaps; ~30–60s for 24–32b models. Batch
calls by model family to minimize swaps (see `models.md`).

## Integration with Claude Code

Claude Code calls `delegate.sh` via its Bash tool to offload subtasks:

```bash
# Reasoning scaffold — pre-plan before acting
PLAN=$(./delegate.sh --quiet deepseek-r1:14b \
  "List 5 numbered steps to migrate this cron job to systemd. Be concise.")

# Live explanation during long analysis
./delegate.sh --stream devstral:24b \
  "Review this Rust function for correctness and suggest improvements"

# Log compression before Claude reads it
journalctl -u ollama --since "1 hour ago" \
  | ./delegate.sh --quiet ministral-3:8b - \
  > /tmp/ollama_summary.txt
```

The latency math: a local 14b model at ~25 tok/s takes 2–8s for most planning
prompts. A Claude API round-trip also costs tokens. For multi-step tasks this
compounds — delegation pays off quickly.

## Limitations

- `OLLAMA_NUM_PARALLEL=1` — no concurrent generations; requests queue.
- `OLLAMA_KEEP_ALIVE=5m` — warm hit avoids ~15s load penalty.
- Large models (32b+) may not fit in VRAM alongside other workloads.
- Local model quality is below frontier — treat output as a scaffold, not final.
- `stream:true` output cannot be captured into a variable cleanly; use batch
  mode when you need to store the response.
