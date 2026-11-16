#!/usr/bin/env bash
# =============================================================================
# forge run-watch — the push half of an unattended run: a message when something NEW needs you.
#
# The build loop takes minutes (the lane 3-4, the verifier 3-8) and nothing told the operator a hold had
# appeared, a chunk had landed or a worker had stopped moving: the daily digest comes once a day and
# `forge status` has to be asked. This is the cron job that asks for them, every ten minutes:
#
#   ~/.hermes/scripts/forge-run-watch.sh     a FILE (Hermes refuses a symlink, P22), whose body is
#       exec bash "$HOME/.forge/repo/scripts/run-watch.sh" "$@"
#   hermes cron create 'every 10m' --name forge-run-watch --no-agent --script forge-run-watch.sh --deliver telegram
#
# `--no-agent` runs no model: stdout IS the message, an empty stdout sends nothing (the merge-watcher's and the
# checkpoint cron's pattern). READ-ONLY on the boards, on Hermes' config and on GitHub: every board is read
# through scripts/board-snapshot.sh, the one WAL-safe read, and the only thing written is this script's own
# state, <forge state root>/run-watch/<board>.json, by tmp + mv AFTER the message has been printed. The
# script compares each board with what it recorded on its previous tick and prints one short block per NEW event:
#
#   WAITING ON YOU   a card entered the set `forge status` calls "waiting on you" (scripts/decision-message.sh's
#                    forge_waiting_sql: the same query `forge status` and the digest run). Reported once per
#                    hold: the key is the card and the id of its latest blocked / block_loop_detected / gave_up
#                    event, so a card that is unblocked and holds again is reported again. A card the dispatcher
#                    blocked after a crash or a timeout says "the worker gave up" and the error it recorded.
#   IN TRIAGE        the same set, for a CHUNK-* card whose status is `triage`: the kernel sends a card there
#                    on its second block of one kind, nothing dispatches it and `unblock` is refused. Says the
#                    reason of its last hold and the one command that takes it out (`specify`). Once, like a hold.
#   LANDED           a CHUNK-* or GATE-* card is newly done: its title, the first line of its result (the
#                    merge-watcher writes "NOT a verified merge" there on head drift) and the PR.
#   STALL            a card has been `running` for more than FORGE_RUN_WATCH_RUNNING_MAX_MIN minutes (default
#                    45), by its open run's start (its latest claim, or the first tick that saw it, when it has no
#                    open run row). Once per run, again every FORGE_RUN_WATCH_REMIND_MIN (180)
#                    while it lasts. A park record (lane-parks/<card>.json) says it is waiting on a quota.
#   NOT STARTING     a card is `ready` (not on the human-handoff sentinel, which "waiting" covers) or in
#                    `review`, with no open run, for more than FORGE_RUN_WATCH_IDLE_MAX_MIN minutes (30) as
#                    this script has seen it, AND no card is running on ANY board (Hermes runs one worker at a
#                    time host-wide, so a card queued behind a running one is normal; its clock starts when nothing
#                    runs). Once per card and entry into the status. A card the dispatcher is holding on purpose
#                    (a respawn guard in the last 15 minutes) says why instead of "nothing picks it up". Never said
#                    while a board could not be read.
#   CHECKPOINT CRON  a gate is armed (scripts/checkpoint-arm.sh list) while the cron job forge-checkpoint is
#                    missing or paused in <HERMES_HOME>/cron/jobs.json: nothing would complete the gate.
#   WATCHDOG SILENT  the launchd watchdog (scripts/watchdog.sh) checks that this cron's tickers are fresh, and this
#                    is the other direction: its log has not been written for more than 30 minutes (the reading
#                    and the limit are forge-state.sh's, the ones `forge status` uses), or is missing or
#                    unreadable. Said once, at once (no baseline), then WATCHDOG BACK once when a reading
#                    returns, and nothing in between. Only on a host where the watchdog is installed (its
#                    LaunchAgent plist exists): a host without one is never told its watchdog is silent.
#   <board>: cannot be read   a board that could not be snapshotted or queried. Said once per occurrence;
#                    its previous state is kept, so what happened meanwhile is reported when it can be read.
#
# THE FIRST TICK FOR A BOARD (no recorded state) says what already waits on you, once, so a board created minutes
# ago does not hide its first hold until the digest, and records everything else (landings, runs, idle cards) as a
# baseline without a word. The checkpoint cron check has no baseline: a gate armed with no job to run it is said at
# once. A message over 3,500 characters (Telegram's limit is 4,096) keeps its first blocks and ends "and N more -
# run: forge status"; the cut ones count as seen. If the state cannot be written (a full disk, a read-only
# directory) the same message repeats every tick and the cron reports a failure: that is deliberate, since a
# watcher that cannot remember what it said is better loud than silent.
#
# Usage:
#   run-watch.sh              one tick (cron passes no arguments)
#   run-watch.sh --dry-run    print what would be sent and write no state (a board with no recorded state is
#                             said on stderr)
# Exit: 0 whenever it ran to the end, with or without a message (a non-zero exit makes the cron report a
#       failure), 2 a usage error, a knob that is not a number, or a host that cannot run it at all: a tool
#       missing, or a state directory that cannot be written (stderr says which; sending the same message
#       every ten minutes would be worse).
# Environment: HERMES_HOME, HERMES_KANBAN_HOME, FORGE_STATE_ROOT and FORGE_HANDOFF_SENTINEL as `forge status`
# reads them; FORGE_RUN_WATCH_RUNNING_MAX_MIN, _REMIND_MIN, _IDLE_MAX_MIN as above; FORGE_LANE_PARK_ROOT
# (default <forge state root>/lane-parks). FORGE_RUN_WATCH_NOW (epoch seconds) is a test seam, not a knob.
# =============================================================================
set -uo pipefail

# Resolve through symlinks FIRST (the siblings live beside the TARGET), as digest.sh does.
_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in /*) _self="$_link";; *) _self="$(dirname "$_self")/$_link";; esac
done
HERE="$(cd "$(dirname "$_self")" 2>/dev/null && pwd -P)" \
  || { echo "run-watch: script directory cannot be resolved" >&2; exit 2; }
# shellcheck source=forge-state.sh
. "$HERE/forge-state.sh" || { echo "run-watch: cannot source forge-state.sh beside itself" >&2; exit 2; }
# shellcheck source=decision-message.sh
. "$HERE/decision-message.sh" || { echo "run-watch: cannot source decision-message.sh beside itself" >&2; exit 2; }

DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    -h|--help) awk 'NR>2 && /^# ={10,}/{exit} NR>2 {sub(/^# ?/,""); print}' "$0"; exit 0;;
    *) echo "run-watch: unknown argument '$1' (usage: run-watch.sh [--dry-run])" >&2; exit 2;;
  esac
done
for tool in sqlite3 jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "run-watch: $tool is not on PATH" >&2; exit 2; }
done

knob() {  # name default -> the value, or fails for one that is not a whole number
  local v="${!1:-$2}"
  case "$v" in ''|*[!0-9]*) echo "run-watch: $1 must be a whole number of minutes, got '$v'" >&2; return 1;; esac
  printf '%s' "$((10#$v))"
}
RUN_MAX_MIN="$(knob FORGE_RUN_WATCH_RUNNING_MAX_MIN 45)" || exit 2
REMIND_MIN="$(knob FORGE_RUN_WATCH_REMIND_MIN 180)" || exit 2
IDLE_MAX_MIN="$(knob FORGE_RUN_WATCH_IDLE_MAX_MIN 30)" || exit 2
NOW="${FORGE_RUN_WATCH_NOW:-$(date +%s)}"
case "$NOW" in ''|*[!0-9]*) echo "run-watch: FORGE_RUN_WATCH_NOW must be epoch seconds, got '$NOW'" >&2; exit 2;; esac
NOW=$((10#$NOW))

HERMES_ROOT="${HERMES_HOME:-${HOME:-}/.hermes}"
KANBAN_ROOT="${HERMES_KANBAN_HOME:-$HERMES_ROOT/kanban}"
SENTINEL_SQL="$(printf '%s' "${FORGE_HANDOFF_SENTINEL:-forge-operator-handoff}" | sed "s/'/''/g")"
HOLD_SQL="$(printf '%s' "$INTERACTIVE_HOLD_REASON" | sed "s/'/''/g")"
STATE_DIR="$(forge_run_watch_root)"
PARK_ROOT="${FORGE_LANE_PARK_ROOT:-$(forge_state_root)/lane-parks}"
MAX_CHARS=3500

if [ "$DRY" = 0 ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null && [ -w "$STATE_DIR" ] \
    || { echo "run-watch: the state directory $STATE_DIR cannot be written" >&2; exit 2; }
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-run-watch.XXXXXX")" || { echo "run-watch: cannot make a temporary directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# What one board says now: one JSON object. `waiting` is the shared query; the rest is this script's own.
# ---------------------------------------------------------------------------
board_sql() {
  cat <<SQL
SELECT json_object(
  'running', (SELECT COUNT(*) FROM tasks WHERE status = 'running'),
  'waiting', $(forge_waiting_sql "$SENTINEL_SQL" "$HOLD_SQL"),
  'running_cards', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'who', who, 'run', run, 'since', since)), json_array())
                      FROM (SELECT t.id, t.title,
                                   COALESCE((SELECT r.profile FROM task_runs r WHERE r.task_id = t.id AND r.ended_at IS NULL
                                              ORDER BY r.started_at DESC, r.id DESC LIMIT 1), t.assignee) AS who,
                                   (SELECT r.id FROM task_runs r WHERE r.task_id = t.id AND r.ended_at IS NULL
                                     ORDER BY r.started_at DESC, r.id DESC LIMIT 1) AS run,
                                   COALESCE((SELECT r.started_at FROM task_runs r WHERE r.task_id = t.id AND r.ended_at IS NULL
                                              ORDER BY r.started_at DESC, r.id DESC LIMIT 1),
                                            (SELECT MAX(e.created_at) FROM task_events e WHERE e.task_id = t.id AND e.kind = 'claimed')) AS since
                              FROM tasks t WHERE t.status = 'running' ORDER BY t.id)),
  'idle_cards', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'status', status, 'runs', runs, 'guard', guard)), json_array())
                   FROM (SELECT t.id, t.title, t.status, (SELECT COUNT(*) FROM task_runs r WHERE r.task_id = t.id) AS runs,
                                (SELECT COALESCE(CASE WHEN json_valid(g.payload) THEN json_extract(g.payload,'\$.reason') END, 'no reason recorded')
                                   FROM task_events g
                                  WHERE g.task_id = t.id AND g.kind = 'respawn_guarded' AND g.created_at > $((NOW - 900))
                                  ORDER BY g.created_at DESC, g.id DESC LIMIT 1) AS guard
                           FROM tasks t
                          WHERE (t.status = 'review' OR (t.status = 'ready' AND t.assignee IS NOT '$SENTINEL_SQL'))
                            AND NOT EXISTS (SELECT 1 FROM task_runs r WHERE r.task_id = t.id AND r.ended_at IS NULL)
                          ORDER BY t.id)),
  'done', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'result', result, 'pr', pr)), json_array())
             FROM (SELECT t.id, t.title, t.result,
                          (SELECT json_extract(r.metadata,'\$.pr') FROM task_runs r
                            WHERE r.task_id = t.id AND json_type(r.metadata,'\$.pr') = 'text'
                            ORDER BY r.started_at DESC, r.id DESC LIMIT 1) AS pr
                     FROM tasks t
                    WHERE t.status = 'done' AND (t.title GLOB 'CHUNK-*' OR t.title GLOB 'GATE-*')
                    ORDER BY t.id))
);
SQL
}

# ---------------------------------------------------------------------------
# The comparison, one board at a time, in jq: no associative arrays in bash 3.2, and the previous state is data.
# Inputs: $cur (this tick's reading) and $oldf (the recorded state, or null), the clock, the thresholds, the
# park records, the class -> reply table, and whether any card runs anywhere. Output: {events, state}.
# ---------------------------------------------------------------------------
read -r -d '' DIFF_JQ <<'JQ'
def clean: gsub("[[:cntrl:]]+"; " ") | gsub("^ +| +$"; "");
def short($n): clean | if length > $n then .[0:$n-1] + "…" else . end;
def firstline: (split("\n")[0] // "");
def mins($s): (($s / 60) | floor);
def utc: strftime("%Y-%m-%d %H:%M UTC");
def inn($a): . as $x | any($a[]; . == $x);
def why: if .status == "ready" then "sent back for changes (a human chunk)"
         else ((.reason // "") | firstline | clean) as $r
              | if $r != "" then $r elif .status == "triage" then "in triage" else "blocked, no reason recorded" end end;
# A chunk the kernel routed to `triage` (a second block of one kind, docs/hermes-field-notes.md): it is not a
# hold, since nothing the hold's own reply names works on it. Follow-up cards are born in triage and are not this.
def stranded: .status == "triage" and ((.title // "") | test("^CHUNK-"));
# The command that resolves a card: its own Reply line when its reason is a decision-first hold, else the class
# table's (scripts/decision-message.sh, handed in as $replies), else the `other` entry.
def reply($board):
  . as $card
  | (if $card.status == "ready" then "the reasons are on the card: hermes kanban --board \($board) show \($card.id)"
     elif $card.gave_up == 1 then "read the error, fix it, then: hermes kanban --board \($board) unblock \($card.id)"
     elif $card.status != "triage" and (($card.reason // "") | test("(^|\n)Decision needed: ")) then
       (($card.reason | split("\n") | map(select(startswith("Reply: "))) | .[0] // "") | ltrimstr("Reply: "))
     else "" end) as $own
  | (if $own != "" then $own
     else (($card.reason // "") as $r
           | (if $card.status != "triage" and ($r | contains(":")) then ($r | split(":")[0]) else "other" end) as $cl
           | if ($replies[$cl] // null) != null then $replies[$cl] else ($replies["other"] // "hermes kanban --board <board> show <id>") end)
     end)
  | gsub("<id>"; $card.id) | gsub("<board>"; $board);

($cur[0]) as $c
| ($oldf[0]) as $old
| ((($old | type) == "object") and (($old.waiting | type) == "array")) as $had
| ($run_max * 60) as $run_secs | ($remind * 60) as $remind_secs | ($idle_max * 60) as $idle_secs

# WAITING ON YOU: the key is the card, its status and the newest event that put it in the operator's hands (a bounce
# writes no `blocked` event, so the hold alone cannot tell one waiting from the next)
| ($c.waiting | map(. + {key: "\(.id):\(.status):\(.sig // 0)"})) as $wait
| ($old.waiting // []) as $ow
| ($wait | map(select(.key | inn($ow) | not))) as $newwait

# LANDED: a CHUNK or GATE that is done now and was not on the last tick
| ($c.done | map(.id)) as $doneids
| ($old.landed // []) as $ol
| ($c.done | map(select(.id | inn($ol) | not))) as $newdone

# STALL: the key is the open run; reported again after the reminder interval. A running card with no open run row
# counts from its latest claim, and failing that from the first tick that saw it running.
| ($old.rsince // {}) as $orsince
| ($c.running_cards | map(. + {since: (.since // $orsince[.id] // $now)})) as $running
| ($running | map(select(($now - .since) > $run_secs
                          # a review asleep on the Claude usage limit is waiting, by its own record, until a time
                          # it names (scripts/prejudge-review.sh); it is bounded there, and not a stall
                          and (($jwaits[.id].until // 0) <= $now))
                  | . + {key: "\(.id):\(.run // .since)"})) as $stalled
| ($old.stalls // {}) as $os
| ($stalled | map(select(($os[.key] // null) == null or ($now - $os[.key]) >= $remind_secs))) as $stallnow

# NOT STARTING: how long this script has SEEN the card idle in this status; once per entry, never while a worker runs anywhere
| ($c.idle_cards | map(. + {key: "\(.id):\(.status):\(.runs)"})) as $idle
| ($old.idle // {}) as $oi
| ($old.idle_reported // []) as $orep
| ($idle | map(. + {since: (if $any_running then $now else ($oi[.key] // $now) end)})) as $idle2
| ($idle2 | map(select(($now - .since) > $idle_secs and (.key | inn($orep) | not)))) as $eligible
| (if $any_running then [] else $eligible end) as $idlenow

| ( ($newwait | map({rank: 1, text: (if stranded
       then "IN TRIAGE: \(.id) on \($board)\n\(.title | short(90))\n"
            + "Last hold: \(((.reason // "") | firstline | clean) as $r | if $r == "" then "no reason recorded" else ($r | short(160)) end)\n"
            + "Nothing dispatches a card in triage, and unblock and complete are refused there.\n"
            + "Do: hermes kanban --board \($board) specify \(.id) (the one way out: back to todo, for its implementer)"
       else "WAITING ON YOU: \(.id) on \($board)\n\(.title | short(90))\n\(why | short(200))\nDo: \(reply($board) | short(280))" end)}))
   + (if $had then
     ( ($stallnow | map(. as $s | ($os[$s.key] // null) as $before | ($parks[$s.id] // null) as $p
         | {rank: 2, text: ("\(if $before != null then "STILL STALLED" else "STALL" end): \($s.id) on \($board)\n\($s.title | short(90))\n"
              + "Running \(mins($now - $s.since)) min on \($s.who // "an unknown profile"), over the \($run_max) min limit."
              + (if $p == null then ""
                 elif ($p.until | type) != "number" then "\nA quota park record exists for it."
                 elif $p.until > $now then "\nParked for quota until \($p.until | utc)\(if ($p.windows // "") != "" then " (\($p.windows | short(60)))" else "" end)."
                 else "\nIts quota park record ended at \($p.until | utc); it has not moved since." end)
              + "\nDo: hermes kanban --board \($board) show \($s.id)")}))
     + ($idlenow | map({rank: 3, text: ("NOT STARTING: \(.id) on \($board)\n\(.title | short(90))\n"
              + (if .status == "review" then "In review" else "Ready" end) + " for \(mins($now - .since)) min"
              + (if .guard != null
                 then ", and the dispatcher is holding it: \(.guard | short(80))."
                 else " with no worker, and nothing else is running on any board." end)
              + "\nDo: forge status \($board)")}))
     + ($newdone | map(. as $d | (($d.result // "") | firstline | clean) as $r
         | {rank: 5, text: ("LANDED: \($d.id) on \($board)\n\($d.title | short(90))"
              + (if $r != "" then "\n\($r | short(300))" else "" end)
              + (if ($r | test("NOT a verified merge")) and (($r | short(300)) | test("NOT a verified merge") | not)
                 then "\nNOT a verified merge: the code that landed is not what the verifier reviewed." else "" end)
              + (if ($d.pr // "") != "" and ($r | contains($d.pr) | not) then "\nPR: \($d.pr)" else "" end))}))
     ) else [] end)) as $events

| { events: $events,
    state: { schema: "forge.run-watch.v1", at: $now,
             waiting: ($wait | map(.key)),
             landed: $doneids,
             stalls: ($stalled | map(. as $s | {key: $s.key, value: (if ($stallnow | any(.key == $s.key)) then $now else $os[$s.key] end)}) | from_entries),
             rsince: ($c.running_cards | map(select(.since == null) | {key: .id, value: ($orsince[.id] // $now)}) | from_entries),
             idle: ($idle2 | map({key: .key, value: .since}) | from_entries),
             idle_reported: ([$orep[] | select(inn($idle | map(.key)))] + ($idlenow | map(.key))) } }
JQ

# The assembly: every event of every board, most urgent first, as one message that fits.
read -r -d '' FIT_JQ <<'JQ'
(add // []) | to_entries | sort_by([.value.rank, .key]) | map(.value.text) as $t
| reduce range(0; $t | length) as $i ({out: [], len: 0, cut: 0};
    ($t[$i] | length) as $l | (if (.out | length) == 0 then 0 else 2 end) as $sep
    | if .cut > 0 or ((.out | length) > 0 and (.len + $sep + $l) > ($max - 60)) then .cut += 1
      else .out += [$t[$i]] | .len += $sep + $l end)
| (.out | join("\n\n")) + (if .cut > 0 then "\n\nand \(.cut) more — run: forge status" else "" end)
JQ

# ---------------------------------------------------------------------------
# Phase 1: read every board. Which boards exist is read as `forge status` reads it. A board that cannot be read
# means nobody can say that nothing runs, so NOT STARTING is held back for the tick.
# ---------------------------------------------------------------------------
BOARDS=""; BOARDS_DIR_OK=1
if [ -d "$KANBAN_ROOT/boards" ]; then
  for db in "$KANBAN_ROOT"/boards/*/kanban.db; do
    [ -f "$db" ] || continue
    b="${db%/kanban.db}"; b="${b##*/}"
    case "$b" in _*) continue;; esac
    forge_board_slug_ok "$b" || continue
    BOARDS="$BOARDS $b"
  done
else
  BOARDS_DIR_OK=0
fi

read_board() {  # slug -> $WORK/cur-<slug>.json; 1 when the board cannot be snapshotted or asked
  local snap json
  snap="$("$HERE/board-snapshot.sh" "$KANBAN_ROOT/boards/$1/kanban.db" "$WORK/snap-$1" 2>/dev/null)" || true
  [ -n "$snap" ] || return 1
  json="$(sqlite3 "$snap" "$(board_sql)" 2>/dev/null)" || json=""
  rm -rf "$WORK/snap-$1"
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  printf '%s\n' "$json" > "$WORK/cur-$1.json"
}

OKBOARDS=""; BADBOARDS=""; ANY_RUNNING=false
[ "$BOARDS_DIR_OK" = 1 ] || { BADBOARDS=" _boards"; ANY_RUNNING=true; }
for b in $BOARDS; do
  if read_board "$b"; then
    OKBOARDS="$OKBOARDS $b"
    case "$(jq -r '.running' "$WORK/cur-$b.json" 2>/dev/null)" in ''|0) ;; *) ANY_RUNNING=true;; esac
  else
    BADBOARDS="$BADBOARDS $b"; ANY_RUNNING=true
  fi
done

# the class -> reply table, from decision-message.sh (the fourth line of each class's decision)
REPLIES='{}'
for c in $(decision_classes); do
  r="$(class_decision "$c" | sed -n 4p)"
  [ -z "$r" ] || REPLIES="$(printf '%s' "$REPLIES" | jq -c --arg c "$c" --arg r "$r" '. + {($c): $r}')"
done
# the park records: card id -> until / windows
PARKS="$(for f in "$PARK_ROOT"/*.json; do
  [ -f "$f" ] || continue
  id="${f##*/}"; id="${id%.json}"
  jq -c --arg id "$id" '{key: $id, value: {until: (.wake_at // null), windows: (.blocked_windows // "")}}' "$f" 2>/dev/null
done | jq -s 'from_entries' 2>/dev/null)"
[ -n "$PARKS" ] || PARKS='{}'
# the verifier's waits for the Claude usage limit: card id -> {until}
JWAITS="$(forge_judge_waits_json)"
[ -n "$JWAITS" ] || JWAITS='{}'
printf 'null\n' > "$WORK/null.json"
state_or_null() {  # file -> the file when it holds a JSON object, else a file that holds null
  if [ -f "$1" ] && jq -e 'type == "object"' "$1" >/dev/null 2>&1; then printf '%s' "$1"; else printf '%s' "$WORK/null.json"; fi
}

# ---------------------------------------------------------------------------
# Phase 2: compare each readable board with its recorded state; say each unreadable one once.
# ---------------------------------------------------------------------------
printf '[]\n' > "$WORK/ev-_host.json"
for b in $OKBOARDS; do
  src="$(state_or_null "$STATE_DIR/$b.json")"
  if jq -n -c --slurpfile cur "$WORK/cur-$b.json" --slurpfile oldf "$src" --arg board "$b" --argjson now "$NOW" \
        --argjson run_max "$RUN_MAX_MIN" --argjson remind "$REMIND_MIN" --argjson idle_max "$IDLE_MAX_MIN" \
        --argjson any_running "$ANY_RUNNING" --argjson replies "$REPLIES" --argjson parks "$PARKS" --argjson jwaits "$JWAITS" \
        "$DIFF_JQ" > "$WORK/res-$b.json" 2>"$WORK/res-$b.err"; then
    jq -c '.events' "$WORK/res-$b.json" > "$WORK/ev-$b.json"
    jq -c '.state' "$WORK/res-$b.json" > "$WORK/new-$b.json"
    if [ "$DRY" = 1 ] && [ "$src" = "$WORK/null.json" ]; then
      echo "run-watch: $b: no recorded state, so a real tick would say what already waits on you and record the rest as a baseline" >&2
    fi
  else
    echo "run-watch: $b: the comparison failed: $(head -c 300 "$WORK/res-$b.err")" >&2
    BADBOARDS="$BADBOARDS $b"
  fi
done
for b in $BADBOARDS; do
  src="$(state_or_null "$STATE_DIR/$b.json")"
  if jq -e '.unreadable == true' "$src" >/dev/null 2>&1; then
    printf '[]\n' > "$WORK/ev-$b.json"
  elif [ "$b" = _boards ]; then
    jq -n -c --arg t "run-watch: there is no boards directory at $KANBAN_ROOT/boards, so nothing here says the boards are quiet. Run: forge status" \
      '[{rank: 0, text: $t}]' > "$WORK/ev-$b.json"
  else
    jq -n -c --arg t "$b: the board could not be read, so nothing here says it is quiet. Run: forge status $b" \
      '[{rank: 0, text: $t}]' > "$WORK/ev-$b.json"
  fi
  jq -c '(if type == "object" then . else {schema: "forge.run-watch.v1"} end) + {unreadable: true}' "$src" > "$WORK/new-$b.json"
done

# ---------------------------------------------------------------------------
# Phase 3: the checkpoint cron. A gate armed while its cron job is missing or paused completes nothing.
# ---------------------------------------------------------------------------
HOST_NEW=ok; HOST_TEXT=""
arm_out="$("$HERE/checkpoint-arm.sh" list 2>&1)"; arm_rc=$?
case "$arm_rc" in
  0|1)
    armed="$(printf '%s\n' "$arm_out" | awk '$2 ~ /^GATE-/ { printf "%s%s on %s", sep, $2, $1; sep = ", " }')"
    if [ -n "$armed" ]; then
      job="$(jq -r --arg n forge-checkpoint 'if (.jobs | type) != "array" then "unreadable"
          else [.jobs[] | select(.name == $n)] as $j
            | if ($j | length) == 0 then "missing" elif ($j | length) > 1 then "unreadable"
              else ($j[0] | "\(.id) \(if (.enabled == false or .state == "paused") then "paused" else "active" end)") end end' \
          "$HERMES_ROOT/cron/jobs.json" 2>/dev/null)" || job=unreadable
      case "$job" in
        missing)
          HOST_NEW=missing
          HOST_TEXT="CHECKPOINT CRON NOT RUNNING
$armed armed, but there is no cron job named forge-checkpoint, so nothing will probe or complete it.
Do: hermes cron create 'every 15m' --name forge-checkpoint --no-agent --script forge-checkpoint.sh --deliver telegram";;
        *" paused")
          HOST_NEW=paused
          HOST_TEXT="CHECKPOINT CRON NOT RUNNING
$armed armed, but the cron job forge-checkpoint is paused, so nothing will probe or complete it.
Do: hermes cron resume ${job% *}";;
        *" active") ;;
        *) HOST_NEW=unreadable;;
      esac
    fi;;
  *) HOST_NEW=unreadable;;
esac
HOST_OLD="$(jq -r '.checkpoint // empty' "$(state_or_null "$STATE_DIR/_host.json")" 2>/dev/null)"
if [ -n "$HOST_TEXT" ] && [ "$HOST_OLD" != "$HOST_NEW" ]; then   # no record yet is a change too: a gate armed with no job to run it is said at once
  jq -n -c --arg t "$HOST_TEXT" '[{rank: 4, text: $t}]' > "$WORK/ev-_host.json"
fi
# not asked is not "fine": keep what was recorded rather than record a reading nobody took
if [ "$HOST_NEW" = unreadable ] && [ -n "$HOST_OLD" ]; then HOST_NEW="$HOST_OLD"; fi

# ---------------------------------------------------------------------------
# Phase 4: the other watcher. The launchd watchdog reports this cron's silence; this reports the watchdog's.
# WD_SINCE is the watchdog's last write before it went silent (this tick, when it left no log to date).
# ---------------------------------------------------------------------------
WD_NEW=absent; WD_TEXT=""; WD_SINCE=0
WD_OLD="$(jq -r '.watchdog // empty' "$(state_or_null "$STATE_DIR/_host.json")" 2>/dev/null)"
WD_OLD_SINCE="$(jq -r '.watchdog_since // 0 | floor' "$(state_or_null "$STATE_DIR/_host.json")" 2>/dev/null)"
case "$WD_OLD_SINCE" in ''|*[!0-9]*) WD_OLD_SINCE=0;; esac
if [ -f "$(forge_watchdog_plist)" ]; then
  wd_age="$(forge_watchdog_log_age "$NOW")"; wd_rc=$?
  if [ "$wd_rc" = 0 ] && [ "$wd_age" -le "$FORGE_WATCHDOG_SILENT_SECS" ]; then
    WD_NEW=ok
    if [ "$WD_OLD" = silent ]; then
      wd_gap=""
      if [ "$WD_OLD_SINCE" -gt 0 ] && [ $((NOW - wd_age)) -gt "$WD_OLD_SINCE" ]; then
        wd_gap=", after about $(((NOW - wd_age - WD_OLD_SINCE) / 60)) min of silence"
      fi
      WD_TEXT="WATCHDOG BACK
The liveness watchdog wrote a reading $((wd_age / 60)) min ago$wd_gap.
What it says: forge status"
    fi
  else
    WD_NEW=silent; WD_SINCE="$WD_OLD_SINCE"
    if [ "$WD_OLD" != silent ]; then
      case "$wd_rc" in
        0) WD_SINCE=$((NOW - wd_age)); wd_why="has written nothing for $((wd_age / 60)) min, over the $((FORGE_WATCHDOG_SILENT_SECS / 60)) min limit";;
        1) WD_SINCE="$NOW"; wd_why="is installed and has no log at $(forge_watchdog_root)/watchdog.log";;
        *) WD_SINCE="$NOW"; wd_why="has a log that cannot be read, $(forge_watchdog_root)/watchdog.log";;
      esac
      WD_TEXT="WATCHDOG SILENT
The liveness watchdog (launchd, ai.forge.watchdog) $wd_why. Until it runs, nothing checks the gateway, the cron tickers or the verifier's token.
Do: launchctl kickstart gui/$(id -u 2>/dev/null)/ai.forge.watchdog"
    fi
  fi
fi
if [ -n "$WD_TEXT" ]; then
  jq -c --arg t "$WD_TEXT" '. + [{rank: 4, text: $t}]' "$WORK/ev-_host.json" > "$WORK/ev-_host.tmp" && mv -f "$WORK/ev-_host.tmp" "$WORK/ev-_host.json"
fi
jq -n -c --argjson now "$NOW" --arg c "$HOST_NEW" --arg w "$WD_NEW" --argjson ws "$WD_SINCE" \
  '{schema: "forge.run-watch.v1", at: $now, checkpoint: $c, watchdog: $w} + (if $w == "silent" then {watchdog_since: $ws} else {} end)' > "$WORK/new-_host.json"

# ---------------------------------------------------------------------------
# Say it, THEN record it: a tick that dies before the message is out re-says it next time.
# ---------------------------------------------------------------------------
MSG="$(cat "$WORK"/ev-*.json | jq -s -r --argjson max "$MAX_CHARS" "$FIT_JQ")"
[ -z "$MSG" ] || printf '%s\n' "$MSG"

if [ "$DRY" = 0 ]; then
  rc=0
  for f in "$WORK"/new-*.json; do
    [ -f "$f" ] || continue
    n="${f##*/new-}"; n="${n%.json}"
    tmp="$STATE_DIR/.$n.json.$$"
    if cp "$f" "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE_DIR/$n.json" 2>/dev/null; then :; else
      rm -f "$tmp"; echo "run-watch: the state for $n could not be written under $STATE_DIR" >&2; rc=2
    fi
  done
  # a board that is gone (archived) leaves nothing behind; only when the boards directory itself could be read
  if [ "$BOARDS_DIR_OK" = 1 ]; then
    rm -f "$STATE_DIR/_boards.json"   # the directory is back: its next disappearance is a new occurrence
    for f in "$STATE_DIR"/*.json; do
      [ -f "$f" ] || continue
      n="${f##*/}"; n="${n%.json}"
      case "$n" in _*) continue;; esac
      case " $BOARDS " in *" $n "*) ;; *) rm -f "$f";; esac
    done
  fi
  exit "$rc"
fi
exit 0
