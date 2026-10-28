#!/usr/bin/env bash
# =============================================================================
# driver-call-hook — make the driver's terminal call the one its program named (P34).
#
# A Hermes `pre_tool_call` shell hook, installed in forge-codex-lane's and forge-verifier's
# config.yaml by hermes/profiles-bootstrap.sh and reached ONLY as
#     ~/.forge/repo/scripts/driver-call-hook.sh
# (a bare relative path cannot resolve from a worker's worktree; verify.sh and preflight.sh grep
# for this literal form). Matcher: kanban_request_review|kanban_block|kanban_request_changes|
# kanban_complete — the four tools that end a worker's run.
#
# WHY. Since S6d a worker's program (scripts/lane.sh, scripts/prejudge-review.sh) decides the
# card's next transition and PRINTS it as `terminate: {tool, args}` (+ `on_error`); the driver
# model must retype it. In rehearsal 4 (2026-10-28, card t_6e076ae7) the envelope said
# kanban_request_review {task_id, summary, metadata, reviewer:"forge-verifier"} and the driver
# called it with {summary, metadata, artifacts:[]}. Hermes defaults a missing reviewer to the
# card's _prior_reviewer, which is None on a first hand-off, so the card went `review` still
# assigned to the lane and the dispatcher handed it back to the lane. The program now ALSO records
# the call (scripts/forge-state.sh, forge_pending_write) and this hook rewrites the driver's call
# to the record, so the driver's fidelity stops mattering.
#
# WHAT IT IS GIVEN (measured, docs/hermes-field-notes.md). stdin JSON {tool_name, tool_input,
# session_id, cwd, profile, extra}. Its environment is scrubbed like the fenced terminal's: NO
# HERMES_KANBAN_TASK/_RUN_ID/_CLAIM_LOCK, so the task id is NOT available. What survives, and is
# identical in the terminal the program ran in, is HERMES_KANBAN_BOARD, HERMES_PROFILE and
# HERMES_KANBAN_WORKSPACE. The record is keyed on those three (the profile because the lane and
# the verifier work one card in one worktree). The driver's own arguments are never used to find it.
#
# WHAT IT DOES, for the tool T the driver called, given the record R for this board+profile+workspace:
#   * T == R.terminate.tool            -> modify: R.terminate.args, complete.
#   * T == kanban_block                -> modify: R.on_error.args when it is a kanban_block (see the
#                                         `used` rule below); R.terminate.args when terminate is the
#                                         block itself. Otherwise unchanged: the block exit stays open.
#   * any other of the four tools      -> block, with a message naming the tool the program chose.
# `modify` only shallow-merges, so a key the driver invented would survive. Every DECLARED
# parameter of T that R's args do not carry is therefore sent as null (an explicit null reads as
# absent in Hermes's handlers: measured; `board` is one of them, so a driver cannot aim a call at
# another board). A key T does not declare is left alone: Hermes rejects
# it with "Nothing changed", and nothing partial lands.
# `used`: a program may name a kanban_block as BOTH terminate and on_error (the recommend-only
# hold, whose fallback is the handoff-integrity block). The first block of such a record is
# terminate; the hook bumps R.used, and a later block is on_error.
#
# EVERY FAILURE KEEPS AN EXIT OPEN. This hook is installed WITHOUT fail_closed, deliberately: a
# fault in the hook (crash, missing, timeout, bad JSON) must leave the driver exactly where it
# was before this existed — its own arguments reach the kernel — and never a card that sits
# `running` until the 1800 s timeout reaps it. So:
#   * the hook script is missing, crashes or times out -> Hermes fails open; the driver's call stands.
#   * no record (the program died before naming a call, the board/profile/workspace identity is
#     unreadable, stdin and HERMES_PROFILE disagree) -> exit 0, nothing printed: every call passes.
#   * a record that is stale (older than FORGE_PENDING_MAX_AGE_S, or from the future), malformed,
#     or for another board/profile/workspace -> treated as no record.
#   * a record for ANOTHER TASK (the workspace basename has the shape of a task id and it is not
#     R.task_id) -> kanban_block passes unchanged; the other three tools are blocked, with a
#     message that tells the driver to end the run with kanban_block.
#   * the tool is neither terminate nor on_error -> blocked WITH a message naming the right tool,
#     except kanban_block, which is never refused.
# Only a block message the hook itself prints can stop a call, and kanban_block is never blocked.
# EXIT CODE 2 IS A BLOCK. Hermes blocks a pre_tool_call on exit code 2 "even without JSON", and
# fail_closed or not, that includes kanban_block. bash itself exits 2 on a syntax error, and a
# fault in the body can end with any code. So the body runs in a subshell (main), whatever it
# prints is kept only if it is a JSON object, and THIS SCRIPT ALWAYS EXITS 0. The one fault that
# cannot be absorbed is a syntax error in this file, which `make validate` (bash -n) refuses.
# `the-hook-policy-keeps-an-exit-open` drives a copy that exits 2 and a copy with an unbound
# variable, and a hook that is only `exit 2` as the control that Hermes does refuse on it.
#
# Knobs: FORGE_STATE_ROOT / FORGE_LANE_SESSION_ROOT (shared with the programs), FORGE_HOOK_NOW
# (a pinned epoch, for fixtures). `--check` exits 0 when the hook can run here (jq, a hash tool,
# forge-state.sh beside it) and prints why not otherwise: what `make preflight` runs.
# =============================================================================
set -u
# A hook inherits a worker's PATH, which a launchd-started gateway may leave without Homebrew.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || exit 0
# shellcheck source=forge-state.sh
. "$HERE/forge-state.sh" 2>/dev/null || { [ "${1:-}" = --check ] && echo "forge-state.sh is missing beside the hook" >&2 && exit 1; exit 0; }

if [ "${1:-}" = --check ]; then
  command -v jq >/dev/null 2>&1 || { echo "jq is not on the hook's PATH" >&2; exit 1; }
  { command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; } \
    || { echo "neither shasum nor sha256sum is on the hook's PATH" >&2; exit 1; }
  exit 0
fi
main() {
  command -v jq >/dev/null 2>&1 || exit 0

  pass()   { exit 0; }
  modify() { jq -nc --argjson a "$1" '{action: "modify", args: $a}'; exit 0; }
  deny()   { jq -nc --arg m "$1" '{action: "block", message: $m}'; exit 0; }

  IN="$(cat 2>/dev/null)" || pass
  TOOL="$(printf '%s' "$IN" | jq -r '.tool_name // ""' 2>/dev/null)" || pass
  PROFILE_STDIN="$(printf '%s' "$IN" | jq -r '.profile // ""' 2>/dev/null)" || pass
  BOARD="${HERMES_KANBAN_BOARD:-}"
  WS="${HERMES_KANBAN_WORKSPACE:-}"
  PROFILE="${HERMES_PROFILE:-}"
  case "$TOOL" in kanban_request_review|kanban_block|kanban_request_changes|kanban_complete) ;; *) pass;; esac
  { [ -n "$BOARD" ] && [ -n "$WS" ] && [ -n "$PROFILE" ]; } || pass
  [ "$PROFILE_STDIN" = "$PROFILE" ] || pass

  # The parameters each tool declares (tools/kanban_tools_schemas.py; the case
  # `lane/the-hook-declares-the-schemas-keys` compares this table with the installed ones).
  declared() {
    case "$1" in
      kanban_request_review)  echo '["board","task_id","summary","reviewer","metadata","artifacts"]';;
      kanban_block)           echo '["board","task_id","reason","kind"]';;
      kanban_request_changes) echo '["board","task_id","reason"]';;
      kanban_complete)        echo '["board","task_id","summary","metadata","result","created_cards","artifacts"]';;
    esac
  }

  NOW="${FORGE_HOOK_NOW:-$(date +%s)}"
  REC=""
  # The programs' root is $HOME/.forge by default; a hook's HOME can differ from a terminal's, so
  # the real home Hermes keeps in HERMES_REAL_HOME is tried too.
  roots="$(forge_lane_session_root)"
  [ -n "${FORGE_LANE_SESSION_ROOT:-}${FORGE_STATE_ROOT:-}" ] || [ -z "${HERMES_REAL_HOME:-}" ] \
    || roots="$roots
  ${HERMES_REAL_HOME}/.forge/lane-sessions"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    f="$(forge_pending_path "$BOARD" "$PROFILE" "$WS" "$root")"
    [ -f "$f" ] || continue
    # valid: ours, this identity, not stale, not from the future, with a terminate call
    if jq -e --arg b "$BOARD" --arg p "$PROFILE" --arg w "$WS" --argjson now "$NOW" --argjson max "$FORGE_PENDING_MAX_AGE_S" '
          .schema == "forge.pending-call.v1" and .board == $b and .profile == $p and .workspace == $w
          and (.written_at | type) == "number" and (($now - .written_at) <= $max) and (($now - .written_at) >= -60)
          and (.terminate.tool | type) == "string" and (.terminate.args | type) == "object"
          and (.task_id | type) == "string"' "$f" >/dev/null 2>&1; then
      REC="$f"; break
    fi
  done <<< "$roots"
  [ -n "$REC" ] || pass

  TASK_ID="$(jq -r '.task_id' "$REC")"
  T_TOOL="$(jq -r '.terminate.tool' "$REC")"
  E_TOOL="$(jq -r '.on_error.tool // ""' "$REC")"
  USED="$(jq -r '(.used // 0) | tostring' "$REC")"
  case "$USED" in ""|*[!0-9]*) USED=0;; esac

  # The record is for another task than this worker's: the workspace basename is a task id's shape.
  base="$(basename "$WS")"
  if printf '%s' "$base" | grep -Eq '^t_[0-9a-f]{8}$' && [ "$base" != "$TASK_ID" ]; then
    [ "$TOOL" = kanban_block ] && pass
    deny "driver-call-hook: refused $TOOL — the call on record for this workspace is for task $TASK_ID, but this worker's workspace ($base) is another task. Nothing changed. End the run with kanban_block, reason: other: handoff-integrity — a pending call for another task was found in this workspace."
  fi

  bump() {   # one more terminal call has been rewritten from this record
    local tmp; tmp="$(mktemp "$REC.XXXXXX" 2>/dev/null)" || return 0
    jq -c --argjson n "$((USED + 1))" '.used = $n' "$REC" > "$tmp" 2>/dev/null && mv -f "$tmp" "$REC" 2>/dev/null || rm -f "$tmp"
  }
  rewrite() {   # terminate|on_error -> modify with that call's complete args
    local args extra
    # A call carrying a key the tool does not declare is refused by Hermes ("Nothing changed"), so
    # nothing was made and the record must not count it: the driver retries and needs the same call.
    extra="$(printf '%s' "$IN" | jq -r --argjson d "$(declared "$TOOL")" '((.tool_input // {}) | keys) - $d | length' 2>/dev/null)"
    args="$(jq -c --argjson keys "$(declared "$TOOL")" --arg which "$1" '
        ($keys | map({key: ., value: null}) | from_entries) + .[$which].args' "$REC" 2>/dev/null)" || pass
    [ -n "$args" ] || pass
    [ "$extra" = 0 ] && bump
    modify "$args"
  }

  if [ "$TOOL" = kanban_block ]; then
    if [ "$T_TOOL" = kanban_block ]; then
      if [ "$E_TOOL" = kanban_block ] && [ "$USED" -ge 1 ]; then rewrite on_error; fi
      rewrite terminate
    fi
    [ "$E_TOOL" = kanban_block ] && rewrite on_error
    pass   # a record that plans no block: the exit stays open and the driver's own reason stands
  fi
  [ "$TOOL" = "$T_TOOL" ] && rewrite terminate
  [ "$TOOL" = "$E_TOOL" ] && rewrite on_error
  deny "driver-call-hook: refused $TOOL — this run's program decided the call, and it is $T_TOOL. Nothing changed. Make exactly that call with the arguments in the program's envelope (\`terminate\`); if the kernel refuses it, make the envelope's \`on_error\` call. If you cannot, end the run with kanban_block."
}

OUT="$(main)"
if printf '%s' "$OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then printf '%s\n' "$OUT"; fi
exit 0
