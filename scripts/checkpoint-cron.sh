#!/usr/bin/env bash
# =============================================================================
# forge checkpoint-cron — the cron job that runs the milestone checkpoint (epic MS4, decision 13, S8d).
#
#   hermes cron create 'every 15m' --name forge-checkpoint --no-agent \
#     --script forge-checkpoint.sh --deliver telegram --paused
#
# `--script` names a real file under ~/.hermes/scripts that `exec`s this one through ~/.forge/repo (a symlink is
# refused, P22), and cron hands it NO arguments. scripts/checkpoint.sh cannot be that job as it is: it needs a
# project, a board and a gate, it exits 2 for an unfinished milestone (the normal state for days), and under
# `--no-agent` any non-zero exit sends a "script failed" alert. This script is the adapter, and `--no-agent` runs
# no model: the overseer proposes, this runs the program (decision 13).
#
# THE ARMING FILE IS THE SWITCH. It looks only at gates with a file in <state>/checkpoint/armed/ (scripts/
# checkpoint-arm.sh makes them). No file: it does nothing, says nothing, exits 0. A file that is not exactly the
# two well-formed lines reads as no file (one message, then silence). Mode `rehearse` runs checkpoint.sh
# --rehearse, which writes nothing anywhere; mode `apply` runs --apply, which completes the gate on a pass.
# GATE-M1 is armed apply only at the owner's go for run B; the job is created --paused.
#
# SILENT UNLESS IT HAS SOMETHING TO DECIDE. Under --no-agent stdout IS the message, so every standing condition
# is reported once and then not again, and the exit is 0:
#   - the gate is not blocked, or any chunk of its milestone is not done: nothing, ever, until it is;
#   - the gate was decided for this hold (a /park or /redirect): nothing;
#   - the product checkout is dirty or not on main: said once per reason;
#   - a checkpoint it ran for this gate, this hold and this checkout HEAD: not run again;
#   - a block (exit 1) is delivered once per hold per text, and recorded in <state>/checkpoint/pending/ with the
#     hold's id, which is what /accept, /redirect answer (scripts/gate-reply.sh);
#   - a pass is delivered once. Under `apply` the gate is then done and the file is removed;
#   - no verdict (exit 2) is delivered when its text changes, and not marked probed, so it is retried.
# Non-zero is for the job's own faults only (a tool is missing, the state cannot be written, checkpoint.sh did
# something it never does): they go to stderr and exit 2.
#
# Usage (cron passes nothing):
#   scripts/checkpoint-cron.sh
#   scripts/checkpoint-cron.sh --check     are the tools here? (preflight)
# =============================================================================
set -uo pipefail

gr_help() { awk 'NR>2 && /^# ={10,}/{exit} NR>2 {sub(/^# ?/, ""); print}' "$0"; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || { echo "checkpoint-cron: script directory cannot be resolved" >&2; exit 2; }
# shellcheck source=gate-reply.sh
. "$HERE/gate-reply.sh" || { echo "checkpoint-cron: cannot source gate-reply.sh" >&2; exit 2; }

fault() { echo "checkpoint-cron: $*" >&2; FAULT=1; }
FAULT=0
case "${1:-}" in
  --check)
    miss=""
    for t in sqlite3 jq git shasum; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
    [ -x "$HERE/checkpoint.sh" ] || miss="$miss checkpoint.sh"
    [ -z "$miss" ] || { echo "checkpoint-cron: the host is missing:$miss" >&2; exit 2; }
    echo "ok: the host can run this"; exit 0;;
  -h|--help) gr_help; exit 0;;
  "") ;;
  *) echo "checkpoint-cron: takes no arguments from cron" >&2; exit 2;;
esac

for t in sqlite3 jq git shasum; do command -v "$t" >/dev/null 2>&1 || { fault "$t is not on PATH"; exit 2; }; done
[ -x "$HERE/checkpoint.sh" ] || { fault "checkpoint.sh is not beside this script"; exit 2; }

STATE="$(gr_state_dir)"
[ -d "$STATE/armed" ] || exit 0          # nothing was ever armed: silent, exit 0
ls "$STATE/armed" 2>/dev/null | grep -qv '^\.tmp\.' || exit 0

# One tick at a time: a probe can outlast the interval. A lock older than two hours is a dead tick's.
if ! mkdir "$STATE/lock" 2>/dev/null; then
  if [ -n "$(find "$STATE/lock" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
    rmdir "$STATE/lock" 2>/dev/null && mkdir "$STATE/lock" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
OUT="$(mktemp "${TMPDIR:-/tmp}/forge-checkpoint-cron.XXXXXX")" || { rmdir "$STATE/lock" 2>/dev/null; exit 2; }
cleanup() { rm -f "$OUT"; gr_cleanup; rmdir "$STATE/lock" 2>/dev/null; return 0; }
trap cleanup EXIT
mkdir -p "$STATE/pending" "$STATE/decided" "$STATE/probed" "$STATE/reported" 2>/dev/null \
  || { fault "cannot write under $STATE"; exit 2; }

sha() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }
# say <text>: a message for the operator. Messages are separated by a blank line.
say() { [ ! -s "$OUT" ] || echo >> "$OUT"; printf '%s\n' "$1" >> "$OUT"; }
# report_once <key> <text>: say it unless the same text was the last thing said under this key.
report_once() {
  local key="$1" text="$2" f="$STATE/reported/$1" now
  now="$(sha "$text")"
  [ "$(cat "$f" 2>/dev/null)" != "$now" ] || return 0
  if printf '%s' "$now" > "$f" 2>/dev/null; then say "$text"; else fault "cannot write $f"; fi
}

for armed in "$STATE"/armed/*; do
  [ -e "$armed" ] || [ -L "$armed" ] || continue
  name="${armed##*/}"
  case "$name" in .tmp.*) continue;; esac
  board="${name%%--GATE-*}"; gate="GATE-${name#*--GATE-}"
  if ! { [[ $board =~ $GR_BOARD_RE ]] && [[ $gate =~ $GR_GATE_RE ]] && [ "$name" = "$(gr_key "$board" "$gate")" ]; }; then
    report_once "armed-name-$(sha "$name")" "checkpoint: the arming file '$name' is not <board>--GATE-<m>, so nothing is armed by it."
    continue
  fi
  key="$name"
  # THE ARMING FILE IS WHAT MAKES ANYTHING HAPPEN: malformed reads as not armed.
  if ! gr_read_armed "$board" "$gate"; then
    report_once "$key.malformed" "checkpoint: the arming file for $gate on board $board is malformed, so the gate is NOT armed (it must be exactly mode=rehearse|apply and project=/abs/path). Arm it again with scripts/checkpoint-arm.sh."
    continue
  fi
  mode="$GR_ARM_MODE"; project="$GR_ARM_PROJECT"

  gr_try_load_gate "$board" "$gate"; lrc=$?
  if [ "$lrc" = 2 ]; then fault "$GR_WHY"; continue; fi
  if [ "$lrc" = 1 ]; then
    # Not blocked (done, ready, running ...) or no such card: there is no hold to look at. A missing card or
    # board is said once, because an armed gate that cannot exist is a mistake; a gate merely not held is not.
    case "$GR_WHY" in
      *"no card for"*|*"no board named"*|*"more than one card"*) report_once "$key.missing" "checkpoint: $GR_WHY, so the armed gate $gate cannot be checked.";;
    esac
    continue
  fi
  hold="$GR_HOLD"; card="$GR_CARD"

  # Silent while the milestone is unfinished: any chunk that is not done (an archived one is not a chunk).
  open="$(sqlite3 "$GR_SNAP" "SELECT count(*) FROM tasks t JOIN task_links l ON l.parent_id = t.id
            WHERE l.child_id = '$card' AND t.status NOT IN ('done', 'archived');" 2>/dev/null)" \
    || { fault "the chunks of $gate could not be read"; continue; }
  total="$(sqlite3 "$GR_SNAP" "SELECT count(*) FROM tasks t JOIN task_links l ON l.parent_id = t.id
            WHERE l.child_id = '$card' AND t.status <> 'archived';" 2>/dev/null)" \
    || { fault "the chunks of $gate could not be read"; continue; }
  [ "$open" = 0 ] && [ "${total:-0}" -gt 0 ] 2>/dev/null || continue

  # A decision for this hold (a /park or a /redirect) stops the cron for it.
  if jq -e --argjson h "$hold" '.hold == $h' "$STATE/decided/$key.json" >/dev/null 2>&1; then continue; fi

  # The product checkout: on main, clean. A probe of anything else says nothing about the milestone.
  if [ ! -d "$project/.git" ] && ! git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    report_once "$key.project" "checkpoint: the project $project for $gate is not a git checkout, so it was not probed."
    continue
  fi
  branch="$(git -C "$project" symbolic-ref --short HEAD 2>/dev/null)"
  if [ "$branch" != main ]; then
    report_once "$key.project" "checkpoint: the project $project for $gate is on '${branch:-a detached HEAD}', not main, so it was not probed."
    continue
  fi
  if [ -n "$(git -C "$project" status --porcelain 2>/dev/null)" ]; then
    report_once "$key.project" "checkpoint: the project $project for $gate has uncommitted changes, so it was not probed (a probe of unmerged work says nothing about the milestone)."
    continue
  fi
  head="$(git -C "$project" rev-parse HEAD 2>/dev/null)"
  [ -n "$head" ] || { fault "cannot read HEAD of $project"; continue; }
  probed="$STATE/probed/$key--$hold--$head"
  [ ! -e "$probed" ] || continue

  flag=--rehearse; [ "$mode" = apply ] && flag=--apply
  run_out="$("$HERE/checkpoint.sh" "$project" --board "$board" --gate "$gate" "$flag" 2>"$GR_WORK/checkpoint.err")"; rc=$?
  case "$rc" in
    0)
      : > "$probed"
      say "$run_out"
      [ "$mode" != apply ] || rm -f "$armed" 2>/dev/null;;
    1)
      : > "$probed"
      printf '{"schema":"forge.checkpoint-pending.v1","board":"%s","gate":"%s","card":"%s","hold":%s,"outcome":"block","at":%s}\n' \
        "$board" "$gate" "$card" "$hold" "$(date +%s)" > "$STATE/pending/$key.json.tmp" \
        && mv -f "$STATE/pending/$key.json.tmp" "$STATE/pending/$key.json" \
        || { fault "cannot record the block for $gate"; continue; }
      report_once "$key.block.$hold" "$run_out";;
    2)
      report_once "$key.noverdict" "$run_out";;
    *)
      fault "checkpoint.sh exited $rc for $gate on board $board: $(tail -n 3 "$GR_WORK/checkpoint.err" | tr '\n' ' ')";;
  esac
done

[ ! -s "$OUT" ] || cat "$OUT"
[ "$FAULT" = 0 ] || exit 2
exit 0
