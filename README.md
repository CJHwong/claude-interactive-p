# claude-interactive-p

A drop-in replacement for `claude -p --output-format=json` that runs the
**interactive** Claude Code TUI under a PTY and emits the same JSON envelope (a
superset) on stdout. Driving the real TUI is the point: an operator can `tmux
attach` to watch or take over a live turn, and the statusline fields `-p`
doesn't expose (rate limits, context window, fast mode) are folded into the
envelope.

Built for [claude-on-the-fly](https://github.com/CJHwong/claude-on-the-fly).

> **tmux is required for full output.** claude only flushes its session
> transcript against a real terminal, and tmux is what provides one headless.
> Without tmux, claude-pty drops to a degraded [no-tmux mode](#no-tmux-mode).
> Install it: `brew install tmux`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/CJHwong/claude-interactive-p/main/install.sh | bash
```

Then:

```bash
claude-pty --model haiku "Reply with only the word PONG." | jq
```

Requires `tmux`, `jq`, and `curl`. Re-run the curl line to update. Remove with
`~/.local/share/claude-interactive-p/uninstall.sh`.

## Usage

```bash
claude-pty [claude flags...] "prompt"
```

All claude flags pass through. `--help`/`--version` go straight to claude.
`--bare` is rejected: it disables the hooks claude-pty depends on.

Watch a live turn:

```bash
CLAUDE_PTY_TMUX_SESSION=watch claude-pty --model sonnet "Explain this repo."
# in another terminal:
tmux attach -t watch
```

Drive it from Python: see [`examples/usage.py`](examples/usage.py).

## Backends

Chosen at runtime:

| Backend | Selected when | Attachable | Output |
|---|---|---|---|
| **tmux** (default) | `tmux` on PATH and `CLAUDE_PTY_NO_TMUX` unset | yes | full envelope |
| **script** | `tmux` missing, or `CLAUDE_PTY_NO_TMUX=1` | no | degraded headless (below) |

tmux is used whenever it's installed; if you don't set
`CLAUDE_PTY_TMUX_SESSION`, a session name is generated (and logged, so the run
is still attachable). A tmux failure mid-run falls back to script so a hiccup
never costs a turn.

### No-tmux mode

The `script` backend hosts the same interactive TUI without tmux. With a **real
terminal** (a human at a shell) it behaves like tmux mode. **Headless** (no
controlling tty, e.g. launched from a daemon) it gets a 0×0 terminal where
claude never flushes its transcript, so the transcript-derived fields are lost:

| Field | tmux | script (headless) |
|---|---|---|
| `result`, `total_cost_usd`, `statusline` subtree | yes | yes |
| `num_turns`, `usage`, `modelUsage`, `uuid`, `stop_reason` | yes | `0` / `null` |

The cost and statusline fields survive because the statusline renders
regardless; only the transcript is missing. If your automation needs accurate
`num_turns`/usage, use tmux.

## Reference

### Envelope

Superset of `claude -p --output-format=json`. Every `-p` key is present, plus:

| Field | Source |
|---|---|
| `statusline` | statusline shim (cost, context_window, rate_limits, fast_mode) |
| `cwd`, `permission_mode`, `transcript_path`, `background_tasks`, `session_crons` | Stop hook |
| `num_turns`, `stop_reason`, `usage`, `modelUsage`, `uuid` | parsed from the transcript JSONL |
| `duration_ms` | wall-clock measured by the wrapper |
| `duration_api_ms` | statusline `cost.total_api_duration_ms` |
| `fast_mode_state` | `on`/`off` from statusline |
| `terminal_reason` | `completed`, or `background_timeout` if the background-task wait cap fired |

Always-null stubs: `ttft_ms`, `api_error_status`. Always present:
`permission_denials` (`[]`), `is_error` (`false`).

### Env vars

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Config dir claude reads; hooks must be installed here |
| `CLAUDE_PTY_NO_TMUX` | unset | `1` forces the script backend even when tmux is available |
| `CLAUDE_PTY_TMUX_SESSION` | auto | tmux session name (for `tmux attach`); auto-generated if unset |
| `CLAUDE_PTY_NO_LOCK` | unset | `1` skips startup serialization (set when the caller guarantees serial startup) |
| `CLAUDE_PTY_TASK_WAIT_SEC` | `5400` | Max seconds to keep claude alive draining background subagents/teammates |
| `CLAUDE_PTY_DEBUG_LOG` | unset | File path for the wrapper + Stop-hook debug log |
| `CLAUDE_INTERACTIVE_P_HOME` | `~/.local/share/claude-interactive-p` | Where the curl bootstrap drops runtime files |

Install-time: `CLAUDE_PTY_NO_STATUSLINE=1` skips wiring the statusline shim
(then also set `CLAUDE_PTY_NO_LOCK=1` at runtime); `CLAUDE_PTY_YES=1` skips the
install prompt. Lock tuning: `CLAUDE_PTY_LOCK_WAIT_SEC` (600),
`CLAUDE_PTY_LOCK_HOLD_SEC` (10).

## How it works

claude's TUI doesn't exit at turn end, so the wrapper can't wait on process
exit. Three pieces cooperate per turn:

1. **`bin/claude-pty`** launches claude (in tmux, or under `script`), polls for
   the envelope file, waits for any background subagents/teammates to drain,
   then reaps it.
2. **`hooks/statusline.sh`** replaces your `statusLine.command`; it writes each
   tick to a sidecar (captured into `statusline`) and still delegates to your
   real statusline.
3. **`hooks/stop_envelope.sh`** fires on `Stop`, merges the Stop payload with
   the sidecar into the envelope, and writes it. The envelope appearing is the
   turn-done signal.

Without the `CLAUDE_PTY_*` env vars both hooks no-op, so they're safe to leave
installed in your real config.

### Background work

A turn can finish while a subagent or teammate it spawned is still running.
After the first envelope appears, the wrapper keeps claude alive while
`background_tasks` still lists a running `subagent`/`teammate`/`workflow`, and
finalizes once they drain. Background *shells* aren't awaited (they never wake
the session). The whole wait is capped by `CLAUDE_PTY_TASK_WAIT_SEC`; on expiry
the envelope is finalized with `terminal_reason: background_timeout`.

### Compatibility

Tested against Claude Code `2.1.195`. The Stop hook reads
`last_assistant_message` (undocumented; falls back to `transcript_path`).
Background-task waiting reads `background_tasks`, available in `2.1.145`+.

## License

MIT.
