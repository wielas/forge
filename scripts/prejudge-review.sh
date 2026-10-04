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
#   FORGE_VERIFIER_MERGE=1          merge mode. Absent = recommend-only, which
#                                   is the default and fails closed.
#   FORGE_VERIFIER_BOUNCE_BUDGET    rounds before the exception          [2]
#   FORGE_MERGE_CHECK_BIN           stand in for scripts/merge-check.sh
#   FORGE_MUTATION_PROBE_BOUNCE=1   the mutation probe BOUNCES. Absent = it
#                                   reports on the hold and gates nothing.
#   FORGE_MUTATION_PROBE_BIN        stand in for scripts/mutation-probe.py
#   FORGE_MUTATION_BUDGET           seconds the mutation probe may spend [420]
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
[ -n "$PR_URL" ] || { usagetext; exit 2; }
[ "$CONTRACT_FROM_CARD" != 1 ] || [ "$DRY_RUN" != 1 ] || { echo "usage: --contract-from-card reads the card, and a --dry-run has none" >&2; exit 2; }
command -v jq >/dev/null || {
  # no jq, so nothing is escaped: the literal names no task (the kernel applies a block to the
  # driver's own) and embeds nothing the caller typed
  printf '{"schema":"forge.review.v2","action":"substrate-block","reason":"env: jq missing","rc":3,"terminate":{"tool":"kanban_block","args":{"reason":"env: jq missing"}},"on_error":null,"created_cards":[]}\n'
  exit 3
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forge-review.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# The envelope is the whole of this script's output, and it is small on
# purpose. The driver is the only metered agent in the run, so every byte
# printed here is billed to it. A 127 KB diff passes through this process and
# never touches stdout.
# ---------------------------------------------------------------------------
envelope() {   # action, summary, metadata-file|'null', reason, exit-code, [terminate-json], [on_error-json]
  local action="$1" summary="$2" metafile="$3" reason="$4" code="$5" terminate="${6:-null}" on_error="${7:-null}" meta='null'
  [ "$metafile" != "null" ] && [ -s "$metafile" ] && meta="$(cat "$metafile")"
  jq -nc --arg action "$action" --arg summary "$summary" --arg reason "$reason" --argjson rc "$code" \
        --argjson metadata "$meta" --argjson terminate "$terminate" --argjson on_error "$on_error" \
        --argjson created "$(printf '%s\n' ${CREATED[@]+"${CREATED[@]}"} \
                             | jq -Rs 'split("\n") | map(select(length>0))')" '
    { schema: "forge.review.v2", action: $action, summary: $summary,
      reason: (if $reason == "" then null else $reason end),
      rc: $rc, metadata: $metadata, terminate: $terminate, on_error: $on_error, created_cards: $created }'
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
    #     replaces text which was not there is an edit, not a redaction.
    # A leaf changed to anything else, a key added or removed, a list shortened: red.
    handoff_matches() {  # $1=the stored run (json) $2=the lane's host copy (file) -> 0 if the same hand-off
      jq -en --argjson run "$1" --slurpfile host "$2" '
        def redacted(a; b): (a | type) == "string" and (b | type) == "string" and a != b
                            and ((a | capture("^(?<p>.*?)(?:[*][*][*]|[.][.][.])") // null) as $m
                                 | $m != null and (b | startswith($m.p)));
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
merge_mode() { [ "${FORGE_VERIFIER_MERGE:-}" = 1 ]; }
# Return 1: nothing was merged. Return 4: `gh pr merge` ACCEPTED the merge and
# GitHub did not confirm it afterwards: the work is probably on the base branch,
# and the card has to be held where the merge-watcher will finish it (see the
# caller). The completion is NOT made here (no board writes): the caller names
# `kanban_complete`, with the `merge-pending:` hold as its `on_error`.
route_merge() {
  # `--match-head-commit` is not belt-and-braces: without it this merges whatever
  # the head is NOW, and every stage above read the PR separately over several
  # minutes. A push in that window would put code on `main` that nothing in this
  # run verified — on an ungated repo, with no second gate behind it. An empty
  # VERIFIED_HEAD means the read failed, and a merge that cannot name what it
  # verified must not happen at all.
  [ -n "$VERIFIED_HEAD" ] || return 1
  gh pr merge --squash --delete-branch --match-head-commit "$VERIFIED_HEAD" "$PR_URL" \
    >/dev/null 2>&1 < /dev/null || return 1
  gh pr view "$PR_URL" --json state,mergedAt < /dev/null 2>/dev/null \
    | jq -e '.state == "MERGED" and (.mergedAt | type) == "string"' >/dev/null || return 4
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
# the difference between a failure and a defect. P9 owns the rest.
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
#
# The pinned jq above collapses three distinct failures into one empty
# `$verdict` and discards which one fired: `.is_error`, `.api_error_status`,
# and a non-object `.structured_output` are FAIL CLOSED together by design
# (the comment above the pinned region says so), but that means every one of
# them reached `kanban_block` as the same `other: judge-envelope — claude -p
# returned no structured verdict` string — an API-level failure (quota, auth,
# a rate limit) filed identically to the model returning malformed output.
# `reason_class`'s own vocabulary (rubrics/run-metadata-contract.json) already
# has `env:` for a substrate fact distinct from a work judgement; this was
# never routed there because nothing after the pinned block re-read `$raw` to
# find out which arm fired. `$raw` is untouched by the pinned region — reading
# it again here does not move the control arm's pinned bytes, only what a
# caller does after they already decided nothing usable came back.
[ -n "${verdict:-}" ] || {
  reason="$(printf '%s' "$raw" | jq -r '
      if .is_error == true or .api_error_status != null
      then "env: judge-envelope — claude -p reported an API failure before returning a verdict (is_error=\(.is_error // false), api_error_status=\(.api_error_status // "n/a"))"
      else "other: judge-envelope — claude -p returned no structured verdict"
      end' 2>/dev/null)"
  substrate "${reason:-other: judge-envelope — claude -p returned no structured verdict}"
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
        "${chunk_title:-this chunk} was squash-merged by the verifier, but this card could not be completed" \
        "\`gh pr merge\` accepted $PR_URL at ${VERIFIED_HEAD:-an unread head}, and then the read-back from GitHub or the completion of this card did not take. The merge-watcher completes this card once GitHub reports the PR merged" \
        "confirm $PR_URL is merged; if it is not, merge it or send it back" \
        "until the card completes, its children stay held" \
        "nothing, if the PR shows MERGED — the merge-watcher completes this card on its next sweep — or \`~/.forge/repo/scripts/bounce.sh $CHUNK \"<reason>\" --board $BOARD\`

$EVIDENCE")"
      if [ "$merge_rc" = 0 ]; then
        envelope merged "$SUMMARY" "$TMP/verdict.json" "" 4 \
          "$(call_json kanban_complete "$(task_args '{summary: $s, result: $s, metadata: $m[0]}' \
              --arg s "merged by forge-verifier: $SUMMARY" --slurpfile m "$TMP/verdict.json")")" \
          "$(hold_call "$merged_hold")"
      fi
      # If even the hold does not land, the reason the driver blocks with verbatim
      # still starts `merge-pending:` and names the PR, so the watcher finds it.
      envelope merged-held "$SUMMARY — merged, and held for the merge-watcher because GitHub did not confirm it" "$TMP/verdict.json" "" 4 \
        "$(hold_call "$merged_hold")" \
        "$(term_block "merge-pending: $PR_URL was squash-merged by the verifier, but neither the completion nor the hold on this card took — the merge-watcher completes this card once GitHub reports the PR merged")"
    fi
    envelope recommend "$SUMMARY" "$TMP/verdict.json" "" 4 \
      "$(hold_call "$(decision_message merge-pending \
      "${chunk_title:-this chunk} is verified and NOT merged — the verifier may only recommend" \
      "the deterministic gate is clear, \`make check\` is green on this branch merged with $base_ref, $PROBE_CLAUSE, and the scorer reached $SUMMARY. Recommend-only is the default until the flip criterion is met (ADR-0019 D19.3)" \
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
