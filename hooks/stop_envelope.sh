#!/usr/bin/env bash
# Stop hook for "interactive-p" mode.
#   - If CLAUDE_PTY_ENVELOPE is unset, do nothing (normal interactive session).
#   - Otherwise: merge Stop stdin + statusline sidecar into a draft envelope and
#     write it atomically to CLAUDE_PTY_ENVELOPE. That is the ONLY job — the
#     envelope's appearance is the "turn done" signal. The parent (claude-pty)
#     polls for it and terminates claude itself.
#
# Why the hook no longer kills claude: it used to `kill -TERM $PPID`, assuming
# $PPID was the claude TUI. Newer Claude Code (2.1.x) invokes hook commands via
# a shell wrapper, so $PPID is that shell, not claude — the TUI survived,
# claude-pty blocked forever, and the claude-pty/script/claude tree leaked as
# orphans. Letting the parent own the kill is version-proof: it knows the real
# child pid (and, in tmux mode, the session).
set -euo pipefail
input=$(cat)

DEBUG_LOG="${CLAUDE_PTY_DEBUG_LOG:-}"
log() { [ -n "$DEBUG_LOG" ] && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$DEBUG_LOG" || true; }

if [ -z "${CLAUDE_PTY_ENVELOPE:-}" ]; then
  log "no envelope env, no-op"
  exit 0
fi

# Statusline ticks are debounced 300ms behind the "new assistant message"
# trigger that ALSO fires this Stop hook. Without this wait, the hook would
# read the previous (often session-start) statusline payload with empty
# cost/context. Snapshot the sidecar's mtime once, then wait for it to
# advance. Using > (strict) rather than comparing against a wall-clock start
# avoids the same-integer-second race where a sidecar written in the same
# second as the hook start would falsely match on the first check.
sidecar='{}'
if [ -n "${CLAUDE_PTY_SIDECAR:-}" ]; then
  sidecar_mtime() {
    stat -f %m "$CLAUDE_PTY_SIDECAR" 2>/dev/null \
      || stat -c %Y "$CLAUDE_PTY_SIDECAR" 2>/dev/null \
      || echo 0
  }
  prev_mtime=$(sidecar_mtime)
  # Cap at 10 × 0.15s = 1.5s. statusline debounce is 300ms, so this gives
  # multiple chances to land plus headroom for slow disks.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -f "$CLAUDE_PTY_SIDECAR" ] && [ "$(sidecar_mtime)" -gt "$prev_mtime" ]; then
      break
    fi
    sleep 0.15
  done
  if [ -f "$CLAUDE_PTY_SIDECAR" ]; then
    sidecar=$(cat "$CLAUDE_PTY_SIDECAR")
  else
    log "sidecar never appeared, emitting envelope without statusline fields"
  fi
fi

envelope=$(jq -n \
  --argjson stop "$input" \
  --argjson side "$sidecar" '
  {
    type: "result",
    subtype: "success",
    session_id: $stop.session_id,
    transcript_path: $stop.transcript_path,
    cwd: $stop.cwd,
    permission_mode: $stop.permission_mode,
    result: $stop.last_assistant_message,
    background_tasks: $stop.background_tasks,
    session_crons: $stop.session_crons,
    statusline: $side
  }
')

tmp="${CLAUDE_PTY_ENVELOPE}.tmp.$$"
printf '%s\n' "$envelope" > "$tmp"
mv "$tmp" "$CLAUDE_PTY_ENVELOPE"
log "draft envelope written; parent will detect + terminate claude"
exit 0
