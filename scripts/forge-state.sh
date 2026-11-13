# shellcheck shell=bash
# =============================================================================
# Where Forge keeps its own state on the host — ONE definition, sourced.
#
# A worker's terminal cannot write the board (the kernel fences it: `hermes
# kanban comment`, `heartbeat`, `block`, `request-review` ... are all refused;
# epic S6d, P24), so anything a worker's PROGRAM must leave behind for a later
# reader — the lane's session record and its validated hand-off envelope, the
# verifier's verdict — goes on the host instead. Three programs agree on where:
#
#   scripts/lane.sh            writes lane-sessions/<board>-<task>[.metadata.json]
#   scripts/prejudge-review.sh reads that envelope; writes verdicts/<board>-<task>.json
#   scripts/merge-watcher.sh   reads verdicts/<board>-<task>.json
#
# A fourth thing is kept here that is not a worker's output but the OPERATOR's act: merge authority.
#
#   scripts/merge-authority.sh   writes and deletes merge-authority/<board>.json (grant / revoke / status)
#   scripts/prejudge-review.sh   reads it when it reaches the merge decision
#
# The root is `$HOME/.forge`, which is what `lane.sh` has always resolved for
# `lane-sessions` (and what `~/.forge/repo/scripts/...`, the only path that
# resolves from a project worktree, already depends on). It is the same for
# every profile on this host: Hermes keeps the REAL home in a host's subprocess
# env (`hermes_constants.get_subprocess_home`, mode `auto`), measured in run A,
# where a fenced lane wrote `/Users/goonlab/.forge/lane-sessions/...` and no
# profile-local `home/.forge` exists. A host that gave a profile its own HOME
# would break `~/.forge/repo/...` first.
#
# Sourced, never executed — but it carries +x all the same: preflight FAILs any script it lists
# that is not executable (preflight.sh, the `_lscript` loop), and a sourced file is listed.
# Every consumer is bash; do not add a second parser
# or a second formula for these paths. `FORGE_STATE_ROOT` and the two narrower
# overrides exist so a case can aim a program at a throwaway directory.
# =============================================================================
forge_state_root()        { printf '%s' "${FORGE_STATE_ROOT:-$HOME/.forge}"; }
forge_lane_session_root() { printf '%s' "${FORGE_LANE_SESSION_ROOT:-$(forge_state_root)/lane-sessions}"; }
forge_verdict_root()      { printf '%s' "${FORGE_VERDICT_ROOT:-$(forge_state_root)/verdicts}"; }
forge_merge_authority_root() { printf '%s' "${FORGE_MERGE_AUTHORITY_ROOT:-$(forge_state_root)/merge-authority}"; }

# ---------------------------------------------------------------------------
# THE PENDING CALL (P34). A program decides the one lifecycle call the driver must make and
# prints it in its envelope; a cheap driver model retypes it, and sometimes drops an argument
# (rehearsal 4: `kanban_request_review` without `reviewer`, so the card stayed with the lane).
# The program therefore also RECORDS the call here, and `scripts/driver-call-hook.sh` — a
# `pre_tool_call` hook in the worker's profile — rewrites the driver's call to the record's
# arguments before the kernel sees it.
#
# THE KEY IS BOARD + PROFILE + WORKSPACE, NOT THE TASK. Hermes scrubs HERMES_KANBAN_TASK from a
# hook's environment exactly as it does from the terminal's (measured 2026-10-28,
# docs/hermes-field-notes.md), and a hook's stdin carries no kanban task id. What both sides
# keep, identically, is HERMES_KANBAN_BOARD, HERMES_PROFILE and HERMES_KANBAN_WORKSPACE. The
# profile is in the key because the lane and the verifier work ONE card in ONE worktree, and
# neither may overwrite the other's record. The record carries the task id and the hook checks it
# whenever the workspace basename has the shape of one.
#
# THE SESSION GUARD. The terminal and the hook both see the worker's HERMES_SESSION_ID (it is
# the hook's stdin `session_id` too), so the program records it when it has one and the hook
# ignores a record from another session. That closes the window between a re-claim and the
# program's start: a driver that calls a terminal tool BEFORE it launches the program would
# otherwise get the previous round's record applied. Context compression rotates the session id
# mid-run, which makes the record unusable: the result is the driver's own arguments, the
# behaviour before the hook, never a trap. No id on the program side, no field, no comparison.
# The record lives beside the host copies of the lane's hand-off (lane-sessions), is written
# atomically, and is DELETED by the program that owns it at the very start of its next run: a run
# that dies before it names a call leaves no record, and the driver's own arguments pass
# through. The hook also refuses a record older than FORGE_PENDING_MAX_AGE_S.
# ---------------------------------------------------------------------------
# The profiles' terminal timeout is 1800 s; a record older than that plus a margin cannot belong
# to a run that is still alive.
FORGE_PENDING_MAX_AGE_S=2100
forge_pending_key() {   # workspace -> a short, stable name for it
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -c1-16
  elif command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -c1-16
  else printf '%s' "$1" | cksum | tr -d ' \t'; fi
}
forge_pending_path() {   # board profile workspace [root] -> path of the record
  printf '%s/%s-%s-%s.pending.json' "${4:-$(forge_lane_session_root)}" "$1" "$2" "$(forge_pending_key "$3")"
}
forge_pending_clear() {   # board profile workspace: nothing is pending for this run yet
  [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 0
  rm -f "$(forge_pending_path "$1" "$2" "$3")" 2>/dev/null
  return 0
}
# board profile workspace task terminate-json on_error-json -> 0 once the record is on disk.
# Never fails the program: a record that cannot be written only means the driver's own
# arguments are used, which is the behaviour before this existed.
forge_pending_write() {
  local board="$1" profile="$2" ws="$3" task="$4" terminate="$5" on_error="$6" path tmp
  [ -n "$board" ] && [ -n "$profile" ] && [ -n "$ws" ] && [ -n "$task" ] || return 0
  [ "$terminate" != null ] && [ -n "$terminate" ] || return 0
  path="$(forge_pending_path "$board" "$profile" "$ws")"
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
  tmp="$(mktemp "$path.XXXXXX" 2>/dev/null)" || return 0
  if jq -nc --arg board "$board" --arg profile "$profile" --arg ws "$ws" --arg task "$task" \
        --arg sid "${HERMES_SESSION_ID:-}" \
        --argjson pid "$$" --argjson at "$(date +%s)" \
        --argjson terminate "$terminate" --argjson on_error "${on_error:-null}" '
      { schema: "forge.pending-call.v1", task_id: $task, board: $board, profile: $profile,
        workspace: $ws, pid: $pid, written_at: $at, used: 0,
        terminate: $terminate, on_error: $on_error }
      + (if $sid == "" then {} else {session_id: $sid} end)' > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# MERGE AUTHORITY, PER BOARD. One file per board, <merge-authority root>/<board>.json, written by
# `scripts/merge-authority.sh grant` and deleted by `revoke`. The verifier merges a PR on its own only on
# `FORGE_VERIFIER_MERGE=1` (the old, host-wide switch) or when forge_merge_authority_read says its board is granted.
#
# ONE READER, SO THE OPERATOR'S "IS IT GRANTED?" AND THE VERIFIER'S DECISION CANNOT DISAGREE: both
# `merge-authority.sh status` and `prejudge-review.sh`'s merge_mode call it. It FAILS CLOSED: 0 only for a file
# that is, all at once,
#   * for a board whose name is a Hermes slug (forge_board_slug_ok: no path is built from anything else),
#   * a regular file (not a directory, not a symlink) that can be read,
#   * a JSON object with schema forge.merge-authority.v1,
#   * whose inner `board` is BYTE-IDENTICAL to the board asked about. The host volume is case-insensitive APFS,
#     so `Vlab.json` and `vlab.json` are one file there and the file NAME proves nothing,
#   * with a `granted_by` and a `granted_at`, each one printable, non-blank line (`granted_by` ends up on a
#     card's result, so it must be one line).
# Anything else (no file, unreadable, malformed, another board's, no grantor, an unknown schema) is "not granted".
# It prints nothing: prejudge-review.sh's stdout is ONE envelope line. On 0 it leaves FORGE_MA_BY, FORGE_MA_AT and
# FORGE_MA_REASON set; on 1 they are empty.
# ---------------------------------------------------------------------------
# Hermes's own rule, hermes_cli/kanban_db.py _BOARD_SLUG_RE: ^[a-z0-9][a-z0-9_-]{0,63}$. Spelled out as a
# character list on purpose: a bash range like [a-z] follows the locale's collation on bash 3.2.
forge_board_slug_ok() {   # board -> 0 iff it is a Hermes board slug
  local s="${1:-}" LC_ALL=C
  [ -n "$s" ] && [ "${#s}" -le 64 ] || return 1
  case "$s" in
    [_-]*|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1;;
  esac
  return 0
}
forge_merge_authority_path() { printf '%s/%s.json' "$(forge_merge_authority_root)" "$1"; }   # board -> its file
forge_merge_authority_text_ok() {   # text max-length -> 0 iff non-blank, one printable line, short enough
  local t="${1:-}" max="${2:-0}"
  [ -n "$t" ] && [ "${#t}" -le "$max" ] || return 1
  case "$t" in *[[:cntrl:]]*) return 1;; esac
  case "$t" in *[![:space:]]*) return 0;; esac
  return 1
}
forge_merge_authority_read() {   # board -> 0 iff granted; sets FORGE_MA_BY / _AT / _REASON
  local board="${1:-}" file out
  FORGE_MA_BY=""; FORGE_MA_AT=""; FORGE_MA_REASON=""
  forge_board_slug_ok "$board" || return 1
  command -v jq >/dev/null 2>&1 || return 1
  file="$(forge_merge_authority_path "$board")"
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  # Every test is jq's. It prints three lines only when all of them held; no output at all is "no".
  out="$(jq -r --arg b "$board" '
      def line($max): type == "string" and length > 0 and length <= $max
                      and (explode | all(. >= 32 and . != 127))
                      and (explode | any(. != 32 and . != 160));
      if type == "object" and .schema == "forge.merge-authority.v1" and .board == $b
         and (.granted_by | line(128)) and (.granted_at | line(64))
         and ((.reason // "") | (. == "" or line(500)))
      then .granted_by, .granted_at, (.reason // "") else empty end' "$file" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  { IFS= read -r FORGE_MA_BY; IFS= read -r FORGE_MA_AT; IFS= read -r FORGE_MA_REASON; } <<MA_READ || :
$out
MA_READ
  [ -n "$FORGE_MA_BY" ] && [ -n "$FORGE_MA_AT" ] || { FORGE_MA_BY=""; FORGE_MA_AT=""; FORGE_MA_REASON=""; return 1; }
  return 0
}
