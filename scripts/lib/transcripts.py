"""Shared Claude Code transcript reader for the telemetry scripts.

Used by cost-per-day.sh and opusplan-validation.sh. Fixes three errors the
per-script loops had (found 2026-09-19, see README "Counting method"):

  1. DOUBLE COUNT. Claude Code writes ~2.05 transcript lines per assistant message (one per streamed
     content block), each carrying a `usage` block. Summing lines overstated cost/turns ~2x.
     Here: one record per (message.id, requestId); the copy with the most output_tokens wins
     (the final snapshot, not the message_start one).
  2. SUBAGENTS SKIPPED. The loops globbed `<project>/*.jsonl` only; Task/Workflow subagent transcripts
     live in `<project>/<session>/subagents/*.jsonl`. Now included (Msg.is_sub).
  3. CACHE-WRITE TIER. usage.cache_creation splits ephemeral_5m (1.25x input) from ephemeral_1h (2.00x).
     About half of all cache-write tokens are 1h (measured 2026-09-19: ~52% corpus-wide; Claude Code
     picks the tier per request); everything was priced at 1.25x.

`legacy=True` reproduces the old behaviour exactly (no dedupe, no subagents, flat 1.25x writes) so
numbers can still be compared against baselines built before 2026-09-19 (May W2 $283/day etc.).

Days are UTC (timestamp[:10]) like the original scripts by default; `tz="local"` buckets by the
box's LOCAL calendar day instead (message timestamp converted with astimezone()) — used only by
reports that must follow the local calendar day. cost-per-day.sh and
opusplan-validation.sh stay UTC by design (documented in their headers). Rates come from
scripts/lib/pricing.sh, exported into the environment by the calling script.

FILE SELECTION (explicit, not a tree walk). Main transcripts = `<project>/*.jsonl` (depth 1, exactly
the old glob). Subagent transcripts = `<project>/<session>/subagents/**/*.jsonl` (includes
`subagents/workflows/wf_*`). Any other nested .jsonl (tool-results/, memory/, ... — none exist today)
is deliberately IGNORED rather than guessed at, so `--legacy` cannot silently drift.

MTIME PREFILTER (assumption). Files whose mtime is older than `since - 1 day` are skipped without
being opened; that is sound only while mtimes are trustworthy (append-only files). After an
`rsync -a`/`cp -p` restore or a skewed-clock mount the report would silently shrink, so callers can
pass a `stats` dict to read `files_skipped_mtime`, and `mtime_filter=False` (CLI: --no-mtime-filter)
to scan everything.

`stats` (optional dict, filled in place): files_scanned, files_skipped_mtime, messages,
unknown_entrypoint (count of messages whose entrypoint field is missing -> '?'),
synthetic_by_day ({day: n} of `<synthetic>` zero-usage error/interrupt rows in the window; these
never enter the returned list or any cost, but callers print them so lockout days stay visible).
"""

import datetime as dt
import glob
import json
import os
from collections import namedtuple

Msg = namedtuple(
    "Msg", "day model project is_sub entrypoint input output cache_read cc_5m cc_1h"
)

TIERS = ("opus", "fable", "sonnet", "haiku", "other")


def classify(model):
    m = (model or "").lower()
    if "fable" in m or "mythos" in m:  # $10/$50 tier — checked first (2026-08-19 fix)
        return "fable"
    if "opus" in m:
        return "opus"
    if "haiku" in m:
        return "haiku"
    if "sonnet" in m:
        return "sonnet"
    return "other"


def _env(name, default):
    return float(os.environ.get(name, default))


def rates():
    """{tier: (in_per_M, out_per_M)}, plus write/read multipliers, from pricing.sh env vars."""
    son = (_env("SONNET_INPUT_PER_M", 3.0), _env("SONNET_OUTPUT_PER_M", 15.0))
    return {
        "tier": {
            "fable": (
                _env("FABLE_INPUT_PER_M", 10.0),
                _env("FABLE_OUTPUT_PER_M", 50.0),
            ),
            "opus": (_env("OPUS_INPUT_PER_M", 5.0), _env("OPUS_OUTPUT_PER_M", 25.0)),
            "haiku": (_env("HAIKU_INPUT_PER_M", 1.0), _env("HAIKU_OUTPUT_PER_M", 5.0)),
            "sonnet": son,
            "other": son,  # unknown models priced as Sonnet (same as before)
        },
        "w5m": _env("CACHE_WRITE_MULT", 1.25),
        "w1h": _env("CACHE_WRITE_1H_MULT", 2.00),
        "read": _env("CACHE_READ_MULT", 0.10),
    }


def cost(msg, r):
    i, o = r["tier"][classify(msg.model)]
    return (
        msg.input * i
        + msg.cc_5m * i * r["w5m"]
        + msg.cc_1h * i * r["w1h"]
        + msg.cache_read * i * r["read"]
        + msg.output * o
    ) / 1e6


def _files(projects_dir, proj_filter, include_subagents, min_mtime, stats):
    """Yield (path, project, is_sub). Explicit globs — see FILE SELECTION in the module docstring."""
    for proj_path in sorted(glob.glob(os.path.join(projects_dir, "*"))):
        if not os.path.isdir(proj_path):
            continue
        proj = os.path.basename(proj_path)
        if proj_filter and proj_filter not in proj:
            continue
        cands = [(p, False) for p in sorted(glob.glob(os.path.join(proj_path, "*.jsonl")))]
        if include_subagents:
            cands += [
                (p, True)
                for p in sorted(
                    glob.glob(
                        os.path.join(proj_path, "*", "subagents", "**", "*.jsonl"),
                        recursive=True,
                    )
                )
            ]
        for p, is_sub in cands:
            try:
                if os.path.getmtime(p) < min_mtime:
                    stats["files_skipped_mtime"] += 1
                    continue
            except OSError:
                continue
            stats["files_scanned"] += 1
            yield p, proj, is_sub


def _local_day(ts):
    """UTC ISO timestamp ('2026-09-17T03:12:45.123Z') -> box-local YYYY-MM-DD."""
    try:
        return (
            dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
            .astimezone()
            .strftime("%Y-%m-%d")
        )
    except ValueError:
        return ts[:10]


def iter_messages(
    projects_dir,
    since,
    until,
    proj_filter="",
    include_subagents=True,
    dedupe=True,
    legacy=False,
    tz="utc",
    mtime_filter=True,
    stats=None,
):
    """Return a list of Msg with since <= day <= until (YYYY-MM-DD; UTC unless tz="local")."""
    if legacy:
        dedupe, include_subagents, tz = False, False, "utc"
    if stats is None:
        stats = {}
    stats.update(
        files_scanned=0,
        files_skipped_mtime=0,
        messages=0,
        unknown_entrypoint=0,
        synthetic_by_day={},
    )
    synth_seen = set()
    day_of = _local_day if tz == "local" else (lambda ts: ts[:10])
    # files not touched since `since` (minus a day of slack for UTC/local skew) cannot hold newer lines
    min_mtime = (
        dt.datetime.strptime(since, "%Y-%m-%d")
        .replace(tzinfo=dt.timezone.utc)
        .timestamp()
        - 86400
        if mtime_filter
        else 0
    )
    out = []
    best = {}  # (message.id, requestId) -> Msg
    for path, proj, is_sub in _files(
        projects_dir, proj_filter, include_subagents, min_mtime, stats
    ):
        try:
            f = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with f:
            for line in f:
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                ts = d.get("timestamp")
                msg = d.get("message") or {}
                u = msg.get("usage") or {}
                if not ts or not u:
                    continue
                model = msg.get("model", "unknown")
                if model == "<synthetic>" and not legacy:
                    # zero-usage error/interrupt rows (weekly-limit lockout days consist of ONLY
                    # these). Not a billable turn: never returned, but counted per day in stats
                    # so callers can show the day instead of letting it vanish (review MED-4).
                    sk = (msg["id"], d.get("requestId") or "") if msg.get("id") else object()
                    if sk not in synth_seen:
                        synth_seen.add(sk)
                        sd = day_of(ts)
                        if since <= sd <= until:
                            bd = stats["synthetic_by_day"]
                            bd[sd] = bd.get(sd, 0) + 1
                    continue
                cc = u.get("cache_creation_input_tokens", 0) or 0
                split = u.get("cache_creation") or {}
                if legacy or not split:
                    cc_5m, cc_1h = cc, 0
                else:
                    cc_1h = split.get("ephemeral_1h_input_tokens", 0) or 0
                    cc_5m = split.get("ephemeral_5m_input_tokens", 0) or 0
                    if (
                        cc_5m + cc_1h != cc
                    ):  # inconsistent breakdown: trust the total, price as 5m
                        cc_5m, cc_1h = cc, 0
                m = Msg(
                    day_of(ts),
                    model,
                    proj,
                    is_sub,
                    d.get("entrypoint") or "?",
                    u.get("input_tokens", 0) or 0,
                    u.get("output_tokens", 0) or 0,
                    u.get("cache_read_input_tokens", 0) or 0,
                    cc_5m,
                    cc_1h,
                )
                if not dedupe:
                    out.append(m)
                    continue
                mid = msg.get("id")
                if not mid:
                    continue  # no id => cannot dedupe (synthetic/system rows)
                key = (mid, d.get("requestId") or "")
                prev = best.get(key)
                if prev is None or m.output >= prev.output:
                    best[key] = m
    if dedupe:
        out = list(best.values())
    out = [m for m in out if since <= m.day <= until]
    stats["messages"] = len(out)
    stats["unknown_entrypoint"] = sum(1 for m in out if m.entrypoint == "?")
    return out
