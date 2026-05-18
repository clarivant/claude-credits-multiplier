# scripts/lib/pricing.sh
# Anthropic API pricing constants — sourced by session-usage-summary.sh
# Source: https://www.anthropic.com/pricing → https://platform.claude.com/docs/en/about-claude/pricing
# Verified: 2026-04-28
#
# Note: Opus 4.x (current: claude-opus-4-7) is $5/$25 input/output per MTok as of 2026-04-28.
# The task-spec fallback values ($15/$75) reflect Claude Opus 4.1 / legacy Opus 3 rates.
# Current rates used here (sourced live from Anthropic pricing page).

# $ per 1M tokens
OPUS_INPUT_PER_M=5.00
OPUS_OUTPUT_PER_M=25.00
SONNET_INPUT_PER_M=3.00
SONNET_OUTPUT_PER_M=15.00
HAIKU_INPUT_PER_M=1.00
HAIKU_OUTPUT_PER_M=5.00

# Cache multipliers (apply to base input rate)
# 5-minute cache write: 1.25x base input price
# 1-hour cache write:   2.00x base input price
# Cache read (hit):     0.10x base input price
CACHE_WRITE_MULT=1.25
CACHE_READ_MULT=0.10

# Subscription plan context (used for the plan-equivalent footer in reports)
# Set these to match your actual plan; the script uses them ONLY for display,
# not for computing $-savings (which always use API-equivalent rates above).
CLAUDE_PLAN_NAME="Max 200"
CLAUDE_PLAN_MONTHLY_USD=200
# Anthropic doesn't publish exact weekly API-equivalent caps for Max plans.
# Leave commented unless you've calibrated against /usage data over a full week.
# CLAUDE_PLAN_WEEKLY_API_EQUIV_USD=10000

# Embed query methodology (refined 2026-04-28 after empirical audit)
# Calls below this token threshold are counted as queries (just embedded query strings,
# typically 5-50 tokens). Calls above are index-time operations on file content.
EMBED_QUERY_TOKEN_THRESHOLD=100
# Per-query Claude-equivalent: a SocratiCode query typically replaces ~3-5 Reads of
# source files (~1k-2k tokens each). 5000 is a conservative midpoint.
EMBED_QUERY_REPLACES_TOKENS=5000
