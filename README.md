# claude-interactive-p

A drop-in replacement for `claude -p --output-format=json` that runs through interactive mode under a PTY, so the JSON envelope includes the statusline-only fields `-p` doesn't expose: `rate_limits.{five_hour, seven_day}` with reset times, `context_window.used_percentage`, `exceeds_200k_tokens`, `fast_mode`, `output_style`, and the rest.

Built for [claude-on-the-fly](https://github.com/CJHwong/claude-on-the-fly), which needs visibility into rate limits and context usage that `-p` doesn't surface.

## How it works

Three pieces:

- `bin/claude-snap` spawns `claude "prompt"` under a PTY (via `script(1)`), captures the JSON envelope after the turn finishes, and prints it on stdout.
- `hooks/statusline.sh` is a transparent shim. When the snap wrapper is active (env var set), it writes the raw statusline payload to a sidecar file. It always delegates the visible TUI rendering to `$CLAUDE_SNAP_REAL_STATUSLINE`, so your existing statusline keeps working.
- `hooks/stop_envelope.sh` fires when the assistant turn finishes. It polls the sidecar for the post-response statusline tick (which lands ~300ms after Stop due to debounce), writes the merged envelope, and SIGTERMs the parent claude process so the TUI exits.

Without the snap env vars present, both hooks no-op and the statusline shim passes through unchanged, so it's safe to leave installed in your real `~/.claude/settings.json`.

## Compatibility

Tested against Claude Code `2.1.146`. The Stop hook relies on `last_assistant_message` in its stdin payload, which is undocumented and could be renamed or removed in future versions. If a Claude Code update breaks the envelope, that field is the first thing to check. The fallback is to read the assistant response from `transcript_path` instead.

## Install

Run the installer straight from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/CJHwong/claude-interactive-p/main/install.sh | bash
```

It fetches the runtime files (`bin/claude-snap`, the two hook scripts, `uninstall.sh`) into `~/.local/share/claude-interactive-p` via curl (no `git clone`), then runs the local install path. Override the destination with `CLAUDE_INTERACTIVE_P_HOME`, the source ref with `CLAUDE_INTERACTIVE_P_REF` (default `main`).

`install.sh` backs up `~/.claude/settings.json`, points `statusLine.command` at the shim, appends the Stop hook (deduped), and prints the `CLAUDE_SNAP_REAL_STATUSLINE` export you should add to your shell rc.

Requires `curl` and `jq`. Optionally set `CLAUDE_CONFIG_DIR` before running to install into a non-default config dir. Re-run the curl line to update.

## Use

```bash
~/.local/share/claude-interactive-p/bin/claude-snap --model haiku "Reply with only the word PONG." | jq
```

Output is a single JSON object on stdout. Top-level shape is a superset of `claude -p --output-format=json` (every `-p` key is present), plus `statusline` and a few session fields (`cwd`, `permission_mode`, `transcript_path`, `background_tasks`, `session_crons`).

See `examples/usage.sh` and `examples/usage.py` for integration templates.

## Caveats

- `ttft_ms` is always `null`. Time-to-first-token isn't surfaced by any hook channel; capturing it would require a stream-parsing shim that isn't built.
- `terminal_reason` is always `"completed"` because the wrapper always SIGTERMs after Stop. No distinction from error exit.
- `permission_denials` and `api_error_status` are stubs. Derivable from the transcript but format-fragile; not implemented.
- `num_turns` counts every `assistant` record (including `ai-title` generation), so it can be higher than `-p`'s.
- Wall-clock is ~1-2s slower than plain `-p` due to TUI bringup and the post-response statusline poll.
- **Snap serializes only claude's supervisor startup race, not the full turn.** Claude's TUI mode races on a singleton supervisor lock during the first ~1s of boot; two TUIs starting simultaneously leave one (or both) hung. Once a claude is past that window, additional claudes can run in parallel. Snap holds a mkdir-based lock at `${CLAUDE_CONFIG_DIR:-~/.claude}/.snap-lock/` to gate that startup window, then hands the lock off as soon as the statusline sidecar appears (signal that claude reached steady state). Parallel callers queue at startup but run concurrently after that. Knobs: `CLAUDE_SNAP_LOCK_WAIT_SEC` (acquire timeout, default 600s), `CLAUDE_SNAP_LOCK_HOLD_SEC` (hard hold cap if the sidecar never appears, default 10s), `CLAUDE_SNAP_NO_LOCK=1` (skip the lock entirely — only safe when the caller already guarantees serial startup). Stale locks (holder PID dead) are stolen automatically.

## Uninstall

```bash
~/.local/share/claude-interactive-p/uninstall.sh
```

Removes the shim from `statusLine.command` and the Stop hook entry. Other hooks and settings keys are left alone. Backup is written first.

## License

MIT.
