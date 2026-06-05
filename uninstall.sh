#!/usr/bin/env bash
#
# Reverse install.sh: remove the claude-pty statusLine + Stop hook from settings.json.
# Leaves a backup and prints any prior statusLine.command you may want to
# restore manually.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$REPO_DIR/hooks/statusline.sh"
STOP="$REPO_DIR/hooks/stop_envelope.sh"

CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CFG_DIR/settings.json"

command -v jq >/dev/null 2>&1 || { echo "uninstall.sh: jq is required" >&2; exit 1; }
[ -f "$SETTINGS" ] || { echo "uninstall.sh: no $SETTINGS"; exit 0; }

ts=$(date +%Y%m%d%H%M%S)
cp "$SETTINGS" "$SETTINGS.bak.$ts"
echo "uninstall.sh: backup written to $SETTINGS.bak.$ts"

# If install.sh saved a prior statusLine.command, restore it as part of the
# round-trip. Otherwise the statusLine key is removed entirely.
PRIOR_STATUSLINE_FILE="$CFG_DIR/.pty-prior-statusline"
prior_sl=""
if [ -f "$PRIOR_STATUSLINE_FILE" ]; then
  prior_sl=$(cat "$PRIOR_STATUSLINE_FILE")
fi

# Drop or restore the statusLine; drop the claude-pty Stop hook entry. Other hooks
# and settings keys are untouched.
updated=$(jq \
  --arg shim "$SHIM" \
  --arg stop "$STOP" \
  --arg prior "$prior_sl" '
    if .statusLine.command == $shim then
      if ($prior | length) > 0
        then .statusLine = { type: "command", command: $prior }
        else del(.statusLine)
      end
    else . end
  | if .hooks then
      .hooks.Stop = ((.hooks.Stop // []) | map(select((.hooks // []) | all(.command != $stop))))
      | if (.hooks.Stop | length == 0) then del(.hooks.Stop) else . end
      | if (.hooks | length == 0) then del(.hooks) else . end
    else .
    end
' "$SETTINGS")

printf '%s\n' "$updated" > "$SETTINGS"
echo "uninstall.sh: wrote $SETTINGS"

if [ -f "$PRIOR_STATUSLINE_FILE" ]; then
  rm -f "$PRIOR_STATUSLINE_FILE"
  echo "uninstall.sh: restored prior statusLine.command and removed $PRIOR_STATUSLINE_FILE"
fi
