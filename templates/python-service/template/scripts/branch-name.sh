#!/usr/bin/env bash
# The chunk branch-name rule, in ONE place (audit F7).
#
# AGENTS.md requires `chunk/<id>-<slug>`. Nothing enforced it, so on
# forgeboard-report the lane pushed `chunk/1`…`chunk/6` six times: CHUNK-1 and
# CHUNK-2 merged in violation, CHUNK-3–6 were bounced on the name alone and
# closed PRs #4, #6, #8 and #10 unmerged. `t_298e46f4` is the case that names
# the cost — verdict `bounce` with the first three dimensions scored 3/3/3.
# Exemplary work, rejected after implementation, prejudge and review had all
# been paid for, to enforce a regex.
#
# This file exists so the pattern is written once. It is called by lefthook
# pre-push (fast, local, skippable) and by CI (authoritative, not skippable) —
# ADR-0003 names both tiers, and a regex duplicated across two config files is
# a third copy of the rule waiting to disagree with the other two.
#
# Usage: branch-name.sh [branch]
#   With no argument it asks git. In CI on a pull_request the checkout is a
#   detached merge ref, so the caller must pass `github.head_ref` explicitly —
#   HEAD there is not the contributor's branch.
set -euo pipefail

branch="${1:-}"
if [ -z "$branch" ]; then
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
fi

# `main` is not a chunk branch and is not this rule's business. `no-main-push`
# in lefthook.yml owns main-branch policy INCLUDING its bootstrap exception,
# and a second opinion here would re-block the push that creates main — the
# rung-1 failure that exception exists to fix.
[ "$branch" = "main" ] && exit 0

# Detached HEAD. lefthook does not forward git's stdin, so a pre-push hook can
# see the remote it is pushing to but never the refs being pushed (measured
# 2026-07-28, documented in lefthook.yml). With no branch name there is no
# question to answer, and inventing a "no" here would block legitimate
# `git push origin <sha>:refs/heads/...` work for a rule that could not see it.
if [ "$branch" = "HEAD" ] || [ -z "$branch" ]; then
  echo "branch-name: detached HEAD, nothing to check" >&2
  exit 0
fi

# <id> is `[A-Za-z0-9]+` with optional dotted segments — `7`, `C6`, `C9.1`.
# <slug> is lowercase alphanumeric words joined by SINGLE hyphens.
#
# Both halves were wrong here, in opposite directions. `[A-Za-z0-9]+` refused
# every dotted id, so `chunk/C7.1-mirror-and-migration-hardening` was blocked at
# push time; `[a-z0-9-]+` accepted `chunk/7--foo`, which scripts/prejudge.sh's
# copy of this rule refused at review time. A branch that passes the hook and
# fails the gate costs F7's price after the work is done, which is exactly what
# writing the rule once was meant to prevent — so this pattern and the one in
# `branch_name()` in scripts/prejudge.sh are now the same string, and must stay
# that way. `make verify` probes both against the same names.
if printf '%s' "$branch" | grep -Eq '^chunk/[A-Za-z0-9]+(\.[A-Za-z0-9]+)*-[a-z0-9]+(-[a-z0-9]+)*$'; then
  exit 0
fi

echo "BLOCKED: branch '$branch' is not a chunk branch." >&2
echo "  AGENTS.md requires chunk/<id>-<slug>, e.g. chunk/7-render-report." >&2
echo "  Rename before pushing: git branch -m chunk/<id>-<slug>" >&2
echo "  Not a chunk? Locally this is advisory: git push --no-verify" >&2
echo "  (CI enforces the same rule on pull requests, where it is not.)" >&2
exit 1
