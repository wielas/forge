#!/usr/bin/env bash
# =============================================================================
# forge prejudge-review — the VERIFIER's protocol, as a program (ADR-0010).
#
# ADR-0003: "anything that MUST hold is expressed as a machine gate at the
# lowest layer that sees every actor." `scripts/prejudge.sh` applied that rule
# to what this stage *decides*. This file applies it to what it *does*.
#
# The protocol used to live in `hermes/profiles/forge-prejudge.SOUL.md`: 404
# lines, of which 144 were executable bash in 11 fenced blocks — a `jq` schema
# reduction, a `claude -p` invocation, a 15-line stamping `jq`, a
# create/block/unassign sentinel dance and two `jq -e` read-backs. None of it
# needed a model. All of it was retyped by one, on every run, at
# `deepseek-v4-flash` quality, with no gate on the transcription. The other
# three profiles are 27, 29 and 32 lines, because their protocol is an artifact
# they load rather than prose they re-enact (audit F61).
#
# WHAT FL4 CHANGED (epic S3, ADR-0019).
#   * The profile this runs as is `forge-verifier`, not `forge-prejudge`. THE
#     FILE NAME DELIBERATELY LAGS: the live SOUL, `scripts/preflight.sh` and two
#     `verify` anchors resolve this path literally, and moving it while the
#     runtime is mid-deploy would leave a dispatched review pointing at a file
#     that is not there. Renaming it is its own slice.
#   * Verification EXECUTES. Stage 1b runs `make check` on the tree the merge
#     would produce, in a fresh clone (`scripts/merge-check.sh`). Read-and-score
#     bounced nothing in two product runs; a merged-tree check is what caught
#     redglass PR #9's five-test union failure.
#   * ONE CARD (D19.1). There is no judge card and no fix card. Every outcome is
#     a transition on the chunk's own card: `request-changes` on a fail, a
#     sticky block on an approval the verifier may only recommend, or — only
#     once the operator has flipped `FORGE_VERIFIER_MERGE` — the squash merge
#     itself, then completion.
#   * The kernel ends the run as part of the transition, exactly as
#     `request-review` ends the lane's. (FL4 said "the model terminates NOTHING
#     on a routed outcome": since epic S6d the program no longer makes the
#     transition at all — see below — so the model makes exactly the call the
#     envelope names, and that call is what ends the run.)
#
# WHAT FL5 ADDED (epic S3b).
#   * Stage 1c, the MUTATION PROBE (`scripts/mutation-probe.sh`). It runs in the
#     merged tree Stage 1b just proved green, mutates the implementation lines the
#     PR changed, and runs the tests against each mutant. A changed line on which
#     every mutant survived is a line no test observes — JobApp C21's config reads,
#     C17's message, the July ladder's assertion-free Then step — and each one is
#     a bounce reason the implementer can act on: the file, the line, the
#     mutation, and that no test failed. It runs BEFORE the scorer for the same
#     reason Stage 1b does: a deterministic bounce is free, and the scorer is not.
#   * It REPORTS by default and bounces only behind the operator's switch,
#     `FORGE_MUTATION_PROBE_BOUNCE=1` (the operator's decision at S3b's close).
#     Replayed, it bounced C21, C17 and the ladder's PR #6 as it should — and
#     all six of redglass's all-3s PRs too, mostly on real untested lines and
#     partly on noise. A bounce is live even while approvals only recommend, so
#     enforcing an unmeasured probe would put its precision on every chunk of
#     run A. Its verdict is on every hold instead, which is where run A
#     measures it.
#
# WHAT S6d CHANGED (epic S6d, P24): THIS FILE NEVER WRITES THE BOARD.
# Hermes fences a worker's terminal. Every `hermes kanban` mutation from a shell
# the worker started — request-changes, block, comment, complete — is refused,
# "even if a script removes the task id" (kanban-worker-lanes.md, *Descendant
# process scope*), and HERMES_KANBAN_TASK / _RUN_ID / _CLAIM_LOCK are scrubbed.
# Run A's first attempt (2026-10-03) met this on the lane's hand-off. The fence is
# a documented, cooperative boundary and is not ours to defeat, so the split
# moves one step: this file still decides EVERYTHING, and it now prints the one
# lifecycle call that carries the decision out — `kanban_request_changes`,
# `kanban_block` or (merge mode) `kanban_complete`, with its arguments — and the
# driver, the one party the kernel lets terminate a run, makes it verbatim.
#   * Every call carries `task_id` = the card judged here. The kernel refuses a
#     worker's call on any task but its own ("worker is scoped to task X"), so
#     identity is enforced where it can be: it replaced a guard that compared
#     --chunk with HERMES_KANBAN_TASK and passed vacuously once that was scrubbed.
#   * Every envelope carries `on_error`: the call to make if the kernel refuses
#     `terminate`. A refused terminator leaves the card `running` (measured), so
#     without one the run is reaped as a crash. In merge mode it is the
#     `merge-pending:` hold, so a merge that landed is never left unheld.
#   * The read-backs this file used to make after each transition cannot run: the
#     kernel ends the run WITH the transition. The tool's own result carries the
#     end state (`status`, `implementer`, `block_kind`), and the cases
#     `verifier/the-envelope-lands-on-the-real-kernel` execute each transition
#     through Hermes's real handler.
#   * The verdict JSON used to ride the card as a `FORGE-VERDICT-V1` comment, which
#     only the merge-watcher ever read. It is a host file now (scripts/forge-state.sh
#     owns the path), written here and read there, so the driver retypes none of it.
#   * The hand-off the lane made is checked before anything runs: the metadata the
#     kernel stored on its `review_requested` run must equal the envelope the lane
#     validated (kept on the host), and the PR url must be the one that run names —
#     the driver retyped both.
#
# WHAT THIS FILE IS NOT ALLOWED TO DO
# It does not re-decide anything the gate decided, it does not score, and it
# does not touch the scorer's brief. The `claude -p --model opus` call below is
# S5's experimental control arm: it MOVED here from the SOUL and it was not
# modified. `make verify`'s `prejudge/scorer-is-the-control-arm` diffs it
# against the recorded baseline `scripts/fixtures/control-arm.txt` and fails
# the suite on any difference, whitespace included. (It diffed against
# `git show main:hermes/profiles/forge-prejudge.SOUL.md` until audit F65: that
# baseline stopped existing the moment this file was merged, since removing the
# block from the SOUL is precisely what this file did.) That is why two regions below
# are indented three spaces instead of two: they are pinned bytes carried over
# from a markdown list item. Do not reindent them. Do not tidy them. If you
# think the scorer should change, that is ADR-0009 D9.5 — S5's experiment, not
# an edit. ADR-0019 D19.7 keeps it for the same reason: retiring the scorer and
# adding an executing verifier in one change would move two variables at once.
#
# Usage:
#   prejudge-review.sh <pr-url> --chunk <card-id> [--board <slug>]
#                      [--repo owner/name] [--wait <seconds>]
#                      [--fixture <dir>] [--dry-run] [--contract-from-card]
#   ...with the chunk contract on stdin, or `--contract-from-card` to read it from
#   the card's own body (what a driver should do: a background terminal call has no
#   pipe, and the contract is a multi-KB text it would otherwise retype into a
#   shell command). <card-id> IS your own task's id
#   (`kanban_show().task.id`; the fenced terminal has no HERMES_KANBAN_TASK, and
#   none is read). It must be `running`, assigned to this profile (HERMES_PROFILE)
#   and hold exactly one running run. HERMES_KANBAN_BOARD names the board.
#
# Env:
#   FORGE_VERIFIER_MERGE=1          merge mode, for EVERY board on this host. Absent =
#                                   recommend-only, which is the default and fails closed.
#   <state>/merge-authority/<board>.json
#                                   merge mode for ONE board, by an explicit grant:
#                                   `~/.forge/repo/scripts/merge-authority.sh grant <board> --by <you>`.
#                                   Revoked by `... revoke <board>`. Merges only a chunk the
#                                   lane (forge-codex-lane) built; any other is held.
#   FORGE_VERIFIER_BOUNCE_BUDGET    rounds before the exception          [2]
#   FORGE_MERGE_CHECK_BIN           stand in for scripts/merge-check.sh
#   FORGE_MUTATION_PROBE_BOUNCE=1   the mutation probe BOUNCES. Absent = it
#                                   reports on the hold and gates nothing.
#   FORGE_MUTATION_PROBE_BIN        stand in for scripts/mutation-probe.py
#   FORGE_MUTATION_BUDGET           seconds the mutation probe may spend [420]
#   FORGE_JUDGE_QUOTA_MAX_WAIT      seconds this review may wait, in all, for a Claude usage limit
#                                   (HTTP 429 on the judge call) to lift before it holds [1800]. It holds
#                                   the host's ONE worker slot (the lanes stop meanwhile), so it is short;
#                                   a limit whose stated reset is later than that holds at once.
#   FORGE_JUDGE_QUOTA_STEP / _CAP   with no reset time in the answer: the first wait and its ceiling, seconds
#                                   [120 / 600], doubling. FORGE_JUDGE_QUOTA_MARGIN: seconds past a stated
#                                   reset before trying again [60]. FORGE_JUDGE_QUOTA_NOW (HH:MM:SS in the
#                                   reset's zone) is a test seam, not a knob.
#
# stdout is ONE `forge.review.v2` envelope, as ONE COMPACT LINE — the last thing
# printed: `action`, `summary`, `reason`, `rc` (this program's exit code),
# `metadata`, `terminate` and `on_error` (each `{tool, args}`), `created_cards`.
# The driver reads it with `process_manage(action="log")`, never from `wait`: a
# wait's output is cut to the last 2000 characters (tools/process_registry.py
# COMPLETION_OUTPUT_CHARS) and the call sits near the START of the envelope. Run
# it in the BACKGROUND: a review outlasts the 420 s a foreground tool call gets
# (agent/tool_executor.py _DEFAULT_CONCURRENT_TOOL_TIMEOUT_S; the CI wait alone
# defaults to 600 s).
#
# Exit: 4 a routed outcome — NOTHING has been transitioned yet. Call
#         `.terminate.tool` with `.terminate.args`, verbatim; if it returns an
#         error, call `.on_error.tool` with `.on_error.args` and stop. `.action`
#         says which: `bounce` / `gate-block` (kanban_request_changes),
#         `recommend` (kanban_block: held for the operator), `exception` (kanban_
#         block: bounce budget spent), `merged` (merge mode: kanban_complete),
#         `merged-held` (merge mode: merged, but GitHub did not confirm it, so the
#         card is held `merge-pending:` for the merge-watcher).
#       3 a substrate fault — nothing was decided. `.terminate` is `kanban_block`
#         with `.reason`; call it verbatim. Includes a run with no board to read
#         (`env: no-board`), unless it is a --dry-run.
#       2 a usage error: `kanban_block` with `other: review-usage — <stderr>`.
#       0 only for --help and --dry-run (`would-score`, which transitions nothing).
#         A real run NEVER exits 0: a driver whose notes still say "0 = nothing to
#         call" must fail loudly, not silently.
#
# 1 is deliberately NOT used: a bounced PR is a routed outcome, not a failure of
# this script, and a caller running under `set -e` must not treat a bounce as a
# crash.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_URL=""; CHUNK=""; BOARD="${HERMES_KANBAN_BOARD:-}"; REPO=""; chunk_title=""
WAIT_SECS=600; FIXTURE="${PREJUDGE_FIXTURE:-}"; DRY_RUN=0; CONTRACT_FROM_CARD=0
CREATED=()
# shellcheck source=forge-state.sh
. "$HERE/forge-state.sh" || { echo "usage: forge-state.sh is missing beside prejudge-review.sh" >&2; exit 2; }
. "$HERE/model-pins.sh" || { echo "usage: model-pins.sh is missing beside prejudge-review.sh" >&2; exit 2; }
# The judge call below is `claude -p`, and a ROUTED worker's environment has no CLAUDE_CODE_OAUTH_TOKEN
# (the dispatcher strips every name the root ~/.hermes/.env defines; docs/hermes-field-notes.md,
# rehearsal 5). Sourcing this defines a `claude` function that supplies it to that one child, so the
# pinned scorer lines further down stay byte-identical. Without the file the review cannot authenticate.
. "$HERE/claude-token.sh" || { echo "usage: claude-token.sh is missing beside prejudge-review.sh" >&2; exit 2; }
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --chunk)   CHUNK="${2:-}"; [ -n "$CHUNK" ] || { echo "usage: --chunk needs your own task's id (kanban_show().task.id); the fenced terminal has no HERMES_KANBAN_TASK" >&2; exit 2; }; shift 2;;
    --board)   BOARD="${2:?--board needs a slug}"; shift 2;;
    --repo)    REPO="${2:?--repo needs owner/name}"; shift 2;;
    --wait)    WAIT_SECS="${2:?--wait needs seconds}"; shift 2;;
    --fixture) FIXTURE="${2:?--fixture needs a directory}"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --contract-from-card) CONTRACT_FROM_CARD=1; shift;;
    -h|--help) awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; exit 0;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) [ -z "$PR_URL" ] || { echo "only one PR: '$PR_URL' and '$1'" >&2; exit 2; }
       PR_URL="$1"; shift;;
  esac
done
# P34: whatever an EARLIER run of this profile in this workspace left as "the call to make" is not
# this run's. Cleared before anything else, so a run that dies before it names a call leaves none
# and the driver's own arguments pass through the hook untouched.
forge_pending_clear "${HERMES_KANBAN_BOARD:-$BOARD}" "${HERMES_PROFILE:-}" "${HERMES_KANBAN_WORKSPACE:-}"
[ -n "$PR_URL" ] || { usagetext; exit 2; }
[ "$CONTRACT_FROM_CARD" != 1 ] || [ "$DRY_RUN" != 1 ] || { echo "usage: --contract-from-card reads the card, and a --dry-run has none" >&2; exit 2; }
command -v jq >/dev/null || {
  # no jq, so nothing is escaped: the literal names no task (the kernel applies a block to the
  # driver's own) and embeds nothing the caller typed
  printf '{"schema":"forge.review.v2","action":"substrate-block","reason":"env: jq missing","rc":3,"terminate":{"tool":"kanban_block","args":{"reason":"env: jq missing"}},"on_error":null,"created_cards":[]}\n'
  exit 3
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forge-review.XXXXXX")"
JUDGE_WAIT_FILE=""   # the record of a wait for the Claude usage limit (below); never left behind
trap 'rm -rf "$TMP"; [ -z "$JUDGE_WAIT_FILE" ] || rm -f "$JUDGE_WAIT_FILE"' EXIT

# THE CLAUDE USAGE LIMIT, WAITED OUT. The knobs of the wait the judge call gets (see judge_quota_pause), read here so a
# value that is not a number is a usage error before any work is spent, not after the judge has already been paid for.
JUDGE_QUOTA_MAX_WAIT="${FORGE_JUDGE_QUOTA_MAX_WAIT:-1800}"   # seconds this review may wait in all
JUDGE_QUOTA_STEP="${FORGE_JUDGE_QUOTA_STEP:-120}"            # the first wait when the reset time is unknown; doubles
JUDGE_QUOTA_CAP="${FORGE_JUDGE_QUOTA_CAP:-600}"              # ...up to this
JUDGE_QUOTA_MARGIN="${FORGE_JUDGE_QUOTA_MARGIN:-60}"         # seconds past a stated reset time before trying again
for _kn in JUDGE_QUOTA_MAX_WAIT JUDGE_QUOTA_STEP JUDGE_QUOTA_CAP JUDGE_QUOTA_MARGIN; do
  awk -v v="${!_kn}" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/) }' \
    || { echo "usage: FORGE_${_kn} must be a number of seconds, got '${!_kn}'" >&2; exit 2; }
done
awk -v a="$JUDGE_QUOTA_STEP" -v b="$JUDGE_QUOTA_CAP" 'BEGIN { exit !(a > 0 && b > 0) }' \
  || { echo "usage: FORGE_JUDGE_QUOTA_STEP and FORGE_JUDGE_QUOTA_CAP must be above 0 seconds" >&2; exit 2; }

JUDGE_ORDER="${FORGE_JUDGE_ORDER:-codex claude}"
case "$JUDGE_ORDER" in
  "codex claude"|"claude codex"|codex|claude) ;;
  *) echo "usage: FORGE_JUDGE_ORDER must be one of: codex claude, claude codex, codex, claude" >&2; exit 2;;
esac
JUDGE_TIMEOUT="${FORGE_JUDGE_TIMEOUT:-900}"
case "$JUDGE_TIMEOUT" in
  ''|*[!0-9]*) echo "usage: FORGE_JUDGE_TIMEOUT must be a non-negative integer, got '$JUDGE_TIMEOUT'" >&2; exit 2;;
esac
[ "$JUDGE_TIMEOUT" = 0 ] || command -v pgrep >/dev/null 2>&1 || {
  echo "usage: pgrep is required to enforce FORGE_JUDGE_TIMEOUT" >&2; exit 2;
}
JUDGE_MODEL="${FORGE_JUDGE_MODEL:-$FORGE_PIN_JUDGE_MODEL}"
JUDGE_EFFORT="${FORGE_JUDGE_EFFORT:-$FORGE_PIN_JUDGE_EFFORT}"
[ -n "$JUDGE_MODEL" ] && [ -n "$JUDGE_EFFORT" ] || {
  echo "usage: verifier judge model and effort must resolve from model-pins.sh or their overrides" >&2; exit 2;
}

# ---------------------------------------------------------------------------
# The envelope is the whole of this script's output, and it is small on
# purpose. The driver is the only metered agent in the run, so every byte
# printed here is billed to it. A 127 KB diff passes through this process and
# never touches stdout.
# ---------------------------------------------------------------------------
envelope() {   # action, summary, metadata-file|'null', reason, exit-code, [terminate-json], [on_error-json]
  local action="$1" summary="$2" metafile="$3" reason="$4" code="$5" terminate="${6:-null}" on_error="${7:-null}" meta='null'
  [ "$metafile" != "null" ] && [ -s "$metafile" ] && meta="$(cat "$metafile")"
  # P34: the call the driver must make is also recorded on the host, and a pre_tool_call hook in
  # this profile (scripts/driver-call-hook.sh) rewrites the driver's retyped call to the record's
  # arguments. Written BEFORE the envelope is printed. A dry-run names no call and writes none. Keyed on
  # HERMES_KANBAN_BOARD, the board the hook reads (and the one a call with no `board` argument lands on).
  forge_pending_write "${HERMES_KANBAN_BOARD:-$BOARD}" "${HERMES_PROFILE:-}" "${HERMES_KANBAN_WORKSPACE:-}" "$CHUNK" "$terminate" "$on_error"
  # -M: this runs under a pty, where jq colours its output; the escape codes tripled the envelope's length.
  jq -nMc --arg action "$action" --arg summary "$summary" --arg reason "$reason" --argjson rc "$code" \
        --argjson metadata "$meta" --argjson terminate "$terminate" --argjson on_error "$on_error" \
        --argjson created "$(printf '%s\n' ${CREATED[@]+"${CREATED[@]}"} \
                             | jq -Rs 'split("\n") | map(select(length>0))')" '
    { schema: "forge.review.v2", action: $action, summary: $summary,
      reason: (if $reason == "" then null else $reason end),
      rc: $rc, metadata: $metadata, terminate: $terminate, on_error: $on_error, created_cards: $created }'
  # THE LAST LINE NAMES THE STEP. A driver that reads only the END of this output (`process_manage` wait keeps
  # about 2,000 characters, and the envelope ends with on_error) saw a complete `kanban_block` call and nothing
  # else, and made it: a merged card was held, twice in a row, on 2026-11-16. So the step is said again, last and
  # short, on stderr (stdout stays one envelope line). The hook fills the arguments from the record written above,
  # so the tool's name is all a driver needs.
  if [ "$terminate" != null ]; then
    local next_tool fallback_tool=""
    next_tool="$(printf '%s' "$terminate" | jq -r '.tool // empty' 2>/dev/null)"
    [ "$on_error" = null ] || fallback_tool="$(printf '%s' "$on_error" | jq -r '.tool // empty' 2>/dev/null)"
    if [ -n "$next_tool" ]; then
      printf '\nNEXT STEP: call the tool %s now, once. Its arguments are the ones under "terminate" in the line above, and a hook fills them in if you cannot see them.' "$next_tool" >&2
      if [ -n "$fallback_tool" ]; then
        printf ' Call %s ONLY IF %s itself returns an error; the call shown under "on_error" is not the step to take.' "$fallback_tool" "$next_tool" >&2
      fi
      printf '\n' >&2
    fi
  fi
  exit "$code"
}

# THE CALL, NAMED. `args` always carries `task_id` = the card judged here, which the
# kernel checks against the driver's own task (see the top). `kind` only when given.
call_json() {   # tool, args-json -> {tool, args}
  jq -nc --arg tool "$1" --argjson args "$2" '{tool: $tool, args: $args}'
}
# CHUNK_TRUSTED is 0 until the card has been read back and is provably THIS
# worker's (below). Until then a call names no task at all, and the kernel applies
# it to the driver's own: naming a card that failed the identity check would make
# the kernel refuse the very `kanban_block` that reports the failure.
CHUNK_TRUSTED=0
task_args() {   # jq filter over {task_id: $t}, then --arg pairs -> args-json
  local filter="$1"; shift
  jq -nc --arg t "$([ "$CHUNK_TRUSTED" = 1 ] && printf '%s' "$CHUNK")" "$@" \
    "(if \$t == \"\" then {} else {task_id: \$t} end) + ($filter)"
}
term_block() {   # reason [kind] -> the kanban_block call
  if [ -n "${2:-}" ]; then
    call_json kanban_block "$(task_args '{reason: $r, kind: $k}' --arg r "$1" --arg k "$2")"
  else
    call_json kanban_block "$(task_args '{reason: $r}' --arg r "$1")"
  fi
}

# A substrate fault is a fact about the world, never a verdict on the work.
# Conflating the two is how an outage reads as a rejection, which is why it has
# its own exit code and its own terminator.
substrate() { envelope substrate-block "" null "$1" 3 "$(term_block "$1")" null; }

kanban() { hermes kanban --board "$BOARD" "$@"; }
board_live() { [ -n "$BOARD" ] && command -v hermes >/dev/null; }

# ---------------------------------------------------------------------------
# --chunk IS THE RUNNING CARD — AND THE BOARD, NOT AN ENVIRONMENT VARIABLE, SAYS SO.
# This guard has been through two shapes. Until ADR-0019 a chunk card parented a
# tier-1 child, a MODEL read the parent's id out of prose in the SOUL, and on
# 2026-09-04 a running prejudge task passed ITS OWN id — route_tier2 parented the
# tier-2 card under itself and the misparented chunk drove the card into `todo`,
# where `block` silently refuses it. Then (D19.1: ONE card per chunk, the
# verifier claimed on that card) it compared --chunk with $HERMES_KANBAN_TASK.
# Under the fence (P24) that variable is scrubbed, so the comparison passed
# vacuously for ANY id. The identity is now read off the card, before anything is
# decided, and the same fact is enforced a second time by the kernel when the
# driver makes the call (every `terminate.args` carries `task_id`):
#
#   1. The card must be `running`, assigned to THIS profile (HERMES_PROFILE is kept
#      by the fence), and hold exactly one running run — a review claim.
#   2. It must LOOK like a chunk card (`CHUNK-<id>: <title>`, scripts/prejudge.sh's
#      `branch_name` convention). A verifier pointed at a gate card or a typo'd id
#      is refused.
#   3. The hand-off the lane made arrives intact (below).
#
# All of them fail closed through `substrate` (exit 3, `kanban_block`): a bad
# hand-off is a fact about how this run was invoked, not a judgement on the work,
# so it routes exactly like `env: jq missing` and never like a usage error a caller
# under `set -e` could crash on. A --dry-run has no claim to check.
# ---------------------------------------------------------------------------
# NO BOARD, NO ROUTED OUTCOME. Every exit-4 action below names a transition on this
# card; a run with no board to read has nothing to name. The routers used to
# `return 0` when the board was unset or `hermes` was missing, so a run with no
# board reported `bounce` or `recommend` although nothing could transition: the
# card stayed `running` and the dispatcher reaped it as a crash. So a run that
# cannot name a transition refuses before it starts, the way `lane.sh` refuses an
# unset HERMES_KANBAN_BOARD.
#
# `--dry-run` is the one deliberate exception: it is the offline rehearsal
# (`prejudge/review-routes-by-gate-result` and the envelope cases run it with no
# board at all), and its envelope never claims a transition was made.
if [ "$DRY_RUN" != 1 ] && ! board_live; then
  substrate "env: no-board — ${BOARD:+board '$BOARD' is named but hermes is not on PATH}${BOARD:-no --board and no HERMES_KANBAN_BOARD}, so no outcome can be named on this card, and one that cannot be named must not be reported as made"
fi

LANE_COPY_NOTE=""
if [ "$DRY_RUN" = 1 ]; then
  CHUNK_TRUSTED=1   # nothing here is performed; the envelope only shows the routing
fi
if board_live; then
  CARD0="$(kanban show "$CHUNK" --json 2>/dev/null)"
  chunk_title="$(printf '%s' "$CARD0" | jq -r '.task.title // empty' 2>/dev/null)"
  case "$chunk_title" in
    CHUNK-[A-Za-z0-9]*) ;;
    *) substrate "env: chunk-identity — --chunk ($CHUNK) does not look like a chunk card (title '${chunk_title:-<unreadable>}', want CHUNK-<id>: <title>)";;
  esac
  if [ "$DRY_RUN" != 1 ]; then
    [ -n "${HERMES_PROFILE:-}" ] \
      || substrate "env: chunk-identity — HERMES_PROFILE is unset, so there is no profile to check the card against (the fence keeps it)"
    printf '%s' "$CARD0" | jq -e --arg id "$CHUNK" --arg me "$HERMES_PROFILE" '
        .task.id == $id and .task.status == "running" and (.task.assignee // "") == $me
        and ([.runs[]? | select(.status == "running")] | length) == 1' >/dev/null 2>&1 \
      || substrate "env: chunk-identity — --chunk ($CHUNK) is not a card this profile ($HERMES_PROFILE) is running: it is '$(printf '%s' "$CARD0" | jq -r '(.task.status // "unreadable") + "/" + (.task.assignee // "nobody")' 2>/dev/null)'. Pass YOUR task's id (kanban_show().task.id); under ADR-0019 D19.1 the chunk card and the review are the same card"
    CHUNK_TRUSTED=1

    # THE LANE'S HAND-OFF ARRIVES INTACT. The lane's driver retyped the metadata and
    # the reviewer into `kanban_request_review`; this is the only place anything can
    # still notice. The card's last `review_requested` run is compared with what the
    # lane validated and kept on the host.
    #
    # THE KERNEL REWRITES TWO THINGS, and neither may read as tampering: it adds
    # `worker_session_id`, and it REDACTS secret-shaped strings (`API_KEY=sk-…` becomes
    # `API_KEY=***`, `ghp_ab…6789` becomes `ghp_ab...6789`) — in the free-text lists
    # (decisions, debt, card proposals: lines lifted from the diff) and equally in a
    # file NAME in `changed_files`. A false `handoff-integrity` is a run A stop rule, so:
    #   * `worker_session_id` is dropped from both sides;
    #   * the three free-text lists are compared by LENGTH (an item cannot vanish);
    #   * every other leaf must be equal, or differ ONLY as a redaction does: the stored copy
    #     carries a mark (`***` or `...`) and everything BEFORE the mark is the same text the
    #     lane validated (`secrets/API_KEY=***` against `secrets/API_KEY=sk-…`). A mark that
    #     replaces text which was not there is an edit, not a redaction. And a mask never
    #     adds text: a stored value LONGER than the one the lane validated is an edit.
    # A leaf changed to anything else, a key added or removed, a list shortened: red.
    handoff_matches() {  # $1=the stored run (json) $2=the lane's host copy (file) -> 0 if the same hand-off
      jq -en --argjson run "$1" --slurpfile host "$2" '
        def redacted(a; b): (a | type) == "string" and (b | type) == "string" and a != b
                            and ((a | capture("^(?<p>.*?)(?:[*][*][*]|[.][.][.])") // null) as $m
                                 | $m != null and (b | startswith($m.p))
                                   and ((a | length) <= (b | length)));   # a mask never ADDS text
        def texty: [.decisions, .debt, .card_proposals] | map(length);
        ($run.metadata | del(.worker_session_id)) as $a
        | ($host[0] | del(.worker_session_id)) as $b
        | ($a | del(.decisions, .debt, .card_proposals)) as $x
        | ($b | del(.decisions, .debt, .card_proposals)) as $y
        | (($a | texty) == ($b | texty))
          and (([$x | paths(scalars)] | sort) == ([$y | paths(scalars)] | sort))   # key ORDER is not content
          and all([$y | paths(scalars)][];
                  . as $p | ($x | getpath($p)) as $u | ($y | getpath($p)) as $v
                  | $u == $v or redacted($u; $v))' >/dev/null 2>&1
    }
    handoff="$(printf '%s' "$CARD0" | jq -c '[.runs[]? | select(.outcome == "review_requested")] | sort_by(.id) | last // empty' 2>/dev/null)"
    if [ -n "$handoff" ]; then
      handoff_pr="$(printf '%s' "$handoff" | jq -r '.metadata.pr // empty' 2>/dev/null)"
      [ -z "$handoff_pr" ] || [ "$handoff_pr" = "$PR_URL" ] \
        || substrate "env: chunk-identity — the PR url given ($PR_URL) is not the one the lane's hand-off recorded ($handoff_pr)"
      if [ "$(printf '%s' "$handoff" | jq -r '.profile // ""')" = forge-codex-lane ]; then
        lane_copy="$(forge_lane_session_root)/$BOARD-$CHUNK.metadata.json"
        if [ -s "$lane_copy" ]; then
          handoff_matches "$handoff" "$lane_copy" \
            || substrate "other: handoff-integrity — the chunk envelope stored on this card differs from the one the lane validated ($lane_copy): the driver altered it in transit, so what this review would read is not what the lane produced"
          LANE_COPY_NOTE="lane envelope: stored copy equals the one the lane validated"
        else
          LANE_COPY_NOTE="lane envelope: NOT CHECKED — no host copy of what the lane validated ($lane_copy)"
        fi
      fi
    fi
  fi
fi

# An approval is a hand-off to the operator, not an ending. Completing without
# creating anything strands the PR: both cards go `done`, the PR sits at
# REVIEW_REQUIRED, and nothing on the board says a human still owes it a look
# (measured 2026-07-28, first real chunk). The `kanban_create` MCP tool cannot
# express this hand-off — its runtime rejects a missing assignee. The CLI can.
#
# CREATE PARENTLESS. This used to `create --parent "$CHUNK"` directly, on the
# assumption that a chunk card is always `done` by the time tier-1 runs. A
# misrouted --chunk breaks that assumption (handoff-integrity, live
# 2026-09-04: a running prejudge task's OWN id was passed as --chunk), and
# create_task derives the new card's status from ITS PARENTS' status
# (kanban_db.py:3441-3462) — no parent -> `ready`, any parent not `done` ->
# `todo`. `block_task` only ever succeeds `FROM 'running'/'ready'`
# (:6378/:6417/:6432; :6320 is the `dependency`-kind arm), so a `todo` card
# silently fails to block and the read-back below fails closed into
# `other: handoff-integrity` — exactly what was observed. This is the SAME bug
# `hermes/board-bootstrap.sh`'s `create_interactive_card` hit and fixed the
# same way; converge on that shape rather than inventing a second one.
#
# `--initial-status blocked` wrote no sticky `blocked` event before Hermes
# 0.21.5 (which now appends one), so on older kernels the next
# dispatcher sweep promotes the card and `kanban.default_assignee` routes it
# to a real profile — observed twice, once back to the very model that had
# just approved it. Start on a deliberately non-existent sentinel assignee,
# block it through the real state transition, then unassign. THEN, and only
# then, attach the parent with `kanban link`: `link_tasks` demotes a child
# `WHERE status = 'ready'` ONLY (kanban_db.py:3850), so a card already
# `blocked` survives being linked, and the `linked` event it writes is not
# `unblocked`, so `_has_sticky_block` (which reads the latest blocked/unblocked
# event, not the status column) still reports sticky. Linking BEFORE blocking
# would demote the fresh `ready` card to `todo` first and reproduce this exact
# bug one line later — the ordering here is load-bearing, not stylistic.
# `INSERT OR IGNORE INTO task_links` makes the link idempotent, so calling it
# unconditionally (even when idempotency-key resolved to an already-blocked
# card) is safe. The read-back fails closed if any of those substrate facts —
# including the link itself — did not take.
# NEVER CALL route_tier2 OR route_bounce. They are the ADR-0007 tier-2 and fix-card machinery
# ADR-0019 D19.1 retired; they stay defined only until the two `prejudge/` cases that lift them
# are removed in their own slice. They run `hermes kanban create/assign/link`, which a fenced
# worker terminal refuses (epic S6d), so a live call from here could not work anyway.
route_tier2() {
  local body="$1" review
  board_live || return 0
  review="$(kanban create "judge: $CHUNK" \
      --assignee forge-operator-handoff \
      --created-by "${HERMES_KANBAN_TASK:-prejudge-review}" \
      --body "$body" \
      --idempotency-key "tier2-${HERMES_KANBAN_TASK:-$CHUNK}" \
      --json | jq -er '.id')" || return 1

  [ "$(kanban show "$review" --json | jq -r '.task.status')" = "blocked" ] || \
    kanban block --kind needs_input "$review" \
      "other: tier-2 operator review required — run /judge, then merge or bounce" >/dev/null
  kanban assign "$review" none >/dev/null
  kanban link "$CHUNK" "$review" >/dev/null
  kanban show "$review" --json | jq -e --arg chunk "$CHUNK" '
    .task.assignee == null and .task.status == "blocked"
    and any(.events[]; .kind == "blocked")
    and (.parents // [] | index($chunk)) != null' >/dev/null || return 1
  CREATED+=("$review")
}

# A bounce must not just block. The review card is a leaf child of a chunk card
# that is already `completed`; blocking it leaves the findings on a dead leaf
# that nothing routes to a worker. A default child gets a disposable scratch
# directory with neither the rejected branch nor the lane protocol, so it can
# only improvise a clone and may author code directly. The completed chunk's
# preserved linked worktree is shared as a `dir` workspace instead, which keeps
# the original PR branch checked out without asking Hermes to branch from main.
route_bounce() {
  local findings="$1" why="$2" ws fix
  board_live || return 0
  ws="$(kanban show "$CHUNK" --json \
        | jq -er '.task.workspace_path | select(type=="string" and length>0)')" \
    || substrate "env: bounce-workspace — completed chunk has no recorded workspace"
  git -C "$ws" rev-parse --is-inside-work-tree 2>/dev/null | grep -Fxq true \
    || substrate "env: bounce-workspace — completed chunk has no reusable git worktree"

  fix="$(kanban create "fix: $CHUNK — $why" \
      --assignee forge-codex-lane \
      --created-by "${HERMES_KANBAN_TASK:-prejudge-review}" \
      --body "$PR_URL

Repair this existing PR branch only.

$findings" \
      --parent "$CHUNK" --workspace "dir:$ws" --skill forge-lane \
      --idempotency-key "bounce-${HERMES_KANBAN_TASK:-$CHUNK}" \
      --max-runtime 900 --json | jq -er '.id')" || return 1

  # `--workspace` names a KIND, optionally with a path: `scratch`, `worktree`,
  # `worktree:<path>` or `dir:<path>`. A bare path is not one of them — Hermes
  # exits 2 with "unknown --workspace value" before it opens the board, so the
  # `jq -er '.id'` above reads nothing and this whole function returns 1.
  # Measured 2026-09-02 on JobApp: EVERY bounce whose parent chunk ran in a
  # worktree died here, the caller raised `other: handoff-integrity`, and tier
  # 1's real verdict was destroyed with it — recoverable only by re-running the
  # deterministic gate by hand. A bounce is the common case, not the exception.
  #
  # The read-back below is what makes `dir:` load-bearing rather than cosmetic:
  # it proves the fix card will repair the rejected branch in the completed
  # chunk's preserved worktree. `scratch` is the failure it exists to catch
  # (docs/ladder-2026-07-28.md R3-F4 — the cheap driver cloned the repo and
  # authored the change itself), and so is `worktree`, because asking Hermes for
  # a worktree at an already-occupied path makes it fall back to a fresh branch
  # off main, which is not the rejected PR (docs/hermes-field-notes.md).
  kanban show "$fix" --json | jq -e --arg ws "$ws" '
    .task.workspace_kind == "dir" and .task.workspace_path == $ws
    and (.task.skills | index("forge-lane")) != null' >/dev/null || return 1
  CREATED+=("$fix")
}

# ---------------------------------------------------------------------------
# FL4 — the card's own transitions. One card per chunk for its whole life
# (ADR-0019 D19.1), so every outcome below is a transition ON THIS CARD and
# nothing creates one. `route_tier2` and `route_bounce` above are no longer
# called by anything: ADR-0019's Consequences require the replacement to be
# green in its own slice before the dead machinery is deleted, so they stay
# defined, and the `prejudge/` cases that lift them stay green, until that
# slice.
#
# WHY A SCRIPT MAKES THEM. The same reason the lane's handoff is a script
# (FL3): the CLI binds the run id out of the worker's environment, so the
# transition proves ownership of the live review claim, and no model retypes a
# board call.
# ---------------------------------------------------------------------------
card_json() { kanban show "$CHUNK" --json 2>/dev/null; }

# THE UNBLOCK-LOOP GUARD, AND WHY THIS READS EVENTS RATHER THAN COLUMNS.
#
# `_route_block` counts a re-block of the SAME kind as a loop
# (`kanban_db.py:3325`): `recurrences = prev + 1 if prev_kind == kind`, and at
# `BLOCK_RECURRENCE_LIMIT = 2` the card is routed to `triage` instead of
# `blocked`. `block_kind`/`block_recurrences` deliberately survive an `unblock`
# and are cleared only by `complete_task` (`:3665`, `:2786`).
#
# MEASURED 2026-09-26 against the installed kernel in an isolated HERMES_HOME: a
# card in `triage` refuses `complete`, `complete --force`, `promote` AND
# `unblock` — "cannot complete … (unknown id or terminal state)", "promote only
# applies to 'todo' or 'blocked'", "cannot unblock … (not blocked/scheduled?)".
# Its one CLI exit is `hermes kanban specify`, which calls an auxiliary model
# (it failed here with `AuxiliaryClientUnavailable`) and lands the card in
# `todo` — back with an IMPLEMENTER, never at `done`. So a chunk whose PR is
# merged and whose card reached `triage` can never be completed by the
# merge-watcher, and its children never release.
#
# The sequence that gets there is the ordinary one: a recommend-only approval
# blocks `needs_input`; the operator disagrees (`bounce.sh` — `unblock` then
# `reopen-review`); the lane repairs; the verifier approves again. Two
# `needs_input` blocks with no completion between them.
#
# So the verifier never re-blocks with the kind of the last block on this card.
# `hermes kanban show --json` does not expose those columns at all (measured:
# absent from `.task`'s keys, and both read `null`), but every `blocked` event's
# PAYLOAD carries `kind`, so the events are the source of truth. The guard
# exists to stop a WORKER looping unblock/re-block by itself; a re-block that
# follows the operator's own `reopen-review` is not that loop, and the
# alternative is a chunk nothing can finish.
last_block_kind() {
  card_json | jq -r '
    [ .events[]? | select(.kind == "blocked" or .kind == "block_loop_detected") ]
    | last | .payload.kind // empty' 2>/dev/null
}
next_block_kind() {
  if [ "$(last_block_kind)" = needs_input ]; then echo capability; else echo needs_input; fi
}

# FL6's budget, counted from the card's own events and WINDOWED.
#
# `changes_requested` is the only event a bounce writes, and `request-changes` is
# not a block, so it never touches the kernel's recurrence counter — the budget
# is this script's to keep. The window starts at the last operator decision
# (`unblocked` or `review_reopened`), so a chunk the operator explicitly sent
# back after an exception gets its budget again instead of re-tripping the
# exception on its first bounce.
bounce_rounds() {
  local n
  n="$(card_json | jq -r '
    [ .events[]? | .kind ] as $k
    | ( [ $k | to_entries[]
          | select(.value == "unblocked" or .value == "review_reopened") | .key ]
        | last // -1 ) as $since
    | [ $k | to_entries[] | select(.key > $since and .value == "changes_requested") ]
    | length' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) echo 0;; *) echo "$n";; esac
}

# A bounce: the SAME card back to its implementer, with the reasons on it. The
# call is NAMED here (`changes_call`) and made by the driver. Its result is the
# read-back this function used to make — `{ok, status, implementer}`, measured:
# `ready`/`todo` and the implementer the kernel recorded at the hand-off — and a
# kernel that cannot return the card (no implementer provenance) refuses, which
# leaves the card `running` for `on_error` to block.
changes_call() {  # $1=reasons body
  call_json kanban_request_changes "$(task_args '{reason: $r}' --arg r "$1")"
}

# WHERE THE VERDICT GOES WHEN THE TRANSITION CANNOT CARRY IT.
#
# `kanban_complete` and `kanban_request_review` take `metadata`. `kanban_block` and
# `kanban_request_changes` DO NOT (measured against the installed tool schemas). So
# on every path except a merge, the envelope this script computed — `forge.gate.v1`
# or `forge.judge.v1`, the rows `scripts/metrics.sh` counts — has no run to ride.
#
# It used to be posted as a card COMMENT under a stable marker (`FORGE-VERDICT-V1`),
# and the merge-watcher passed it back as `--metadata` when it completed the card.
# A comment is a board write, which a fenced terminal cannot make, and posting it
# through the driver would have it retype ~2 KB of JSON. So it is a HOST FILE now,
# keyed by board and card, written here and read by the merge-watcher
# (`scripts/forge-state.sh` is the one definition of where). Nothing is retyped. The
# cost: the verdict is not on the card until the card completes — and nothing but
# the watcher ever read it there (the lane only filtered it out of its contract).
#
# Measured: completing a card with no live claim opens a NEW run
# (`profile = forge-verifier`, `outcome = completed`) and the metadata lands on
# it, so `rubrics/run-metadata-contract.json`'s `forge-verifier` entry is true of
# a merged chunk however it was completed.
#
# It goes down BEFORE the transition is named, and it never fails the outcome — a
# verdict that was reached must not be destroyed by a disk that would not take a
# file. A failed write is said out loud instead: the watcher then completes the
# card with "NO stored verdict envelope", which names the absence.
stash_envelope() {  # $1=metadata file
  board_live || return 0
  [ -s "$1" ] || return 0
  # ONLY AN ENVELOPE THE CONTRACT ALLOWS THIS PRODUCER TO COMPLETE WITH.
  # `rubrics/run-metadata-contract.json` maps forge-verifier to forge.gate.v1 and
  # forge.judge.v1 — and nothing else. The bounce path's metadata file is whatever
  # produced the bounce, which on the merged-tree arm is a `forge.mergecheck.v1`
  # object: stashing that would have the merge-watcher complete the card with a
  # schema the registry does not know, and `metadata-live` exits 1 on it — the
  # "stop and repair the producer" failure this file already carries a scar from
  # (Stage 4a). A file that is not stashable simply is not stashed, and the
  # watcher then completes with a result that says no envelope was stored.
  #
  # AND SOMETHING CONTRACTED IS ALWAYS STASHED, because the absence is a violation
  # too: `metadata-live` counts a completed producer run with null metadata as
  # `invalid`, exactly like a wrong schema. So an unstashable envelope falls back
  # to the gate result, which is a `forge.gate.v1` on every path that reaches this
  # point and is honest about what it says — the gate's own verdict, with the
  # merged-tree evidence already on the card in the bounce reasons.
  local file="$1" root dest
  case "$(jq -r '.schema // ""' "$file" 2>/dev/null)" in
    forge.gate.v1|forge.judge.v1) ;;
    *) file="$GATE"
       case "$(jq -r '.schema // ""' "$file" 2>/dev/null)" in
         forge.gate.v1|forge.judge.v1) ;;
         *) return 0;;
       esac;;
  esac
  root="$(forge_verdict_root)"; dest="$root/$BOARD-$CHUNK.json"
  if mkdir -p "$root" 2>/dev/null && jq -c . "$file" > "$dest.new" 2>/dev/null && mv -f "$dest.new" "$dest"; then
    :
  else
    rm -f "$dest.new" 2>/dev/null
    echo "verdict stash: could not write $dest — the merge-watcher will complete this card with NO stored verdict envelope" >&2
  fi
}

# An approval the verifier may only RECOMMEND (ADR-0019 D19.3). The card is
# blocked sticky; the operator merges on GitHub; the merge-watcher completes it.
# The block is NAMED here and made by the driver. Its kind comes from the card's own
# events (`next_block_kind`), never from the driver. The kernel's result carries the
# end state (`status`, `block_kind`): `triage` there means the block was routed to
# the kernel's unblock-loop breaker anyway — a hold that was never taken. That is
# PREVENTED here (the kind rotates) rather than detected after the run ended, and
# `digest.sh` lists a `triage` card as one no script can complete (epic P8).
hold_call() {  # $1=reason, already carrying its registry class
  term_block "$1" "$(next_block_kind)"
}

# Merge mode. NOT a configuration this script may choose: it is the operator's
# switch, flipped once on the flip criterion (D19.3/D19.4), and its ABSENCE is
# recommend-only. Only the exact string `1` enables it, so a typo, an empty
# value or an inherited `0` all fail closed to recommending.
#
# D19.6 is all three parts: squash, delete the branch, and the merge is read
# back from GitHub before the card is completed. A `gh pr merge` that exits 0
# without merging (a race, an unmergeable state) must not complete a card whose
# work is not on `main`.
#
# TWO SWITCHES, either of which opens it:
#   * `FORGE_VERIFIER_MERGE=1`: the host-wide one, exactly as above. Nothing about a board or a chunk is asked.
#   * A BOARD GRANT: <state>/merge-authority/<board>.json, written by `scripts/merge-authority.sh grant <board>
#     --by <actor>` and read by forge_merge_authority_read (forge-state.sh), which fails closed: no board, no
#     file, an unreadable or malformed one, one whose inner `board` is not byte-identical to $BOARD (the host
#     volume is case-insensitive, so the file name proves nothing) or one that names nobody are all "no grant".
#     `FORGE_VERIFIER_MERGE=0`, or any other value, neither disables a grant nor enables merging on its own.
#
# A GRANT MERGES ONLY A CHUNK THE LANE BUILT. This is an ALLOWLIST: under a grant the recorded implementer, the one
# the kernel stored on the card's last `review_requested` event (what bounce.sh returns the card to), must be
# exactly the lane profile `forge-codex-lane`. Anything else takes the recommend-only hold, and the hold says why:
# the non-spawnable sentinel `forge-operator-handoff` (the literal, whatever FORGE_HANDOFF_SENTINEL says) and
# `claude-interactive` are a person's chunk; an empty or unreadable implementer cannot be shown to be nobody's;
# any other string (a card reassigned to another profile, a lookalike) is simply not the lane. THE ENV SWITCH IS NOT
# GIVEN THIS RULE (it is the unchanged host-wide switch: nothing in the approve branch asked who built the chunk
# before this), so a person's chunk still merges under FORGE_VERIFIER_MERGE=1.
#
# The decision is made HERE, at the one place an approval is acted on, not at the start of the run, so a revoke
# made during a long review still wins. Called once, from the approve branch, in the shell that reads the
# globals it sets:
#   MERGE_AUTHORITY_CLAUSE  non-empty only for a merge made under a grant: it is said on the merge's own record
#   MERGE_HOLD_HEADLINE / MERGE_HOLD_MEANS  non-empty only when a grant exists and this chunk is held anyway
MERGE_AUTHORITY_CLAUSE=""; MERGE_HOLD_HEADLINE=""; MERGE_HOLD_MEANS=""
merge_mode() {
  # A plain assignment, never an environment override: who may be merged under a grant is not configuration.
  local implementer lane=forge-codex-lane
  MERGE_AUTHORITY_CLAUSE=""; MERGE_HOLD_HEADLINE=""; MERGE_HOLD_MEANS=""
  [ "${FORGE_VERIFIER_MERGE:-}" = 1 ] && return 0
  forge_merge_authority_read "$BOARD" || return 1
  implementer="$(printf '%s' "${CARD0:-}" | jq -r '
      [.events[]? | select(.kind == "review_requested")] | last | .payload.implementer // ""' 2>/dev/null)"
  if [ "$implementer" != "$lane" ]; then
    local grant="Board $BOARD has given the verifier merge authority (granted by $FORGE_MA_BY at $FORGE_MA_AT)"
    case "$implementer" in
      "")
        MERGE_HOLD_HEADLINE="this board has merge authority, but this card names no implementer, so the merge is yours"
        MERGE_HOLD_MEANS="$grant, but the card records no implementer, so it cannot be shown that the lane built this chunk. A grant merges only a chunk the lane ($lane) built; the merge is yours";;
      forge-operator-handoff|claude-interactive|"${FORGE_HANDOFF_SENTINEL:-forge-operator-handoff}")
        MERGE_HOLD_HEADLINE="this board has merge authority, but this chunk was built by a person, so the merge is yours"
        MERGE_HOLD_MEANS="$grant, but this chunk was built by a person (recorded implementer: $implementer), and a grant merges only a chunk the lane ($lane) built; the merge is yours";;
      *)
        MERGE_HOLD_HEADLINE="this board has merge authority, but this chunk was not built by the lane, so the merge is yours"
        MERGE_HOLD_MEANS="$grant, but this chunk's recorded implementer is $implementer, not the lane ($lane), and a grant merges only a chunk the lane built; the merge is yours";;
    esac
    return 1
  fi
  MERGE_AUTHORITY_CLAUSE="board merge authority granted by $FORGE_MA_BY at $FORGE_MA_AT"
  return 0
}
# Three answers, never two: `merged`, `unmerged` (GitHub answered, and the PR is not merged) and
# `unreadable` (it did not answer, twice). A read that fails once is retried once.
pr_merge_state() {
  local try out
  for try in 1 2; do
    out="$(gh pr view "$PR_URL" --json state,mergedAt < /dev/null 2>/dev/null)" \
      && printf '%s' "$out" | jq -e 'has("state")' >/dev/null 2>&1 && {
        printf '%s' "$out" | jq -e '.state == "MERGED" and (.mergedAt | type) == "string"' >/dev/null \
          && echo merged || echo unmerged
        return 0; }
    [ "$try" = 1 ] && sleep 1
  done
  echo unreadable
}
# Return 1: nothing was merged. Return 4: the merge LANDED, or `gh pr merge`
# ACCEPTED it, and GitHub did not confirm it afterwards: the work is probably on
# the base branch, and the card has to be held where the merge-watcher will finish
# it (see the caller). Return 5: the PR's head is not the head this run verified,
# so nothing was attempted (epic P9). The completion is NOT made here (no board
# writes): the caller names `kanban_complete`, with the `merge-pending:` hold as
# its `on_error`.
MERGE_REFUSAL=""
route_merge() {
  # `--match-head-commit` is not belt-and-braces: without it this merges whatever
  # the head is NOW, and every stage above read the PR separately over several
  # minutes. A push in that window would put code on `main` that nothing in this
  # run verified — on an ungated repo, with no second gate behind it. An empty
  # VERIFIED_HEAD means the read failed, and a merge that cannot name what it
  # verified must not happen at all.
  [ -n "$VERIFIED_HEAD" ] || return 1
  # P9 (owner decision, 2026-11-05): MERGE MODE REFUSES A HEAD THAT MOVED AFTER THE
  # VERDICT. The pin above only fails the merge at GitHub; this refuses it here, by
  # name, before `gh pr merge` is asked at all, and compares the head the verdict
  # was ABOUT (the gate's own read, `$GATE .head`, which the scorer's diff came
  # from) with the head Stage 0 pinned and the head the PR has now. Review is NOT
  # re-opened by this: the card is held for the operator, and a merge made later
  # is flagged by the merge-watcher as a head drift, never counted as verified.
  local verdict_head live_head
  verdict_head="$(jq -r '.head // empty' "$GATE" 2>/dev/null)"
  live_head="$(gh pr view "$PR_URL" --json headRefOid < /dev/null 2>/dev/null | jq -r '.headRefOid // empty')"
  [ -n "$verdict_head" ] && [ -n "$live_head" ] || return 1
  if [ "$verdict_head" != "$VERIFIED_HEAD" ] || [ "$live_head" != "$VERIFIED_HEAD" ]; then
    MERGE_REFUSAL="head-drift — the verdict is about ${verdict_head:0:12} (pinned ${VERIFIED_HEAD:0:12}) and $PR_URL is now at ${live_head:0:12}, so nothing was merged"
    return 5
  fi
  if ! gh pr merge --squash --delete-branch --match-head-commit "$VERIFIED_HEAD" "$PR_URL" \
         >/dev/null 2>&1 < /dev/null; then
    # A NON-ZERO EXIT IS NOT "NOTHING MERGED" (epic P10(4)). `gh pr merge` can land the
    # squash and then fail on the rest (`--delete-branch`, say). Treating that as
    # return 1 blocked the card `other: handoff-integrity`, which the merge-watcher
    # does not sweep, so the PR was on the base branch and the card was held forever.
    # GitHub is asked, and the answer has three values: MERGED takes rc 4 (held
    # `merge-pending:`, finished by the watcher); a definite not-merged answer is a
    # merge that did not take (return 1); and an answer that cannot be read, after one
    # retry, ALSO takes rc 4 — the hold is the one state the watcher resolves later
    # (it completes on MERGED and is silent while the PR is OPEN), whereas return 1
    # would strand a merge that did land.
    case "$(pr_merge_state)" in
      unmerged) return 1;;
      *) return 4;;
    esac
  fi
  [ "$(pr_merge_state)" = merged ] || return 4
  return 0
}

# ---------------------------------------------------------------------------
# WHO WROTE THE DIFF — one line, on the card a human opens before merging (F22).
#
# 2026-09-08: the Codex desktop app rewrote `~/.codex/config.toml` to a model
# nobody pinned. `config/codex-pin-live` FAILED against it — the control worked.
# Nobody looked. Lane run 52 then authored CHUNK-11 under the unpinned model and
# run 55 APPROVED that diff, with nothing on either card naming what wrote it.
#
# THAT WAS AN ATTENTION FAILURE, NOT A DETECTION FAILURE, and the four PRs since
# (#63 provenance, #64 one pin file, #65 the pin is passed not inherited, #66
# set-model.sh) all improved detection. Better records nobody reads recur as the
# same finding a fourth time. This is the line that makes the record land in
# front of the one reader who can still stop the merge.
#
# `codex_model_source` IS THE HALF THAT MATTERS. `rollout` is evidence — Codex's
# own session log said so. `requested` is intent — the rollout could not be
# read, so all that is known is the pin that was ASKED for, which is precisely
# what the incident proved can differ from what ran. A line that printed the
# model and swallowed the marker would read identically in both cases, which is
# F22 wearing the fix's clothes (rubrics/chunk-handoff.schema.json says so too).
#
# ABSENCE IS PRINTED, NEVER OMITTED. A chunk card naming no model is the
# 2026-09-08 shape exactly; a silent line reproduces the silence this exists to
# end. Same rule as a check that goes blind: it has not passed.
#
# This reads the CHUNK card, not the review card: the model is stamped by the
# lane into the chunk's own completion envelope (forge-lane §7). `.runs[]
# .metadata` comes back as a PARSED OBJECT — measured against Hermes 0.20.6, not
# assumed, because `--json` shapes differ per subcommand and jq answers a wrong
# path with silence (docs/ladder-2026-07-28.md R3-F2). Runs are sorted here by
# `started_at` rather than trusting the array's order for the same reason.
#
# It never fails the review. A missing provenance line must not cost a verdict
# that was actually reached — the same rule the shadow stamp keeps below.
implementer_model_line() {
  local shown="" line=""
  board_live && shown="$(kanban show "$CHUNK" --json 2>/dev/null)"
  # Gating matches scripts/metrics.sh's `json_type(...)='text' AND
  # trim(...)<>''` for the same three fields: a whitespace-only string is
  # `type == "string"` and `length > 0` but carries no evidence, so `length`
  # alone is not enough — least of all for codex_model_requested, whose ONLY
  # job is to trigger the F22 alarm below it.
  [ -n "$shown" ] && line="$(printf '%s' "$shown" | jq -r '
      def present: type == "string" and (gsub("^\\s+|\\s+$";"") | length) > 0;
      [ (.runs // [])[]
        | select((.metadata | type) == "object")
        | select(.metadata.codex_model | present) ]
      | sort_by(.started_at, .id) | last | .metadata
      | if . == null then
          "implementer model: NOT RECORDED — no completed run on this chunk card names the model that wrote this diff (F22)"
        else
          "implementer model: \(.codex_model)"
          + (if (.codex_reasoning_effort | present)
             then " \(.codex_reasoning_effort)" else "" end)
          + (if .codex_model_source == "rollout"
             then " — source: rollout (Codex own session log; evidence)"
             elif .codex_model_source == "requested"
             then " — source: REQUESTED, not observed — the rollout could not be read, so this is the pin that was asked for and NOT proof of what ran"
             else " — source: absent; provenance unverified" end)
          + (if (.codex_model_requested | present)
             then " — the pin requested \(.codex_model_requested); WHAT RAN IS NOT WHAT WAS PINNED (F22)"
             else "" end)
        end' 2>/dev/null)"
  printf '%s\n' "${line:-implementer model: UNREADABLE — the chunk card could not be read, so nothing here names the model that wrote this diff (F22)}"
}

# GW1's format, as a function rather than as a habit: what happened, what it
# means, the one decision, the risk, the one reply. No decision, no message.
# It lives in one file shared with the merge-watcher and the digest, so the
# operator reads one shape whoever is speaking; an unreadable copy is a
# substrate fault, because every hold this script makes is written through it.
# shellcheck source=decision-message.sh
. "$HERE/decision-message.sh" 2>/dev/null && declare -F decision_message >/dev/null \
  || substrate "env: decision-message.sh is missing beside prejudge-review.sh — no hold could be written in the operator's format"

# FL6 — two bounce rounds, then ONE exception, and the exception is a completable
# block rather than the kernel's `triage`. The epic reached the same number by a
# different route ("same-kind re-blocks route to triage at
# BLOCK_RECURRENCE_LIMIT=2"); that route is measured above to be a dead end for a
# chunk card, so the budget is counted here and the exception is an ordinary
# sticky block the operator can act on. `FORGE_VERIFIER_BOUNCE_BUDGET` exists so
# a case can drive the boundary without three round trips; it defaults to 2 and
# nothing in the pipeline sets it.
bounce_or_except() {  # $1=reasons  $2=one-line why  $3=metadata file  $4=action [bounce]
  local rounds budget="${FORGE_VERIFIER_BOUNCE_BUDGET:-2}" action="${4:-bounce}"
  rounds="$(bounce_rounds)"
  stash_envelope "$3"
  if [ "$rounds" -lt "$budget" ]; then
    envelope "$action" "$2 (round $((rounds + 1)) of $budget)" "$3" "" 4 \
      "$(changes_call "$PR_URL

$(implementer_model_line)${LANE_COPY_NOTE:+$(case "$LANE_COPY_NOTE" in *"NOT CHECKED"*) printf '\n%s' "$LANE_COPY_NOTE";; esac)}
$2

$1")" \
      "$(term_block "other: handoff-integrity — request-changes did not return this card to its implementer")"
  fi
  envelope exception "$2 — bounce budget spent after $rounds rounds" "$3" "" 4 \
    "$(hold_call "$(decision_message bounce-budget \
    "$2 — and this chunk has now used its $budget bounce rounds" \
    "the verifier bounced it $rounds times with actionable reasons and the work still does not pass; a third machine round is not evidence of anything new" \
    "repair it yourself, amend the contract, or send it back for another round" \
    "the card is blocked and its children stay held; nothing is merged" \
    "fix and push to the PR branch, or \`~/.forge/repo/scripts/bounce.sh $CHUNK \"<reason>\" --board $BOARD\` to give it another round

$1")")" \
    "$(term_block "other: handoff-integrity — the bounce-budget exception did not land as a block")"
}

# ---------------------------------------------------------------------------
# Stage 0 — WHICH COMMIT THIS RUN IS ABOUT, read once, before anything looks at
# the PR.
#
# Every stage below asks GitHub separately: the gate reads the CI rollup, the
# merged-tree check clones, the scorer buys the diff. That is minutes, and a push
# landing inside it silently re-points each later stage at a different commit. The
# verdict would then be about a mixture, and in merge mode `gh pr merge` would land
# whatever the head is at the end — CI never checked by this gate, a diff never
# read by this scorer.
#
# So the head SHA is read HERE, carried to the merged-tree check (`--head-sha`) and
# to the merge (`--match-head-commit`). If it cannot be read, merge mode refuses to
# merge (route_merge) rather than merging something it cannot name. Reading it
# earlier does not close the window — the gate's CI read still happens after this —
# but it makes a moved head a REFUSED MERGE instead of an unnoticed one, which is
# the difference between a failure and a defect. `route_merge` closes the rest (epic P9):
# it refuses a head that is not the one the verdict was about, and the merge-watcher
# flags a merge the operator made at a different head.
#
# In fixture mode it comes out of the recorded `pr.json`, so no dry-run case needs
# a live `gh`.
VERIFIED_HEAD=""
if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE/pr.json" ] && VERIFIED_HEAD="$(jq -r '.headRefOid // empty' "$FIXTURE/pr.json" 2>/dev/null)"
else
  VERIFIED_HEAD="$(gh pr view "$PR_URL" --json headRefOid < /dev/null 2>/dev/null | jq -r '.headRefOid // empty')"
fi

# ---------------------------------------------------------------------------
# Stage 1 — the gate. Before anything is spawned and before a diff is bought.
# ---------------------------------------------------------------------------
GATE="$TMP/gate.json"
gate_args=("$PR_URL" --json --wait "$WAIT_SECS")
[ -n "$REPO" ]    && gate_args+=(--repo "$REPO")
[ -n "$FIXTURE" ] && gate_args+=(--fixture "$FIXTURE")
"$HERE/prejudge.sh" "${gate_args[@]}" > "$GATE" 2>"$TMP/gate.err"; gate_rc=$?

[ "$gate_rc" = 2 ] && substrate "gate-unrunnable: $(tr -d '\n' < "$TMP/gate.err" | head -c 300)"
[ -s "$GATE" ] || substrate "gate-unrunnable: the gate produced no result object"

# ---------------------------------------------------------------------------
# Stage 5a — the gate blocked. No model was spawned, so there is no verdict and
# none may be manufactured. The gate result is stored as it came out, and the
# blocking findings are rendered rather than retyped: each already carries an
# `action` a fresh worker can execute with no questions, which is the bounce
# contract in rubrics/judge-rubric.md binding a program instead of a model.
# ---------------------------------------------------------------------------
if [ "$gate_rc" = 1 ]; then
  ids="$(jq -r '.blocks | join(", ")' "$GATE")"
  bounce_or_except "$(jq -r '.checks[] | select(.status=="block")
                      | "- **\(.id)** — \(.evidence)\n  - action: \(.action)"' "$GATE")" \
                   "gate blocked: $ids" "$GATE" gate-block
fi

# ---------------------------------------------------------------------------
# Stage 2 — assemble the scorer's prompt. The diff is moved, never read: it is
# redirected into a file and only its byte count is ever observed. The largest
# measured review payload is 127,738 bytes ~ 32k tokens; rendering that into
# the driver's context bills it to the one metered agent in the run and then
# sends it, free, to the OAuth engine that actually needs it. Sampling it with
# `head` or a summariser is the same purchase at a discount.
# ---------------------------------------------------------------------------
prompt_file="$TMP/prompt.txt"
contract_file="$TMP/contract.md"
if [ "$CONTRACT_FROM_CARD" = 1 ]; then
  # The contract IS the card's body (the lane read the same field for Codex), read from the card
  # this program already identified — not retyped by a driver into a shell command, and not a
  # stdin a background terminal call does not have.
  printf '%s' "$CARD0" | jq -r '.task.body // ""' > "$contract_file" 2>/dev/null
  [ -s "$contract_file" ] && grep -q '[^[:space:]]' "$contract_file" \
    || substrate "stale-spec: card $CHUNK has an empty body — there is no contract to review against"
else
  cat > "$contract_file"   # the chunk contract, on stdin
fi

# --- PINNED REGION (scorer brief) — three-space indent is load-bearing. ------
# The heredoc is quoted and NOT `<<-`, so every leading space is part of the
# prompt the model receives. Reindenting changes the control arm's input.
   cat > "$prompt_file" <<'SCORER'
   You are tier 1 of a two-tier review: a filter, not the judge. Score the diff
   below against the chunk contract below, and return the verdict object the
   schema demands — nothing else.

   Scoring and verdict logic live in `~/.forge/rubrics/judge-rubric.md`. Read it
   before scoring.

   Machines already checked what machines can check, and more than CI: a
   deterministic gate cleared this PR's CI state, branch name, scenario count,
   `Touches` boundary and assertion shape before you were called. Do not spend a
   line re-deciding any of them. Look for the one thing no program can see.

   - **Scenario theater** — tests that pass without exercising the promised
     behaviour: mocked-away core paths, Then-clauses weaker than the contract's,
     a scenario whose name promises more than its steps check.

   Anything subtler than that is the operator's call, not yours. Pass it
   through: this tier can only bounce work that is obviously bad, and a
   marginal bounce costs a full repair cycle.

   **Every finding needs evidence**: `file:line` or a verbatim quote. A score
   below 3 with no corresponding finding is invalid.

   **Every finding's action must be executable** by a fresh worker with no
   questions. "Scenario 3 asserts nothing" — not "tests could be better". A
   bounced finding is copied verbatim into the repair card, so a vague finding
   becomes an unworkable card.
SCORER
# --- end pinned region ------------------------------------------------------

printf '\n## Chunk contract\n\n' >> "$prompt_file"
cat "$contract_file" >> "$prompt_file"
printf '\n## Diff under review\n\n' >> "$prompt_file"
if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE/diff.patch" ] && cat "$FIXTURE/diff.patch" >> "$prompt_file"
else
  gh pr diff "$PR_URL" >> "$prompt_file" < /dev/null \
    || substrate "env: diff-unavailable — the diff fetch returned nothing usable"
  # A brief plus a contract is ~2 KB before any diff at all, so a prompt that
  # small means the fetch succeeded and returned nothing.
  [ "$(wc -c < "$prompt_file")" -gt 2500 ] \
    || substrate "env: diff-unavailable — prompt is implausibly small for a PR"
fi
PROMPT_BYTES="$(wc -c < "$prompt_file" | tr -d ' ')"

# `--dry-run` stops exactly here: the gate has run and the prompt exists, but
# nothing has been spawned and no board has been touched. It is what makes the
# clear-side path testable offline, and what lets a human rehearse a review
# without dispatching anything — the S2/S3/S4 discipline, in one command.
if [ "$DRY_RUN" = 1 ]; then
  jq -n --argjson bytes "$PROMPT_BYTES" --argjson gate "$(cat "$GATE")" \
     '{prompt_bytes: $bytes, gate: $gate}' > "$TMP/dry.json"
  envelope would-score \
    "gate clear; prompt assembled, ${PROMPT_BYTES}B, no model spawned" \
    "$TMP/dry.json" "" 0
fi

# ---------------------------------------------------------------------------
# Stage 1b — `make check` on the tree the merge would produce (ADR-0019 D19.2).
#
# It runs AFTER the dry-run exit above, so `--dry-run` still means exactly "the
# gate ran and the prompt exists, nothing spawned, no board touched", and BEFORE
# the scorer, which is the only paid stage: a union that does not build is not
# worth a model's opinion.
#
# The clone source is the PR's own repository, read from `gh`, never the cwd —
# the verifier's workspace is scratch and may hold no clone at all.
# `FORGE_MERGE_CHECK_BIN` lets a case drive a recorded outcome without a
# network; `scripts/merge-check.sh`'s own cases execute the real thing against
# real local repositories.
#
# A NOT-PASS RESULT MAY NEVER BECOME AN APPROVAL. `pass` continues to the
# scorer; `conflict` and `check-failed` are bounces with the script's own action
# text; anything else — including `skipped`, which is what a fixture run without
# an override produces — is a substrate fault. "Could not be run" is not a pass
# (the rule `prejudge/skip-is-distinguishable-from-pass` states for the gate).
# ---------------------------------------------------------------------------
MERGE_CHECK_BIN="${FORGE_MERGE_CHECK_BIN:-$HERE/merge-check.sh}"
MERGED="$TMP/merged-tree.json"; TREE="$TMP/merged-tree"
merge_repo=""; head_ref=""; base_ref=""; clone_url=""
if [ -n "$FIXTURE" ] && [ -z "${FORGE_MERGE_CHECK_BIN:-}" ]; then
  jq -n '{schema:"forge.mergecheck.v1", result:"skipped",
          evidence:"--fixture without FORGE_MERGE_CHECK_BIN: no repository to merge"}' > "$MERGED"
  merged_rc=3
else
  # THE REPOSITORY COMES FROM THE PR URL, NEVER FROM THE CWD. `gh repo view` with
  # no argument asks git about the working directory and dies with "not a git
  # repository" — and the verifier's workspace is `scratch`, which holds no clone.
  # Measured: every real review would have ended here as a substrate fault while
  # every fixture passed, because a stub answers whatever it is asked. So the
  # owner/name is derived from the canonical URL (the same URL that gives `gh` its
  # context everywhere else in this file), and `--repo` still wins when given.
  merge_repo="$REPO"
  if [ -z "$merge_repo" ]; then
    merge_repo="${PR_URL%/pull/*}"; merge_repo="${merge_repo#*://}"
    merge_repo="${merge_repo#*/}"          # strip the host, leaving owner/name
  fi
  # THE BASE IS THE PR'S OWN, NEVER AN ASSUMED `main`. merge-check.sh defaults to
  # `main`, and this call used to lean on that default: a product repo whose
  # default branch is `master` got "no origin/main in the clone" on every review
  # (every card blocked as a substrate fault), and a stacked PR was tested against
  # a base it will never merge into. An unreadable base fails closed — falling
  # back to `main` would be that bug again.
  pr_refs="$(gh pr view "$PR_URL" --json headRefName,baseRefName < /dev/null 2>/dev/null)"
  head_ref="$(printf '%s' "$pr_refs" | jq -r '.headRefName // empty' 2>/dev/null)"
  base_ref="$(printf '%s' "$pr_refs" | jq -r '.baseRefName // empty' 2>/dev/null)"
  clone_url="$(gh repo view "$merge_repo" --json url < /dev/null 2>/dev/null | jq -r '.url // empty')"
  [ -n "$head_ref" ] && [ -n "$base_ref" ] && [ -n "$clone_url" ] \
    || substrate "env: merge-check-unrunnable — cannot read the PR's head branch, its base branch, or the repository URL for '$merge_repo', from gh (this must not depend on the cwd: the verifier's workspace holds no clone)"
  # --head-sha pins the union to Stage 0's commit: without it this clones "the
  # branch", which may have moved since.
  # --keep-at leaves the prepared, merged clone where Stage 1c can probe it: the
  # mutation probe must judge the tree this stage proved green, not a second one.
  "$MERGE_CHECK_BIN" --clone-from "$clone_url" --head-ref "$head_ref" --base-ref "$base_ref" \
    ${VERIFIED_HEAD:+--head-sha "$VERIFIED_HEAD"} --keep-at "$TREE" > "$MERGED" 2>"$TMP/merged.err"
  merged_rc=$?
fi
merged_result="$(jq -r '.result // "unreadable"' "$MERGED" 2>/dev/null || echo unreadable)"
case "$merged_result" in
  pass) ;;
  conflict|check-failed)
    bounce_or_except "$(jq -r '"- **merged-tree** — \(.evidence)\n  - action: \(.action // "make the union green and push")"' "$MERGED")" \
                     "merged tree: $merged_result" "$MERGED";;
  *) substrate "env: merge-check-unrunnable — $(jq -r '.evidence // "no result object"' "$MERGED" 2>/dev/null | head -c 300) (rc $merged_rc)";;
esac

# ---------------------------------------------------------------------------
# Stage 1c — the mutation probe (FL5). Does any test OBSERVE each line this PR
# changed?
#
# Neither tier caught JobApp C21's two blockers by reading; a mutation did — the
# judge deleted every config read the chunk added and the suite stayed
# green. That is the class this stage executes: it mutates the implementation
# lines the PR changed, in the merged tree Stage 1b kept (`--keep-at`), runs the
# project's tests against each mutant, and reports every changed line on which
# EVERY mutant survived. Such a line is one no test can see, whatever the
# scenarios claim. The rule, its operators and its budget live in
# `scripts/mutation-probe.py`; this stage only routes the result.
#
# UNDER THE SWITCH, THE SAME THREE-WAY CONTRACT AS STAGE 1b. `pass` continues
# to the scorer; `survived` is a bounce with one actionable reason per
# unobserved line; anything else — including `skipped`, which is what a fixture
# run without an override produces, and a probe that could not run its own
# unmutated baseline — is a substrate fault. A probe that did not run has not
# passed.
#
# WITHOUT THE SWITCH (the default), nothing here transitions the card: every
# outcome continues to the scorer and is written on the hold — `pass` as such,
# `survived` with the lines it WOULD have bounced, anything else as "did not
# run". It is never reported as a pass it was not, and the implementer never
# sees a report-only finding, because acting on it would make it a bounce in
# all but name. Only the exact string `1` enables bouncing, so a typo, an empty
# value or an inherited `0` all fail closed to reporting — the same rule as
# FORGE_VERIFIER_MERGE.
#
# `FORGE_MUTATION_PROBE_BIN` lets a case drive a recorded outcome; the probe's
# own cases execute the real thing against real repositories.
# ---------------------------------------------------------------------------
PROBE_BIN="${FORGE_MUTATION_PROBE_BIN:-$HERE/mutation-probe.py}"
PROBE="$TMP/mutation-probe.json"
if [ -n "$FIXTURE" ] && [ -z "${FORGE_MUTATION_PROBE_BIN:-}" ]; then
  jq -n '{schema:"forge.mutation.v1", result:"skipped",
          evidence:"--fixture without FORGE_MUTATION_PROBE_BIN: no tree to mutate"}' > "$PROBE"
  probe_rc=3
else
  "$PROBE_BIN" --tree "$TREE" --base-sha "$(jq -r '.base_sha // empty' "$MERGED" 2>/dev/null)" \
    --budget "${FORGE_MUTATION_BUDGET:-420}" > "$PROBE" 2>"$TMP/probe.err"
  probe_rc=$?
fi
probe_result="$(jq -r '.result // "unreadable"' "$PROBE" 2>/dev/null || echo unreadable)"
probe_bounces() { [ "${FORGE_MUTATION_PROBE_BOUNCE:-}" = 1 ]; }
case "$probe_result" in
  pass) ;;
  survived)
    # Reporting (no switch), nothing transitions here: the lines go on the hold
    # below. Bouncing, at most 30 lines are listed — the reasons ride a card
    # event, and a PR with hundreds of unobserved lines needs its count and its
    # first lines, not a 40 KB comment. The count is always the whole number.
    if probe_bounces; then
    bounce_or_except "$(jq -r '(.unobserved[:30][]? |
        "- **mutation-probe** — `\(.file):\(.line)` `\(.source)`: no test failed under \(.mutants | map("`" + .mutation + "`") | join(", "))\n  - action: \(.action)"),
        (if (.unobserved | length) > 30 then "- …and \((.unobserved | length) - 30) more unobserved line(s) of the same kind" else empty end)' "$PROBE")" \
      "mutation probe: $(jq -r '.unobserved | length' "$PROBE" 2>/dev/null) changed line(s) no test observes" "$PROBE"
    fi;;
  *) ! probe_bounces \
       || substrate "env: mutation-probe-unrunnable — $(jq -r '.evidence // "no result object"' "$PROBE" 2>/dev/null | head -c 300) (rc $probe_rc)";;
esac
# What the hold says about the probe, in every mode. Report-only findings name
# their lines (at most ten) so the operator can judge them at the merge.
case "$probe_result" in
  pass)     PROBE_LINE="mutation probe: $(jq -r '.evidence // ""' "$PROBE" 2>/dev/null | head -c 300)"
            PROBE_CLAUSE="every changed line it probed is observed by a test";;
  survived) PROBE_LINE="mutation probe: REPORT-ONLY, would bounce under FORGE_MUTATION_PROBE_BOUNCE=1 — $(jq -r '.evidence // ""' "$PROBE" 2>/dev/null | head -c 300)
$(jq -r '.unobserved[:10][]? | "  - \(.file):\(.line) `\(.source)` — no test failed under \(.mutants | map(.mutation) | join("; "))"' "$PROBE" 2>/dev/null)$(jq -r 'if (.unobserved | length) > 10 then "\n  - …and \((.unobserved | length) - 10) more" else "" end' "$PROBE" 2>/dev/null)"
            PROBE_CLAUSE="the mutation probe found $(jq -r '.unobserved | length' "$PROBE" 2>/dev/null) changed line(s) no test observes (report-only, listed below)";;
  *)        PROBE_LINE="mutation probe: DID NOT RUN (report-only, so this does not block) — $(jq -r '.evidence // "no result object"' "$PROBE" 2>/dev/null | head -c 300)"
            PROBE_CLAUSE="the mutation probe did not run (report-only, see below)";;
esac

# ---------------------------------------------------------------------------
# A CLAUDE USAGE LIMIT ON THE JUDGE IS WAITED OUT, NOT HELD FOR A PERSON.
#
# 2026-11-15, the first hands-free run: the judge hit the account's 5-hour limit, both reviews ended in
# `env: judge-envelope — … api_error_status=429`, and two cards sat held for three hours until a person unblocked
# them after the reset. Nothing was wrong with either PR.
#
# THE BETTER SHAPE WAS NOT AVAILABLE (docs/hermes-field-notes.md, "scheduled has no wake"): Hermes 0.21.5 has no
# worker tool that schedules a card, `scheduled` has no wake time, and `unblock` of a scheduled card lands it
# `ready` on the lane, not in `review`. So this process waits, and the driver keeps the claim alive meanwhile as it
# does for the lane's Codex park (lane.sh, "NO HEARTBEAT HERE": every `process_manage wait` heartbeats).
#
# WHAT IT COSTS: Hermes runs ONE worker for the whole host, so a waiting review stops every lane. That is why the
# allowance is short (FORGE_JUDGE_QUOTA_MAX_WAIT, 1800 s) and why a stated reset that is later than what is left
# of it holds AT ONCE instead of sitting on the slot for nothing. The wait is counted in seconds slept, in this
# process; a hold ends the review and a later review starts with a full allowance.
#
# ONLY `is_error` with `api_error_status` 429 is a usage limit. A 401, a 5xx and an answer that is not JSON keep
# the failure path below exactly as it was. The retry loop wraps the pinned scorer lines and touches none of them.
# ---------------------------------------------------------------------------
QUOTA_WAITED=0        # seconds slept so far, for this review
QUOTA_TRIES=0
QUOTA_NEXT="$JUDGE_QUOTA_STEP"
QUOTA_RESET=""        # "resets 1:20pm (Europe/Copenhagen)" when the last answer named one

# The seconds until the reset the answer names, or return 1. "resets 1:20pm (Europe/Copenhagen)": the time of day
# in a named zone, the next time it comes. Anything else (a weekday, a date, a zone this host has no file for)
# is not guessed at: the caller backs off instead. Neither BSD nor GNU `date` is asked to parse anything; the
# zone is only read from (`TZ=<zone> date +%H:%M:%S`), and a zone with no file is refused first because both of
# them answer UTC for it without a word.
judge_quota_reset_in() {   # $1=the answer's text; sets QUOTA_SECS and QUOTA_RESET (no subshell: they must survive)
  local re='resets ([0-9]{1,2})(:([0-9]{2}))?(am|pm) \(([A-Za-z0-9_/+-]+)\)' h m ap tz tod now target
  local tod_re='^([0-9]{2}):([0-9]{2}):([0-9]{2})$'
  QUOTA_SECS=""; QUOTA_RESET=""
  [[ $1 =~ $re ]] || return 1
  h=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[3]:-0})); ap="${BASH_REMATCH[4]}"; tz="${BASH_REMATCH[5]}"
  [ "$h" -ge 1 ] && [ "$h" -le 12 ] && [ "$m" -le 59 ] || return 1
  case "$tz" in UTC) ;; *) [ -f "${TZDIR:-/usr/share/zoneinfo}/$tz" ] || return 1;; esac
  tod="${FORGE_JUDGE_QUOTA_NOW:-$(TZ="$tz" date +%H:%M:%S)}"
  [[ $tod =~ $tod_re ]] || return 1
  now=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
  target=$(( (h % 12 + $([ "$ap" = pm ] && echo 12 || echo 0)) * 3600 + m * 60 ))
  QUOTA_SECS=$(( (target - now + 86400) % 86400 ))
  [ "$QUOTA_SECS" -le 86280 ] || QUOTA_SECS=0   # a reset passed seconds ago is now, not tomorrow
  QUOTA_RESET="resets $h:$(printf '%02d' "$m")$ap ($tz)"
}

# "90" -> "1 min", "7200" -> "2 h", "20" -> "20 s": a duration a person reads at a glance.
judge_quota_span() {
  awk -v s="$1" 'BEGIN { if (s + 0 > 0 && s + 0 < 0.5) { printf "under 1 s"; exit }
    s = int(s + 0.5)
    if (s < 60) printf "%d s", s
    else if (s < 7200) printf "%d min", int(s / 60 + 0.5)
    else printf "%d h", int(s / 3600 + 0.5) }'
}

# The hold, when the allowance is spent or the reset is past it. A review that waited says for how long; one that
# did not says what the limit said. The block's kind comes from the card's own events (hold_call), never `substrate`:
# a block with no kind counts as a re-block of any earlier block with none, and the kernel's second one is `triage`.
judge_quota_hold() {   # $1=why this is a hold
  local reason
  if [ "${JUDGE_CLAUDE_DIAGNOSTIC_PRINTED:-0}" != 1 ]; then
    printf 'judge: claude failed: %s\n' "$(printf '%s' "$1" | sed -n '1p' | cut -c1-240)" >&2
    JUDGE_CLAUDE_DIAGNOSTIC_PRINTED=1
  fi
  reason="$(judge_usage_limit_reason "$1" "$BOARD" "$CHUNK")"
  if [ "${JUDGE_ATTEMPT_COUNT:-0}" -gt 0 ] && [ -n "${JUDGE_ATTEMPT_SUMMARY:-}" ]; then
    reason="$reason; tried: $JUDGE_ATTEMPT_SUMMARY"
  fi
  envelope substrate-block "" null "$reason" 3 "$(hold_call "$reason")" null
}

# A record for the readers (forge status, the digest, run-watch): this card is `running` and asleep until <epoch>.
judge_wait_record() {   # $1=epoch of the next try
  local dir; dir="$(forge_judge_wait_root)"
  mkdir -p "$dir" 2>/dev/null || return 0
  JUDGE_WAIT_FILE="$dir/$CHUNK.json"
  jq -nc --arg t "$CHUNK" --arg b "$BOARD" --argjson at "$1" --arg r "$QUOTA_RESET" --argjson w "$QUOTA_WAITED" \
     --argjson max "$JUDGE_QUOTA_MAX_WAIT" \
     '{schema: "forge.judge-wait.v1", task_id: $t, board: $b, wake_at: $at, waited: $w, max_wait: $max, resets: $r}' \
     > "$JUDGE_WAIT_FILE.tmp" 2>/dev/null && mv -f "$JUDGE_WAIT_FILE.tmp" "$JUDGE_WAIT_FILE" 2>/dev/null
  return 0
}
judge_wait_clear() { [ -z "$JUDGE_WAIT_FILE" ] || rm -f "$JUDGE_WAIT_FILE" "$JUDGE_WAIT_FILE.tmp"; JUDGE_WAIT_FILE=""; }

# After a judge call that gave no verdict: 0 = it was a usage limit and this process waited, call the judge again;
# 1 = it was not one, carry on to the failure path as before. A usage limit with nothing left to wait for does not
# return: it ends the review in a hold.
judge_quota_pause() {   # reads $raw
  local result remaining want base far_re='resets ([A-Za-z][A-Za-z0-9 :,]{2,40}( \([A-Za-z0-9_/+-]+\))?)'
  [ "${JUDGE_CLAUDE_LAST:-1}" = 1 ] || return 1
  [ "$(printf '%s' "${raw:-}" | jq -r 'if .is_error == true and .api_error_status == 429 then "429" else "" end' 2>/dev/null)" = 429 ] \
    || return 1
  result="$(printf '%s' "$raw" | jq -r '.result | if type == "string" then . else "" end' 2>/dev/null | head -c 400)"
  QUOTA_TRIES=$((QUOTA_TRIES + 1))
  remaining="$(awk -v m="$JUDGE_QUOTA_MAX_WAIT" -v w="$QUOTA_WAITED" 'BEGIN { r = m - w; printf "%.3f", (r < 0 ? 0 : r) }')"
  judge_quota_reset_in "$result" || :
  base="the judge did not run"
  if awk -v w="$QUOTA_WAITED" 'BEGIN { exit !(w > 0) }'; then base="the judge could not run for $(judge_quota_span "$QUOTA_WAITED")"; fi
  # a reset named by date or weekday (a weekly limit: "resets Nov 18 at 6pm (Europe/Copenhagen)") is hours or days
  # away: it is not waited for on the host's one worker slot. It holds at once and quotes what the limit said.
  if [ -z "$QUOTA_SECS" ] && [[ $result =~ $far_re ]]; then
    judge_quota_hold "$base; the limit lifts ${BASH_REMATCH[1]% }, a date this review does not wait for"
  fi
  # nothing left to wait with (or fifty refusals in a row, which only a stated reset of "now" could make)
  if [ "$QUOTA_TRIES" -gt 50 ] || awk -v r="$remaining" 'BEGIN { exit !(r <= 0) }'; then
    judge_quota_hold "$base${QUOTA_RESET:+; the limit lifts at ${QUOTA_RESET#resets }}"
  fi
  if [ -n "$QUOTA_SECS" ]; then
    want="$(awk -v r="$QUOTA_SECS" -v g="$JUDGE_QUOTA_MARGIN" 'BEGIN { printf "%.3f", r + g }')"
    if awk -v w="$want" -v r="$remaining" 'BEGIN { exit !(w > r) }'; then
      judge_quota_hold "$base; the limit lifts at ${QUOTA_RESET#resets }, later than the $(judge_quota_span "$JUDGE_QUOTA_MAX_WAIT") this review may wait"
    fi
  else
    want="$(awk -v s="$QUOTA_NEXT" -v r="$remaining" 'BEGIN { printf "%.3f", (s > r ? r : s) }')"
    QUOTA_NEXT="$(awk -v s="$QUOTA_NEXT" -v c="$JUDGE_QUOTA_CAP" 'BEGIN { s = s * 2; printf "%.3f", (s > c ? c : s) }')"
  fi
  judge_wait_record "$(( $(date +%s) + $(awk -v w="$want" 'BEGIN { printf "%d", w + 0.999 }') ))"
  echo "review: the judge call was refused for the account's usage limit (HTTP 429); waiting $(judge_quota_span "$want") of at most $(judge_quota_span "$JUDGE_QUOTA_MAX_WAIT") in all${QUOTA_RESET:+ ($QUOTA_RESET)}" >&2
  sleep "$want"
  QUOTA_WAITED="$(awk -v a="$QUOTA_WAITED" -v b="$want" 'BEGIN { printf "%.3f", a + b }')"
  return 0
}

# ---------------------------------------------------------------------------
# Stages 3 and 4 — score, and stamp the provenance the model cannot know about
# itself. THIS IS THE CONTROL ARM (ADR-0009 D9.5, ADR-0010): byte-identical to
# `main`'s SOUL, pinned by `make verify`.
#
# Why every line of the stamping `jq` is mandatory — preserved from the SOUL so
# the next editor cannot delete it cheaply, and free here, because a comment in
# a script is never billed to a context the way a line of prose in a system
# prompt is billed on every single run:
#
#   FAIL CLOSED. `is_error`, `api_error_status` and a missing
#   `structured_output` are how the CLI reports that it did not produce a
#   verdict. Unchecked, an error envelope becomes a verdict object with no
#   scores in it — which then gets stored, and counted.
#
#   STAMP WHAT THE MODEL CANNOT KNOW ABOUT ITSELF. On 2026-07-28 real verdicts
#   came back claiming `claude-opus-4-8` and `claude-opus-4`, neither of which
#   was the observed `--model` argument. The identical argument applies to
#   every number beside it: `tokens_estimate` was self-reported by the model
#   whose consumption it purported to measure, from introspection it does not
#   have. `cost` keeps the `usage` breakdown whole — ESPECIALLY
#   `cache_read_input_tokens`, without which no claim about cache efficiency
#   can ever be checked — plus `total_cost_usd`, an actual price rather than a
#   token guess. Only `iterations` is dropped: an unbounded per-turn array
#   whose totals are already the scalars beside it. `session_id` makes the
#   review resumable — `claude -p --resume` replays this context from cache
#   (measured 2026-07-30: 19,480 cache-created tokens, all 19,480 read back on
#   the resumed pass), so a verdict without it forces the next re-review to buy
#   the diff again.
#
# The model-facing schema is the supported subset minus every field stamped
# below. Never ask a model for a value you are about to overwrite — an
# asked-for field is a field it will invent. `--json-schema` takes the JSON
# itself, not a path, and its subset rejects a top-level `$schema`.
# ---------------------------------------------------------------------------
pr_url="$PR_URL"

# The pinned Claude arm computes its own copy of the model-facing schema in-place for the control-arm comparison.
# This copy is for Codex's path-valued --output-schema flag and is deliberately outside that region. It holds ONLY
# the fields the model must author: OpenAI's structured output refuses a schema whose `required` does not list every
# key in `properties` (seen live 2026-11-16: "Invalid schema … 'schema.required' is required to include every key in
# properties. Missing 'judge_engine'", and the first live review fell back to Claude). Every property that is not
# required is stamped by this script after the call, so the model is not asked for it.
JUDGE_SCHEMA_FILE="$TMP/judge-verdict.schema.json"
jq -c --argjson stamped '["pr","judge_model","tokens_estimate","cost","session_id"]' '
    del(."$schema")
  | .required |= map(select(. | IN($stamped[]) | not))
  | .required as $asked
  | .properties |= with_entries(select(.key | IN($asked[])))
' ~/.forge/rubrics/judge-verdict.schema.json > "$JUDGE_SCHEMA_FILE" 2>/dev/null ||
  substrate "env: judge-envelope — could not compute the model-facing verdict schema"

JUDGE_ATTEMPT_COUNT=0
JUDGE_ATTEMPT_SUMMARY=""
JUDGE_ENGINE=""
CODEX_USAGE_LIMIT=0
JUDGE_LAST_ENGINE=""
JUDGE_LAST_FAILURE_REASON=""
judge_record_failure() { # engine, reason -> one bounded diagnostic line
  local engine="$1" why="$2" one
  one="$(printf '%s' "$why" | sed -n '1p' | tr '\n' ' ' | cut -c1-240)"
  [ -n "$one" ] || one="no reason was reported"
  printf 'judge: %s failed: %s\n' "$engine" "$one" >&2
  if [ -n "$JUDGE_ATTEMPT_SUMMARY" ]; then JUDGE_ATTEMPT_SUMMARY="$JUDGE_ATTEMPT_SUMMARY; "; fi
  JUDGE_ATTEMPT_SUMMARY="${JUDGE_ATTEMPT_SUMMARY}${engine}: $one"
  JUDGE_ATTEMPT_COUNT=$((JUDGE_ATTEMPT_COUNT + 1))
  JUDGE_LAST_ENGINE="$engine"
  JUDGE_LAST_FAILURE_REASON="$one"
}

# A Codex process can leave children behind on macOS, where timeout(1) and
# setsid are not available. This is the small process-tree watcher used by
# scripts/codex-run.sh, with the root included because this one-shot call has
# no resumable supervisor to reap it.
judge_codex_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    printf '%s\n' "$child"
    judge_codex_tree "$child"
  done
}
judge_codex_end_tree() {
  local root="$1" pids p alive late steps=0
  pids="$root $(judge_codex_tree "$root")"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || :
  while [ "$steps" -lt 25 ]; do
    alive=""
    for p in $pids; do kill -0 "$p" 2>/dev/null && alive=yes; done
    [ -z "$alive" ] && return 0
    sleep 0.2
    steps=$((steps + 1))
  done
  late=""
  for p in $pids; do kill -0 "$p" 2>/dev/null && late="$late $p"; done
  pids="$late $(judge_codex_tree "$root")"
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null || :
}

# Only called AFTER an unsuccessful call or an unusable final message. Agent
# messages can legitimately review a rate limiter; they are never provider errors.
judge_codex_failure() { # fallback reason, stderr file, event stream
  local fallback="$1" err="$2" events="$3" last errors
  last="$(tr -d '\r' < "$err" | awk 'NF && $0 != "Reading prompt from stdin..." { last=$0 } END { print last }')"
  errors="$(jq -Rr 'fromjson? | select(type == "object")
    | select(.type == "error" or .type == "turn.failed")
    | (.message // (.error | if type == "object" then .message // . else . end) // .)
    | if type == "string" then . else tojson end' "$events" 2>/dev/null)"
  CODEX_REASON="$fallback"
  if grep -Eiq '429|usage[ -]?limit|rate[ -]?limit|quota|exhaust' "$err" 2>/dev/null \
     || printf '%s\n' "$errors" | grep -Ei '429|usage[ -]?limit|rate[ -]?limit|quota|exhaust' >/dev/null; then
    CODEX_USAGE_LIMIT=1
    CODEX_REASON="provider refused this call for its usage limit"
  fi
  if [ -z "$last" ]; then
    last="$(printf '%s\n' "$errors" | tr -d '\r' | awk 'NF { last=$0 } END { print last }')"
  fi
  # Remove provider upsell links BEFORE bounding the message, keeping room for
  # the useful "try again at ..." reset time in an event-only refusal.
  last="$(printf '%s\n' "$last" | sed -E 's@\(?https?://[^[:space:])]+\)?@@g; s/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-240)"
  [ -z "$last" ] || CODEX_REASON="$last"
  return 0
}

judge_codex() {
  local bin="${FORGE_CODEX_BIN:-codex}" out="$TMP/codex-verdict.json" events="$TMP/codex-events.jsonl"
  local err="$TMP/codex.stderr" job watcher="" rc=0 usage_json
  local input_tokens cached_input_tokens cache_write_input_tokens output_tokens reasoning_output_tokens
  CODEX_VERDICT=""; CODEX_REASON=""; CODEX_USAGE_LIMIT=0
  if ! command -v "$bin" >/dev/null 2>&1; then
    CODEX_REASON="codex binary '$bin' is not on PATH"; return 1
  fi
  : > "$events"; : > "$err"; rm -f "$out"
  (
    "$bin" exec -m "$JUDGE_MODEL" \
      -c "model_reasoning_effort=\"$JUDGE_EFFORT\"" \
      -c 'approval_policy="never"' \
      --sandbox read-only --skip-git-repo-check --ephemeral \
      --output-schema "$JUDGE_SCHEMA_FILE" -o "$out" --json \
      < "$prompt_file" > "$events" 2> "$err"
    printf '%s\n' "$?" > "$TMP/codex.rc"
  ) &
  job=$!
  if [ "$JUDGE_TIMEOUT" -gt 0 ]; then
    (
      deadline=$((SECONDS + JUDGE_TIMEOUT + 1))
      while kill -0 "$job" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          : > "$TMP/codex.timeout"
          judge_codex_end_tree "$job"
          break
        fi
        sleep 1
      done
    ) >/dev/null 2>&1 &
    watcher=$!
  fi
  wait "$job" 2>/dev/null || rc=$?
  if [ -n "$watcher" ]; then
    [ -e "$TMP/codex.timeout" ] || kill "$watcher" 2>/dev/null || :
    wait "$watcher" 2>/dev/null || :
  fi
  [ -s "$TMP/codex.rc" ] && rc="$(head -1 "$TMP/codex.rc")"
  if [ -e "$TMP/codex.timeout" ]; then
    CODEX_REASON="timed out after ${JUDGE_TIMEOUT}s"; return 1
  fi
  case "$rc" in ''|*[!0-9]*) rc=1;; esac
  [ "$rc" -eq 0 ] || {
    judge_codex_failure "codex exited with status $rc" "$err" "$events"; return 1;
  }
  [ -s "$out" ] || {
    judge_codex_failure "codex produced no final message" "$err" "$events"; return 1;
  }
  jq -e 'type == "object"' "$out" >/dev/null 2>&1 || {
    judge_codex_failure "codex final message was not a JSON object" "$err" "$events"; return 1;
  }
  jq -e '
    . as $v
    | $v.schema == "forge.judge.v1" and ($v.chunk_id | type) == "string"
    and ($v.verdict | IN("approve","approve-with-nits","bounce"))
    and ($v.scores | type) == "object"
    and (($v.scores.spec_fidelity | type) == "number" and ($v.scores.spec_fidelity | floor) == $v.scores.spec_fidelity and $v.scores.spec_fidelity >= 0 and $v.scores.spec_fidelity <= 3)
    and (($v.scores.scenario_integrity | type) == "number" and ($v.scores.scenario_integrity | floor) == $v.scores.scenario_integrity and $v.scores.scenario_integrity >= 0 and $v.scores.scenario_integrity <= 3)
    and (($v.scores.architectural_conformance | type) == "number" and ($v.scores.architectural_conformance | floor) == $v.scores.architectural_conformance and $v.scores.architectural_conformance >= 0 and $v.scores.architectural_conformance <= 3)
    and (($v.scores.scope_discipline | type) == "number" and ($v.scores.scope_discipline | floor) == $v.scores.scope_discipline and $v.scores.scope_discipline >= 0 and $v.scores.scope_discipline <= 3)
    and (($v.scores.debt_honesty | type) == "number" and ($v.scores.debt_honesty | floor) == $v.scores.debt_honesty and $v.scores.debt_honesty >= 0 and $v.scores.debt_honesty <= 3)
    and (($v.scores.doc_reconciliation | type) == "number" and ($v.scores.doc_reconciliation | floor) == $v.scores.doc_reconciliation and $v.scores.doc_reconciliation >= 0 and $v.scores.doc_reconciliation <= 3)
    and ($v.findings | type) == "array"
    and ($v.nits_as_cards | type) == "array"
    and ($v.spot_check_suggestion | type) == "string"
  ' "$out" >/dev/null 2>&1 || {
    judge_codex_failure "codex final message was missing a required verdict field" "$err" "$events"; return 1;
  }
  usage_json="$(jq -c 'select(.type == "turn.completed" and (.usage | type) == "object") | .usage' "$events" 2>/dev/null | tail -1)"
  jq -e '[.input_tokens,.cached_input_tokens,.cache_write_input_tokens,.output_tokens,.reasoning_output_tokens] | all(.[]; type == "number" and floor == .)' \
    <<< "${usage_json:-null}" >/dev/null 2>&1 || {
    judge_codex_failure "codex returned no complete turn.completed usage event" "$err" "$events"; return 1;
  }
  input_tokens="$(printf '%s' "$usage_json" | jq -r '.input_tokens')"
  cached_input_tokens="$(printf '%s' "$usage_json" | jq -r '.cached_input_tokens')"
  cache_write_input_tokens="$(printf '%s' "$usage_json" | jq -r '.cache_write_input_tokens')"
  output_tokens="$(printf '%s' "$usage_json" | jq -r '.output_tokens')"
  reasoning_output_tokens="$(printf '%s' "$usage_json" | jq -r '.reasoning_output_tokens')"
  CODEX_VERDICT="$(jq -c --arg pr "$pr_url" --arg model "$JUDGE_MODEL" \
    --argjson input "$input_tokens" --argjson cached "$cached_input_tokens" \
    --argjson created "$cache_write_input_tokens" --argjson output "$output_tokens" \
    --argjson reasoning "$reasoning_output_tokens" '
      .pr = $pr
      | .judge_model = $model
      | .tokens_estimate = ($input + $created + $output)
      | .cost = {input_tokens: $input, output_tokens: $output,
                 cache_read_input_tokens: $cached,
                 cache_creation_input_tokens: $created,
                 reasoning_output_tokens: $reasoning,
                 total_cost_usd: null, cost_basis: "subscription"}
      | del(.session_id)
      | .judge_engine = "codex"
    ' "$out")" || {
      CODEX_REASON="could not stamp the Codex verdict"; CODEX_VERDICT=""; return 1;
    }
  return 0
}

judge_claude() {
  JUDGE_CLAUDE_REASON=""
  JUDGE_CLAUDE_LAST=1
  [ "$JUDGE_ORDER" = "claude codex" ] && JUDGE_CLAUDE_LAST=0
  verdict=""
  raw=""
  # The loop (not its body) is this slice's: a judge call refused for the account's usage limit is made again after a
  # wait (judge_quota_pause, above). Every line between the two markers is the control arm, unmoved.
  while :; do
# --- PINNED REGION (control arm) — do not reindent, do not edit. ------------
   STAMPED='["pr","judge_model","tokens_estimate","cost","session_id"]'
   VERDICT_SCHEMA="$(jq -c --argjson stamped "$STAMPED" '
       del(."$schema")
     | .properties |= with_entries(select(.key | IN($stamped[]) | not))
     | .required |= map(select(. | IN($stamped[]) | not))
   ' ~/.forge/rubrics/judge-verdict.schema.json)"
   raw="$(claude -p --model opus --output-format json \
            --json-schema "$VERDICT_SCHEMA" < "$prompt_file")"

   verdict="$(printf '%s' "$raw" | jq -ce --arg pr "$pr_url" '
       if .is_error == true
          or .api_error_status != null
          or (.structured_output | type) != "object"
       then "judge-envelope" | halt_error(9) else . end
     | . as $env
     | $env.usage as $u
     | $env.structured_output
     | .pr = $pr
     | .judge_model = "opus"
     | .tokens_estimate = ($u.input_tokens + $u.cache_creation_input_tokens
                           + $u.output_tokens)
     | .cost = ($u | del(.iterations)) + {total_cost_usd: $env.total_cost_usd}
     | .session_id = $env.session_id
   ')"
# --- end pinned region ------------------------------------------------------
    [ -z "${verdict:-}" ] && judge_quota_pause && continue
    break
  done
  judge_wait_clear
  if [ -n "${verdict:-}" ]; then
    verdict="$(printf '%s' "$verdict" | jq -c '.judge_engine = "claude"')"
    JUDGE_ENGINE=claude
    return 0
  fi
  if [ "$JUDGE_CLAUDE_LAST" != 1 ] \
     && [ "$(printf '%s' "$raw" | jq -r 'if .api_error_status == 429 then "429" else "" end' 2>/dev/null)" = 429 ]; then
    JUDGE_CLAUDE_REASON="claude usage limit (HTTP 429)"
    return 1
  fi
  JUDGE_CLAUDE_REASON="$(printf '%s' "$raw" | jq -r '
      if .is_error == true or .api_error_status != null
      then "env: judge-envelope — claude -p reported an API failure before returning a verdict (is_error=\(.is_error // false), api_error_status=\(.api_error_status // "n/a"))"
      else "other: judge-envelope — claude -p returned no structured verdict"
      end' 2>/dev/null)"
  JUDGE_CLAUDE_REASON="${JUDGE_CLAUDE_REASON:-other: judge-envelope — claude -p returned no structured verdict}"
  return 1
}

judge_hold_with_attempts() {
  local base="$1"
  if [ "$JUDGE_ATTEMPT_COUNT" -gt 1 ]; then
    printf '%s — tried: %s' "$base" "$JUDGE_ATTEMPT_SUMMARY"
  else
    printf '%s' "$base"
  fi
}

verdict=""
if [ "$JUDGE_ORDER" = codex ] || [ "$JUDGE_ORDER" = "codex claude" ]; then
  if judge_codex; then
    verdict="$CODEX_VERDICT"
    JUDGE_ENGINE=codex
  else
    judge_record_failure codex "$CODEX_REASON"
  fi
fi
if [ -z "${verdict:-}" ] && { [ "$JUDGE_ORDER" = claude ] || [ "$JUDGE_ORDER" = "claude codex" ] || [ "$JUDGE_ORDER" = "codex claude" ]; }; then
  if judge_claude; then :; else judge_record_failure claude "$JUDGE_CLAUDE_REASON"; fi
fi
if [ -z "${verdict:-}" ] && [ "$JUDGE_ORDER" = "claude codex" ]; then
  if judge_codex; then
    verdict="$CODEX_VERDICT"
    JUDGE_ENGINE=codex
  else
    judge_record_failure codex "$CODEX_REASON"
  fi
fi

[ -n "${verdict:-}" ] || {
  if [ "$JUDGE_LAST_ENGINE" = codex ] && [ "${CODEX_USAGE_LIMIT:-0}" = 1 ]; then
    reason="$(judge_hold_with_attempts "env: judge-envelope — codex usage limit: $JUDGE_LAST_FAILURE_REASON")"
    envelope substrate-block "" null "$reason" 3 "$(hold_call "$reason")" null
  fi
  if [ "${JUDGE_LAST_ENGINE:-}" = claude ]; then
    reason="$(judge_hold_with_attempts "${JUDGE_CLAUDE_REASON:-env: judge-envelope — claude did not return a verdict}")"
  else
    reason="$(judge_hold_with_attempts "env: judge-envelope — codex: ${JUDGE_LAST_FAILURE_REASON:-codex did not return a verdict}")"
  fi
  substrate "$reason"
}

# ---------------------------------------------------------------------------
# Stage 4a — make the envelope satisfy the schema it is stored against. Two
# one-way repairs, both OUTSIDE the pinned region above, because the stamping
# `jq` is S5's baseline and may be moved but not modified.
#
# Measured 2026-09-02, board forge-hello-20260902, task t_0868e3c1 run 2: the
# first `--hello` rehearsal to run end to end stored a verdict that
# `metadata-live` refused — `worker_session_id` unexpected, `nits_as_cards` and
# `tokens_estimate` missing. That is exit 1, "stop and repair the producer"
# (docs/staged-run-guide.md), fired at the ROOT checkpoint of the run, after the
# chunk had been implemented, reviewed and merged. The two halves the producer
# owns are repaired here; the third was the schema refusing a key the substrate
# writes, and is fixed in rubrics/judge-verdict.schema.json.
#
# `nits_as_cards //= []` FILLS AN ABSENCE; it is not the overwrite the pinned
# region forbids. Which nits deserve a follow-up card is a judgement only the
# scorer made, so it stays in the model-facing schema and stays required in the
# stored one — adding it to STAMPED would ask for a field and then discard the
# answer, which is how `claude-opus-4-8` got invented. An omitted array has
# exactly one honest reading, so filling it asserts nothing the scorer did not.
# Contrast `scores`, where a default would invent five numbers to say one thing:
# that is the retired ci-red sentinel, and it is not what this line does.
#
# `del(.worker_session_id)` is the other direction. The schema now declares that
# key so Hermes's own stamp survives validation, and declaring it also offers it
# to the scorer, which must never be its author: it is the id metrics.sh joins
# on to reach real per-model usage, and a plausible invented one is worse than a
# missing one. Deleting it here leaves the substrate the only writer.
#
# Repaired through a variable, not `mv` over the file. The temp-file-and-move
# pair truncates the verdict to zero bytes when the filter emits nothing, and
# Stage 5 then reports a completed, paid-for review as a substrate outage —
# already measured once, and the reason stamp_shadow_file exists.
repaired="$(printf '%s' "$verdict" \
            | jq -c '.nits_as_cards //= [] | del(.worker_session_id)')"
[ -n "$repaired" ] && verdict="$repaired"

printf '%s' "$verdict" > "$TMP/verdict.json"

# ---------------------------------------------------------------------------
# Stage 4b — the verdict, DERIVED. This is what routes.
#
# `rubrics/judge-rubric.md` has always stated the verdict logic as four rules
# over the scores, and nothing ever computed them — the model was asked for
# `verdict` beside the scores it also produced, and whatever word came back was
# stored, routed on and counted (audit F29). `scripts/verdict.sh` is those four
# rules as a program.
#
# PROMOTED FROM SHADOW TO BLOCKING. Routing reads `.derived_verdict`; the
# model's own word no longer decides anything. This is the third step of the
# instrument -> shadow -> block order the gate itself went through in S1, S3
# and S4, and it is taken on measurement: 34 recorded verdicts replayed through
# `derive_verdict` agreed 33 times, and the single divergence changed no
# routing (18 of the 34 were discriminating; 17 of those agreed).
#
# THE MODEL STILL ASSERTS `verdict`, DELIBERATELY. Leaving it in the
# model-facing schema costs a few tokens and keeps the instrument running: with
# routing derived, an asserted verdict decides nothing, so it is free to record
# — and every review from here is a POST-GATE divergence sample, which is the
# one thing the replay could not provide. Adding `verdict` to `STAMPED` would
# end that measurement permanently and must wait until D9.5 is answered and no
# further sample is wanted. It is the last step of the arc, not this one.
#
# WHAT THIS DOES NOT DECIDE. ADR-0009 D9.5 asks whether an Opus pass told to
# pass through earns its latency GIVEN a gate that catches the mechanical half.
# Nothing here answers that: the scorer still runs, still costs what it costs,
# and the pinned region above is untouched. This narrows what the scorer's
# output is trusted for — its scores and findings, not its conclusion.
#
# This block sits deliberately AFTER `end pinned region`. Everything above that
# marker is the control arm, byte-identical to
# `scripts/fixtures/control-arm.txt`; `prejudge/scorer-is-the-control-arm`
# fails the suite on any edit inside it, whitespace included, because S5's
# experiment is measured against exactly those bytes (F65 is what happens when
# that pin stops holding).
#
# A DERIVATION FAILURE IS NOT A REVIEW FAILURE. Malformed scores mean the
# shadow record is unavailable for this run; that must never cost a review the
# scorer actually completed. `stamp_shadow_file` ENFORCES that rather than
# merely intending it: the verdict is replaced only if the stamped result is
# non-empty, parses, and still carries the same `.verdict`; otherwise the file
# is left byte-for-byte as it was found.
#
# The two obvious lines — stamp into a temp file, `mv` it over — do the
# opposite. An empty stamp truncates the verdict to zero bytes, `.verdict`
# reads null, and Stage 5 below falls to its `*)` arm and calls `substrate`. A
# completed, paid-for review is then reported as an infrastructure outage
# because a SHADOW record could not be computed. That is measured rather than
# theoretical: it is exactly what the first version of this stage did, and the
# empty-output path returns 0, so its exit code could not have caught it.
#
# THE FALLBACK BELOW IS THAT SAME RULE, AND PROMOTION IS EXACTLY WHAT PUTS IT
# AT RISK AGAIN. `.derived_verdict` is null on two separate paths — the stamp
# could not be applied at all, or it applied and derivation itself failed
# (malformed scores, or a dimension marked down naming no finding). A bare
# `jq -r '.derived_verdict'` yields the string "null" on both, Stage 5 falls to
# its `*)` arm, and a completed review is reported as an outage. That is the
# PR #14 bug rebuilt one line further down, so `// .verdict` is load-bearing,
# not defensive: when the program cannot decide, the model's word still routes
# and the run still lands. Derivation may narrow what we trust; it may never
# cost a review that was actually performed.
# ---------------------------------------------------------------------------
# shellcheck source=scripts/verdict.sh
. "$HERE/verdict.sh"
if [ -n "${JUDGE_ENGINE:-}" ]; then
  _engine_stamped="$(stamp_judge_engine "$(cat "$TMP/verdict.json")" "$JUDGE_ENGINE")" || _engine_stamped=""
  [ -n "$_engine_stamped" ] && printf '%s' "$_engine_stamped" > "$TMP/verdict.json"
fi
stamp_shadow_file "$TMP/verdict.json" \
  || echo "shadow: derivation unavailable this run; verdict left untouched" >&2

VERDICT="$(jq -r '.derived_verdict // .verdict' "$TMP/verdict.json")"
[ "$(jq -r '.derived_verdict // "null"' "$TMP/verdict.json")" = "null" ] \
  && echo "verdict: derivation unavailable; routing on the model's own word — $VERDICT" >&2
SUMMARY="$(jq -r '
    (.derived_verdict // .verdict) as $routed
  | "\($routed) — \([.findings[]?] | length) finding(s)"
    + (if .verdict_divergence == true then " (derived; the scorer asserted \(.verdict))"
       elif .derived_verdict == null then " (the scorer asserted this; derivation was unavailable)"
       else "" end)' "$TMP/verdict.json")"

# ---------------------------------------------------------------------------
# Stage 4c — fold the gate's own result into the SAME terminal envelope.
#
# Storage is one blob per run (the SOUL terminates exactly once), and before
# this only the BLOCK path (`gate_rc = 1`, above) got a standalone
# `forge.gate.v1` row. A CLEAR gate's result — reached on every PR that gets
# this far — lived only as prose in the tier-2 card body (`tier-1 gate: clear
# — …` below), never as metadata anything can query. `scripts/metrics.sh`'s
# gate CTE (`WHERE json_extract(r.metadata,'$.schema') = 'forge.gate.v1'`) and
# its own fixture (`scripts/fixtures/metrics-board.sql`, one block row and one
# CLEAR row, both standalone) already expect a clear run to be countable — the
# real driver just never produced one. Measured on jobapp-second-instance,
# 2026-09-02..09-04: 4 real prejudge runs, at least 2 with a clear gate that
# reached a scorer verdict, 0 stored `forge.gate.v1` rows of either result —
# `make metrics` read "gate n/a — 0 gate runs in period" for a period that ran
# the gate 4 times.
#
# `$GATE` is already schema `forge.gate.v1` (prejudge.sh) and already fully
# computed; nest it unmodified rather than re-deriving a summary. This is
# additive — `gate_result` is a new optional key (named to avoid colliding
# with `forge.gate.v1`'s OWN `gate` field, the constant "forge-prejudge-gate"
# — `.gate` would have made every clear run's nested value that string, not
# the object), `judge-verdict.schema.json` is updated to declare it, and
# nothing that reads `.verdict`/`.scores`/`.findings` changes shape.
gated="$(jq -c --slurpfile gate "$GATE" '.gate_result = $gate[0]' "$TMP/verdict.json")"
[ -n "$gated" ] && printf '%s' "$gated" > "$TMP/verdict.json"

# ---------------------------------------------------------------------------
# Stage 5 — the card's own terminal transition. No card is created, and the
# verdict decides which of three transitions happens ON THIS CARD.
#
# The implementer line goes FIRST in every body: it is the one fact that decides
# whether the rest can be trusted, and run 55 approved a diff without it (F22).
# ---------------------------------------------------------------------------
EVIDENCE="$(printf '%s\ngate: clear — %s\nmerged tree: %s\n%s\nverdict: %s — scores %s\nspot-check: %s' \
  "$(implementer_model_line)${LANE_COPY_NOTE:+
$LANE_COPY_NOTE}" \
  "$(jq -r '[.checks[]|select(.status=="warn")|.id]
     | if length==0 then "no warnings" else "warnings: "+join(", ") end' "$GATE")" \
  "$(jq -r '.evidence // "not run"' "$MERGED" 2>/dev/null | head -c 300)" \
  "$PROBE_LINE" \
  "$SUMMARY" \
  "$(jq -r '.scores | "\(.spec_fidelity)/\(.scenario_integrity)/\(.architectural_conformance)"
     + "/\(.scope_discipline)/\(.debt_honesty)/\(.doc_reconciliation)"' "$TMP/verdict.json")" \
  "$(jq -r '.spot_check_suggestion // "not offered"' "$TMP/verdict.json")")"

case "$VERDICT" in
  approve|approve-with-nits)
    # The merged-tree stage already refused to continue on anything but `pass`;
    # this re-reads it at the one place an approval is actually granted, because
    # a stage that returns early is one edit away from not returning early.
    [ "$(jq -r '.result // "unreadable"' "$MERGED" 2>/dev/null)" = pass ] \
      || substrate "env: merge-check-unrunnable — no passing merged-tree result, so nothing here may approve"
    # Under the switch the probe is half of what an approval rests on, so it is
    # re-read here for the same reason; reporting, it is evidence on the hold.
    ! probe_bounces || [ "$(jq -r '.result // "unreadable"' "$PROBE" 2>/dev/null)" = pass ] \
      || substrate "env: mutation-probe-unrunnable — no passing mutation-probe result, so nothing here may approve"
    # STASHED BEFORE ANY MERGE, not after it. In merge mode the completion is what
    # carries the verdict; if the merge lands and the completion does not, the
    # merge-watcher finishes the card and this file is the only copy of the
    # verdict it can attach.
    stash_envelope "$TMP/verdict.json"
    if merge_mode; then
      route_merge; merge_rc=$?
      # P9, a head that moved after the verdict: NOT a substrate fault. `other: handoff-integrity`
      # is not swept by the merge-watcher, so an operator's hand merge would leave the card
      # stuck and its children stranded, with nothing to flag that the merge was unverified.
      # The card is held `merge-pending:` instead (the verdict is stashed above), naming both
      # heads; the watcher completes it on a merge and flags the drift. Review is not re-opened.
      if [ "$merge_rc" = 5 ]; then
        envelope merge-refused-head-drift "$SUMMARY — NOT merged: $MERGE_REFUSAL" "$TMP/verdict.json" "" 4 \
          "$(hold_call "$(decision_message merge-pending \
            "${chunk_title:-this chunk} was verified, and NOT merged: its head moved after the verdict" \
            "$MERGE_REFUSAL. The verdict does not cover the new head, so merge mode refused to merge it. Review is not re-opened" \
            "review the new head and merge it, or send the chunk back" \
            "a merge of the new head lands code the verifier did not review; the merge-watcher completes this card on a merge and flags the head drift" \
            "merge $PR_URL on GitHub if you accept the new head — or \`~/.forge/repo/scripts/bounce.sh $CHUNK \"<reason>\" --board $BOARD\`

$EVIDENCE")")" \
          "$(term_block "merge-pending: $PR_URL head moved after the verdict — nothing was merged; the merge-watcher completes this card on a merge and flags the head drift")"
      fi
      [ "$merge_rc" = 1 ] \
        && substrate "other: handoff-integrity — the squash merge did not take, so nothing was merged"
      # MERGED, BUT THE CARD IS A SEPARATE QUESTION. `gh pr merge` accepted it, so the
      # work is probably on $base_ref already. If the completion then fails — or
      # GitHub would not confirm the merge — the card must be HELD `merge-pending:`,
      # which the merge-watcher DOES watch: it asks GitHub, and completes the card
      # (with the verdict stashed above) once the PR reads MERGED. Exiting 3 here
      # used to make the model block this card `other: handoff-integrity`, which the
      # watcher does not watch — the PR was on the base branch and the card and its
      # children were held forever. So the hold is the `on_error` of the completion,
      # and the terminator itself when the merge was not confirmed.
      merged_hold="$(decision_message merge-pending \
        "${chunk_title:-this chunk}: merge attempted by the verifier; GitHub did not confirm either way, or this card could not be completed" \
        "The verifier ran \`gh pr merge\` for $PR_URL at ${VERIFIED_HEAD:-an unread head}. GitHub did not confirm the outcome either way (the merge may have failed or the read-back was unreadable), or the completion of this card did not take. The merge-watcher completes this card once GitHub reports the PR merged${MERGE_AUTHORITY_CLAUSE:+. The merge was attempted under $MERGE_AUTHORITY_CLAUSE}" \
        "confirm $PR_URL is merged; if it is not, merge it or send it back" \
        "until the card completes, its children stay held" \
        "nothing, if the PR shows MERGED — the merge-watcher completes this card on its next sweep — or \`~/.forge/repo/scripts/bounce.sh $CHUNK \"<reason>\" --board $BOARD\`

$EVIDENCE")"
      if [ "$merge_rc" = 0 ]; then
        envelope merged "$SUMMARY" "$TMP/verdict.json" "" 4 \
          "$(call_json kanban_complete "$(task_args '{summary: $s, result: $s, metadata: $m[0]}' \
              --arg s "merged by forge-verifier: $SUMMARY${MERGE_AUTHORITY_CLAUSE:+ ($MERGE_AUTHORITY_CLAUSE)}" --slurpfile m "$TMP/verdict.json")")" \
          "$(hold_call "$merged_hold")"
      fi
      # If even the hold does not land, the reason the driver blocks with verbatim
      # still starts `merge-pending:` and names the PR, so the watcher finds it.
      envelope merged-held "$SUMMARY — merged, and held for the merge-watcher because GitHub did not confirm it" "$TMP/verdict.json" "" 4 \
        "$(hold_call "$merged_hold")" \
        "$(term_block "merge-pending: $PR_URL merge attempted by the verifier; GitHub did not confirm either way, and neither the completion nor the hold on this card took — the merge-watcher completes this card once GitHub reports the PR merged")"
    fi
    # A board that HAS merge authority and still holds this chunk says why (merge_mode set these); otherwise
    # this is the recommend-only text, unchanged.
    rec_headline="${chunk_title:-this chunk} is verified and NOT merged — ${MERGE_HOLD_HEADLINE:-the verifier may only recommend}"
    rec_tail="${MERGE_HOLD_MEANS:-Recommend-only is the default until the flip criterion is met (ADR-0019 D19.3)}"
    envelope recommend "$SUMMARY" "$TMP/verdict.json" "" 4 \
      "$(hold_call "$(decision_message merge-pending \
      "$rec_headline" \
      "the deterministic gate is clear, \`make check\` is green on this branch merged with $base_ref, $PROBE_CLAUSE, and the scorer reached $SUMMARY. $rec_tail" \
      "merge the PR, or send it back" \
      "nothing is merged and this card's children stay held until it is" \
      "merge $PR_URL on GitHub — the merge-watcher completes this card — or \`~/.forge/repo/scripts/bounce.sh $CHUNK \"<reason>\" --board $BOARD\`

$EVIDENCE")")" \
      "$(term_block "other: handoff-integrity — the recommend-only block did not land on this card")";;
  bounce)
    bounce_or_except "$(jq -r '.findings[]? |
        "- **\(.dimension)** (\(.severity)) — \(.evidence)\n  - action: \(.action)"' \
        "$TMP/verdict.json")" \
      "$(jq -r '[.findings[]? | .dimension] | unique | join(", ")' "$TMP/verdict.json")" \
      "$TMP/verdict.json";;
  *)
    substrate "other: judge-envelope — verdict was '$VERDICT', not one of the three";;
esac
