#!/usr/bin/env bash
#
# claude-pty StopFailure hook: finish the run when the turn died on an API error.
#
# Why this exists. claude-pty's turn-done signal is the envelope, which the
# Stop hook writes. A turn that fails on an API error (an expired login, a 429,
# an overloaded model) fires StopFailure INSTEAD of Stop, and the TUI drops back
# to its input box. So without this hook no envelope ever appears, and the run
# hangs until the caller's own timeout, then reports a timeout that hides the
# real error. Measured on Claude Code 2.1.289: an invalid token fires
# StopFailure with `error: "authentication_failed"` 2s into the turn, and no Stop.
#
# The envelope mirrors what `claude -p --output-format json` reports for the
# same failure (`is_error: true`, `terminal_reason: "api_error"`), so a consumer
# reads one shape in either mode. `-p` also carries the HTTP status; the hook
# payload has only the category, so `error` carries that and the final envelope
# leaves `api_error_status` null rather than guess one.
#
# `background_tasks` comes from the envelope this run already has, if any. The
# file lives in claude-pty's per-run temp dir, so it exists only when a Stop
# fired earlier in this run, and claude-pty is then waiting on that list. A
# failure there is a wake-up turn that died (teammate A finished, the main
# thread's reply hit a 429), and an empty list would end the wait and kill
# teammate B mid-flight. Carrying the list keeps the wait, and a later clean Stop
# replaces this draft. With no earlier Stop the turn itself failed, so there is
# nothing to drain and the list is empty. StopFailure is the MAIN thread's: in
# 2.1.289 its emitter returns early for a subagent context, the same guard the
# Stop path uses before it fires SubagentStop, so a subagent's 429 never writes
# here. No statusline
# subtree, for the reason postcompact_envelope.sh gives: the sidecar would
# describe an earlier turn.
set -euo pipefail
input=$(cat)

DEBUG_LOG="${CLAUDE_PTY_DEBUG_LOG:-}"
log() { [ -n "$DEBUG_LOG" ] && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$DEBUG_LOG" || true; }

if [ -z "${CLAUDE_PTY_ENVELOPE:-}" ]; then
  log "stopfailure: no envelope env, no-op"
  exit 0
fi

pending='[]'
if [ -f "$CLAUDE_PTY_ENVELOPE" ]; then
  pending=$(jq -c '.background_tasks // []' "$CLAUDE_PTY_ENVELOPE" 2>/dev/null) || pending='[]'
fi

envelope=$(jq -n \
  --argjson fail "$input" \
  --argjson pending "$pending" '
  {
    type: "result",
    subtype: "success",
    is_error: true,
    error: ($fail.error // "unknown"),
    error_details: ($fail.error_details // null),
    session_id: $fail.session_id,
    transcript_path: $fail.transcript_path,
    cwd: $fail.cwd,
    permission_mode: $fail.permission_mode,
    result: ($fail.last_assistant_message // ""),
    background_tasks: $pending,
    session_crons: [],
    statusline: {}
  }
')

tmp="${CLAUDE_PTY_ENVELOPE}.tmp.$$"
printf '%s\n' "$envelope" > "$tmp"
mv "$tmp" "$CLAUDE_PTY_ENVELOPE"
log "stopfailure: envelope written (error=$(printf '%s' "$input" | jq -r '.error // "unknown"')); parent will terminate claude"
exit 0
