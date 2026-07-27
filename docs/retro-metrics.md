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
| _(none yet)_ | — | n/a | n/a | n/a | — | — |

**Baseline (2026-07-27):** no chunk card has ever completed, so all three are
`n/a` by measurement, not by omission. The first real row comes from the
hello-chunk run and whatever follows it. Until then there is no baseline, and
any claim that Forge is improving is unfalsifiable.
