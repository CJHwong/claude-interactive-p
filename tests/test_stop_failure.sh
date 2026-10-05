#!/usr/bin/env bash
# Exercise a turn that dies on an API error, through the real wrapper and the
# real StopFailure hook, without calling Claude. Then check install/uninstall
# wire and remove the hook.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
real_tmux=$(command -v tmux)
scratch=$(mktemp -d "$repo/.pty-stopfailure.XXXXXX")
export CLAUDE_CONFIG_DIR="$scratch/config"
export CLAUDE_PTY_NO_LOCK=1
export CLAUDE_PTY_TEST_HOOK="$repo/hooks/stopfailure_envelope.sh"
export PATH="$scratch/bin:$PATH"
unset TMUX TMUX_PANE TMUX_TMPDIR CLAUDE_PTY_SIDECAR CLAUDE_PTY_DEBUG_LOG
mkdir -p "$CLAUDE_CONFIG_DIR" "$scratch/bin"

printf '#!/usr/bin/env bash\nexec %q -S %q "$@"\n' \
  "$real_tmux" "${scratch#"$repo"/}/socket" > "$scratch/bin/tmux"
chmod +x "$scratch/bin/tmux"

cleanup() {
  tmux kill-server 2>/dev/null || true
  find "$scratch" -delete
}
trap cleanup EXIT

# Claude fires StopFailure, not Stop, on an API error and then idles at its
# input box. The sleep stands in for that idle TUI: only the envelope can end
# the run early, and the elapsed check below tells the two apart. No `timeout`:
# stock macOS has none.
cat > "$scratch/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
printf '%s\n' '{"session_id":"s1","transcript_path":"/nonexistent.jsonl","cwd":"/tmp","hook_event_name":"StopFailure","error":"authentication_failed","last_assistant_message":"Login expired · Please run /login"}' \
  | "$CLAUDE_PTY_TEST_HOOK"
sleep 60
CLAUDE
chmod +x "$scratch/bin/claude"

fail() { echo "FAIL: $*" >&2; exit 1; }

check_envelope() {
  local arm="$1" out="$2"
  jq -e '.is_error == true' "$out" > /dev/null || fail "$arm: is_error is not true"
  jq -e '.terminal_reason == "api_error"' "$out" > /dev/null || fail "$arm: terminal_reason is not api_error"
  jq -e '.error == "authentication_failed"' "$out" > /dev/null || fail "$arm: error category lost"
  jq -e '.result == "Login expired · Please run /login"' "$out" > /dev/null || fail "$arm: result text lost"
}

for arm in tmux script; do
  start=$(date +%s)
  if [ "$arm" = script ]; then
    CLAUDE_PTY_NO_TMUX=1 "$repo/bin/claude-pty" prompt > "$scratch/$arm.json" 2> "$scratch/$arm.err" \
      || { cat "$scratch/$arm.err" >&2; fail "$arm: claude-pty exited non-zero"; }
  else
    CLAUDE_PTY_TMUX_SESSION=sf "$repo/bin/claude-pty" prompt > "$scratch/$arm.json" 2> "$scratch/$arm.err" \
      || { cat "$scratch/$arm.err" >&2; fail "$arm: claude-pty exited non-zero"; }
  fi
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 20 ] || fail "$arm: took ${elapsed}s; the envelope did not end the run"
  check_envelope "$arm" "$scratch/$arm.json"
done

# A failure during the drain wait keeps the wait: teammate t2 is still listed,
# the wake-up turn dies, and only the later clean Stop ends the run.
cat > "$scratch/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
printf '%s\n' '{"result":"spawned","background_tasks":[{"id":"t2","type":"teammate"}]}' > "$CLAUDE_PTY_ENVELOPE"
sleep 1
printf '%s\n' '{"hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"429"}' \
  | "$CLAUDE_PTY_TEST_HOOK"
sleep 2
printf '%s\n' '{"result":"all done","background_tasks":[]}' > "$CLAUDE_PTY_ENVELOPE"
sleep 60
CLAUDE
CLAUDE_PTY_TMUX_SESSION=drain "$repo/bin/claude-pty" prompt > "$scratch/drain.json" 2> "$scratch/drain.err" \
  || { cat "$scratch/drain.err" >&2; fail "drain: claude-pty exited non-zero"; }
jq -e '.is_error == false and .result == "all done"' "$scratch/drain.json" > /dev/null \
  || fail "drain: a failed wake-up turn ended the wait for a running teammate"

# A normal turn still reads as a clean one: a Stop draft carries no is_error.
cat > "$scratch/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
printf '%s\n' '{"result":"ok","background_tasks":[]}' > "$CLAUDE_PTY_ENVELOPE"
sleep 60
CLAUDE
CLAUDE_PTY_TMUX_SESSION=ok "$repo/bin/claude-pty" prompt > "$scratch/ok.json" 2> "$scratch/ok.err" \
  || { cat "$scratch/ok.err" >&2; fail "success: claude-pty exited non-zero"; }
jq -e '.is_error == false and .terminal_reason == "completed"' "$scratch/ok.json" > /dev/null \
  || fail "success: a clean turn did not read as completed"

# Without the envelope env the hook is a no-op for a normal session.
printf '{"error":"authentication_failed"}' | env -u CLAUDE_PTY_ENVELOPE "$repo/hooks/stopfailure_envelope.sh" \
  || fail "hook failed outside claude-pty"

# install wires the hook once, even on a second run; uninstall removes it.
CLAUDE_PTY_YES=1 "$repo/install.sh" > /dev/null
CLAUDE_PTY_YES=1 "$repo/install.sh" > /dev/null
settings="$CLAUDE_CONFIG_DIR/settings.json"
count=$(jq --arg h "$repo/hooks/stopfailure_envelope.sh" '[.hooks.StopFailure[].hooks[] | select(.command == $h)] | length' "$settings")
[ "$count" = 1 ] || fail "install wired StopFailure $count times"
"$repo/uninstall.sh" > /dev/null
jq -e '.hooks.StopFailure == null' "$settings" > /dev/null || fail "uninstall left StopFailure behind"

# The branch that leaves the statusline alone wires the hook too.
CLAUDE_PTY_YES=1 CLAUDE_PTY_NO_STATUSLINE=1 "$repo/install.sh" > /dev/null
jq -e --arg h "$repo/hooks/stopfailure_envelope.sh" '[.hooks.StopFailure[].hooks[] | select(.command == $h)] | length == 1' "$settings" > /dev/null \
  || fail "the no-statusline install did not wire StopFailure"

echo "ok: StopFailure ends the run as an api_error on both backends"
