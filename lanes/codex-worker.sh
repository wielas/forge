#!/usr/bin/env bash
# =============================================================================
# forge lane A: codex-worker
# Polls a Hermes kanban board for ready cards assigned to $ASSIGNEE, implements
# each in an isolated git worktree via `codex exec` (start-chunk → end-chunk),
# verifies green, ensures a PR exists, and completes the card with structured
# metadata (rubrics/kanban-metadata-schema.md).
#
# Run from cron/launchd on the mini:   codex-worker.sh --once
# Foreground debugging (hello-chunk):  codex-worker.sh --once --verbose
#
# DESIGN NOTE (ADR-0004): this lane uses Codex plan auth, which works headless.
# Never point this runner at Claude subscription auth.
#
# DESIGN NOTE (ADR-0005): ALL board I/O is isolated in the four board_*
# functions below. Hermes CLI flags are marked VERIFY — reconcile against
# `hermes kanban --help` on your install, edit ONLY those functions.
# =============================================================================
set -euo pipefail

# ---- config (env-overridable) ----------------------------------------------
ASSIGNEE="${FORGE_ASSIGNEE:-codex-worker}"
PROJECT="${FORGE_PROJECT:?set FORGE_PROJECT (kanban tenant / board)}"
REPO_DIR="${FORGE_REPO_DIR:?set FORGE_REPO_DIR (main checkout path)}"
WT_ROOT="${FORGE_WORKTREES:-$HOME/forge-worktrees}"
LOCKFILE="${FORGE_LOCK:-/tmp/forge-codex-worker-$PROJECT.lock}"
CHUNK_TIMEOUT="${FORGE_CHUNK_TIMEOUT:-3600}"          # seconds per chunk
CODEX_BIN="${FORGE_CODEX_BIN:-codex}"
MODEL_FLAG="${FORGE_CODEX_MODEL_FLAG:-}"              # e.g. "--model gpt-x-mini"
VERBOSE=0; ONCE=0
for a in "$@"; do case "$a" in --once) ONCE=1;; --verbose) VERBOSE=1;; esac; done
log() { echo "[$(date +%H:%M:%S)] $*"; }
vlog() { [ "$VERBOSE" = 1 ] && log "$@" || true; }

# ---- board adapter (EDIT ONLY HERE when Hermes CLI differs) ------------------
board_list_ready() {   # -> lines: "<card_id>\t<title>"
  # VERIFY: exact list flags & JSON shape (`hermes kanban list --help`)
  hermes kanban list --tenant "$PROJECT" --assignee "$ASSIGNEE" \
    --status ready --json \
    | jq -r '.[] | [.id, .title] | @tsv'
}
board_claim() {        # $1=card_id  — mark running so parallel runners skip it
  # VERIFY: external lanes may claim via a status command or comment convention
  hermes kanban start "$1" 2>/dev/null \
    || hermes kanban comment "$1" "claimed by codex-worker on $(hostname)"
}
board_complete() {     # $1=card_id $2=summary $3=metadata_json_file
  hermes kanban complete "$1" --summary "$2" --metadata-file "$3" \
    || hermes kanban complete "$1" --summary "$2 | metadata: $(cat "$3")"
}
board_block() {        # $1=card_id $2=reason
  hermes kanban block "$1" --reason "$2" \
    || hermes kanban comment "$1" "BLOCKED: $2"
}
board_card_body() {    # $1=card_id -> chunk contract markdown on stdout
  # VERIFY: field name for body in `hermes kanban show --json`
  hermes kanban show "$1" --json | jq -r '.body // .description // empty'
}

# ---- helpers -----------------------------------------------------------------
extract_metadata() {   # scrape FORGE_METADATA markers from worker log -> file
  awk '/FORGE_METADATA_BEGIN/{f=1;next}/FORGE_METADATA_END/{f=0}f' "$1"
}

run_one_card() {
  local card_id="$1" title="$2"
  local chunk_id; chunk_id=$(echo "$title" | grep -oE 'CHUNK-[A-Za-z0-9_-]+' || echo "$card_id")
  local slug; slug=$(echo "$title" | sed 's/^CHUNK-[^:]*: *//' | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-' | cut -c1-30)
  local branch="chunk/${chunk_id#CHUNK-}-${slug:-work}"
  local wt="$WT_ROOT/$PROJECT/$chunk_id"
  local logf="$wt.log" metaf="$wt.meta.json"

  log "▶ $chunk_id ($card_id): $title"
  board_claim "$card_id"

  # -- isolated worktree, fresh from main --
  git -C "$REPO_DIR" fetch origin
  git -C "$REPO_DIR" worktree add -B "$branch" "$wt" origin/main
  board_card_body "$card_id" > "$wt/.forge-card.md"

  # -- drive codex through the ceremony (skills discovered via ~/.codex/skills) --
  local prompt="You are the unattended forge worker. The chunk contract is in
.forge-card.md. Execute the start-chunk skill for ${chunk_id}, then the
end-chunk skill. Repo conventions: AGENTS.md. You MUST finish with 'make check'
green, push branch ${branch}, open a PR with gh, and print the forge.chunk.v1
metadata JSON between FORGE_METADATA_BEGIN and FORGE_METADATA_END markers.
If the contract is stale or contradictory: print FORGE_BLOCKED: <reason> and stop."

  local rc=0
  # VERIFY: codex non-interactive invocation & approval flags for your version
  ( cd "$wt" && timeout "$CHUNK_TIMEOUT" \
      "$CODEX_BIN" exec $MODEL_FLAG --full-auto "$prompt" ) >"$logf" 2>&1 || rc=$?

  # -- blocked by worker? --
  if grep -q '^FORGE_BLOCKED:' "$logf"; then
    board_block "$card_id" "$(grep -m1 '^FORGE_BLOCKED:' "$logf" | cut -d' ' -f2-)"
    log "⛔ $chunk_id blocked by worker"; return 0
  fi
  if [ "$rc" -ne 0 ]; then
    board_block "$card_id" "worker exited rc=$rc (timeout=$CHUNK_TIMEOUT); log: $logf"
    log "⛔ $chunk_id failed rc=$rc"; return 0
  fi

  # -- trust but verify: green proof re-run by the runner itself --
  if ! ( cd "$wt" && make check ) >>"$logf" 2>&1; then
    board_block "$card_id" "runner re-check failed; see $logf"
    log "⛔ $chunk_id re-check red"; return 0
  fi

  # -- ensure branch pushed + PR exists (idempotent belt & suspenders) --
  ( cd "$wt" && git push -u origin "$branch" ) >>"$logf" 2>&1 || true
  local pr_url
  pr_url=$( cd "$wt" && gh pr view --json url -q .url 2>/dev/null ) || \
  pr_url=$( cd "$wt" && gh pr create --fill --title "$title" 2>/dev/null | tail -1 ) || pr_url=""

  # -- metadata + completion --
  extract_metadata "$logf" > "$metaf"
  if ! jq -e .chunk_id "$metaf" >/dev/null 2>&1; then
    printf '{"schema":"forge.chunk.v1","chunk_id":"%s","branch":"%s","pr":"%s","lane":"codex-worker","note":"metadata reconstructed by runner"}\n' \
      "$chunk_id" "$branch" "$pr_url" > "$metaf"
  fi
  board_complete "$card_id" "$chunk_id green; PR: ${pr_url:-unknown}" "$metaf"
  git -C "$REPO_DIR" worktree remove "$wt" --force || true
  log "✅ $chunk_id done → ${pr_url:-no-pr-url}"
}

# ---- main loop ----------------------------------------------------------------
exec 9>"$LOCKFILE"; flock -n 9 || { vlog "another runner active, exiting"; exit 0; }
mkdir -p "$WT_ROOT/$PROJECT"

while :; do
  ready=$(board_list_ready || true)
  if [ -z "$ready" ]; then vlog "no ready cards"; [ "$ONCE" = 1 ] && exit 0; sleep 60; continue; fi
  while IFS=$'\t' read -r cid ctitle; do
    [ -n "$cid" ] && run_one_card "$cid" "$ctitle"
  done <<< "$ready"
  [ "$ONCE" = 1 ] && exit 0
  sleep 15
done
