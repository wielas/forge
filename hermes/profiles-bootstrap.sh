#!/usr/bin/env bash
# =============================================================================
# forge profiles bootstrap — create the four forge-* Hermes profiles.
#
# A Hermes profile is a separate HERMES_HOME directory (~/.hermes/profiles/<name>)
# with its own config.yaml, .env, SOUL.md, skills, memory and cron. It is NOT an
# entry in a `profiles:` block — see hermes/config-snippets.yaml.
#
# Idempotent: re-running skips existing profiles and only rewrites SOUL.md.
# Run ON THE MINI.  ./hermes/profiles-bootstrap.sh [--dry-run]
#
# WHY least privilege: the dispatcher spawns these unattended. A profile with no
# terminal tool cannot implement, cannot push, and cannot spend, no matter what a
# card body talks it into.
# =============================================================================
set -uo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Dry-run output must be copy-pasteable, so quote it properly rather than
# printing "$*" and losing the argument boundaries.
run() {
  if [ "$DRY" = 1 ]; then
    printf '  + '; printf '%q ' "$@"; printf '\n'
  else
    "$@"
  fi
}

# Model pins. The lane and prejudge models only DRIVE codex — the reasoning
# happens inside Codex — so cheap and fast is correct, not a compromise.
# Confirm current ids against `hermes model` / OpenRouter before trusting these.
MODEL_ROUTER="${FORGE_MODEL_ROUTER:-}"      # orchestrator: decomposition quality matters
MODEL_DRIVER="${FORGE_MODEL_DRIVER:-}"      # lane + prejudge + digest: shell driver only

# name | description (feeds kanban orchestrator routing) | core toolsets
#
# TOOLSET NAMES ARE NOT FREE TEXT. Every entry must be a real toolset — check
# with `python -c 'import toolsets; print(toolsets.get_toolset_names())'` in the
# hermes venv. An unknown name resolves to ZERO tools, silently: `toolsets:
# [forge]` with a `custom_toolsets:` block gave all four profiles no tools at
# all on 0.19.0, because nothing in the code reads `custom_toolsets` (it is
# documented in website/docs/reference/toolsets-reference.md but unimplemented).
# `messaging` is likewise not a toolset; the gateway platforms carry those tools.
PROFILES=(
  "forge-orchestrator|Routes forge work: decomposes chunks, links dependencies, assigns lanes. Never implements.|kanban,memory,skills"
  "forge-codex-lane|Implements one chunk contract by driving codex exec in a git worktree, verifies make check, opens the PR.|terminal,file,kanban,memory,skills"
  "forge-prejudge|Tier-1 PR filter: bounces ci-red, scenario theater and scope creep. Reads diffs, never edits code.|terminal,kanban,memory,skills"
  "forge-digest|Reads the forge boards and sends one short daily status message. Read-only.|kanban,memory"
)

for spec in "${PROFILES[@]}"; do
  IFS='|' read -r name desc tools <<< "$spec"
  echo "── $name"

  if [ -d "$HOME/.hermes/profiles/$name" ]; then
    echo "  exists, skipping create"
  else
    run hermes profile create "$name" --description "$desc"
  fi

  # SOUL.md is the profile's identity slot. Rewriting it is safe and idempotent;
  # it takes effect on the profile's next session.
  soul="$HERE/profiles/$name.SOUL.md"
  dest="$HOME/.hermes/profiles/$name/SOUL.md"
  if [ -f "$soul" ]; then
    if [ "$DRY" = 1 ]; then echo "  + cp $soul -> $dest"; else cp "$soul" "$dest"; fi
  else
    echo "  WARN no SOUL file at $soul"
  fi

  # Scalar settings via the CLI (routes to config.yaml, no hand-editing).
  case "$name" in
    forge-orchestrator) m="$MODEL_ROUTER";;
    *)                  m="$MODEL_DRIVER";;
  esac
  [ -n "$m" ] && run hermes -p "$name" config set model.default "$m"

  # Toolsets are a list, so `config set` is the wrong tool. Emit the exact block
  # instead of guessing — paste it into the profile's config.yaml. ONE REAL
  # TOOLSET NAME PER LINE; see the warning above the PROFILES table.
  cfg="$HOME/.hermes/profiles/$name/config.yaml"
  if [ -f "$cfg" ] && grep -qE '^toolsets:' "$cfg" 2>/dev/null; then
    echo "  toolsets already present in $cfg — check it matches:"
  else
    echo "  ADD to $cfg :"
  fi
  echo "      toolsets:"
  printf '        - %s\n' ${tools//,/ }
done

cat <<'EOF'

── verify
  hermes profile list
  hermes kanban assignees          # every forge-* name must appear here BEFORE
                                   # any card is assigned to it. An unknown
                                   # assignee is NOT an error: the card sits in
                                   # `ready` forever with a skipped_nonspawnable
                                   # event, and only surfaces ~30 min later in
                                   # `hermes kanban diagnostics` as stranded.

── the lane profiles also need, in ~/.hermes/.env (the gateway injects it):
  CLAUDE_CODE_OAUTH_TOKEN=...      # subscription auth, keychain-independent
  GH_TOKEN=...                     # only if `gh auth login` state is not inherited

── and in the DEFAULT profile's config.yaml (see hermes/config-snippets.yaml):
  approvals.mode: smart            # `manual` hangs an unattended worker forever
  skills.write_approval: true      # L5's consent gate
EOF
