#!/usr/bin/env bash
# =============================================================================
# forge profiles bootstrap — create AND fully configure the four forge-* Hermes
# profiles, reproducibly, from this file alone.
#
# A Hermes profile is a separate HERMES_HOME directory (<root>/profiles/<name>)
# with its own config.yaml, .env, SOUL.md, skills, memory and cron. It is NOT an
# entry in a `profiles:` block — see hermes/config-examples.yaml.
#
# TOTAL, not partial. This script writes every key the runtime depends on and
# then READS EACH ONE BACK, failing if the readback disagrees. That is the whole
# point: a system whose live configuration cannot be rebuilt from version
# control is not self-upgrading, it is hand-tuned with documentation attached.
# Nothing here is "paste this yourself".
#
# Idempotent: safe to re-run. config.yaml is rewritten from the template below
# every time, so drift is corrected rather than accumulated. Hand edits to a
# forge-* config.yaml will be overwritten — change this file instead.
#
#   ./hermes/profiles-bootstrap.sh [--dry-run]
#
# Rebuild-from-scratch test (this is the F7 assertion — run it after any edit):
#   HERMES_HOME=/tmp/scratch-hermes ./hermes/profiles-bootstrap.sh
#   diff <(cat /tmp/scratch-hermes/profiles/forge-codex-lane/config.yaml) \
#        <(cat ~/.hermes/profiles/forge-codex-lane/config.yaml)
#
# WHY least privilege: the dispatcher spawns these unattended. A profile with no
# terminal tool cannot implement, cannot push, and cannot spend, no matter what a
# card body talks it into.
# =============================================================================
set -euo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FORGE_DIR="$(cd "$HERE/.." && pwd)"

# The profile root. Hermes resolves <root>/profiles/<name>; pointing HERMES_HOME
# at a scratch directory outside ~/.hermes makes that scratch dir the root, which
# is how the rebuild test above works.
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"

run() {
  if [ "$DRY" = 1 ]; then
    printf '  + '; printf '%q ' "$@"; printf '\n'
  else
    "$@"
  fi
}

# Model pins. The lane, prejudge and digest models only DRIVE another agent —
# the reasoning happens inside Codex — so cheap and fast is correct, not a
# compromise. These defaults are the live values as of 2026-07-27; they are
# checked in precisely so a rebuild reproduces the running system. Confirm ids
# against `hermes model` / OpenRouter before bumping them.
MODEL_ROUTER="${FORGE_MODEL_ROUTER:-z-ai/glm-5.2}"        # orchestrator: decomposition quality matters
MODEL_DRIVER="${FORGE_MODEL_DRIVER:-deepseek/deepseek-v4-flash-0731}"  # lane + prejudge + digest: shell driver only

# `codex exec` and `make check` run SYNCHRONOUSLY inside a worker. The 180s
# stock default kills the lane at `make check` — after the code is written and
# before it is verified, the most expensive possible place to fail.
TERMINAL_TIMEOUT=1800

# Which skills each profile may load. This is an ALLOWLIST, and it is the only
# list that is hand-maintained: `disabled_skills_for` derives its complement
# from what is actually installed, so a name that is not here is disabled.
#
# WHY: external_dirs exposes the whole skills/ tree, so all eight ceremonies were
# live in every profile — including start-chunk (which branches) and end-chunk
# (which pushes and opens a PR), both of which duplicate what forge-lane already
# does and collide with the Hermes worker lifecycle. Auto-invocation in the wrong
# layer branches, pushes, or completes twice.
#
# The control is Hermes-side on purpose. `disable-model-invocation` is a
# Claude-Code-only frontmatter key and ADR-0002 commits the portable skill core
# to `name` + `description` only; using it would break a recorded decision to fix
# a Hermes problem. `skills.disabled` is a per-profile YAML list read by
# hermes_cli/skills_config.py, and card-level `--skill forge-lane` force-loading
# is the second half of the same mechanism.
#
# WHY AN ALLOWLIST AND NOT A LONGER DENYLIST: Hermes has no `skills.enabled`
# key — `skills.disabled` is the only lever, and it matches by NAME with no
# regard for source (`get_disabled_skills` in hermes_cli/skills_config.py,
# `get_disabled_skill_names` in agent/skill_utils.py), so a builtin is as
# disableable as a forge skill. Naming the handful of builtins that bother us
# today re-breaks on every Hermes update, because new builtins arrive enabled.
# Enumerating the installed set and subtracting this allowlist does not.
#
# The interactive ceremonies (scope, architect, start-chunk, end-chunk, judge,
# retro) belong to Claude Code reading this repo directly — not to any unattended
# profile.
skills_allowed_for() {  # $1=profile -> space-separated skill names, or empty
  case "$1" in
    forge-codex-lane)   echo "forge-lane";;
    forge-orchestrator) echo "roadmap";;
    *)                  echo "";;
  esac
}

# name | description (feeds kanban orchestrator routing) | core toolsets
#
# TOOLSET NAMES ARE NOT FREE TEXT. Every entry must be a real toolset — check
# with `python -c 'import toolsets; print(toolsets.get_toolset_names())'` in the
# hermes venv. An unknown name resolves to ZERO tools, silently: `toolsets:
# [forge]` with a `custom_toolsets:` block gave all four profiles no tools at
# all on 0.19.0, because nothing in the code reads `custom_toolsets` (it is
# documented in website/docs/reference/toolsets-reference.md but unimplemented).
# `messaging` is likewise not a toolset; the gateway platforms carry those tools.
#
# The 0.19.0 line above is a DATED MEASUREMENT and stays as it was taken. Its
# cause was re-checked against the installed 0.20.4 (2026.8.18) on 2026-08-18
# and still holds: `custom_toolsets` appears nowhere in the Python tree — only
# in website/docs/reference/toolsets-reference.md and its zh-Hans translation.
# Documented, unimplemented, two minor versions later.
PROFILES=(
  "forge-orchestrator|Routes forge work: decomposes chunks, links dependencies, assigns lanes. Never implements.|kanban,memory,skills"
  "forge-codex-lane|Implements one chunk contract by driving codex exec in a git worktree, verifies make check, opens the PR.|terminal,file,kanban,memory,skills"
  "forge-prejudge|Tier-1 PR filter: bounces ci-red, scenario theater and scope creep. Reads diffs, never edits code.|terminal,kanban,memory,skills"
  "forge-digest|Reads the forge boards and sends one short daily status message. Read-only.|kanban,memory"
)

# Keys this script owns end to end. Every one is written by write_config and
# then verified by verify_config — if you add a key to the template, add it
# here or it is not actually guaranteed.
VERIFIED_KEYS=(model.default toolsets skills.external_dirs skills.disabled skills.write_approval terminal.timeout)

# `hermes config set` provably cannot write a YAML list — it stores it as a
# quoted string and the value is then silently ignored (see
# docs/hermes-field-notes.md). So the file is the interface, not the CLI.
write_config() {  # $1=name $2=model $3=toolsets $4=dest $5=disabled skill names
  local name="$1" model="$2" tools="$3" dest="$4" disabled="$5"
  {
    echo "# GENERATED by hermes/profiles-bootstrap.sh — do not hand-edit."
    echo "# Profile: $name. Edit the script and re-run; this file is overwritten."
    echo "model:"
    echo "  default: $model"
    echo "toolsets:"
    printf '  - %s\n' ${tools//,/ }
    echo "skills:"
    echo "  # ADR-0013: Hermes cannot disable skill_manage separately from"
    echo "  # the skills toolset. Profiles retaining it may stage a skill edit,"
    echo "  # but write approval prevents it taking effect unattended."
    echo "  write_approval: true"
    echo "  # Forge methodology skills stay in git and are read from the"
    echo "  # checkout. The curator never touches external-dir skills, so"
    echo "  # nothing drifts out of version control."
    echo "  external_dirs:"
    echo "    - $FORGE_DIR/skills"
    echo "  # An ALLOWLIST expressed as a denylist, because Hermes has no"
    echo "  # skills.enabled key. This is EVERY skill that was installed for"
    echo "  # this profile when the file was generated, minus the ones"
    echo "  # skills_allowed_for() names — builtins included, enumerated from"
    echo "  # 'hermes -p $name skills list', not from the forge checkout."
    echo "  #"
    echo "  # It is a SNAPSHOT, not a standing guarantee. A skill that arrives"
    echo "  # after generation — a builtin from a Hermes update, a hub install,"
    echo "  # a project-local skill in a trusted repo — is absent from this list"
    echo "  # and therefore ENABLED until this bootstrap is re-run. That gap is"
    echo "  # what scripts/preflight.sh section 9 WARNs about; the WARN is the"
    echo "  # signal to re-run, not a fault in the file."
    echo "  #"
    echo "  # sdlc-review is the one name here that costs something. Review"
    echo "  # dispatch force-loads it into the worker's --skills (the review"
    echo "  # loop in hermes_cli/kanban_db.py), and skills.disabled BEATS that"
    echo "  # force-load: build_preloaded_skills_prompt in"
    echo "  # agent/skill_commands.py applies the disabled set to --skills"
    echo "  # preloading and treats a disabled skill as missing. Under forge's"
    echo "  # current model an implementation card completes and a pre-created"
    echo "  # child card carries review, so forge never enters the review lane"
    echo "  # and disabling it here is correct. ANY profile forge ever wants to"
    echo "  # REVIEW with must add sdlc-review to skills_allowed_for(), or"
    echo "  # review dispatch spawns a reviewer with nothing to review by."
    echo "  disabled:"
    printf '    - %s\n' $disabled
    echo "terminal:"
    echo "  timeout: $TERMINAL_TIMEOUT"
  } > "$dest"
}

# A silently EMPTY enumeration would enable everything, which is worse than the
# defect this replaced, so a result smaller than this is treated as a broken
# parse rather than as a minimal machine. Every profile Hermes creates is seeded
# with dozens of bundled skills; a single-digit answer has never been real.
MIN_INSTALLED_SKILLS="${FORGE_MIN_INSTALLED_SKILLS:-20}"

# Every skill name the profile's runtime can see, whatever its source: bundled
# builtins seeded into <profile>/skills, hub installs, and skills.external_dirs.
# The CLI is the authority, not a directory walk — the on-disk tree nests
# categories, carries a .hub/ area and non-skill subdirectories, and the same
# name can resolve from more than one place. `skills list` also lists DISABLED
# skills, so re-running this script re-enumerates the set it last disabled
# instead of shrinking to the survivors.
#
# Prints one name per line. Returns NON-ZERO and says why on any failure —
# never an empty list on stdout with a zero status.
installed_skills_for() {  # $1=profile
  local prof="$1" raw rows names n_rows n_names
  if ! command -v hermes >/dev/null 2>&1; then
    echo "  skill enumeration: 'hermes' is not on PATH" >&2; return 1
  fi
  if [ ! -d "$HERMES_ROOT/profiles/$prof" ]; then
    echo "  skill enumeration: profile '$prof' does not exist at" >&2
    echo "    $HERMES_ROOT/profiles/$prof — it must be created before its" >&2
    echo "    installed set can be read (--dry-run cannot create it)." >&2
    return 1
  fi
  # COLUMNS is passed through `env`, not left to the tty: the table truncates
  # the Name column to the terminal width, and a truncated name like
  # `songwriting-and-ai-mu…` disables nothing while still counting as a row.
  if ! raw="$(env COLUMNS=400 hermes -p "$prof" skills list 2>/dev/null)"; then
    echo "  skill enumeration: 'hermes -p $prof skills list' failed" >&2; return 1
  fi
  # Body rows are delimited by U+2502; the header rule uses U+2503, so it drops
  # out on the field count alone. The guard on 'Name' is belt and braces.
  rows="$(printf '%s\n' "$raw" \
          | awk -F'│' 'NF>=6 && $2 !~ /^[[:space:]]*Name[[:space:]]*$/ {print $2}')"
  n_rows="$(printf '%s\n' "$rows" | awk 'NF{c++} END{print c+0}')"
  names="$(printf '%s\n' "$rows" \
           | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/,""); if ($0 ~ /^[A-Za-z0-9._-]+$/) print}')"
  n_names="$(printf '%s\n' "$names" | awk 'NF{c++} END{print c+0}')"
  if [ "$n_rows" != "$n_names" ]; then
    echo "  skill enumeration: parsed $n_names names from $n_rows rows for" >&2
    echo "    '$prof' — a dropped or truncated name silently stays ENABLED." >&2
    return 1
  fi
  if [ "$n_names" -lt "$MIN_INSTALLED_SKILLS" ]; then
    echo "  skill enumeration: only $n_names skills for '$prof' (floor" >&2
    echo "    $MIN_INSTALLED_SKILLS) — refusing to write a list that would" >&2
    echo "    leave the rest enabled. Check 'hermes -p $prof skills list'." >&2
    return 1
  fi
  printf '%s\n' "$names"
}

# The installed set UNION the checkout's skills, minus the ones this profile may
# load. The union matters on a first run: external_dirs is not in the config
# yet, so the forge skills are not installed yet either, and only the checkout
# knows their names.
#
# Enumerated PER PROFILE, not once. The four forge-* profiles do currently hold
# identical sets, but the DEFAULT profile does not — measured 2026-08-18, it
# differs from them by ~26 names in both directions and does NOT carry
# sdlc-review at all. Enumerating "once, from the default" would therefore have
# omitted the single most important name from every generated list.
disabled_skills_for() {  # $1=profile
  local prof="$1" allowed=" $(skills_allowed_for "$1") " forge installed s
  forge="$(cd "$FORGE_DIR/skills" && ls -d */ 2>/dev/null | tr -d '/')"
  if [ -z "$forge" ]; then
    echo "  skill enumeration: no skills found in $FORGE_DIR/skills" >&2; return 1
  fi
  installed="$(installed_skills_for "$prof")" || return 1
  for s in $(printf '%s\n%s\n' "$forge" "$installed" | sort -u); do
    case "$allowed" in *" $s "*) ;; *) echo "$s";; esac
  done
}

# Read back through the CLI, not the file, so we verify what the RUNTIME sees.
verify_config() {  # $1=name $2=model $3=toolsets $4=disabled skill names
  local name="$1" model="$2" tools="$3" disabled="$4" got want rc=0
  got=$(hermes -p "$name" config get model.default 2>&1) || true
  [ "$got" = "$model" ] || { echo "  FAIL model.default: got '$got' want '$model'" >&2; rc=1; }

  want=$(printf -- '- %s\n' ${tools//,/ })
  got=$(hermes -p "$name" config get toolsets 2>&1) || true
  [ "$got" = "$want" ] || { echo "  FAIL toolsets: got '$got' want '$want'" >&2; rc=1; }

  got=$(hermes -p "$name" config get skills.external_dirs 2>&1) || true
  [ "$got" = "- $FORGE_DIR/skills" ] || { echo "  FAIL skills.external_dirs: got '$got'" >&2; rc=1; }

  want=$(printf -- '- %s\n' $disabled)
  got=$(hermes -p "$name" config get skills.disabled 2>&1) || true
  [ "$got" = "$want" ] || { echo "  FAIL skills.disabled: got '$got' want '$want'" >&2; rc=1; }

  got=$(hermes -p "$name" config get skills.write_approval 2>&1) || true
  [ "$got" = "true" ] || { echo "  FAIL skills.write_approval: got '$got' want 'true'" >&2; rc=1; }

  got=$(hermes -p "$name" config get terminal.timeout 2>&1) || true
  [ "$got" = "$TERMINAL_TIMEOUT" ] || { echo "  FAIL terminal.timeout: got '$got' want '$TERMINAL_TIMEOUT'" >&2; rc=1; }

  return $rc
}

failed=0
for spec in "${PROFILES[@]}"; do
  IFS='|' read -r name desc tools <<< "$spec"
  echo "── $name"

  case "$name" in
    forge-orchestrator) model="$MODEL_ROUTER";;
    *)                  model="$MODEL_DRIVER";;
  esac

  if [ -d "$HERMES_ROOT/profiles/$name" ]; then
    echo "  exists, skipping create"
  else
    run hermes profile create "$name" --description "$desc"
  fi

  # SOUL.md is the profile's identity slot. Rewriting it is safe and idempotent;
  # it takes effect on the profile's next session.
  soul="$HERE/profiles/$name.SOUL.md"
  dest="$HERMES_ROOT/profiles/$name/SOUL.md"
  if [ -f "$soul" ]; then
    if [ "$DRY" = 1 ]; then echo "  + cp $soul -> $dest"; else cp "$soul" "$dest"; fi
  else
    echo "  WARN no SOUL file at $soul"
  fi

  # Enumerated HERE, in the parent shell, and passed down. Inside
  # `$(disabled_skills_for ...)` a `return 1` or `exit 1` only kills the command
  # substitution: printf's own status is what `set -e` sees, so the script would
  # sail on and write `disabled:` with nothing under it — enabling every skill,
  # which is precisely the failure this rewrite exists to remove. Computing it
  # once also means write_config and verify_config compare the SAME list; two
  # separate `skills list` calls could straddle the CLI's scan-cache TTL and
  # fail the readback for no reason.
  if ! DISABLED="$(disabled_skills_for "$name")"; then
    echo >&2
    echo "FATAL: could not enumerate the installed skills for $name." >&2
    echo "       skills.disabled is an allowlist rendered as a denylist; writing" >&2
    echo "       it from a partial enumeration would leave the unenumerated" >&2
    echo "       skills ENABLED. Refusing to write $name's config." >&2
    exit 1
  fi

  cfg="$HERMES_ROOT/profiles/$name/config.yaml"
  if [ "$DRY" = 1 ]; then
    echo "  + write $cfg :"
    write_config "$name" "$model" "$tools" /dev/stdout "$DISABLED" | sed 's/^/      /'
    echo "  + then read back and require: ${VERIFIED_KEYS[*]}"
  else
    write_config "$name" "$model" "$tools" "$cfg" "$DISABLED"
    echo "  wrote $cfg"
    if verify_config "$name" "$model" "$tools" "$DISABLED"; then
      echo "  verified: ${VERIFIED_KEYS[*]}"
    else
      echo "  READBACK FAILED for $name" >&2
      failed=1
    fi
  fi
done

if [ "$failed" != 0 ]; then
  echo >&2
  echo "FATAL: at least one profile's config did not read back as written." >&2
  echo "       The runtime is NOT in the state this script describes." >&2
  exit 1
fi

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
  (secrets are the one thing this script deliberately does NOT write)

── and in the DEFAULT profile's config.yaml (see hermes/config-examples.yaml):
  approvals.mode: smart            # `manual` hangs an unattended worker forever
EOF
