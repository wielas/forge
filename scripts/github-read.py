#!/usr/bin/env python3
"""Retry the verifier's read-only GitHub requests, without leaking partial output.

Three attempts, each limited to 30 seconds, with 2 and 4 seconds between them.
Only successful stdout is published. Writes (especially merges) are never retried.
Callers keep their existing substrate-failure handling when all attempts fail.
"""

import os
import signal
import subprocess
import sys
import tempfile
import time


READS = {("pr", "view"), ("pr", "diff"), ("repo", "view")}


def read(args, *, timeout=30, delays=(2, 4)):
    if tuple(args[:2]) not in READS or "--web" in args or "-w" in args:
        print("github-read: only pr view, pr diff and repo view are allowed", file=sys.stderr)
        return 2
    for attempt in range(len(delays) + 1):
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            try:
                proc = subprocess.Popen(
                    ["gh", *args], stdin=subprocess.DEVNULL, stdout=output,
                    stderr=errors, start_new_session=True,
                )
            except OSError as exc:
                print(f"github-read: cannot start gh: {exc}", file=sys.stderr)
                return 127
            try:
                code = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
                code = 124
                errors.write(b"\ngithub-read: request timed out\n")
            if code == 0:
                output.seek(0)
                while data := output.read(65536):
                    sys.stdout.buffer.write(data)
                return 0
            if attempt == len(delays):
                errors.seek(0)
                sys.stderr.buffer.write(errors.read())
                print(f"github-read: failed after {attempt + 1} attempts", file=sys.stderr)
                return code if code > 0 else 1
        print(f"github-read: request failed; retrying ({attempt + 2}/{len(delays) + 1})", file=sys.stderr)
        time.sleep(delays[attempt])
    return 1


if __name__ == "__main__":
    sys.exit(read(sys.argv[1:]))
