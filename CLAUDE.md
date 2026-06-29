# CLAUDE.md

`claude-pty` runs one `claude` turn headlessly and emits a JSON envelope (a superset of `claude -p --output-format=json`) on stdout when the turn finishes. With an attachable tmux target it drives a real interactive `claude` TUI an operator can `tmux attach` into; otherwise it falls back to a non-attachable subprocess. Pure bash plus `jq`. Do not add other runtime dependencies.

The README covers usage, env vars, the envelope shape, and the install flow. This file records the things that aren't obvious from reading the code: how the two backends differ, how the turn-done mechanism works, how to debug hook behavior, and how to test changes.

## Backends

The backend is chosen at runtime in `claude-pty`:

- **tmux** — when `CLAUDE_PTY_TMUX_SESSION` is set and `tmux` is on PATH. Hosts the interactive TUI in a detached tmux session an operator can `tmux attach` into. The only attachable mode, and the only one that uses the Stop-hook envelope mechanism below.
- **subprocess** — otherwise (or if tmux fails to start). Runs `claude -p --output-format=json` as a plain subprocess. Headless, not attachable.

Why two backends: claude's TUI only persists its transcript against a real, rendered terminal. tmux provides one even when launched headless; a bare `script`-style PTY launched with no controlling tty gets a 0×0 terminal and the TUI never flushes the transcript, so turns/tool-use/cost are lost. (Verified on 2.1.195: same `script` invocation flushes from inside a tmux pane, not from a tty-less context — it's the terminal, not the kill timing.) The subprocess backend sidesteps the TUI entirely: with no tty, claude runs the turn non-interactively, flushes its transcript, prints the result JSON, and exits on its own. So it's correct headless at the cost of attachability. An earlier `script` fallback was dropped because it can't flush headless.

## The turn-done mechanism (tmux backend)

In interactive mode `claude` does not exit at turn end (the TUI waits for more input), so the wrapper cannot wait on process exit. Instead the `Stop` hook (`hooks/stop_envelope.sh`) writes `$CLAUDE_PTY_ENVELOPE`, and that file appearing is the turn-done signal. `claude-pty` polls for it, waits for background agent work to drain, then reaps the tmux session.

The wrapper owns the kill, not the hook. An older design had the hook `kill $PPID`; that broke when Claude Code started wrapping hook commands in a shell, so `$PPID` became the wrapper rather than `claude`, and the process tree leaked. Keep kill ownership in `claude-pty`, which knows the tmux session. When you change terminate logic, change it in `wait_for_turn_completion`.

The subprocess backend needs none of this: `claude -p` exits on its own at turn end and prints the envelope directly (cost, turns, usage, `terminal_reason`, etc.), so `run_subprocess_mode` just normalizes that JSON to the envelope shape — no hook, no statusline, no kill.

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

Verify with REAL `claude-pty` runs, not unit reasoning. Tests passing is not the same as the feature working. Cover both backends.

Subprocess backend (no `CLAUDE_PTY_TMUX_SESSION`):

- Fast path: a fresh `--session-id` turn that runs a tool finalizes with valid envelope JSON, correct `num_turns`/`total_cost_usd`, and the transcript flushed to `<session_uuid>.jsonl`.
- Resume: seed a session, then `--resume` a tool turn; assert the transcript grows and `num_turns` reflects it.
- Error: `--resume` a nonexistent session; assert non-zero exit and a non-empty stderr dump (claude's "No conversation found" must survive — never swallow it). `set -e` will abort before the dump if the `claude` call isn't guarded; keep the `if … then rc=0 else rc=$?` form.

tmux backend (`CLAUDE_PTY_TMUX_SESSION` set), for terminate-logic changes:

- Fast path: a prompt with no background work finalizes promptly with `terminal_reason: "completed"` and a populated `statusline` subtree.
- Drain: spawn a background subagent that does blocking work and writes a marker file, then assert the marker IS written (proves the teammate was not killed mid-flight) and `terminal_reason` is `"completed"`. Make the inner work blocking inside the subagent, not a detached shell, or you are testing shell draining instead of agent draining.
- Cap: set `CLAUDE_PTY_TASK_WAIT_SEC` small with a longer-running task, then assert it finalizes near the cap with `terminal_reason: "background_timeout"`.

After a kill mid-flight, a deeply nested bash grandchild (a subagent's `sleep`, for example) can orphan and run to completion on its own before exiting. That is expected, not a leak.

## Constraints

- Stay version-proof against Claude Code TUI and hook changes. Prefer documented payload fields and avoid depending on internal pids or undocumented behavior. Note the version a feature was verified against.
- `--bare` disables the hook system, so no envelope is ever written and the wrapper would hang. It is rejected up front.
- Backward compatibility across the binary rename (`claude-snap` to `claude-pty`) matters, since deployed callers depend on it.
- The tool is publishable and self-contained. Keep personal paths, env prefixes, and sibling-project or org names out of code, comments, and docs. Install is one-line `curl | sh`.
