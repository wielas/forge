#!/usr/bin/env bash
# =============================================================================
# forge triage — the overseer's way to empty `triage`, audited (epic MS5, S8c).
#
# A card lands in `triage` for follow-ups that nobody routed (a lane's CARD?
# notes, a judge's out-of-scope finding, a recurrence-limit block). Hermes gives
# it one exit that needs a model — `hermes kanban specify` / `decompose`, which
# call an auxiliary model — and refuses `complete`, `unblock` and `promote` on it
# (executed 2026-09-26, P8; `promote` is the kernel's todo/blocked-only recovery).
# This script uses none of them. Every exit below is a plain board verb, so it
# needs no model and no auxiliary client:
#
#   close    archive the card.
#   fold     comment the card's title and body onto the card it folds INTO, then
#            archive it, so the content survives on a live card.
#   promote  create the card again, outside triage, with the same body and the
#            same (non-archived) parents, then archive the original. The new
#            card lands `ready`, or `todo` when a parent is still open: the
#            kernel offers no way to create a parentless `todo`. It is created
#            UNASSIGNED unless --assignee names a profile: promotion decides that
#            the work is real, and routing it is a separate act. --assignee
#            forge-overseer is refused (scripts/overseer-guard.sh).
#
# EVERY action writes an audit comment on the original card, before the card is
# archived, naming the action, the actor and the reason:
#     triage <action> by <actor>: <reason>[; folded into <id>][; promoted as <id>]
# and every `hermes kanban` call carries --board: a call that omitted it would
# land on whatever board is "current" (the trap preflight section 8 warns of).
# Comments are authored as the actor. metrics.sh does not count a comment by
# forge-overseer as an operator touch (it is a machine); the operator's own are
# touches, as they always were. So --apply has NO default actor: it must be named
# with --actor, or the operator's own write would be counted as a machine's.
#
# TWO KINDS OF CARD ARE NEVER AN EXIT, whatever the title looks like (a block
# repeated in one kind routes a card to `triage`, kanban_db.py:3325, so a held
# gate can be there; archiving it, or any parent of a live card, releases the
# cards behind it, kanban_db.py:2159, 3916):
#   - a milestone gate: a title that, trimmed, lowercased and stripped of a
#     leading "CARD?: ", starts with "gate-", or a card whose block reason
#     starts "milestone-gate:". A gate is completed by the checkpoint or the
#     operator.
#   - a parent of any card that is not archived.
# A refusal says why, exits 1, and writes nothing, not even a comment.
#
# MODES, one of which is required, as in scripts/checkpoint.sh:
#   --rehearse   writes nothing; prints the calls --apply would make.
#   --apply      makes them. A failed call stops the run and is reported; the
#                cards already handled stay handled. Each action can be re-run:
#                a promote carries an idempotency key, so it does not create a
#                second card.
# The board is read from a snapshot copy (never mode=ro: it is WAL).
#
# A PLAN is the unit of "empty":
#   triage.sh plan --board <slug> --file <plan> (--rehearse|--apply)
# Each line is  action|card|into-or-assignee|reason  (the reason may contain
# '|'; a '#' line is a comment). The whole plan is validated against the
# snapshot before the first write (every card in triage, a fold target live and
# not in triage, a reason on every line, no card twice); then it runs; then the
# board is read again and the run FAILS (exit 1) if triage is not empty. The
# overseer writes the plan - the judgement - and this script executes it.
#
# Usage:
#   ./scripts/triage.sh list    --board <slug>
#   ./scripts/triage.sh close   --board <slug> --card <id> --reason <text> (--rehearse | --apply --actor <name>)
#   ./scripts/triage.sh fold    --board <slug> --card <id> --into <id> --reason <text> (--rehearse | --apply --actor <name>)
#   ./scripts/triage.sh promote --board <slug> --card <id> --reason <text> [--assignee <profile>] (--rehearse | --apply --actor <name>)
#   ./scripts/triage.sh plan    --board <slug> --file <plan> (--rehearse | --apply --actor <name>)
# Exit: 0 done (for plan: triage is empty), 1 refused or failed or triage not
#       empty, 2 usage (including --apply with no --actor) or the board could
#       not be read.
# =============================================================================
set -uo pipefail

helptext() { awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; }
usagetext() { awk '/^# Usage:/{u=1} u && /^# Exit:/{exit} u' "$0"; }

_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in /*) _self="$_link";; *) _self="$(dirname "$_self")/$_link";; esac
done
HERE="$(cd "$(dirname "$_self")" 2>/dev/null && pwd -P)" \
  || { echo "triage: script directory cannot be resolved" >&2; exit 2; }

ACTION="${1:-}"
case "$ACTION" in
  -h|--help) helptext; exit 0;;
  list|close|fold|promote|plan) shift;;
  *) usagetext >&2; exit 2;;
esac

BOARD=""; CARD=""; INTO=""; REASON=""; ASSIGNEE=""; ACTOR=""; MODE=""; PLAN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --board)    [ $# -ge 2 ] || { echo "triage: --board needs a slug" >&2; exit 2; }; BOARD="$2"; shift 2;;
    --card)     [ $# -ge 2 ] || { echo "triage: --card needs an id" >&2; exit 2; }; CARD="$2"; shift 2;;
    --into)     [ $# -ge 2 ] || { echo "triage: --into needs an id" >&2; exit 2; }; INTO="$2"; shift 2;;
    --reason)   [ $# -ge 2 ] || { echo "triage: --reason needs text" >&2; exit 2; }; REASON="$2"; shift 2;;
    --assignee) [ $# -ge 2 ] || { echo "triage: --assignee needs a profile" >&2; exit 2; }; ASSIGNEE="$2"; shift 2;;
    --actor)    [ $# -ge 2 ] || { echo "triage: --actor needs a name" >&2; exit 2; }; ACTOR="$2"; shift 2;;
    --file)     [ $# -ge 2 ] || { echo "triage: --file needs a path" >&2; exit 2; }; PLAN="$2"; shift 2;;
    --rehearse)
      [ "$MODE" != apply ] || { echo "triage: --rehearse and --apply are exclusive" >&2; exit 2; }
      MODE=rehearse; shift;;
    --apply)
      [ "$MODE" != rehearse ] || { echo "triage: --rehearse and --apply are exclusive" >&2; exit 2; }
      MODE=apply; shift;;
    -h|--help) helptext; exit 0;;
    *) echo "triage: unknown argument: $1" >&2; exit 2;;
  esac
done

board_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
card_re='^t_[A-Za-z0-9]+$'
name_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
[ -n "$BOARD" ] && [[ $BOARD =~ $board_re ]] || { echo "triage: --board <slug> is required" >&2; exit 2; }
[ -n "$ACTOR" ] || { [ "$MODE" != apply ] || { echo "triage: --apply needs an explicit --actor <name>: a write to the board says who made it, and an operator's own name is counted as a touch where forge-overseer is not" >&2; exit 2; }; ACTOR=forge-overseer; } # actor-required
[[ $ACTOR =~ $name_re ]] || { echo "triage: '$ACTOR' is not an actor name" >&2; exit 2; }
if [ "$ACTION" != list ] && [ -z "$MODE" ]; then
  echo "triage: say --rehearse (writes nothing) or --apply (changes the board)" >&2; exit 2
fi
for tool in sqlite3 jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "triage: $tool is not on PATH" >&2; exit 2; }
done

HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
KANBAN_ROOT="${HERMES_KANBAN_HOME:-$HERMES_ROOT/kanban}"
if [ "$BOARD" = default ]; then DB="$HERMES_ROOT/kanban.db"; else DB="$KANBAN_ROOT/boards/$BOARD/kanban.db"; fi
[ -f "$DB" ] || { echo "triage: no board database at $DB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-triage.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
snapshot() { # -> path of a fresh readable copy on stdout (a new directory each time: this runs in $(...))
  local d
  d="$(mktemp -d "$WORK/snap.XXXXXX")" || return 1
  "$HERE/board-snapshot.sh" "$DB" "$d/board" 2>"$WORK/snap.err" && return 0
  echo "triage: could not snapshot board $BOARD; a board that was not read is not an empty one ($(tail -n 1 "$WORK/snap.err"))" >&2
  return 1
}

# The only way this script changes a board (bar the promote's create, which
# needs a body on stdin and says so). The mode is honoured here, and --board is
# added here, so no call made through it can omit either.
board_write() { # $@ = the hermes kanban arguments after --board <slug>
  if [ "$MODE" != apply ]; then
    echo "would run: hermes kanban --board $BOARD $*   (rehearsal: not run)"
    return 0
  fi
  hermes kanban --board "$BOARD" "$@" </dev/null
}

one_line() { printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'; }

card_json() { # $1=snapshot $2=card -> one JSON object, or empty
  sqlite3 "$1" "SELECT json_object('id', id, 'title', title, 'body', COALESCE(body, ''), 'status', status,
                                    'assignee', assignee) FROM tasks WHERE id = '$2';" 2>/dev/null
}
parents_of() { # $1=snapshot $2=card -> parent ids, one per line, archived ones left out
  sqlite3 "$1" "SELECT l.parent_id FROM task_links l JOIN tasks p ON p.id = l.parent_id
                 WHERE l.child_id = '$2' AND p.status <> 'archived' ORDER BY l.parent_id;" 2>/dev/null
}
triage_count() { sqlite3 "$1" "SELECT COUNT(*) FROM tasks WHERE status = 'triage';" 2>/dev/null; }
gate_reasons() { # $1=snapshot $2=card -> how many of its `blocked` events carry a milestone-gate reason (a query that fails counts as 1: refuse)
  sqlite3 "$1" "SELECT COUNT(*) FROM task_events
                 WHERE task_id = '$2' AND kind = 'blocked' AND json_valid(payload)
                   AND lower(trim(COALESCE(json_extract(payload, '\$.reason'), ''))) LIKE 'milestone-gate:%';" 2>/dev/null || echo 1
}
live_children() { # $1=snapshot $2=card -> the ids of its children that are not archived, comma-joined ('?' when the query fails: refuse)
  local r
  r="$(sqlite3 "$1" "SELECT group_concat(id, ',') FROM (SELECT t.id FROM task_links l JOIN tasks t ON t.id = l.child_id
                      WHERE l.parent_id = '$2' AND t.status <> 'archived' ORDER BY t.id);" 2>/dev/null)" || { printf '?'; return 0; }
  printf '%s' "$r"
}

if [ "$ACTION" = list ]; then
  S="$(snapshot)" || exit 2
  echo "triage on board $BOARD: $(triage_count "$S") card(s)"
  sqlite3 "$S" "SELECT id || '  ' || COALESCE(created_by, '-') || '  ' || title
                  FROM tasks WHERE status = 'triage' ORDER BY created_at, id;" | sed 's/^/  /'
  exit 0
fi

# validate_one <snapshot> <action> <card> <into-or-assignee> <reason> -> 0 ok, else the refusal on stdout
validate_one() {
  local s="$1" act="$2" card="$3" arg="$4" reason="$5" cj st tgt tj tst title g kids
  [[ $card =~ $card_re ]] || { echo "'$card' is not a card id"; return 1; }
  [ -n "$(one_line "$reason")" ] || { echo "$card: every action needs a reason"; return 1; }
  cj="$(card_json "$s" "$card")"
  [ -n "$cj" ] || { echo "$card: no such card on board $BOARD"; return 1; }
  st="$(printf '%s' "$cj" | jq -r '.status')"
  [ "$st" = triage ] || { echo "$card: is $st, not triage; triage exits only handle triage cards"; return 1; }
  # Two kinds of card are never an exit (see the header). Every verb passes here, and so does every plan line.
  title="$(printf '%s' "$cj" | jq -r '.title')"
  g="$title"
  g="$(printf '%s' "$g" | tr '[:upper:]' '[:lower:]')" # gate-lower
  g="$(printf '%s' "$g" | sed -E 's/^[[:space:]]+//')" # gate-trim
  g="$(printf '%s' "$g" | sed -E 's/^(card[?]:[[:space:]]*)+//')" # gate-strip
  case "$g" in gate-*) echo "$card: is a milestone gate (title '$(one_line "$title")'); a gate is completed by the checkpoint or the operator and is no triage exit"; return 1;; esac # gate-guard
  [ "$(gate_reasons "$s" "$card")" = 0 ] || { echo "$card: is a milestone gate (it was blocked with a milestone-gate reason); a gate is completed by the checkpoint or the operator and is no triage exit"; return 1; } # gate-event
  kids="$(live_children "$s" "$card")"; [ -z "$kids" ] || { echo "$card: is the parent of live card(s) $kids; archiving it would release them (kanban_db.py:2159), so it is no triage exit"; return 1; } # parent-guard
  case "$act" in
    close) return 0;;
    fold)
      tgt="$arg"
      [[ $tgt =~ $card_re ]] || { echo "$card: fold needs --into <card id>, got '$tgt'"; return 1; }
      [ "$tgt" != "$card" ] || { echo "$card: cannot fold into itself"; return 1; }
      tj="$(card_json "$s" "$tgt")"
      [ -n "$tj" ] || { echo "$card: fold target $tgt does not exist on board $BOARD"; return 1; }
      tst="$(printf '%s' "$tj" | jq -r '.status')"
      case "$tst" in archived|triage|done) echo "$card: fold target $tgt is $tst; fold into a live card"; return 1;; esac
      return 0;;
    promote)
      if [ -n "$arg" ]; then
        # The guard first, on the name as given: Hermes trims and lowercases an assignee, so
        # " forge-overseer" and "FORGE-OVERSEER" are the overseer, and the guard says so.
        "$HERE/overseer-guard.sh" lane "$arg" >/dev/null || { echo "$card: --assignee '$arg' is refused: the overseer takes no chunk (MS3)"; return 1; }
        [[ $arg =~ $name_re ]] || { echo "$card: '$arg' is not a profile name"; return 1; }
      fi
      return 0;;
    *) echo "$card: unknown action '$act' (close, fold or promote)"; return 1;;
  esac
}

# run_one <snapshot> <action> <card> <into-or-assignee> <reason> -> 0 handled, 1 a call failed
run_one() {
  local s="$1" act="$2" card="$3" arg="$4" reason cj title body parents newjson newid="" p
  local args=()
  reason="$(one_line "$5")"
  cj="$(card_json "$s" "$card")"
  title="$(printf '%s' "$cj" | jq -r '.title')"; body="$(printf '%s' "$cj" | jq -r '.body')"
  case "$act" in
    close)
      board_write comment "$card" "triage close by $ACTOR: $reason" --author "$ACTOR" || return 1
      board_write archive "$card" || return 1;;
    fold)
      board_write comment "$arg" "triage fold by $ACTOR: $reason; folded from $card ($title)

$body" --author "$ACTOR" || return 1
      board_write comment "$card" "triage fold by $ACTOR: $reason; folded into $arg" --author "$ACTOR" || return 1
      board_write archive "$card" || return 1;;
    promote)
      parents="$(parents_of "$s" "$card")"
      for p in $parents; do args+=(--parent "$p"); done
      [ -z "$arg" ] || args+=(--assignee "$arg")
      title="${title#CARD[?]: }"
      # The title comes last, after `--`: a title that starts with '-' ("-x", "--help") would be read
      # as an option by Hermes's parser if it were a bare argument.
      if [ "$MODE" = apply ]; then
        newjson="$(printf '%s' "$body" | hermes kanban --board "$BOARD" create --body-file - \
                     --created-by "$ACTOR" --idempotency-key "triage-promote-$BOARD-$card" \
                     ${args[@]+"${args[@]}"} --json -- "$title" 2>"$WORK/create.err")" \
          || { echo "triage: creating the promoted card for $card failed: $(tail -n 1 "$WORK/create.err")" >&2; return 1; }
        newid="$(printf '%s' "$newjson" | jq -r '.id // empty' 2>/dev/null)"
        [ -n "$newid" ] || { echo "triage: create printed no card id for $card; the original is left in triage" >&2; return 1; }
      else
        echo "would run: hermes kanban --board $BOARD create --body-file - --created-by $ACTOR --idempotency-key triage-promote-$BOARD-$card ${args[*]:-} --json -- '$title'   (rehearsal: not run)"
        newid="<new card>"
      fi
      board_write comment "$card" "triage promote by $ACTOR: $reason; promoted as $newid" --author "$ACTOR" || return 1
      board_write archive "$card" || return 1;;
  esac
  if [ "$MODE" = apply ]; then echo "$act $card: done${newid:+ (promoted as $newid)}"; fi
  return 0
}

if [ "$ACTION" != plan ]; then
  [ -n "$CARD" ] || { echo "triage: --card is required" >&2; exit 2; }
  case "$ACTION" in fold) arg="$INTO";; promote) arg="$ASSIGNEE";; *) arg="";; esac
  S="$(snapshot)" || exit 2
  msg="$(validate_one "$S" "$ACTION" "$CARD" "$arg" "$REASON")" || { echo "triage: refused: $msg" >&2; exit 1; }
  run_one "$S" "$ACTION" "$CARD" "$arg" "$REASON" || { echo "triage: $ACTION $CARD stopped on a failed board call" >&2; exit 1; }
  if [ "$MODE" = rehearse ]; then echo "rehearsal: nothing was written to the board"; fi
  exit 0
fi

# ---- plan ------------------------------------------------------------------
[ -n "$PLAN" ] && [ -f "$PLAN" ] || { echo "triage: plan needs --file <plan>" >&2; exit 2; }
S="$(snapshot)" || exit 2
before="$(triage_count "$S")"
: >"$WORK/plan.rows"; refused=0; n=0
while IFS='|' read -r act card arg reason || [ -n "${act:-}" ]; do
  case "${act:-}" in ''|'#'*) continue;; esac
  n=$((n + 1))
  if msg="$(validate_one "$S" "$act" "$card" "$arg" "$reason")"; then
    printf '%s|%s|%s|%s\n' "$act" "$card" "$arg" "$reason" >> "$WORK/plan.rows"
  else
    refused=$((refused + 1)); echo "triage: plan line $n refused: $msg" >&2
  fi
done < "$PLAN"
[ "$n" -gt 0 ] || { echo "triage: the plan is empty" >&2; exit 1; }
[ "$refused" = 0 ] || { echo "triage: $refused plan line(s) refused; nothing was written" >&2; exit 1; }
dups="$(cut -d'|' -f2 "$WORK/plan.rows" | sort | uniq -d | paste -sd, -)"
[ -z "$dups" ] || { echo "triage: a card appears twice in the plan ($dups); nothing was written" >&2; exit 1; }

failed=0
while IFS='|' read -r act card arg reason; do
  run_one "$S" "$act" "$card" "$arg" "$reason" || { failed=1; echo "triage: stopped at $act $card" >&2; break; }
done < "$WORK/plan.rows"

if [ "$MODE" = rehearse ]; then
  cut -d'|' -f2 "$WORK/plan.rows" | sort > "$WORK/planned"
  left="$(sqlite3 "$S" "SELECT id FROM tasks WHERE status = 'triage' ORDER BY id;" | comm -23 - "$WORK/planned" | paste -sd, -)"
  echo "rehearsal: nothing was written to the board"
  if [ -n "$left" ]; then echo "triage: this plan would leave triage non-empty: $left" >&2; exit 1; fi
  echo "triage: this plan covers all $before card(s) in triage"
  exit "$failed"
fi
[ "$failed" = 0 ] || exit 1
S2="$(snapshot)" || exit 2
after="$(triage_count "$S2")"
if [ "$after" != 0 ]; then
  echo "triage: $after card(s) still in triage after the plan: $(sqlite3 "$S2" "SELECT id FROM tasks WHERE status = 'triage' ORDER BY id;" | paste -sd, -)" >&2
  exit 1
fi
echo "triage: board $BOARD is empty (was $before)"
exit 0
