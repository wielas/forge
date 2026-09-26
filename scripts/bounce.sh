#!/usr/bin/env bash
# =============================================================================
# forge bounce — the operator disagrees with a recommendation.
#
# Recommend-only means the verifier's approval is a hold, not a merge. When the
# operator looks at the PR and disagrees, the card has to go back to its
# implementer with the reason ON it — the same card, the same worktree, the same
# PR (ADR-0019 D19.1, FL3's re-entry). That is two kernel writes, `unblock` then
# `reopen-review`, and the gap between them is the whole reason this is a script:
#
#   * `unblock` restores the card's source phase, which for a verifier hold is
#     `review` (measured on the installed kernel; `kanban_db.py:3650`).
#   * `reopen-review` only accepts `review`, and restores the implementer from
#     the `review_requested` event.
#
# Between those two writes the card is claimable, so a dispatcher tick can spawn
# a worker on it before the reason arrives. The card is therefore parked on the
# NON-SPAWNABLE sentinel `forge-operator-handoff` first — the same sentinel
# `hermes/board-bootstrap.sh` uses for human-tier cards and `lane-handoff.sh`
# unparks. EXECUTED 2026-09-26 in an isolated HERMES_HOME: a real
# `hermes kanban dispatch` pass inside that window reported
# "Skipped (non-spawnable assignee — terminal lane, OK)" and spawned nothing,
# and `reopen-review` still restored `forge-codex-lane` afterwards.
#
# The end state is READ BACK. The CLI's word is not evidence (FL3's rule): a
# bounce that looks like it worked and left the card parked on the sentinel is a
# card nothing will ever pick up.
#
# Usage: bounce.sh <card-id> "<reason>" [--board <slug>]
# Exit:  0 the card is back with its implementer, carrying the reason.
#        1 the round trip did not complete; the message says where it stopped.
#        2 a usage error.
# =============================================================================
set -uo pipefail

CARD=""; REASON=""; BOARD="${HERMES_KANBAN_BOARD:-}"
SENTINEL="${FORGE_HANDOFF_SENTINEL:-forge-operator-handoff}"
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --board) BOARD="${2:?--board needs a slug}"; shift 2;;
    -h|--help) awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; exit 0;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) if [ -z "$CARD" ]; then CARD="$1"; elif [ -z "$REASON" ]; then REASON="$1";
       else echo "too many arguments: '$1'" >&2; exit 2; fi; shift;;
  esac
done
[ -n "$CARD" ] && [ -n "$REASON" ] && [ -n "$BOARD" ] || { usagetext; exit 2; }
command -v hermes >/dev/null || { echo "bounce: hermes is not on PATH" >&2; exit 1; }
command -v jq     >/dev/null || { echo "bounce: jq is not on PATH" >&2; exit 1; }

kanban() { hermes kanban --board "$BOARD" "$@"; }
status()  { kanban show "$CARD" --json 2>/dev/null | jq -r '.task.status // "unreadable"'; }
assignee(){ kanban show "$CARD" --json 2>/dev/null | jq -r '.task.assignee // "none"'; }
implementer() {
  kanban show "$CARD" --json 2>/dev/null \
    | jq -r '[.events[]? | select(.kind == "review_requested")] | last | .payload.implementer // ""'
}

start="$(status)"
case "$start" in
  blocked) ;;
  review)  ;;   # already back in the reviewer's hands: only the reopen is owed
  *) echo "bounce: $CARD is '$start'; a bounce applies to a card the verifier is holding (blocked) or reviewing (review)" >&2
     exit 1;;
esac

want_implementer="$(implementer)"
if [ "$start" = blocked ]; then
  kanban assign "$CARD" "$SENTINEL" >/dev/null 2>&1 \
    || { echo "bounce: could not park $CARD on $SENTINEL; refusing to open the window" >&2; exit 1; }
  kanban unblock "$CARD" >/dev/null 2>&1 \
    || { echo "bounce: could not unblock $CARD (it is '$(status)')" >&2; exit 1; }
  [ "$(status)" = review ] \
    || { echo "bounce: $CARD unblocked to '$(status)', not 'review'; reopen-review would refuse it" >&2; exit 1; }
fi

kanban reopen-review "$CARD" --reason "$REASON" >/dev/null 2>&1 \
  || { echo "bounce: reopen-review refused $CARD (it is '$(status)')" >&2; exit 1; }

end="$(status)"; who="$(assignee)"
case "$end" in ready|todo) ;; *) echo "bounce: $CARD ended '$end', not back with its implementer" >&2; exit 1;; esac
if [ "$who" = "$SENTINEL" ] || [ "$who" = none ]; then
  # reopen-review restores the implementer from the review_requested event; if
  # that event is missing (a card handed over by hand) it has nothing to restore,
  # and a card parked on a non-spawnable sentinel is a card nothing picks up.
  [ -n "$want_implementer" ] \
    || { echo "bounce: $CARD is '$end' but assigned '$who', and no review_requested event names an implementer to restore" >&2; exit 1; }
  kanban assign "$CARD" "$want_implementer" >/dev/null 2>&1
  who="$(assignee)"
fi
[ "$who" != "$SENTINEL" ] && [ "$who" != none ] \
  || { echo "bounce: $CARD is '$end' but still parked on '$who'" >&2; exit 1; }
echo "$CARD: back with $who ($end) — $REASON"
