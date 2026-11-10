#!/usr/bin/env bash
# =============================================================================
# forge gate-accept — `/accept <board> <GATE-id> [why]`: complete a held gate (epic GW3, S8d).
#
# The one write is `hermes kanban --board <board> complete <gate> --result "accepted: <why>"`.
# The result is NEVER `checkpoint pass:`: metrics.sh counts a gate completed that way as the
# checkpoint's, and every other completion as the operator's (`gate_completions`, P14), so an
# accept from a phone is counted as what it is.
#
# REFUSED, with nothing written, unless ALL of these hold (scripts/gate-reply.sh):
#   - the board has exactly one card for the gate, and it is `blocked`;
#   - the checkpoint reported a block for THIS hold (checkpoint/pending/ names the hold);
#   - the gate is armed `apply` (scripts/checkpoint-arm.sh). Armed `rehearse` is not enough, and
#     neither is a file that is malformed: this is what keeps a phone from releasing GATE-M1
#     before the owner's go (decision 4, 2026-11-09).
# After the write the gate is read back from a fresh snapshot and must read `done`; a `complete`
# that exits 0 over a gate that is not done is exit 3, "check the card", not a success.
#
# Usage:
#   scripts/gate-accept.sh --board <board> --gate GATE-<m> [--text <why>] (--rehearse | --apply)
#   scripts/gate-accept.sh --check
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
WHY="${GR_TEXT:-no reason given}"

gr_load_gate "$GR_BOARD" "$GR_GATE"
gr_require_pending "$GR_BOARD" "$GR_GATE"
gr_read_armed "$GR_BOARD" "$GR_GATE" || gr_refuse "$GR_GATE is not armed, so nothing is completed from here (arm it with scripts/checkpoint-arm.sh)"
[ "$GR_ARM_MODE" = apply ] || gr_refuse "$GR_GATE is armed for rehearsal only, which completes nothing (arm it apply with scripts/checkpoint-arm.sh to release it)"

if [ "$GR_MODE" = rehearse ]; then
  echo "rehearsal: would run: hermes kanban --board $GR_BOARD complete $GR_CARD --result \"accepted: $WHY\" (nothing was written)"
  exit 0
fi

OUT="$(hermes kanban --board "$GR_BOARD" complete "$GR_CARD" --result "accepted: $WHY" 2>&1)"; RC=$?
if [ "$RC" != 0 ]; then
  printf '%s\n' "$OUT" >&2
  gr_fail "completing $GR_GATE ($GR_CARD) was refused by the board; it is still held"
fi
GR_NOW=""
if ! gr_reread_status; then
  printf 'unconfirmed: completing %s (%s) reported success, but the board could not be read back; check the card\n' "$GR_GATE" "$GR_CARD"
  exit 3
fi
if [ "$GR_NOW" != done ]; then
  printf 'unconfirmed: completing %s (%s) reported success, but a fresh read says it is "%s", not done; check the card\n' "$GR_GATE" "$GR_CARD" "${GR_NOW:-gone}"
  exit 3
fi
gr_mark_decided "$GR_BOARD" "$GR_GATE" accept
printf 'accepted: %s (%s) is complete on board %s; the next milestone can start.\n' "$GR_GATE" "$GR_CARD" "$GR_BOARD"
exit 0
