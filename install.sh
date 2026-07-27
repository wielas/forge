#!/usr/bin/env bash
# =============================================================================
# forge install — symlink the canonical skills into every harness (ADR-0002).
# Idempotent; re-run after adding skills. Symlinks mean a `git pull` in the
# forge repo updates every harness instantly.
# =============================================================================
set -euo pipefail
FORGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SRC="$FORGE_DIR/skills"

# Harness skill directories. VERIFY the Hermes path on your install
# (`hermes skills list` shows where it reads from).
TARGETS=(
  "$HOME/.claude/skills"        # Claude Code
  "$HOME/.agents/skills"        # shared standard dir (Codex, Gemini CLI, others)
  "$HOME/.codex/skills"         # Codex personal skills
  "${HERMES_SKILLS_DIR:-$HOME/.hermes/skills}"   # Hermes — VERIFY
)

linked=0
for target in "${TARGETS[@]}"; do
  mkdir -p "$target"
  for skill in "$SKILLS_SRC"/*/; do
    name="$(basename "$skill")"
    dest="$target/$name"
    if [ -L "$dest" ]; then
      ln -sfn "${skill%/}" "$dest"
    elif [ -e "$dest" ]; then
      echo "SKIP  $dest exists and is not a symlink (resolve manually)"; continue
    else
      ln -s "${skill%/}" "$dest"
    fi
    linked=$((linked+1))
  done
  echo "OK    $target"
done

# Rubrics: skills reference rubrics by repo-relative path; give harnesses a
# stable absolute pointer too.
mkdir -p "$HOME/.forge" && ln -sfn "$FORGE_DIR/rubrics" "$HOME/.forge/rubrics"
ln -sfn "$FORGE_DIR" "$HOME/.forge/repo"

echo
echo "Linked $linked skill symlinks. Next steps:"
echo "  1. Verify discovery:  claude → /skills · codex → /skills · hermes skills list"
echo "  2. Optional Claude sugar: claude --plugin-dir $FORGE_DIR/adapters/claude/forge-claude-plugin"
echo "  3. Reconcile hermes/config-snippets.yaml into ~/.hermes/config.yaml"
echo "  4. Run the hello-chunk test (README: Day-one risk burn-down)"
