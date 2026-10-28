#!/usr/bin/env bash
# A pre_tool_call shell hook that records what Hermes hands one: its stdin, the HERMES_/TERMINAL_
# part of its environment (the claim lock redacted) and its cwd, appended to $PROBE_OUT. It
# changes nothing and always exits 0. Used only by `worker-ctx.py hook-probe`.
out="${PROBE_OUT:-/dev/null}"
{
  echo "--- stdin"; cat; echo
  echo "--- env"; env | grep -E '^(HERMES_|TERMINAL_)' | sed -E 's/(CLAIM_LOCK=).*/\1<redacted>/' | sort
  echo "--- cwd"; pwd
} >> "$out"
exit 0
