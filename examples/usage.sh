#!/usr/bin/env bash
# Minimal shell usage: drive claude-pty, get JSON envelope, slice it with jq.
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Uses whatever Claude config `claude` would use (default ~/.claude, or
# CLAUDE_CONFIG_DIR if you have it set). The claude-pty hooks must already be
# installed into that config; see install.sh.
envelope=$("$REPO_DIR/bin/claude-pty" --model haiku "Reply with only the word PONG.")

# Pull anything you need; here are the interesting fields.
echo "$envelope" | jq '{
  result:       .result,
  cost_usd:     .total_cost_usd,
  duration_ms:  .duration_ms,
  context_pct:  .statusline.context_window.used_percentage,
  rate_5h:      .statusline.rate_limits.five_hour,
  rate_7d:      .statusline.rate_limits.seven_day
}'
