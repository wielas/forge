#!/usr/bin/env bash
# Prepare and validate a lane worktree before Codex receives the contract.
#
# Setup owns the complete pre-Codex mechanism: validate the dispatcher-created
# worktree, give it its own hooks directory, refresh origin, build the
# environment, prove the baseline clean and green, then take the immutable
# blast-radius capture. If this script returns 0, the environment and the audit
# control are both ready; otherwise Codex must not run.
#
# On success the LAST line of stdout is `FORGE_LANE_RUNTIME=<abs path>` — the
# per-run scratch directory for the contract, the transcript, the PR body and
# the UV cache. It lives in $TMPDIR because the sandbox must be able to write
# it, which is exactly why the audit baseline may NOT live there. The line
# BEFORE it is `FORGE_LANE_RUN_KEY=<board>-<run-id>`, the board-scoped key this
# run's audit baseline is filed under; §5 of the lane skill passes it back to
# `lane-blast-radius.sh check`. Emitted in that order because the last-line
# contract above is what callers rely on.
#
# Usage: lane-setup.sh <workspace> <run-id>
#        HERMES_KANBAN_BOARD scopes the per-run paths (see the block below)
#
# Exit: 0  ready — environment built, baseline green, audit captured
#       2  usage
#       3  substrate — workspace is not a non-bare worktree checkout
#       4  env — origin could not be fetched or `make setup` failed
#       5  failing-prereq — baseline `make check` was red or setup left dirt
#       6  audit-control — immutable blast-radius capture failed
#
# Exit 1 remains unused, matching ADR-0010's driver convention. Every runtime
# failure prints a board-ready `<class>: <reason>`; command output is suppressed
# so credentials or noisy build logs do not enter durable metadata.
set -uo pipefail

[ "$#" -eq 2 ] || {
  echo "usage: lane-setup.sh <workspace> <run-id>" >&2
  exit 2
}
WS="$1" RUN_ID="$2"
case "$RUN_ID" in
  ""|.|..|*[!A-Za-z0-9._-]*)
    echo "usage: lane-setup.sh <workspace> <safe-run-id>" >&2
    exit 2
    ;;
esac

# RUN IDS ARE BOARD-LOCAL. Every Hermes board keeps its own database at
# ~/.hermes/kanban/boards/<slug>/kanban.db, so run ids restart at 1 for each
# new board. Measured 2026-09-02: boards `forge-hello-20260902` and
# `forge-hello-20260902b` each issued run ids 1, 2, 3. A per-run path keyed on
# the run id alone therefore collides across boards — and the collision is a
# HARD failure, which is right inside one board and wrong between two.
#
# It fired for real on 2026-09-02: a fresh board's run 1 met the completed
# leftovers of an earlier board's run 1, and the run survived only because the
# worker improvised a quarantine directory that exists nowhere in this repo.
# Nothing cleans these paths up, so every fresh board inherits the last one's.
#
# The board slug makes the key unique again. The dispatcher injects
# HERMES_KANBAN_BOARD into every worker environment unconditionally
# (hermes_cli/kanban_db.py, alongside the HERMES_KANBAN_BRANCH read above), so
# this needs no new argument and no new agreement with the caller.
#
# What is deliberately NOT done here: auto-removing or auto-quarantining a
# directory that already exists. Refusing reuse is what stops two LIVE runs
# from sharing one scratch and corrupting each other's baseline and audit.
# Scoping the key removes the FALSE collisions and keeps the real one fatal.
BOARD="${HERMES_KANBAN_BOARD:-}"
case "$BOARD" in
  "")
    # Unset degrades to a sentinel rather than an empty path component:
    # `forge-lane--1` is both ugly and ambiguous. A leading underscore is
    # illegal in a real Hermes slug (its own regex is
    # ^[a-z0-9][a-z0-9-_]{0,63}$, which bans a leading `_`), so no genuine
    # board can ever shadow this token.
    # Note this degrades, it does not fix: two boardless runs sharing one id
    # still collide, and still refuse loudly. That is the correct outcome.
    BOARD=_noboard
    ;;
  .|..|*[!A-Za-z0-9._-]*)
    # A slug carrying `/`, `..` or anything else that could climb out of
    # $TMPDIR is an upstream problem. Degrading it would hide that, so refuse
    # exactly the way an unsafe run id is refused above.
    echo "usage: lane-setup.sh <workspace> <run-id> needs a safe HERMES_KANBAN_BOARD" >&2
    exit 2
    ;;
esac

# THE ONE definition of this run's scope key. lane-blast-radius.sh receives it
# as its <run-id> argument — its own charset guard already admits the hyphen —
# so the audit baseline is filed under exactly the same string that names the
# scratch directory, and neither script carries its own copy of the rule above.
# `<board>-<run-id>` is ambiguous in the abstract (board `a-1` run `2` and
# board `a` run `1-2` build one path), but Hermes run ids are
# `str(task.current_run_id)` — always integers — so no real pair can collide.
SCOPE="$BOARD-$RUN_ID"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || {
  echo "env: lane script directory cannot be resolved"
  exit 6
}

cd "$WS" 2>/dev/null || {
  echo "env: workspace $WS does not exist"
  exit 3
}
WS_PHYS="$(pwd -P)" || {
  echo "env: workspace $WS cannot be resolved"
  exit 3
}

inside="$(git rev-parse --is-inside-work-tree 2>/dev/null)" || {
  echo "env: workspace $WS is not a git checkout"
  exit 3
}
[ "$inside" = true ] || {
  echo "env: workspace $WS is not a non-bare worktree checkout"
  exit 3
}
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || {
  echo "env: workspace $WS is detached; a task branch is required"
  exit 3
}
[ "$BRANCH" != main ] || {
  echo "env: workspace $WS is on main, not a task branch"
  exit 3
}
if [ -n "${HERMES_KANBAN_BRANCH:-}" ] && [ "$BRANCH" != "$HERMES_KANBAN_BRANCH" ]; then
  echo "env: workspace branch $BRANCH does not match $HERMES_KANBAN_BRANCH"
  exit 3
fi

# GIVE THIS WORKTREE ITS OWN HOOKS DIRECTORY, BEFORE `make setup` INSTALLS ONE.
# `git rev-parse --git-path hooks` resolves to the SHARED `.git/hooks` in a
# worktree, and lefthook bakes the installing checkout's `.venv` path into the
# hook it writes there. Two lanes therefore race on one file, each rewriting the
# other's (`docs/ladder-2026-07-28.md`) — and once the final audit protects hook
# content, that race becomes a `kanban_block` blaming Codex for a sibling lane's
# `make setup` (audit F77). Per-worktree config fixes the contention itself:
# lefthook honours `core.hooksPath`, `--git-path hooks` follows it, and the
# shared directory stops being written by lanes at all — which is what makes it
# safe for the audit to hold the operator's own hooks strictly immutable.
#
# Ordered before `make setup` so lefthook installs to the right place, and
# before the capture so the config change is part of the baseline, not a breach.
if [ "$(git config --bool --get extensions.worktreeConfig 2>/dev/null)" != true ]; then
  git config extensions.worktreeConfig true 2>/dev/null || {
    echo "env: cannot enable per-worktree git config in $WS_PHYS"
    exit 3
  }
fi
# --absolute-git-dir, not --git-dir: the latter may answer relatively, and a
# relative core.hooksPath resolves against the process CWD rather than the repo.
WT_GIT_DIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || WT_GIT_DIR=""
[ -n "$WT_GIT_DIR" ] && mkdir -p "$WT_GIT_DIR/hooks" 2>/dev/null \
  && git config --worktree core.hooksPath "$WT_GIT_DIR/hooks" 2>/dev/null || {
  echo "env: cannot give $WS_PHYS its own hooks directory"
  exit 3
}

# A stale origin/main makes dependency checks and the final hostile diff lie.
# Network failure is therefore an environment block, not a best-effort warning.
git fetch origin >/dev/null 2>&1 || {
  echo "env: 'git fetch origin' failed in $WS_PHYS — remote state is unverified"
  exit 4
}

make setup >/dev/null 2>&1 || {
  echo "env: 'make setup' failed in $WS_PHYS — the environment cannot be built"
  exit 4
}

make check >/dev/null 2>&1 || {
  echo "failing-prereq: baseline 'make check' was already red before the chunk started"
  exit 5
}
baseline_status="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" || {
  echo "env: baseline worktree status could not be read"
  exit 3
}
[ -z "$baseline_status" ] || {
  echo "failing-prereq: setup left a dirty baseline before the chunk started"
  exit 5
}

RUNTIME_DIR="${TMPDIR:-/tmp}/forge-lane-$SCOPE"
[ ! -e "$RUNTIME_DIR" ] && mkdir "$RUNTIME_DIR" 2>/dev/null || {
  echo "env: per-run scratch $RUNTIME_DIR exists or cannot be created; refusing reuse"
  exit 4
}

BLAST="$SCRIPT_DIR/lane-blast-radius.sh"
[ -x "$BLAST" ] || {
  echo "env: lane-blast-radius.sh is missing or not executable"
  exit 6
}
"$BLAST" capture "$WS_PHYS" "$SCOPE" >/dev/null 2>&1 || {
  echo "env: immutable blast-radius capture failed for run $SCOPE"
  exit 6
}

echo "lane-setup: ready — environment built, baseline green, audit captured"
# THE path, emitted rather than described. The skill used to recompute this
# string itself, so a `$TMPDIR` that differed between the driver's shell and
# this script would silently put the contract somewhere setup never created.
echo "FORGE_LANE_RUN_KEY=$SCOPE"
echo "FORGE_LANE_RUNTIME=$RUNTIME_DIR"
