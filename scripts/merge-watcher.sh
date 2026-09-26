#!/usr/bin/env bash
# =============================================================================
# forge merge-watcher — completes the cards whose PR the operator merged.
#
# Recommend-only (ADR-0019 D19.3) leaves a verified chunk card `blocked` with a
# `merge-pending:` reason while the operator merges on GitHub. Something has to
# notice the merge and move the card to `done`, or the chunk never finishes and
# its children never release. That something must not be a model: it makes board
# writes, and "scripts run protocols; models make judgements" is the epic's first
# principle. So it is this script, run by
#
#   hermes cron create '10m' --name forge-merge-watcher --no-agent \
#     --script ~/.hermes/scripts/forge-merge-watcher.sh
#
# `--no-agent` skips the LLM entirely and delivers stdout verbatim; empty stdout
# is silent. `--script` must name a path under `~/.hermes/scripts/`, so the
# operator's step is a SYMLINK there to `~/.forge/repo/scripts/merge-watcher.sh`
# — never to a dev checkout, which is the same trap as P7's.
#
# IT TAKES NO ARGUMENTS FROM CRON, so it cannot require any. `--script` passes a
# path and nothing else, so with no `--board` this sweeps EVERY board
# (`hermes kanban boards list`), which is also what an operator running several
# product boards wants. And nothing but a real finding may reach stdout: under
# `--no-agent` stdout IS the message delivered to the operator, so a usage text or
# a diagnostic printed there would be a notification every ten minutes. Usage and
# every complaint go to stderr; stdout carries card outcomes or nothing.
#
# WHAT IT WILL AND WILL NOT TOUCH.
#   * Only cards it can prove are verifier holds: `blocked`, whose LAST blocked
#     event carries a `merge-pending:` reason. A card blocked for any other
#     reason — a lane's `env:` fault, an operator's own park — is not a hold on
#     a merged PR and completing it would release children onto nothing.
#   * MERGED (read from GitHub, never inferred from the card) -> `complete`,
#     with the merge commit in the result, and the end state read back.
#   * CLOSED WITHOUT MERGING -> reported, never completed. A closed PR means the
#     work was abandoned; `done` would tell the board it landed.
#   * OPEN -> nothing, silently.
#
# `complete` is accepted from `blocked` — measured on the installed kernel
# (`kanban_db.py:2723`, `WHERE status IN ('running','ready','blocked','review')`),
# and executed by `verifier/merge-watcher-completes-a-merged-hold`.
#
# Usage: merge-watcher.sh [--board <slug>] [--dry-run]
# Exit:  0 nothing to do, or everything it did succeeded.
#        1 at least one card it should have completed did not complete.
#        2 a usage error.
#        3 the substrate could not be read at all (no hermes, no gh, no board).
# =============================================================================
set -uo pipefail

BOARD="${HERMES_KANBAN_BOARD:-}"; DRY=0
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --board)   BOARD="${2:?--board needs a slug}"; shift 2;;
    --dry-run) DRY=1; shift;;
    -h|--help) awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; usagetext; exit 2;;
  esac
done
for need in hermes gh jq; do
  command -v "$need" >/dev/null || { echo "merge-watcher: $need is not on PATH" >&2; exit 3; }
done

BOARDS="$BOARD"
if [ -z "$BOARDS" ]; then
  BOARDS="$(hermes kanban boards list --json 2>/dev/null | jq -r '.[]?.slug // empty' 2>/dev/null)"
  [ -n "$BOARDS" ] || BOARDS="$(hermes kanban boards list 2>/dev/null \
    | sed -n 's/^[* ]*\([a-z0-9][a-z0-9_-]*\).*/\1/p')"
  [ -n "$BOARDS" ] || { echo "merge-watcher: no board given and none could be listed" >&2; exit 3; }
fi

rc=0
for BOARD in $BOARDS; do
sweep_board() {
kanban() { hermes kanban --board "$BOARD" "$@"; }
held="$(kanban list --json 2>/dev/null | jq -r '.[]? | select(.status == "blocked") | .id')" \
  || { echo "merge-watcher: cannot read board $BOARD" >&2; return 3; }

for card in $held; do
  meta=""
  shown="$(kanban show "$card" --json 2>/dev/null)" || continue
  # The LAST blocked event decides, not any of them: a card bounced for a
  # substrate fault after a hold is no longer a hold.
  reason="$(printf '%s' "$shown" | jq -r '
    [ .events[]? | select(.kind == "blocked" or .kind == "block_loop_detected") ]
    | last | .payload.reason // ""' 2>/dev/null)"
  # BOTH HOLD CLASSES ARE WATCHABLE. `merge-pending:` is the recommend-only
  # approval. `bounce-budget:` is FL6's exception — and the operator's answer to
  # one is often "I fixed it myself and merged it", which leaves exactly the same
  # merged PR and blocked card. Watching only the first stranded that case: the
  # PR was merged, the card stayed blocked, and its children stayed held.
  case "$reason" in merge-pending:*|bounce-budget:*) ;; *) continue;; esac

  # The PR is read from the lane's own handoff envelope — the one place it is
  # recorded as data rather than as prose in a message.
  pr="$(printf '%s' "$shown" | jq -r '
    [ .runs[]? | select(.outcome == "review_requested")
      | (.metadata.pr // empty) ] | last // ""' 2>/dev/null)"
  [ -n "$pr" ] || pr="$(printf '%s' "$reason" | grep -oE 'https://[^ ]*/pull/[0-9]+' | head -1)"
  [ -n "$pr" ] || { echo "$card: held for merge but no PR url on the card — nothing to watch"; rc=1; continue; }

  state="$(gh pr view "$pr" --json state,mergedAt,mergeCommit < /dev/null 2>/dev/null)" || {
    echo "$card: cannot read $pr from GitHub"; rc=1; continue; }
  case "$(printf '%s' "$state" | jq -r '.state')" in
    MERGED)
      sha="$(printf '%s' "$state" | jq -r '.mergeCommit.oid // "unknown"')"
      [ "$DRY" = 1 ] && { echo "$card: would complete — $pr merged as ${sha:0:12}"; continue; }
      # THE VERDICT RIDES THIS COMPLETION. `block` takes no `--metadata`, so the
      # verifier stashed its envelope as a comment under a stable marker; this is
      # the only write left that can store it, and completing a card with no live
      # claim opens a new `forge-verifier` run for it to land on (measured). A
      # card with no stash still completes — a missing record must not cost a
      # merge — and then nothing counts it, which is what the absence means.
      meta="$(printf '%s' "$shown" | jq -r '
        [ .comments[]? | select(.body | test("^FORGE-VERDICT-V1")) ] | last | .body // ""' 2>/dev/null \
        | sed -n '/^```json$/,/^```$/p' | sed '1d;$d')"
      printf '%s' "$meta" | jq -e 'type == "object"' >/dev/null 2>&1 || meta=""
      if [ -n "$meta" ]; then
        kanban complete "$card" --result "merged: $pr as ${sha:0:12} (completed by merge-watcher)" \
          --metadata "$meta" >/dev/null 2>&1
      else
        kanban complete "$card" --result "merged: $pr as ${sha:0:12} (completed by merge-watcher; NO stored verdict envelope on this card)" >/dev/null 2>&1
      fi
      if [ "$(kanban show "$card" --json 2>/dev/null | jq -r '.task.status')" = done ]; then
        echo "$card: done — $pr merged as ${sha:0:12}"
      else
        echo "$card: $pr is merged but the card did not complete — it needs a look"; rc=1
      fi;;
    CLOSED)
      echo "$card: $pr was CLOSED without merging; the card stays blocked (completing it would tell the board this landed)";;
    *) ;;   # still open: silence is the point of --no-agent
  esac
done
return 0
}
sweep_board || rc=$?
done
exit $rc
