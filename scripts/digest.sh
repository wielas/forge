#!/usr/bin/env bash
# =============================================================================
# forge digest — GW2: one message a day that says what the boards did.
#
# Landed, in flight, waiting on you, spend — per board, computed here and
# printed. Nothing reads it back and rephrases it: the operator's step is
#
#   ln -s ~/.forge/repo/scripts/digest.sh ~/.hermes/scripts/forge-digest.sh
#   hermes cron create '0 9 * * *' --name forge-digest --no-agent \
#     --script ~/.hermes/scripts/forge-digest.sh --deliver telegram
#
# `--no-agent` IS THE DECISION. The epic's Roles table has a cheap model
# relaying this script's output; it does not here, because "numbers come from
# scripts, never from a model" (Forge once published a bounce rate of 0.00 for a
# run with 12 bounces), and a model that relays a number can still restate it.
# Under `--no-agent` stdout is delivered verbatim and an empty stdout is silent —
# the merge-watcher's pattern, for the same reason. The `forge-digest` SOUL,
# which has a model call `kanban_list` and compose the message itself, was never
# scheduled and is not used by this.
#
# READ-ONLY. Every board is read through scripts/board-snapshot.sh — the one
# WAL-safe read (F47, F67) — and the spend line is `metrics.sh`'s own number,
# never recomputed here. The script makes no board write of any kind.
#
# WHAT A BOARD IS. Every `<kanban home>/boards/<slug>/kanban.db` except the ones
# Hermes moved under `_archived/`. A board appears only when something landed on
# the day, something is in flight, or something waits on the operator — so a
# finished run drops out when its board is archived, and a dormant card on an
# old board keeps appearing until someone decides about it, which is what
# "waiting on you" means.
#
# WAITING ON YOU is rendered in GW1's format (scripts/decision-message.sh). A
# verifier hold already carries the whole format in its reason and is shown as
# written, cut after its reply; a one-line lane block is expanded from the
# class table there.
#
# Usage:
#   digest.sh [--board <slug>]... [--day YYYY-MM-DD]
#     --day   the calendar day "landed" and "spend" cover (local); default yesterday
#     --board limit to these boards (repeatable); default every live board
#
# Exit: 0 printed a digest, or there was nothing to say (empty stdout).
#       2 a usage error, or a tool is missing.
#       3 a board could not be read — the digest says which, on stdout too,
#         because a board it could not read is not a quiet board.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" \
  || { echo "digest: script directory cannot be resolved" >&2; exit 2; }
# shellcheck source=decision-message.sh
. "$HERE/decision-message.sh" || { echo "digest: cannot source decision-message.sh" >&2; exit 2; }

BOARDS=""; DAY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --board) BOARDS="$BOARDS ${2:?--board needs a slug}"; shift 2;;
    --day)   DAY="${2:?--day needs YYYY-MM-DD}"; shift 2;;
    -h|--help) awk 'NR>2 && /^# ={10,}/{exit} NR>2 {sub(/^# ?/,""); print}' "$0"; exit 0;;
    *) echo "digest: unknown arg: $1" >&2; exit 2;;
  esac
done
for tool in sqlite3 jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "digest: $tool is not on PATH" >&2; exit 2; }
done
[ -n "$DAY" ] || DAY="$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d yesterday '+%Y-%m-%d')"
case "$DAY" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "digest: --day must be YYYY-MM-DD: got '$DAY'" >&2; exit 2;; esac

HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
KANBAN_ROOT="${HERMES_KANBAN_HOME:-$HERMES_ROOT/kanban}"
if [ -z "$BOARDS" ]; then
  for db in "$KANBAN_ROOT"/boards/*/kanban.db; do
    [ -f "$db" ] || continue
    slug="${db%/kanban.db}"; slug="${slug##*/}"
    [ "$slug" = _archived ] || BOARDS="$BOARDS $slug"
  done
fi

# The same local-midnight arithmetic metrics.sh uses: 'utc' reads the literal as
# local time, so a day boundary is the operator's midnight, not Greenwich's.
DAY_START="$(sqlite3 :memory: "SELECT strftime('%s','$DAY','utc');")"
DAY_END="$(sqlite3 :memory: "SELECT strftime('%s','$DAY','+1 day','utc');")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-digest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# One JSON object per board: landed on the day, everything in flight, everything
# waiting, with the last block reason of each waiting card.
board_json() {  # $1=snapshot path
  sqlite3 "$1" <<SQL
SELECT json_object(
  'landed', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'pr', pr)), json_array())
               FROM (SELECT t.id, t.title,
                            (SELECT json_extract(r.metadata,'\$.pr') FROM task_runs r
                              WHERE r.task_id = t.id AND json_type(r.metadata,'\$.pr') = 'text'
                              ORDER BY r.started_at DESC, r.id DESC LIMIT 1) AS pr
                       FROM tasks t
                      WHERE t.status = 'done'
                        AND t.completed_at >= $DAY_START AND t.completed_at < $DAY_END
                      ORDER BY t.completed_at, t.id)),
  'flight', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'status', status)), json_array())
               FROM (SELECT id, title, status FROM tasks
                      WHERE status IN ('running','review','ready','todo')
                      ORDER BY CASE status WHEN 'running' THEN 0 WHEN 'review' THEN 1
                                           WHEN 'ready' THEN 2 ELSE 3 END, id)),
  'waiting', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'status', status, 'reason', reason)), json_array())
               FROM (SELECT t.id, t.title, t.status,
                            (SELECT json_extract(e.payload,'\$.reason') FROM task_events e
                              WHERE e.task_id = t.id AND e.kind IN ('blocked','block_loop_detected')
                              ORDER BY e.created_at DESC, e.id DESC LIMIT 1) AS reason
                       FROM tasks t WHERE t.status IN ('blocked','triage')
                      ORDER BY t.id))
);
SQL
}

# A waiting card, in GW1's format. $1=board $2=one element of .waiting
render_waiting() {
  local board="$1" card id title status reason class headline means decision risk reply
  card="$2"
  id="$(printf '%s' "$card" | jq -r '.id')"
  title="$(printf '%s' "$card" | jq -r '.title')"
  status="$(printf '%s' "$card" | jq -r '.status')"
  reason="$(printf '%s' "$card" | jq -r '.reason // ""')"
  printf -- '— %s · %s\n' "$id" "$title"
  # A verifier hold already speaks the format. Show it as written, up to the end
  # of its reply: what follows is evidence, which is on the card.
  if printf '%s' "$reason" | grep -q '^Decision needed: '; then
    printf '%s\n' "$reason" | awk '/^Reply: /{r=1} r && /^$/{exit} {print}'
    return
  fi
  class="${reason%%:*}"
  if [ "$status" = triage ]; then
    class=other; headline="the card is in triage, which no script can complete (epic P8)"
  elif [ -z "$reason" ]; then
    class=other; headline="blocked with no recorded reason"
  elif [ "$class" != "$reason" ] && class_decision "$class" >/dev/null 2>&1; then
    headline="${reason#*: }"; headline="${headline%%$'\n'*}"
  else
    class=other; headline="${reason%%$'\n'*}"
  fi
  { read -r means; read -r decision; read -r risk; read -r reply; } < <(class_decision "$class")
  reply="${reply//<id>/$id}"; reply="${reply//<board>/$board}"
  decision_message "$class" "$headline" "$means" "$decision" "$risk" "$reply"
}

# The driver spend on the day, as metrics.sh reports it — never recomputed.
render_spend() {  # $1=board
  local m rc
  m="$("$HERE/metrics.sh" "$1" --json --since "$DAY" --until "$DAY" 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] || { printf 'Spend: unreadable — make metrics exited %s for this board\n' "$rc"; return; }
  printf '%s' "$m" | jq -r '
    .driver_usage as $d
    | if $d.coverage.eligible == 0 then "Spend: no metered driver runs on the day"
      else "Spend: driver "
        + (if $d.cost.actual_usd == null then "actual n/a" else "actual $\($d.cost.actual_usd)" end)
        + " · "
        + (if $d.cost.estimated_usd == null then "estimated n/a" else "estimated $\($d.cost.estimated_usd)" end)
        + " — \($d.coverage.joined)/\($d.coverage.eligible) runs joined. Codex quota is not metered here."
      end'
}

OUT="$WORK/out"; : > "$OUT"; rc=0
for BOARD in $BOARDS; do
  db="$KANBAN_ROOT/boards/$BOARD/kanban.db"
  [ "$BOARD" = default ] && db="$HERMES_ROOT/kanban.db"
  snap=""
  [ -f "$db" ] && snap="$("$HERE/board-snapshot.sh" "$db" "$WORK/$BOARD" 2>/dev/null)"
  json=""
  [ -n "$snap" ] && json="$(board_json "$snap" 2>/dev/null)"
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || {
    printf '\n== %s ==\nUNREADABLE — the board could not be read, so nothing here says it is quiet\n' "$BOARD" >> "$OUT"
    rc=3; continue; }
  printf '%s' "$json" | jq -e '(.landed + .flight + .waiting) | length > 0' >/dev/null || continue
  {
    printf '\n== %s ==\n' "$BOARD"
    printf '%s' "$json" | jq -r '
      . as $b |
      "Landed (\(.landed | length))"
        + (if (.landed | length) == 0 then ": nothing" else "" end),
      (.landed[] | "- \(.title) — \(.pr // "no PR recorded") (\(.id))"),
      "In flight: "
        + ([ ["running","running"], ["review","in review"], ["ready","ready"], ["todo","waiting on parents"] ]
           as $order | [ $order[] as [$s,$label]
                         | ([$b.flight[] | select(.status == $s)] | length) as $n
                         | select($n > 0) | "\($n) \($label)" ]
           | if length == 0 then "nothing" else join(" · ") end),
      (.flight[] | select(.status == "running" or .status == "review")
                 | "- \(if .status == "review" then "in review" else .status end): \(.title) (\(.id))"),
      "Waiting on you (\(.waiting | length))"
        + (if (.waiting | length) == 0 then ": nothing" else "" end)' \
      || { echo "digest: rendering board $BOARD failed" >&2; rc=3; }
    printf '%s' "$json" | jq -c '.waiting[]' | while IFS= read -r card; do
      echo; render_waiting "$BOARD" "$card"
    done
    echo; render_spend "$BOARD"
  } >> "$OUT"
done

[ -s "$OUT" ] || exit "$rc"
printf 'Forge digest — %s\n' "$DAY"
cat "$OUT"
exit "$rc"
