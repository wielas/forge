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
# THIS IS THE OPERATOR'S TOOL, AND ONLY THE OPERATOR'S (epic S6d, P24). A
# lane worker no longer calls it: Hermes fences a worker's terminal, so every
# `hermes kanban` mutation made from it — this one included — is refused, and the
# lane hands off through the `kanban_request_review` TOOL the lane.sh envelope
# names (the driver makes that call; `lane.sh` validates the envelope first and
# always names the reviewer). Run A's first attempt (2026-10-03) was exactly this
# script failing under the fence: "delegate_task child contexts cannot mutate
# Kanban tasks via the CLI". Under the fence it now says so and refuses.
#
# THE REVIEWER IS ALWAYS EXPLICIT — after an operator `reopen-review` there is no
# `changes_requested` run, so the kernel's default reviewer is None and the card
# would be dispatched back to the lane to review itself.
#
# THE CALLER is the operator, from their own unfenced shell: a human-tier chunk
# finished in Claude Code or Pi. The card is `ready`, or `blocked`
# (board-bootstrap parks human chunks there); a blocked card is unblocked and
# handed off back-to-back, and the END STATE is re-read because a dispatcher
# tick can land between the two writes. An unassigned card is first given the
# non-spawnable sentinel `forge-operator-handoff`, so a bounce has an
# implementer to return to (epic P21).
#
# Usage: lane-handoff.sh <task-id> --metadata <file> --summary <text>
#                        [--reviewer <profile>] [--board <slug>]
#
# Exit: 0 handed off — the card is in `review`, assigned to the reviewer.
#       3 refused — the envelope failed its contract, the kernel refused the
#         transition, the card did not land in review, or this is a fenced worker
#         terminal. A canonical `<class>: <reason>` is the last line of stdout.
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
# A fenced terminal (a worker's, or any descendant of one) cannot do any of this;
# saying so is better than the kernel's one-line refusal after the validation.
[ -z "${HERMES_DELEGATED_CHILD_CONTEXT:-}" ] \
  || refuse "env: lane-handoff.sh is the operator's path and this is a fenced worker terminal (HERMES_DELEGATED_CHILD_CONTEXT is set) — a worker terminates through the kanban_request_review tool its lane.sh envelope names"
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

# A HUMAN-TIER CARD NEEDS AN IMPLEMENTER ON RECORD (epic P21). The kernel returns
# a bounce to the assignee recorded at request-review, and refuses
# `request-changes` when there was none ("review handoff has no valid
# implementer provenance", measured on 0.21.5) — and board-bootstrap.sh takes
# the sentinel back off an interactive card, so an operator's handoff starts
# unassigned. The verifier then strands the card as `handoff-integrity`. So the
# non-spawnable sentinel goes on first: a bounce lands the card `ready` on it,
# where nothing spawns it and the digest lists it as waiting on the operator.
# BEFORE the unblock, so the card is never `ready` with nobody on it.
SENTINEL="${FORGE_HANDOFF_SENTINEL:-forge-operator-handoff}"
if [ -z "${assignee:-}" ]; then
  kanban assign "$TASK" "$SENTINEL" >/dev/null 2>&1 \
    || refuse "other: card $TASK has no implementer on record and could not be given $SENTINEL"
fi
if [ "$status" = blocked ]; then
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
