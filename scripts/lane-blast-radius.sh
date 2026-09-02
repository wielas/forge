#!/usr/bin/env bash
# Prove that `codex exec` stayed inside the Git boundary forge-lane grants it.
#
# §4 hands Codex `--add-dir "$(git rev-parse --git-common-dir)"`, because in a
# worktree the real `.git` lives in the main repo and `workspace-write` alone
# cannot commit. The grant is therefore wide — this script is what bounds it
# afterwards. Capture must run BEFORE §4; a hash taken afterwards proves nothing.
#
# WHAT THIS PROTECTS, AND WHAT IT DELIBERATELY DOES NOT.
# The audit compares a named set of surfaces, not the whole shared `.git`. An
# earlier version asserted that everything under the common dir was frozen
# except a small allow-list, and that assertion is FALSE under normal operation:
# a sibling lane committing on its own branch, any `git fetch`, `git pack-refs`
# and `git commit-graph write` all changed protected bytes with no Codex
# involvement (audit F75). Blocking a clean chunk with the most alarming block
# the protocol raises is worse than a narrower guarantee.
#
# The governing constraint is that from inside this lane, `refs/heads/<other>`
# moving is INDISTINGUISHABLE from Codex moving it — the shared `.git` carries
# no signal separating a sibling lane doing its job from an escape. Sibling
# branches, `refs/remotes/*` and other worktrees' admin directories are
# therefore out of scope by construction, not by oversight. What remains is
# everything an escape could use to reach the operator's machine or the
# protected branch:
#
#   hooks (both directories)  executes on the operator's machine
#   local + worktree config   `core.hooksPath`, aliases, credential helpers
#   refs/heads/main           the protected branch
#   objects/info/alternates   redirects object lookup elsewhere
#   object reachability       history cannot silently lose objects
#   worktree cleanliness      `.orig`/`.rej` leftovers (measured 2026-07-28)
#
# WHY BOTH HOOK DIRECTORIES. `lane-setup.sh` points this worktree at its own
# `core.hooksPath`, so `git rev-parse --git-path hooks` resolves per-worktree
# and the shared `$COMMON/hooks` stops being rewritten by every lane's
# `make setup` (audit F77). The shared directory is the one that runs in the
# OPERATOR's checkout, so it is audited too — auditing only the resolved path
# would leave the highest-value target in the grant unwatched.
#
# WHY `--connectivity-only`. `git fsck --full` also validates object CONTENT,
# which fails on malformed history the repository already carried — a
# CVS/SVN-imported commit made this audit block every chunk on that repo
# forever, with no Codex involvement at all (audit F76). Connectivity is the
# property that matters here and is the cheap half.
#
# Usage: lane-blast-radius.sh capture <workspace> <run-id>
#        lane-blast-radius.sh check   <workspace> <run-id>
#
# Exit: 0  capture complete, or check clean
#       2  usage/substrate error, missing capture, or capture could not inspect
#       3  post-Codex breach, including a check that cannot inspect Git safely
#
# Exit 1 remains unused, matching ADR-0010's driver convention. A breach is
# ALWAYS a `kanban_block`, never a push and never a retry: the run went outside
# its contract and there is no way to tell from here what else it did.
set -uo pipefail
umask 077

usage() {
  echo "usage: lane-blast-radius.sh capture|check <workspace> <run-id>" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
MODE="$1" WS="$2" RUN_ID="$3"
case "$MODE" in capture|check) ;; *) usage ;; esac
case "$RUN_ID" in
  ""|.|..|*[!A-Za-z0-9._-]*)
    echo "blast-radius: run id contains unsafe path characters" >&2
    exit 2
    ;;
esac

# The baseline must live where Codex cannot reach it. The worktree, /tmp,
# $TMPDIR and the shared .git are all inside the sandbox's write grant, so a
# baseline stored in any of them can be recaptured over after a breach (F69).
if [ -n "${FORGE_LANE_AUDIT_ROOT:-}" ]; then
  AUDIT_BASE="$FORGE_LANE_AUDIT_ROOT"
elif [ -n "${HOME:-}" ]; then
  AUDIT_BASE="$HOME/.forge/lane-audits"
else
  echo "blast-radius: HOME is unset and FORGE_LANE_AUDIT_ROOT was not provided" >&2
  exit 2
fi
# <run-id> is the CALLER'S SCOPE KEY, not necessarily a bare Hermes run id.
# Run ids are board-local — every board's database restarts them at 1 — so
# lane-setup.sh passes `<board>-<run-id>` and the lane skill passes the
# `FORGE_LANE_RUN_KEY` that setup emitted. Keying this directory on a bare run
# id made a fresh board's run 1 collide with an earlier board's completed run 1
# (measured 2026-09-02), and the single-use guards below then read that stale
# capture as this run's own. Sanitising the board is deliberately NOT repeated
# here: lane-setup owns that rule, and a second copy is how the two drift.
STATE="$AUDIT_BASE/$RUN_ID"

cd "$WS" 2>/dev/null || {
  echo "blast-radius: workspace $WS does not exist" >&2
  exit 2
}
WS_PHYS="$(pwd -P)" || exit 2

inside="$(git rev-parse --is-inside-work-tree 2>/dev/null)" || {
  echo "blast-radius: $WS is not a git checkout" >&2
  exit 2
}
[ "$inside" = true ] || {
  echo "blast-radius: $WS is not a worktree checkout" >&2
  exit 2
}

BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || {
  echo "blast-radius: $WS must be on the task branch, not detached HEAD" >&2
  exit 2
}
[ "$BRANCH" != main ] || {
  echo "blast-radius: main is not a task branch" >&2
  exit 2
}
COMMON_RAW="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 2
HOOKS_RAW="$(git rev-parse --git-path hooks 2>/dev/null)" || exit 2

case "$COMMON_RAW$HOOKS_RAW$WS_PHYS" in
  *$'\n'*)
    echo "blast-radius: newline-bearing Git paths are not auditable" >&2
    exit 2
    ;;
esac

COMMON="$(cd "$COMMON_RAW" 2>/dev/null && pwd -P)" || {
  echo "blast-radius: cannot resolve shared Git directory" >&2
  exit 2
}
case "$HOOKS_RAW" in
  /*) HOOKS_PATH="$HOOKS_RAW" ;;
  *)  HOOKS_PATH="$WS_PHYS/$HOOKS_RAW" ;;
esac
SHARED_HOOKS="$COMMON/hooks"

digest_text() {
  local line
  line="$(printf '%s' "$1" | shasum -a 256)" || return 1
  printf '%s\n' "${line%% *}"
}

# GNU `stat -f` is a valid but different command: it prints filesystem status.
# Trying the BSD spelling first therefore succeeds on Linux and puts changing
# free-block counts into the hook manifest, making every clean audit a breach.
# GNU `-c` is rejected by BSD stat, so this order distinguishes the dialects.
node_mode()     { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
followed_mode() { stat -L -c '%a' "$1" 2>/dev/null || stat -L -f '%Lp' "$1" 2>/dev/null; }

# One manifest line per node: hashed relative path (so odd path bytes cannot
# break the line format), node type, mode, symlink/content digest, and finally
# the plaintext path for HUMAN use only. The trailing column is why a breach is
# readable at all — the hash alone told the operator that something moved but
# never what, which made a misfire impossible to diagnose.
record_node() {
  local root="$1" path="$2" rel mode kind value path_hash display
  local target target_kind target_mode target_value
  rel="${path#"$root"}"
  rel="${rel#/}"
  [ -n "$rel" ] || rel="."

  mode="$(node_mode "$path")" || return 1
  path_hash="$(digest_text "$rel")" || return 1
  value="-"
  if [ -L "$path" ]; then
    kind=link
    target="$(readlink "$path")" || return 1
    value="$(digest_text "$target")" || return 1
    if [ -e "$path" ]; then
      target_mode="$(followed_mode "$path")" || return 1
      target_value="-"
      if [ -f "$path" ]; then
        target_kind=file
        target_value="$(shasum -a 256 "$path" 2>/dev/null)" || return 1
        target_value="${target_value%% *}"
      elif [ -d "$path" ]; then
        target_kind=dir
      else
        target_kind=other
      fi
      value="$value:$target_kind:$target_mode:$target_value"
    else
      value="$value:dangling:-:-"
    fi
  elif [ -f "$path" ]; then
    kind=file
    value="$(shasum -a 256 "$path" 2>/dev/null)" || return 1
    value="${value%% *}"
  elif [ -d "$path" ]; then
    kind=dir
  else
    kind=other
  fi
  display="${rel//$'\n'/?}"
  display="${display//$'\t'/?}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$path_hash" "$kind" "$mode" "$value" "$display"
}

snapshot_tree() {
  local root="$1" out="$2" list unsorted path failed=0
  list="$out.find"
  unsorted="$out.unsorted"
  # A missing hooks directory is a legitimate state, not an error. Normalise it
  # so absence compares equal to absence instead of reading as a breach.
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    printf 'MISSING\n' > "$out" || return 1
    return 0
  fi
  find -H "$root" -print0 > "$list" || return 1
  : > "$unsorted" || return 1
  while IFS= read -r -d '' path; do
    record_node "$root" "$path" >> "$unsorted" || { failed=1; break; }
  done < "$list"
  [ "$failed" -eq 0 ] || return 1
  LC_ALL=C sort "$unsorted" > "$out" || return 1
  rm -f "$list" "$unsorted"
}

snapshot_file() {   # a single protected file, or the fact that it is absent
  local path="$1" out="$2" line
  if [ -f "$path" ]; then
    line="$(shasum -a 256 "$path" 2>/dev/null)" || return 1
    printf '%s\n' "${line%% *}" > "$out" || return 1
  else
    printf 'MISSING\n' > "$out" || return 1
  fi
}

snapshot_all() {
  local suffix="$1"
  git config --local --includes --null --show-origin --list \
    > "$STATE/config-local.$suffix" 2>/dev/null || return 1

  # Worktree-scoped config is a separate file that `--local` never shows, and
  # it is where `core.hooksPath` lives. Only readable when the extension is on.
  if [ "$(git config --bool --get extensions.worktreeConfig 2>/dev/null)" = true ]; then
    git config --worktree --null --list > "$STATE/config-worktree.$suffix" 2>/dev/null || return 1
  else
    : > "$STATE/config-worktree.$suffix" || return 1
  fi

  git rev-parse --verify --quiet refs/heads/main > "$STATE/main.$suffix" 2>/dev/null \
    || printf 'MISSING\n' > "$STATE/main.$suffix" || return 1

  snapshot_file "$COMMON/objects/info/alternates" "$STATE/alternates.$suffix" || return 1
  snapshot_tree "$HOOKS_PATH" "$STATE/hooks.$suffix" || return 1
  if [ "$HOOKS_PATH" != "$SHARED_HOOKS" ]; then
    snapshot_tree "$SHARED_HOOKS" "$STATE/shared-hooks.$suffix" || return 1
  fi
}

write_meta() {
  local name="$1" value="$2"
  case "$value" in *$'\n'*) return 1 ;; esac
  printf '%s\n' "$value" > "$STATE/$name"
}
read_meta() { [ -f "$STATE/$1" ] || return 1; cat "$STATE/$1"; }

FIRST_PATH=""
compare() {   # label before after -> records the diff and the first path moved
  local label="$1" before="$2" after="$3"
  cmp -s "$before" "$after" && return 0
  {
    printf '=== %s ===\n' "$label"
    diff "$before" "$after" 2>/dev/null | head -40
    printf '\n'
  } >> "$STATE/breach.txt" 2>/dev/null
  [ -n "$FIRST_PATH" ] || FIRST_PATH="$(
    diff "$before" "$after" 2>/dev/null | awk -F'\t' '/^[<>]/ && NF >= 5 { print $5; exit }'
  )"
  return 1
}

case "$MODE" in
  capture)
    mkdir -p "$AUDIT_BASE" 2>/dev/null || {
      echo "blast-radius: cannot create protected audit root $AUDIT_BASE" >&2
      exit 2
    }
    # Nothing else reaps this directory, and every run leaves one behind.
    find "$AUDIT_BASE" -mindepth 1 -maxdepth 1 -type d -mtime +14 \
      -exec rm -rf {} + 2>/dev/null || true

    [ ! -e "$STATE" ] && mkdir "$STATE" 2>/dev/null || {
      echo "blast-radius: capture for run $RUN_ID already exists; refusing overwrite" >&2
      exit 2
    }
    write_meta workspace "$WS_PHYS" \
      && write_meta branch "$BRANCH" \
      && write_meta common "$COMMON" \
      && write_meta hooks-path "$HOOKS_RAW" \
      && snapshot_all before \
      && : > "$STATE/capture.complete" || {
        echo "blast-radius: capture could not inspect every protected Git surface" >&2
        exit 2
      }
    echo "blast-radius: captured immutable baseline for run $RUN_ID"
    ;;

  check)
    # A missing baseline is not a pass: it is the control being unable to run,
    # which must be louder than a clean result and never quieter (audit F65).
    [ -f "$STATE/capture.complete" ] || {
      echo "blast-radius: no complete capture for run $RUN_ID — setup must capture BEFORE codex exec" >&2
      exit 2
    }
    # One final audit per run id, claimed before anything post-Codex is read.
    # Without this a detected breach could be restored and re-checked (F74).
    # Recovery from a burnt run id is a new card, not a second attempt.
    mkdir "$STATE/check.started" 2>/dev/null || {
      echo "blast-radius: final audit for run $RUN_ID was already attempted; refusing replay" >&2
      exit 2
    }

    expected_ws="$(read_meta workspace)" \
      && expected_branch="$(read_meta branch)" \
      && expected_common="$(read_meta common)" \
      && expected_hooks="$(read_meta hooks-path)" || {
        echo "other: protected blast-radius metadata is unreadable"
        exit 3
      }

    breach=""
    [ "$WS_PHYS" = "$expected_ws" ]      || breach="$breach workspace-changed"
    [ "$BRANCH" = "$expected_branch" ]   || breach="$breach branch-changed"
    [ "$COMMON" = "$expected_common" ]   || breach="$breach common-git-changed"
    [ "$HOOKS_RAW" = "$expected_hooks" ] || breach="$breach hooks-path-changed"

    snapshot_all after || {
      echo "other: blast-radius audit could not inspect every protected Git surface"
      exit 3
    }
    # fsck before status: a missing object breaks `git status` too, and the
    # object-database diagnosis is the accurate one for the operator to read.
    git fsck --connectivity-only --no-reflogs --no-dangling --no-progress >/dev/null 2>&1 || {
      echo "other: blast-radius audit found unreachable or missing objects"
      exit 3
    }
    worktree_status="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" || {
      echo "other: blast-radius audit could not read worktree status"
      exit 3
    }

    compare config-local    "$STATE/config-local.before"    "$STATE/config-local.after"    || breach="$breach config-edited"
    compare config-worktree "$STATE/config-worktree.before" "$STATE/config-worktree.after" || breach="$breach worktree-config-edited"
    compare main            "$STATE/main.before"            "$STATE/main.after"            || breach="$breach main-moved"
    compare alternates      "$STATE/alternates.before"      "$STATE/alternates.after"      || breach="$breach object-alternates-edited"
    compare hooks           "$STATE/hooks.before"           "$STATE/hooks.after"           || breach="$breach hooks-edited"
    if [ "$HOOKS_PATH" != "$SHARED_HOOKS" ]; then
      compare shared-hooks "$STATE/shared-hooks.before" "$STATE/shared-hooks.after" \
        || breach="$breach shared-hooks-edited"
    fi
    [ -z "$worktree_status" ] || {
      breach="$breach worktree-dirty"
      [ -n "$FIRST_PATH" ] || FIRST_PATH="$(printf '%s\n' "$worktree_status" | awk '{print $NF; exit}')"
      { printf '=== worktree ===\n%s\n\n' "$worktree_status"; } >> "$STATE/breach.txt" 2>/dev/null
    }

    if [ -n "$breach" ]; then
      if [ -n "$FIRST_PATH" ]; then
        echo "other: codex exceeded its contract —$breach (first: $FIRST_PATH)"
      else
        echo "other: codex exceeded its contract —$breach"
      fi
      echo "blast-radius: evidence in $STATE/breach.txt" >&2
      exit 3
    fi
    printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$STATE/check.complete" || {
      echo "other: blast-radius result could not be recorded"
      exit 3
    }
    echo "blast-radius: clean — protected Git state unchanged, task commit surfaces only"
    ;;
esac
