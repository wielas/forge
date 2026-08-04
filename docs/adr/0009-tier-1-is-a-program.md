# ADR-0009: Tier 1 is a program, not a model

**Status:** accepted · 2026-08-04
**Supersedes:** ADR-0007 **D7.1 only.** D7.2 (the operator is tier 2), D7.3
(auto-merge, still `planned — not implemented`) and D7.4 (structured verdicts)
stand unchanged.

## Context

D7.1 says tier 1 *"reads the diff, the scenarios and the CI result against
`rubrics/judge-rubric.md`"* — a `claude -p --model opus` call driven by the
`forge-prejudge` Hermes profile. After the `forgeboard-report` run that sentence
describes something that should not exist.

**Measured, 17 tier-1 runs on 11 PRs** (audit F4, F20, F35):

| | tier 1 (`opus`) | tier 2 (operator) |
|---|---|---|
| verdicts | 17 runs, **7 readable** | 17 |
| bounces | **0** | **12** |
| mean d1–3 | ~3.00 | **1.88** |

Same diffs, same rubric, same days. A 1.1-point spread on identical inputs is
not a filter and a judge; it is one judgement with enormous variance. Tier 1
approved PR #10 at a straight 3/3/3/3/3/3 which tier 2 then bounced with a 0,
and approved four PRs whose only defect was a branch name that a regex decides.
`docs/retro-metrics.md` predicted this in writing on 2026-07-28 — *"if d1–3
stays at 3.00 across the next few chunks, the score is decorative"* — and then
17 more 3.00s arrived.

Everything tier 1 was actually mandated to catch is decidable without a model,
which is ADR-0003 (*deterministic enforcement lives in the repo*) applied to
review. S3 built that program and backtested it against all 11 PRs before this
decision was taken; §"Consequences" records what the backtest changed about it,
because three of its five findings cut against the design it was testing.

## Decision

**D9.1 — Tier 1 is `make prejudge PR=<n>`, and it contains no model call.**
`scripts/prejudge.sh` runs seven checks, prints `pass | block | warn | skip` with
evidence for each, and exits 1 when any check blocks. The `forge-prejudge`
profile survives as a *driver*: it waits, runs the gate, and routes the result to
a card. It no longer shells out to a scorer, assembles a prompt, or moves a diff.

**D9.2 — Severity comes from the backtest, not from a table written in advance.**

| check | severity | why |
|---|---|---|
| `ci-state` | block | F5. Absent checks are a block, never a pass |
| `branch-name` | block | F7. 6 hits, 4 PRs closed for it alone, one at 3/3/3 |
| `then-asserts` | block | F14/F54. Both shapes are defects on their face |
| `scenario-count` | block **only when fewer** | fewer is spec infidelity; more is a planning miss |
| `touches` | warn | F55. 3 of 5 drifting paths are undeclarable process docs |
| `size-budget` | warn | F53. Fires on 11 of 11 — a gate that blocks everything is not a filter |
| `real-source` | warn | F53. Same argument, 8 of 11 |

`parents-merged` is **deleted**, not demoted (F52): by the time a PR exists its
parent has merged, so the check cannot ever fire here. F10's waste happens before
any PR exists, and its fix is a dispatcher edge.

**D9.3 — Residual judgement stays on tier 2, on the OAuth path.** It is *not*
migrated to the metered `deepseek-v4-flash` profile. §M of the audit measured the
auth topology and found the cost model backwards: the Hermes profiles are the
only metered path, and everything called "expensive" — Opus at tier 1, the
operator's sessions — is subscription-covered. Moving scoring in-profile would
move work from a free path onto the only billed one. The deleted call frees
~134k Opus tokens per run and **zero dollars**.

**D9.4 — A gate block is not a bounce, and is stored as `forge.gate.v1`.**
Tier 1 emits its own flat metadata envelope with the schema key inside it. It
does **not** speak `forge.judge.v1`: zeroing six dimensions to express "the
branch name is wrong" invents five scores, which is the argument the prejudge
SOUL already accepts for cost — *a zeroed cost object is an invented number
wearing a measurement's clothes*. `scripts/metrics.sh` counts gate blocks and
tier-2 bounces as separate numbers, and the `ci-red` zeroed-verdict sentinel is
retired with this ADR.

**D9.5 — Every blocking check emits an executable `action`.** The gate's findings
are copied verbatim into the repair card, so the bounce contract in
`rubrics/judge-rubric.md` binds a program now. "branch-name fails" is not an
action; `git branch -m chunk/5 chunk/5-render-canonical-report && git push
--force-with-lease` is. `make verify` fails if any blocking finding lacks one.

## Consequences

- **Tier 1 can now be wrong in a new direction.** D7.1's *"a false approval is
  impossible by construction"* held because tier 1 could only bounce. That is
  still true of the gate, but a *deterministic* false block repeats identically
  on every run, where a model's did not. This is why four checks block and three
  only warn, and why the severity map is backed by 11 PRs rather than by taste.
- **What the gate lets through is the cost of the decision, and it is real.**
  Re-backtested on the same 11 PRs it blocks 8 and clears 3. Of the 3, two (#5,
  #7) were bounced by tier 2 six times between them, on `forge.judge.v1` decoder
  fidelity and equal-timestamp causality — semantic findings no program decides.
  That is tier 2 doing the work the audit found justified.
- **S3's headline recall figure does not survive this ADR's severity map.** "The
  gate blocks all 7 PRs tier 1 read and approved" was true when every failing
  check blocked; with `size-budget` and `real-source` demoted it blocks 5 of
  those 7 verdicts and 3 of the 5 distinct PRs. Still infinitely better than 0,
  measured the same way, and the smaller number is the honest one.
- **Four `make verify` cases were deleted with their subject.** The tier-1
  stamping of `judge_model`, `tokens_estimate`, `cost` and `session_id` from the
  `claude -p` envelope (F30, F45, F50) had exactly one call site. The schema
  keeps the fields and `verdict-cost-is-storable` keeps guarding them; when a
  judging harness returns usage again, those cases return with it.
- **`forge-prejudge` remains a Hermes profile** (ADR-0006). Something must still
  wait for CI, run the gate, and route to a card — that is driving, which is what
  the cheap metered model is for. Its prompt is materially shorter: the contract
  and the diff are gone from it entirely.

## Rejected

- **Delete tier 1 outright and route straight to tier 2** (F4 option (a)). The
  mechanical findings are real and cost nothing to make; sending a misnamed
  branch to a human is the waste this whole audit is about.
- **Keep the model with a bounce quota or adversarial framing** (F4 option (c)).
  It is a second sampling process bolted to the first, and F6 already shows the
  verdict tracking which model was configured that hour rather than the diff.
- **Move tier-1 scoring in-profile to `deepseek-v4-flash`** (F20 fix 2). §M —
  this is the one recommendation in the audit that was wrong in the expensive
  direction, and it is recorded here so it cannot be adopted by inertia.
- **Emit `forge.judge.v1` with zeroed scores so `/retro` keeps one number.**
  One number that averages a free gate block with a paid review is worse than
  two numbers, and the metric it would corrupt is the one that exposed F3.
