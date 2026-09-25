#!/usr/bin/env bash
# opusplan-validation.sh — per-day Opus vs Sonnet vs Haiku turn split.
#
# Validates that ANTHROPIC_MODEL=opusplan is actually keeping the bulk of turns
# on Sonnet (with Opus reserved for plan mode). Walks ~/.claude/projects/**/*.jsonl
# (main AND subagent transcripts, one record per assistant message — see
# scripts/lib/transcripts.py), groups by day, splits by model tier.
#
# Memory predicts: opusplan should drop Opus % from 88% to 15-25% (post-2026-05-02).
#
# VERDICT BASIS: opusplan governs the MAIN thread's model only; subagents take their model from
# their agent definition / caller override. The verdict therefore uses MAIN-THREAD (non-subagent)
# turns on days >= the activation date. The daily table and window totals include subagents
# (unless --main-only) and the verdict line prints the subagent-inclusive share alongside for
# reference. (Same window measured 2026-09-19: main-thread 94.2% vs 57.4% incl. subagents.)
# Days are UTC (message timestamp[:10]) — by design, same as cost-per-day.sh. Days holding only
# `<synthetic>` error/interrupt rows (weekly-limit lockout) are listed, not dropped.
#
# Usage:
#   opusplan-validation.sh                        # last 14 days
#   opusplan-validation.sh --since 2026-04-25     # custom window
#   opusplan-validation.sh --project myproj
#   opusplan-validation.sh --legacy               # pre-2026-09-19 method (line-sum, no subagents)
#   opusplan-validation.sh --main-only            # exclude subagent transcripts
#   opusplan-validation.sh --no-mtime-filter      # also scan files whose mtime predates the window
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; source "$_SCRIPT_DIR/lib/pricing.sh"; set +a

SINCE=$(date -d '14 days ago' +%Y-%m-%d)
UNTIL=$(date +%Y-%m-%d)
PROJECT_FILTER=""
LEGACY=0
MAIN_ONLY=0
MTIME_FILTER=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE="$2"; shift 2;;
        --until) UNTIL="$2"; shift 2;;
        --project) PROJECT_FILTER="$2"; shift 2;;
        --legacy) LEGACY=1; shift;;
        --main-only) MAIN_ONLY=1; shift;;
        --no-mtime-filter) MTIME_FILTER=0; shift;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
    esac
done

PROJECTS_DIR="$HOME/.claude/projects"
[[ -d "$PROJECTS_DIR" ]] || { echo "No Claude Code projects dir at $PROJECTS_DIR"; exit 0; }

python3 - "$_SCRIPT_DIR/lib" "$PROJECTS_DIR" "$SINCE" "$UNTIL" "$PROJECT_FILTER" "$LEGACY" "$MAIN_ONLY" "$MTIME_FILTER" <<'PYEOF'
import sys
from collections import defaultdict

sys.path.insert(0, sys.argv[1])
import transcripts as tx

projects_dir, since, until, proj_filter = sys.argv[2:6]
legacy, main_only, mtime_filter = sys.argv[6] == '1', sys.argv[7] == '1', sys.argv[8] == '1'
R = tx.rates()

stats = {}
msgs = tx.iter_messages(projects_dir, since, until, proj_filter,
                        include_subagents=not main_only, legacy=legacy,
                        mtime_filter=mtime_filter, stats=stats)
synth = stats['synthetic_by_day']

# day -> tier -> {turns, output_tokens, cost}
daily = defaultdict(lambda: defaultdict(lambda: {'turns': 0, 'output': 0, 'cost': 0.0}))
# day -> tier -> turns, MAIN THREAD only (verdict basis; legacy has no subagents so main == all)
main_daily = defaultdict(lambda: defaultdict(int))
for m in msgs:
    b = daily[m.day][tx.classify(m.model)]
    b['turns'] += 1
    b['output'] += m.output
    b['cost'] += tx.cost(m, R)
    if not m.is_sub:
        main_daily[m.day][tx.classify(m.model)] += 1

if not daily and not synth:
    print(f"No transcripts in window {since} → {until}")
    sys.exit(0)

method = ("LEGACY (line-sum, main transcripts only)" if legacy else
          "dedup by message id, " + ("main transcripts only" if main_only else "main + subagent transcripts"))
print(f"=== Opusplan validation ({since} → {until}, project={proj_filter or 'all'}) ===")
print(f"    method: {method}   (opus% = premium tier: opus + fable)")
print()
print(f"  {'Date':<12} {'opus%':>7} {'sonnet%':>9} {'haiku%':>8} {'opus-turns':>12} {'sonnet-turns':>14} {'opus-out':>11} {'sonnet-out':>12}")

cumulative = defaultdict(lambda: {'turns': 0, 'output': 0, 'cost': 0.0})

for day in sorted(set(daily.keys()) | set(synth.keys())):
    if day not in daily:
        print(f"  {day:<12} {'-':>7} {'-':>9} {'-':>8} {0:>12} {0:>14} {'-':>11} {'-':>12}"
              f"   (no billable turns; {synth[day]} synthetic/error rows)")
        continue
    tiers = daily[day]
    total = sum(t['turns'] for t in tiers.values())
    if total == 0: continue
    # opus% column = premium tier: opus + fable (2026-08-19 — fable previously fell into
    # 'other' and was counted as SONNET here, understating the premium share)
    opus_n = tiers.get('opus', {}).get('turns', 0) + tiers.get('fable', {}).get('turns', 0)
    son_n  = tiers.get('sonnet', {}).get('turns', 0) + tiers.get('other', {}).get('turns', 0)
    hai_n  = tiers.get('haiku', {}).get('turns', 0)
    opus_pct = opus_n / total * 100
    son_pct  = son_n / total * 100
    hai_pct  = hai_n / total * 100
    opus_out = tiers.get('opus', {}).get('output', 0) + tiers.get('fable', {}).get('output', 0)
    son_out  = tiers.get('sonnet', {}).get('output', 0) + tiers.get('other', {}).get('output', 0)
    print(f"  {day:<12} {opus_pct:>6.1f}% {son_pct:>8.1f}% {hai_pct:>7.1f}% {opus_n:>12} {son_n:>14} {opus_out:>11,} {son_out:>12,}")
    for tier, b in tiers.items():
        cumulative[tier]['turns'] += b['turns']
        cumulative[tier]['output'] += b['output']
        cumulative[tier]['cost'] += b['cost']

total_turns = sum(c['turns'] for c in cumulative.values())
total_output = sum(c['output'] for c in cumulative.values())
total_cost = sum(c['cost'] for c in cumulative.values())

print()
print("=== Window totals ===")
print(f"  Total turns:    {total_turns:>10,}")
print(f"  Total output:   {total_output:>10,}")
print()
for tier in tx.TIERS:
    n = cumulative[tier]['turns']
    o = cumulative[tier]['output']
    pct_t = (n / total_turns * 100) if total_turns else 0
    pct_o = (o / total_output * 100) if total_output else 0
    print(f"  {tier:<10} {n:>6,} turns ({pct_t:>5.1f}%)  |  {o:>10,} output tokens ({pct_o:>5.1f}%)")
prem_cost = cumulative['opus']['cost'] + cumulative['fable']['cost']
print(f"\n  Premium (opus+fable) share of COST: {prem_cost / total_cost * 100 if total_cost else 0:.1f}%  (the verdict below uses MAIN-THREAD turn share, not this cost share)")

# Verdict: MAIN-THREAD turns only, and only days on or after opusplan activation (2026-05-02).
# opusplan selects the main thread's model; subagent models come from agent definitions, so mixing
# them in answers a different question (review HIGH-2: same window, 94.2% main vs 57.4% blended).
# Pre-activation days are all-Opus by design and are excluded.
OPUSPLAN_ACTIVATION = '2026-05-02'

def _prem_share(day_map):
    prem = sum(t.get('opus', 0) + t.get('fable', 0) for t in day_map.values())
    tot = sum(sum(t.values()) for t in day_map.values())
    return prem, tot

post_main = {d: t for d, t in main_daily.items() if d >= OPUSPLAN_ACTIVATION}
post_all = {d: {k: v['turns'] for k, v in t.items()} for d, t in daily.items() if d >= OPUSPLAN_ACTIVATION}
m_prem, m_tot = _prem_share(post_main)
a_prem, a_tot = _prem_share(post_all)

print()
if m_tot == 0:
    print(f"Verdict: none — no main-thread turns on/after opusplan activation ({OPUSPLAN_ACTIVATION}) in this window")
else:
    pct = m_prem / m_tot * 100
    basis = f"main thread only, {m_tot:,} turns, days >= {OPUSPLAN_ACTIVATION}"
    if pct < 30:
        verdict = f"opusplan working as designed — Opus at {pct:.1f}% [{basis}] (target: 15-25%)"
    elif pct < 50:
        verdict = f"opusplan partial — Opus at {pct:.1f}% [{basis}] (some plan-mode overuse)"
    else:
        verdict = f"opusplan NOT effective — Opus at {pct:.1f}% [{basis}] (check ANTHROPIC_MODEL env var, plan-mode habits)"
    print(f"Verdict: {verdict}")
    if not main_only and not legacy and a_tot and a_tot != m_tot:
        print(f"         (reference only — incl. subagents: {a_prem / a_tot * 100:.1f}% of {a_tot:,} turns; "
              f"subagent models are set by agent definitions, not opusplan)")

if stats['files_skipped_mtime']:
    print(f"note: {stats['files_skipped_mtime']} of {stats['files_scanned'] + stats['files_skipped_mtime']} files "
          f"skipped by the mtime prefilter (mtime < window start - 1d; assumes trustworthy mtimes — "
          f"re-run with --no-mtime-filter after a restore/rsync)")
PYEOF
