# ADR-0007: Two-tier judging — a cheap unattended filter, then the operator

**Status:** accepted · 2026-07-27

## Context

Chunks land as PRs while nobody is watching. Something has to decide whether a PR
is worth a human's attention, and the obvious failure modes are cheap to detect
and expensive to miss: red CI, scenarios that assert nothing ("scenario theater"),
and diffs that quietly exceed the chunk contract.

ADR-0004's original answer was a single metered judge with a monthly budget. That
premise died with the ADR: `claude -p` authenticates on a subscription headlessly,
so review capacity is no longer the scarce resource. **Operator attention is.**

## Decision

**D7.1 — Tier 1 is `forge-prejudge`, unattended, and it only bounces.** It reads
the diff, the scenarios and the CI result against `rubrics/judge-rubric.md` and
rejects the obvious: ci-red, scenario theater, scope creep beyond the contract.
It never approves anything into main; the best it can do is stay silent and let
the PR through to a human. An unattended process that can only *reject* has a
bounded blast radius when it is wrong.

**D7.2 — Tier 2 is the operator running `/judge` in Claude Code.** Interactive,
subscription-covered, zero marginal cost, and a far better fit for "read the
judge report, spot-check the two things that smell" than any attempt to automate
final approval. This is a deliberate choice to keep a human in the loop where
judgement is actually required, not a stopgap until we can automate it away.

**D7.3 — Auto-merge only where both signals agree.** `planned — not implemented`
*(status as of 2026-07-27; nothing in the repo implements this, and it must not
be read as a property the system has.)* A PR would merge without a human tap only
when it is judge-approved **and** the chunk was tagged low-risk at roadmap time.
Risk is assigned before implementation exists, by whoever wrote the chunk
contract — so the tag cannot be influenced by the diff that wants to merge.
Everything else waits for a tap.

Prerequisite: auto-merge is meaningless until a merge gate exists off the host.
`make protect` (GitHub branch protection) is that gate; the local pre-push hook
is advisory and bypassable.

**D7.4 — The verdict is structured.** Tier-1 verdicts use `--output-schema`
(`claude -p` takes `--json-schema`) so the result is machine-readable without
parsing prose, and land as card metadata per `rubrics/judge-rubric.md`. /retro
mines those verdicts across cards; a free-text verdict would teach it nothing.

## Consequences

- The expensive tier is now attention, not tokens, so tier 1 can afford to read
  the entire diff rather than a summary.
- Tier 1 can be wrong in one direction only. A false bounce costs a retry; a
  false approval is impossible by construction.
- The judge is a **card**, not a step inside the lane. It is created by the lane
  on completion with `parents=[<chunk card>]`, which means it inherits the
  board's retry and stranding machinery for free — and it also means a stranded
  judge card silently leaves a chunk unreviewed. Watch `kanban diagnostics`.
- The lane completing its own card while review is still pending is a small lie
  on the board. Hermes's own guidance prefers `kanban_block(reason="review-
  required: …")` for exactly this reason. We chose completion + a child card
  because blocking conflates "needs review" with "failed", and because unblocking
  would have to be done by the prejudge profile acting on its parent. **If the
  hello-chunk run shows the child card is unreliable, switch to `review-required`
  — that is the honest fallback, and this decision is the weakest one here.**

## Rejected

- **A single strong judge with merge rights.** Removes the human from the only
  step where taste matters, and makes a false approval unrecoverable.
- **A metered judge model.** Withdrawn with ADR-0004; there is no longer a reason
  to pay per token for review.
- **Judging inside the lane worker.** The implementer reviewing its own diff in
  the same context is not review. Fresh context is the point.
