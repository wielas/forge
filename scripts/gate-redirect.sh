#!/usr/bin/env bash
# =============================================================================
# forge gate-redirect — `/redirect <board> <GATE-id> <text>`: say what to change (epic GW3, S8d).
#
# The one write is a comment on the gate card: `redirect: <text>`, authored `operator`, which
# metrics.sh counts as an operator touch. Nothing reads the text: the run waits, the gate stays
# held, and the operator changes the plan and arms the gate again (owner decision 2, 2026-11-09).
# What it does on the host is record the decision for this hold and disarm the gate, so the cron
# stops probing it.
#
# REFUSED, with nothing written, unless the gate is `blocked`, the checkpoint reported a block for
# THIS hold, the gate is armed (either mode: a comment completes nothing), and the text is 1 to
# 1000 characters (scripts/gate-reply.sh).
#
# Usage:
#   scripts/gate-redirect.sh --board <board> --gate GATE-<m> --text <text> (--rehearse | --apply)
#   scripts/gate-redirect.sh --check
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
gr_validate_text "$GR_TEXT" 1
BODY="redirect: $GR_TEXT"

gr_load_gate "$GR_BOARD" "$GR_GATE"
gr_require_pending "$GR_BOARD" "$GR_GATE"
gr_read_armed "$GR_BOARD" "$GR_GATE" || gr_refuse "$GR_GATE is not armed, so there is no checkpoint run to redirect"

if [ "$GR_MODE" = rehearse ]; then
  echo "rehearsal: would run: hermes kanban --board $GR_BOARD comment --author operator $GR_CARD \"$BODY\" (nothing was written)"
  exit 0
fi

# DISARM FIRST, THEN WRITE. The decision is recorded and the gate is disarmed before the comment is written, so a
# still-armed check made by the cron in between (checkpoint.sh --before-complete) already sees the decision: a comment
# written first, then the disarm, would leave a window in which the gate is still armed and undecided. If the comment
# then fails, the gate stays disarmed and decided: the safe side, and the reply says so.
gr_mark_decided "$GR_BOARD" "$GR_GATE" redirect
OUT="$(hermes kanban --board "$GR_BOARD" comment --author operator "$GR_CARD" "$BODY" 2>&1)"; RC=$?
if [ "$RC" != 0 ]; then
  printf '%s\n' "$OUT" >&2
  gr_fail "commenting on $GR_GATE ($GR_CARD) was refused by the board; the gate is now DISARMED and decided, so the cron has stopped, but the comment was not written"
fi
if ! gr_reread_comment "$BODY"; then
  printf 'unconfirmed: the comment on %s (%s) reported success, but a fresh read does not show it; the gate is DISARMED and decided; check the card\n' "$GR_GATE" "$GR_CARD"
  exit 3
fi
printf 'redirect recorded on %s (%s). The gate stays held and the cron stops probing it; change the plan, then arm it again.\n' "$GR_GATE" "$GR_CARD"
exit 0
