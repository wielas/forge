---
name: start-chunk
description: Opening ceremony for implementing one chunk with BDD/TDD discipline. Use for /start-chunk <id>, "implement chunk X", or when a worker picks up a chunk card.
---

# start-chunk — implement exactly one chunk, fresh context, scenario by scenario

You implement ONE chunk. Not two. Discoveries beyond this chunk become decision-log
entries or new card proposals — never scope creep.

## 1. Gather context (read, in order)
1. `docs/chunks/CHUNK-<id>.md` (or the kanban card body — same text), the feature
   named by its `Acceptance` field, and that feature's entry in
   `docs/chunks/contract-freeze.json`.
2. `AGENTS.md` · the ADRs listed in the chunk · `docs/decision-log.md` (skim for
   entries touching the same paths).
3. `git log --oneline -15` on main, to see what recently landed.

## 2. Restate & reconcile
Write a 5-line restatement: goal, scenarios, files, what's out of scope, and the
DONE condition. Compare against current code — if the chunk spec is stale
(prereq changed, file moved), reconcile: small drift → note it in the decision
log and adapt; contradiction → STOP, block the card with the reason
(unattended lane) or ask the human (interactive).

**A `Depends on:` chunk releases when its parent CARD is `done`, not when the
parent's code is merged into `main`.** Before branching, for every declared
dependency check that its handoff PR is actually merged:
`gh pr view <parent PR> --json state,mergedAt`. A non-null `mergedAt` on every
one clears this step; an open parent PR means you would be building on code
that is not in `main` yet — stop and say so (block, unattended; tell the human,
interactive) rather than branching. `forge-lane` §1a is the unattended lane's
identical check, including the narrow bounce-remediation exception for
repairing an already-rejected PR on the same branch — read it there rather
than re-deriving the exception here.

## 3. Mark in progress & branch
Branch only if you are not already on the chunk branch. In a Hermes worktree the
dispatcher created the workspace and checked out the branch **before** the worker
started, so `git switch -c` there fails on a branch that already exists.

The branch must start after the planning PR that approved its frozen acceptance.
If acceptance genuinely needs amendment, stop and land a separate human planning
PR that changes the contract, feature, and regenerated manifest together; only
then start or rebase the implementation branch onto that approved hash.

This skill assumes **network and a built `.venv`** — it is for an operator
driving the repo directly. Inside a `codex exec` sandbox neither holds: the
fetch below fails with `Could not resolve hostname` (measured 2026-07-28), and
`forge-lane` §3 is what makes the worktree usable before Codex ever sees it.

```bash
branch=chunk/<id>-<slug>
git fetch origin
if [ "$(git rev-parse --abbrev-ref HEAD)" != "$branch" ]; then
  git switch -c "$branch" origin/main 2>/dev/null || git switch "$branch"
fi
```
Interactive: tick the ROADMAP checkbox in your first commit.
Unattended: the lane runner has already claimed the card — do not touch the board.

## 4. Scenarios first
The planning pass already translated the chunk's Given/When/Then lines into the
feature named by `Acceptance` and froze its exact bytes. Do not edit that feature
or regenerate `contract-freeze.json` on the implementation branch. Add only the
step definitions in `tests/steps/`, then run them; they MUST fail for the right
reason before any implementation.
Commit: `test(<id>): add failing scenarios`.

## 5. Implement scenario-by-scenario
For each scenario: red → green → refactor. Granular commits, imperative messages,
scoped `type(<id>): message`. Never weaken a scenario to make it pass — if a
scenario is wrong, that is a decision-log entry plus (interactive) human ping or
(unattended) an explicit note in the PR body.

## 6. Prove it
```bash
make check     # format + lint + full tests + BDD; THE definition of green
```
Paste the trailing summary into your notes. Not green = not done; no exceptions,
no `--no-verify`, ever.

## 7. Log the unexpected
Append to `docs/decision-log.md` anything future sessions need: surprises,
workarounds, deviations from the chunk spec, debt knowingly introduced
(prefix `DEBT:`), follow-up ideas (prefix `CARD?:`).

Then run /end-chunk. If the session must stop early: commit WIP on the branch,
write a `HANDOFF:` entry in the decision log stating exact state and next step.
