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
        --argjson pid "$$" --argjson at "$(date +%s)" \
        --argjson terminate "$terminate" --argjson on_error "${on_error:-null}" '
      { schema: "forge.pending-call.v1", task_id: $task, board: $board, profile: $profile,
        workspace: $ws, pid: $pid, written_at: $at, used: 0,
        terminate: $terminate, on_error: $on_error }' > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 0
}
