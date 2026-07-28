# Retro metrics — does the flywheel actually turn?

`/retro` proposes changes to Forge itself. Nothing measured whether any of them
helped, so the loop could only accumulate: it had no way to tell an improvement
from a regression, and every proposal was equally defensible.

Three numbers, recorded once per retro period. They are deliberately few. A
number nobody reads is worse than no number, because it looks like rigour.

## The three numbers

### 1. Bounce rate

**Definition:** `bounced chunk cards / completed chunk cards`, over the period.
A chunk counts as bounced if any tier-1 verdict against it was `bounce`, even if
a later attempt was approved — the cost was already paid.

**Source:** `forge.judge.v1` verdicts in card metadata (`.verdict == "bounce"`),
counted against completed chunk cards on the period's boards.

**Reads as:** how often work reaches review in a state review rejects. Rising
means chunks are too big, contracts too vague, or the lane model too weak — the
retro's job is to say which.

### 2. Mean judge score, dimensions 1–3

**Definition:** the arithmetic mean of `spec_fidelity`, `scenario_integrity` and
`architectural_conformance` across every verdict in the period. Range 0–3.

**Source:** `forge.judge.v1` `.scores`. Dimensions 4–6 (scope discipline, debt
honesty, doc reconciliation) are deliberately excluded: they measure hygiene,
which gates already enforce. 1–3 measure whether the work was *right*.

**Reads as:** quality of what survives to review. This is the number that must
not fall when the bounce rate falls — the two together catch a "fix" that merely
made review more permissive.

### 3. `reason_class` distribution

**Definition:** counts per `reason_class` from `forge.block.v1` metadata on
blocked cards: `stale-spec`, `failing-prereq`, `env`, `ci-red`, `judge-bounce`,
`other`.

**Source:** `forge.block.v1` in blocked-card metadata.

**Reads as:** where the system loses runs. It is a distribution, not a scalar,
on purpose — the shape names the layer to fix. A period dominated by `stale-spec`
is a roadmap problem; by `env`, a substrate problem. A large `other` bucket means
the vocabulary is wrong and should be extended.

## How this is used

- `/retro` step 1 opens by reporting **whether the numbers moved since the last
  retro**, and whether the changes proposed last time had their stated effect.
- `/retro` step 3 requires each proposed change to name the number it expects to
  move, and in which direction. **A proposal that cannot name its metric is a
  preference, not a lesson** — park it or drop it.
- A change whose number did not move within two retro periods is reverted or
  re-argued from new evidence. Accumulating unfalsifiable improvements is the
  failure mode this file exists to prevent.

## Honesty rules

- Record the period even when the numbers are **unavailable** — write `n/a` and
  why. A missing row is indistinguishable from a skipped retro.
- Never backfill a row from memory. If the exhaust is gone, the row is `n/a`.
- Small n is normal early. Report the denominator, not just the rate: `0.33 (1/3)`
  is honest, `33%` is not.

## Log

One row per retro. Newest last.

| Retro date | Period | Bounce rate | Mean score d1–3 | `reason_class` distribution | Changes proposed | Did last period's changes move their number? |
|---|---|---|---|---|---|---|
| 2026-07-28 | hello-chunk (first run) | 0.00 (0/1) | 3.00 (1 verdict) | empty (0 blocked cards) | — (baseline row) | n/a — no prior period |
| 2026-07-28 | ladder run, rung 3 (`forge-ladder`) | 0.00 (0/1) | 3.00 (1 verdict) | `other` ×1 (tier-2 card misrouted, self-blocked) | 8 findings, 5 fixed — see `docs/ladder-2026-07-28.md` | n/a — no changes were proposed last period |
| 2026-07-28 | controlled bounce, PR #6 (`forge-ladder`) | 1.00 (1/1) | 2.33 (1 verdict) | empty (0 blocked cards) | worktree route, hard driver boundary, clean-worktree proof | yes for routing/role; clean proof awaits the next lane |
| 2026-07-28 | dependency D1 → D2 (`forge-dependency-clone-20260728`) | 0.00 (0/2) | 3.00 (2 verdicts) | `failing-prereq` ×1 | atomic parent creation, merged-PR gate, no implicit stacks | no — 3/3 scope score missed D1 files in D2 PR |
| 2026-07-28 | CI-red recovery, PR #10 (`forge-dependency-clone-20260728`) | n/a — observed bounce used noncanonical metadata | 3.00 (1 green verdict; red sentinel absent) | empty (0 blocked cards) | repo-independent `gh`; canonical CI-red verdict | yes — worktree repair and clean proof both held live |

**Baseline (2026-07-28).** `CHUNK-HELLO-1` on board `forge-hello`: card
`t_1b7be3bb` completed on its first run, prejudge `t_1570a10e` returned
`approve` with 3/3 on every dimension, PR #1 green, nothing blocked.

Read this row with more suspicion than pride. **n = 1, on a six-line function
written to be easy.** A perfect score on the first measurement is exactly what
a filter that is not discriminating would also produce, so this row cannot yet
distinguish "the work was good" from "tier 1 approves everything". The second
and third rows are what make it a metric rather than a number.

Two things to watch specifically:

- **If d1–3 stays at 3.00 across the next few chunks, the score is decorative**
  and the rubric needs sharper discrimination, not congratulation.
- **Bounce rate of 0.00 is only meaningful once something has bounced.** Until
  a bounce happens the tier-1 filter is unproven in the direction that matters:
  we have never seen it reject anything.

**Second row (2026-07-28, ladder run).** `CHUNK-C3` on board `forge-ladder`:
card `t_01649280` completed on its first run, prejudge `t_4a0f55d3` returned
`approve` with 3/3 on every dimension, PR #4 green and merged after a hand
review at tier 2.

Both things the baseline said to watch got worse, not better:

- **d1–3 is 3.00 for the second time — twelve dimension scores, twelve 3s.**
  The baseline called a single 3.00 indistinguishable from an undiscriminating
  filter. Two of them is not evidence of quality; it is the same non-evidence
  twice, and the case for treating the score as decorative is now stronger.
- **Bounce rate is still 0.00 (0/2).** Nothing has ever been rejected.

The `reason_class` bucket is `other` ×1, which is the vocabulary doing its job:
"the tier-2 review card was dispatched to a lane instead of a human" is not
`stale-spec`, `env` or `ci-red`. One occurrence does not justify extending the
vocabulary; a second would.

**Controlled bounce row.** This is fault injection, not a production-quality
sample. The PR was deliberately CI-green while its Then step returned a boolean
that pytest-bdd ignores. Prejudge scored d1–3 as 3/1/3 and emitted an executable
bounce. The first fix route defaulted to scratch; the corrected route resumed
the rejected branch's preserved linked worktree. See
`docs/experiment-2026-07-28.md` for the operator-time and correction ledger;
the three retro numbers above are diagnostic exhaust, not the success criteria.

**Dependency row.** Card-level gating worked, but D2 promoted when D1 merely
opened PR #7. Its first `dependency` block immediately auto-promoted because
the linked card was already done; its retry invented a stack, and PR #8 showed
six D1+D2 files against `main`. Tier 1 still returned 3/3 scope discipline.
ADR-0008 moves the gate to parent `mergedAt` and keeps the wait sticky.

**CI-red row.** The operational loop worked: Tier 1 saw red, created fix card
`t_0a443d25` in the rejected branch's worktree, the lane removed only the
injected failure, PR #10 turned green, and the second Tier 1 run handed off to
the operator. The metric did not: the first review stored custom
`forge.prejudge.v1.*` keys instead of `forge.judge.v1`, so the definition above
cannot count its real bounce. The row stays `n/a` rather than being backfilled
from prose. The corrected protocol emits zero-score canonical metadata without
calling the judging model.
