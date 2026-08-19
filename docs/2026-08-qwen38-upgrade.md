# Addendum: the Qwen3.8 + MTP upgrade (Aug 18–19, 2026)

The May snapshot froze Layer 4 with a Qwen3.6-27B architect at ~33 tok/s. In August, Qwen
released Qwen3.8-27B, and the question every homelab operator faces — *"should we upgrade?"* —
got answered the way this repo answers everything: by measurement. The whole arc, from
"new weights on Hugging Face" to "2× throughput in production," took 27 elapsed hours, and every
step had a tested rollback.

This doc is the receipts for that arc, including two corrections to numbers previously published
here.

---

## The ~1 MB answer to "will it even load"

Before downloading a 19 GB GGUF, range-fetch its first 16 MB — that's the metadata header, and
it answers the two questions that kill upgrades:

```bash
curl -sL -r 0-16777215 -o probe.part \
  "https://huggingface.co/<repo>/resolve/main/<model>.gguf"
strings -n 4 probe.part | grep -A1 -m1 general.architecture
```

**Question 1 — does my llama.cpp build know this architecture?** Compare the string against
`src/llama-arch.cpp` in your installed build. Ours (4 months stale) listed `qwen35` — and the
probe showed Qwen3.8 declares `general.architecture = qwen35`, the same entry our production
Qwen3.6 already used. Parsing the full header showed something better: **Qwen3.8-27B and
Qwen3.6-27B have byte-identical hyperparameters** — same 64 blocks, same 24/4 heads, same hybrid
attention (48 linear + 16 full layers), same 262K native context. It's the same architecture
retrained. Load risk: ~zero, known before downloading anything.

**Question 2 — does the chat template still support the knob my stack depends on?** The template
is embedded in the same header. Qwen3.8 thinks by default (`reasoning_effort: xhigh` in the
released template), but `enable_thinking: false` — the exact mechanism behind the
`architect-fast` speed story in the main README — survives verbatim: the template emits a
pre-closed `<think>\n\n</think>` block. Also worth doing: diff the template across GGUF packs
(ggml-org / unsloth / bartowski) — launch-day community packs differ, and template bugs
masquerade as "broken quant" reports.

Total cost to de-risk the two biggest unknowns: three 16 MB range-fetches, zero downtime.

## The evaluation: three arms, eight gates, one human read

One 45-minute maintenance window on the second GPU (the drafter stopped for the duration), an
eval server on a scratch port, and **three arms**: production control (3.6 at Q5), a quant
control (3.6 at Q4), and the candidate (3.8 at Q4). The third arm is the trick — it separates
"the Q4 quantization hurt it" from "the model changed," turning the usual quant-confound
argument into a measurement.

| Gate | Bar | Result |
|---|---|---|
| Loads on the stale build, production flags | binary | first try |
| Thinking suppression (trivial prompt) | ≤10 completion tokens | **2** — identical to prod; survives the LiteLLM proxy with `drop_params: true` |
| Multi-turn integrity | no `<think>` artifacts, flat tokens | clean, [3, 2, 4] tokens/turn |
| Decode / prompt-eval vs prod (same-window `llama-bench`) | ≥0.90× | 1.07× / 1.16× |
| Golden-prompt wall-clock median (9 prompts) | ≤1.15× | **0.79×** — faster on 6/9; the "slower" ones wrote 1.4–2× more output tokens |
| Prompt-injection regression (15 fixtures, EN/ES: tool-lure, exfiltration, obfuscation, fake-authority) | ≥ nightly baseline | **15/15**, equal to baseline |
| Peak VRAM at 30K context | ≤22 GB | 19.6 GB on a 24 GB card |
| Quant confound (third arm) | measured | Q4 alone: +13% decode; the new model gives ~6% back — net faster |

The one gate no script can run: a human reading the nine output pairs side by side (Spanish
register, code quality, thoroughness-vs-bloat on the longer outputs). Verdict: as good or
better. Ten minutes of attention beats a fabricated LLM-judge score.

**A landmine found before it fired:** our watchdog's health smoke sends a trivial prompt with
`max_tokens: 20` and greps the `content` field. Under Qwen3.8's thinking-ON default, all 20
tokens go to `reasoning_content` — content comes back empty, and the health check fails every
5 minutes, forever. The fix (send the suppression kwarg in the smoke payload) shipped and was
verified against the *old* model before the swap. That's what eval-first buys: the failure mode
surfaced on a scratch port, not in production at 3 a.m.

## Cutover, then the runtime

The model swap was one line in a systemd unit. Restart-to-serving: **10 seconds** (page cache
still hot from the eval — the proxy's fallback route never fired). Overnight, the first
unattended automation cycle ran on the new model: injection suite 15/15, 283 calls, 0 errors,
latency median *better* than baseline (4,206 ms vs 4,454 ms).

Next morning, the runtime, same discipline. llama.cpp had drifted 4 months. Fresh clone, pinned
release tag (`b10502`), staged build to a non-production prefix, then three checks before any
binary touched `/usr/local`:

- **Flag-drift audit** — every flag in every unit file against the new `--help`: zero drift.
- **Embedding equivalence** — the silent-corruption check that matters most in a runtime swap:
  cosine ≥0.99944 against the April baseline vectors, on the staging binary.
- **Same-GGUF bench parity** — the new binary alone came out 5% *faster* (1.05× tg128).

Then the prize: Qwen3.8 ships a **Multi-Token Prediction draft head** (1.7 GB, same repo, same
pinned revision). Speculative decoding — a cheap head guesses tokens ahead, the main model
verifies, so outputs are draws from the same distribution, just faster:

```
llama-server -m Qwen3.8-27B-Q4_K_M.gguf \
  --spec-default --spec-type draft-mtp \
  --spec-draft-model mtp-Qwen3.8-27B-Q4_0.gguf -ctkd q8_0 ...
```

| | Staging (bench GPU) | Production (through the LiteLLM proxy) |
|---|---|---|
| Long-output decode, no MTP | 34.4 tok/s | ~32 tok/s |
| Long-output decode, MTP | **71.0 tok/s (2.06×)** | **61.6 tok/s (~1.9×)** |

Rolling restart (embeddings → drafter → architect), health gate green between each. VRAM with
the draft head: 20.8 GB of 24 — still under the watchdog's 22 GB warning line.

## Two corrections to previously published numbers

This repo's whole premise is receipts, so when the instrumentation turns out to be wrong, that's
a publishable result too:

1. **"0 errors, 0 fallbacks" (Layer 4, May window) — the fallbacks half is retired.** The JSONL
   telemetry logger read request metadata from the wrong key (`kwargs["metadata"]` instead of
   `kwargs["litellm_params"]["metadata"]` — where this LiteLLM version actually puts it), which
   made the `fallback_used` field structurally incapable of ever being `true`. Every historical
   "0 fallbacks" figure was instrumentation, not evidence. Fixed 2026-08-18; the field is
   trustworthy going forward, and the historical fallback count is honestly unknowable.
   The "0 errors" half came from `status` and stands.
2. **"Delegation calls" were over-counted as interactive offload.** ~90% of proxy traffic turned
   out to be scheduled automation jobs, not Claude Code delegation — the two were
   indistinguishable in the telemetry. The proxy's JSONL rows now carry a caller-supplied
   `source` tag so the split is exact instead of reconstructed from cron-timing heuristics.

Both fixes are the same lesson: **tag and verify at the source, or your dashboard is fiction.**

## Day-two correction: MTP shelved, context doubled instead

This repo's premise is receipts, so here is the next day's finding, unedited: **MTP's 2× win
holds only below ~3-4K prompt tokens.** Large-prompt validation — which the original gate set
lacked (`pp512` benches 512-token prompts; the golden set was all small-prompt/large-output) —
found speculative decoding *collapses at depth*: decode 12-17 tok/s and prefill 900→130 tok/s
on 30-47K-token prompts. Measured crossover:

| Prompt size | MTP decode | no-MTP decode |
|---|---|---|
| 550 tok | 44.5 tok/s | ~35 |
| 2.1K | 45.0 | ~35 |
| 3.7K | 35.5 (break-even) | ~35 |
| 5.8K | 26.4 | — |
| 30K | 17.3 | 31.5 |
| 47K | 12.3 | ~29 |

The regression ran in production for one day before a validation pass caught it. The fix chosen:
**drop MTP, double the context window to 64K** — hybrid attention makes deep KV cheap (+1.3 GB
for +32K tokens; total VRAM actually *fell* 1.3 GB with the draft head gone), and the
documented 39K/47K-token hard-failure class now serves in ~30-54 seconds. For a delegation
stack, servable-large-prompts beats faster-short-outputs. MTP's draft heads stay on disk,
pinned; it gets re-evaluated when llama.cpp's days-old support matures — this time with a
large-prompt gate in the harness.

Two lessons, both generalizable: **validate at the workload sizes you claim, not the sizes that
are easy to bench** — and a day-one benchmark is a hypothesis until a day-two workload confirms it.

## The bottom line

| | Before (Aug 17) | After (Aug 19) |
|---|---|---|
| Architect model | Qwen3.6-27B Q5 | Qwen3.8-27B Q4 |
| llama.cpp | Apr 25 build | b10502 (Aug 19) |
| Long-output decode | ~32–34 tok/s | **62–71 tok/s with MTP (short prompts only — see day-two correction)**; 31-37 tok/s in the final 64K config |
| Trivial-prompt completion | 2 tokens | 2 tokens (the number that mattered most, unchanged) |
| Injection regression | 15/15 | 15/15 |
| Max servable prompt | 32K tokens (hard error above) | **64K** — the real prize |
| Rollback | — | model: 1 line · MTP: 4 lines (exercised day two) · runtime: reinstall preserved old tree |

Local-first isn't just cheaper — it's *faster to adopt frontier open source*. Five days after
Qwen published the weights, they were serving production traffic on a two-GPU homelab at 2× the
previous throughput, gated by the same eval rigor a platform team would demand, with the whole
decision trail in version control.
