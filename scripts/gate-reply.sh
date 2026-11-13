# shellcheck shell=bash
# =============================================================================
# forge gate-reply — what the three decision verbs share (epic GW3, S8d).
#
# SOURCED, NEVER EXECUTED (it carries +x all the same: preflight lists every
# script it sources and FAILs one that is not executable). The three programs
# that source it are the whole of what a phone can do to a milestone gate:
#
#   scripts/gate-accept.sh    complete the gate          (the one write: `complete`)
#   scripts/gate-redirect.sh  say what to change         (the one write: a comment)
#   scripts/gate-park.sh      stop and leave it held     (the one write: a comment)
#
# They are reached only from the forge-gateway plugin's handlers, each handler
# calling exactly one, and by the operator by hand. This file holds the checks
# the three agree on, so that "the gate is blocked, this block was reported, the
# gate is armed" is one definition and not three.
#
# THE CHECKS, all made on a snapshot copy of the board (never mode=ro: a Hermes
# board is WAL, scripts/board-snapshot.sh) and all before the one write:
#   - the board exists and exactly one card is the gate (`GATE-<m>` or `GATE-<m>: ...`);
#   - the gate is `blocked`, that is, held;
#   - THE HOLD: the id of the gate's last `blocked` event. A block is reported
#     once per hold (scripts/checkpoint-cron.sh writes checkpoint/pending/ with
#     the hold it reported), and a reply is honoured only for the hold that was
#     reported, so a stale record can never license a later block;
#   - the gate is ARMED: checkpoint/armed/<board>--<gate> holds exactly two
#     lines, `mode=rehearse|apply` and `project=/abs/path`, byte for byte as
#     checkpoint-arm.sh writes them. Anything else, a malformed file, a symlink,
#     a third line (terminated or not), a missing final newline, reads as NOT armed. `complete`
#     needs `apply`; `rehearse` completes nothing (scripts/checkpoint-arm.sh).
#
# WHAT A DECISION LEAVES BEHIND, on the host (not on the board):
#   checkpoint/decided/<board>--<gate>.json   {verb, hold, at}: the cron stops for that hold
# and the arming file is removed, so the next probe needs the operator to arm
# the gate again. Redirect and park act on no automation: nothing reads the
# text of a redirect (owner decision 2, 2026-11-09).
#
# EXIT CODES the three programs share:
#   0  done (or, with --rehearse, would be done: nothing was written)
#   1  refused: a check failed, nothing was written
#   2  usage, or the host cannot run it (a tool is missing, the board cannot be read)
#   3  the write was made but its effect could not be confirmed: check the card
# stdout carries the one-line reply the operator reads; stderr carries diagnostics.
# =============================================================================

GR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || GR_HERE=""
# shellcheck source=forge-state.sh
. "$GR_HERE/forge-state.sh" || { echo "failed: cannot source forge-state.sh" >&2; exit 2; }

# The gateway runs under launchd with whatever PATH the plist gave it, and `hermes` lives in
# ~/.local/bin (docs/hermes-field-notes.md, the PATH trap): add the usual homes, after the caller's.
PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"

GR_BOARD_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
GR_GATE_RE='^GATE-[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'
GR_TEXT_MAX=1000

gr_state_dir() { printf '%s/checkpoint' "$(forge_state_root)"; }
gr_key()       { printf '%s--%s' "$1" "$2"; }

# gr_refuse <reason>: the reply the operator reads, exit 1. Nothing has been written.
gr_refuse() { printf 'refused: %s\n' "$1"; exit 1; }
gr_fail()   { printf 'failed: %s\n' "$1"; exit 2; }

# gr_check_tools: the programs this needs, named when one is missing. Exit 2.
gr_check_tools() {
  local t miss=""
  for t in sqlite3 jq hermes shasum; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
  [ -x "$GR_HERE/board-snapshot.sh" ] || miss="$miss board-snapshot.sh"
  [ -z "$miss" ] || gr_fail "the host is missing:$miss"
}

# gr_validate <board> <gate>: shapes only. `--` would make the <board>--<gate> key ambiguous.
gr_validate() {
  [[ $1 =~ $GR_BOARD_RE ]] || gr_refuse "'$1' is not a board name"
  case "$1" in *--*) gr_refuse "'$1' is not a board name";; esac
  [[ $2 =~ $GR_GATE_RE ]] || gr_refuse "'$2' is not a gate id (GATE-<milestone>)"
}

# gr_validate_text <text> <required 0|1>: 1 to 1000 characters, no control characters but newline and tab.
gr_validate_text() {
  local text="$1" required="$2" clean
  if [ -z "$text" ]; then
    [ "$required" = 0 ] || gr_refuse "this needs some text (1 to $GR_TEXT_MAX characters)"
    return 0
  fi
  [ "${#text}" -le "$GR_TEXT_MAX" ] || gr_refuse "the text is ${#text} characters; the limit is $GR_TEXT_MAX"
  clean="$(printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
  [ "$clean" = "$text" ] || gr_refuse "the text has control characters"
}

# gr_try_load_gate <board> <gate>: reads the gate WITHOUT exiting; for a caller that has other gates to look
# at (scripts/checkpoint-cron.sh). Returns 0 and sets GR_CARD, GR_STATUS, GR_HOLD, GR_DB, GR_SNAP (the
# snapshot read) when the gate is exactly one card and `blocked` with a recorded block event. Otherwise
# returns 1 (a refusal: GR_WHY says why) or 2 (the host could not read: GR_WHY says what). GR_WORK is a
# scratch directory the caller removes.
gr_try_load_gate() {
  local board="$1" gate="$2" rows n snap
  local hroot="${HERMES_HOME:-$HOME/.hermes}"
  local kroot="${HERMES_KANBAN_HOME:-$hroot/kanban}"
  GR_WHY=""; GR_CARD=""; GR_STATUS=""; GR_HOLD=""
  if [ "$board" = default ]; then GR_DB="$hroot/kanban.db"; else GR_DB="$kroot/boards/$board/kanban.db"; fi
  [ -f "$GR_DB" ] || { GR_WHY="there is no board named '$board'"; return 1; }
  if [ -z "${GR_WORK:-}" ] || [ ! -d "$GR_WORK" ]; then
    GR_WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-gate-reply.XXXXXX")" || { GR_WHY="cannot make a scratch directory"; return 2; }
  fi
  GR_READS=$(( ${GR_READS:-0} + 1 ))
  snap="$("$GR_HERE/board-snapshot.sh" "$GR_DB" "$GR_WORK/read$GR_READS" 2>/dev/null)" && [ -n "$snap" ] \
    || { GR_WHY="board '$board' could not be read, so nothing was decided"; return 2; }
  GR_SNAP="$snap"
  rows="$(sqlite3 "$snap" "SELECT json_object('card', id, 'status', status)
            FROM tasks WHERE substr(title, 1, length('$gate') + 1) = '$gate:' OR title = '$gate';" 2>/dev/null)" \
    || { GR_WHY="board '$board' could not be queried"; return 2; }
  n="$(printf '%s\n' "$rows" | grep -c .)"
  case "$n" in
    1) ;;
    0) GR_WHY="board '$board' has no card for $gate"; return 1;;
    *) GR_WHY="board '$board' has more than one card for $gate"; return 1;;
  esac
  GR_CARD="$(printf '%s' "$rows" | jq -r '.card')"
  GR_STATUS="$(printf '%s' "$rows" | jq -r '.status')"
  [ "$GR_STATUS" = blocked ] || { GR_WHY="$gate ($GR_CARD) is $GR_STATUS, not blocked; there is no hold to decide"; return 1; }
  GR_HOLD="$(sqlite3 "$snap" "SELECT COALESCE(MAX(id), 0) FROM task_events WHERE task_id = '$GR_CARD' AND kind = 'blocked';" 2>/dev/null)" \
    || { GR_WHY="the events of $GR_CARD could not be read"; return 2; }
  case "$GR_HOLD" in ''|*[!0-9]*|0) GR_WHY="$gate ($GR_CARD) is blocked but has no recorded block event, so it has no hold to decide"; return 1;; esac
  return 0
}

# gr_load_gate <board> <gate>: the same, for a verb: it refuses (exit 1) or fails (exit 2) on the spot.
gr_load_gate() {
  gr_try_load_gate "$1" "$2"
  case $? in
    0) return 0;;
    1) gr_refuse "$GR_WHY";;
    *) gr_fail "$GR_WHY";;
  esac
}

# gr_read_armed <board> <gate>: sets GR_ARM_MODE and GR_ARM_PROJECT; succeeds only for a well-formed file.
gr_read_armed() {
  GR_ARM_MODE=""; GR_ARM_PROJECT=""
  local f l1 l2 n
  f="$(gr_state_dir)/armed/$(gr_key "$1" "$2")"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  # The file is checked BYTE FOR BYTE against what checkpoint-arm.sh writes, not by counting newlines (a third,
  # unterminated line is not counted by `wc -l`): read the two values, rebuild the file and compare. A trailing
  # newline is part of the format, so a file without one is not armed either.
  l1="$(sed -n 1p "$f")"; l2="$(sed -n 2p "$f")"
  case "$l1" in mode=apply|mode=rehearse) GR_ARM_MODE="${l1#mode=}";; *) return 1;; esac
  case "$l2" in project=/*) GR_ARM_PROJECT="${l2#project=}";; *) GR_ARM_MODE=""; return 1;; esac
  if [ "$(cat "$f"; printf x)" != "$(printf 'mode=%s\nproject=%s\n' "$GR_ARM_MODE" "$GR_ARM_PROJECT"; printf x)" ]; then
    GR_ARM_MODE=""; GR_ARM_PROJECT=""; return 1
  fi
  case "$GR_ARM_PROJECT" in *[[:cntrl:]]*) GR_ARM_MODE=""; GR_ARM_PROJECT=""; return 1;; esac
  return 0
}

# gr_require_pending <board> <gate>: a block was reported for THIS hold.
gr_require_pending() {
  local f; f="$(gr_state_dir)/pending/$(gr_key "$1" "$2").json"
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    gr_refuse "no checkpoint block has been reported for $2, so there is nothing to answer"
  fi
  jq -e --arg b "$1" --arg g "$2" --argjson h "$GR_HOLD" \
      '.schema == "forge.checkpoint-pending.v1" and .board == $b and .gate == $g and .hold == $h' "$f" >/dev/null 2>&1 \
    || gr_refuse "the block that was reported for $2 is not the gate's current hold (hold $GR_HOLD), so it is not answered"
}

# gr_mark_decided <board> <gate> <verb>: the host's record of the decision, then the gate is disarmed.
# Not a board write. Failing to record is reported on stderr and does not undo the decision.
gr_mark_decided() {
  local board="$1" gate="$2" verb="$3" d tmp
  d="$(gr_state_dir)/decided"
  if mkdir -p "$d" 2>/dev/null && tmp="$(mktemp "$d/.tmp.XXXXXX" 2>/dev/null)" \
     && jq -nc --arg b "$board" --arg g "$gate" --arg v "$verb" --argjson h "$GR_HOLD" --argjson at "$(date +%s)" \
          '{schema: "forge.gate-decision.v1", board: $b, gate: $g, hold: $h, verb: $v, at: $at}' > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$d/$(gr_key "$board" "$gate").json" 2>/dev/null; then
    :
  else
    [ -z "${tmp:-}" ] || rm -f "$tmp" 2>/dev/null
    echo "gate-reply: could not record the decision under $d; the cron may probe this hold again" >&2
  fi
  rm -f "$(gr_state_dir)/armed/$(gr_key "$board" "$gate")" 2>/dev/null || true
}

# gr_reread_status: the gate's status on a fresh snapshot, into GR_NOW. Two tries; fails if neither read the board.
gr_reread_status() {
  local try snap
  for try in 1 2; do
    snap="$("$GR_HERE/board-snapshot.sh" "$GR_DB" "$GR_WORK/read-after$try" 2>/dev/null)" && [ -n "$snap" ] || continue
    GR_NOW="$(sqlite3 "$snap" "SELECT status FROM tasks WHERE id = '$GR_CARD';" 2>/dev/null)" && return 0
  done
  return 1
}

# gr_sql_escape <text>: the text with every ' doubled, for a SQL string literal. THE QUOTE IS IN A VARIABLE ON
# PURPOSE: /bin/bash 3.2 (the mini's, and macOS's) does not take \' inside ${var//.../...}: it leaves the
# backslashes in, so `don't` became a SQL syntax error, the read-back failed, and the decision was never recorded.
# bash 5 takes either, so CI cannot see the difference; `gateway/gate-scripts-run-under-the-minis-bash` greps for the
# idiom and runs the verbs under /bin/bash.
gr_sql_escape() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

# gr_reread_comment <body>: succeeds if the gate card carries a comment with exactly this body, on a fresh snapshot.
gr_reread_comment() {
  local body="$1" try snap esc n
  esc="$(gr_sql_escape "$body")"
  for try in 1 2; do
    snap="$("$GR_HERE/board-snapshot.sh" "$GR_DB" "$GR_WORK/read-comment$try" 2>/dev/null)" && [ -n "$snap" ] || continue
    n="$(sqlite3 "$snap" "SELECT count(*) FROM task_comments WHERE task_id = '$GR_CARD' AND body = '$esc';" 2>/dev/null)" || continue
    [ "${n:-0}" -ge 1 ] 2>/dev/null && return 0
    return 1
  done
  return 1
}

gr_cleanup() { [ -z "${GR_WORK:-}" ] || rm -rf "$GR_WORK" 2>/dev/null; return 0; }

# gr_parse_args "$@": --board <b> --gate <g> [--text <t>] (--rehearse | --apply) | --check | -h.
# Sets GR_BOARD GR_GATE GR_TEXT GR_MODE; --check and -h are handled here (and exit). An argument that is
# not one of these is a usage error (exit 2) and writes nothing. --text takes the NEXT argument whole,
# so a text that begins with '-' is a text, not an option.
gr_parse_args() {
  GR_BOARD=""; GR_GATE=""; GR_TEXT=""; GR_MODE=""; GR_TEXT_SET=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) [ $# -ge 2 ] || gr_fail "--board needs a board name"; GR_BOARD="$2"; shift 2;;
      --gate)  [ $# -ge 2 ] || gr_fail "--gate needs a gate id"; GR_GATE="$2"; shift 2;;
      --text)  [ $# -ge 2 ] || gr_fail "--text needs a text"; GR_TEXT="$2"; GR_TEXT_SET=1; shift 2;;
      --rehearse) [ "$GR_MODE" != apply ] || gr_fail "--rehearse and --apply are exclusive"; GR_MODE=rehearse; shift;;
      --apply)    [ "$GR_MODE" != rehearse ] || gr_fail "--rehearse and --apply are exclusive"; GR_MODE=apply; shift;;
      --check) gr_check_tools; echo "ok: the host can run this"; exit 0;;
      -h|--help) gr_help; exit 0;;
      *) gr_fail "unknown argument '$1'";;
    esac
  done
  [ -n "$GR_BOARD" ] && [ -n "$GR_GATE" ] || gr_fail "usage: --board <board> --gate GATE-<m> [--text <text>] (--rehearse | --apply)"
  [ -n "$GR_MODE" ] || gr_fail "say --rehearse (writes nothing) or --apply"
}
