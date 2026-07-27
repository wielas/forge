#!/usr/bin/env bash
# =============================================================================
# forge board bootstrap
#   board-bootstrap.sh <board>            init board + load docs/chunks/* cards
#   board-bootstrap.sh <board> --hello    init board + ONE hello-chunk card
#                                         (the day-one risk burn-down test)
# Run from the project repo root.
#
# Every flag below was verified against `hermes kanban create --help` on 0.19.0
# (preflight §5). The four that are load-bearing, and what breaks without them:
#   --board       belongs to the KANBAN parser, not to `create`:
#                 `hermes kanban --board <slug> create …`. After the subcommand
#                 it is an unrecognized argument. Board resolution otherwise
#                 falls back to HERMES_KANBAN_BOARD, then the PERSISTED CURRENT
#                 board — `digest` today. We pin both, belt and braces.
#   --workspace   `scratch` (the default) is DELETED on completion. A chunk card
#                 must be `worktree`, which is also preserved afterwards.
#   --assignee    must name a real Hermes profile. An unknown assignee is not an
#                 error: the card sits in `ready` forever with a
#                 skipped_nonspawnable event, visible only via `kanban
#                 diagnostics` half an hour later.
#   --idempotency-key   re-running this script must not duplicate cards.
# There is NO --body-file. Pass file contents with --body "$(cat f)".
# =============================================================================
set -euo pipefail
BOARD="${1:?usage: board-bootstrap.sh <board> [--hello]}"
MODE="${2:-full}"
LANE_ASSIGNEE="${FORGE_LANE_ASSIGNEE:-forge-codex-lane}"

# Pin the board for every hermes call in this script AND for anything it spawns.
# This is the same mechanism `--board` uses internally (it sets this var for the
# duration of the call), so the two can never disagree.
export HERMES_KANBAN_BOARD="$BOARD"

hermes kanban init 2>/dev/null || true      # idempotent
hermes kanban boards create "$BOARD" 2>/dev/null || true   # `boards` ignores --board

# A `--workspace worktree` card with no explicit workspace_path anchors on the
# BOARD's default_workdir. Unset, `_resolve_worktree_workspace` raises; the
# dispatcher catches that into _record_spawn_failure, and with --max-retries 1
# below the first card auto-blocks on tick 1 — no worker output, no obvious
# cause. Set it here and read it back; `boards create` above is a no-op when the
# board already exists, so the flag on `create` cannot be relied on.
REPO_ROOT="$(git rev-parse --show-toplevel)"
hermes kanban boards set-default-workdir "$BOARD" "$REPO_ROOT"
readback=$(hermes kanban boards list --json \
  | jq -r --arg b "$BOARD" '.[]|select(.slug==$b)|.default_workdir // "null"')
if [ "$readback" != "$REPO_ROOT" ]; then
  echo "FATAL: board '$BOARD' default_workdir is '$readback', expected" >&2
  echo "       '$REPO_ROOT'. Worktree cards would auto-block on tick 1." >&2
  exit 1
fi
echo "board '$BOARD' default_workdir = $readback"

# Fail loudly HERE rather than stranding a card an hour from now.
if ! hermes kanban assignees 2>/dev/null | grep -q "$LANE_ASSIGNEE"; then
  echo "FATAL: '$LANE_ASSIGNEE' is not a known assignee. Run" >&2
  echo "       ./hermes/profiles-bootstrap.sh first, then re-run this." >&2
  exit 1
fi

create_card() {  # $1=title $2=bodyfile $3=assignee $4=idempotency-key $5=branch
  hermes kanban --board "$BOARD" create "$1" \
    --assignee "$3" \
    --body "$(cat "$2")" \
    --workspace worktree \
    --branch "$5" \
    --max-retries 1 \
    --idempotency-key "$4" \
    --skill forge-lane
}

if [ "$MODE" = "--hello" ]; then
  tmp=$(mktemp)
  cat > "$tmp" << 'EOF'
### CHUNK-HELLO-1: Add greet(name) with a BDD scenario
- **Goal:** Prove the full lane end-to-end with a trivially small chunk.
- **Milestone:** M0 · **Depends on:** none
- **Serves:** none (infrastructure test) · **Relevant ADRs:** none
- **Touches:** src/<package>/greet.py, tests/features/chunk_hello_1.feature, tests/steps/
- **Scenarios:**
  - Given the package is installed, When I greet "Forge", Then I get "Hello, Forge!"
- **Out of scope:** anything else. Literally anything.
- **Done when:** make check green + scenario passes + PR open
- **Lane:** forge-codex-lane · **Risk:** low
EOF
  create_card "CHUNK-HELLO-1: Add greet(name) with a BDD scenario" \
              "$tmp" "$LANE_ASSIGNEE" "hello-1" "chunk/hello-1-greet"
  rm -f "$tmp"
  echo "hello card created on board '$BOARD'. Watch every step:"
  echo "  hermes kanban --board $BOARD watch"
  echo "  hermes kanban --board $BOARD tail <task-id>   # live worker output"
  exit 0
fi

# full mode: one card per chunk contract emitted by /roadmap
shopt -s nullglob
chunks=(docs/chunks/CHUNK-*.md)
[ ${#chunks[@]} -gt 0 ] || { echo "no docs/chunks/CHUNK-*.md found — run /roadmap first"; exit 1; }

for f in "${chunks[@]}"; do
  id=$(basename "$f" .md)
  title=$(head -1 "$f" | sed 's/^#* *//')
  lane=$(grep -oE 'Lane:\*?\*? *(forge-codex-lane|claude-interactive)' "$f" \
         | awk '{print $NF}' | head -1)
  # claude-interactive chunks are for a human at a keyboard — no card is
  # dispatched for them; they would strand exactly like a typo'd assignee.
  if [ "${lane:-$LANE_ASSIGNEE}" = "claude-interactive" ]; then
    echo "skip  $id (Lane: claude-interactive — run /start-chunk yourself)"
    continue
  fi
  slug=$(printf '%s' "$id" | tr 'A-Z' 'a-z')
  create_card "${title:-$id}" "$f" "${lane:-$LANE_ASSIGNEE}" \
              "$BOARD-$id" "chunk/${slug#chunk-}"
done

echo "cards created on board '$BOARD'. Now express the dependency graph:"
echo "  hermes kanban --board $BOARD link <parent-id> <child-id>   # positional, in that order"
echo "(Dependencies are listed in each chunk's 'Depends on' line — the /roadmap"
echo " skill prints the exact link commands; paste them here.)"
