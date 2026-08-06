#!/usr/bin/env bash
# =============================================================================
# forge worktree-sweep — reclaim the checkouts finished chunks leave behind.
#
# `worktree` workspaces are PRESERVED on completion (only `scratch` is deleted),
# so every finished chunk leaves <project>/.worktrees/<task-id> behind: a full
# checkout plus the `.venv` the lane built, measured at 50 MB per chunk. It also
# holds the branch, which is why `gh pr merge --delete-branch` fails every time
# with "cannot delete branch … used by worktree" (state.md gap #1, audit F18).
#
# Three properties make this safe enough to run unattended:
#
#   DRY-RUN BY DEFAULT. Without --apply it prints and changes nothing.
#
#   PATH-BOUNDED. It will only touch worktrees under <project>/.worktrees/.
#   Everything else — sibling checkouts, agent worktrees, the main checkout —
#   is reported as REFUSE and left alone. A sweep that can reach outside a
#   single directory is a sweep you cannot run without reading its output first,
#   which defeats the point of having it.
#
#   NEVER `git branch -D`. `-d` refuses a branch whose commits are not reachable
#   from HEAD or its upstream, and that refusal is the last thing standing
#   between an unpushed commit and nothing. A retained branch costs bytes; a
#   forced delete costs work. When `-d` refuses, the worktree is still reclaimed
#   and the branch is reported as retained.
#
# "Merged" is decided by asking GitHub for a merged PR on that head branch, not
# by a local ancestry test: a squash merge leaves no local ancestry at all, so a
# local heuristic would report every squash-merged chunk as unmerged and sweep
# nothing. Without `gh` the question cannot be answered, and an unanswerable
# question is refused rather than guessed.
#
# Usage: scripts/worktree-sweep.sh <abs-project-path> [--apply]
# Exit:  0 = ran (dry-run or applied)   2 = refused to run at all
# =============================================================================
set -uo pipefail

PROJECT=""; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift;;
    -h|--help) sed -n '2,33p' "$0"; exit 0;;
    -*) echo "worktree-sweep: unknown flag: $1" >&2; exit 2;;
    *) [ -z "$PROJECT" ] || { echo "worktree-sweep: one project at a time" >&2; exit 2; }
       PROJECT="$1"; shift;;
  esac
done

[ -n "$PROJECT" ] || { echo "usage: worktree-sweep.sh <abs-project-path> [--apply]" >&2; exit 2; }

# Absolute only. A relative PROJECT resolves against whatever directory the
# caller happened to be in — the same mechanism that put a real product in
# /private/tmp (F19). A sweep that deletes things must never inherit its target.
case "$PROJECT" in
  /*) ;;
  *) echo "worktree-sweep: PROJECT must be an absolute path; got '$PROJECT'" >&2; exit 2;;
esac

[ -d "$PROJECT" ] || { echo "worktree-sweep: no such directory: $PROJECT" >&2; exit 2; }
PROJECT="$(cd "$PROJECT" && pwd -P)"
git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "worktree-sweep: not a git repository: $PROJECT" >&2; exit 2; }

# The one directory this command is allowed to touch. Physical, because a
# worktree path reported by git is physical and a string compare against an
# unresolved prefix would silently match nothing (or, worse, something else).
BOUND="$PROJECT/.worktrees"
[ -d "$BOUND" ] && BOUND="$(cd "$BOUND" && pwd -P)"

command -v gh >/dev/null 2>&1 \
  || { echo "worktree-sweep: gh is not on PATH; merge state cannot be read from the remote" >&2; exit 2; }

REMOVED=0; KEPT=0; REFUSED=0
say() { printf '%s\n' "$*"; }

# 0 merged · 1 not merged · 2 could not ask
pr_merged() { # $1=branch
  local out rc
  out="$(cd "$PROJECT" && gh pr list --head "$1" --state merged --limit 1 --json number 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] || return 2
  case "$(printf '%s' "$out" | tr -d '[:space:]')" in
    ""|"[]") return 1;;
    *) return 0;;
  esac
}

say "worktree-sweep: $PROJECT"
say "  bound to:  $BOUND/"
say "  mode:      $([ "$APPLY" = 1 ] && echo 'APPLY — worktrees will be removed' || echo 'dry-run (pass APPLY=1 to act)')"
say ""

# --porcelain gives one record per worktree, blank-line separated. `branch` is
# absent for a detached HEAD, which we cannot judge and therefore keep.
wt=""; br=""
flush() {
  [ -n "$wt" ] || return 0
  local path="$wt" branch="$br"
  wt=""; br=""

  # The main checkout is itself a record. Anything not under the bound is
  # refused before any state is even read: no dirty check, no gh call, no
  # chance of a typo in the guard being papered over by a later condition.
  case "$path" in
    "$BOUND"/*) ;;
    *) say "  REFUSE  $path"
       say "          outside $BOUND/ — this command does not reach here"
       REFUSED=$((REFUSED+1)); return 0;;
  esac

  if [ ! -d "$path" ]; then
    say "  KEEP    $path"; say "          worktree path is missing; run 'git worktree prune'"
    KEPT=$((KEPT+1)); return 0
  fi

  if [ -z "$branch" ]; then
    say "  KEEP    $path"; say "          detached HEAD — no branch to judge or delete"
    KEPT=$((KEPT+1)); return 0
  fi

  local dirty
  dirty="$(git -C "$path" status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ]; then
    say "  KEEP    $path  [$branch]"
    say "          dirty: $(printf '%s\n' "$dirty" | grep -c '') uncommitted/untracked path(s)"
    KEPT=$((KEPT+1)); return 0
  fi

  pr_merged "$branch"; local m=$?
  if [ "$m" = 2 ]; then
    say "  KEEP    $path  [$branch]"
    say "          could not read merge state from the remote — not guessing"
    KEPT=$((KEPT+1)); return 0
  fi
  if [ "$m" = 1 ]; then
    say "  KEEP    $path  [$branch]"
    say "          no merged PR for this head branch on the remote"
    KEPT=$((KEPT+1)); return 0
  fi

  if [ "$APPLY" != 1 ]; then
    say "  WOULD   $path  [$branch]"
    say "          clean, PR merged — 'git worktree remove' then 'git branch -d $branch'"
    REMOVED=$((REMOVED+1)); return 0
  fi

  if ! git -C "$PROJECT" worktree remove "$path" >/dev/null 2>&1; then
    say "  KEEP    $path  [$branch]"
    say "          git worktree remove refused it — left intact (no --force here)"
    KEPT=$((KEPT+1)); return 0
  fi
  REMOVED=$((REMOVED+1))
  say "  REMOVED $path  [$branch]"

  # Deliberately -d. A squash merge leaves the branch's commits unreachable from
  # main, so this legitimately refuses on merged work too; the worktree — the
  # 50 MB and the branch lock — is already reclaimed either way.
  if git -C "$PROJECT" branch -d "$branch" >/dev/null 2>&1; then
    say "          branch deleted"
  else
    say "          branch RETAINED: 'git branch -d' refused it (not reachable from HEAD)."
    say "          Verify nothing is unpushed, then delete it yourself."
  fi
}

while IFS= read -r line; do
  case "$line" in
    "worktree "*) flush; wt="${line#worktree }";;
    "branch refs/heads/"*) br="${line#branch refs/heads/}";;
    "detached") br="";;
    "") ;;
  esac
done < <(git -C "$PROJECT" worktree list --porcelain 2>/dev/null)
flush

say ""
if [ "$APPLY" = 1 ]; then
  say "  $REMOVED removed · $KEPT kept · $REFUSED refused (outside the bound)"
else
  say "  $REMOVED would be removed · $KEPT kept · $REFUSED refused (outside the bound)"
  [ "$REMOVED" -gt 0 ] && say "  re-run with APPLY=1 to act"
fi
exit 0
