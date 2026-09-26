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
#   * The model terminates NOTHING on a routed outcome. The kernel ends the run
#     as part of the transition, exactly as `request-review` ends the lane's.
#     Exit 3 is still the model's `kanban_block`, because nothing transitioned.
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
#                      [--fixture <dir>] [--dry-run]
#   ...with the chunk contract on stdin. <card-id> IS the running card.
#
# Env:
#   FORGE_VERIFIER_MERGE=1          merge mode. Absent = recommend-only, which
#                                   is the default and fails closed.
#   FORGE_VERIFIER_BOUNCE_BUDGET    rounds before the exception          [2]
#   FORGE_MERGE_CHECK_BIN           stand in for scripts/merge-check.sh
#
# Exit: 0 a routed outcome — the card has already been transitioned; the model
#         calls NOTHING. Read `.action` for which transition happened:
#         `bounce` / `gate-block` (request-changes), `recommend` (blocked for
#         the operator), `exception` (bounce budget spent), `merged` (merge
#         mode), `would-score` (--dry-run).
#       3 a substrate fault — nothing transitioned. Read `.reason` and
#         `kanban_block`.
#       2 a usage error.
#
# 1 is deliberately NOT used: a bounced PR is a routed outcome, not a failure of
# this script, and a caller running under `set -e` must not treat a bounce as a
# crash.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_URL=""; CHUNK=""; BOARD="${HERMES_KANBAN_BOARD:-}"; REPO=""; chunk_title=""
WAIT_SECS=600; FIXTURE="${PREJUDGE_FIXTURE:-}"; DRY_RUN=0
CREATED=()
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --chunk)   CHUNK="${2:?--chunk needs a card id}"; shift 2;;
    --board)   BOARD="${2:?--board needs a slug}"; shift 2;;
    --repo)    REPO="${2:?--repo needs owner/name}"; shift 2;;
    --wait)    WAIT_SECS="${2:?--wait needs seconds}"; shift 2;;
    --fixture) FIXTURE="${2:?--fixture needs a directory}"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; exit 0;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) [ -z "$PR_URL" ] || { echo "only one PR: '$PR_URL' and '$1'" >&2; exit 2; }
       PR_URL="$1"; shift;;
  esac
done
[ -n "$PR_URL" ] || { usagetext; exit 2; }
command -v jq >/dev/null || { echo '{"action":"substrate-block","reason":"env: jq missing"}'; exit 3; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forge-review.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# The envelope is the whole of this script's output, and it is small on
# purpose. The driver is the only metered agent in the run, so every byte
# printed here is billed to it. A 127 KB diff passes through this process and
# never touches stdout.
# ---------------------------------------------------------------------------
envelope() {   # action, summary, metadata-file|'null', reason, exit-code
  local action="$1" summary="$2" metafile="$3" reason="$4" code="$5" meta='null'
  [ "$metafile" != "null" ] && [ -s "$metafile" ] && meta="$(cat "$metafile")"
  jq -n --arg action "$action" --arg summary "$summary" --arg reason "$reason" \
        --argjson metadata "$meta" \
        --argjson created "$(printf '%s\n' ${CREATED[@]+"${CREATED[@]}"} \
                             | jq -Rs 'split("\n") | map(select(length>0))')" '
    { schema: "forge.review.v1", action: $action, summary: $summary,
      reason: (if $reason == "" then null else $reason end),
      metadata: $metadata, created_cards: $created }'
  exit "$code"
}

# A substrate fault is a fact about the world, never a verdict on the work.
# Conflating the two is how an outage reads as a rejection, which is why it has
# its own exit code and its own terminator.
substrate() { envelope substrate-block "" null "$1" 3; }

kanban() { hermes kanban --board "$BOARD" "$@"; }
board_live() { [ -n "$BOARD" ] && command -v hermes >/dev/null; }

# ---------------------------------------------------------------------------
# --chunk IS THE RUNNING CARD. This guard used to assert the opposite, and it
# was right until ADR-0019: a chunk card parented a tier-1 child, a MODEL read
# the parent's id out of prose in the SOUL, and on 2026-09-04 a running prejudge
# task passed ITS OWN id — route_tier2 parented the tier-2 card under itself and
# the misparented chunk drove the card into `todo`, where `block` silently
# refuses it. The fix then was to refuse `--chunk == $HERMES_KANBAN_TASK`.
#
# D19.1 removes the parent relationship the old guard protected: there is ONE
# card per chunk for its whole life, the verifier is claimed on that card, and
# the SOUL passes `$HERMES_KANBAN_TASK`. So the identity that must hold is the
# inverse, and it is still mechanically checkable BEFORE anything transitions:
#
#   1. Under a worker, --chunk must BE the running task. Anything else means the
#      caller reached for another card, and the card this run holds a claim on is
#      not the card it would transition — the 2026-09-04 shape with the sign
#      flipped. No board access needed, which is why it runs first.
#   2. --chunk's card must still LOOK like a chunk card (`CHUNK-<id>: <title>`,
#      scripts/prejudge.sh's `branch_name` convention). A verifier pointed at a
#      gate card or a typo'd id is refused. Needs a live board, so it is
#      conditional on one.
#
# Both fail closed through `substrate` (exit 3, `kanban_block`): a bad hand-off
# is a fact about how this run was invoked, not a judgement on the work, so it
# routes exactly like `env: jq missing` and never like a usage error a caller
# under `set -e` could crash on.
# ---------------------------------------------------------------------------
[ -z "${HERMES_KANBAN_TASK:-}" ] || [ "$CHUNK" = "$HERMES_KANBAN_TASK" ] || \
  substrate "env: chunk-identity — --chunk ($CHUNK) is not the running card (${HERMES_KANBAN_TASK}); under ADR-0019 D19.1 the chunk card and the review are the same card"

if board_live; then
  chunk_title="$(kanban show "$CHUNK" --json 2>/dev/null | jq -r '.task.title // empty' 2>/dev/null)"
  case "$chunk_title" in
    CHUNK-[A-Za-z0-9]*) ;;
    *) substrate "env: chunk-identity — --chunk ($CHUNK) does not look like a chunk card (title '${chunk_title:-<unreadable>}', want CHUNK-<id>: <title>)";;
  esac
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
# end state is read back rather than taken from the CLI's word (FL3's rule).
route_changes() {  # $1=reasons body
  board_live || return 0
  kanban request-changes "$CHUNK" "$1" >/dev/null 2>&1 || return 1
  card_json | jq -e '
    (.task.status | IN("ready","todo"))
    and any(.events[]?; .kind == "changes_requested")' >/dev/null || return 1
}

# WHERE THE VERDICT GOES WHEN THE TRANSITION CANNOT CARRY IT.
#
# `hermes kanban complete` and `request-review` take `--metadata`. `block` and
# `request-changes` DO NOT (measured against the installed CLI: neither help text
# names the flag). So on every path except a merge, the envelope this script
# computed — `forge.gate.v1` or `forge.judge.v1`, the rows `scripts/metrics.sh`
# counts — has no run to ride.
#
# It is therefore posted as a card COMMENT under a stable marker, and the
# merge-watcher passes it back as `--metadata` when it completes the card.
# Measured: completing a card with no live claim opens a NEW run
# (`profile = forge-verifier`, `outcome = completed`) and the metadata lands on
# it, so `rubrics/run-metadata-contract.json`'s `forge-verifier` entry is true of
# a merged chunk however it was completed.
#
# The comment goes on BEFORE the transition: a block ends this run, and evidence
# that depends on a later write is evidence that can be lost. It never fails the
# outcome — a verdict that was reached must not be destroyed by a board that
# would not take a comment.
VERDICT_MARKER="FORGE-VERDICT-V1"
stash_envelope() {  # $1=metadata file
  board_live || return 0
  [ -s "$1" ] || return 0
  kanban comment "$CHUNK" "$VERDICT_MARKER
\`\`\`json
$(jq -c . "$1" 2>/dev/null || cat "$1")
\`\`\`" >/dev/null 2>&1 || true
}

# An approval the verifier may only RECOMMEND (ADR-0019 D19.3). The card is
# blocked sticky; the operator merges on GitHub; the merge-watcher completes it.
# Return 2 means the kernel routed the block to `triage` anyway — a hold that
# was never taken, which must be reported and never reported as a hold.
route_recommend() {  # $1=reason, already carrying its registry class
  local kind; kind="$(next_block_kind)"
  board_live || return 0
  kanban block --kind "$kind" "$CHUNK" "$1" >/dev/null 2>&1 || return 1
  case "$(card_json | jq -r '.task.status')" in
    blocked) return 0;;
    triage)  return 2;;
    *)       return 1;;
  esac
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
route_merge() {  # $1=result summary, $2=metadata file
  gh pr merge --squash --delete-branch "$PR_URL" >/dev/null 2>&1 < /dev/null || return 1
  gh pr view "$PR_URL" --json state,mergedAt < /dev/null 2>/dev/null \
    | jq -e '.state == "MERGED" and (.mergedAt | type) == "string"' >/dev/null || return 1
  board_live || return 0
  kanban complete "$CHUNK" --result "$1" --metadata "$(jq -c . "$2" 2>/dev/null)" >/dev/null 2>&1 || return 1
  [ "$(card_json | jq -r '.task.status')" = done ] || return 1
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
decision_message() {  # $1=class  $2=headline  $3=means  $4=decision  $5=risk  $6=reply
  printf '%s: %s\n\nWhat it means: %s\nDecision needed: %s\nRisk: %s\nReply: %s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

# FL6 — two bounce rounds, then ONE exception, and the exception is a completable
# block rather than the kernel's `triage`. The epic reached the same number by a
# different route ("same-kind re-blocks route to triage at
# BLOCK_RECURRENCE_LIMIT=2"); that route is measured above to be a dead end for a
# chunk card, so the budget is counted here and the exception is an ordinary
# sticky block the operator can act on. `FORGE_VERIFIER_BOUNCE_BUDGET` exists so
# a case can drive the boundary without three round trips; it defaults to 2 and
# nothing in the pipeline sets it.
bounce_or_except() {  # $1=reasons  $2=one-line why  $3=metadata file  $4=action [bounce]
  local rounds budget="${FORGE_VERIFIER_BOUNCE_BUDGET:-2}" rc action="${4:-bounce}"
  rounds="$(bounce_rounds)"
  stash_envelope "$3"
  if [ "$rounds" -lt "$budget" ]; then
    route_changes "$PR_URL

$(implementer_model_line)
$2

$1" || substrate "other: handoff-integrity — request-changes did not return this card to its implementer"
    envelope "$action" "$2 (round $((rounds + 1)) of $budget)" "$3" "" 0
  fi
  route_recommend "$(decision_message bounce-budget \
    "$2 — and this chunk has now used its $budget bounce rounds" \
    "the verifier bounced it $rounds times with actionable reasons and the work still does not pass; a third machine round is not evidence of anything new" \
    "repair it yourself, amend the contract, or send it back for another round" \
    "the card is blocked and its children stay held; nothing is merged" \
    "fix and push to the PR branch, or \`~/.forge/repo/scripts/bounce.sh $CHUNK \"<reason>\" --board $BOARD\` to give it another round

$1")"; rc=$?
  [ "$rc" = 2 ] && substrate "other: handoff-integrity — the exception block was routed to triage, so this chunk is not held for the operator, it is stranded"
  [ "$rc" = 0 ] || substrate "other: handoff-integrity — the bounce-budget exception did not land as a block"
  envelope exception "$2 — bounce budget spent after $rounds rounds" "$3" "" 0
}

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
cat > "$contract_file"   # the chunk contract, on stdin

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
MERGED="$TMP/merged-tree.json"
merge_repo=""; head_ref=""; clone_url=""
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
  head_ref="$(gh pr view "$PR_URL" --json headRefName < /dev/null 2>/dev/null | jq -r '.headRefName // empty')"
  clone_url="$(gh repo view "$merge_repo" --json url < /dev/null 2>/dev/null | jq -r '.url // empty')"
  [ -n "$head_ref" ] && [ -n "$clone_url" ] \
    || substrate "env: merge-check-unrunnable — cannot read the PR's head branch, or the repository URL for '$merge_repo', from gh (this must not depend on the cwd: the verifier's workspace holds no clone)"
  "$MERGE_CHECK_BIN" --clone-from "$clone_url" --head-ref "$head_ref" > "$MERGED" 2>"$TMP/merged.err"
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
EVIDENCE="$(printf '%s\ngate: clear — %s\nmerged tree: %s\nverdict: %s — scores %s\nspot-check: %s' \
  "$(implementer_model_line)" \
  "$(jq -r '[.checks[]|select(.status=="warn")|.id]
     | if length==0 then "no warnings" else "warnings: "+join(", ") end' "$GATE")" \
  "$(jq -r '.evidence // "not run"' "$MERGED" 2>/dev/null | head -c 300)" \
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
    if merge_mode; then
      route_merge "merged by forge-verifier: $SUMMARY" "$TMP/verdict.json" \
        || substrate "other: handoff-integrity — the squash merge, its read-back, or the completion did not take"
      envelope merged "$SUMMARY" "$TMP/verdict.json" "" 0
    fi
    stash_envelope "$TMP/verdict.json"
    route_recommend "$(decision_message merge-pending \
      "${chunk_title:-this chunk} is verified and NOT merged — the verifier may only recommend" \
      "the deterministic gate is clear, \`make check\` is green on this branch merged with main, and the scorer reached $SUMMARY. Recommend-only is the default until the flip criterion is met (ADR-0019 D19.3)" \
      "merge the PR, or send it back" \
      "nothing is merged and this card's children stay held until it is" \
      "merge $PR_URL on GitHub — the merge-watcher completes this card — or \`~/.forge/repo/scripts/bounce.sh $CHUNK \"<reason>\" --board $BOARD\`

$EVIDENCE")"; recommend_rc=$?
    [ "$recommend_rc" = 2 ] && substrate "other: handoff-integrity — the approval block was routed to triage, so this PR is not waiting for the operator, it is stranded"
    [ "$recommend_rc" = 0 ] || substrate "other: handoff-integrity — the recommend-only block did not land on this card"
    envelope recommend "$SUMMARY" "$TMP/verdict.json" "" 0;;
  bounce)
    bounce_or_except "$(jq -r '.findings[]? |
        "- **\(.dimension)** (\(.severity)) — \(.evidence)\n  - action: \(.action)"' \
        "$TMP/verdict.json")" \
      "$(jq -r '[.findings[]? | .dimension] | unique | join(", ")' "$TMP/verdict.json")" \
      "$TMP/verdict.json";;
  *)
    substrate "other: judge-envelope — verdict was '$VERDICT', not one of the three";;
esac
