#!/usr/bin/env bash
# =============================================================================
# forge checkpoint-arm — the switch that lets the checkpoint cron touch a gate (epic GW3, S8d).
#
# scripts/checkpoint-cron.sh runs from `hermes cron --no-agent` every few minutes and looks ONLY at gates
# that have an arming file. NO FILE, NO ACTION: a gate nobody armed is never probed, never completed and
# never reported. That is the safety property GATE-M1 relies on, since its probe passed 5 of 5 and its
# chunks are done, so an `apply` tick would complete it (docs/epic-hands-free.md, decision 6, run A):
# it is armed `apply` only at the owner's go for run B (S9). S8e arms it `rehearse`.
#
#   arm      write <state>/checkpoint/armed/<board>--<gate>: two lines, `mode=` and `project=` (an absolute
#            path to the product checkout the probe runs in). The mode is REQUIRED and has no default.
#            `--mode apply` also needs --confirm-release, because on a passing probe the cron COMPLETES the
#            gate, which releases the next milestone. Arming starts a gate fresh: the host's records of an
#            earlier report, decision or probe for it are cleared.
#   disarm   remove the file. The cron stops looking.
#   list     every armed gate, its mode and project. A file that is not exactly two well-formed lines is
#            listed as MALFORMED and counts as NOT armed everywhere (exit 1).
#
# Modes: `rehearse` runs scripts/checkpoint.sh --rehearse, which writes nothing, and `apply` runs --apply.
#
# Usage:
#   scripts/checkpoint-arm.sh arm --board <board> --gate GATE-<m> --project <abs-dir> --mode rehearse
#   scripts/checkpoint-arm.sh arm --board <board> --gate GATE-<m> --project <abs-dir> --mode apply --confirm-release
#   scripts/checkpoint-arm.sh disarm --board <board> --gate GATE-<m>
#   scripts/checkpoint-arm.sh list
# Exit: 0 done, 1 a malformed file in `list`, 2 usage or the host cannot do it.
# =============================================================================
set -uo pipefail

gr_help() { awk 'NR>2 && /^# ={10,}/{exit} NR>2 {sub(/^# ?/, ""); print}' "$0"; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || { echo "checkpoint-arm: script directory cannot be resolved" >&2; exit 2; }
# shellcheck source=gate-reply.sh
. "$HERE/gate-reply.sh" || { echo "checkpoint-arm: cannot source gate-reply.sh" >&2; exit 2; }

die() { echo "checkpoint-arm: $*" >&2; exit 2; }

CMD="${1:-}"; [ $# -eq 0 ] || shift
BOARD=""; GATE=""; PROJECT=""; MODE=""; CONFIRM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --board)   [ $# -ge 2 ] || die "--board needs a board name"; BOARD="$2"; shift 2;;
    --gate)    [ $# -ge 2 ] || die "--gate needs a gate id"; GATE="$2"; shift 2;;
    --project) [ $# -ge 2 ] || die "--project needs a directory"; PROJECT="$2"; shift 2;;
    --mode)    [ $# -ge 2 ] || die "--mode needs rehearse or apply"; MODE="$2"; shift 2;;
    --confirm-release) CONFIRM=1; shift;;
    -h|--help) gr_help; exit 0;;
    *) die "unknown argument '$1'";;
  esac
done

STATE="$(gr_state_dir)"
case "$CMD" in
  arm|disarm)
    [ -n "$BOARD" ] && [ -n "$GATE" ] || die "$CMD needs --board and --gate"
    [[ $BOARD =~ $GR_BOARD_RE ]] && [[ $BOARD != *--* ]] || die "'$BOARD' is not a board name"
    [[ $GATE =~ $GR_GATE_RE ]] || die "'$GATE' is not a gate id (GATE-<milestone>)"
    KEY="$(gr_key "$BOARD" "$GATE")"
    if [ "$CMD" = disarm ]; then
      rm -f "$STATE/armed/$KEY" || die "cannot remove $STATE/armed/$KEY"
      echo "disarmed $GATE on board $BOARD: the cron will not look at it"
      exit 0
    fi
    case "$MODE" in rehearse|apply) ;; "") die "arm needs --mode rehearse (completes nothing) or --mode apply";; *) die "--mode is rehearse or apply, not '$MODE'";; esac
    if [ "$MODE" = apply ] && [ "$CONFIRM" != 1 ]; then
      die "--mode apply COMPLETES $GATE on a passing probe, which releases the next milestone; add --confirm-release if that is the intent"
    fi
    case "$PROJECT" in /*) ;; *) die "--project must be an absolute path to the product checkout";; esac
    [ -d "$PROJECT" ] || die "no such project directory: $PROJECT"
    case "$PROJECT" in *[[:cntrl:]]*) die "the project path has control characters";; esac
    mkdir -p "$STATE/armed" "$STATE/pending" "$STATE/decided" "$STATE/probed" "$STATE/reported" || die "cannot create $STATE"
    # Fresh start: a report, a decision or a probe record belongs to the arming that made it.
    rm -f "$STATE/pending/$KEY.json" "$STATE/decided/$KEY.json" "$STATE/reported/$KEY".* "$STATE/probed/$KEY"--* 2>/dev/null
    TMP="$(mktemp "$STATE/armed/.tmp.XXXXXX")" || die "cannot write under $STATE/armed"
    printf 'mode=%s\nproject=%s\n' "$MODE" "$PROJECT" > "$TMP" && mv -f "$TMP" "$STATE/armed/$KEY" || { rm -f "$TMP"; die "cannot write the arming file"; }
    if [ "$MODE" = apply ]; then
      echo "ARMED APPLY: $GATE on board $BOARD (project $PROJECT). A passing probe will COMPLETE the gate."
    else
      echo "armed rehearse: $GATE on board $BOARD (project $PROJECT). Nothing is completed."
    fi
    exit 0;;
  list)
    BAD=0; N=0
    for f in "$STATE"/armed/*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      name="${f##*/}"; case "$name" in .tmp.*) continue;; esac
      N=$((N+1))
      b="${name%%--GATE-*}"; g="GATE-${name#*--GATE-}"
      if [[ $b =~ $GR_BOARD_RE ]] && [[ $g =~ $GR_GATE_RE ]] && [ "$name" = "$(gr_key "$b" "$g")" ] && gr_read_armed "$b" "$g"; then
        printf '%s %s %s %s\n' "$b" "$g" "$GR_ARM_MODE" "$GR_ARM_PROJECT"
      else
        printf 'MALFORMED %s (not armed)\n' "$f"; BAD=$((BAD+1))
      fi
    done
    [ "$N" -gt 0 ] || echo "no gate is armed"
    [ "$BAD" = 0 ] || exit 1
    exit 0;;
  *) die "usage: checkpoint-arm.sh arm|disarm|list ... (see --help)";;
esac
