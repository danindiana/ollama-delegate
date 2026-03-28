# Project Status

**Repo:** https://github.com/danindiana/ollama-delegate
**Local:** `~/Documents/claude_creations/2026-03-27_181510_1774653310_ollama-delegate/`
**Last active:** 2026-03-27

## What this is

Shell toolkit for delegating subtasks from Claude Code to local Ollama models.
Core idea: offload planning/summarization/code drafts to local LLMs to reduce
Anthropic API token spend and latency on tasks that don't need frontier quality.

## Current state — all working, committed, pushed

| Script | Status |
|--------|--------|
| `delegate.sh` | Complete — batch + `--stream`, busy-wait, prompt guard, dep check |
| `peek.sh` | Complete — live operator snapshot with stuck heuristic |
| `reset.sh` | Complete — graduated recovery (unload → kill-runner → restart) |
| `test_models.sh` | Complete — tier1 7/7 pass, concurrent/4 pass |
| `examples/syshealth.sh` | Complete — SMART, RAID, GPU, Ollama, disk |
| `examples/plan_task.sh` | Complete |
| `examples/draft_code.sh` | Complete |
| `examples/summarize_log.sh` | Complete |
| `examples/sysadmin_query.sh` | Complete — think-block auto-stripped |

## What was tested live today

- Full reset chain: `--unload` (blocked mid-gen) → `--kill-runner` (needs sudo,
  now fixed) → `--restart` (works, prompts confirm)
- Tier 1 tests: 7/7 pass across ministral-3:8b, qwen3:4b, qwen2.5-coder:7b,
  qwen3.5:9b
- Concurrent/4: 4 parallel requests queued and serialized correctly in 5s
- `--stream` verified live: tokens arrive incrementally, Ctrl-C clean
- nemotron-terminal-14b: confirmed loops on meta-prompts (22KB of repeated text);
  documented in models.md and README

## What's not done yet

- `--tier2` and `--tier3` test runs (medium/heavy models)
- Streaming mode not yet tested on reasoning models (deepseek-r1 think blocks
  stream fine in theory, worth verifying)
- No install script / PATH setup (currently run as `./delegate.sh` from project dir)
- No systemd timer or cron integration for scheduled delegation tasks

## Key operational notes

- `expires_at` in `/api/ps` is static — not a generation progress indicator
- `--restart` orphans in-flight `delegate.sh` calls (they return empty)
- Large prompts via `$()` substitution corrupt JSON silently — always pipe via stdin
- nemotron-terminal models loop on abstract/meta prompts; use deepseek-r1:14b instead
- GPU util via `nvidia-smi` is the real heartbeat for stuck detection

## Quick resume

```bash
cd ~/Documents/claude_creations/2026-03-27_181510_1774653310_ollama-delegate
./peek.sh                          # check Ollama state
./test_models.sh --tier2           # pick up testing
./delegate.sh --stream deepseek-r1:14b "your task"
```
