# claude-credits-multiplier

Get 2–3× more work from the same Claude Max subscription. Three layers that compound: model routing, context sandboxing, and local LLM delegation. All measured on a real workload over 24 days.

**Status:** in production since 2026-04-25. Snapshot maintained as the setup evolves — check commit history for what's changed.

---

## The result first

**If you're on Claude Max (flat-rate):** the invoice doesn't change. What changes is how much work fits before hitting the weekly quota. The 3× below is a quota multiplier — 3× more sprint-days per credit-week.

**If you're on usage-based API billing:** the 3× doesn't directly apply. opusplan alone (Layer 1) gets you ~50–60% cost reduction by routing most turns from Opus to Sonnet. Layers 2 and 3 add on top, but the compounding math is different. Run the telemetry scripts to measure your own ratio.

| Period | What was running | Avg cost/day | Credits multiplier | In practice |
|---|---|---|---|---|
| W0 Apr 25–30 | Baseline — all Opus, no stack | $858/day | 1× | Ran out of quota mid-week |
| W1 May 1–7 | opusplan + Context Mode wiring | $356/day | 2.4× | Full week, headroom |
| W2 May 8–14 | All three layers stable | $283/day | **3.0×** | Three sprints per credit-week |
| W3 May 15–18 | Steady state | $326/day | 2.6× | Running steady |

Multiplier = W0 daily rate ÷ Wx daily rate. Same $200/mo plan. The drop from $858 → $283 means the same quota budget now covers 3× as many sprint-days.

> These numbers are from one workload profile (heavy Claude Code usage across 5–8 projects simultaneously). Run the telemetry scripts against your own JSONL to measure your actual ratio — [see below](#measure-your-own-numbers).

---

## The three layers

### Layer 1 — opusplan: right model for the task

**What:** Set `ANTHROPIC_MODEL=opusplan` in your shell. Opus only fires in Plan Mode (Shift+Tab). Every other turn: Sonnet.

```bash
# .bashrc / .zshrc
export ANTHROPIC_MODEL=opusplan
```

**Result (measured):**

| Before | After |
|---|---|
| 99% Opus turns | 15.8% Opus turns |
| $0.2568/turn avg | $0.1010/turn avg |
| Quota exhausted mid-week | Full week with headroom |

The split stabilizes at 15–25% Opus depending on how often you use Plan Mode. Sonnet handles the vast majority of implementation, debugging, and file work without any quality loss on bounded tasks.

**How to verify it's working:**

```bash
# Clone this repo and run:
./scripts/opusplan-validation.sh --since 2026-05-01
```

Output shows per-day Opus/Sonnet/Haiku split with a pass/fail verdict.

---

### Layer 2 — Context Mode MCP: sandbox tool output

**What:** [context-mode](https://github.com/mksglu/context-mode) by [@mksglu](https://github.com/mksglu) keeps large tool results — web fetches, file reads, command output — out of Claude's context window. Output lands in a local FTS5 index. Only what you search for enters context.

**Install:**

```json
// .mcp.json in your project root
{
  "mcpServers": {
    "context-mode": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "context-mode"]
    }
  }
}
```

**Result (measured, 15 days):**

| Metric | Value |
|---|---|
| Sessions | 58 |
| Total `ctx_*` calls | 2,145 |
| Tokens kept out of context | **8,109,886** |
| Direct savings (Opus input rate) | $121.65 |
| Single web fetch reduction | 97.9% |

The compounding effect: at 96.1% session cache-hit rate, every token kept out of context early doesn't get re-read on every subsequent turn. The 8.1M number understates the real impact.

**Key tools:**

- `ctx_batch_execute` — run shell commands and index results (730 calls, 11.5 MB kept out)
- `ctx_execute_file` — analyze large files without loading them into context (602 calls)
- `ctx_fetch_and_index` — web fetches that stay out of context (43 calls)
- `ctx_search` — retrieve only the relevant chunks back into context (352 calls)

**Enforce it with hooks** (add to `~/.claude/settings.json`):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "WebFetch",
        "hooks": [{ "type": "command", "command": "echo 'Use ctx_fetch_and_index instead'" }]
      }
    ]
  }
}
```

---

### Layer 3 — SocratiCode + local LLM delegation

**What:** Two tools that keep bounded work off Claude entirely.

**[SocratiCode](https://github.com/giancarloerra/socraticode)** by [@giancarloerra](https://github.com/giancarloerra) — local semantic codebase search. Instead of loading files into context to answer "where is X used?", SocratiCode runs a hybrid semantic + BM25 search over a local index. Zero Claude tokens for codebase exploration.

```bash
# Install via MCP
npx -y socraticode
```

Reach for `mcp__socraticode__codebase_search` before `grep -r` or multi-file reads. Primary queries: "find all endpoints missing dep X", "where is config Y read", "callers of fn Z". Typical savings: 3–5 file reads per query avoided.

**Local LLM delegation** — route bounded tasks (commit messages, test stubs, format conversion, translations, boilerplate) to a local model instead of Claude. The key is `code_task_files`: pass the file path, not the file content.

| Method | Tokens to Claude |
|---|---|
| `code_task` — file content in prompt | ~7,500 |
| `code_task_files` — file path only | ~250 |
| **Delta** | **97% fewer tokens** |

The local model writes to disk. Claude gets the output. The file never enters Claude's context.

> **Caveat:** The 97% savings is Claude tokens — it requires a non-Claude executor (local GPU model, GPT-4o-mini, etc.). Without one, you're shifting the bill to a different provider, not eliminating it. The methodology generalizes to any cheap local-or-remote executor; the number only holds when Claude is fully off the path.

**Session totals (May 1–18, measured):**

- 890 chat calls to local models (architect-27B + drafter-14B)
- 91% offload ratio (local savings / total work)
- 0 errors, 0 fallbacks

---

## How the layers compound

Each layer hits a different part of the cost:

```
opusplan:       ~60–70% of total savings
                (Opus → Sonnet routing, every non-plan turn)

Context Mode:   ~20–25% and growing
                (tokens kept out of context never get re-read)

Local LLM:      ~8–12%
                (bounded tasks routed off Claude entirely)
```

opusplan is the biggest lever. You can get most of the benefit from Layer 1 alone. Layers 2 and 3 compound on top.

---

## Measure your own numbers

Three scripts that only depend on your Claude Code transcript JSONL (`~/.claude/projects/`):

```bash
# Daily cost by model tier + cache hit ratio
./scripts/cost-per-day.sh --since 2026-04-25

# Opus/Sonnet/Haiku split per day (validates opusplan is working)
./scripts/opusplan-validation.sh --since 2026-05-01

# Context Mode lifetime savings (requires context-mode MCP)
./scripts/ctx-mode-lifetime.sh
```

**Establish your baseline first:**

```bash
# Before making any changes — capture your current burn rate
./scripts/cost-per-day.sh --since $(date -d '7 days ago' +%Y-%m-%d)
```

Save that number. Then activate opusplan. Run the same script a week later. The ratio is your Layer 1 multiplier.

**Pricing constants** are in `scripts/lib/pricing.sh` — update if Anthropic changes rates. Current values: Opus $5/$25 input/output per MTok, Sonnet $3/$15, Haiku $1/$5 (as of 2026-04-28).

---

## Full daily log (Apr 25 → May 18)

The complete day-by-day record — cost, Opus%, context savings, and what changed each day — is in [docs/daily-log.md](docs/daily-log.md).

The inflection is visible: May 2 is the day opusplan activated. Cost dropped from ~$850/day to $203 overnight.

---

## What didn't work

Honest accounting of failures:

**nomic-embed via LiteLLM proxy** — tried routing through LiteLLM for unified telemetry. Cosine equivalence test failed (<0.99). Root cause: nomic-embed-text requires `search_query:` / `search_document:` task prefixes; the LiteLLM→Ollama adapter doesn't pass them. Stayed on Ollama direct.

**SocratiCode via LiteLLM (base64 bug)** — SocratiCode's OpenAI Node SDK sends `encoding_format: "base64"` by default. LiteLLM's Ollama adapter ignores it and returns raw floats. The SDK mis-decodes to 4× too-short vectors (768→192 dims). Fix: force `encoding_format: "float"` in the provider config. [Related upstream issues](https://github.com/giancarloerra/socraticode/issues).

**opusplan false negatives** — `opusplan-validation.sh` initially produced "NOT effective" verdicts because it averaged over all days including the all-Opus baseline. Fix: scope the verdict to post-activation dates only.

**Thinking mode on the local 27B** — Qwen3-14B emits zero output (all reasoning tokens, no content) on Makefile/config/multi-target tasks. Observed in production. Escalation rule: 0 emitted tokens → retry with the 27B model, do NOT fall back to writing it yourself.

---

## Requirements

- Claude Code (any plan; results are most visible on Max/Team plans with weekly quota)
- For Layer 1: none beyond setting an env var
- For Layer 2: Node 18+, `npx` ([context-mode](https://github.com/mksglu/context-mode))
- For Layer 3 (SocratiCode): Docker ([socraticode](https://github.com/giancarloerra/socraticode))
- For Layer 3 (local LLM): GPU hardware + [llama.cpp](https://github.com/ggerganov/llama.cpp) or [Ollama](https://ollama.ai)
- Telemetry scripts: `bash`, `python3`, `jq`

---

## Repo layout

```
claude-credits-multiplier/
├── scripts/
│   ├── cost-per-day.sh          # daily Claude spend + cache hit ratio
│   ├── opusplan-validation.sh   # Opus/Sonnet split per day
│   ├── ctx-mode-lifetime.sh     # Context Mode lifetime token savings
│   └── lib/
│       └── pricing.sh           # Anthropic pricing constants (single source of truth)
└── docs/
    └── daily-log.md             # complete day-by-day record Apr 25 → May 18
```

---

## Credits

- **[context-mode](https://github.com/mksglu/context-mode)** — [@mksglu](https://github.com/mksglu) — context window sandboxing via FTS5 index
- **[SocratiCode](https://github.com/giancarloerra/socraticode)** — [@giancarloerra](https://github.com/giancarloerra) — local semantic codebase search
- **[llama.cpp](https://github.com/ggerganov/llama.cpp)** — local inference backend
- **[LiteLLM](https://github.com/BerriAI/litellm)** — proxy and routing layer

---

## About

Built and maintained by [Arturo Camargo](https://clarivant.co) — founder at [Clarivant](https://clarivant.co), a consulting firm that runs AI-augmented workflows in production. The narrative companion to this repo — what this setup actually changed about how a small team works — is at [clarivant.co/insights](https://clarivant.co/insights).

This repo is the receipts. The site is the story.
