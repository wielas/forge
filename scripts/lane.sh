#!/usr/bin/env bash
# =============================================================================
# forge lane — implement ONE chunk card by driving Codex, as a program
# (epic FL2, ADR-0010).
#
# ADR-0010 moved tier 1's protocol out of a SOUL and into
# `scripts/prejudge-review.sh`. The lane was left behind: `skills/forge-lane`
# was 300 lines of prose that a cheap driver model re-enacted on every chunk —
# read the card, check the parents, build the environment, write the contract,
# run Codex, verify, push, open the PR, fill the metadata, create a card and
# terminate. Measured on the two product runs (docs/epic-hands-free.md): the
# lane driver made 1,166 tool calls over 28 sessions, and its free-form board
# calls produced the CHUNK-8 card storm. None of those steps needs a model.
# This file does all of them and hands back one small JSON envelope, exactly
# as prejudge-review.sh does.
#
# WHAT STAYS WITH THE MODEL, AND WHY IT IS SO LITTLE
# The driver runs this file in the background, waits, reads the envelope and
# makes the ONE tool call the envelope names. Its model sees ~2 KB of JSON,
# never a diff, a transcript or a build log.
#
# THIS FILE NEVER WRITES THE BOARD (epic S6d, P24). Hermes fences a worker's
# terminal: every `hermes kanban` mutation from a shell the worker started is
# refused, "even if a script removes the task id" (kanban-worker-lanes.md,
# *Descendant process scope*), and HERMES_KANBAN_TASK, _RUN_ID and _CLAIM_LOCK
# are scrubbed from it. Run A's first attempt (2026-10-03) did the work and then
# could not hand it off: the driver improvised `export HERMES_KANBAN_TASK=...`,
# the heartbeats all failed, and `request-review` was refused. The fence is a
# boundary Hermes documents as cooperative, and it is not ours to defeat. So
# this program decides and validates, and the driver — the one party the kernel
# lets terminate a run — performs the transition the envelope names, verbatim.
# What the terminal DOES keep (the board, DB, workspace, branch and profile
# variables) is what this reads; the task id is the one explicit argument.
#
# THE ORDER IS THE PROTOCOL. Each step below exists because its absence was
# measured, and the reason is kept beside the step rather than in a prompt a
# model pays to read on every run:
#
#   1 read the card        body + operator comments; an operator comment
#                          overrides the body
#   2 parent guard         ADR-0008's rule, kept as a guard that should never
#                          fire (ADR-0019 D19.5: retired only when a run shows
#                          the native gate holding)
#   3 integrate the base   a fresh branch is fast-forwarded to origin/<base>
#   4 lane-setup.sh        network, .venv, green baseline, immutable capture
#   5 contract             body + comments + the role boundary, ALWAYS
#   6 codex-run.sh         the pinned model, the sandbox, quota parking; the
#                          driver's own bridge keeps the claim alive meanwhile
#   7 make check           plain — no UV_OFFLINE, no UV_CACHE_DIR
#   8 blast-radius check   the final fail-closed audit, one per run key
#   9 push, PR             reuse an open PR; never main
#  10 metadata             forge.chunk.v1, computed, then validated
#  11 hand off             the envelope names kanban_request_review, with the
#                          reviewer always explicit; the CARD is moved by the
#                          driver's call, not by this file
#
# A BOUNCE COMES BACK TO THIS CARD (epic FL3, ADR-0019 D19.1). When the
# reviewer requests changes, or the operator reopens the review, the card
# returns to `ready` with this profile restored, and the dispatcher spawns this
# file again in the SAME worktree, on the SAME branch, with the SAME PR. It
# notices (the card carries a review_requested event), collects the reasons
# recorded since that handoff, and resumes the implementer's OWN Codex session
# with them — the comprehension paid for on the first pass is reused, not
# re-read. There is no fix card, no judge card, and so no parent check that a
# fix card could fail (the `failing-prereq` blocks of the product runs).
#
# Usage: lane.sh --task <task-id>
#   <task-id> is your own task's id — `kanban_show().task.id`, the id in your
#   prompt. The fenced terminal has no HERMES_KANBAN_TASK, and none is read.
#   Everything else comes from what the terminal keeps: HERMES_KANBAN_BOARD,
#   HERMES_KANBAN_WORKSPACE, HERMES_PROFILE, and HERMES_KANBAN_BRANCH (checked by
#   lane-setup.sh). The run id is READ from the card: its one `running` run.
#   The card must be this profile's, `running`, in this workspace.
#
# Knobs (all optional):
#   FORGE_LANE_BASE        the protected branch PRs target            [main]
#   FORGE_LANE_TICK        seconds between checks of the Codex run      [5]
#   FORGE_LANE_REVIEWER    the profile the card is handed to  [forge-verifier]
#   FORGE_LANE_SESSION_ROOT  where each card's Codex session id and validated
#                          envelope are kept   [<state root>/lane-sessions]
#                          (scripts/forge-state.sh owns the root)
#
# stdout is ONE `forge.lane.v2` envelope, as ONE COMPACT LINE — the last thing
# printed: `action`, `summary`, `reason`, `rc` (this program's exit code),
# `terminate` and `on_error` (each `{tool, args}`), `created_cards`. The driver
# reads it with `process_manage(action="log")`, never from `wait`: a wait's output
# is cut to the last 2000 characters (tools/process_registry.py
# COMPLETION_OUTPUT_CHARS), and the call sits near the START of the envelope.
#
# Exit: 4 hand off — `.action` is `handoff`. Call `.terminate.tool` with
#         `.terminate.args`, verbatim (`kanban_request_review`); if it returns
#         an error, call `.on_error.tool` with `.on_error.args` and stop.
#       3 a block — nothing was handed off. `.terminate` is `kanban_block` with
#         a canonical `<class>: <reason>` (rubrics/run-metadata-contract.json);
#         call it verbatim.
#       2 a usage error — the argument or the runtime was wrong; `kanban_block`
#         with `other: lane-usage — <the stderr>`.
#       0 only for --help. A real run NEVER exits 0: a driver whose notes still
#         say "0 = nothing to call" must fail loudly, not silently.
# 1 is deliberately unused (ADR-0010 D10.3): a caller under `set -e` must not
# read a block as a crash.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Codex's own workaround for a missing venv was UV_CACHE_DIR + UV_OFFLINE, and
# a green under either is not the green CI runs (measured 2026-07-28). Stripped
# for the WHOLE run, not just the final check: the baseline in lane-setup.sh
# and the uv-run validator are both judged by the same rule. codex-run.sh sets
# its own UV_CACHE_DIR for Codex, inside the sandbox, and nowhere else.
unset UV_OFFLINE UV_CACHE_DIR
# shellcheck source=forge-state.sh
. "$HERE/forge-state.sh" || { echo "usage: forge-state.sh is missing beside lane.sh" >&2; exit 2; }
# NO HERMES_KANBAN_TASK / _RUN_ID / _CLAIM_LOCK ANYWHERE BELOW. The fenced
# terminal does not carry them (agent/delegation_context.py KANBAN_ENV_KEYS), a
# fallback to them would hide the defect on any host where they leak, and
# `lane/programs-read-no-scrubbed-variable` runs this file with WRONG values
# planted in exactly those names.
TASK=""
WS="${HERMES_KANBAN_WORKSPACE:-}"
RUN_ID=""
BOARD="${HERMES_KANBAN_BOARD:-}"
PROFILE="${HERMES_PROFILE:-}"
BASE="${FORGE_LANE_BASE:-main}"
REVIEWER="${FORGE_LANE_REVIEWER:-forge-verifier}"
SESSION_ROOT="$(forge_lane_session_root)"
TICK="${FORGE_LANE_TICK:-5}"
STARTED="$(date +%s)"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; exit 0;;
    --task) TASK="${2:-}"; [ $# -ge 2 ] || { echo "usage: --task needs a task id" >&2; exit 2; }; shift 2;;
    *) echo "usage: lane.sh --task <task-id>   (unknown argument '$1')" >&2; exit 2;;
  esac
done
[ -n "$TASK" ] || { echo "usage: lane.sh --task <task-id> — your task's id, from kanban_show().task.id; the fenced terminal has no HERMES_KANBAN_TASK" >&2; exit 2; }
case "$TASK" in *[!A-Za-z0-9_-]*) echo "usage: --task '$TASK' is not a task id" >&2; exit 2;; esac
for knob in "HERMES_KANBAN_WORKSPACE=$WS" "HERMES_KANBAN_BOARD=$BOARD" "HERMES_PROFILE=$PROFILE"; do
  [ -n "${knob#*=}" ] || { echo "usage: ${knob%%=*} is unset — lane.sh runs in a dispatcher-spawned worker's terminal, which keeps it" >&2; exit 2; }
done
case "$TICK" in ""|*[!0-9]*|0) echo "usage: FORGE_LANE_TICK must be a positive whole number of seconds, got '$TICK'" >&2; exit 2;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forge-lane-sh.XXXXXX")"
CODEX_PID=""
cleanup() {
  [ -n "$CODEX_PID" ] && kill "$CODEX_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

say() { printf '%s lane: %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

# ---------------------------------------------------------------------------
# The envelope is the whole of stdout. Progress goes to stderr, and every log
# a step produces goes to a file under the run's scratch directory — the driver
# is metered, and a build log in its context is paid for on every turn after.
# ---------------------------------------------------------------------------
# `terminate` is the ONE call the driver makes; `on_error` is what it makes
# instead when the kernel refuses `terminate` (the card is still `running`, so a
# `kanban_block` lands, and without one the run is reaped as a crash). Both carry
# `task_id`: the kernel refuses a worker's call on any task but its own, which is
# the identity check no program can do from a terminal that has no task id.
call_json() {   # tool, args-json -> {tool, args}
  jq -nc --arg tool "$1" --argjson args "$2" '{tool: $tool, args: $args}'
}
ENVELOPE_COPY=""
envelope() {   # action, summary, reason, terminate-json, on_error-json|null, exit-code
  local out
  out="$(jq -nc --arg action "$1" --arg summary "$2" --arg reason "$3" --argjson rc "$6" \
        --argjson terminate "$4" --argjson on_error "$5" '
    { schema: "forge.lane.v2", action: $action,
      summary: (if $summary == "" then null else $summary end),
      reason: (if $reason == "" then null else $reason end),
      rc: $rc, terminate: $terminate, on_error: $on_error, created_cards: [] }')"
  printf '%s\n' "$out"
  [ -z "$ENVELOPE_COPY" ] || printf '%s\n' "$out" > "$ENVELOPE_COPY" 2>/dev/null
  exit "$6"
}
# TRUSTED_TASK is empty until the card has been read back and is provably this
# terminal's. Until then a block names no task and the kernel applies it to the
# driver's own: a wrong --task must not make the kernel refuse the very block that
# reports it (a worker may only mutate its own task).
TRUSTED_TASK=""
block() {
  say "block: $1"
  envelope block "" "$1" \
    "$(call_json kanban_block "$(jq -nc --arg t "$TRUSTED_TASK" --arg r "$1" \
         '(if $t == "" then {} else {task_id: $t} end) + {reason: $r}')")" null 3
}

# The canonical `<class>: <reason>` line out of a step's output, or a fallback
# naming the step and its exit code. The helpers already print board-ready
# reasons; re-wording them here would be a second dialect.
CLASSES='^(stale-spec|failing-prereq|env|ci-red|judge-bounce|gate-misrouted|gate-unrunnable|other): '
reason_from() {   # file, fallback
  local line
  line="$(grep -E "$CLASSES" "$1" 2>/dev/null | tail -1)"
  printf '%s\n' "${line:-$2}"
}

command -v jq >/dev/null || {
  printf '{"schema":"forge.lane.v2","action":"block","reason":"env: jq missing","rc":3,"terminate":{"tool":"kanban_block","args":{"reason":"env: jq missing"}},"on_error":null,"created_cards":[]}\n'
  exit 3
}
for tool in git gh hermes make; do
  command -v "$tool" >/dev/null || block "env: $tool is not on PATH"
done
kanban() { hermes kanban --board "$BOARD" "$@"; }

# NO HEARTBEAT HERE. `hermes kanban heartbeat` is a mutation, so it is refused in
# this terminal (run A: every one failed). The claim is kept alive by the driver
# process: every tool call, `process wait` included, runs under a 30 s activity
# thread that calls `heartbeat_current_worker_from_env` (tools/kanban_tools.py:519,
# agent/tool_executor.py:618) — heartbeat_claim and a `heartbeat` event, at least
# 60 s apart. Run A's own board shows those events at ~60 s throughout, while every
# one of this file's CLI heartbeats failed.

# ---------------------------------------------------------------------------
# 1. Read the card. An operator comment overrides the card body — the skill
# said so for the model's benefit, and it matters just as much to Codex, so
# every comment not written by a forge-* worker profile rides the contract —
# EXCEPT the verifier's `FORGE-VERDICT-V1` envelope, which is excluded by its
# marker rather than by its author. The author is whatever profile the CLI
# happened to run as (an unprofiled `kanban comment` records `default`), so an
# author filter alone would let ~2 KB of verdict JSON into the section headed
# "THEY win" — an operator override the operator never wrote.
# ---------------------------------------------------------------------------
kanban show "$TASK" --json > "$TMP/card.json" 2>/dev/null \
  && jq -e '.task.id' "$TMP/card.json" >/dev/null 2>&1 \
  || block "env: cannot read card $TASK on board $BOARD"
# ---------------------------------------------------------------------------
# WHICH CARD IS THIS TERMINAL'S, AND WHICH RUN? The driver passed the id; the
# fence kept no task id to check it against, so the card itself is asked. A wrong
# id is a driver error (exit 2: it blocks, and the kernel refuses a block on a
# card that is not its own), never a reason to run Codex in someone else's
# workspace. The run id is the card's ONE `running` run — the CLI's `show --json`
# has no `.task.current_run_id`, but the run list names the live run, and it is
# the id the board-local scratch and audit keys are built from (lane-setup.sh).
# ---------------------------------------------------------------------------
identity_error() { echo "usage: $1" >&2; exit 2; }
jq -e --arg id "$TASK" '.task.id == $id' "$TMP/card.json" >/dev/null \
  || identity_error "board $BOARD returned a different card than --task $TASK"
[ "$(jq -r '.task.status // ""' "$TMP/card.json")" = running ] \
  || identity_error "card $TASK is '$(jq -r '.task.status // "unreadable"' "$TMP/card.json")', not running — --task must be YOUR task's id (kanban_show().task.id)"
[ "$(jq -r '.task.assignee // ""' "$TMP/card.json")" = "$PROFILE" ] \
  || identity_error "card $TASK is assigned to '$(jq -r '.task.assignee // "nobody"' "$TMP/card.json")', not to this profile ($PROFILE) — --task must be YOUR task's id"
[ "$(jq '[.runs[]? | select(.status == "running")] | length' "$TMP/card.json")" = 1 ] \
  || identity_error "card $TASK has no single running run, so there is no run id to key this run on"
RUN_ID="$(jq -r '[.runs[] | select(.status == "running")][0].id | tostring' "$TMP/card.json")"
# `cd ""` SUCCEEDS in bash 3.2 (it stays where it is), so an empty workspace_path would compare
# equal to an empty answer from the other side: both are asked ONLY when non-empty.
card_ws_raw="$(jq -r '.task.workspace_path // ""' "$TMP/card.json")"
card_ws="" env_ws=""
[ -z "$card_ws_raw" ] || card_ws="$(cd "$card_ws_raw" 2>/dev/null && pwd -P)"
[ -z "$WS" ] || env_ws="$(cd "$WS" 2>/dev/null && pwd -P)"
{ [ -n "$card_ws" ] && [ "$card_ws" = "$env_ws" ]; } \
  || identity_error "card $TASK's workspace is '$(jq -r '.task.workspace_path // "none"' "$TMP/card.json")', not this terminal's ($WS) — --task must be YOUR task's id"
TRUSTED_TASK="$TASK"   # from here a block may name the card: the kernel will accept it
# A REVIEW CLAIM IS NOT A LANE RUN. `kanban_request_review` with no reviewer leaves
# the card in `review` on THIS profile, and the dispatcher then claims it for the
# lane to "review" its own work (measured on 0.21.5: review/forge-codex-lane, and
# `dispatch` lists it as spawnable). The hand-off below always names a reviewer,
# but it is made by a model retyping the arguments, so a dropped one must not run
# Codex again over finished work. The claim says where it came from.
[ "$(jq -r '[.events[]? | select(.kind == "claimed")] | last | .payload.source_status // ""' "$TMP/card.json")" != review ] \
  || block "other: handoff-integrity — card $TASK was claimed from review by its own implementer, so its last hand-off named no reviewer; name one (kanban assign it to forge-verifier, then unblock) instead of re-running the chunk"
TITLE="$(jq -r '.task.title // ""' "$TMP/card.json")"
jq -r '.task.body // ""' "$TMP/card.json" > "$TMP/body.md"
[ -s "$TMP/body.md" ] && grep -q '[^[:space:]]' "$TMP/body.md" \
  || block "stale-spec: card $TASK has an empty body — there is no contract to implement"
CHUNK_ID="$(printf '%s' "$TITLE" | sed -n 's/^\(CHUNK-[A-Za-z0-9][A-Za-z0-9._-]*\).*/\1/p')"
CHUNK_ID="${CHUNK_ID%.}"
jq -r '[.comments[]? | select(((.author // "") | startswith("forge-") | not)
                              and ((.body // "") | startswith("FORGE-VERDICT-V1") | not)) | .body]
       | if length == 0 then empty else
         "\n---\nOperator comments on this card. Where they disagree with the contract above, THEY win:\n\n"
         + (map("- " + (gsub("\n"; "\n  "))) | join("\n")) end' "$TMP/card.json" > "$TMP/comments.md"
# A card that was handed off before is a bounce re-entry. The reasons are
# whatever was recorded since the LATEST handoff: request-changes puts its
# reason on the event; reopen-review and the verifier put theirs in comments.
# The verifier also parks its whole verdict envelope on the card as a
# `FORGE-VERDICT-V1` comment, because `request-changes` takes no `--metadata`
# (epic FL4). That is a record for the merge-watcher and for metrics, not a
# reason for Codex: delivering ~2 KB of JSON as review feedback would spend the
# implementer's context on something it cannot act on. Filtered by the MARKER
# rather than by author, because the author depends on which profile wrote it.
# Both are read — reading one would lose the other path's reasons.
REENTRY=0
LAST_HANDOFF="$(jq -r '[.events[]? | select(.kind == "review_requested") | .created_at] | max // empty' "$TMP/card.json")"
if [ -n "$LAST_HANDOFF" ]; then
  REENTRY=1
  jq -r --argjson t "$LAST_HANDOFF" '
    ([.events[]? | select(.kind == "changes_requested" and .created_at >= $t)
                 | .payload.reason // empty]
     + [.comments[]? | select(.created_at >= $t and (.author // "") != "forge-codex-lane"
                              and ((.body // "") | startswith("FORGE-VERDICT-V1") | not))
                     | .body]) | map(select(length > 0)) | .[] | "- " + gsub("\n"; "\n  ")' \
    "$TMP/card.json" > "$TMP/reasons.md"
  [ -s "$TMP/reasons.md" ] \
    || block "judge-bounce: card $TASK came back from review with no recorded reason — there is nothing to fix"
fi

# ---------------------------------------------------------------------------
# 2. Parent guard. ADR-0008's rule — children build on merged parents — is
# enforced natively since ADR-0019: a chunk card reaches `done` only once its
# PR merged, and `_parents_satisfied` counts only done/archived, so the
# dispatcher cannot spawn this lane while a parent is unmerged. D19.5 retires
# the compensating check only once a run shows the native gate holding, so it
# stays — as a guard that should never fire. The old §1a's narrow
# bounce-remediation exception is NOT carried over: it existed for tier-2 fix
# cards, which ADR-0019 D19.1 retires (a bounce now returns to THIS card).
# ---------------------------------------------------------------------------
for parent in $(jq -r '.parents[]?' "$TMP/card.json"); do
  kanban show "$parent" --json > "$TMP/parent.json" 2>/dev/null \
    || block "env: cannot read parent card $parent"
  parent_pr="$(jq -r '[.runs[]? | .metadata | select(type == "object")
                        | select(.schema == "forge.chunk.v1") | .pr] | last // empty' "$TMP/parent.json")"
  [ -n "$parent_pr" ] || continue
  merged="$(gh pr view "$parent_pr" --json mergedAt -q '.mergedAt // ""' 2>/dev/null)" \
    || block "env: cannot read parent PR $parent_pr"
  [ -n "$merged" ] \
    || block "failing-prereq: parent PR $parent_pr is not merged — the native gate should have held this card"
done

# ---------------------------------------------------------------------------
# 3. Integrate the base. The dispatcher branches the worktree from the main
# checkout's HEAD, which lags GitHub whenever a parent merged there and nobody
# pulled. Under the old flow §1a rebased on the operator-unblocked retry;
# under native gating there is no retry, so a FRESH branch (no commits of its
# own) is fast-forwarded to origin/<base> here, before setup builds on it. A
# branch that already carries commits is a bounce re-entry and is left alone.
# ---------------------------------------------------------------------------
cd "$WS" 2>/dev/null || block "env: workspace $WS does not exist"
git fetch origin >/dev/null 2>&1 || block "env: 'git fetch origin' failed in $WS — remote state is unverified"
git rev-parse --verify --quiet "origin/$BASE" >/dev/null \
  || block "env: origin has no $BASE branch to build on"
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" \
  || block "env: workspace $WS is detached; a task branch is required"
[ "$BRANCH" != "$BASE" ] || block "env: workspace $WS is on $BASE, not a task branch"
OWN_COMMITS="$(git rev-list --count "origin/$BASE..HEAD" 2>/dev/null)" \
  || block "env: cannot compare $BRANCH with origin/$BASE"
if [ "$OWN_COMMITS" = 0 ]; then
  git merge --ff-only --quiet "origin/$BASE" >/dev/null 2>&1 \
    || block "env: fresh branch $BRANCH cannot fast-forward to origin/$BASE"
fi

# ---------------------------------------------------------------------------
# 4. Make the worktree usable. Codex's sandbox has no network and the
# worktree has no .venv; lane-setup.sh builds both, proves the baseline, and
# takes the immutable blast-radius capture. It emits the run's scratch path and
# audit key as its last two lines; they are consumed, never recomputed — run
# ids are board-local, so a recomputed key rebuilds the collision.
# ---------------------------------------------------------------------------
FORGE_LANE_REENTRY="$REENTRY" "$HERE/lane-setup.sh" "$WS" "$RUN_ID" > "$TMP/setup.out" 2>/dev/null
setup_rc=$?
[ "$setup_rc" = 0 ] || block "$(reason_from "$TMP/setup.out" "env: lane-setup.sh exited $setup_rc")"
FORGE_LANE_RUN_KEY="$(sed -n 's/^FORGE_LANE_RUN_KEY=//p' "$TMP/setup.out" | tail -1)"
FORGE_LANE_RUNTIME="$(sed -n 's/^FORGE_LANE_RUNTIME=//p' "$TMP/setup.out" | tail -1)"
[ -n "$FORGE_LANE_RUN_KEY" ] && [ -d "$FORGE_LANE_RUNTIME" ] \
  || block "env: lane-setup.sh succeeded without emitting FORGE_LANE_RUN_KEY and FORGE_LANE_RUNTIME"
export FORGE_LANE_RUNTIME

# ---------------------------------------------------------------------------
# 5. The contract, with the role boundary appended ALWAYS, whatever the card
# says. Load-bearing, not boilerplate: reads are not sandboxed, the project's
# AGENTS.md names the ceremony skills, and Codex followed that pointer into
# skills/ and adopted the calling agent's role — push, PR and board included
# (measured 2026-07-28).
# ---------------------------------------------------------------------------
BOUNDARY_FILE="$TMP/boundary.md"
cat > "$BOUNDARY_FILE" << 'EOF'

---
You implement this contract inside this worktree. That is your whole job.
Do NOT push, do NOT open a PR, do NOT run `hermes` or touch the kanban board,
do NOT read or follow `forge-lane`, `start-chunk` or `end-chunk` — those are
the calling agent's protocol, not yours. Commit in small scoped commits.
Never use --no-verify. `make check` must be green when you stop.
EOF
{
  cat "$TMP/body.md"
  cat "$TMP/comments.md"
  if [ "$REENTRY" = 1 ]; then
    printf '\n---\nThis contract was implemented on this branch, reviewed, and sent back. Fix exactly these, in new commits on top of the existing ones:\n\n'
    cat "$TMP/reasons.md"
  fi
  cat "$BOUNDARY_FILE"
} > "$FORGE_LANE_RUNTIME/contract.md"

# A re-entry resumes the session that wrote the branch, when it still exists:
# codex-run.sh finds the id in its session file and delivers the reasons as
# the resume prompt. Codex prunes old sessions, so an id whose rollout is gone
# falls back to a fresh session given the full contract — which carries the
# reasons too. Only a record naming THIS workspace is trusted.
SESSION_RECORD="$SESSION_ROOT/$BOARD-$TASK"
if [ "$REENTRY" = 1 ]; then
  prior_session="" prior_ws=""
  [ -r "$SESSION_RECORD" ] && IFS=$'\t' read -r prior_session prior_ws < "$SESSION_RECORD"
  if [ -n "$prior_session" ] && [ "$prior_ws" = "$WS" ] \
     && [ -n "$(find "${CODEX_HOME:-$HOME/.codex}/sessions" -name "*-$prior_session.jsonl" -type f 2>/dev/null | head -1)" ]; then
    printf '%s\n' "$prior_session" > "$FORGE_LANE_RUNTIME/codex-session-id"
    {
      printf 'Your implementation of this contract, on this branch, was reviewed and sent back. Fix exactly these, in new commits on top of your earlier ones. Do not start over and do not revert your earlier work:\n\n'
      cat "$TMP/reasons.md"
      cat "$BOUNDARY_FILE"
    } > "$FORGE_LANE_RUNTIME/bounce-prompt.md"
    say "re-entry: resuming the implementer's session $prior_session"
  else
    say "re-entry: no resumable session for $TASK; a fresh session gets the contract and the reasons"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Codex. codex-run.sh owns the invocation (sandbox, --add-dir grant, model
# pin, UV cache) and parks through provider usage limits, resuming the same
# session. A park keeps this run alive for hours; the driver's own bridge keeps
# the claim fresh meanwhile (see "NO HEARTBEAT HERE" above).
#
# THE RUNNER'S `PARK-COMMENT` LINES USED TO BE POSTED TO THE CARD AS THEY APPEARED.
# `hermes kanban comment` is refused in this terminal, so they are COUNTED instead
# and reported once, in the hand-off summary (`parked N× on <windows>`), which is
# durable on the run. Resumption never depended on the comment: it reads the park
# file and `lane-sessions` (codex-run.sh). What the operator loses is the card-
# visible "parked until ..." WHILE the run lives; the runner's own log, the park
# file under ~/.forge/lane-parks and `hermes kanban log <id>` still show it.
# ---------------------------------------------------------------------------
CODEX_LOG="$FORGE_LANE_RUNTIME/codex-run.log"
"$HERE/codex-run.sh" "$WS" "$RUN_ID" "$TASK" > "$CODEX_LOG" 2>&1 &
CODEX_PID=$!
while kill -0 "$CODEX_PID" 2>/dev/null; do
  sleep "$TICK"
done
wait "$CODEX_PID"; codex_rc=$?
CODEX_PID=""
[ "$codex_rc" = 0 ] || block "$(reason_from "$CODEX_LOG" "env: codex-run.sh exited $codex_rc")"
# Kept for a bounce re-entry, keyed by board and card, outside the per-run
# scratch (which a new run never sees). Never fatal: losing it costs one
# re-read of the chunk, not the chunk.
if [ -s "$FORGE_LANE_RUNTIME/codex-session-id" ]; then
  mkdir -p "$SESSION_ROOT" 2>/dev/null \
    && printf '%s\t%s\n' "$(head -1 "$FORGE_LANE_RUNTIME/codex-session-id")" "$WS" > "$SESSION_RECORD" \
    || say "could not keep the Codex session id for a re-entry (continuing)"
fi
PARKS="$(grep -c 'PARK-COMMENT ' "$CODEX_LOG" 2>/dev/null)"
PARK_NOTE=""
if [ "${PARKS:-0}" -gt 0 ]; then
  PARK_WINDOWS="$(sed -n 's/.*PARK-COMMENT env: codex usage limit on \([^;]*\);.*/\1/p' "$CODEX_LOG" | sort -u | paste -sd, -)"
  PARK_NOTE=" Parked ${PARKS}x on a Codex usage limit (${PARK_WINDOWS:-window unknown})."
fi

# ---------------------------------------------------------------------------
# 7. Verify it here. Plain `make check` — the command CI runs, with the uv
# overrides already stripped at the top of this file. A green from a warm lint
# cache is not a green either (measured 2026-07-28).
#
# Not carried over from the old §5: "read the diff as a hostile reviewer".
# That was a judgement asked of the cheapest model in the pipeline; judgement
# about the diff belongs to the verifier (ADR-0019 D19.2), and no program can
# perform it here.
# ---------------------------------------------------------------------------
rm -rf .ruff_cache
make check > "$FORGE_LANE_RUNTIME/make-check.log" 2>&1 \
  || block "ci-red: 'make check' is red after codex — not green is not done (log: $FORGE_LANE_RUNTIME/make-check.log)"
[ "$(git rev-list --count "origin/$BASE..HEAD")" -gt 0 ] \
  || block "other: codex finished without a commit on $BRANCH — there is nothing to hand off"

# ---------------------------------------------------------------------------
# 8. The final fail-closed audit, under the key setup emitted. A breach is
# ALWAYS a block, never a push and never a retry: the run went outside its
# contract and there is no telling from here what else it did.
# ---------------------------------------------------------------------------
"$HERE/lane-blast-radius.sh" check "$WS" "$FORGE_LANE_RUN_KEY" > "$TMP/blast.out" 2>/dev/null
blast_rc=$?
[ "$blast_rc" = 0 ] || block "$(reason_from "$TMP/blast.out" "other: lane-blast-radius.sh check exited $blast_rc")"

# ---------------------------------------------------------------------------
# 9. Push and PR. Never main (step 3 refused it). Reuse an open PR — a Codex
# run that ignored the boundary may have opened one, and a bounce re-entry
# pushes to the one it already has.
# ---------------------------------------------------------------------------
git push -u origin HEAD > "$TMP/push.out" 2>&1 \
  || block "env: 'git push' of $BRANCH was refused (see the branch's remote state)"
PR_URL="" PR_STATE=""
if gh pr view "$BRANCH" --json url,state > "$TMP/pr.json" 2>/dev/null; then
  PR_URL="$(jq -r '.url // ""' "$TMP/pr.json")"
  PR_STATE="$(jq -r '.state // ""' "$TMP/pr.json")"
fi
case "$PR_STATE" in
  OPEN) ;;
  "")
    {
      printf '%s\n\nImplements Hermes card `%s` on board `%s`.\n\n' "${TITLE:-$BRANCH}" "$TASK" "$BOARD"
      printf '## What Codex reported\n\n'
      if [ -s "$FORGE_LANE_RUNTIME/codex-last.md" ]; then cat "$FORGE_LANE_RUNTIME/codex-last.md"; else echo '_no final message_'; fi
      printf '\n\n## Commits\n\n'
      git log --format='- %s' "origin/$BASE..HEAD"
      printf '\n## `make check`\n\n```\n'
      tail -15 "$FORGE_LANE_RUNTIME/make-check.log"
      printf '```\n'
    } > "$FORGE_LANE_RUNTIME/pr-body.md"
    gh pr create --base "$BASE" --head "$BRANCH" --title "${TITLE:-$BRANCH}" \
      --body-file "$FORGE_LANE_RUNTIME/pr-body.md" > "$TMP/pr-create.out" 2>&1 \
      || block "env: 'gh pr create' failed for $BRANCH"
    PR_URL="$(grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' "$TMP/pr-create.out" | tail -1)"
    ;;
  *) block "other: $BRANCH already has a $PR_STATE PR ($PR_URL) — a lane never reopens one";;
esac
[ -n "$PR_URL" ] || block "env: no PR URL could be read back for $BRANCH"

# ---------------------------------------------------------------------------
# 10. The completion envelope, computed. Every number here comes from git or
# from the run's own files — "numbers come from scripts, never from a model"
# (the epic's principles). The four codex_* keys are copied from what
# codex-run.sh recorded, source marker included (F22).
# ---------------------------------------------------------------------------
git diff "origin/$BASE...HEAD" > "$TMP/diff.patch" 2>/dev/null
git diff --name-only "origin/$BASE...HEAD" > "$TMP/files.txt" 2>/dev/null
added_lines() { # path-regex -> the added lines of matching files, '+' stripped
  awk -v re="$1" '
    /^diff --git / { f = $4; sub(/^b\//, "", f); keep = (f ~ re); next }
    keep && /^\+/ && !/^\+\+\+ / { print substr($0, 2) }' "$TMP/diff.patch"
}
added_lines '\.feature$' > "$TMP/features.txt"
added_lines '^docs/decision-log\.md$' | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}' > "$TMP/decisions.txt"
added_lines '.' > "$TMP/marks.txt"
coverage="$(grep -E '^TOTAL[[:space:]]' "$FORGE_LANE_RUNTIME/make-check.log" | tail -1 \
            | grep -Eo '[0-9]+(\.[0-9]+)?%' | tail -1 | tr -d '%')"
read -r lines_ins lines_del < <(git diff --numstat "origin/$BASE...HEAD" \
  | awk '$1 ~ /^[0-9]+$/ { a += $1; d += $2 } END { print a + 0, d + 0 }')
codex_model="" codex_effort="" codex_source="" codex_requested=""
if [ -r "$FORGE_LANE_RUNTIME/codex-model" ]; then
  codex_model="$(sed -n 's/^FORGE_CODEX_MODEL_RAN=//p' "$FORGE_LANE_RUNTIME/codex-model" | tail -1)"
  codex_effort="$(sed -n 's/^FORGE_CODEX_REASONING_EFFORT=//p' "$FORGE_LANE_RUNTIME/codex-model" | tail -1)"
  codex_source="$(sed -n 's/^FORGE_CODEX_MODEL_SOURCE=//p' "$FORGE_LANE_RUNTIME/codex-model" | tail -1)"
  codex_requested="$(sed -n 's/^FORGE_CODEX_MODEL_REQUESTED=//p' "$FORGE_LANE_RUNTIME/codex-model" | tail -1)"
fi
project="$(basename "$(git remote get-url origin 2>/dev/null)" .git)"
jq -n \
  --arg chunk_id "$CHUNK_ID" --arg project "$project" --arg branch "$BRANCH" \
  --arg pr "$PR_URL" --arg coverage "$coverage" \
  --argjson ins "${lines_ins:-0}" --argjson del "${lines_del:-0}" \
  --argjson minutes "$(( ($(date +%s) - STARTED) / 60 ))" \
  --arg model "$codex_model" --arg effort "$codex_effort" \
  --arg source "$codex_source" --arg requested "$codex_requested" \
  --rawfile files "$TMP/files.txt" --rawfile features "$TMP/features.txt" \
  --rawfile decisions "$TMP/decisions.txt" --rawfile marks "$TMP/marks.txt" '
  def lines($s): $s | split("\n") | map(select(length > 0));
  (lines($files)) as $changed
  | ([lines($features)[] | select(test("^[[:space:]]*Scenario( Outline)?:"))] | length) as $scen
  | {
      schema: "forge.chunk.v1",
      chunk_id: $chunk_id, project: $project, branch: $branch, pr: $pr,
      lane: "forge-codex-lane",
      scenarios: { added: $scen, passing: $scen,
                   feature_files: [$changed[] | select(endswith(".feature"))] },
      check: { green: true, coverage_pct: ($coverage | tonumber? // null) },
      files_changed: ($changed | length),
      lines_changed: ($ins + $del),
      decisions: [lines($decisions)[] | .[0:300]],
      debt: [lines($marks)[] | select(contains("DEBT:")) | sub("^.*DEBT:"; "DEBT:") | .[0:300]] | unique,
      card_proposals: [lines($marks)[] | select(contains("CARD?:")) | sub("^.*CARD\\?:"; "CARD?:") | .[0:300]] | unique,
      docs_reconciled: [$changed[] | select(startswith("docs/") or endswith(".md"))],
      duration_min: $minutes,
      worker: ("codex/" + (if $model == "" then "unknown" else $model end)
               + (if $effort == "" then "" else " " + $effort end)),
      changed_files: $changed,
      tests_run: ["make check"]
    }
  + (if $model == ""     then {} else { codex_model: $model } end)
  + (if $effort == ""    then {} else { codex_reasoning_effort: $effort } end)
  + (if $source == ""    then {} else { codex_model_source: $source } end)
  + (if $requested == "" then {} else { codex_model_requested: $requested } end)
  ' > "$FORGE_LANE_RUNTIME/chunk-metadata.json" 2> "$TMP/meta.err" \
  || block "other: the completion envelope could not be assembled ($(head -1 "$TMP/meta.err"))"

# The validator runs under `uv run`, whose install chatter shares stderr with
# the validator's own findings; the reason line is the first finding.
validator_says() {
  grep -vE '^[[:space:]]*$|^(Installed|Resolved|Prepared|Downloaded|Audited|Uninstalled|Using|Reading|Built|warning:) ' "$1" \
    | head -1
}
"$HERE/validate-metadata.py" --profile forge-codex-lane \
  "$FORGE_LANE_RUNTIME/chunk-metadata.json" > "$TMP/validate.out" 2>&1 \
  || block "other: the completion envelope failed its contract — $(validator_says "$TMP/validate.out")"

SUMMARY="$CHUNK_ID$([ "$REENTRY" = 1 ] && printf ' (after review)'): PR $PR_URL — make check green, blast radius clean, codex ${codex_model:-unknown}. Watch: $(jq -r '.files_changed' "$FORGE_LANE_RUNTIME/chunk-metadata.json") files, ${lines_ins:-0}+/${lines_del:-0}- lines."

# ---------------------------------------------------------------------------
# 11. The hand-off — NAMED here, MADE by the driver (epic FL3, then P24).
#
# The card moves running -> review, assigned to the reviewer, on the SAME card.
# The reviewer is always named: after an operator `reopen-review` the kernel has
# no reviewer to default to and would dispatch the card back to this lane (the
# check in step 1 refuses that run). The card reaches `done` only when its PR
# merges, which is what holds its children — so this is NOT `kanban_complete`.
#
# This file does not make the call: the terminal is fenced (see the top). It
# prints the call, `kanban_request_review` with the validated envelope as its
# `metadata`, and the driver makes it. Two consequences are handled here:
#
#   * The driver retypes the arguments. What it must not get wrong is on the host
#     too: the validated envelope is kept beside the session record, and the
#     verifier compares the metadata the kernel stored with it before it reviews
#     anything (prejudge-review.sh, "the lane's envelope arrives intact").
#   * `kanban_request_review` adds one key to the stored metadata,
#     `worker_session_id`, and redacts secret-shaped strings; neither touches a
#     SHA, a URL or a number, and the schema allows the key (measured, S6d).
#
# The envelope is also left in the run's scratch, so an operator can re-issue a
# hand-off a driver never made without re-running Codex.
# ---------------------------------------------------------------------------
SUMMARY="${SUMMARY}${PARK_NOTE}"
RECOVER_META=""
if mkdir -p "$SESSION_ROOT" 2>/dev/null \
   && jq -S . "$FORGE_LANE_RUNTIME/chunk-metadata.json" > "$SESSION_ROOT/$BOARD-$TASK.metadata.json.new" 2>/dev/null \
   && mv -f "$SESSION_ROOT/$BOARD-$TASK.metadata.json.new" "$SESSION_ROOT/$BOARD-$TASK.metadata.json"; then
  RECOVER_META="$SESSION_ROOT/$BOARD-$TASK.metadata.json"
else
  RECOVER_META="$FORGE_LANE_RUNTIME/chunk-metadata.json"
  say "could not keep the validated envelope for the verifier to compare (continuing)"
  rm -f "$SESSION_ROOT/$BOARD-$TASK.metadata.json.new" 2>/dev/null
fi
ENVELOPE_COPY="$FORGE_LANE_RUNTIME/envelope.json"
envelope handoff "$SUMMARY" "" \
  "$(call_json kanban_request_review "$(jq -nc --arg t "$TASK" --arg s "$SUMMARY" --arg r "$REVIEWER" \
       --slurpfile m "$FORGE_LANE_RUNTIME/chunk-metadata.json" \
       '{task_id: $t, summary: $s, metadata: $m[0], reviewer: $r}')")" \
  "$(call_json kanban_block "$(jq -nc --arg t "$TASK" --arg u "$PR_URL" --arg b "$BOARD" --arg m "$RECOVER_META" \
       '{task_id: $t, reason: ("other: handoff-integrity — the review hand-off of " + $t + " was refused by the kernel; the branch is pushed and the PR is open (" + $u + "). Do NOT just unblock the card: that runs Codex again over finished work. Recover with: ~/.forge/repo/scripts/lane-handoff.sh " + $t + " --board " + $b + " --summary \"<one line>\" --metadata " + $m)}')")" \
  4
