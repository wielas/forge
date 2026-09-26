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
#                  [--base-ref <branch>] [--check-cmd <cmd>] [--json]
#
# Exit: 0 the merged tree is green.
#       1 the merge conflicts, or the merged tree fails its check (actionable).
#       2 a usage error.
#       3 the check could not be run at all.
# =============================================================================
set -uo pipefail

CLONE_FROM=""; HEAD_REF=""; BASE_REF="main"; CHECK_CMD="make check"
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --clone-from) CLONE_FROM="${2:?--clone-from needs a url or path}"; shift 2;;
    --head-ref)   HEAD_REF="${2:?--head-ref needs a branch}"; shift 2;;
    --base-ref)   BASE_REF="${2:?--base-ref needs a branch}"; shift 2;;
    --check-cmd)  CHECK_CMD="${2:?--check-cmd needs a command}"; shift 2;;
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
  jq -n --arg result "$1" --arg evidence "$2" --arg action "$3" \
        --arg base "$BASE_REF" --arg head "$HEAD_REF" \
        --arg base_sha "${BASE_SHA:-}" --arg head_sha "${HEAD_SHA:-}" \
        --arg cmd "$CHECK_CMD" --arg head_alone "${HEAD_ALONE:-not-measured}" '
    { schema: "forge.mergecheck.v1", result: $result,
      base: $base, head: $head,
      base_sha: (if $base_sha == "" then null else $base_sha end),
      head_sha: (if $head_sha == "" then null else $head_sha end),
      check: $cmd, head_alone: $head_alone, evidence: $evidence,
      action: (if $action == "" then null else $action end) }'
  exit "$4"
}
command -v jq >/dev/null || { echo '{"schema":"forge.mergecheck.v1","result":"unrunnable","evidence":"jq is not on PATH"}'; exit 3; }

# A shallow clone cannot be merged against an arbitrary base, so this is a full
# one. `--no-tags` keeps it to the two refs that matter.
git clone --quiet --no-tags "$CLONE_FROM" "$REPO" 2>"$TMP/clone.err" \
  || emit unrunnable "clone of $CLONE_FROM failed: $(tr -d '\n' < "$TMP/clone.err" | head -c 200)" "" 3
git -C "$REPO" fetch --quiet origin "$BASE_REF" "$HEAD_REF" 2>/dev/null || true
# `--verify --quiet`, never a bare rev-parse: a bare one ECHOES the unresolved
# argument on stdout and exits non-zero, so `origin/nope` comes back as the
# STRING "origin/nope" and the absent-branch arm below never fires. Measured
# while writing this file.
BASE_SHA="$(git -C "$REPO" rev-parse --verify --quiet "origin/$BASE_REF" 2>/dev/null || true)"
HEAD_SHA="$(git -C "$REPO" rev-parse --verify --quiet "origin/$HEAD_REF" 2>/dev/null || true)"
[ -n "$BASE_SHA" ] || emit unrunnable "no origin/$BASE_REF in the clone" "" 3
[ -n "$HEAD_SHA" ] || emit unrunnable "no origin/$HEAD_REF in the clone — was the branch deleted?" "" 3

git -C "$REPO" -c advice.detachedHead=false checkout --quiet "$HEAD_SHA" 2>/dev/null \
  || emit unrunnable "cannot check out $HEAD_REF at $HEAD_SHA" "" 3

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

git -C "$REPO" -c user.email=verifier@forge.invalid -c user.name=forge-verifier \
    merge --no-edit --no-ff "$BASE_SHA" >"$TMP/merge.log" 2>&1 || {
  conflicts="$(git -C "$REPO" diff --name-only --diff-filter=U | tr '\n' ' ')"
  emit conflict \
    "merging $BASE_REF ($BASE_SHA) into $HEAD_REF ($HEAD_SHA) conflicts in: ${conflicts:-<see merge output>}" \
    "rebase this branch on $BASE_REF, resolve the conflict, and push" 1
}

if ( cd "$REPO" && run_check eval "$CHECK_CMD" ) >"$LOG" 2>&1; then
  emit pass "$CHECK_CMD is green on $HEAD_REF merged with $BASE_REF ($BASE_SHA), and was green on $HEAD_REF alone first" "" 0
fi
emit check-failed \
  "$CHECK_CMD fails on $HEAD_REF merged with $BASE_REF ($BASE_SHA) although it passes on $HEAD_REF alone in this same clone: $(tail -20 "$LOG" | tr '\n' '|' | head -c 400)" \
  "merge $BASE_REF into this branch locally, make the union green, and push" 1
