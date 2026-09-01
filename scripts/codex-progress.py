#!/usr/bin/env python3
"""Condense a `codex exec --json` event stream into a readable progress log.

`--json` is not an addition to the human-readable stream, it *replaces* it. The
lane needs the JSON because that is where the usage-window data lives
(`scripts/quota-window.py`), but the driver watches this process through
`process(action="log")`, and a driver watching raw JSONL scroll past has been
given a worse view of its own run than it had before. So the raw stream is teed
to a file for the parser and this prints one short line per event worth seeing.

It also captures the session id the moment it appears, into `--session-id-file`.
That is not a convenience: `codex exec resume <id>` is the only way to continue
a session after a usage-limit park, and an id recovered by scraping
`~/.codex/sessions/` after the process died is recovered too late and from the
wrong place -- any concurrent session could be the newest rollout on disk.

Reads stdin, writes progress to stdout, and passes nothing through: the raw
stream is already teed upstream.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

# Events that say something an operator reading a night run would want to see.
# Anything not named here is counted, not printed -- a chunk run emits thousands
# of deltas, and echoing them would reproduce the problem this exists to fix.
INTERESTING = {
    "task_started": lambda p: "turn started",
    "task_complete": lambda p: "turn complete",
    "error": lambda p: "ERROR: " + str(p.get("message", ""))[:200],
    "stream_error": lambda p: "stream error: " + str(p.get("message", ""))[:200],
}


def first_str(obj: Any, *keys: str) -> str | None:
    """The first value for any of `keys` found anywhere in `obj`."""
    if isinstance(obj, dict):
        for key in keys:
            value = obj.get(key)
            if isinstance(value, str) and value:
                return value
        for value in obj.values():
            found = first_str(value, *keys)
            if found:
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = first_str(value, *keys)
            if found:
                return found
    return None


def payload_of(event: dict) -> dict:
    """`--json` events and rollout lines nest the payload differently."""
    payload = event.get("payload")
    return payload if isinstance(payload, dict) else event


def describe(event: dict) -> str | None:
    payload = payload_of(event)
    kind = payload.get("type")

    render = INTERESTING.get(kind)
    if render:
        return render(payload)

    if kind == "agent_message":
        text = " ".join(str(payload.get("message", "")).split())
        return "codex: " + (text[:160] or "(empty message)")

    if kind in ("exec_command_begin", "command_execution"):
        command = payload.get("command")
        if isinstance(command, list):
            command = " ".join(str(c) for c in command)
        text = " ".join(str(command or "").split())
        return "$ " + text[:160] if text else None

    if kind == "token_count":
        limits = payload.get("rate_limits")
        if isinstance(limits, dict):
            parts = []
            for name, window in limits.items():
                if isinstance(window, dict) and "used_percent" in window:
                    used = window.get("used_percent")
                    mins = window.get("window_minutes")
                    if used is not None:
                        # window_minutes is not required to be there, and
                        # "5.0% of Nonemin" in an operator's log is worse than
                        # saying nothing about the length.
                        span = f" of {mins}min" if mins is not None else ""
                        parts.append(f"{name} {used}%{span}")
            if parts:
                return "quota: " + ", ".join(parts)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--session-id-file",
                        help="write the session id here the moment it appears")
    args = parser.parse_args()

    session_written = False
    counted = 0
    previous = None
    for line in sys.stdin:
        line = line.strip()
        if not line or line[0] != "{":
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        if not session_written and args.session_id_file:
            session_id = first_str(event, "session_id", "thread_id",
                                   "conversation_id")
            if session_id:
                try:
                    with open(args.session_id_file, "w", encoding="utf-8") as fh:
                        fh.write(session_id + "\n")
                    session_written = True
                    print(f"session: {session_id}", flush=True)
                except OSError as exc:
                    print(f"WARNING: session id not captured: {exc}", flush=True)

        text = describe(event)
        if text is None:
            counted += 1
        elif text == previous:
            # A long turn re-reports an unchanged quota figure on every
            # response. Printing each one buries the lines that carry news.
            counted += 1
        else:
            print(text, flush=True)
            previous = text
    print(f"(codex stream ended; {counted} further events not shown)",
          flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
