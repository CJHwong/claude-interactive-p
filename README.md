# claude-interactive-p

A drop-in replacement for `claude -p --output-format=json` that runs through interactive mode under a PTY, so the JSON envelope includes the statusline-only fields `-p` doesn't expose: `rate_limits.{five_hour, seven_day}` with reset times, `context_window.used_percentage`, `exceeds_200k_tokens`, `fast_mode`, `output_style`, and the rest.

Built for [claude-on-the-fly](https://github.com/CJHwong/claude-on-the-fly), which needs visibility into rate limits and context usage that `-p` doesn't surface.

## How it works

Three pieces:

- `bin/claude-pty` spawns `claude "prompt"` under a PTY (via `script(1)`), waits for the turn to finish, captures the JSON envelope, and prints it on stdout. It launches claude in the background, polls for the envelope, then terminates claude itself — the wrapper owns the kill (see below).
- `hooks/statusline.sh` is a transparent shim. When the claude-pty wrapper is active (env var set), it writes the raw statusline payload to a sidecar file. It always delegates the visible TUI rendering to `$CLAUDE_PTY_REAL_STATUSLINE`, so your existing statusline keeps working.
- `hooks/stop_envelope.sh` fires when the assistant turn finishes. It polls the sidecar for the post-response statusline tick (which lands ~300ms after Stop due to debounce) and writes the merged envelope. That's its only job: the envelope appearing is the "turn done" signal the wrapper polls for.

Without the claude-pty env vars present, both hooks no-op and the statusline shim passes through unchanged, so it's safe to leave installed in your real `~/.claude/settings.json`.

**Who kills claude.** The wrapper terminates claude, not the Stop hook. The hook used to `kill $PPID`, assuming `$PPID` was the claude TUI — but newer Claude Code wraps hook commands in a shell, so `$PPID` became that shell and claude survived, the wrapper blocked forever, and the process tree leaked as orphans. The wrapper knows the real child pid (and, in tmux mode, the session), so it owns the kill.

**tmux mode.** Set `CLAUDE_PTY_TMUX_SESSION=<name>` and, if `tmux` is available, the wrapper hosts claude's PTY in a detached tmux session of that name instead of throwing the rendered TUI at `/dev/null`. You can `tmux attach -t <name>` to watch the live turn. Any tmux failure falls back to the `script` PTY, so it never costs a turn.

## Compatibility

Tested against Claude Code `2.1.146`. The Stop hook relies on `last_assistant_message` in its stdin payload, which is undocumented and could be renamed or removed in future versions. If a Claude Code update breaks the envelope, that field is the first thing to check. The fallback is to read the assistant response from `transcript_path` instead.

## Install

Run the installer straight from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/CJHwong/claude-interactive-p/main/install.sh | bash
```

It fetches the runtime files (`bin/claude-pty`, the two hook scripts, `uninstall.sh`) into `~/.local/share/claude-interactive-p` via curl (no `git clone`), then runs the local install path. Override the destination with `CLAUDE_INTERACTIVE_P_HOME`, the source ref with `CLAUDE_INTERACTIVE_P_REF` (default `main`).

`install.sh` backs up `~/.claude/settings.json`, points `statusLine.command` at the shim, appends the Stop hook (deduped), and prints the `CLAUDE_PTY_REAL_STATUSLINE` export you should add to your shell rc. Set `CLAUDE_PTY_NO_STATUSLINE=1` to skip the statusLine wiring entirely and install only the Stop hook — for callers that don't read the statusline subtree (note: without the shim the startup lock has no release signal, so pair it with `CLAUDE_PTY_NO_LOCK=1`).

Requires `curl` and `jq`. Optionally set `CLAUDE_CONFIG_DIR` before running to install into a non-default config dir. Re-run the curl line to update.

## Use

```bash
~/.local/share/claude-interactive-p/bin/claude-pty --model haiku "Reply with only the word PONG." | jq
```

Output is a single JSON object on stdout. Top-level shape is a superset of `claude -p --output-format=json` (every `-p` key is present), plus `statusline` and a few session fields (`cwd`, `permission_mode`, `transcript_path`, `background_tasks`, `session_crons`).

See `examples/usage.sh` and `examples/usage.py` for integration templates.

## Caveats

- `ttft_ms` is always `null`. Time-to-first-token isn't surfaced by any hook channel; capturing it would require a stream-parsing shim that isn't built.
- `terminal_reason` is always `"completed"` because the wrapper always terminates claude after Stop. No distinction from error exit.
- `permission_denials` and `api_error_status` are stubs. Derivable from the transcript but format-fragile; not implemented.
- `num_turns` counts every `assistant` record (including `ai-title` generation), so it can be higher than `-p`'s.
- Wall-clock is ~1-2s slower than plain `-p` due to TUI bringup and the post-response statusline poll.
- **claude-pty serializes only claude's supervisor startup race, not the full turn.** Claude's TUI mode races on a singleton supervisor lock during the first ~1s of boot; two TUIs starting simultaneously leave one (or both) hung. Once a claude is past that window, additional claudes can run in parallel. claude-pty holds a mkdir-based lock at `${CLAUDE_CONFIG_DIR:-~/.claude}/.pty-lock/` to gate that startup window, then hands the lock off as soon as the statusline sidecar appears (signal that claude reached steady state). Parallel callers queue at startup but run concurrently after that. Knobs: `CLAUDE_PTY_LOCK_WAIT_SEC` (acquire timeout, default 600s), `CLAUDE_PTY_LOCK_HOLD_SEC` (hard hold cap if the sidecar never appears, default 10s), `CLAUDE_PTY_NO_LOCK=1` (skip the lock entirely — only safe when the caller already guarantees serial startup). Stale locks (holder PID dead) are stolen automatically.

## Uninstall

```bash
~/.local/share/claude-interactive-p/uninstall.sh
```

Removes the shim from `statusLine.command` and the Stop hook entry. Other hooks and settings keys are left alone. Backup is written first.

## License

MIT.
