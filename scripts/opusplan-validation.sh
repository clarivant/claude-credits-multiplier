#!/usr/bin/env bash
# opusplan-validation.sh — per-day Opus vs Sonnet vs Haiku turn split.
#
# Validates that ANTHROPIC_MODEL=opusplan is actually keeping the bulk of turns
# on Sonnet (with Opus reserved for plan mode). Walks ~/.claude/projects/*/*.jsonl,
# groups by day, splits by model tier.
#
# Memory predicts: opusplan should drop Opus % from 88% to 15-25% (post-2026-05-02).
#
# Usage:
#   opusplan-validation.sh                        # last 14 days
#   opusplan-validation.sh --since 2026-04-25     # custom window
#   opusplan-validation.sh --project fac
set -euo pipefail

SINCE=$(date -d '14 days ago' +%Y-%m-%d)
UNTIL=$(date +%Y-%m-%d)
PROJECT_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE="$2"; shift 2;;
        --until) UNTIL="$2"; shift 2;;
        --project) PROJECT_FILTER="$2"; shift 2;;
        -h|--help) head -16 "$0" | tail -14; exit 0;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
    esac
done

PROJECTS_DIR="$HOME/.claude/projects"
[[ -d "$PROJECTS_DIR" ]] || { echo "No Claude Code projects dir at $PROJECTS_DIR"; exit 0; }

python3 - "$PROJECTS_DIR" "$SINCE" "$UNTIL" "$PROJECT_FILTER" <<'PYEOF'
import json, sys, os, glob
from collections import defaultdict

projects_dir, since, until, proj_filter = sys.argv[1:5]

def classify(model):
    m = (model or '').lower()
    if 'opus' in m: return 'opus'
    if 'haiku' in m: return 'haiku'
    if 'sonnet' in m: return 'sonnet'
    return 'other'

# day -> tier -> {turns, output_tokens}
daily = defaultdict(lambda: defaultdict(lambda: {'turns': 0, 'output': 0}))

for proj_path in glob.glob(os.path.join(projects_dir, '*')):
    if not os.path.isdir(proj_path): continue
    proj_name = os.path.basename(proj_path)
    if proj_filter and proj_filter not in proj_name:
        continue
    for jsonl in glob.glob(os.path.join(proj_path, '*.jsonl')):
        with open(jsonl) as f:
            for line in f:
                try:
                    d = json.loads(line)
                    ts = d.get('timestamp')
                    if not ts: continue
                    day = ts[:10]
                    if day < since or day > until: continue
                    msg = d.get('message') or {}
                    usage = msg.get('usage') or {}
                    if not usage: continue
                    tier = classify(msg.get('model', ''))
                    daily[day][tier]['turns'] += 1
                    daily[day][tier]['output'] += usage.get('output_tokens', 0)
                except Exception:
                    pass

if not daily:
    print(f"No transcripts in window {since} → {until}")
    sys.exit(0)

print(f"=== Opusplan validation ({since} → {until}, project={proj_filter or 'all'}) ===")
print()
print(f"  {'Date':<12} {'opus%':>7} {'sonnet%':>9} {'haiku%':>8} {'opus-turns':>12} {'sonnet-turns':>14} {'opus-out':>11} {'sonnet-out':>12}")

cumulative = defaultdict(lambda: {'turns': 0, 'output': 0})

for day in sorted(daily.keys()):
    tiers = daily[day]
    total = sum(t['turns'] for t in tiers.values())
    if total == 0: continue
    opus_n = tiers.get('opus', {}).get('turns', 0)
    son_n  = tiers.get('sonnet', {}).get('turns', 0) + tiers.get('other', {}).get('turns', 0)
    hai_n  = tiers.get('haiku', {}).get('turns', 0)
    opus_pct = opus_n / total * 100
    son_pct  = son_n / total * 100
    hai_pct  = hai_n / total * 100
    opus_out = tiers.get('opus', {}).get('output', 0)
    son_out  = tiers.get('sonnet', {}).get('output', 0) + tiers.get('other', {}).get('output', 0)
    print(f"  {day:<12} {opus_pct:>6.1f}% {son_pct:>8.1f}% {hai_pct:>7.1f}% {opus_n:>12} {son_n:>14} {opus_out:>11,} {son_out:>12,}")
    for tier, b in tiers.items():
        cumulative[tier]['turns'] += b['turns']
        cumulative[tier]['output'] += b['output']

total_turns = sum(c['turns'] for c in cumulative.values())
total_output = sum(c['output'] for c in cumulative.values())

print()
print(f"=== Window totals ===")
print(f"  Total turns:    {total_turns:>10,}")
print(f"  Total output:   {total_output:>10,}")
print()
for tier in ['opus', 'sonnet', 'haiku', 'other']:
    n = cumulative[tier]['turns']
    o = cumulative[tier]['output']
    pct_t = (n / total_turns * 100) if total_turns else 0
    pct_o = (o / total_output * 100) if total_output else 0
    print(f"  {tier:<10} {n:>6,} turns ({pct_t:>5.1f}%)  |  {o:>10,} output tokens ({pct_o:>5.1f}%)")

# Verdict: only count days on or after opusplan activation (2026-05-02).
# Pre-activation days are all-Opus by design — including them inflates the %
# and produces false-negative verdicts.
OPUSPLAN_ACTIVATION = '2026-05-02'
post = {d: tiers for d, tiers in daily.items() if d >= OPUSPLAN_ACTIVATION}
if post:
    post_opus   = sum(t.get('opus',   {}).get('turns', 0) for t in post.values())
    post_sonnet = sum(t.get('sonnet', {}).get('turns', 0) + t.get('other', {}).get('turns', 0) for t in post.values())
    post_total  = post_opus + post_sonnet + sum(t.get('haiku', {}).get('turns', 0) for t in post.values())
    opus_turn_pct = (post_opus / post_total * 100) if post_total else 0
    scope = f"post-activation ({OPUSPLAN_ACTIVATION}+)"
else:
    opus_turn_pct = (cumulative['opus']['turns'] / total_turns * 100) if total_turns else 0
    scope = "full window (no post-activation data)"

print()
if opus_turn_pct < 30:
    verdict = f"opusplan working as designed — Opus at {opus_turn_pct:.1f}% [{scope}] (target: 15-25%)"
elif opus_turn_pct < 50:
    verdict = f"opusplan partial — Opus at {opus_turn_pct:.1f}% [{scope}] (some plan-mode overuse)"
else:
    verdict = f"opusplan NOT effective — Opus at {opus_turn_pct:.1f}% [{scope}] (check ANTHROPIC_MODEL env var, plan-mode habits)"
print(f"Verdict: {verdict}")
PYEOF
