# CLAUDE.md

`claude-pty` runs one `claude` turn under an interactive PTY and emits a JSON
envelope (a superset of `claude -p --output-format=json`) on stdout when the
turn finishes. By default it hosts the TUI in a detached tmux session an
operator can `tmux attach` into; when tmux is unavailable (or
`CLAUDE_PTY_NO_TMUX=1`) it falls back to a non-attachable `script` PTY. Pure
bash plus `jq`. Do not add other runtime dependencies.

The README covers usage, env vars, the envelope shape, and install. This file
records what isn't obvious from the code: how the two backends differ, the
turn-done mechanism, how to debug hooks, and how to test changes.

## Backends

Chosen at runtime in `claude-pty`:

- **tmux** (default) — when `tmux` is on PATH and `CLAUDE_PTY_NO_TMUX` is unset.
  Hosts the TUI in a detached tmux session (name auto-generated if
  `CLAUDE_PTY_TMUX_SESSION` is unset). The only attachable mode.
- **script** — when tmux is missing, `CLAUDE_PTY_NO_TMUX=1`, or a tmux launch
  fails mid-run. Hosts the same interactive TUI under `script`. Not attachable.

Both backends use the Stop-hook + statusline-shim envelope mechanism below; the
only structural difference is the process host.

Why tmux is the default: claude only flushes its session transcript against a
real, rendered terminal. tmux provides one even headless. The `script` PTY does
**not** when launched with no controlling tty — it gets a 0×0 terminal and the
transcript never flushes, so the transcript-derived envelope fields
(`num_turns`, `usage`, `modelUsage`, `uuid`, `stop_reason`) come back `0`/`null`
(verified on 2.1.195 over 20 headless runs: 0 flushed; the same turn under tmux
flushes every time). What survives in headless script mode is everything *not*
from the transcript: `result` (the Stop hook's `last_assistant_message`) and the
whole `statusline` subtree including `total_cost_usd` (the shim fires on render,
which happens regardless of terminal size). So script mode is fine with a real
terminal (a human at a shell) and degraded-but-not-broken headless. It is not a
guess — emulation completeness (size, controlling tty, VT query responses) was
tested and does not make the transcript flush; only the tmux process host does.

## The turn-done mechanism

`claude` does not exit at turn end in interactive mode (the TUI waits for more
input), so the wrapper cannot wait on process exit. Instead the `Stop` hook
(`hooks/stop_envelope.sh`) writes `$CLAUDE_PTY_ENVELOPE`, and that file appearing
is the turn-done signal. `claude-pty` polls for it, waits for background agent
work to drain, then reaps the session (tmux `kill-session`, or SIGTERM/SIGKILL
of the `script` child tree). This is identical across both backends — both run
the interactive TUI, so both depend on the Stop hook firing.

The wrapper owns the kill, not the hook. An older design had the hook
`kill $PPID`; that broke when Claude Code started wrapping hook commands in a
shell, so `$PPID` became the wrapper rather than `claude`, and the process tree
leaked. Keep kill ownership in `claude-pty`. When you change terminate logic,
change it in `wait_for_turn_completion` and the per-backend reap in
`run_claude_pty`.

## Hooks

Authoritative reference for hook events and payloads: https://code.claude.com/docs/en/hooks

Read it before touching anything hook-related. Do not guess payload field names or assume which event fires. Facts the code depends on, all verified against real runs:

- `Stop` fires when the MAIN agent finishes a turn. `SubagentStop` fires when a subagent finishes. They are distinct events, and only `Stop` is wired here. Wiring `stop_envelope.sh` to `SubagentStop` would write a premature envelope every time any subagent finishes and kill the session mid-turn.
- The `Stop` payload carries `background_tasks[]` (each entry has `id`, `type`, `status`, `description`, plus `command` for shell tasks and `agent_type` for subagent tasks) and `session_crons[]`. Available in Claude Code `2.1.145`+.
- A completed task DROPS OUT of `background_tasks`. It is not left in the array with a terminal status. So presence of an awaited type means still in flight.
- A finished `subagent`/`teammate`/`workflow` wakes the orchestrator and produces a fresh `Stop` with that task dropped. A finished background `shell` does NOT wake the session, so it never produces a draining `Stop`. This asymmetry is why `claude-pty` awaits agentic task types only and relies on a wall-clock cap (`CLAUDE_PTY_TASK_WAIT_SEC`) for everything else.
- `Stop`/`SubagentStop` include `agent_id`/`agent_type` only inside a subagent context. On a main-agent `Stop` they are null, so the payload itself tells you which kind of stop it is.

## Debugging hook behavior

To learn what a hook actually receives, capture its raw stdin instead of reasoning about it.

1. Run from a directory Claude Code already trusts. A fresh directory triggers the "trust this folder?" prompt, which blocks before any hook fires and makes the session look hung. Put the capture hooks in `.claude/settings.local.json` inside a trusted repo (local settings are gitignored by convention and merge with user hooks).
2. Point a capture script at the events you care about (`Stop`, `SubagentStop`, `SubagentStart`, `TeammateIdle`). Have it write `$(cat)` to a unique file and append a one-line summary (the `background_tasks` types and statuses, `agent_id`). Use `mktemp` for the unique name. macOS `date` has no `%N`, so do not rely on nanosecond timestamps.
3. To watch MULTIPLE `Stop` events across a background task's lifetime, run `claude` directly under `script` with NO kill, since `claude-pty` terminates at the first qualifying Stop. Let it live longer than the task, then kill the process tree yourself.
4. For the wrapper's own trace, set `CLAUDE_PTY_DEBUG_LOG` to a known path. Both the wrapper and the Stop hook append to it.

## Testing changes

Verify with REAL `claude-pty` runs, not unit reasoning. Tests passing is not the
same as the feature working. Cover both backends.

tmux backend (default; tmux on PATH):

- Fast path: a fresh turn that runs a tool finalizes with valid envelope JSON,
  correct `num_turns`/`total_cost_usd`, a populated `statusline` subtree, and the
  transcript flushed to `<session_uuid>.jsonl`.
- Drain: spawn a background subagent that does blocking work and writes a marker
  file, then assert the marker IS written (the teammate was not killed
  mid-flight) and `terminal_reason` is `"completed"`. Make the inner work
  blocking inside the subagent, not a detached shell, or you are testing shell
  draining instead of agent draining.
- Cap: set `CLAUDE_PTY_TASK_WAIT_SEC` small with a longer-running task, then
  assert it finalizes near the cap with `terminal_reason: "background_timeout"`.

script backend (`CLAUDE_PTY_NO_TMUX=1`):

- Headless: a turn finalizes with a valid envelope, `terminal_reason: "completed"`,
  `result` present, `total_cost_usd` and `statusline` present (the shim renders
  regardless), and `num_turns: 0` / `usage: null` (transcript not flushed). It
  must NOT hang — the Stop hook still fires. This degraded shape is expected;
  don't "fix" it by reaching for a subprocess backend (an earlier `claude -p`
  fallback was removed: it defeats the tool's interactive-recreation purpose).
- Error: `--resume` a nonexistent session; assert a non-zero exit and that
  claude's "No conversation found" survives in the stderr dump (never swallow
  it). The `script` typescript feeds that dump.

After a kill mid-flight, a deeply nested bash grandchild (a subagent's `sleep`,
for example) can orphan and run to completion on its own before exiting. That is
expected, not a leak.

## Constraints

- Stay version-proof against Claude Code TUI and hook changes. Prefer documented payload fields and avoid depending on internal pids or undocumented behavior. Note the version a feature was verified against.
- `--bare` disables the hook system, so no envelope is ever written and the wrapper would hang. It is rejected up front.
- Backward compatibility across the binary rename (`claude-snap` to `claude-pty`) matters, since deployed callers depend on it.
- The tool is publishable and self-contained. Keep personal paths, env prefixes, and sibling-project or org names out of code, comments, and docs. Install is one-line `curl | sh`.
