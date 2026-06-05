#!/usr/bin/env bash
#
# claude-pty statusline shim.
#
# This script REPLACES whatever was in your settings.json's `statusLine.command`
# field, but is engineered to be a transparent pass-through so your real
# statusline keeps working untouched.
#
# What it does, in order:
#
#   1. Reads the statusline JSON payload Claude Code piped on stdin.
#      (Same payload your old statusline received: model, cost, context, etc.)
#
#   2. If CLAUDE_PTY_SIDECAR is set in the environment (i.e. running under
#      `claude-pty`), atomically writes that JSON to the sidecar file.
#      The claude-pty Stop hook later reads the sidecar and merges its fields into
#      the final envelope on stdout.
#      When the env var is NOT set (a regular interactive session that just
#      happens to have these hooks installed), this step is skipped, with
#      zero side effects.
#
#   3. Hands the visible TUI rendering back to your original statusline by
#      pipe-feeding the same JSON to it. The shim resolves "your original"
#      in this order:
#        a. $CLAUDE_PTY_REAL_STATUSLINE if exported (explicit override)
#        b. the contents of <CFG_DIR>/.pty-prior-statusline (sidecar file
#           install.sh writes with the statusLine.command it replaced)
#        c. nothing — the script prints no statusline output, so Claude Code
#           shows a blank one. Safe default for users who never configured
#           a statusline in the first place.
#
# Wiring is handled by install.sh:
#   - statusLine.command in settings.json points at THIS script.
#   - install.sh saves whatever statusLine.command was there before into the
#     sidecar file above, so the shim picks it up with no shell rc edits.
#
set -euo pipefail

input=$(cat)

# Step 2: claude-pty sidecar write.
# Atomic via tmp-then-rename so a partial read from the Stop hook is impossible.
if [ -n "${CLAUDE_PTY_SIDECAR:-}" ]; then
  tmp="${CLAUDE_PTY_SIDECAR}.tmp.$$"
  printf '%s' "$input" > "$tmp"
  mv "$tmp" "$CLAUDE_PTY_SIDECAR"
  if [ -n "${CLAUDE_PTY_DEBUG_LOG:-}" ]; then
    # One jq call extracts both fields formatted; cheaper than two parses
    # of the same payload on a hot tick.
    fields=$(printf '%s' "$input" | jq -r '"cost=\(.cost.total_cost_usd // "?") pct=\(.context_window.used_percentage // "?")"' 2>/dev/null || echo "cost=? pct=?")
    ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s statusline tick %s\n' "$ts" "$fields" >> "$CLAUDE_PTY_DEBUG_LOG"
  fi
fi

# Step 3: transparent pass-through to the user's real statusline.
# Resolve the target command: env var first, then the sidecar file. `eval`
# because the resolved command may be multi-word (e.g. "jq -r '...'" with
# embedded quoting). User-controlled either way, so eval is acceptable.
real_sl="${CLAUDE_PTY_REAL_STATUSLINE:-}"
if [ -z "$real_sl" ]; then
  prior_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.pty-prior-statusline"
  if [ -f "$prior_file" ]; then
    real_sl=$(cat "$prior_file")
  fi
fi
if [ -n "$real_sl" ]; then
  printf '%s' "$input" | eval "$real_sl"
fi
