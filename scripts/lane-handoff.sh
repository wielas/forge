#!/usr/bin/env bash
# =============================================================================
# forge lane-handoff — hand ONE chunk card to its reviewer, on the same card
# (epic FL3, ADR-0019 D19.1).
#
# A chunk card lives its whole life as one card: implemented, reviewed on
# itself, `done` only once its PR merged. The implementer's last act is this
# transition — `running → review`, reassigned to the reviewer — made by a
# program so that no model creates, links or completes a card. Before this,
# the lane completed its card at PR-open and CREATED a prejudge child; the two
# product runs averaged 1.9 and 3.5 cards per chunk, and the CHUNK-8 card
# storm was a cheap model making exactly those calls.
#
# WHY THIS IS NOT `kanban_complete`. A card in `review` is not `done`, and
# `_parents_satisfied` counts only done/archived — so holding the card here
# until the PR merges is what gates its children natively (ADR-0019 D19.5).
# Completing it would release every dependent onto unmerged code, which is
# the PR #8 failure ADR-0008 was written for.
#
# WHY THIS IS NOT THE MODEL'S `kanban_request_review` TOOL. That tool stays
# forbidden to the lane driver (forge-lane, lane/terminator-set-is-closed):
# a cheap driver reaching for it by habit would hand off unvalidated metadata,
# with no reviewer named. The call below is the same kernel transition with
# the envelope validated first and the reviewer ALWAYS explicit — after an
# operator `reopen-review` there is no `changes_requested` run, so the kernel's
# default reviewer is None and the card would be dispatched back to the lane
# to review itself.
#
# TWO CALLERS, ONE SCRIPT.
#   worker    inside a dispatcher-spawned run (HERMES_KANBAN_TASK is this card
#             and HERMES_KANBAN_RUN_ID is set). The Hermes CLI binds the run id
#             from that environment and passes it as expected_run_id, so the
#             transition proves ownership of the live claim. lane.sh calls it.
#   operator  a human-tier chunk finished in Claude Code or Pi. The card is
#             `ready`, or `blocked` (board-bootstrap parks human chunks there);
#             a blocked card is unblocked and handed off back-to-back, and the
#             END STATE is re-read because a dispatcher tick can land between
#             the two writes.
#
# Usage: lane-handoff.sh <task-id> --metadata <file> --summary <text>
#                        [--reviewer <profile>] [--board <slug>]
#
# Exit: 0 handed off — the card is in `review`, assigned to the reviewer.
#       3 refused — the envelope failed its contract, the kernel refused the
#         transition, or the card did not land in review. A canonical
#         `<class>: <reason>` is the last line of stdout.
#       2 usage.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TASK="" META="" SUMMARY="" REVIEWER="${FORGE_LANE_REVIEWER:-forge-verifier}"
BOARD="${HERMES_KANBAN_BOARD:-}"
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --metadata) META="${2:?--metadata needs a file}"; shift 2;;
    --summary)  SUMMARY="${2:?--summary needs text}"; shift 2;;
    --reviewer) REVIEWER="${2:?--reviewer needs a profile}"; shift 2;;
    --board)    BOARD="${2:?--board needs a slug}"; shift 2;;
    -h|--help)  awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; exit 0;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) [ -z "$TASK" ] || { echo "only one task: '$TASK' and '$1'" >&2; exit 2; }
       TASK="$1"; shift;;
  esac
done
[ -n "$TASK" ] && [ -n "$META" ] && [ -n "$SUMMARY" ] || { usagetext; exit 2; }
[ -n "$REVIEWER" ] || { echo "usage: the reviewer may not be empty" >&2; exit 2; }
refuse() { echo "$1"; exit 3; }
command -v jq >/dev/null || refuse "env: jq missing"
command -v hermes >/dev/null || refuse "env: hermes is not on PATH"
kanban() { if [ -n "$BOARD" ]; then hermes kanban --board "$BOARD" "$@"; else hermes kanban "$@"; fi; }

# The envelope rides the review_requested run, which is where the verifier and
# /retro read it. It is validated here, before the transition, because nothing
# downstream re-checks it: validate-metadata.py used to sit only on the
# kanban_complete path.
[ -r "$META" ] || refuse "other: handoff metadata $META is unreadable"
"$HERE/validate-metadata.py" --profile forge-codex-lane "$META" > "${TMPDIR:-/tmp}/lane-handoff.$$" 2>&1
vrc=$?
vline="$(grep -v '^[[:space:]]*$' "${TMPDIR:-/tmp}/lane-handoff.$$" | head -1)"
rm -f "${TMPDIR:-/tmp}/lane-handoff.$$"
[ "$vrc" = 0 ] || refuse "other: the handoff envelope failed its contract — ${vline:-validate-metadata.py exited $vrc}"

status_of() { kanban show "$TASK" --json 2>/dev/null | jq -r '[.task.status, .task.assignee] | @tsv'; }
IFS=$'\t' read -r status assignee < <(status_of)
[ -n "${status:-}" ] || refuse "env: cannot read card $TASK"

worker=0
[ "${HERMES_KANBAN_TASK:-}" = "$TASK" ] && [ -n "${HERMES_KANBAN_RUN_ID:-}" ] && worker=1
if [ "$worker" = 0 ] && [ "$status" = blocked ]; then
  kanban unblock "$TASK" >/dev/null 2>&1 || refuse "other: card $TASK is blocked and could not be unblocked for handoff"
fi
kanban request-review "$TASK" --reviewer "$REVIEWER" --summary "$SUMMARY" \
  --metadata "$(cat "$META")" > "${TMPDIR:-/tmp}/lane-handoff-rr.$$" 2>&1
rrc=$?
rline="$(tail -1 "${TMPDIR:-/tmp}/lane-handoff-rr.$$")"
rm -f "${TMPDIR:-/tmp}/lane-handoff-rr.$$"

# The kernel's word is not the end state. Read the card back: only `review`,
# assigned to the named reviewer, is a handoff.
IFS=$'\t' read -r status assignee < <(status_of)
if [ "$rrc" = 0 ] && [ "$status" = review ] && [ "$assignee" = "$REVIEWER" ]; then
  echo "handed off: $TASK is in review, assigned to $REVIEWER"
  exit 0
fi
refuse "other: handoff of $TASK did not land — request-review rc $rrc (${rline:-no output}); card is ${status:-unreadable}, assigned to ${assignee:-nobody}"
