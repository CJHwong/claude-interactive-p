#!/usr/bin/env bash
#
# Install the claude-pty hooks into ~/.claude/settings.json (or the directory pointed
# at by CLAUDE_CONFIG_DIR). Idempotent: safe to re-run.
#
# Two ways to invoke:
#
#   1. From a checked-out copy of this repo:
#        ./install.sh
#      The script writes hook paths pointing at the directory it lives in.
#
#   2. Via curl, with nothing on disk:
#        curl -fsSL https://raw.githubusercontent.com/CJHwong/claude-interactive-p/main/install.sh | bash
#      The script detects it has no sibling hooks/ directory, fetches the
#      runtime files directly from raw.githubusercontent into
#      $CLAUDE_INTERACTIVE_P_HOME (default: ~/.local/share/claude-interactive-p),
#      then re-execs itself from that location so step 1's logic runs.
#      No git clone, just curl.
#
# Env vars honored:
#   CLAUDE_CONFIG_DIR             config dir to write to. Default: ~/.claude
#   CLAUDE_INTERACTIVE_P_HOME     where to drop files in curl mode.
#                                 Default: ~/.local/share/claude-interactive-p
#   CLAUDE_INTERACTIVE_P_REPO     GitHub owner/repo in curl mode.
#                                 Default: CJHwong/claude-interactive-p
#   CLAUDE_INTERACTIVE_P_REF      branch/tag/sha to fetch from raw.gh in curl
#                                 mode. Default: main
#   CLAUDE_PTY_NO_STATUSLINE     when 1, skip wiring statusLine.command — only
#                                 the Stop hook is installed. For callers that
#                                 don't consume the statusline subtree (and that
#                                 serialize startup themselves, since without the
#                                 shim the lock's release signal never arrives).
#
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE" 2>/dev/null)" 2>/dev/null && pwd || echo "")"

# Bootstrap: no sibling hooks/ means the script was piped from curl.
# Fetch the runtime files into a stable location and re-exec from there.
if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/hooks/statusline.sh" ]; then
  TARGET="${CLAUDE_INTERACTIVE_P_HOME:-$HOME/.local/share/claude-interactive-p}"
  REPO="${CLAUDE_INTERACTIVE_P_REPO:-CJHwong/claude-interactive-p}"
  REF="${CLAUDE_INTERACTIVE_P_REF:-main}"
  RAW_BASE="https://raw.githubusercontent.com/$REPO/$REF"

  command -v curl >/dev/null 2>&1 || { echo "install.sh: curl is required for the curl bootstrap path" >&2; exit 1; }

  echo "install.sh: fetching runtime files from $REPO@$REF into $TARGET"
  mkdir -p "$TARGET/bin" "$TARGET/hooks"

  # Files actually needed at runtime. Examples/ stay on GitHub.
  for rel in install.sh uninstall.sh bin/claude-pty hooks/statusline.sh hooks/stop_envelope.sh; do
    echo "  fetching $rel"
    curl -fsSL "$RAW_BASE/$rel" -o "$TARGET/$rel"
  done

  chmod +x "$TARGET/install.sh" "$TARGET/uninstall.sh" \
           "$TARGET/bin/claude-pty" \
           "$TARGET/hooks/statusline.sh" "$TARGET/hooks/stop_envelope.sh"

  exec "$TARGET/install.sh" "$@"
fi

# Local-install path begins here.
REPO_DIR="$SCRIPT_DIR"
SHIM="$REPO_DIR/hooks/statusline.sh"
STOP="$REPO_DIR/hooks/stop_envelope.sh"

# When 0, leave statusLine.command alone and install only the Stop hook.
WIRE_STATUSLINE=1
[ "${CLAUDE_PTY_NO_STATUSLINE:-0}" = "1" ] && WIRE_STATUSLINE=0

CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CFG_DIR/settings.json"

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }
[ "$WIRE_STATUSLINE" = "1" ] && { [ -x "$SHIM" ] || { echo "install.sh: $SHIM is not executable" >&2; exit 1; }; }
[ -x "$STOP" ] || { echo "install.sh: $STOP is not executable" >&2; exit 1; }

mkdir -p "$CFG_DIR"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
  echo "install.sh: created empty $SETTINGS"
fi

# Preview what's about to change and ask before mutating. Read from /dev/tty
# (not stdin) so the confirm works even when the script was piped from curl.
# Skip the prompt entirely when CLAUDE_PTY_YES is set or no tty is available.
echo
echo "About to update $SETTINGS:"
echo "  - back up to $SETTINGS.bak.<timestamp>"
if [ "$WIRE_STATUSLINE" = "1" ]; then
  prior_sl_preview=$(jq -r '.statusLine.command // "(none)"' "$SETTINGS")
  echo "  - set .statusLine.command to $SHIM"
  if [ "$prior_sl_preview" != "(none)" ] && [ "$prior_sl_preview" != "$SHIM" ]; then
    echo "    (replaces: $prior_sl_preview)"
    echo "    (saved to $CFG_DIR/.pty-prior-statusline so the shim delegates to it)"
  fi
else
  echo "  - leave .statusLine.command untouched (CLAUDE_PTY_NO_STATUSLINE=1)"
fi
echo "  - append Stop hook to .hooks.Stop[] (deduped)"
echo

if [ -z "${CLAUDE_PTY_YES:-}" ] && [ -e /dev/tty ]; then
  printf "Proceed? [Y/n] " >&2
  read -r ans </dev/tty || ans=""
  case "$ans" in
    n|N|no|No|NO) echo "install.sh: aborted by user"; exit 1 ;;
  esac
fi

ts=$(date +%Y%m%d%H%M%S)
cp "$SETTINGS" "$SETTINGS.bak.$ts"
echo "install.sh: backup written to $SETTINGS.bak.$ts"

# The Stop hook splice is always applied. The statusLine wiring is gated on
# WIRE_STATUSLINE so callers that don't read the statusline subtree can opt out.
if [ "$WIRE_STATUSLINE" = "1" ]; then
  # Persist the prior statusLine.command so the shim can delegate to it
  # without the user having to touch their shell rc. The shim reads this file
  # when CLAUDE_PTY_REAL_STATUSLINE is not exported; uninstall.sh consumes
  # the file to restore the original on the way out.
  PRIOR_STATUSLINE_FILE="$CFG_DIR/.pty-prior-statusline"
  prior_sl=$(jq -r '.statusLine.command // ""' "$SETTINGS")
  if [ -n "$prior_sl" ] && [ "$prior_sl" != "$SHIM" ]; then
    printf '%s' "$prior_sl" > "$PRIOR_STATUSLINE_FILE"
    echo "install.sh: saved prior statusLine.command to $PRIOR_STATUSLINE_FILE"
  fi
  updated=$(jq \
    --arg shim "$SHIM" \
    --arg stop "$STOP" '
      .statusLine = { type: "command", command: $shim }
    | .hooks = (.hooks // {})
    | .hooks.Stop = (
        ((.hooks.Stop // []) | map(select((.hooks // []) | all(.command != $stop))))
        + [ { hooks: [ { type: "command", command: $stop } ] } ]
      )
  ' "$SETTINGS")
else
  updated=$(jq \
    --arg stop "$STOP" '
      .hooks = (.hooks // {})
    | .hooks.Stop = (
        ((.hooks.Stop // []) | map(select((.hooks // []) | all(.command != $stop))))
        + [ { hooks: [ { type: "command", command: $stop } ] } ]
      )
  ' "$SETTINGS")
fi

printf '%s\n' "$updated" > "$SETTINGS"
echo "install.sh: wrote $SETTINGS"

echo
echo "Test the install:"
echo "  $REPO_DIR/bin/claude-pty --model haiku 'Reply PONG.'"
