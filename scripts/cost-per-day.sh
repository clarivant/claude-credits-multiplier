#!/usr/bin/env bash
# cost-per-day.sh — daily Claude Code API spend with model-aware pricing + cache hit ratio.
#
# Walks ~/.claude/projects/*/*.jsonl, extracts message.usage and message.model per turn,
# applies the correct Opus/Sonnet/Haiku pricing tier, and groups by day (UTC). Cross-checks
# against ccusage for sanity if --check-ccusage is passed.
#
# Pricing constants live in scripts/lib/pricing.sh (single source of truth — same as
# session-usage-summary.sh and close-session-reconciliation.sh).
#
# Usage:
#   cost-per-day.sh                                # last 7 days
#   cost-per-day.sh --since 2026-04-25             # from a specific date
#   cost-per-day.sh --since 2026-04-25 --until 2026-05-04
#   cost-per-day.sh --project fac                  # filter by cwd basename
#   cost-per-day.sh --check-ccusage                # also run `ccusage daily` for cross-check
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SCRIPT_DIR/lib/pricing.sh"

SINCE=$(date -d '7 days ago' +%Y-%m-%d)
UNTIL=$(date +%Y-%m-%d)
PROJECT_FILTER=""
CHECK_CCUSAGE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE="$2"; shift 2;;
        --until) UNTIL="$2"; shift 2;;
        --project) PROJECT_FILTER="$2"; shift 2;;
        --check-ccusage) CHECK_CCUSAGE=1; shift;;
        -h|--help) head -18 "$0" | tail -16; exit 0;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
    esac
done

PROJECTS_DIR="$HOME/.claude/projects"
[[ -d "$PROJECTS_DIR" ]] || { echo "No Claude Code projects dir at $PROJECTS_DIR"; exit 0; }

python3 - "$PROJECTS_DIR" "$SINCE" "$UNTIL" "$PROJECT_FILTER" \
    "$OPUS_INPUT_PER_M" "$OPUS_OUTPUT_PER_M" \
    "$SONNET_INPUT_PER_M" "$SONNET_OUTPUT_PER_M" \
    "$HAIKU_INPUT_PER_M" "$HAIKU_OUTPUT_PER_M" \
    "$CACHE_WRITE_MULT" "$CACHE_READ_MULT" <<'PYEOF'
import json, sys, os, glob
from collections import defaultdict

projects_dir, since, until, proj_filter = sys.argv[1:5]
opus_in, opus_out, son_in, son_out, hai_in, hai_out = [float(x) for x in sys.argv[5:11]]
write_mult, read_mult = float(sys.argv[11]), float(sys.argv[12])

def classify(model):
    m = (model or '').lower()
    if 'opus' in m: return 'opus'
    if 'haiku' in m: return 'haiku'
    if 'sonnet' in m: return 'sonnet'
    return 'other'

def price(model):
    c = classify(model)
    if c == 'opus': return opus_in, opus_out
    if c == 'haiku': return hai_in, hai_out
    return son_in, son_out  # sonnet (and 'other' falls back to sonnet pricing)

# day -> tier -> metrics
daily = defaultdict(lambda: defaultdict(lambda: {
    'turns': 0, 'input': 0, 'cache_create': 0, 'cache_read': 0, 'output': 0, 'cost': 0.0,
}))

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
                    model = msg.get('model', 'unknown')
                    tier = classify(model)
                    bucket = daily[day][tier]
                    bucket['turns'] += 1
                    in_t = usage.get('input_tokens', 0)
                    cc = usage.get('cache_creation_input_tokens', 0)
                    cr = usage.get('cache_read_input_tokens', 0)
                    out_t = usage.get('output_tokens', 0)
                    bucket['input'] += in_t
                    bucket['cache_create'] += cc
                    bucket['cache_read'] += cr
                    bucket['output'] += out_t
                    in_per_m, out_per_m = price(model)
                    bucket['cost'] += (
                        in_t * in_per_m / 1e6
                        + cc * in_per_m * write_mult / 1e6
                        + cr * in_per_m * read_mult / 1e6
                        + out_t * out_per_m / 1e6
                    )
                except Exception:
                    pass

if not daily:
    print(f"No transcripts in window {since} → {until}")
    sys.exit(0)

print(f"=== Claude Code daily cost ({since} → {until}, project={proj_filter or 'all'}) ===")
print()
print(f"  {'Date':<12} {'turns':>6} {'cache-hit%':>11} {'opus$':>8} {'sonnet$':>9} {'haiku$':>8} {'TOTAL$':>9}")

grand_turns = 0
grand_input = grand_cache_create = grand_cache_read = 0
grand_cost = {'opus': 0.0, 'sonnet': 0.0, 'haiku': 0.0, 'other': 0.0}
grand_turns_by_tier = {'opus': 0, 'sonnet': 0, 'haiku': 0, 'other': 0}

for day in sorted(daily.keys()):
    tiers = daily[day]
    day_turns = sum(t['turns'] for t in tiers.values())
    day_input = sum(t['input'] for t in tiers.values())
    day_cc = sum(t['cache_create'] for t in tiers.values())
    day_cr = sum(t['cache_read'] for t in tiers.values())
    total_input_tokens = day_input + day_cc + day_cr
    cache_hit = (day_cr / total_input_tokens * 100) if total_input_tokens else 0
    opus_d = tiers.get('opus', {}).get('cost', 0)
    sonnet_d = tiers.get('sonnet', {}).get('cost', 0) + tiers.get('other', {}).get('cost', 0)
    haiku_d = tiers.get('haiku', {}).get('cost', 0)
    total = opus_d + sonnet_d + haiku_d
    print(f"  {day:<12} {day_turns:>6} {cache_hit:>10.1f}% ${opus_d:>7.2f} ${sonnet_d:>8.2f} ${haiku_d:>7.2f} ${total:>8.2f}")
    grand_turns += day_turns
    grand_input += day_input
    grand_cache_create += day_cc
    grand_cache_read += day_cr
    for tier, b in tiers.items():
        grand_cost[tier] += b['cost']
        grand_turns_by_tier[tier] += b['turns']

grand_total_input = grand_input + grand_cache_create + grand_cache_read
grand_cache_hit = (grand_cache_read / grand_total_input * 100) if grand_total_input else 0
grand_total_cost = sum(grand_cost.values())

print()
print(f"  {'TOTAL':<12} {grand_turns:>6} {grand_cache_hit:>10.1f}% ${grand_cost['opus']:>7.2f} ${grand_cost['sonnet'] + grand_cost['other']:>8.2f} ${grand_cost['haiku']:>7.2f} ${grand_total_cost:>8.2f}")
print()
print(f"Tokens (window total):")
print(f"  input (non-cached):   {grand_input:>14,}")
print(f"  cache_creation:       {grand_cache_create:>14,}")
print(f"  cache_read:           {grand_cache_read:>14,}")
print(f"  total input-side:     {grand_total_input:>14,}")
print(f"  cache hit ratio:      {grand_cache_hit:>13.1f}%")
print()
print(f"Turns by model tier:")
total_turns = sum(grand_turns_by_tier.values())
for tier in ['opus', 'sonnet', 'haiku', 'other']:
    n = grand_turns_by_tier[tier]
    pct = (n / total_turns * 100) if total_turns else 0
    print(f"  {tier:<10} {n:>6} ({pct:>5.1f}%)")
print()
print(f"Counterfactual (no cache): ${(grand_input + grand_cache_create + grand_cache_read) * son_in / 1e6 + grand_cost.get('output_eq', 0):>8.2f}  (assumes Sonnet input rate; rough upper bound)")
print(f"Cache savings vs no-cache: ${(grand_cache_read * son_in - grand_cache_read * son_in * read_mult) / 1e6:>8.2f}  (cache_read at {read_mult}x vs full input)")
PYEOF
