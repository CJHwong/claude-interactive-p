#!/usr/bin/env bash
#
# claude-pty PostCompact hook: finish the run when the turn was a compaction.
#
# Why this exists at all. claude-pty's turn-done signal is the envelope, and
# `stop_envelope.sh` writes it from the **Stop** hook. Stop fires when the
# assistant finishes a message — and a compaction produces no message. So
# `claude-pty --resume <id> "/compact"` compacts, drops the TUI back to its
# prompt, and then hangs: no envelope ever appears, the TUI never exits on its
# own, and `wait_for_turn_completion` has no wall-clock cap of its own. The run
# only ends when the *caller's* timeout does. This hook is the missing writer.
#
# ONLY for trigger == "manual". Claude Code also compacts on its own, mid-turn,
# when a conversation outgrows the window — and that compaction lands with
# `trigger: "auto"` while the real turn is still going. Writing an envelope
# there would be actively harmful: `wait_for_turn_completion` breaks out of its
# wait the instant the envelope file exists, so claude-pty would kill claude in
# the middle of the turn and return a compaction summary in place of the answer.
# An auto compaction is an internal event of a turn that has its own Stop hook
# coming; leave it alone. Anything other than "manual" is likewise left alone,
# so an unrecognized trigger degrades to today's behavior rather than to a
# truncated turn.
#
# No statusline subtree, deliberately. The sidecar holds the last tick, and a
# compaction may produce none — so the file would still describe the
# *pre*-compaction context. Reporting that as this run's reading is worse than
# reporting nothing: a consumer thresholding on context size would see the old,
# larger number and immediately ask for another compaction. An absent subtree
# reads as "unknown", which is the truth.
set -euo pipefail
input=$(cat)

DEBUG_LOG="${CLAUDE_PTY_DEBUG_LOG:-}"
log() { [ -n "$DEBUG_LOG" ] && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$DEBUG_LOG" || true; }

if [ -z "${CLAUDE_PTY_ENVELOPE:-}" ]; then
  # A normal interactive session that merely has these hooks installed.
  log "postcompact: no envelope env, no-op"
  exit 0
fi

trigger=$(printf '%s' "$input" | jq -r '.trigger // ""')
if [ "$trigger" != "manual" ]; then
  log "postcompact: trigger=${trigger:-none}, not ours — leaving the turn alone"
  exit 0
fi

# `compact` mirrors the subtree `claude -p` reports for the same operation, so a
# consumer reads one shape in either mode instead of special-casing pty. The
# token counts are not here on purpose: they live in the transcript's
# `compact_boundary` record, which is authoritative and which the consumer is
# already reading the session file for.
envelope=$(jq -n \
  --argjson post "$input" '
  {
    type: "result",
    subtype: "success",
    is_error: false,
    session_id: $post.session_id,
    transcript_path: $post.transcript_path,
    cwd: $post.cwd,
    result: ($post.compact_summary // ""),
    background_tasks: [],
    compact: { result: "success", trigger: $post.trigger },
    statusline: {}
  }
')

tmp="${CLAUDE_PTY_ENVELOPE}.tmp.$$"
printf '%s\n' "$envelope" > "$tmp"
mv "$tmp" "$CLAUDE_PTY_ENVELOPE"
log "postcompact: envelope written (trigger=manual); parent will terminate claude"
exit 0
