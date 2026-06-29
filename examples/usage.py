#!/usr/bin/env python3
"""Minimal Python usage: drive claude-pty, parse the JSON envelope.

Intended as the integration template for claude-on-the-fly's claude backend:
replace its `-p --output-format=json` subprocess call with `claude_pty()` below
without changing the call shape. With tmux (the default backend) the envelope
carries the full statusline subtree (rate_limits, context_window, etc.) and
accurate num_turns/usage. Headless no-tmux runs (the `script` fallback) still
return result + cost + statusline, but leave num_turns/usage at 0/null because
claude can't flush its transcript without a real terminal.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
CLAUDE_PTY = REPO_ROOT / "bin" / "claude-pty"


def claude_pty(
    prompt: str,
    *,
    model: str | None = None,
    config_dir: str | None = None,
    extra_args: list[str] | None = None,
) -> dict:
    """Run claude-pty and return the parsed envelope.

    Raises subprocess.CalledProcessError on non-zero exit; stderr is captured.
    """
    env = os.environ.copy()
    if config_dir:
        env["CLAUDE_CONFIG_DIR"] = config_dir
    # No CLAUDE_CONFIG_DIR check: claude defaults to ~/.claude. The claude-pty
    # hooks must already be installed into whatever config dir claude reads.

    cmd: list[str] = [str(CLAUDE_PTY)]
    if model:
        cmd += ["--model", model]
    if extra_args:
        cmd += extra_args
    cmd.append(prompt)

    proc = subprocess.run(
        cmd, env=env, capture_output=True, text=True, check=True
    )
    return json.loads(proc.stdout)


if __name__ == "__main__":
    envelope = claude_pty(
        prompt=sys.argv[1] if len(sys.argv) > 1 else "Reply with only the word PONG.",
        model="haiku",
    )
    sl = envelope.get("statusline") or {}  # present in both backends; defensive anyway
    print(f"result:        {envelope['result']!r}")
    print(f"cost USD:      {envelope['total_cost_usd']}")
    print(f"duration ms:   {envelope['duration_ms']}")
    print(f"context %:     {sl.get('context_window', {}).get('used_percentage')}")
    print(f"5h rate %:     {sl.get('rate_limits', {}).get('five_hour', {}).get('used_percentage')}")
    print(f"7d rate %:     {sl.get('rate_limits', {}).get('seven_day', {}).get('used_percentage')}")
