# claude-interactive-p

A drop-in replacement for `claude -p --output-format=json` that emits the same JSON envelope (a superset) on stdout. Given an attachable `tmux` target it drives a real interactive `claude` TUI — so an operator can `tmux attach` to watch or take over, and the statusline fields `-p` doesn't expose (rate limits, context window usage, fast mode state) are folded into the envelope. Without one it falls back to a headless subprocess that returns the same envelope minus those statusline-only fields.

Built for [claude-on-the-fly](https://github.com/CJHwong/claude-on-the-fly).

## Tutorial

If you just want to try it:

```bash
curl -fsSL https://raw.githubusercontent.com/CJHwong/claude-interactive-p/main/install.sh | bash
```

Then run a prompt:

```bash
~/.local/share/claude-interactive-p/bin/claude-pty --model haiku "Reply with only the word PONG." | jq
```

The output is a JSON object — a superset of `claude -p --output-format=json` with `statusline` and session fields added.

To remove it:

```bash
~/.local/share/claude-interactive-p/uninstall.sh
```

Requires `curl` and `jq`.

## How-to Guides

### Install without the statusline shim

If you only need the Stop hook (you don't consume statusline output in your TUI):

```bash
CLAUDE_PTY_NO_STATUSLINE=1 curl -fsSL https://raw.githubusercontent.com/CJHwong/claude-interactive-p/main/install.sh | bash
```

This skips wiring `statusLine.command`. At runtime you also need `CLAUDE_PTY_NO_LOCK=1` since the statusline shim is what releases the startup lock — without it the lock never signals and the wrapper hangs on the hard timeout.

### Watch a live turn with tmux

```bash
CLAUDE_PTY_TMUX_SESSION=watch claude-pty --model sonnet "Explain this codebase."
```

Then in another terminal:

```bash
tmux attach -t watch
```

You see claude's live TUI. This tmux backend is the only attachable mode. Any tmux failure falls back to the headless subprocess backend so it never costs a turn (you just lose attachability for that run).

### Drive from Python

```python
from examples.usage import claude_pty

envelope = claude_pty("Summarize this file.", model="sonnet")
print(envelope["result"])
print(envelope["total_cost_usd"])  # present in both backends; statusline-only fields need the tmux backend
```

### Drive from shell

```bash
envelope=$(claude-pty --model haiku "Reply PONG.")
echo "$envelope" | jq '{result, total_cost_usd, num_turns}'
# .statusline.* (context_window, rate_limits, ...) is populated only in the tmux backend
```

### Update to latest

Re-run the curl line. It fetches current runtime files and re-wires hooks idempotently:

```bash
curl -fsSL https://raw.githubusercontent.com/CJHwong/claude-interactive-p/main/install.sh | bash
```

### Use a custom config dir

```bash
CLAUDE_CONFIG_DIR=/tmp/claude-test curl -fsSL https://raw.githubusercontent.com/CJHwong/claude-interactive-p/main/install.sh | bash
```

### Debug a stuck or failing run

```bash
CLAUDE_PTY_DEBUG_LOG=/tmp/pty-debug.log claude-pty --model haiku "test"
cat /tmp/pty-debug.log
```

## Reference

### CLI

```
claude-pty [claude flags...] "prompt"
```

All claude flags (`--model`, `--permission-mode`, etc.) pass through. `--help`, `--version` pass straight to claude. `--bare` is rejected — it disables hooks, which claude-pty depends on.

### Env vars

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Config dir claude reads; hooks must be installed here |
| `CLAUDE_INTERACTIVE_P_HOME` | `~/.local/share/claude-interactive-p` | Where curl bootstrap drops runtime files |
| `CLAUDE_INTERACTIVE_P_REPO` | `CJHwong/claude-interactive-p` | GitHub repo for curl bootstrap |
| `CLAUDE_INTERACTIVE_P_REF` | `main` | Branch/tag for curl bootstrap |
| `CLAUDE_PTY_NO_STATUSLINE` | unset | Set to `1` to skip statusline wiring at install |
| `CLAUDE_PTY_YES` | unset | Set to `1` to skip the install confirmation prompt |
| `CLAUDE_PTY_TMUX_SESSION` | unset | Tmux session name for live-turn watching |
| `CLAUDE_PTY_NO_LOCK` | unset | Set to `1` to skip startup serialization |
| `CLAUDE_PTY_LOCK_WAIT_SEC` | `600` | Max seconds to wait for the startup lock |
| `CLAUDE_PTY_LOCK_HOLD_SEC` | `10` | Max seconds to hold the lock if sidecar never appears |
| `CLAUDE_PTY_TASK_WAIT_SEC` | `5400` | Max seconds to keep claude alive waiting for background subagents/teammates to finish before forcing termination |
| `CLAUDE_PTY_DEBUG_LOG` | unset | File path for debug event log |

### JSON envelope shape

Superset of `claude -p --output-format=json`. Every `-p` key is present, plus the fields below. The `Source` column describes the **tmux backend**; the **subprocess backend** takes the core fields (`num_turns`, `usage`, `modelUsage`, `total_cost_usd`, `duration_ms`, `stop_reason`, `terminal_reason`, `fast_mode_state`, `uuid`, `is_error`) straight from `claude -p`'s own JSON, sets `statusline` to `null`, and leaves `background_tasks`/`session_crons` empty.

| Field | Source |
|---|---|
| `statusline` | Full statusline payload (cost, context_window, rate_limits, fast_mode, output_style) |
| `cwd` | Stop hook |
| `permission_mode` | Stop hook |
| `transcript_path` | Stop hook |
| `background_tasks` | Stop hook |
| `session_crons` | Stop hook |
| `num_turns` | Parsed from transcript JSONL |
| `stop_reason` | Parsed from transcript JSONL |
| `usage` | Parsed from transcript JSONL |
| `modelUsage` | Aggregated from transcript JSONL, grouped by model |
| `duration_ms` | Wall-clock measured by the wrapper |
| `duration_api_ms` | From statusline `cost.total_api_duration_ms` |
| `fast_mode_state` | `"on"` / `"off"` from statusline |
| `terminal_reason` | Wrapper: `"completed"`, or `"background_timeout"` if the background-task wait cap fired |

Stubs (always present, not implemented):

| Field | Value |
|---|---|
| `ttft_ms` | `null` |
| `permission_denials` | `[]` |
| `api_error_status` | `null` |
| `is_error` | `false` |

### Files installed

| Path | Purpose |
|---|---|
| `bin/claude-pty` | Wrapper binary |
| `hooks/statusline.sh` | Statusline shim (sidecar writer + pass-through) |
| `hooks/stop_envelope.sh` | Stop hook (envelope writer) |
| `install.sh` | Installer |
| `uninstall.sh` | Uninstaller |

Settings.json mutations:

- `statusLine.command` → statusline shim (unless `CLAUDE_PTY_NO_STATUSLINE=1`)
- `.hooks.Stop[]` → Stop hook appended (deduped)
- Backup written to `settings.json.bak.<timestamp>` before mutation
- Prior statusline saved to `.pty-prior-statusline` for transparent delegation

## Explanation

### Why not just `claude -p`?

For a headless run, `claude -p` is fine — and it's exactly what the subprocess backend uses. The reason to run the interactive TUI (tmux backend) is twofold: an operator can `tmux attach` to watch or take over a live turn, and the statusline fields `-p` doesn't expose (rate limit counters, context window usage, fast mode state, output style) flow only through the TUI's statusline hook, where the shim captures them into the envelope. When you don't have a tmux target, none of that is available, so the subprocess backend just returns `-p`'s JSON in envelope shape.

### Backends

The backend is chosen at runtime:

- **tmux** (`CLAUDE_PTY_TMUX_SESSION` set + tmux available): interactive, attachable, statusline-enriched. Uses the per-turn pipeline below.
- **subprocess** (otherwise): runs `claude -p --output-format=json` headless and normalizes the result. Not attachable, no statusline.

A bare PTY headless (no controlling tty) gives claude a 0×0 terminal, and the TUI won't flush its transcript there, so an interactive non-tmux backend isn't viable — hence the subprocess fallback rather than a `script` PTY.

### Pipeline (tmux backend)

Three pieces run per turn:

1. **`bin/claude-pty`** acquires the startup lock, then launches `claude` in a detached tmux session. It polls for the envelope file, waits for any background subagents or teammates to finish (see [Waiting for background work](#waiting-for-background-work)), then reaps the session.

2. **`hooks/statusline.sh`** replaces your `statusLine.command`. When `CLAUDE_PTY_SIDECAR` is set, it atomically writes each statusline tick to a sidecar file. It always delegates rendering to your real statusline (resolved from `CLAUDE_PTY_REAL_STATUSLINE`, then `.pty-prior-statusline`, then nothing).

3. **`hooks/stop_envelope.sh`** fires on Stop. It waits for the post-response statusline tick (debounced ~300ms behind Stop), merges Stop stdin + sidecar into a draft envelope, and writes it atomically. The envelope's appearance is the "turn done" signal.

Without the claude-pty env vars, both hooks no-op — safe to leave installed in your real config.

### Who kills claude

The wrapper kills claude, not the Stop hook. The hook used to `kill $PPID`, but newer Claude Code wraps hook commands in a shell — `$PPID` was that shell, claude survived, the wrapper blocked forever, and the process tree leaked. Owning the kill means the wrapper knows the real child pid (and, in tmux mode, the session).

### Waiting for background work

A turn can finish (Stop fires, envelope written) while a subagent or teammate the agent spawned is still running. Killing claude then would cut that work off mid-flight. So after the first envelope appears, the wrapper keeps claude alive while `background_tasks` still lists a running `subagent`, `teammate`, or `workflow`, and finalizes only once they drain. The Stop hook rewrites the envelope on every turn, and a finished agent task drops out of `background_tasks`, so a later Stop shows it gone.

Background shells (a dev server, `tail -f`) are not awaited: they finish without waking the session, so they never produce a draining Stop, and waiting on them would stall every turn that left one running. The whole wait is capped by `CLAUDE_PTY_TASK_WAIT_SEC` (default 1.5h); on expiry the wrapper finalizes the last envelope with `terminal_reason: "background_timeout"`. The cap is a backstop for a teammate that never finishes (for example one parked waiting for a message this single turn will never send), not a runtime limit: work that drains on its own ends the wait the moment it completes, however long it ran.

### Startup lock

Claude's TUI mode races on a singleton supervisor lock during the first ~1s of boot. Two TUIs starting simultaneously leave one or both hung. claude-pty serializes only that window with a mkdir-based lock at `$CLAUDE_CONFIG_DIR/.pty-lock/`. Once the statusline sidecar appears (claude reached steady state), the lock is released so the next caller can start. Stale locks from dead holders are stolen automatically.

### Compatibility

Tested against Claude Code `2.1.195`. The Stop hook (tmux backend) reads `last_assistant_message` from stdin — undocumented, could be renamed or removed. If it breaks, the fallback is `transcript_path`. Teammate-aware waiting reads the `background_tasks` array from the Stop payload, available in Claude Code `2.1.145`+; on older versions the array is absent, so the wrapper finalizes on the first Stop as before. The subprocess backend depends only on `claude -p --output-format=json`, which is stable.

### Caveats

- `ttft_ms` is always `null`. No hook channel surfaces time-to-first-token.
- `num_turns` counts all `assistant` records including `ai-title` generation, so it can be higher than `-p`'s count.
- Wall-clock is ~1-2s slower than plain `-p` due to TUI bringup and statusline poll.

## License

MIT.
