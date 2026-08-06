# ADR-0008: Code dependencies wait for integration

**Status:** accepted · 2026-07-28

## Context

Hermes dependency edges gate on card state. A Forge chunk card becomes `done`
when its PR opens so Tier 1 can run as a child. Therefore `parent card done`
means **implementation handed off**, not **parent code present on `main`**.

The first live two-chunk graph made the mismatch concrete:

- D1 opened PR #7 and completed.
- Hermes promoted D2 in the same second while PR #7 was still open.
- D2 correctly found its required `stable_key` absent and blocked with kind
  `dependency`.
- Because the linked D1 card was already done, Hermes promoted D2 again one
  second later.
- The retry invented a stacked-branch policy by rebasing onto `chunk/d1`.
  PR #8 was green but contained all six D1+D2 files against `main`; Tier 1
  nevertheless scored scope discipline 3/3.

Board state alone cannot prove code integration, and silently stacking branches
changes both review scope and merge topology.

## Decision

**D8.1 — Graph edges are atomic at card creation.** `board-bootstrap.sh`
creates cards in topological order and passes every dependency as `--parent`
in the child's `kanban create` call. It reads the parent ids back before
continuing. A dependent card is never briefly dispatchable without its edge.

**D8.2 — A dependent lane requires merged parent PRs.** Before setup or Codex,
`forge-lane` inspects parent chunk metadata and queries every parent PR. An open
parent PR produces a sticky `needs_input` block with
a reason prefixed `failing-prereq:`.

**D8.3 — Retry rebases onto the integrated base.** After the operator merges
the parent and unblocks the child, the lane fetches and rebases the still-clean
child branch onto the parent PR's base before baseline verification.

**D8.4 — No implicit stacked PRs.** A lane may not rebase onto an unmerged
parent branch. Stacking requires an explicit architecture decision covering PR
bases, judge diff ranges, merge order, and branch deletion; Forge does not
currently have that policy.

## Consequences

- A dependency can require one human unblock after its parent merge. That is
  honest operator work; pretending an open PR is integrated merely moves the
  work into correction.
- Tier 1 sees a single-chunk diff, so scope scores are meaningful.
- Parallel independent chunks still run; code-dependent chunks serialize at
  the merge boundary.
- A future integration-gate card could automate the unblock without changing
  these semantics.

## Rejected

- **Treat parent-card completion as integration.** Measured false.
- **Use block kind `dependency` after the parent card is done.** It immediately
  re-promotes and loops.
- **Silently stack branches.** It made PR #8 green but polluted its review diff
  and escaped a 3/3 scope judge.
