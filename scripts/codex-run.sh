#!/usr/bin/env bash
# Drive one chunk through `codex exec`, parking through usage-limit windows.
#
# Codex quota is a rolling window, not a flat allowance. A lane that treats
# exhaustion as a failure throws away a run whose comprehension has already
# been paid for -- the expensive part of a chunk is Codex reading itself into
# the problem, and that is precisely what is lost by starting over. So this
# waits instead: it parks, sleeps until the provider's own stated reset, and
# resumes the SAME session.
#
# Sleeping happens INSIDE one lane run, which is why it does not collide with
# the single-use guards in lane-setup.sh and lane-blast-radius.sh. A park is
# not a retry: the run never terminates, the run id is never reused, and the
# blast-radius capture taken before Codex started still governs the whole run.
#
# Usage: codex-run.sh <workspace> <run-id> <task-id>
#
# Requires FORGE_LANE_RUNTIME in the environment -- the value lane-setup.sh
# printed as its last line. Recomputing it would invent a second scratch dir.
#
# Exit: 0  Codex finished of its own accord
#       2  usage
#       3  substrate — no codex, no runtime dir, no contract
#       4  env — Codex failed for a reason that is not a usage limit
#       5  env — the accumulated wait passed FORGE_QUOTA_MAX_WAIT
#
# Exit 1 remains unused, matching ADR-0010's driver convention, so a caller
# under `set -e` cannot read a park or a block as a crash.
#
# Knobs (all optional):
#   FORGE_QUOTA_PARK_PCT   used_percent at or above which a window parks  [95]
#   FORGE_QUOTA_PAD        seconds added past resets_at before waking     [90]
#   FORGE_QUOTA_MAX_WAIT   total seconds of waiting allowed; 0 = forever  [0]
#   FORGE_QUOTA_POLL       floor between attempts, and the wait when the
#                          provider gave no resets_at                     [300]
#   FORGE_QUOTA_TICK       sleep granularity, so a park stays responsive   [60]
#   FORGE_LANE_PARK_ROOT   where park records live      [~/.forge/lane-parks]
#   FORGE_CODEX_BIN        the codex binary                            [codex]
#   FORGE_CODEX_MODEL      passed through as -m                       [unset]
set -uo pipefail

[ "$#" -eq 3 ] || {
  echo "usage: codex-run.sh <workspace> <run-id> <task-id>" >&2
  exit 2
}
WS="$1" RUN_ID="$2" TASK_ID="$3"
for id in "$RUN_ID" "$TASK_ID"; do
  case "$id" in
    ""|.|..|*[!A-Za-z0-9._-]*)
      echo "usage: codex-run.sh <workspace> <safe-run-id> <safe-task-id>" >&2
      exit 2
      ;;
  esac
done

PARK_PCT="${FORGE_QUOTA_PARK_PCT:-95}"
PAD="${FORGE_QUOTA_PAD:-90}"
MAX_WAIT="${FORGE_QUOTA_MAX_WAIT:-0}"
POLL="${FORGE_QUOTA_POLL:-300}"
TICK="${FORGE_QUOTA_TICK:-60}"
PARK_ROOT="${FORGE_LANE_PARK_ROOT:-$HOME/.forge/lane-parks}"
CODEX_BIN="${FORGE_CODEX_BIN:-codex}"

# How long a park record may be adopted for. Adoption exists for a supervisor
# killed DURING a park, and that successor arrives inside the window it was
# waiting on. A record still on disk a week later is debris from a run nobody
# resumed; adopting it sends "a usage limit interrupted you, continue where you
# stopped" into a session that was abandoned, against a contract that has had a
# week to change. Not a knob: no operator should have to reason about this.
PARK_TTL=604800
# The horizon a single park may cover, matching quota-window.py's own. Every
# wake target is clamped to it, so the worst a corrupt `resets_at` can cost is
# one long sleep and a re-probe rather than a run that never returns.
WAKE_HORIZON=34560000

# Every knob is validated here, once, at startup. A knob that reads as garbage
# must not degrade quietly, and both ways it can are measured:
#
#   FORGE_QUOTA_MAX_WAIT=4h -- the obvious thing to type, and what the operator
#   guide's own paragraph invites -- makes each `[ "$MAX_WAIT" -gt 0 ]` fail
#   with `integer expression expected`, which `&&` short-circuits to false. The
#   only bound on the wait silently stops existing.
#
#   FORGE_QUOTA_PARK_PCT=high reaches `--threshold high`, argparse exits 2, the
#   verdict comes back empty, and every quota block turns into a hard env:
#   failure whose printed reason is an empty pair of parentheses.
#
# Both are usage errors, so both are answered as usage errors, by name.
_int_knob() { # name value floor
  case "$2" in
    ""|*[!0-9]*)
      echo "usage: $1 must be a whole number of seconds, got '$2'" >&2
      exit 2;;
  esac
  [ "$2" -ge "$3" ] || {
    echo "usage: $1 must be at least $3, got '$2'" >&2
    exit 2
  }
}
_int_knob FORGE_QUOTA_PAD "$PAD" 0
_int_knob FORGE_QUOTA_MAX_WAIT "$MAX_WAIT" 0
# POLL and TICK floor at 1 second, not 0: TICK=0 is a `sleep 0` hot loop in
# which TOTAL_WAITED never advances, so MAX_WAIT never fires either and the
# only escape from an unbounded park is a kill.
_int_knob FORGE_QUOTA_POLL "$POLL" 1
_int_knob FORGE_QUOTA_TICK "$TICK" 1
awk -v v="$PARK_PCT" 'BEGIN { exit !(v + 0 > 0 && v + 0 <= 100) }' 2>/dev/null || {
  echo "usage: FORGE_QUOTA_PARK_PCT must be a number in (0,100], got '$PARK_PCT'" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || {
  echo "env: lane script directory cannot be resolved"
  exit 3
}
QUOTA_WINDOW="$SCRIPT_DIR/quota-window.py"
PROGRESS="$SCRIPT_DIR/codex-progress.py"
for helper in "$QUOTA_WINDOW" "$PROGRESS"; do
  [ -x "$helper" ] || { echo "env: $helper is missing or not executable"; exit 3; }
done

command -v "$CODEX_BIN" >/dev/null 2>&1 || {
  echo "env: $CODEX_BIN is not on PATH — the implementation lane cannot run"
  exit 3
}

RUNTIME="${FORGE_LANE_RUNTIME:-}"
[ -n "$RUNTIME" ] && [ -d "$RUNTIME" ] || {
  echo "env: FORGE_LANE_RUNTIME is unset or not a directory — run lane-setup.sh first"
  exit 3
}
CONTRACT="$RUNTIME/contract.md"
[ -s "$CONTRACT" ] || { echo "env: $CONTRACT is missing or empty"; exit 3; }

# TWO logs, and the split is load-bearing. `codex-events.jsonl` is the whole
# run, append-only, for the operator and the audit trail. `codex-events.current`
# holds ONLY the attempt in flight, and it is what the quota checks read.
#
# Measured, not theorised: reading the append-only log parks forever. The
# exhausted token_count from the failed attempt stays in the file after the
# window resets, so every post-wake check re-reads "100% used", parks again,
# and the run never retries. An append-only log cannot answer a question about
# *now*.
EVENTS="$RUNTIME/codex-events.jsonl"
CURRENT="$RUNTIME/codex-events.current.jsonl"
SESSION_FILE="$RUNTIME/codex-session-id"
LAST_MESSAGE="$RUNTIME/codex-last.md"

cd "$WS" 2>/dev/null || { echo "env: workspace $WS does not exist"; exit 3; }
GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null)" || {
  echo "env: workspace $WS is not a git checkout"
  exit 3
}
GIT_COMMON="$(cd "$GIT_COMMON" && pwd -P)" || {
  echo "env: the shared git directory cannot be resolved"
  exit 3
}

mkdir -p "$PARK_ROOT" 2>/dev/null || {
  echo "env: park records cannot be written under $PARK_ROOT"
  exit 3
}

now() { date +%s; }
say() { printf '%s codex-run: %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# BSD and GNU date spell "format this epoch" differently, and on the wrong one
# `-r` means "read this file's mtime" -- so a Linux host would print the raw
# integer for the one line an operator actually reads at 3am. Try both.
fmt_epoch() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$1"
}

# JSON-escape one interpolated value. The park record declares a schema and a
# successor parses it: a `codex --version` carrying a quote, or a branch name
# carrying a backslash, must not be able to make the only route back into a
# half-finished session unreadable.
jesc() {
  printf '%s' "${1:-}" | tr -d '[:cntrl:]' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# One numeric or string field out of the park record, first occurrence only.
park_field() { # file key pattern
  sed -n "s/.*\"$2\":[[:space:]]*$3.*/\\1/p" "$1" 2>/dev/null | head -1
}

TOTAL_WAITED=0
PARKS=0

# ---------------------------------------------------------------------------
# What the provider last said about its windows.
#
# In practice this runs once, before the first attempt: every path that loops
# has just parked, and a park skips the gate because it already waited out the
# window that snapshot describes. The $CURRENT branch is kept because it is the
# correct precedence if a future caller re-gates mid-run, not because it fires
# today. Before the first attempt there is no stream, so the source is the
# newest session rollout on this machine -- the last thing Codex told anybody
# here. Tail it: rollouts reach megabytes and only the
# newest token_count matters. No source at all is `unknown`, and unknown lets
# the run start: a machine that has never run Codex has no snapshot, and
# refusing to start there would be a deadlock, not a safeguard. The reactive
# path below is what catches a limit we could not see coming.
# ---------------------------------------------------------------------------
quota_verdict() {
  local verdict
  if [ -s "$CURRENT" ]; then
    verdict="$("$QUOTA_WINDOW" --threshold "$PARK_PCT" "$CURRENT" 2>/dev/null)"
    [ -n "$verdict" ] && { printf '%s\n' "$verdict"; return 0; }
  fi
  local newest
  # Rollouts are stored as <YYYY>/<MM>/<DD>/rollout-<ISO-8601>-<uuid>.jsonl,
  # so lexicographic order IS chronological order. `xargs ls -t` was wrong
  # here: past ARG_MAX it sorts each batch separately and returns the newest
  # of the first batch, silently, once the session count grows.
  newest="$(find "${CODEX_HOME:-$HOME/.codex}/sessions" -name '*.jsonl' -type f \
              2>/dev/null | sort | tail -1)"
  if [ -n "$newest" ]; then
    verdict="$(tail -n 400 "$newest" 2>/dev/null \
                 | "$QUOTA_WINDOW" --threshold "$PARK_PCT" - 2>/dev/null)"
    [ -n "$verdict" ] && { printf '%s\n' "$verdict"; return 0; }
  fi
  printf 'unknown no-snapshot\n'
}

# Sleep until `wake_at` (+pad), or for POLL seconds when the provider gave no
# reset. Sleeps in TICK slices so a kill lands promptly and the log shows the
# park is alive rather than hung. Returns 5 if MAX_WAIT is exceeded.
park_until() {
  local wake="$1" windows="$2" target remaining
  PARKS=$((PARKS + 1))

  if [ "$wake" = unknown ]; then
    target=$(( $(now) + POLL ))
    say "PARKED on $windows; provider gave no reset time, re-probing in ${POLL}s"
  else
    target=$(( wake + PAD ))
    say "PARKED on $windows until $(fmt_epoch "$target")"
  fi
  # Never spin: a reset already in the past, or a clock ahead of the server's,
  # would otherwise re-attempt in a tight loop against a provider still saying no.
  local floor=$(( $(now) + POLL ))
  [ "$target" -lt "$floor" ] && target="$floor"
  # And never disappear. quota-window.py refuses to report an incredible reset,
  # but it is not the only thing that can put one here, and a park that outlasts
  # the operator is indistinguishable from a hang. Clamped, this costs one long
  # sleep and a re-probe; unclamped it costs the run.
  local ceiling=$(( $(now) + WAKE_HORIZON ))
  if [ "$target" -gt "$ceiling" ]; then
    say "capping an implausible wake time ($target) at $(fmt_epoch "$ceiling")"
    target="$ceiling"
  fi

  write_park_record "$wake" "$windows" "$target"
  say "PARK-COMMENT env: codex usage limit on $windows;" \
      "waiting until $target (epoch), session=${SESSION_ID:-none}," \
      "park=$PARK_ROOT/$TASK_ID.json"

  while :; do
    remaining=$(( target - $(now) ))
    [ "$remaining" -le 0 ] && break
    if [ "$MAX_WAIT" -gt 0 ] && [ "$TOTAL_WAITED" -ge "$MAX_WAIT" ]; then
      say "giving up: waited ${TOTAL_WAITED}s, over FORGE_QUOTA_MAX_WAIT=${MAX_WAIT}s"
      return 5
    fi
    [ "$remaining" -gt "$TICK" ] && remaining="$TICK"
    sleep "$remaining"
    TOTAL_WAITED=$(( TOTAL_WAITED + remaining ))
    [ $(( TOTAL_WAITED % 300 )) -lt "$TICK" ] &&
      say "still parked; $(( target - $(now) ))s to go, ${TOTAL_WAITED}s waited"
  done
  say "window reset reached; resuming"
  return 0
}

write_park_record() {
  local wake="$1" windows="$2" target="$3"
  # Keyed by TASK, not run id: a run that dies during a multi-hour park is
  # exactly the case this record exists for, and its successor has a new run
  # id. Kept outside the worktree and outside $TMPDIR for the same reason the
  # blast-radius baseline is: Codex can write both.
  #
  # Written to a sibling and renamed, never in place. `cat >` truncates first,
  # so a kill landing between the truncate and the write leaves an EMPTY record
  # -- and a supervisor killed mid-park is the precise scenario this file exists
  # to survive. rename(2) is atomic within a directory: a reader sees the whole
  # old record or the whole new one.
  local tmp="$PARK_ROOT/.$TASK_ID.json.$$"
  cat > "$tmp" << JSON
{
  "schema": "forge.park.v1",
  "task_id": "$(jesc "$TASK_ID")",
  "run_id": "$(jesc "$RUN_ID")",
  "workspace": "$(jesc "$WS")",
  "branch": "$(jesc "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)")",
  "codex_session_id": "$(jesc "${SESSION_ID:-}")",
  "codex_version": "$(jesc "$("$CODEX_BIN" --version 2>/dev/null | head -1)")",
  "blocked_windows": "$(jesc "$windows")",
  "resets_at": "$(jesc "$wake")",
  "wake_at": $target,
  "parked_at": $(now),
  "parks": $PARKS,
  "seconds_waited": $TOTAL_WAITED
}
JSON
  mv -f "$tmp" "$PARK_ROOT/$TASK_ID.json" 2>/dev/null || {
    rm -f "$tmp"
    say "WARNING: the park record could not be written to $PARK_ROOT"
  }
}

read_session_id() {
  [ -s "$SESSION_FILE" ] && SESSION_ID="$(head -1 "$SESSION_FILE" | tr -d '[:space:]')"
}

# ---------------------------------------------------------------------------
# One attempt. First attempt hands over the contract; later ones resume the
# same session, because the whole point of waiting is to keep the context.
#
# `codex exec resume` takes neither -s, -C nor --add-dir (measured against
# codex-cli 0.148 --help), so the sandbox grant that lets Codex commit inside a
# worktree cannot be restated the way §4 states it. It is passed as the
# equivalent -c overrides instead rather than trusting that a resumed session
# inherits them -- an assumption whose failure mode is a silent loss of write
# access to the shared .git, which is the defect that cost this repo a rung.
# ---------------------------------------------------------------------------
build_argv() {
  # Built as one always-non-empty array. macOS ships bash 3.2, where expanding
  # an EMPTY array under `set -u` is an unbound-variable error -- so an
  # `opts=()` holding a maybe-absent -m would abort the script on the default
  # path, where FORGE_CODEX_MODEL is unset. Never expand a possibly-empty array.
  ARGV=("$CODEX_BIN" exec)
  if [ -n "${SESSION_ID:-}" ]; then
    ARGV=("${ARGV[@]}" resume "$SESSION_ID")
  fi
  ARGV=("${ARGV[@]}" --json)
  [ -n "${FORGE_CODEX_MODEL:-}" ] && ARGV=("${ARGV[@]}" -m "$FORGE_CODEX_MODEL")

  if [ -n "${SESSION_ID:-}" ]; then
    # `codex exec resume` accepts neither -s, -C nor --add-dir (measured
    # against codex-cli 0.148 `--help`), so §4's sandbox grant cannot be
    # restated the way §4 states it. Pass the equivalent -c overrides rather
    # than trusting a resumed session to inherit them: the failure mode of that
    # assumption is silent loss of write access to the shared .git, which is
    # the defect that cost this repo a rung to find the first time.
    ARGV=("${ARGV[@]}"
          -c 'sandbox_mode="workspace-write"'
          -c "sandbox_workspace_write.writable_roots=[\"$GIT_COMMON\"]"
          --output-last-message "$LAST_MESSAGE"
          "$RESUME_PROMPT")
  else
    ARGV=("${ARGV[@]}"
          -C "$WS"
          -s workspace-write
          --add-dir "$GIT_COMMON"
          --output-last-message "$LAST_MESSAGE"
          "$(cat "$CONTRACT")")
  fi
}

RESUME_PROMPT="A provider usage limit interrupted the previous turn. Nothing you
did caused it and nothing about the contract has changed. Continue where you
stopped: re-read the working tree to see what is already done, then finish the
contract. Do not start over and do not revert your own earlier work."

# One attempt. A straight pipeline, so PIPESTATUS reads codex's exit code and
# not tee's or the condenser's -- process substitution plus `wait` does not
# reliably do that on bash 3.2.
attempt_once() {
  local rc
  : > "$CURRENT"
  build_argv
  if [ -n "${SESSION_ID:-}" ]; then
    say "resuming session $SESSION_ID (attempt $ATTEMPT)"
  else
    say "starting codex (attempt $ATTEMPT)"
  fi
  UV_CACHE_DIR="$FORGE_LANE_RUNTIME/uv-cache" "${ARGV[@]}" < /dev/null \
    | tee -a "$EVENTS" \
    | tee "$CURRENT" \
    | "$PROGRESS" --session-id-file "$SESSION_FILE"
  rc="${PIPESTATUS[0]}"
  read_session_id
  return "$rc"
}

SESSION_ID=""
ATTEMPT=0
JUST_PARKED=no
read_session_id

# A supervisor killed during a multi-hour park leaves the run to a successor
# with a NEW run id and therefore a new, empty scratch directory -- so the
# session id is gone from where this run would look for it. The park record is
# keyed by task for exactly this: adopt its session id and continue the same
# Codex session instead of paying for the comprehension twice. Only when the
# workspace matches; a record pointing somewhere else is evidence of a moved
# card, not an invitation to resume into the wrong tree.
if [ -z "$SESSION_ID" ] && [ -s "$PARK_ROOT/$TASK_ID.json" ]; then
  PARK_FILE="$PARK_ROOT/$TASK_ID.json"
  parked_ws="$(park_field "$PARK_FILE" workspace '"\([^"]*\)"')"
  parked_session="$(park_field "$PARK_FILE" codex_session_id '"\([^"]*\)"')"
  parked_at="$(park_field "$PARK_FILE" parked_at '\([0-9][0-9]*\)')"
  park_age=-1
  [ -n "$parked_at" ] && park_age=$(( $(now) - parked_at ))
  if [ -z "$parked_session" ]; then
    :
  elif [ "$parked_ws" != "$WS" ]; then
    say "ignoring park record: it names workspace $parked_ws, not $WS"
  elif [ "$park_age" -lt 0 ]; then
    # No readable parked_at means no way to tell a live park from debris, and
    # the safe direction is to pay comprehension once more rather than resume
    # into a session that may be arbitrarily old.
    say "ignoring park record: it carries no readable parked_at"
  elif [ "$park_age" -gt "$PARK_TTL" ]; then
    say "ignoring park record: parked ${park_age}s ago, past the ${PARK_TTL}s adoption window"
  else
    SESSION_ID="$parked_session"
    say "adopting session $SESSION_ID from the park record left by an earlier run"
  fi
fi

while :; do
  ATTEMPT=$((ATTEMPT + 1))

  # Pre-emptive: decide BEFORE spawning Codex, which is the only boundary in a
  # chunk where nothing has been mutated and a stop costs nothing.
  if [ "$JUST_PARKED" = yes ]; then
    JUST_PARKED=no
    say "pre-flight: skipped — the window this run waited on has just reset"
    verdict="clear"
  else
    verdict="$(quota_verdict)"
  fi
  case "$verdict" in
    blocked*)
      wake="${verdict#*wake_at=}"; wake="${wake%% *}"
      windows="${verdict#*windows=}"; windows="${windows%% *}"
      say "pre-flight: $verdict"
      park_until "$wake" "$windows" || {
        echo "env: codex usage limit on $windows; waited ${TOTAL_WAITED}s," \
             "over FORGE_QUOTA_MAX_WAIT=${MAX_WAIT}s; park record at" \
             "$PARK_ROOT/$TASK_ID.json"
        exit 5
      }
      JUST_PARKED=yes
      continue
      ;;
    unknown*)
      say "pre-flight: $verdict (proceeding; no snapshot to judge)"
      ;;
  esac

  # Captured explicitly: `$?` read after a completed `if` is the status of the
  # `if` itself, which is 0 whenever the condition merely tested false. That
  # reported every usage-limit exit as "codex exited 0".
  attempt_once
  rc=$?
  if [ "$rc" -eq 0 ]; then
    say "codex finished cleanly after $ATTEMPT attempt(s), ${TOTAL_WAITED}s waited"
    # Unconditionally, not `[ "$PARKS" -gt 0 ]`. A run that ADOPTED a record
    # never parks itself, so the guarded form left the record on disk after a
    # clean finish -- and the next run on that card would adopt a session that
    # had already completed, sending it "a usage limit interrupted you" against
    # a contract that has since moved on. The task is done; the record is spent.
    rm -f "$PARK_ROOT/$TASK_ID.json"
    exit 0
  fi

  # Reactive: the limit landed mid-turn. Ask the stream it just wrote, not a
  # guess about the exit code -- codex returns non-zero for many reasons and
  # only one of them is worth waiting out.
  #
  # $CURRENT, never $EVENTS. This is the same rule the pre-flight gate follows
  # and the reason the two logs exist: the append-only log still holds the
  # exhausted token_count and the usage_limit_reached marker from attempt 1, so
  # asking IT after attempt 2 fails for an unrelated reason -- a dropped
  # connection, an expired token -- reports a limit that is no longer real and
  # parks on a window the provider now says is 5% used. Nothing bounds that by
  # default. An append-only log cannot answer a question about *now*.
  verdict="$("$QUOTA_WINDOW" --threshold "$PARK_PCT" "$CURRENT" 2>/dev/null)"
  case "$verdict" in
    blocked*)
      wake="${verdict#*wake_at=}"; wake="${wake%% *}"
      windows="${verdict#*windows=}"; windows="${windows%% *}"
      say "codex exited $rc on a usage limit: $verdict"
      park_until "$wake" "$windows" || {
        echo "env: codex usage limit on $windows; waited ${TOTAL_WAITED}s," \
             "over FORGE_QUOTA_MAX_WAIT=${MAX_WAIT}s; park record at" \
             "$PARK_ROOT/$TASK_ID.json"
        exit 5
      }
      JUST_PARKED=yes
      ;;
    *)
      say "codex exited $rc and the stream shows no usage limit ($verdict)"
      rm -f "$PARK_ROOT/$TASK_ID.json"
      echo "env: codex exec exited $rc for a reason that is not a usage limit;" \
           "see $EVENTS"
      exit 4
      ;;
  esac
done
