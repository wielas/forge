#!/usr/bin/env bash
# =============================================================================
# forge board bootstrap
#   board-bootstrap.sh <project>            init board + load docs/chunks/* cards
#   board-bootstrap.sh <project> --hello    init board + ONE hello-chunk card
#                                           (the day-one risk burn-down test)
# Run from the project repo root. Hermes CLI flags marked VERIFY (ADR-0005).
# =============================================================================
set -euo pipefail
PROJECT="${1:?usage: board-bootstrap.sh <project> [--hello]}"
MODE="${2:-full}"

hermes kanban init 2>/dev/null || true      # idempotent

create_card() {  # $1=title $2=bodyfile $3=assignee
  # VERIFY: exact create flags (`hermes kanban create --help`)
  hermes kanban create "$1" --tenant "$PROJECT" --assignee "$3" \
    --body-file "$2" \
    || hermes kanban create "$1" --tenant "$PROJECT" --assignee "$3" \
         --body "$(cat "$2")"
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
- **Lane:** codex-worker · **Risk:** low
EOF
  create_card "CHUNK-HELLO-1: Add greet(name) with a BDD scenario" "$tmp" "codex-worker"
  rm -f "$tmp"
  echo "hello card created. Now run in the foreground and watch every step:"
  echo "  FORGE_PROJECT=$PROJECT FORGE_REPO_DIR=\$(pwd) ../forge/lanes/codex-worker.sh --once --verbose"
  exit 0
fi

# full mode: one card per chunk contract emitted by /roadmap
shopt -s nullglob
chunks=(docs/chunks/CHUNK-*.md)
[ ${#chunks[@]} -gt 0 ] || { echo "no docs/chunks/CHUNK-*.md found — run /roadmap first"; exit 1; }

for f in "${chunks[@]}"; do
  id=$(basename "$f" .md)
  title=$(head -1 "$f" | sed 's/^#* *//')
  lane=$(grep -oE 'Lane:\*?\*? *(codex-worker|claude-interactive)' "$f" | awk '{print $NF}' | head -1)
  create_card "${title:-$id}" "$f" "${lane:-codex-worker}"
done

echo "cards created. Now express the dependency graph:"
echo "  VERIFY link syntax: hermes kanban link <child> --parent <parent>"
echo "(Dependencies are listed in each chunk's 'Depends on' line — the /roadmap"
echo " skill prints the exact link commands; paste them here.)"
