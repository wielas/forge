#!/usr/bin/env bash
# =============================================================================
# forge gate-park — `/park <board> <GATE-id> [why]`: stop and leave the gate held (epic GW3, S8d).
#
# The one write is a comment on the gate card: `parked: <why>`, authored `operator`. The gate is
# already held, so this changes nothing about the next milestone; what it does is stop the cron
# (a decision is recorded for this hold and the gate is disarmed). Park is the stopping verb, so it
# asks for less than the others: only that the gate is `blocked`. It needs no reported block and no
# arming, and it works on a gate that was never armed.
#
# Usage:
#   scripts/gate-park.sh --board <board> --gate GATE-<m> [--text <why>] (--rehearse | --apply)
#   scripts/gate-park.sh --check
# Exit: 0 done (or rehearsed), 1 refused, 2 usage or the host cannot run it, 3 written but unconfirmed.
# =============================================================================
set -uo pipefail

gr_help() { awk 'NR>2 && /^# ={10,}/{exit} NR>2 {sub(/^# ?/, ""); print}' "$0"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || { echo "failed: script directory cannot be resolved"; exit 2; }
# shellcheck source=gate-reply.sh
. "$HERE/gate-reply.sh" || { echo "failed: cannot source gate-reply.sh"; exit 2; }
trap gr_cleanup EXIT

gr_parse_args "$@"
gr_check_tools
gr_validate "$GR_BOARD" "$GR_GATE"
gr_validate_text "$GR_TEXT" 0
BODY="parked: ${GR_TEXT:-no reason given}"

gr_load_gate "$GR_BOARD" "$GR_GATE"

if [ "$GR_MODE" = rehearse ]; then
  echo "rehearsal: would run: hermes kanban --board $GR_BOARD comment --author operator $GR_CARD \"$BODY\" (nothing was written)"
  exit 0
fi

# DISARM FIRST, THEN WRITE. The decision is recorded and the gate is disarmed before the comment is written, so a
# still-armed check made by the cron in between (checkpoint.sh --before-complete) already sees the decision: a comment
# written first, then the disarm, would leave a window in which the gate is still armed and undecided. If the comment
# then fails, the gate stays disarmed and decided: the safe side, and the reply says so.
gr_mark_decided "$GR_BOARD" "$GR_GATE" park
OUT="$(hermes kanban --board "$GR_BOARD" comment --author operator "$GR_CARD" "$BODY" 2>&1)"; RC=$?
if [ "$RC" != 0 ]; then
  printf '%s\n' "$OUT" >&2
  gr_fail "commenting on $GR_GATE ($GR_CARD) was refused by the board; the gate is now DISARMED and decided, so the cron has stopped, but the comment was not written"
fi
if ! gr_reread_comment "$BODY"; then
  printf 'unconfirmed: the comment on %s (%s) reported success, but a fresh read does not show it; the gate is DISARMED and decided; check the card\n' "$GR_GATE" "$GR_CARD"
  exit 3
fi
printf 'parked: %s (%s) stays held and the cron stops probing it.\n' "$GR_GATE" "$GR_CARD"
exit 0
