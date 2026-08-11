# ADR-0009: The tier-1 gate — a deterministic first stage, before the model

**Status:** accepted · 2026-08-04
**Supersedes:** nothing. **ADR-0007 D7.1 stands**: tier 1 still makes a
`claude -p --model opus` scoring call, and this ADR does not remove it, re-model
it or re-frame it. It inserts a stage in front of it and takes the mechanical
half of its mandate away.

## Context

D7.1 says tier 1 *"reads the diff, the scenarios and the CI result against
`rubrics/judge-rubric.md`"* and rejects *"ci-red, scenario theater, scope creep
beyond the contract"*. Two of those three are decidable without a model, and the
`forgeboard-report` run measured what happens when a model is asked anyway.

**Measured, 17 tier-1 runs on 11 PRs** (audit F4, F20, F35):

| | tier 1 (`opus`) | tier 2 (operator) |
|---|---|---|
| verdicts | 17 runs, **7 readable** | 17 |
| bounces | **0** | **12** |
| mean d1–3 | ~3.00 | **1.88** |

Four PRs were closed and recreated over a **branch name**, one of them scored
3/3/3 by tier 1 in the same breath. Absent CI was read as green four times. Both
are a regex and an exit code.

**What that table does not license.** F4 offered three options and recommended
deleting the model tier. An earlier version of this slice did exactly that, and
it was cancelled, because the argument does not survive contact with three
facts:

1. **The call is OAuth.** §M of the audit measured the auth topology: the only
   metered path is the `deepseek-v4-flash` Hermes profiles. Deleting an Opus
   call saves **zero dollars**. If a component is free, cost is not a reason to
   remove it — the real charge against tier 1 is that its 17 approvals at ~3.00
   are what made mean d1–3 decorative.
2. **The model was told to pass through.** The SOUL says, verbatim: *"Anything
   subtler than that is the operator's call, not yours. Pass it through: this
   tier can only bounce work that is obviously bad."* 0-for-17 is consistent
   with a model complying exactly. F4 lists adversarial framing as option (c)
   and recommends deletion without testing it. **No tier 1 that was permitted to
   bounce has ever been run**, so the measurement everyone is reasoning from is
   a measurement of a prompt.
3. **A program cannot replace it.** S3 measured the split: of 12 tier-2 bounces,
   7 are mechanically catchable and **5 are purely semantic**. Delete the model
   and the only thing reading for meaning is the operator — adequate at six
   chunks, wrong at fifty unattended, which is the regime D7.1 exists for.

So this ADR ships the half that is measured and leaves the half that is argued.

## Decision

**D9.1 — Tier 1 has two stages, and the first is a program.**
`scripts/prejudge.sh` (`make prejudge PR=<n>`) runs eight checks, prints
`pass | block | warn | skip` with evidence for each, and **exits 1 when any check
blocks**. It runs before the scorer, on every PR. A clear result is not an
approval: it is the input the scorer then reads. Exit 2 — the gate could not run
— is deliberately distinct from exit 1, so an outage cannot read as a rejection.

**D9.2 — Severity comes from the backtest, not from a table written in advance.**

| check | severity | why |
|---|---|---|
| `ci-state` | block | F5. Absent checks are a block, never a pass |
| `branch-name` | block | F7. 6 hits, 4 PRs closed for it alone, one at 3/3/3 |
| `then-asserts` | block | F14/F54. Both shapes are defects on their face |
| `scenario-count` | block **only when fewer** | fewer is spec infidelity; more is a planner underestimating |
| `touches` | warn | F55. 3 of 5 drifting paths are process docs no contract may declare |
| `touches-widened` | warn | F57. A head contract can otherwise certify paths it added to itself |
| `size-budget` | warn | F53. Fires on 11 of 11 — a gate that blocks everything is not a filter |
| `real-source` | warn | F53. Same argument, 8 of 11 |

The two Touches checks answer different questions and neither is an approval.
`touches` compares the implementation diff with the **head** contract, because
that is the contract the implementer used. `touches-widened` compares the
head's declaration with the contract at the PR's recorded base OID and reports
only head-minus-base additions. A removal is not widening. Both comparisons
source ADR-0012 D12.4's one process-document exemption; neither carries a
private copy. If either contract cannot be read, widening is `skip`, never
`pass`. A widening finding remains advisory and does not change the gate's exit
status.

`parents-merged` is **deleted**, not demoted (F52): by the time a PR exists its
parent has merged, so the check cannot ever fire here. F10's waste happens
before any PR exists, and its fix is a dispatcher edge, not a review check.

**D9.3 — The scorer keeps only what no program can decide.** The brief's
*"scope creep — changes outside the contract's `Touches` list"* bullet is
deleted: that is a set difference on paths and the gate owns it. So is
"assertion-free steps", which is an AST walk. What remains is scenario theater
in its semantic sense. This is F35's actual thesis — the two tiers stopped
duplicating — and it is satisfied by **narrowing the model's mandate rather than
amputating it**.

**D9.4 — A gate block is not a bounce, and is stored as `forge.gate.v1`.** The
gate emits its own flat metadata envelope with the schema key inside it
(`rubrics/kanban-metadata-schema.md`). It does **not** speak `forge.judge.v1`:
zeroing six dimensions to express "the branch name is wrong" invents five
scores, which is the argument the prejudge SOUL already accepts for cost — *a
zeroed cost object is an invented number wearing a measurement's clothes*. More
importantly, a block at zero model tokens and a bounce after a full review are
different events; averaging them into one bounce rate destroys the signal this
audit is built on. `scripts/metrics.sh` reports them as separate numbers, and
the `ci-red` zeroed-verdict sentinel retires with this ADR — CI is a gate check
now.

**D9.5 — The model stage is retained as a control arm, under evaluation.** It is
byte-identical to `main` apart from D9.3's brief. It may not be tuned, re-modelled
or deleted as a side effect of other work, because **S5's experiment measures
candidate tier-1 mandates against exactly this baseline**, and a control somebody
improved is not a control. The open question is stated plainly: *given a gate
that catches the mechanical half, does an Opus pass told to pass-through earn its
latency?* That question is answered by running the experiment, not by whoever
next edits the SOUL. `make verify`'s
`prejudge/gate-is-a-stage-not-a-replacement` fails if the call goes missing.

## Consequences

- **Tier 1 can now be wrong in a new direction.** D7.1's *"a false approval is
  impossible by construction"* held because tier 1 could only bounce. That is
  still true of the gate, but a *deterministic* false block repeats identically
  on every run where a model's did not. That is why four checks block and three
  only warn, and why the severity map is backed by 11 PRs rather than by taste.
  F56 is the cautionary instance: the gate's first version manufactured four
  findings from one underscore, and only reading the flagged code found it.
- **What the gate lets through is the cost of the decision, and it is real.**
  Re-backtested on the same 11 PRs it blocks 8 and clears 3. Of the 3, two (#5,
  #7) were bounced by tier 2 six times between them on `forge.judge.v1` decoder
  fidelity and equal-timestamp causality — semantic findings no program decides,
  and the residual the model stage exists to attempt.
- **The saving is latency and spawns, not dollars.** A blocked PR costs zero
  driver tokens and zero scorer latency, because nothing is spawned. There is no
  instrument for a dollar figure on either path, and this audit has already
  published one cost model that was backwards (§M); no dollar saving is claimed.
- **S3's headline recall figure does not survive this severity map.** "The gate
  blocks all 7 PRs tier 1 read and approved" was true when every failing check
  blocked; with `size-budget` and `real-source` demoted it blocks fewer. Still
  infinitely better than 0, measured the same way, and the smaller number is the
  honest one.
- **`forge-prejudge` remains a Hermes profile** (ADR-0006), and its prompt is
  materially cheaper on the blocking path: it reads a ~2 KB gate result instead
  of buying a 127 KB diff to learn that a branch is misnamed. On the clearing
  path it still moves the diff, because the scorer still needs it.

## Rejected

- **Delete tier 1's model call** (F4 option (a), and this slice's own first
  draft). Cancelled for the three reasons in Context. It remains a live option
  and S5 is the place to settle it — with an experiment, not with a number
  produced by a prompt that told the model to do nothing.
- **Keep the model but give it a bounce quota** (F4 option (c) in its crude
  form). A quota manufactures bounces to fill it. Adversarial *framing* is a
  real candidate and is exactly what S5 should measure against D9.5's control.
- **Move tier-1 scoring in-profile to `deepseek-v4-flash`** (F20 fix 2). §M —
  this is the one recommendation in the audit that was wrong in the expensive
  direction, moving work from a free OAuth path onto the only metered one. It is
  recorded here so it cannot be adopted by inertia.
- **Emit `forge.judge.v1` with zeroed scores so `/retro` keeps one number.** One
  number that averages a free gate block with a paid review is worse than two
  numbers, and the metric it would corrupt is the one that exposed F3.
- **Move `size-budget` and `real-source` to `/roadmap` now** (F53's conclusion,
  and correct). They are planning defects surfaced at review time. Moving them
  is a planning-layer change and is not this slice; they stay here at `warn`,
  still emitting, and the ledger keeps the move open.
