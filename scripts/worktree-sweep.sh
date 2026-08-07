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
# But the branch NAME is not the identity of the work. "Was a PR with this name
# ever merged" is answered `yes` forever, including for a branch that was merged
# in March, deleted, and recreated in August with entirely new commits — and
# this command then removed that live chunk's worktree and deleted its branch,
# reproduced end to end. So the merged PR's `headRefOid` must equal the
# worktree's current HEAD. A merged PR whose head has moved on is a branch with
# unmerged work on it.
#
# Every git question asked here is checked for FAILURE, not just for output. An
# empty `git status --porcelain` means "clean"; a git that could not run also
# prints nothing, and reading the second as the first is how an unreadable
# worktree full of uncommitted work gets classified clean and taken to removal.
# A question that could not be answered keeps the worktree and says so.
#
# Usage: scripts/worktree-sweep.sh <abs-project-path> [--apply]
# Exit:  0 = ran (dry-run or applied)   2 = refused to run at all
# =============================================================================
set -uo pipefail

# `sed -n '2,33p'` cut the header off two lines short of the `Exit:` contract —
# the one line a caller most needs — and would have gone further wrong every
# time a paragraph was added above it. Anchored to the `# ====` rules instead,
# so the help is whatever the header block says it is.
help_text() {
  awk 'NR==1 { next }
       /^# ={10,}/ { if (seen) exit; seen=1; next }
       seen { sub(/^#[ ]?/, ""); print }' "$0"
}

PROJECT=""; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift;;
    -h|--help) help_text; exit 0;;
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
#
# FAIL CLOSED. `-d` needs only `+x` on the PARENT; `cd` needs `+x` on the
# directory itself. When the two disagreed the command substitution produced the
# empty string, `BOUND` became "", and the guard below turned into
# `case "$path" in "/*")` — a glob matching EVERY absolute path. The bound, which
# is this command's entire safety property, silently became "everywhere":
# measured, a sibling checkout outside the bound was removed and its branch
# deleted, at exit 0, with `0 refused` in the summary. This is the same defect
# `new-dest.sh`'s `physical()` was hardened against in this slice, not carried
# across at the time.
BOUND="$PROJECT/.worktrees"
if [ -e "$BOUND" ]; then
  BOUND="$(cd "$BOUND" 2>/dev/null && pwd -P)" || {
    echo "worktree-sweep: $PROJECT/.worktrees exists but cannot be entered; refusing to run with an unresolved bound" >&2
    exit 2; }
fi
[ -n "$BOUND" ] || {
  echo "worktree-sweep: the bound resolved to nothing; refusing to run" >&2
  exit 2; }

command -v gh >/dev/null 2>&1 \
  || { echo "worktree-sweep: gh is not on PATH; merge state cannot be read from the remote" >&2; exit 2; }

REMOVED=0; KEPT=0; REFUSED=0
say() { printf '%s\n' "$*"; }

# 0 merged AT THIS HEAD · 1 no merged PR · 2 could not ask · 3 merged, but the
# branch has moved since — new work under a name that was merged once before.
pr_merged() { # $1=branch  $2=the worktree's current HEAD oid
  local out rc oid
  out="$(cd "$PROJECT" && gh pr list --head "$1" --state merged --limit 1 \
           --json number,headRefOid 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] || return 2
  out="$(printf '%s' "$out" | tr -d '[:space:]')"
  case "$out" in ""|"[]") return 1;; esac

  # Extracted with grep rather than jq: `gh` is already required, jq is not, and
  # this is one flat object. Whitespace is stripped above so the same expression
  # matches gh's compact and pretty output.
  #
  # `grep -o | head -1` takes the FIRST match. A `sed 's/.*"headRefOid":"…"/'`
  # is greedy and takes the LAST, which is only safe while `--limit 1` stays on
  # the line above — a guard depending on another guard staying correct, which is
  # the arrangement this slice argues against everywhere else.
  oid="$(printf '%s' "$out" \
         | grep -o '"headRefOid":"[0-9a-fA-F]\{7,40\}"' \
         | head -1 | sed 's/.*:"//; s/"$//')"
  [ -n "$oid" ] || return 2      # a merged PR we cannot pin to a commit is unanswered
  [ "$oid" = "$2" ] || return 3
  return 0
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

  # `git status` failing prints nothing, and so does a clean worktree. The rc is
  # the only thing that tells them apart, and without it a worktree holding
  # uncommitted work was classified clean and taken all the way to removal —
  # surviving only because `git worktree remove` has its own check, and then
  # being reported with the wrong reason.
  local dirty rc
  dirty="$(git -C "$path" status --porcelain 2>/dev/null)"; rc=$?
  if [ "$rc" != 0 ]; then
    say "  KEEP    $path  [$branch]"
    say "          could not read 'git status' here (exit $rc) — refusing to call it clean"
    KEPT=$((KEPT+1)); return 0
  fi
  if [ -n "$dirty" ]; then
    say "  KEEP    $path  [$branch]"
    say "          dirty: $(printf '%s\n' "$dirty" | grep -c '') uncommitted/untracked path(s)"
    KEPT=$((KEPT+1)); return 0
  fi

  local head
  head="$(git -C "$path" rev-parse HEAD 2>/dev/null)"; rc=$?
  if [ "$rc" != 0 ] || [ -z "$head" ]; then
    say "  KEEP    $path  [$branch]"
    say "          could not read HEAD here (exit $rc) — nothing to compare a merged PR against"
    KEPT=$((KEPT+1)); return 0
  fi

  pr_merged "$branch" "$head"; local m=$?
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
  if [ "$m" = 3 ]; then
    say "  KEEP    $path  [$branch]"
    say "          a PR on this branch NAME was merged, but at a different commit than"
    say "          ${head} — this branch has moved since, so the work here is unmerged"
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

# Materialised to a file rather than read from a process substitution, because
# `done < <(cmd)` throws the command's exit status away. An enumeration that
# failed produced an empty stream, which printed "0 would be removed · 0 kept ·
# 0 refused" and exited 0 — "nothing to sweep" and "I could not look" were the
# same output. This is the whole input to the command; it cannot be guessed at.
LISTING="$(mktemp "${TMPDIR:-/tmp}/forge-sweep.XXXXXX")" \
  || { echo "worktree-sweep: could not create a temporary file" >&2; exit 2; }
trap 'rm -f "$LISTING" "$LISTING.err"' EXIT

# stderr goes to its OWN file. Merged into $LISTING it would be parsed as
# porcelain, and a git warning whose first word happened to be `worktree` or
# `branch` would be read as a record.
if ! git -C "$PROJECT" worktree list --porcelain > "$LISTING" 2>"$LISTING.err"; then
  echo "worktree-sweep: could not enumerate worktrees in $PROJECT" >&2
  sed 's/^/  /' "$LISTING.err" >&2
  exit 2
fi

while IFS= read -r line; do
  case "$line" in
    "worktree "*) flush; wt="${line#worktree }";;
    "branch refs/heads/"*) br="${line#branch refs/heads/}";;
    "detached") br="";;
    "") ;;
  esac
done < "$LISTING"
flush

say ""
if [ "$APPLY" = 1 ]; then
  say "  $REMOVED removed · $KEPT kept · $REFUSED refused (outside the bound)"
else
  say "  $REMOVED would be removed · $KEPT kept · $REFUSED refused (outside the bound)"
  [ "$REMOVED" -gt 0 ] && say "  re-run with APPLY=1 to act"
fi
exit 0
