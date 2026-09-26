#!/usr/bin/env bash
# =============================================================================
# forge merge-check — `make check` on the tree the merge would actually produce.
#
# WHY THIS EXISTS. redglass PR #9 was green, and `main` was green, and their
# union failed five tests neither branch failed alone. Nothing in the pipeline
# ever built that union: CI tests the PR's own head, the lane tests its worktree,
# and the scorer reads a diff. ADR-0019 D19.2 makes an executing check half of
# what an approval rests on, and this is that half.
#
# WHERE IT RUNS, AND WHY NOT IN THE CARD'S WORKTREE. In a FRESH CLONE under
# $TMPDIR, never the implementer's worktree and never a `git worktree add` inside
# the project repo. Merging `origin/main` into the card's own tree would dirty
# the tree a bounce re-enters (FL3 resumes the same worktree, branch and PR), and
# `git worktree add` writes `.git/worktrees/*` while a fetch moves
# `refs/remotes/origin/main` — both inside the set `lane-blast-radius.sh`
# protects, so the verifier's own residue would read as the implementer touching
# shared state (F75/F76). A clone touches nothing the lane can see.
#
# WHAT A FAILURE MEANS. A conflict or a red merged tree is a `request-changes`
# with an action a fresh worker can execute, never a substrate fault: the work
# does not integrate, which is a fact about the work. An UNRUNNABLE check — no
# git, no clone, no `make check` target — is exit 3 and must never read as a
# pass (`prejudge/skip-is-distinguishable-from-pass`'s rule, applied here).
#
# Usage:
#   merge-check.sh --clone-from <url|path> --head-ref <branch>
#                  [--base-ref <branch>] [--check-cmd <cmd>]
#                  [--setup-cmd <cmd>|--no-setup] [--json]
#
# Exit: 0 the merged tree is green.
#       1 the merge conflicts, or the merged tree fails its check (actionable).
#       2 a usage error.
#       3 the check could not be run at all.
# =============================================================================
set -uo pipefail

CLONE_FROM=""; HEAD_REF=""; BASE_REF="main"; CHECK_CMD="make check"
# A FRESH CLONE IS NOT A BUILT TREE. `lane-setup.sh` runs `make setup` before it
# will even look at `make check`, and calls a setup failure `env:` — the
# environment cannot be built — precisely because an unbuilt tree fails every
# check for reasons that have nothing to do with the diff. This script runs in a
# clone nobody has prepared, so it prepares it the same way. Skipped silently when
# the project has no such target, overridable, and `--no-setup` for a caller that
# has its own arrangement.
SETUP_CMD="${FORGE_MERGE_SETUP_CMD-make setup}"
HEAD_SHA_WANT=""
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --clone-from) CLONE_FROM="${2:?--clone-from needs a url or path}"; shift 2;;
    --head-ref)   HEAD_REF="${2:?--head-ref needs a branch}"; shift 2;;
    --head-sha)   HEAD_SHA_WANT="${2:?--head-sha needs a sha}"; shift 2;;
    --base-ref)   BASE_REF="${2:?--base-ref needs a branch}"; shift 2;;
    --check-cmd)  CHECK_CMD="${2:?--check-cmd needs a command}"; shift 2;;
    --setup-cmd)  SETUP_CMD="${2:?--setup-cmd needs a command}"; shift 2;;
    --no-setup)   SETUP_CMD=""; shift;;
    --json)       shift;;   # accepted and ignored: the result is always JSON
    -h|--help)    awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$CLONE_FROM" ] && [ -n "$HEAD_REF" ] || { usagetext; exit 2; }
command -v git >/dev/null || { echo '{"schema":"forge.mergecheck.v1","result":"unrunnable","evidence":"git is not on PATH"}'; exit 3; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forge-mergecheck.XXXXXX")" || {
  echo '{"schema":"forge.mergecheck.v1","result":"unrunnable","evidence":"no writable TMPDIR"}'; exit 3; }
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; LOG="$TMP/check.log"

# Every check runs through this, never bare: `lane.sh` strips exactly these for
# exactly this reason, and a verifier that inherits the driver's environment
# measures the driver, not the tree.
# A subshell with the variables UNSET, not `env -u`: `eval` and `make` are reached
# through normal command lookup this way, and `env` cannot exec a shell builtin.
run_check() { ( unset UV_OFFLINE UV_CACHE_DIR; "$@" ); }

emit() {  # result, evidence, action, exit code
  jq -n --arg result "$1" --arg evidence "$2" --arg action "$3" --arg setup "${SETUP_CMD:-none}" --arg head_moved "${HEAD_MOVED:-}" \
        --arg base "$BASE_REF" --arg head "$HEAD_REF" \
        --arg base_sha "${BASE_SHA:-}" --arg head_sha "${HEAD_SHA:-}" \
        --arg cmd "$CHECK_CMD" --arg head_alone "${HEAD_ALONE:-not-measured}" '
    { schema: "forge.mergecheck.v1", result: $result,
      base: $base, head: $head,
      base_sha: (if $base_sha == "" then null else $base_sha end),
      head_sha: (if $head_sha == "" then null else $head_sha end),
      check: $cmd, setup: $setup, head_alone: $head_alone,
      head_moved: (if $head_moved == "" then null else $head_moved end),
      evidence: $evidence,
      action: (if $action == "" then null else $action end) }'
  exit "$4"
}
command -v jq >/dev/null || { echo '{"schema":"forge.mergecheck.v1","result":"unrunnable","evidence":"jq is not on PATH"}'; exit 3; }

# A shallow clone cannot be merged against an arbitrary base, so this is a full
# one. `--no-tags` keeps it to the two refs that matter.
#
# THROUGH `gh` WHEN THE SOURCE IS A GITHUB REPOSITORY, because `git clone` cannot
# read a private one. Measured 2026-09-26 on this host:
#
#   $ GIT_TERMINAL_PROMPT=0 git clone https://github.com/wielas/vault x
#   fatal: could not read Username for 'https://github.com': terminal prompts disabled
#
# The osxkeychain helper holds no git credential for github.com — `gh` keeps its
# token elsewhere — and BOTH product repos in the ledger are private. So a plain
# `git clone` would make every review on a private repo `unrunnable`, i.e. every
# card blocks on an outage. `gh repo clone` uses gh's own auth and is the same
# credential the lane already pushes with. A local path (a fixture, or a mirror)
# still goes through git.
#
# GIT_TERMINAL_PROMPT=0 on both paths: a missing credential must fail in seconds,
# not sit on a username prompt until `terminal.timeout` kills the worker 1800s
# later with the card still `running`.
gh_repo=""
case "$CLONE_FROM" in
  https://github.com/*) gh_repo="${CLONE_FROM#https://github.com/}"; gh_repo="${gh_repo%.git}";;
  git@github.com:*)     gh_repo="${CLONE_FROM#git@github.com:}";     gh_repo="${gh_repo%.git}";;
  */*) case "$CLONE_FROM" in
         /*|./*|../*|*://*) ;;                   # a path or another host: git
         *) gh_repo="$CLONE_FROM";;              # bare owner/name
       esac;;
esac
case "$gh_repo" in */*/*) gh_repo="";; esac      # not an owner/name after all

if [ -n "$gh_repo" ] && command -v gh >/dev/null; then
  GIT_TERMINAL_PROMPT=0 gh repo clone "$gh_repo" "$REPO" -- --quiet --no-tags \
    >"$TMP/clone.err" 2>&1 \
    || emit unrunnable "gh repo clone $gh_repo failed: $(tr -d '\n' < "$TMP/clone.err" | head -c 200)" "" 3
else
  GIT_TERMINAL_PROMPT=0 git clone --quiet --no-tags "$CLONE_FROM" "$REPO" 2>"$TMP/clone.err" \
    || emit unrunnable "clone of $CLONE_FROM failed: $(tr -d '\n' < "$TMP/clone.err" | head -c 200)" "" 3
fi
git -C "$REPO" fetch --quiet origin "$BASE_REF" "$HEAD_REF" 2>/dev/null || true
# `--verify --quiet`, never a bare rev-parse: a bare one ECHOES the unresolved
# argument on stdout and exits non-zero, so `origin/nope` comes back as the
# STRING "origin/nope" and the absent-branch arm below never fires. Measured
# while writing this file.
BASE_SHA="$(git -C "$REPO" rev-parse --verify --quiet "origin/$BASE_REF" 2>/dev/null || true)"
HEAD_SHA="$(git -C "$REPO" rev-parse --verify --quiet "origin/$HEAD_REF" 2>/dev/null || true)"
[ -n "$BASE_SHA" ] || emit unrunnable "no origin/$BASE_REF in the clone" "" 3
[ -n "$HEAD_SHA" ] || emit unrunnable "no origin/$HEAD_REF in the clone — was the branch deleted?" "" 3

# --head-sha PINS THE UNION TO ONE COMMIT. The caller read the PR's head once and
# every stage of its review is about that commit; cloning "the branch" instead
# would judge whatever landed since, and the verdict would be about a mixture. A
# head that has MOVED is not an error here — it is a fact the caller must see, so
# it is reported rather than quietly followed.
if [ -n "$HEAD_SHA_WANT" ] && [ "$HEAD_SHA_WANT" != "$HEAD_SHA" ]; then
  if git -C "$REPO" cat-file -e "$HEAD_SHA_WANT^{commit}" 2>/dev/null; then
    HEAD_MOVED="$HEAD_SHA"; HEAD_SHA="$HEAD_SHA_WANT"
  else
    emit unrunnable \
      "the commit this review is about ($HEAD_SHA_WANT) is not in $HEAD_REF any more — origin/$HEAD_REF is $HEAD_SHA, so the branch was force-pushed or rewritten mid-review" "" 3
  fi
fi

git -C "$REPO" -c advice.detachedHead=false checkout --quiet "$HEAD_SHA" 2>/dev/null \
  || emit unrunnable "cannot check out $HEAD_REF at $HEAD_SHA" "" 3

# PREPARE THE TREE BEFORE JUDGING IT, and classify a build failure as UNRUNNABLE:
# a host that cannot install this project's dependencies has said nothing about
# the work. `make -n` asks make whether the target exists rather than parsing a
# Makefile, so a project without one simply skips this.
if [ -n "$SETUP_CMD" ]; then
  case "$SETUP_CMD" in
    make\ *) ( cd "$REPO" && run_check make -n ${SETUP_CMD#make } >/dev/null 2>&1 ) || SETUP_CMD="";;
  esac
fi
if [ -n "$SETUP_CMD" ]; then
  ( cd "$REPO" && run_check eval "$SETUP_CMD" ) >"$TMP/setup.log" 2>&1 \
    || emit unrunnable \
         "'$SETUP_CMD' failed in a fresh clone of $HEAD_REF — the environment cannot be built here, so nothing below is a verdict on the work: $(tail -10 "$TMP/setup.log" | tr '\n' '|' | head -c 300)" \
         "" 3
fi

# The merge identity is configured locally, so a host with no global git identity
# can still make the commit. The merge itself happens below, AFTER the head-alone
# baseline: merging first would make an environment failure indistinguishable from
# a union failure.

# Nothing is assumed about the project: the command is the argument, and a
# missing target is UNRUNNABLE, not a failure of the work. `make -n` asks make
# itself rather than parsing a Makefile.
case "$CHECK_CMD" in
  make\ *) git -C "$REPO" rev-parse >/dev/null 2>&1
           ( cd "$REPO" && run_check make -n ${CHECK_CMD#make } >/dev/null 2>&1 ) \
             || emit unrunnable "'$CHECK_CMD' has no target in this tree" "" 3;;
esac

# THE HEAD ALONE IS THE BASELINE, AND IT IS WHY THIS FILE IS ALLOWED TO SAY "the
# union". Without it, a clone that is red for an ENVIRONMENT reason — dependencies
# absent on this host, a leaked `UV_OFFLINE`, a test that needs a service — is
# reported as `check-failed`, which spends a bounce round on something the
# implementer cannot fix and whose evidence line ("although both pass alone")
# nothing measured. A red head alone is `unrunnable`: the union cannot be judged
# from here, and that is a fact about this host, not about the work.
#
# The same variables `lane.sh` strips are stripped here, for the same reason: a
# driver's `UV_OFFLINE=1` or a `UV_CACHE_DIR` pointing at a directory this process
# cannot write turns every check red at the last moment (S2 measured the leak
# reaching the lane's own baseline).
if ! ( cd "$REPO" && run_check eval "$CHECK_CMD" ) >"$LOG" 2>&1; then
  emit unrunnable \
    "'$CHECK_CMD' already fails on $HEAD_REF ($HEAD_SHA) BEFORE the merge, in a fresh clone on this host — so the union cannot be judged here and this is not a verdict on the work: $(tail -20 "$LOG" | tr '\n' '|' | head -c 300)" \
    "" 3
fi
HEAD_ALONE=green

# RESTORE THE TRACKED TREE BEFORE THE MERGE. Setup and the head-alone check ran in
# this same clone, and either may rewrite a tracked file — a lockfile, generated
# code, formatter output. If `main` changed that file too, `git merge` refuses
# ("local changes would be overwritten"), and that used to be reported as a
# `conflict`: a bounce round the implementer cannot act on. `reset --hard` puts
# every tracked file back at the head commit. There is deliberately NO `git
# clean`: `-x` would delete the ignored environment setup built (`.venv`,
# `node_modules`) and turn the union check red for environment reasons, and
# even `-d` deletes an unignored one. An untracked file that still blocks the
# merge is caught by the classification below instead.
git -C "$REPO" reset --quiet --hard "$HEAD_SHA" >>"$TMP/merge.log" 2>&1 || emit unrunnable "cannot restore the tree to $HEAD_REF ($HEAD_SHA) after the head-alone check, so no merge was attempted: $(tail -3 "$TMP/merge.log" | tr '\n' '|' | head -c 300)" "" 3

git -C "$REPO" -c user.email=verifier@forge.invalid -c user.name=forge-verifier \
    merge --no-edit --no-ff "$BASE_SHA" >>"$TMP/merge.log" 2>&1 || {
  conflicts="$(git -C "$REPO" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
  # A MERGE THAT FAILED WITH NO CONFLICTED PATH IS NOT A CONFLICT. git refused for
  # a reason of its own — a dirty or locked tree, an untracked file in the way —
  # and nothing about that is the implementer's to fix. Reporting it as
  # `conflict` spends a bounce round on an instruction ("resolve the conflict")
  # that names no file and has nothing to resolve.
  [ -n "$conflicts" ] || emit unrunnable \
    "git refused to merge $BASE_REF ($BASE_SHA) into $HEAD_REF ($HEAD_SHA) with no conflicted path, so this is not a conflict in the work: $(tail -5 "$TMP/merge.log" | tr '\n' '|' | head -c 300)" \
    "" 3
  emit conflict \
    "merging $BASE_REF ($BASE_SHA) into $HEAD_REF ($HEAD_SHA) conflicts in: $conflicts" \
    "rebase this branch on $BASE_REF, resolve the conflict, and push" 1
}

if ( cd "$REPO" && run_check eval "$CHECK_CMD" ) >"$LOG" 2>&1; then
  emit pass "$CHECK_CMD is green on $HEAD_REF merged with $BASE_REF ($BASE_SHA), and was green on $HEAD_REF alone first" "" 0
fi
emit check-failed \
  "$CHECK_CMD fails on $HEAD_REF merged with $BASE_REF ($BASE_SHA) although it passes on $HEAD_REF alone in this same clone: $(tail -20 "$LOG" | tr '\n' '|' | head -c 400)" \
  "merge $BASE_REF into this branch locally, make the union green, and push" 1
