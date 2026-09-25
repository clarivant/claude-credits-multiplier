#!/usr/bin/env bash
# cost-per-day.sh — daily Claude Code API spend with model-aware pricing + cache hit ratio.
#
# Walks ~/.claude/projects/**/*.jsonl (main AND subagent transcripts), keeps ONE record per
# assistant message (dedupe by message.id + requestId), prices input/output/cache-read plus the
# 5m (1.25x) vs 1h (2.00x) cache-write tiers, groups by day. Reader: scripts/lib/transcripts.py
# (why: see the README's "Counting method" section).
#
# DAYS ARE UTC (message timestamp[:10], same as the pre-09-19 scripts) — by design, so weekly
# baselines stay comparable. Only --check-ccusage buckets by LOCAL day, because ccusage does.
# Days that contain only `<synthetic>` error/interrupt rows (weekly-limit lockout) are printed as
# "(no billable turns; N synthetic/error rows)" instead of vanishing.
#
# Pricing constants live in scripts/lib/pricing.sh (single source of truth — same as
# session-usage-summary.sh and close-session-reconciliation.sh).
#
# Usage:
#   cost-per-day.sh                                # last 7 days
#   cost-per-day.sh --since 2026-04-25             # from a specific date
#   cost-per-day.sh --since 2026-04-25 --until 2026-05-04
#   cost-per-day.sh --project myproj                 # filter by cwd basename
#   cost-per-day.sh --check-ccusage                # compare cache-read tokens with `ccusage daily`
#   cost-per-day.sh --legacy                       # pre-2026-09-19 method (line-sum, no subagents,
#                                                  #   flat 1.25x writes) — for comparing to old baselines
#   cost-per-day.sh --main-only                    # exclude subagent transcripts (keeps dedupe + 1h tier)
#   cost-per-day.sh --no-mtime-filter              # also scan files whose mtime predates the window
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; source "$_SCRIPT_DIR/lib/pricing.sh"; set +a

SINCE=$(date -d '7 days ago' +%Y-%m-%d)
UNTIL=$(date +%Y-%m-%d)
PROJECT_FILTER=""
CHECK_CCUSAGE=0
LEGACY=0
MAIN_ONLY=0
MTIME_FILTER=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE="$2"; shift 2;;
        --until) UNTIL="$2"; shift 2;;
        --project) PROJECT_FILTER="$2"; shift 2;;
        --check-ccusage) CHECK_CCUSAGE=1; shift;;
        --legacy) LEGACY=1; shift;;
        --main-only) MAIN_ONLY=1; shift;;
        --no-mtime-filter) MTIME_FILTER=0; shift;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
    esac
done

PROJECTS_DIR="$HOME/.claude/projects"
[[ -d "$PROJECTS_DIR" ]] || { echo "No Claude Code projects dir at $PROJECTS_DIR"; exit 0; }

CCUSAGE_JSON=""
if [[ "$CHECK_CCUSAGE" == 1 ]] && command -v ccusage >/dev/null 2>&1; then
    # ccusage groups by LOCAL day; the cross-check below therefore re-buckets our data by local day
    CCUSAGE_JSON=$(ccusage daily --since "${SINCE//-/}" --until "${UNTIL//-/}" --offline --json 2>/dev/null || true)
fi

CCUSAGE_JSON="$CCUSAGE_JSON" python3 - "$_SCRIPT_DIR/lib" "$PROJECTS_DIR" "$SINCE" "$UNTIL" "$PROJECT_FILTER" \
    "$LEGACY" "$MAIN_ONLY" "$CHECK_CCUSAGE" "$MTIME_FILTER" <<'PYEOF'
import json, os, sys
from collections import defaultdict

sys.path.insert(0, sys.argv[1])
import transcripts as tx

projects_dir, since, until, proj_filter = sys.argv[2:6]
legacy, main_only, check_ccusage, mtime_filter = (sys.argv[6] == '1', sys.argv[7] == '1',
                                                  sys.argv[8] == '1', sys.argv[9] == '1')
R = tx.rates()

stats = {}
msgs = tx.iter_messages(projects_dir, since, until, proj_filter,
                        include_subagents=not main_only, legacy=legacy,
                        mtime_filter=mtime_filter, stats=stats)
synth = stats['synthetic_by_day']
if not msgs and not synth:
    print(f"No transcripts in window {since} → {until}")
    sys.exit(0)

# day -> tier -> metrics ; plus subagent / headless-SDK cost per day
daily = defaultdict(lambda: defaultdict(lambda: {'turns': 0, 'input': 0, 'cache_create': 0,
                                                 'cache_read': 0, 'output': 0, 'cost': 0.0}))
sub_cost = defaultdict(float)
sdk_cost = defaultdict(float)
for m in msgs:
    b = daily[m.day][tx.classify(m.model)]
    c = tx.cost(m, R)
    b['turns'] += 1
    b['input'] += m.input
    b['cache_create'] += m.cc_5m + m.cc_1h
    b['cache_read'] += m.cache_read
    b['output'] += m.output
    b['cost'] += c
    if m.is_sub:
        sub_cost[m.day] += c
    if m.entrypoint.startswith('sdk'):
        sdk_cost[m.day] += c

method = ("LEGACY (line-sum, main transcripts only, flat 1.25x cache writes)" if legacy else
          "dedup by message id, " + ("main transcripts only" if main_only else "main + subagent transcripts")
          + ", 5m/1h cache-write tiers")
print(f"=== Claude Code daily cost ({since} → {until}, project={proj_filter or 'all'}) ===")
print(f"    method: {method}")
print()
print(f"  {'Date':<12} {'turns':>6} {'cache-hit%':>11} {'premium$':>9} {'sonnet$':>9} {'haiku$':>8} {'TOTAL$':>9} {'sub$':>8}")

grand_turns = 0
grand_input = grand_cache_create = grand_cache_read = 0
grand_cost = {t: 0.0 for t in tx.TIERS}
grand_turns_by_tier = {t: 0 for t in tx.TIERS}

for day in sorted(set(daily.keys()) | set(synth.keys())):
    if day not in daily:
        # lockout / error-only day: nothing billable, but keep the day visible (review MED-4)
        print(f"  {day:<12} {0:>6} {'-':>11} {'-':>9} {'-':>9} {'-':>8} {'-':>9} {'-':>8}"
              f"   (no billable turns; {synth[day]} synthetic/error rows)")
        continue
    tiers = daily[day]
    day_turns = sum(t['turns'] for t in tiers.values())
    day_input = sum(t['input'] for t in tiers.values())
    day_cc = sum(t['cache_create'] for t in tiers.values())
    day_cr = sum(t['cache_read'] for t in tiers.values())
    total_input_tokens = day_input + day_cc + day_cr
    cache_hit = (day_cr / total_input_tokens * 100) if total_input_tokens else 0
    # premium column = opus + fable (fable priced at its own $10/$50 rates)
    prem_d = tiers.get('opus', {}).get('cost', 0) + tiers.get('fable', {}).get('cost', 0)
    sonnet_d = tiers.get('sonnet', {}).get('cost', 0) + tiers.get('other', {}).get('cost', 0)
    haiku_d = tiers.get('haiku', {}).get('cost', 0)
    total = prem_d + sonnet_d + haiku_d
    print(f"  {day:<12} {day_turns:>6} {cache_hit:>10.1f}% ${prem_d:>8.2f} ${sonnet_d:>8.2f} ${haiku_d:>7.2f} ${total:>8.2f} ${sub_cost[day]:>7.2f}")
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
prem_total = grand_cost['opus'] + grand_cost['fable']

print()
print(f"  {'TOTAL':<12} {grand_turns:>6} {grand_cache_hit:>10.1f}% ${prem_total:>8.2f} ${grand_cost['sonnet'] + grand_cost['other']:>8.2f} ${grand_cost['haiku']:>7.2f} ${grand_total_cost:>8.2f} ${sum(sub_cost.values()):>7.2f}")
print()
print(f"Premium (opus+fable) share of cost: {prem_total / grand_total_cost * 100 if grand_total_cost else 0:.1f}%"
      f"   |   subagents: ${sum(sub_cost.values()):,.2f}   |   headless SDK sessions (no user hooks): ${sum(sdk_cost.values()):,.2f}")
if synth:
    print(f"Synthetic/error rows (zero-cost, not counted as turns): {sum(synth.values())} on {len(synth)} day(s)")
print()
print("Tokens (window total):")
print(f"  input (non-cached):   {grand_input:>14,}")
print(f"  cache_creation:       {grand_cache_create:>14,}")
print(f"  cache_read:           {grand_cache_read:>14,}")
print(f"  total input-side:     {grand_total_input:>14,}")
print(f"  cache hit ratio:      {grand_cache_hit:>13.1f}%")
print()
print("Turns by model tier:")
total_turns = sum(grand_turns_by_tier.values())
for tier in tx.TIERS:
    n = grand_turns_by_tier[tier]
    pct = (n / total_turns * 100) if total_turns else 0
    print(f"  {tier:<10} {n:>6} ({pct:>5.1f}%)")
print()
son_in = R['tier']['sonnet'][0]
print(f"Counterfactual (no cache): ${grand_total_input * son_in / 1e6:>8.2f}  (assumes Sonnet input rate; rough upper bound)")
print(f"Cache savings vs no-cache: ${(grand_cache_read * son_in - grand_cache_read * son_in * R['read']) / 1e6:>8.2f}  (cache_read at {R['read']}x vs full input)")

notes = []
if stats['files_skipped_mtime']:
    notes.append(f"{stats['files_skipped_mtime']} of {stats['files_scanned'] + stats['files_skipped_mtime']} "
                 f"files skipped by the mtime prefilter (mtime < window start - 1d; assumes trustworthy "
                 f"mtimes — re-run with --no-mtime-filter after a restore/rsync)")
if stats['messages'] and stats['unknown_entrypoint'] / stats['messages'] > 0.01:
    notes.append(f"{stats['unknown_entrypoint']} of {stats['messages']} messages have no `entrypoint` "
                 f"field (>1%: the 'headless SDK sessions' figure may be understated — field renamed?)")
if notes:
    print()
    for n in notes:
        print(f"note: {n}")

if check_ccusage:
    print()
    raw = os.environ.get('CCUSAGE_JSON', '')
    try:
        rows = (json.loads(raw).get('daily') if raw else None) or []
        cc_cr = sum(r.get('cacheReadTokens', 0) for r in rows)
        if not cc_cr:
            raise ValueError('no cacheReadTokens in ccusage output')
        # ccusage buckets by LOCAL day and covers all projects + subagents, so compare like with like:
        # our deduped data, re-bucketed by local day (tz='local'), no project filter. On UTC buckets a
        # 5-day window read +7.3% purely from edge-day skew; on local buckets it matches to 0.00%.
        lm = tx.iter_messages(projects_dir, since, until, '', include_subagents=True,
                              tz='local', mtime_filter=mtime_filter)
        ours = sum(m.cache_read for m in lm)
        delta = (ours - cc_cr) / cc_cr * 100
        flag = 'OK' if abs(delta) <= 3 else 'CHECK (>3%: transcripts pruned/missing, or ccusage version drift)'
        scope = ' [note: --project ignored for this check]' if proj_filter else ''
        print(f"ccusage cross-check (cache_read tokens, local-day buckets, all projects incl. subagents; "
              f"{len(rows)} ccusage days): ours {ours:,} vs ccusage {cc_cr:,} → {delta:+.1f}%  [{flag}]{scope}")
    except Exception as e:
        print(f"ccusage cross-check unavailable: {e}")
PYEOF
