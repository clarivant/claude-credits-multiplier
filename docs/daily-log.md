# Daily Log — Apr 25 → May 18, 2026

Complete day-by-day record from one Claude Max workload. Three data streams merged: API-equivalent cost from JSONL transcripts, Opus/Sonnet split from opusplan-validation.sh, and tokens kept out of context from ctx-mode-lifetime.sh.

**Run the same scripts on your own data** — see [the main README](../README.md#measure-your-own-numbers).

---

## The log

| Date | $/day | Turns | Opus% | Ctx tokens saved | What changed |
|---|---|---|---|---|---|
| 2026-04-25 | $1,173 | 7,729 | 64.9% | — | **v1 stack cutover** — LiteLLM proxy live, watchdog, PAL removed |
| 2026-04-26 | $478 | 2,435 | 100% | — | First full day on new stack |
| 2026-04-27 | $854 | 3,852 | 100% | — | — |
| 2026-04-28 | $1,267 | 5,030 | 99.4% | — | Heavy sprint day |
| 2026-04-29 | $747 | 2,485 | 100% | — | — |
| 2026-04-30 | $628 | 2,446 | 98.2% | — | **Thinking-OFF audit** → architect-fast alias added, thinking flipped |
| 2026-05-01 | $33 | 511 | 0% | — | Low-activity; all-Sonnet (no plan mode used) |
| 2026-05-02 | $203 | 2,529 | 14.2% | — | **opusplan activated** — instant 85% Sonnet split |
| 2026-05-03 | $336 | 3,524 | 20.9% | 183,808 | **Context Mode MCP added** (.mcp.json), hooks starting to wire |
| 2026-05-04 | $638 | 6,946 | 19.3% | 0 | **Telemetry scripts built** (4 scripts); baseline captured; heavy sprint |
| 2026-05-05 | $349 | 4,091 | 16.4% | 304,082 | **Read guard hook wired** (Read >200 lines → ctx_execute_file) |
| 2026-05-06 | $420 | 3,243 | 26.0% | 688,127 | — |
| 2026-05-07 | $512 | 2,284 | 44.6% | 154,272 | **opusplan-validation.sh fix** (false negative — verdict scoped to May 2+) |
| 2026-05-08 | $163 | 1,561 | 16.5% | 97,182 | — |
| 2026-05-09 | $102 | 1,388 | 10.4% | 2,142,254 | Heavy ctx-mode sprint — 2.1M tokens sandboxed |
| 2026-05-10 | $83 | 1,106 | 2.7% | 12,918 | Lowest-cost day in window |
| 2026-05-11 | $378 | 6,069 | 0.6% | 2,166,160 | Heavy sprint — 2.2M ctx tokens saved |
| 2026-05-12 | $616 | 6,085 | 13.2% | 0 | Heavy sprint — high Sonnet volume |
| 2026-05-13 | $561 | 4,923 | 20.3% | 1,292,007 | 1.3M ctx tokens saved; SocratiCode base64 bug diagnosed + vendored patch |
| 2026-05-14 | $78 | 1,018 | 0% | 0 | Low-activity; all-Sonnet |
| 2026-05-15 | $87 | 1,153 | 5.9% | 0 | — |
| 2026-05-16 | $757 | 6,699 | 22.3% | 896,201 | Heavy sprint; cache-read multiplier quantified; multiplier math fixed |
| 2026-05-17 | $306 | 4,177 | 5.1% | 0 | — |
| 2026-05-18 | $154 | 1,689 | 14.8% | 172,875 | Public reference doc written |

---

## How to read this

- **$/day** — API-equivalent at Opus/Sonnet/Haiku pricing computed from JSONL token counts in `~/.claude/projects/`. On Max flat-rate, this is quota burn, not invoice.
- **Opus%** — share of turns routed to Opus. Pre-May 2: 99–100%. Post-May 2: avg 15.8%.
- **Ctx tokens saved** — tokens kept out of Claude's context window by Context Mode MCP. `—` = before Context Mode existed. `0` = day with no ctx-mode activity.
- **What changed** — the intervention that drove a visible inflection. Blank rows are steady-state.

---

## Inflection points

**May 2 — opusplan activated**
Cost: $478 → $203. Opus share: 99% → 14%. This is the single biggest lever. No infrastructure required — just an env var.

**May 9 and May 11 — Context Mode heavy sprints**
Two back-to-back days with 2M+ tokens sandboxed by Context Mode. Large file reads and web fetches that would have saturated the context window stayed in the local FTS5 index. Cost stayed low despite high turn counts.

**The floor**
May 10 and May 14 are low-activity days at $83 and $78. These are the natural floor — minimal plan mode usage, low turn count, all Sonnet. They set a reference for what the stack costs at idle.

---

## Week-over-week summary

| Period | Total $ | Turns | Avg $/day | Avg $/turn | $/day multiplier |
|---|---|---|---|---|---|
| W0 Apr 25–30 (6d) | $5,148 | 23,977 | $858 | $0.215 | 1× (baseline) |
| W1 May 1–7 (7d) | $2,490 | 24,689 | $356 | $0.101 | 2.4× |
| W2 May 8–14 (7d) | $1,981 | 23,303 | $283 | $0.085 | **3.0×** |
| W3 May 15–18 (4d) | $1,303 | 13,743 | $326 | $0.095 | 2.6× |

Multiplier = W0 avg $/day ÷ Wx avg $/day. $/turn = total $ ÷ total turns.

W2 is the stabilized state — all three layers running, no major incidents. W3 is slightly higher due to one heavy sprint day (May 16, $757) that skews the 4-day partial week.
