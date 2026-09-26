#!/usr/bin/env bash
# Exercise the real wrapper and an isolated tmux server without calling Claude.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
real_tmux=$(command -v tmux)
scratch=$(mktemp -d "$repo/.pty-collision.XXXXXX")
export CLAUDE_CONFIG_DIR="$scratch/config"
export CLAUDE_PTY_TEST_MARKER="$scratch/claude-called"
export CLAUDE_PTY_NO_LOCK=1
export PATH="$scratch/bin:$PATH"
unset TMUX TMUX_PANE TMUX_TMPDIR CLAUDE_PTY_SIDECAR CLAUDE_PTY_DEBUG_LOG
mkdir -p "$CLAUDE_CONFIG_DIR" "$scratch/bin"

# -S uses the relative socket path as given. TMUX_TMPDIR expands to an absolute
# path that can exceed the Unix socket limit in a deep checkout.
printf '#!/usr/bin/env bash\nexec %q -S %q "$@"\n' \
  "$real_tmux" "${scratch#"$repo"/}/socket" > "$scratch/bin/tmux"
chmod +x "$scratch/bin/tmux"

cleanup() {
  tmux kill-session -t '=busy' 2>/dev/null || true
  rm -r "$scratch"
}
trap cleanup EXIT

cat > "$scratch/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
printf 'called\n' >> "$CLAUDE_PTY_TEST_MARKER"
printf '%s\n' '{"result":"ok","background_tasks":[]}' > "$CLAUDE_PTY_ENVELOPE"
sleep 30
CLAUDE
chmod +x "$scratch/bin/claude"

tmux new-session -d -s busy 'sleep 60'

if CLAUDE_PTY_TMUX_SESSION=busy "$repo/bin/claude-pty" prompt > "$scratch/collision.json" 2> "$scratch/collision.err"; then
  echo 'claude-pty unexpectedly replaced a live tmux session' >&2
  exit 1
fi
grep -q "already exists; refusing to replace it" "$scratch/collision.err"
if grep -q 'no envelope produced' "$scratch/collision.err"; then
  echo 'collision error was misreported as a failed Claude turn' >&2
  exit 1
fi
tmux has-session -t '=busy'
test ! -e "$CLAUDE_PTY_TEST_MARKER"

CLAUDE_PTY_TMUX_SESSION=busy-child "$repo/bin/claude-pty" prompt > "$scratch/owned.json" 2> "$scratch/owned.err"
jq -e '.result == "ok"' "$scratch/owned.json" > /dev/null
tmux has-session -t '=busy'
if tmux has-session -t '=busy-child' 2>/dev/null; then
  echo 'claude-pty failed to reap its own tmux session' >&2
  exit 1
fi
test "$(wc -l < "$CLAUDE_PTY_TEST_MARKER")" -eq 1

CLAUDE_PTY_NO_TMUX=1 "$repo/bin/claude-pty" prompt > "$scratch/script.json" 2> "$scratch/script.err"
jq -e '.result == "ok"' "$scratch/script.json" > /dev/null
test "$(wc -l < "$CLAUDE_PTY_TEST_MARKER")" -eq 2
tmux has-session -t '=busy'
