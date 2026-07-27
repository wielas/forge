#!/usr/bin/env bash
# =============================================================================
# forge install — make the canonical skills discoverable in every harness
# (ADR-0002). Idempotent; re-run after adding skills. Nothing is copied: every
# harness reads the git checkout, so a `git pull` updates all of them at once.
#
# Two mechanisms, because the harnesses differ:
#   Claude Code / Codex / .agents  → symlinks into their personal skills dirs.
#   Hermes                         → `skills.external_dirs` in each profile's
#                                    config.yaml. NOT symlinks: Hermes runs a
#                                    curator over its own skills dir, and the
#                                    external-dir path is the one it is
#                                    contractually forbidden to touch
#                                    (agent/curator.py: "DO NOT touch bundled,
#                                    hub-installed, or external-dir skills").
#                                    Each Hermes profile is its own HERMES_HOME
#                                    with its own skills tree, so ~/.hermes/skills
#                                    would only reach the DEFAULT profile anyway.
# =============================================================================
set -euo pipefail
FORGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SRC="$FORGE_DIR/skills"

# Harness skill directories (symlink targets).
TARGETS=(
  "$HOME/.claude/skills"        # Claude Code
  "$HOME/.agents/skills"        # shared standard dir (Codex, Gemini CLI, others)
  "$HOME/.codex/skills"         # Codex personal skills
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

# --- Hermes profiles ---------------------------------------------------------
# `hermes config set skills.external_dirs '[...]'` stores the list as a QUOTED
# STRING, which get_external_skills_dirs() then treats as one path, fails to
# stat, and silently skips. So print the block and let the operator paste it —
# same reason profiles-bootstrap.sh does not try to set `toolsets:`.
echo
echo "Hermes profiles read forge skills via skills.external_dirs, not symlinks."
echo "Add this to each forge profile's config.yaml (a real YAML list, by hand):"
echo
echo "  skills:"
echo "    external_dirs:"
echo "      - $SKILLS_SRC"
echo
for p in "$HOME"/.hermes/profiles/forge-*/; do
  [ -d "$p" ] || continue
  name="$(basename "$p")"
  if grep -q 'external_dirs' "$p/config.yaml" 2>/dev/null; then
    echo "  OK      $name already declares external_dirs"
  elif ! grep -qE '^\s+- skills$' "$p/config.yaml" 2>/dev/null; then
    echo "  n/a     $name has no 'skills' toolset — cannot load skills anyway"
  else
    echo "  TODO    $name/config.yaml has no external_dirs"
  fi
done

# Rubrics: skills reference rubrics by repo-relative path; give harnesses a
# stable absolute pointer too.
mkdir -p "$HOME/.forge" && ln -sfn "$FORGE_DIR/rubrics" "$HOME/.forge/rubrics"
ln -sfn "$FORGE_DIR" "$HOME/.forge/repo"

echo
echo "Linked $linked skill symlinks. Next steps:"
echo "  1. Verify discovery:  claude → /skills · codex → /skills"
echo "     and per Hermes profile:  hermes -p forge-codex-lane skills list"
echo "  2. Optional Claude sugar: claude --plugin-dir $FORGE_DIR/adapters/claude/forge-claude-plugin"
echo "  3. Reconcile hermes/config-snippets.yaml into ~/.hermes/config.yaml"
echo "  4. Run the hello-chunk test (README: Day-one risk burn-down)"
