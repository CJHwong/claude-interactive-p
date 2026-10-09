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
# Every run first warns that it runs downloaded code as you and asks [Y/n] on
# the terminal. With no terminal (an agent, CI), pass -y or set CLAUDE_PTY_YES:
#   curl -fsSL .../install.sh | bash -s -- -y
#
# Env vars honored:
#   CLAUDE_PTY_YES                when set, same as -y: skip both prompts.
#   CLAUDE_CONFIG_DIR             config dir to write to. Default: ~/.claude
#   CLAUDE_INTERACTIVE_P_HOME     where to drop files in curl mode.
#                                 Default: ~/.local/share/claude-interactive-p
#   CLAUDE_INTERACTIVE_P_REPO     GitHub owner/repo in curl mode.
#                                 Default: CJHwong/claude-interactive-p
#   CLAUDE_INTERACTIVE_P_REF      branch/tag/sha to fetch from raw.gh in curl
#                                 mode. Default: main
#   CLAUDE_PTY_NO_STATUSLINE     when 1, skip wiring statusLine.command. Both
#                                 the Stop, PostCompact and StopFailure hooks are still
#                                 installed. For callers that don't consume the
#                                 statusline subtree (and that serialize startup
#                                 themselves, since without the shim the lock's
#                                 release signal never arrives).
#
set -euo pipefail

ASSUME_YES=0
[ -n "${CLAUDE_PTY_YES:-}" ] && ASSUME_YES=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
  esac
done

# A piped install runs whatever the server sends, with your permissions, so ask
# first. The answer comes from /dev/tty because stdin is the script itself. The
# curl path re-execs itself after the fetch; the marker keeps it from asking twice.
confirm_install() {
  cat >&2 <<'EOF'
WARNING: this installer downloads code from the internet and runs it as you.
It can read, change, or delete anything your user account can.
The server can send different code each time, so read the script first:
  https://github.com/CJHwong/claude-interactive-p/blob/main/install.sh
Pass -y to skip this question (for agents and CI).
EOF
  if ! (: </dev/tty) 2>/dev/null; then
    echo "install.sh: no terminal to ask on; re-run with -y to accept the risk" >&2
    exit 1
  fi
  printf 'Proceed? [Y/n] ' >&2
  local answer=""
  read -r answer </dev/tty || answer=""
  case "$answer" in
    n|N|no|No|NO) echo "install.sh: aborted" >&2; exit 1 ;;
  esac
}
if [ "$ASSUME_YES" = 0 ] && [ -z "${_CLAUDE_PTY_RISK_ACCEPTED:-}" ]; then
  confirm_install
fi

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
  for rel in install.sh uninstall.sh bin/claude-pty hooks/statusline.sh hooks/stop_envelope.sh hooks/postcompact_envelope.sh hooks/stopfailure_envelope.sh; do
    echo "  fetching $rel"
    curl -fsSL "$RAW_BASE/$rel" -o "$TARGET/$rel"
  done

  chmod +x "$TARGET/install.sh" "$TARGET/uninstall.sh" \
           "$TARGET/bin/claude-pty" \
           "$TARGET/hooks/statusline.sh" "$TARGET/hooks/stop_envelope.sh" \
           "$TARGET/hooks/postcompact_envelope.sh" "$TARGET/hooks/stopfailure_envelope.sh"

  _CLAUDE_PTY_RISK_ACCEPTED=1 exec "$TARGET/install.sh" "$@"
fi

# Local-install path begins here.
REPO_DIR="$SCRIPT_DIR"
SHIM="$REPO_DIR/hooks/statusline.sh"
STOP="$REPO_DIR/hooks/stop_envelope.sh"
# Writes the envelope for a manual /compact, which fires no Stop hook and would
# otherwise hang the run. See the header of the script for why it is gated on
# trigger == "manual".
POSTCOMPACT="$REPO_DIR/hooks/postcompact_envelope.sh"
# Writes the envelope for a turn that dies on an API error (an expired login, a
# 429), which fires StopFailure instead of Stop and would otherwise hang the run.
STOPFAILURE="$REPO_DIR/hooks/stopfailure_envelope.sh"

# When 0, leave statusLine.command alone and install only the Stop hook.
WIRE_STATUSLINE=1
[ "${CLAUDE_PTY_NO_STATUSLINE:-0}" = "1" ] && WIRE_STATUSLINE=0

CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CFG_DIR/settings.json"

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }
[ "$WIRE_STATUSLINE" = "1" ] && { [ -x "$SHIM" ] || { echo "install.sh: $SHIM is not executable" >&2; exit 1; }; }
[ -x "$STOP" ] || { echo "install.sh: $STOP is not executable" >&2; exit 1; }
[ -x "$POSTCOMPACT" ] || { echo "install.sh: $POSTCOMPACT is not executable" >&2; exit 1; }
[ -x "$STOPFAILURE" ] || { echo "install.sh: $STOPFAILURE is not executable" >&2; exit 1; }

mkdir -p "$CFG_DIR"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
  echo "install.sh: created empty $SETTINGS"
fi

# Preview what's about to change and ask before mutating. Read from /dev/tty
# (not stdin) so the confirm works even when the script was piped from curl.
# Skip the prompt entirely under -y / CLAUDE_PTY_YES or when no tty is available.
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
echo "  - append PostCompact hook to .hooks.PostCompact[] (deduped)"
echo "  - append StopFailure hook to .hooks.StopFailure[] (deduped)"
echo

if [ "$ASSUME_YES" = 0 ] && [ -e /dev/tty ]; then
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
  # Migration: the sidecar was once named .snap-prior-statusline. Seed the new
  # name from it so an upgrader's saved original isn't orphaned (and lost).
  if [ ! -f "$PRIOR_STATUSLINE_FILE" ] && [ -f "$CFG_DIR/.snap-prior-statusline" ]; then
    mv "$CFG_DIR/.snap-prior-statusline" "$PRIOR_STATUSLINE_FILE"
  fi
  prior_sl=$(jq -r '.statusLine.command // ""' "$SETTINGS")
  if [ -z "$prior_sl" ]; then
    # No current statusLine — a stale prior would resurrect a command the user
    # already removed on the next reinstall. Clear it.
    rm -f "$PRIOR_STATUSLINE_FILE"
  elif [ "$(basename "$prior_sl")" = "statusline.sh" ]; then
    # The current statusLine is already a shim (this install's, a sibling
    # tool's, or a different install path). Saving it as the "prior" would
    # clobber the user's real original with a shim and chain shims on every
    # reinstall — the bug the old `!= "$SHIM"` guard missed. Skip; whatever
    # real original was saved on first install stays put.
    :
  else
    printf '%s' "$prior_sl" > "$PRIOR_STATUSLINE_FILE"
    echo "install.sh: saved prior statusLine.command to $PRIOR_STATUSLINE_FILE"
  fi
  updated=$(jq \
    --arg shim "$SHIM" \
    --arg stop "$STOP" \
    --arg postcompact "$POSTCOMPACT" \
    --arg stopfailure "$STOPFAILURE" '
      .statusLine = { type: "command", command: $shim }
    | .hooks = (.hooks // {})
    | .hooks.Stop = (
        ((.hooks.Stop // [])
          | map(.hooks = ((.hooks // []) | map(select(.command != $stop))))
          | map(select((.hooks // []) | length > 0)))
        + [ { hooks: [ { type: "command", command: $stop } ] } ]
      )
    | .hooks.PostCompact = (
        ((.hooks.PostCompact // [])
          | map(.hooks = ((.hooks // []) | map(select(.command != $postcompact))))
          | map(select((.hooks // []) | length > 0)))
        + [ { hooks: [ { type: "command", command: $postcompact } ] } ]
      )
    | .hooks.StopFailure = (
        ((.hooks.StopFailure // [])
          | map(.hooks = ((.hooks // []) | map(select(.command != $stopfailure))))
          | map(select((.hooks // []) | length > 0)))
        + [ { hooks: [ { type: "command", command: $stopfailure } ] } ]
      )
  ' "$SETTINGS")
else
  updated=$(jq \
    --arg stop "$STOP" \
    --arg postcompact "$POSTCOMPACT" \
    --arg stopfailure "$STOPFAILURE" '
      .hooks = (.hooks // {})
    | .hooks.Stop = (
        ((.hooks.Stop // [])
          | map(.hooks = ((.hooks // []) | map(select(.command != $stop))))
          | map(select((.hooks // []) | length > 0)))
        + [ { hooks: [ { type: "command", command: $stop } ] } ]
      )
    | .hooks.PostCompact = (
        ((.hooks.PostCompact // [])
          | map(.hooks = ((.hooks // []) | map(select(.command != $postcompact))))
          | map(select((.hooks // []) | length > 0)))
        + [ { hooks: [ { type: "command", command: $postcompact } ] } ]
      )
    | .hooks.StopFailure = (
        ((.hooks.StopFailure // [])
          | map(.hooks = ((.hooks // []) | map(select(.command != $stopfailure))))
          | map(select((.hooks // []) | length > 0)))
        + [ { hooks: [ { type: "command", command: $stopfailure } ] } ]
      )
  ' "$SETTINGS")
fi

printf '%s\n' "$updated" > "$SETTINGS"
echo "install.sh: wrote $SETTINGS"

echo
echo "Test the install:"
echo "  $REPO_DIR/bin/claude-pty --model haiku 'Reply PONG.'"
