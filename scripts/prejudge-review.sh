#!/usr/bin/env bash
# =============================================================================
# forge prejudge-review — tier 1's protocol, as a program (ADR-0010).
#
# ADR-0003: "anything that MUST hold is expressed as a machine gate at the
# lowest layer that sees every actor." `scripts/prejudge.sh` applied that rule
# to what tier 1 *decides*. This file applies it to what tier 1 *does*.
#
# Until now the protocol lived in `hermes/profiles/forge-prejudge.SOUL.md`: 404
# lines, of which 144 were executable bash in 11 fenced blocks — a `jq` schema
# reduction, a `claude -p` invocation, a 15-line stamping `jq`, a
# create/block/unassign sentinel dance and two `jq -e` read-backs. None of it
# needed a model. All of it was retyped by one, on every run, at
# `deepseek-v4-flash` quality, with no gate on the transcription. The other
# three profiles are 27, 29 and 32 lines, because their protocol is an artifact
# they load rather than prose they re-enact (audit F61).
#
# Everything a model must still decide stays with the model, and it is exactly
# two things: `kanban_complete` and `kanban_block`, which the completion kernel
# ties to the identity of the running task. This script does the rest and hands
# back one small JSON envelope naming which terminator to call.
#
# WHAT THIS FILE IS NOT ALLOWED TO DO
# It does not re-decide anything the gate decided, it does not score, and it
# does not touch the scorer's brief. The `claude -p --model opus` call below is
# S5's experimental control arm: it MOVED here from the SOUL and it was not
# modified. `make verify`'s `prejudge/scorer-is-the-control-arm` diffs it
# against `git show main:hermes/profiles/forge-prejudge.SOUL.md` and fails the
# suite on any difference, whitespace included. That is why two regions below
# are indented three spaces instead of two: they are pinned bytes carried over
# from a markdown list item. Do not reindent them. Do not tidy them. If you
# think the scorer should change, that is ADR-0009 D9.5 — S5's experiment, not
# an edit.
#
# Usage:
#   prejudge-review.sh <pr-url> --chunk <card-id> [--board <slug>]
#                      [--repo owner/name] [--wait <seconds>]
#                      [--fixture <dir>] [--dry-run]
#   ...with the chunk contract on stdin.
#
# Exit: 0 a routed outcome — read the envelope and `kanban_complete`.
#       3 a substrate fault — read `.reason` and `kanban_block`.
#       2 a usage error.
#
# 1 is deliberately NOT used: a blocked PR is a routed outcome, not a failure of
# this script, and a caller running under `set -e` must not treat a bounce as a
# crash.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_URL=""; CHUNK=""; BOARD="${HERMES_KANBAN_BOARD:-}"; REPO=""
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
command -v jq >/dev/null || { echo '{"action":"substrate-block","reason":"jq missing"}'; exit 3; }

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

# An approval is a hand-off to the operator, not an ending. Completing without
# creating anything strands the PR: both cards go `done`, the PR sits at
# REVIEW_REQUIRED, and nothing on the board says a human still owes it a look
# (measured 2026-07-28, first real chunk). The `kanban_create` MCP tool cannot
# express this hand-off — its runtime rejects a missing assignee. The CLI can.
route_tier2() {
  local body="$1" review
  board_live || return 0
  review="$(kanban create "judge: $CHUNK" \
      --assignee forge-operator-handoff \
      --created-by "${HERMES_KANBAN_TASK:-prejudge-review}" \
      --body "$body" --parent "$CHUNK" \
      --idempotency-key "tier2-${HERMES_KANBAN_TASK:-$CHUNK}" \
      --json | jq -er '.id')" || return 1

  # `--initial-status blocked` writes no sticky `blocked` event, so the next
  # dispatcher sweep promotes the card and `kanban.default_assignee` routes it
  # to a real profile — observed twice, once back to the very model that had
  # just approved it. Start on a deliberately non-existent sentinel assignee,
  # block it through the real state transition, then unassign. The read-back
  # fails closed if any of those substrate facts change.
  [ "$(kanban show "$review" --json | jq -r '.task.status')" = "blocked" ] || \
    kanban block --kind needs_input "$review" \
      "tier-2 operator review required: run /judge, then merge or bounce" >/dev/null
  kanban assign "$review" none >/dev/null
  kanban show "$review" --json | jq -e '
    .task.assignee == null and .task.status == "blocked"
    and any(.events[]; .kind == "blocked")' >/dev/null || return 1
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
    || substrate "bounce-workspace: completed chunk has no recorded workspace"
  git -C "$ws" rev-parse --is-inside-work-tree 2>/dev/null | grep -Fxq true \
    || substrate "bounce-workspace: completed chunk has no reusable git worktree"

  fix="$(kanban create "fix: $CHUNK — $why" \
      --assignee forge-codex-lane \
      --created-by "${HERMES_KANBAN_TASK:-prejudge-review}" \
      --body "$PR_URL

Repair this existing PR branch only.

$findings" \
      --parent "$CHUNK" --workspace "$ws" --skill forge-lane \
      --idempotency-key "bounce-${HERMES_KANBAN_TASK:-$CHUNK}" \
      --max-runtime 900 --json | jq -er '.id')" || return 1

  kanban show "$fix" --json | jq -e --arg ws "$ws" '
    .task.workspace_kind == "dir" and .task.workspace_path == $ws
    and (.task.skills | index("forge-lane")) != null' >/dev/null || return 1
  CREATED+=("$fix")
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
  route_bounce "$(jq -r '.checks[] | select(.status=="block")
                  | "- **\(.id)** — \(.evidence)\n  - action: \(.action)"' "$GATE")" \
               "gate blocked: $ids" \
    || substrate "handoff-integrity: fix card could not be created or verified"
  envelope gate-block "gate blocked: $ids" "$GATE" "" 0
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
    || substrate "diff-unavailable: the diff fetch returned nothing usable"
  # A brief plus a contract is ~2 KB before any diff at all, so a prompt that
  # small means the fetch succeeded and returned nothing.
  [ "$(wc -c < "$prompt_file")" -gt 2500 ] \
    || substrate "diff-unavailable: prompt is implausibly small for a PR"
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
[ -n "${verdict:-}" ] \
  || substrate "judge-envelope: claude -p returned no structured verdict"

printf '%s' "$verdict" > "$TMP/verdict.json"

# ---------------------------------------------------------------------------
# Stage 4b — the verdict, DERIVED. Shadow mode: this records, it never routes.
#
# `rubrics/judge-rubric.md` has always stated the verdict logic as four rules
# over the scores, and nothing ever computed them — the model was asked for
# `verdict` beside the scores it also produced, and whatever word came back was
# stored, routed on and counted (audit F29). `scripts/verdict.sh` is those four
# rules as a program.
#
# ROUTING BELOW IS UNCHANGED AND STILL READS `.verdict`, the model's own word.
# The derived value is recorded beside it so the two can be compared over real
# runs. That comparison is the evidence ADR-0009 D9.5 asks for — whether an
# Opus pass told to pass through adds anything a program cannot — and it has to
# be collected before anything acts on it. Same instrument -> shadow -> block
# order the gate itself went through in S1, S3 and S4.
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
# ---------------------------------------------------------------------------
# shellcheck source=scripts/verdict.sh
. "$HERE/verdict.sh"
stamp_shadow_file "$TMP/verdict.json" \
  || echo "shadow: derivation unavailable this run; verdict left untouched" >&2

VERDICT="$(jq -r '.verdict' "$TMP/verdict.json")"
SUMMARY="$(jq -r '"\(.verdict) — \([.findings[]?] | length) finding(s)"' "$TMP/verdict.json")"

# ---------------------------------------------------------------------------
# Stage 5 — route the result to a card something alive will read.
# ---------------------------------------------------------------------------
case "$VERDICT" in
  approve|approve-with-nits)
    route_tier2 "$PR_URL

tier-1 gate: clear — $(jq -r '[.checks[]|select(.status=="warn")|.id]
      | if length==0 then "no warnings" else "warnings: "+join(", ") end' "$GATE")
tier-1 scorer: $VERDICT — scores $(jq -r '.scores
      | "\(.spec_fidelity)/\(.scenario_integrity)/\(.architectural_conformance)"
      + "/\(.scope_discipline)/\(.debt_honesty)/\(.doc_reconciliation)"' "$TMP/verdict.json")
spot-check: $(jq -r '.spot_check_suggestion // "not offered"' "$TMP/verdict.json")
Run /judge, then merge or bounce." \
      || substrate "handoff-integrity: tier-2 card could not be created or verified"
    envelope approve "$SUMMARY" "$TMP/verdict.json" "" 0;;
  bounce)
    route_bounce "$(jq -r '.findings[]? |
        "- **\(.dimension)** (\(.severity)) — \(.evidence)\n  - action: \(.action)"' \
        "$TMP/verdict.json")" \
      "$(jq -r '[.findings[]? | .dimension] | unique | join(", ")' "$TMP/verdict.json")" \
      || substrate "handoff-integrity: fix card could not be created or verified"
    envelope bounce "$SUMMARY" "$TMP/verdict.json" "" 0;;
  *)
    substrate "judge-envelope: verdict was '$VERDICT', not one of the three";;
esac
