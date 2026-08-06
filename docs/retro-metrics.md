# Retro metrics — does the flywheel actually turn?

`/retro` proposes changes to Forge itself. Nothing measured whether any of them
helped, so the loop could only accumulate: it had no way to tell an improvement
from a regression, and every proposal was equally defensible.

Three numbers, recorded once per retro period, plus a fourth added 2026-08-04
when tier 1 grew a deterministic first stage. They are deliberately few. A
number nobody reads is worse than no number, because it looks like rigour.

## Who computes these

`scripts/metrics.sh`, and nothing else:

```bash
make metrics BOARD=<slug> [SINCE=YYYY-MM-DD] [UNTIL=YYYY-MM-DD]
./scripts/metrics.sh <slug> --since .. --until .. --markdown-row   # a Log row
```

Every row below the separator in the Log is pasted from `--markdown-row`. This
is not ceremony. Until 2026-07-30 the numbers were derived by a language model
reading printed board output, and every way that could fail, it did: the bounce
rate read `0.00` for a run with 12 bounces (F3), one row reads `n/a` because a
key was misspelled, the largest run in the project's history had no row at all,
and 22 malformed chunk envelopes went unseen for three days. See audit F27.
**Deriving any of these by hand is a defect, not a fallback.**

## The numbers

### 0. Gate block rate — and why it is not a bounce rate

**Definition:** `gate runs that blocked / gate runs`, over the period, plus the
distribution of **which check did the blocking**. Reported first and labelled
separately. It is *not* a bounce rate and must never be averaged into one.

**Source:** `forge.gate.v1` results on `task_runs` — `$.result` for the rate,
`$.blocks[]` for the per-check distribution. Emitted by `scripts/prejudge.sh`
and stored unmodified by the `forge-prejudge` driver (ADR-0009 D9.4).

**Why it is its own number.** A gate block costs **zero model tokens and zero
scorer latency**, because it lands before anything is spawned; a bounce costs a
full review. They are different events with different prices, and a single
blended rate would hide the gap between a filter and a judge — the same defect,
from the other side, as the tier-blind rate F3 exposed. It would also make
ADR-0009 D9.5's experiment unreadable: if a gate block and a model bounce are
one number, no later period can show which stage did the filtering.

**Reads as:** how much of what reaches review is mechanically wrong. A period
where this rises while tier 2's bounce rate falls is the change working — the
program absorbing defects that used to cost a human. A period where the
`by_check` distribution collapses onto one check is a gate with one useful check
in it, and that is worth knowing before anyone concludes the other six earn
their place.

**No dollar figure belongs here.** The blocked path avoids OAuth work, which is
free at the margin, and the metered driver has no cost telemetry at all (F48).
The saving is spawns and latency; say that, and do not convert it to money.

### 1. Bounce rate

**Definition:** `bounced chunk cards / chunk cards judged at that tier`, over
the period, **reported separately for tier 1 and tier 2**. A chunk counts as
bounced if **any** verdict against it was `bounce`, even if a later attempt was
approved — the cost was already paid.

**Source:** canonical `forge.judge.v1` verdicts on `task_runs`, attributed to
the chunk card the reviewed card hangs off. Tier comes from the `profile` of the
run carrying the verdict — `forge-prejudge` is tier 1, everything else including
an operator's unassigned card is tier 2 — never from the card title.

**Tier 1's number now covers its model stage only.** Since ADR-0009 tier 1 is
two stages: a gate that emits `forge.gate.v1` and never scores, then the
`claude -p` scorer that emits `forge.judge.v1` as before. Only the second
produces a verdict, so only the second appears here. Gate blocks are number 0
above, and a PR that the gate blocked never reached the scorer at all — so the
two denominators are different populations, not two views of one.

**Changed 2026-07-30 (F3), and this is the correction that motivated it.** The
old definition counted tier-1 verdicts only. Tier 1 bounced **0 of 17** on the
`forgeboard-report` run while tier 2 bounced **12**, so the published figure for
the largest run to date was `0.00` — blind to the run's dominant failure mode
*by construction*. A single blended rate would have hidden it just as well in
the other direction, so the two tiers are reported side by side: they measure
different filters, and the gap between them is itself the diagnostic.

**Denominator honesty.** A chunk that was never judged at a tier cannot have
bounced at it, so the denominator is chunk cards that received at least one
canonical verdict at that tier — not all completed chunks. When those differ, the
gap is a metadata-discipline problem and belongs in the row's prose. Chunk cards
are identified by card **shape** (a completed card parenting a `forge-prejudge`
card, or one with a `forge-codex-lane` run), never by "carries a chunk
envelope" — that would drop malformed runs out of the denominator and hide the
exact defect the envelope count exists to find.

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

**Definition:** counts per class over the period's `blocked` events, where the
class is the leading `<token>:` of the block reason. The machine source is
`rubrics/run-metadata-contract.json`; its current documented vocabulary is:
`stale-spec`, `failing-prereq`, `env`, `ci-red`, `judge-bounce`,
`gate-misrouted`, `gate-unrunnable`, `other`. `gate-unrunnable` was added
2026-08-04 with ADR-0009: it is the prejudge driver's reason when
`scripts/prejudge.sh` exits 2 — no `gh`, no network, PR unreadable — and it is a
fact about the substrate, never a verdict on the work. `ci-red` stays in the
vocabulary for the historical rows that carry it; new CI failures block at the
gate instead. Anything whose reason does not begin with a bare
lowercase slug is `(unclassified)`; a class outside the vocabulary is counted
and flagged rather than folded into `other`.

**Source:** `task_events.payload.reason` where `kind='blocked'`.

**Not `forge.block.v1` — that envelope has never existed and cannot (F26).**
`kanban_block` takes no metadata parameter, so nothing can carry it; the count
of runs carrying it is printed on every report and has always been 0. The
leading-token convention is what emerged instead, and it is followed about a
quarter of the time, which is why `(unclassified)` is large and load-bearing.
A period dominated by `(unclassified)` is not a period without problems — it is
a period whose *producers* are broken, and that is the finding.

**Reads as:** where the system loses runs. It is a distribution, not a scalar,
on purpose — the shape names the layer to fix. A period dominated by `stale-spec`
is a roadmap problem; by `env`, a substrate problem. A large `other` bucket means
the vocabulary is wrong and should be extended.

## Cost, and why it is not a fourth number yet

`forge.judge.v1` carries `tokens_estimate` and a full `cost` block since
2026-08-01 (audit F30). Neither is a retro metric, and the reason is worth
stating so nobody promotes one by default.

**`tokens_estimate` = `input + cache_creation + output`** — tokens new to the
model on that call. It deliberately **excludes `cache_read`**: cached re-reads
are real tokens but counting them would make a resumed session score higher than
a cold one, which inverts the signal delta review exists to produce.

**Series break 2026-08-01 (F45).** Before that date the field was
`input + output`, which on `claude -p` measured *output alone* — the prompt is
billed to `cache_creation_input_tokens`, and a 131 KB prompt contributes ~9 to
`input_tokens`. Verdicts either side of that date are not comparable. No row
below has ever carried a token figure, so no published series is affected.

**`cost.total_cost_usd` is recorded and is not the headline.** On the OAuth path
it is a notional price nobody pays. The metered path is the
`deepseek-v4-flash` Hermes profiles, and that side has **no telemetry and no
column to hold any** (F48). A cost number here would measure the free half of a
two-engine system and read as rigour.

The fourth number lands when F48 does, not before.

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
| 2026-07-28 | ladder run, rung 4 (`forge-ladder`) | 0.00 (0/1) | 3.00 (1 verdict) | `other` ×1 (tier-2 card on a ghost assignee) | 1 finding, detection added; the underlying gap left OPEN | **no** — the tier-2 SOUL fix did not produce the specified card shape |
| 2026-07-28 | controlled bounce, PR #6 (`forge-ladder`) | 1.00 (1/1) | 2.33 (1 verdict) | empty (0 blocked cards) | worktree route, hard driver boundary, clean-worktree proof | yes for routing/role; clean proof awaits the next lane |
| 2026-07-28 | dependency D1 → D2 (`forge-dependency-clone-20260728`) | 0.00 (0/2) | 3.00 (2 verdicts) | `failing-prereq` ×1 | atomic parent creation, merged-PR gate, no implicit stacks | no — 3/3 scope score missed D1 files in D2 PR |
| 2026-07-28 | CI-red recovery, PR #10 (`forge-dependency-clone-20260728`) | n/a — observed bounce used noncanonical metadata | 3.00 (1 green verdict; red sentinel absent) | empty (0 blocked cards) | repo-independent `gh`; canonical CI-red verdict | yes — worktree repair and clean proof both held live |

*Rows below this line are generated by `scripts/metrics.sh --markdown-row`. Only
the last two columns are written by a human.*

| 2026-07-30 | forge-ladder, 2026-07-29..2026-07-30 | t1 0.00 (0/7) · t2 0.71 (12/17) | 2.19 (24 verdicts) | `(unclassified)` ×20, `failing-prereq` ×8, `review-required` ×1 | `make metrics` (F27): the three numbers become a program | **cannot tell** — no CI-red bounce occurred, so last period's canonical CI-red verdict was never exercised |

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

**Rows two and three (2026-07-28, ladder run).** Two chunks on board
`forge-ladder`, one per row: `CHUNK-C3` (card `t_01649280`, prejudge
`t_4a0f55d3`, PR #4) and `CHUNK-C4` (card `t_c0f8f0bc`, prejudge `t_cfc13c3e`,
PR #5). Both completed on their first run, both returned `approve` with 3/3 on
every dimension, both green and merged after a hand review at tier 2.

Both things the baseline said to watch got worse, not better:

- **d1–3 was 3.00 for the third time here — eighteen dimension scores, eighteen
  3s.** Superseded later the same day: the controlled-bounce row below scored
  **2.33**, the first non-3 this rubric has ever produced. The worry recorded
  here was answered by injecting a fault, not by waiting.
  The baseline called a single 3.00 indistinguishable from an undiscriminating
  filter. Three of them is not evidence of quality; it is the same non-evidence
  three times, and the case for treating the score as decorative is stronger
  each time it repeats.
- **Bounce rate was still 0.00 (0/3) at this point.** Also answered below: the
  controlled bounce made it 1.00 (1/1) for that period.

The `reason_class` bucket is `other` in the two rung rows, which is the
vocabulary doing its job: "the tier-2 review card did not land as a human gate"
is not `stale-spec`, `env` or `ci-red`. It happened **twice** — once dispatched
to a lane, once parked on a ghost assignee — which was the stated bar for
extending the vocabulary. The next retro should add a class for it
(`gate-misrouted` or similar) rather than let `other` absorb a recurring
failure.

The rung-4 row is the one that earns its keep: it is the first row in this file
to answer *"did last period's fix do what it claimed?"* with **no**. The
read-back added after rung 3 stopped the tier collapse but still produced
`assignee="forge-operator", status="ready"` instead of unassigned + blocked. It
held only because that profile does not exist. That row is the reason the
sticky-sentinel handoff below was built, and it is why the answer column is not
decoration.

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

**`forgeboard-report` row (2026-07-30) — the first machine-generated row, and
the one this file was missing.** Six chunks, five merged, on board
`forge-ladder`; the largest run in the project's history and, until now, the
only one with no row at all. Reproduce it with
`make metrics BOARD=forge-ladder SINCE=2026-07-29 UNTIL=2026-07-30`.

- **`t1 0.00 (0/7) · t2 0.71 (12/17)` is the whole of F3 in one cell.** The old
  definition would have published `0.00` for this run. Tier 1 approved
  everything it looked at; tier 2 bounced 12 of the 17 chunk cards it judged.
  Both numbers are true, and reporting only the first was the defect.
- **Tier 1's denominator is 7, not 17, and that is a finding rather than a
  sample size.** Seventeen prejudge runs executed in this window; only **7**
  carry canonical `forge.judge.v1`. The other ten have the right *shape* and no
  `schema` key, so nothing can count them. They are not backfilled here. The
  honest reading is that tier 1's rate covers under half of tier 1's work.
- **`(unclassified)` ×20 is the F26 story, measured.** Twenty-two of this
  board's block events read `tier-2 operator review required: …`, which carries
  no class token. `forge.block.v1` runs: **0**, as always.
- **Zero conforming chunk envelopes.** All 17 chunk completions in the window
  nest under `$."forge.chunk.v1"`; none uses the documented flat shape. That
  count is why `forgeboard-report` exits 4 on the board that built it (F1), and
  it was available in SQL from the first day of the run.
- **Operator touches: 9 (1 comment + 8 unblocks).** This is a floor, not a
  count. The operator drove 17 tier-2 reviews off-board, closed 4 PRs by hand
  and assembled every review prompt manually; none of that touches the board, so
  none of it is here (F31). A metric that cannot see the human is exactly how a
  change that improves all three numbers while costing more operator time gets
  called an improvement.

**One correction this row makes to the audit that commissioned it.** The audit
reports mean tier-2 d1–3 as **1.90** (§"The run, in numbers", F3, F27). It is
**1.88** — 96 dimension points over 51 dimensions, 17 verdicts, no nulls. The
board-lifetime figures in F27 all reproduce exactly, and they are the ones that
came with an executed query attached; 1.90 was asserted in prose beside it. The
audit's own thesis, arriving one day early and at its own expense.

**CI-red row.** The operational loop worked: Tier 1 saw red, created fix card
`t_0a443d25` in the rejected branch's worktree, the lane removed only the
injected failure, PR #10 turned green, and the second Tier 1 run handed off to
the operator. The metric did not: the first review stored custom
`forge.prejudge.v1.*` keys instead of `forge.judge.v1`, so the definition above
cannot count its real bounce. The row stays `n/a` rather than being backfilled
from prose. The corrected protocol emits zero-score canonical metadata without
calling the judging model.
