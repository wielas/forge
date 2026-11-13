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
# finished run drops out when its board is archived. A card waiting on the
# operator stays on its board until someone decides about it, which is what
# "waiting on you" means; but a board nobody has touched for weeks is not
# repeated in full every morning — see DORMANT BOARDS.
#
# DORMANT BOARDS. A board is dormant for the digest day when nothing landed on
# the day, no card is `running` or in `review`, and its newest row (the latest
# task event, or task timestamp if that is later) is more than
# FORGE_DIGEST_DORMANT_DAYS days (default 14) before the END of the digest day —
# measured from `--day`, never from the clock, so a fixture's answer is the same
# on every date. A dormant board is not rendered in full: every dormant board
# gets one line in a single section at the very END of the message, after all the
# active boards, with the command for its full view and the one that archives it.
# A board with nothing to say is still omitted entirely, and when every board
# with something to say is dormant the message is the header line and that
# section. Three things are never collapsed: a board named with `--board` (that
# is the full view the dormant line points to), a board that could not be read
# (UNREADABLE below, exit 3), and any board when FORGE_DIGEST_DORMANT_DAYS is 0
# or not a number, which restores one full block per board.
#
# WAITING ON YOU is rendered in GW1's format (scripts/decision-message.sh). A
# verifier hold already carries the whole format in its reason and is shown as
# written, cut after its reply; a one-line lane block is expanded from the
# class table there. A card the bootstrap holds for later — a milestone gate,
# or a chunk a human implements — waits on nobody while a parent is open, so it
# is left out until every parent is done. A human chunk sent back for changes
# sits `ready` on the non-spawnable sentinel; nothing but the operator picks it
# up, so it is waiting on them and is not counted in flight (epic P21).
#
# WHERE THIS BOARD STANDS and WHAT TO DO close each board (owner feedback, 2026-11-05). Both
# are computed from the same rows as the sections above them — counts and block
# reasons, never a model's prose — and neither restates a card's own Decision or
# Reply line: they say what the board's state amounts to and what to do next,
# naming every `hermes kanban` command with `--board`. A phone message is chunked
# at 4096 UTF-16 units by Hermes, so "What to do" lists at most MAX_TODO cards and
# says how many more it left to the cards above. The job-management footer Hermes
# appends is its own `cron.wrap_response`, not this script's output (PR #97).
#
# Usage:
#   digest.sh [--board <slug>]... [--day YYYY-MM-DD]
#     --day   the calendar day "landed" and "spend" cover (local); default yesterday
#     --board limit to these boards (repeatable), each rendered in full even if
#             dormant; default every live board, dormant ones collapsed
#   FORGE_DIGEST_DORMANT_DAYS  days of silence that make a board dormant;
#             default 14; 0 or anything that is not a number turns the collapse off
#
# Exit: 0 printed a digest, or there was nothing to say (empty stdout).
#       2 a usage error, or a tool is missing.
#       3 a board could not be read — the digest says which, on stdout too,
#         because a board it could not read is not a quiet board.
# =============================================================================
set -uo pipefail

# Resolve through symlinks FIRST: cron runs this as a symlink under
# ~/.hermes/scripts/, and the siblings live beside the TARGET. A loop, not
# `readlink -f`, which the bash 3.2 / older macOS userland may not have.
_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in /*) _self="$_link";; *) _self="$(dirname "$_self")/$_link";; esac
done
HERE="$(cd "$(dirname "$_self")" 2>/dev/null && pwd -P)" \
  || { echo "digest: script directory cannot be resolved" >&2; exit 2; }
# shellcheck source=decision-message.sh
. "$HERE/decision-message.sh" || { echo "digest: cannot source decision-message.sh" >&2; exit 2; }

BOARDS=""; DAY=""; EXPLICIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --board) BOARDS="$BOARDS ${2:?--board needs a slug}"; EXPLICIT=1; shift 2;;
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

# DORMANT BOARDS (header). "Now" is the end of the digest day, so the answer for a
# fixture is the same on every date. A value that is not a plain number of days,
# or is absurdly long, turns the collapse off: today's behaviour, one full block
# per board. Naming a board always turns it off for that run.
DORMANT_DAYS="${FORGE_DIGEST_DORMANT_DAYS:-14}"
case "$DORMANT_DAYS" in
  *[!0-9]*) DORMANT_DAYS=0;;
  *) if [ "${#DORMANT_DAYS}" -le 5 ]; then DORMANT_DAYS=$((10#$DORMANT_DAYS)); else DORMANT_DAYS=0; fi;;
esac
COLLAPSE=0
{ [ "$DORMANT_DAYS" -gt 0 ] && [ "$EXPLICIT" = 0 ]; } && COLLAPSE=1
DORMANT_CUTOFF=$((DAY_END - DORMANT_DAYS * 86400))

# The interactive hold as an SQL literal: board_json compares the last block
# reason with it.
INTERACTIVE_HOLD_SQL="$(printf '%s' "$INTERACTIVE_HOLD_REASON" | sed "s/'/''/g")"

# The non-spawnable sentinel a human-tier chunk is handed off on (epic P21,
# lane-handoff.sh). A bounce returns such a card `ready` on it, and nothing but
# the operator will ever pick it up — so it is waiting on them, not in flight.
SENTINEL_SQL="$(printf '%s' "${FORGE_HANDOFF_SENTINEL:-forge-operator-handoff}" | sed "s/'/''/g")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-digest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# One JSON object per board: landed on the day, everything in flight, everything
# waiting, with the last block reason of each waiting card.
board_json() {  # $1=snapshot path
  sqlite3 "$1" <<SQL
SELECT json_object(
  'landed', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'pr', pr, 'result', result)), json_array())
               FROM (SELECT t.id, t.title, t.result,
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
                        AND NOT (status = 'ready' AND assignee IS '$SENTINEL_SQL')
                      ORDER BY CASE status WHEN 'running' THEN 0 WHEN 'review' THEN 1
                                           WHEN 'ready' THEN 2 ELSE 3 END, id)),
  -- Held on purpose, with a parent still open: a gate or an interactive chunk. It
  -- is not in "waiting" (it asks nothing yet) but it is waiting on parents, and
  -- "Where this board stands" counts it as such. `links` lets it tell the cards that wait on
  -- a parent from the ones that wait, through a parent, on the operator.
  'links', (SELECT COALESCE(json_group_array(json_array(parent_id, child_id)), json_array()) FROM task_links),
  'held', (SELECT COALESCE(json_group_array(h.id), json_array()) FROM tasks h
            WHERE h.status = 'blocked'
              AND EXISTS (SELECT 1 FROM task_links l JOIN tasks p ON p.id = l.parent_id
                           WHERE l.child_id = h.id AND p.status NOT IN ('done','archived'))
              AND (h.title GLOB 'GATE-*'
                   OR (SELECT json_extract(e.payload,'\$.reason') FROM task_events e
                        WHERE e.task_id = h.id AND e.kind IN ('blocked','block_loop_detected')
                        ORDER BY e.created_at DESC, e.id DESC LIMIT 1) IS '$INTERACTIVE_HOLD_SQL')),
  'waiting', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'status', status, 'reason', reason)), json_array())
               FROM (SELECT t.id, t.title, t.status,
                            (SELECT json_extract(e.payload,'\$.reason') FROM task_events e
                              WHERE e.task_id = t.id AND e.kind IN ('blocked','block_loop_detected')
                              ORDER BY e.created_at DESC, e.id DESC LIMIT 1) AS reason
                       FROM tasks t
                      WHERE (t.status IN ('blocked','triage')
                             -- A human chunk sent back for changes (epic P21).
                             OR (t.status = 'ready' AND t.assignee IS '$SENTINEL_SQL'))
                        -- A milestone gate (epic MS1) is held from the moment the
                        -- board is bootstrapped, but it asks nothing until every
                        -- chunk it closes is done. Before that it is not waiting
                        -- on the operator, and GW1 says no decision, no message.
                        AND NOT (t.title GLOB 'GATE-*' AND t.status = 'blocked'
                                 AND EXISTS (SELECT 1 FROM task_links l
                                               JOIN tasks p ON p.id = l.parent_id
                                              WHERE l.child_id = t.id
                                                AND p.status NOT IN ('done','archived')))
                      ORDER BY t.id) w
              -- An interactive chunk (epic P13) is held from the bootstrap on as
              -- well, and asks nothing while a parent is open: the human cannot
              -- start it yet. Its one mark is the reason the bootstrap blocked it
              -- with, and only as its LAST reason, so a later block still speaks.
              -- IS, not =: a card blocked with no recorded reason must stay.
              WHERE NOT (w.status = 'blocked' AND w.reason IS '$INTERACTIVE_HOLD_SQL'
                         AND EXISTS (SELECT 1 FROM task_links l
                                       JOIN tasks p ON p.id = l.parent_id
                                      WHERE l.child_id = w.id
                                        AND p.status NOT IN ('done','archived')))),
  -- The newest thing that happened on this board, for the dormancy test: the latest
  -- task event, or a task's own created/completed time if one of those is later
  -- (a board with no event rows still has cards).
  'last', MAX(COALESCE((SELECT MAX(created_at) FROM task_events), 0),
              COALESCE((SELECT MAX(created_at) FROM tasks), 0),
              COALESCE((SELECT MAX(completed_at) FROM tasks), 0))
);
SQL
}

# Add display spacing only to an unambiguous GW1 message. Ambiguous or
# nonstandard text is passed through byte-for-byte (apart from final newline).
format_waiting_fields() {
  awk '
    { line[NR]=$0 }
    /^What it means: / { m=NR; mc++ }
    /^Decision needed: / { d=NR; dc++ }
    /^Risk: / { r=NR; rc++ }
    /^Reply: / { p=NR; pc++ }
    END {
      structured = mc==1 && dc==1 && rc==1 && pc==1 && m<d && d<r && r<p
      for (i=1; i<=NR; i++) {
        if (structured && (i==d || i==r) && i>1 && line[i-1]!="") print ""
        print line[i]
      }
    }
  '
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
  # The only `ready` card waiting is a human chunk sent back (epic P21). Its
  # reasons — the verifier's bounce or the operator's own — are evidence and
  # stay on the card, so `.reason` (a block reason) is not read here; the
  # message says whose move it is and where the reasons are.
  if [ "$status" = ready ]; then
    decision_message returned \
      "this human-tier chunk was sent back for changes; the reasons are on the card" \
      "the verifier, or you through bounce.sh, returned it to you; no lane will pick it up" \
      "fix it on its branch and hand it off again, or decide the reasons are wrong" \
      "its children and its milestone gate wait; nothing is merged" \
      "\`hermes kanban --board $board show $id\` for the reasons; after the fix, \`/end-chunk\` hands it back to the verifier" | format_waiting_fields
    return
  fi
  # A verifier hold already speaks the format. Show it as written, up to the end
  # of its reply: what follows is evidence, which is on the card.
  #
  # EXCEPT FROM `triage`. A card the kernel routed to its unblock-loop breaker keeps the
  # hold's text as its last block reason, so the verbatim branch would tell the operator to
  # "merge the PR" about a card no script can complete (epic P8). Since epic S6d the verifier
  # cannot see where its own block landed — the run ends with the transition, and a fenced
  # terminal cannot read back — so THIS is where a stranded hold is told apart from a real one.
  if [ "$status" != triage ] && printf '%s' "$reason" | grep -q '^Decision needed: '; then
    printf '%s\n' "$reason" | awk '/^Reply: /{r=1} r && /^$/{exit} {print}' | format_waiting_fields
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
  decision_message "$class" "$headline" "$means" "$decision" "$risk" "$reply" | format_waiting_fields
}

# At most this many cards get a numbered step under "What to do"; the rest are
# counted. Hermes chunks a Telegram message at 4096 UTF-16 units, and a board with
# thirteen triage cards must still say what to do in a screenful.
MAX_TODO=6

# The kind of one waiting card, and its headline, as two tab-separated fields.
# It follows render_waiting's own branches, so "What to do" and the card above it
# never disagree about what the card is. $1=status $2=reason
waiting_kind() {
  local status="$1" reason="$2" first class
  first="${reason%%$'\n'*}"
  [ "$status" = ready ]  && { printf 'returned\t\n'; return; }
  [ "$status" = triage ] && { printf 'triage\t\n'; return; }
  [ -n "$reason" ]       || { printf 'other\t\n'; return; }
  class="${first%%:*}"
  if [ "$class" = "$first" ]; then
    class=other
  elif printf '%s' "$reason" | grep -q '^Decision needed: '; then
    # A verifier hold or a bootstrap hold: its own first word is its class.
    case "$class" in ""|*[!a-z-]*) class=other;; esac
  elif ! class_decision "$class" >/dev/null 2>&1; then
    class=other
  fi
  if [ "$class" = other ]; then printf 'other\t%s\n' "$first"
  else printf '%s\t%s\n' "$class" "${first#*: }"; fi
}

# "Where this board stands" and "What to do" for one board. $1=board $2=board json $3=file of
# one JSON object per waiting card (id, title, kind, headline, probe).
read -r -d '' GUIDANCE_JQ <<'JQ'
def pl($n; $one; $many): "\($n) \(if $n == 1 then $one else $many end)";
def short($n): if length > $n then .[0:$n-1] + "…" else . end;
def nm: if (.title | test("^[A-Z]+-[A-Za-z0-9]+:")) then (.title | split(":")[0]) else (.title | short(48)) end;
def prio: {"milestone-gate":0,"merge-pending":1,"bounce-budget":2,"interactive":3,"returned":4,"triage":6,"other":6}[.] // 5;
def unblockable: IN("env","ci-red","stale-spec","failing-prereq","gate-unrunnable");
def fact($n; $h; $board; $id):
  if   . == "milestone-gate" then "\(pl($n; "milestone gate"; "milestone gates")) ready for your sign-off; the chunks behind \(if $n == 1 then "it stay" else "them stay" end) held until you complete \(if $n == 1 then "it" else "each" end)."
  elif . == "merge-pending"  then "\(pl($n; "verified chunk"; "verified chunks")), waiting for your merge; \(if $n == 1 then "its children stay" else "their children stay" end) held until \(if $n == 1 then "it is" else "each is" end) merged."
  elif . == "bounce-budget"  then "\(pl($n; "chunk"; "chunks")) the verifier bounced without converging; held, with their children, until you decide."
  elif . == "interactive"    then "\(pl($n; "chunk"; "chunks")) for you to implement; nothing is built until you start."
  elif . == "returned"       then "\(pl($n; "human chunk"; "human chunks")) sent back for changes; their children and milestone gate wait."
  elif . == "triage"         then "\($n) in triage; no script can complete a triage card, so \(if $n == 1 then "it stays" else "they stay" end) until you decide."
  elif . == "other"          then "\($n) stopped for an unrecognised reason; read \(if $n == 1 then "it" else "each" end) with `hermes kanban --board \($board) show \(if $n == 1 then $id else "<card id>" end)`."
  else "\($n) blocked by \(.): \($h | short(90))" + (if $n > 1 then " (and \($n - 1) like it)" else "" end) + "; \(if $n == 1 then "it holds, with its children," else "they hold, with their children," end) until you fix the cause and unblock." end;
def cmd($board; $verb; $id): "`hermes kanban --board \($board) \($verb) \($id)`";
def step($board):
  . as $c | $c.id as $id | ($c | nm) as $name
  | "\($name) (\($id)): " +
    ( if   $c.kind == "milestone-gate" then
        "no chunk it closes is still open, so probe the milestone"
        + (if $c.probe != "" then ":\n   `\($c.probe)`" else " as the card above says:" end)
        + "\n   Exit 0: `hermes kanban --board \($board) complete \($id) --result \"<the runner's last line>\"`"
        + "\n   Completing it releases the next milestone; do it only when your run plan says to."
        + "\n   Exit 1 (a finding) or 2 (no verdict): do not complete it."
      elif $c.kind == "merge-pending" then
        "merge its PR on GitHub, or send it back; both are in its Reply above."
      elif $c.kind == "bounce-budget" then
        "repair the PR branch yourself or amend the contract, or send it back; see its Reply above."
      elif $c.kind == "interactive" then
        "implement it with /start-chunk in the product checkout; its children wait for the merge."
      elif $c.kind == "returned" then
        "read the reasons with \(cmd($board; "show"; $id)), fix its branch, then /end-chunk."
      elif $c.kind == "triage" then
        "read it with \(cmd($board; "show"; $id)) and decide whether to keep it; no script can complete it."
      elif ($c.kind | unblockable) then
        "blocked by \($c.kind). Inspect with \(cmd($board; "show"; $id)); once the cause is fixed, \(cmd($board; "unblock"; $id))."
      elif $c.kind == "other" then
        "read the reason with \(cmd($board; "show"; $id)) and decide."
      else
        "inspect with \(cmd($board; "show"; $id)), then follow its Reply above."
      end );
. as $b | ($items | sort_by(.kind | prio)) as $w
| ($b.flight | map(select(.status == "running")) | length) as $run
| ($b.flight | map(select(.status == "review")) | length) as $rev
| ($b.flight | map(select(.status == "ready")) | length) as $rdy
| ($b.flight | map(select(.status == "todo")) | length) as $todo
| ($b.held // []) as $heldids
| ($heldids | length) as $held
| ($b.landed | length) as $landed
| ($w | length) as $nw
# Everything downstream of a card that waits on the operator: it cannot start
# until the operator acts, however many parents it has. Followed to the end of the
# chain; a visited set keeps a cycle from looping.
| ([ $w[].id ]) as $seed
| ( { seen: $seed, frontier: $seed }
    | until(.frontier | length == 0;
        . as $s
        | ([ ($b.links // [])[] | select(. as $l | $s.frontier | any(. == $l[0])) | .[1] ] | unique - $s.seen) as $new
        | { seen: ($s.seen + $new), frontier: $new })
    | .seen - $seed ) as $down
| ([ ($b.flight[] | select(.status == "todo") | .id), $heldids[] ] | map(select(. as $i | $down | any(. == $i))) | length) as $behind
| "Where this board stands\n────────────",
  ( if $nw == 0 then empty
    elif $run + $rev + $rdy == 0 then "Overall: nothing is running, so the run is stopped until you act."
    elif $behind > 0 then "Overall: work continues on what is in flight, but \(pl($behind; "waiting card"; "waiting cards")) cannot start until you act."
    else "Overall: work continues on what is in flight; no waiting card is behind the cards that need you." end ),
  ( "Progress: "
    + (if $landed == 0 then "nothing landed on \($day)" else "\(pl($landed; "card"; "cards")) landed on \($day)" end)
    + "; "
    + (if $run + $rev + $rdy == 0 then "nothing is running now"
       else "now " + ([ if $run > 0 then "\($run) running" else empty end,
                        if $rev > 0 then "\($rev) in review" else empty end,
                        if $rdy > 0 then "\($rdy) ready to start" else empty end ] | join(", ")) end)
    + "." ),
  ( "Waiting on parents: "
    + (if $todo + $held == 0 then "none."
       else pl($todo + $held; "card"; "cards")
            + (if   $behind == 0 then "; none needs you yet, each starts on its own once its parents finish."
               elif $behind == $todo + $held then " (all behind the cards waiting on you, so they start only after you act)."
               else " (\($behind) behind the cards waiting on you, so they start only after you act; the rest start on their own once their parents finish)." end)
            + (if $held > 0 and $behind < $todo + $held then " Held gates and human chunks appear under Waiting on you once their parents finish." else "" end)
       end) ),
  ( if $nw == 0 then "Waiting on you: nothing."
    else "Waiting on you: \(pl($nw; "card"; "cards"))",
         ( [ $w | group_by(.kind)[] | { k: .[0].kind, n: length, h: .[0].headline, i: .[0].id } ]
           | sort_by(.k | prio)[]
           | . as $g | "  · " + ($g.k | fact($g.n; $g.h; $board; $g.i)) ) end ),
  "",
  "What to do\n────────────",
  ( if $nw == 0 then
      "Nothing needs you today."
      + (if $run + $rev + $rdy > 0 then " The run is moving on its own; the next digest says if that changes."
         elif $todo + $held > 0 then " Nothing is running either, though, and \(pl($todo + $held; "card waits"; "cards wait")) on parents: if tomorrow's digest says the same, look at the board with `hermes kanban --board \($board) list`."
         else "" end)
    else
      ( [ $w[0:$max] | to_entries[] | "\(.key + 1). \(.value | step($board))" ][] ),
      ( if $nw > $max then "…and \($nw - $max) more waiting \(if $nw - $max == 1 then "card" else "cards" end); the cards above have their own Reply lines." else empty end )
    end )
JQ

render_guidance() {  # $1=board $2=board json $3=items file
  printf '%s' "$2" | jq -r --arg board "$1" --arg day "$DAY" --argjson max "$MAX_TODO" \
    --slurpfile items "$3" "$GUIDANCE_JQ" 2>/dev/null \
    || { echo "digest: rendering the guidance for board $1 failed" >&2; return 1; }
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

# One line for a dormant board. $1=board $2=board json. The archive verb is
# `boards rm`: its default is to move the board under boards/_archived/, which is
# recoverable (`--delete` is the hard one, and is never printed).
dormant_line() {
  local nw nf last date parts
  { read -r nw; read -r nf; read -r last; } \
    < <(printf '%s' "$2" | jq -r '(.waiting | length), (.flight | length), .last')
  date="$(sqlite3 :memory: "SELECT strftime('%Y-%m-%d', $last, 'unixepoch', 'localtime');")"
  parts=""
  [ "$nw" -gt 0 ] && parts="$nw waiting on you"
  [ "$nf" -gt 0 ] && parts="${parts:+$parts, }$nf not started"
  printf -- '- %s: %s, last activity %s — full view: `~/.forge/repo/scripts/digest.sh --board %s`; archive it: `hermes kanban boards rm %s`\n' \
    "$1" "$parts" "$date" "$1" "$1"
}

OUT="$WORK/out"; : > "$OUT"; rc=0
DORMANT="$WORK/dormant"; : > "$DORMANT"; ndormant=0
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
  # Dormant: nothing landed on the day, nothing running or in review, and the board's
  # newest row is older than the cutoff. A jq failure here is not dormant: the board
  # is then rendered in full, which is the safe direction to be wrong in.
  if [ "$COLLAPSE" = 1 ] && printf '%s' "$json" | jq -e --argjson cutoff "$DORMANT_CUTOFF" '
       (.landed | length) == 0
       and ([.flight[] | select(.status == "running" or .status == "review")] | length) == 0
       and .last < $cutoff' >/dev/null 2>&1; then
    dormant_line "$BOARD" "$json" >> "$DORMANT"
    ndormant=$((ndormant + 1))
    continue
  fi
  {
    printf '\n== %s ==\n' "$BOARD"
    printf '%s' "$json" | jq -r '
      . as $b |
      "\nLanded (\(.landed | length))"
        + (if (.landed | length) == 0 then ": nothing" else "" end) + "\n────────────",
      # Epic P9: the merge-watcher writes HEAD DRIFT into the result of a card whose PR
      # was merged at a head the verdict did not approve. It is landed, and it is not verified.
      (.landed[] | "- \(.title) — \(.pr // "no PR recorded") (\(.id))"
                   + (if (.result // "") | test("HEAD DRIFT") then " — HEAD DRIFT: merged at a head the verifier did not approve" else "" end)),
      "\nIn flight: "
        + ([ ["running","running"], ["review","in review"], ["ready","ready"], ["todo","waiting on parents"] ]
           as $order | [ $order[] as [$s,$label]
                         | ([$b.flight[] | select(.status == $s)] | length) as $n
                         | select($n > 0) | "\($n) \($label)" ]
           | if length == 0 then "nothing" else join(" · ") end),
      (.flight[] | select(.status == "running" or .status == "review")
                 | "- \(if .status == "review" then "in review" else .status end): \(.title) (\(.id))"),
      "\nWaiting on you (\(.waiting | length))"
        + (if (.waiting | length) == 0 then ": nothing" else "" end) + "\n────────────"' \
      || { echo "digest: rendering board $BOARD failed" >&2; rc=3; }
    items="$WORK/$BOARD.items"; : > "$items"
    printf '%s' "$json" | jq -c '.waiting[]' | while IFS= read -r card; do
      echo; render_waiting "$BOARD" "$card"
      wk="$(waiting_kind "$(printf '%s' "$card" | jq -r '.status')" "$(printf '%s' "$card" | jq -r '.reason // ""')")"
      probe=""
      [ "${wk%%$'\t'*}" = milestone-gate ] && probe="$(printf '%s' "$card" | jq -r '.reason // ""' \
        | sed -n '/^Decision needed: /{s/^[^`]*`\([^`]*\)`.*/\1/p;q;}')"
      printf '%s' "$card" | jq -c --arg k "${wk%%$'\t'*}" --arg h "${wk#*$'\t'}" --arg p "$probe" \
        '{id, title, kind: $k, headline: $h, probe: $p}' >> "$items"
    done
    echo; render_guidance "$BOARD" "$json" "$items" || rc=3
    echo; render_spend "$BOARD"
  } >> "$OUT"
done

[ -s "$OUT" ] || [ "$ndormant" -gt 0 ] || exit "$rc"
printf 'Forge digest — %s\n' "$DAY"
cat "$OUT"
# The dormant boards come last, after every active board, in one section.
if [ "$ndormant" -gt 0 ]; then
  printf '\nDormant boards (%s) — untouched for %s+ days, nothing running\n' "$ndormant" "$DORMANT_DAYS"
  cat "$DORMANT"
fi
exit "$rc"
