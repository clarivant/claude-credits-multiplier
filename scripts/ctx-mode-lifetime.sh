#!/usr/bin/env bash
# ctx-mode-lifetime.sh — aggregate Context Mode savings across ALL session stats files.
#
# Each Claude Code session that loads context-mode MCP writes a stats file at
# ~/.claude/context-mode/sessions/stats-pid-*.json. The lifetime fields in those
# files are zeros (they reset per PID), so this script sums session_start totals
# across files in a date range.
#
# Usage:
#   ctx-mode-lifetime.sh                          # all-time
#   ctx-mode-lifetime.sh --since 2026-05-04       # since a date (YYYY-MM-DD)
#   ctx-mode-lifetime.sh --since 2026-05-04 --until 2026-05-11
set -euo pipefail

SINCE_EPOCH=0
UNTIL_EPOCH=$(date +%s)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE_EPOCH=$(date -d "$2 00:00:00" +%s); shift 2;;
        --until) UNTIL_EPOCH=$(date -d "$2 23:59:59" +%s); shift 2;;
        -h|--help) head -16 "$0" | tail -14; exit 0;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
    esac
done

CTX_DIR="$HOME/.claude/context-mode/sessions"
[[ -d "$CTX_DIR" ]] || { echo "No Context Mode sessions dir at $CTX_DIR"; exit 0; }

python3 - "$CTX_DIR" "$SINCE_EPOCH" "$UNTIL_EPOCH" <<'PYEOF'
import json, os, sys, glob, datetime as dt
from collections import defaultdict
UTC = dt.timezone.utc

ctx_dir, since_epoch, until_epoch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

totals = {
    'sessions': 0, 'calls': 0, 'tokens_saved': 0, 'dollars_saved': 0.0,
    'kept_out': 0, 'bytes_returned': 0, 'bytes_indexed': 0, 'bytes_sandboxed': 0,
}
by_tool = defaultdict(lambda: {'calls': 0, 'bytes': 0})
per_day = defaultdict(lambda: {'sessions': 0, 'calls': 0, 'tokens_saved': 0, 'dollars_saved': 0.0})

for f in sorted(glob.glob(os.path.join(ctx_dir, 'stats-pid-*.json'))):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    sess_start_ms = d.get('session_start') or 0
    sess_start_sec = sess_start_ms // 1000
    if not (since_epoch <= sess_start_sec <= until_epoch):
        continue
    totals['sessions'] += 1
    totals['calls'] += d.get('total_calls', 0)
    totals['tokens_saved'] += d.get('tokens_saved', 0)
    totals['dollars_saved'] += d.get('dollars_saved_session', 0) or 0
    totals['kept_out'] += d.get('kept_out', 0)
    totals['bytes_returned'] += d.get('bytes_returned', 0)
    totals['bytes_indexed'] += d.get('bytes_indexed', 0)
    totals['bytes_sandboxed'] += d.get('bytes_sandboxed', 0)
    for tool, ts in (d.get('by_tool') or {}).items():
        by_tool[tool]['calls'] += ts.get('calls', 0)
        by_tool[tool]['bytes'] += ts.get('bytes', 0)
    # Per-day rollup
    day = dt.datetime.fromtimestamp(sess_start_sec, UTC).strftime('%Y-%m-%d')
    per_day[day]['sessions'] += 1
    per_day[day]['calls'] += d.get('total_calls', 0)
    per_day[day]['tokens_saved'] += d.get('tokens_saved', 0)
    per_day[day]['dollars_saved'] += d.get('dollars_saved_session', 0) or 0

if totals['sessions'] == 0:
    print(f"No Context Mode sessions in window {sys.argv[2]} → {sys.argv[3]}")
    sys.exit(0)

since_str = dt.datetime.fromtimestamp(since_epoch, UTC).strftime('%Y-%m-%d') if since_epoch > 0 else 'all-time'
until_str = dt.datetime.fromtimestamp(until_epoch, UTC).strftime('%Y-%m-%d')

print(f"=== Context Mode lifetime aggregation ({since_str} → {until_str}) ===")
print()
print(f"  Sessions:              {totals['sessions']}")
print(f"  Total ctx_* calls:     {totals['calls']}")
print(f"  Tokens saved:          {totals['tokens_saved']:,}")
print(f"  KB kept out of context: {totals['kept_out'] / 1024:.1f}")
print(f"  Bytes returned:        {totals['bytes_returned'] / 1024:.1f} KB")
print(f"  Bytes indexed:         {totals['bytes_indexed'] / 1024:.1f} KB")
print(f"  Bytes sandboxed:       {totals['bytes_sandboxed'] / 1024:.1f} KB")
print(f"  Dollars saved (Opus):  ${totals['dollars_saved']:.2f}")

if by_tool:
    print()
    print(f"By tool (sorted by calls):")
    for tool, ts in sorted(by_tool.items(), key=lambda kv: -kv[1]['calls']):
        print(f"  {tool:<28} {ts['calls']:>4} calls  {ts['bytes']/1024:>7.1f} KB")

if len(per_day) > 1:
    print()
    print(f"Per-day breakdown:")
    print(f"  {'Date':<12} {'sess':>5} {'calls':>6} {'tok-saved':>11} {'$ saved':>9}")
    for day in sorted(per_day.keys()):
        v = per_day[day]
        print(f"  {day:<12} {v['sessions']:>5} {v['calls']:>6} {v['tokens_saved']:>11,} ${v['dollars_saved']:>8.2f}")
PYEOF
