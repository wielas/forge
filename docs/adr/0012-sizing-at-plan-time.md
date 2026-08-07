# ADR-0012: The sizing rules move to plan time, and ship advisory

**Status:** accepted · 2026-08-07
**Follows:** ADR-0009's own *Rejected* entry — *"Move `size-budget` and
`real-source` to `/roadmap` now (F53's conclusion, and correct). Moving them is a
planning-layer change and is not this slice."* This is that slice. ADR-0009 is
unchanged: nothing is removed from `scripts/prejudge.sh`, and the review-time
checks keep emitting at `warn`.

## Context

`skills/roadmap/SKILL.md` has stated the sizing contract precisely since the
first version: *"Fits comfortably in a single session INCLUDING tests and doc
updates (heuristic: ≤ ~400 lines changed, ≤ ~6 files, ≤ 5 BDD scenarios)."*
Nothing executed it. F28 is the audit's finding that this is the most-violated
rule in the Forge and the only major rule with no gate.

ADR-0009 connected it to something — `size-budget`, on a pull request. The
backtest is what makes this ADR necessary rather than optional.

**Measured against all 11 PRs of the only real run** (audit F28, F53):

| PR | Chunk | lines | vs 400 |
|---|---|---|---|
| #2 | CHUNK-1 | 800 | 2.0× |
| #3 | CHUNK-2 | 1,576 | 3.9× |
| #5 | CHUNK-3 | 3,707 | **9.3×** |
| #7 | CHUNK-4 | 1,105 | 2.8× |
| #9 | CHUNK-5 | 1,645 | 4.1× |
| #11 | CHUNK-6 | 853 | 2.1× |

Six chunks, six violations, mean 4.0× over. `size-budget` fires on **11 of 11**;
`real-source` on **8 of 11**. Every one of those findings is correct.

Two things follow, and only the second is a surprise:

1. **A gate that blocks every PR is not a filter either.** Turned on as blocking
   on day one, `size-budget` would have stopped the project at PR #2 and never
   let it resume, because nothing in that run's methodology produced a 400-line
   chunk.
2. **These are planning defects being surfaced at review time.** By the time a
   PR exists, a model has been spawned, a branch cut, a diff written and a
   review paid for. A `size-budget` warning on PR #5 is a receipt for a decision
   made days earlier, in a document that was free to edit at the time and is not
   free now. **Review time is the most expensive place to learn that a planner
   wrote a 3,700-line chunk.**

The conclusion is emphatically *not* to loosen the threshold. The threshold is
the roadmap skill's own number, and moving it after seeing the data is the one
response F53 forbids: it converts a failed plan into a passing one without
changing the plan.

## Decision

**D12.1 — `make roadmap-check PROJECT=<abs-path>` reads the plan, before a board
exists.** `scripts/roadmap-check.sh` runs nine checks over
`docs/chunks/graph.json` and `docs/chunks/*.md`, offline and deterministic, with
no board, no network and no model. It is meant to run at the end of `/roadmap`
and again before `hermes/board-bootstrap.sh`.

| check | what it holds | source of the number |
|---|---|---|
| `bijection` | graph ids ↔ chunk files, 1:1; no dangling `depends_on` | SKILL.md "definition of done" |
| `acyclic` | `depends_on` has no cycle | SKILL.md; ADR-0008 |
| `single-root` | exactly one chunk with no parents | Track E `--root-only` |
| `reachable` | every chunk reachable from that root | — |
| `fields` | every field of the contract template is present, by name | SKILL.md template |
| `serves` | ≤ 4 requirements per chunk | F11's fix, verbatim |
| `touches` | ≤ 6 **declarable** paths per chunk | SKILL.md "≤ ~6 files" |
| `scenarios` | ≤ 5 scenarios, one Given/When/Then each | SKILL.md "≤ 5 BDD scenarios" |
| `lane` | `claude-interactive`, or a real Hermes assignee | SKILL.md lane heuristic |

**D12.2 — Every threshold is the number the methodology already published, and
it is not tunable here.** `SERVES_MAX=4` is F11's fix text; `TOUCHES_MAX=6` and
`SCENARIO_MAX=5` are SKILL.md's own parenthetical. `make verify`'s
`roadmap/thresholds-are-the-skills-own-numbers` fails if the script and the
skill drift apart. A threshold that looks wrong is argued in a PR body with
evidence and a new ADR, never edited to make a plan pass.

**D12.3 — Counting bullets is not counting scenarios.** The run's CHUNK-6
scenario 2 reads, verbatim: *"Given invalid input, an unknown/changing board,
cyclic graph, unavailable/old GitHub CLI, malformed canonical evidence, or
publication failure"* — six scenarios in one bullet, and five such bullets pass
a naive count of five while specifying thirty. So each bullet is scored by the
**arity of its `Given` and `When` clauses**: a clause enumerating alternatives
and closing with `, or ` is worth as many scenarios as it lists.

Disjunction only, never conjunction, and that distinction is the whole of the
heuristic's precision. *"Given A, B, and C"* is one scenario with a compound
setup — one report containing several kinds of field is still one report.
*"Given A, B, or C"* is three scenarios wearing one bullet, because no single
run can be in three of those states at once. Both directions are pinned by a
verify case; without the conjunctive one the rule degenerates into "any comma
list", which fires on nearly every real bullet.

**D12.4 — The `Touches` exemption is one list, shared with review time.**
F55 counted the drift across six chunks: of five distinct drifting paths, three
are `docs/decision-log.md`, `docs/ROADMAP.md` and `docs/chunks/*` — files every
chunk is required to change and no contract in the entire run ever listed.
`scripts/touches-exempt.sh` now holds the single definition and both
`scripts/prejudge.sh` and `scripts/roadmap-check.sh` source it.
`roadmap/touches-exemption-has-one-definition` fails if a second assignment
appears anywhere.

At review time the exemption suppresses a finding manufactured on every PR. At
plan time its job is different and worth stating, because it is not the same
argument: it stops the check **punishing the one planner honest enough to
declare a process doc**. Without it the cheapest way to clear a six-path budget
is to delete `docs/decision-log.md` from `Touches` — which then manufactures
prejudge's drift finding on the same chunk, at review time, for the same file.

**D12.5 — It ships advisory. Every check warns; the exit status is 0.** This is
F53's other half, and it is the decision rather than an omission. Exit 2 remains
reserved for the check failing to run at all — no project, no `graph.json`, no
`jq` — exactly as in `prejudge.sh`, so an absent plan can never read as a clean
one. The procedure to flip it:

1. Ship warning (this ADR).
2. Run it against a real product roadmap.
3. **Fix the plan** until it passes.
4. Flip to blocking, before bootstrap, as a new recorded decision.

Step 3 is the one that is not optional and the one an impatient reader will skip
to step 4 without.

**There is no severity mechanism, and this ADR claimed one.** It read: *"The
severity map is a single table at the top of the script so that each flip is one
line, deliberately taken."* That table is a **prose comment**. Editing it changes
nothing — `grep -niE 'strict|FORGE_ROADMAP|SEVERITY='` over
`scripts/roadmap-check.sh` returns no matches, every finding's severity is a
literal `warn` at its own `emit` call site, and the script ends in an
unconditional `exit 0`. A future editor following that sentence would have made
a no-op change and believed the gate had flipped. That is the most expensive
kind of error a document like this can hold, because it is discovered only by a
plan that should have been blocked and was not.

The comment table stays — `scripts/prejudge.sh:23-32` uses the same style and it
is a useful index of what the script checks. It is a **convention, not a
mechanism**, and this ADR now says which.

**So step 4 is real work, not a formality:** a severity value read at each `emit`
site plus a non-zero exit path, with its own PR and its own recorded decision.
Until that exists, C1 is advisory and **stays advisory through the first product
run** — F11, F28 and F53 stay open through it by decision, rather than being
recorded as half-closed by a mechanism nobody built.

**D12.6 — It emits no metadata envelope.** The gate emits `forge.gate.v1`
because a card exists to attach it to. Here nothing exists yet — that is the
point of running now — so there is no consumer, and inventing a `forge.*` schema
for a result nothing stores would be a shape with no reader.

## Consequences

- **This does not remove anything from `prejudge.sh`.** `size-budget` and
  `real-source` keep firing at `warn` on PRs. They now describe a decision
  someone was warned about at plan time, which is a different and more useful
  statement than the one they made before, but the recall is not moved twice and
  ADR-0009's severity map is untouched.
- **It cannot predict a diff.** Nothing can. It counts what the contract states
  about itself — requirements served, paths declared, scenarios specified — which
  is what the sizing rule is written in terms of and is the strongest available
  proxy. A plan that clears every check can still produce a 3,000-line PR, and
  `size-budget` is still there to say so.
- **It duplicates none of `board-bootstrap.sh`.** That script proves acyclicity
  by construction, id↔file correspondence and parent readback — all *after*
  opening a board and creating real cards. Everything here runs before any of
  that exists, and one of the checks bootstrap structurally cannot make:
  a chunk **file the graph forgot** is never created and never missed.
- **`reachable` has no recall independent of the other two.** In a finite DAG
  every node has a path back to a source, so with exactly one root and no cycle
  it cannot fail. It is retained for its evidence — it names the stranded chunks
  when `acyclic` or `single-root` has already fired — and its skip on a
  multi-root graph is honest about having cleared nothing.
- **Warn-first means the first real roadmap it reads will be ugly.** The audited
  run's own CHUNK-5 reports 12 requirements against a cap of 4 and 8 scenarios
  from 5 bullets. That is the expected result and it is the measurement, not a
  reason to tune anything.

## Rejected

- **Ship it blocking.** F53's whole finding is that a check firing on 11 of 11 is
  not a filter. Blocking a plan on day one relocates the stall from review to
  planning without anyone having fixed a plan first.
- **Raise `SERVES_MAX` to 12 so the run's own CHUNK-5 clears.** The single
  response F53 forbids, recorded here so it cannot be adopted by inertia.
- **Count `Touches` paths without the F55 exemption.** Manufactures a finding on
  every chunk that is honest about the process docs it will edit, and rewards
  the contract that omits them.
- **Compare the graph's `depends_on` against each contract's prose
  `Depends on:`.** SKILL.md already rules the graph authoritative and the prose a
  bug when they disagree, so the check is well-defined and worth having. It is a
  different finding from anything F53 names and is left for the slice that wants
  it.
- **Emit `forge.gate.v1` from this script so `/retro` can count plan findings.**
  There is no card and no run; the envelope would have no producer identity and
  no consumer. When a `/roadmap` ceremony wants to store its own result, that is
  the slice that adds the schema.
