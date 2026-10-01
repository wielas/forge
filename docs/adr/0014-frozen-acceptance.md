# ADR-0014: Acceptance is emitted and frozen at planning time

**Status:** accepted · 2026-08-10
**Depends on:** ADR-0003, ADR-0012

## Context

The audited run wrote acceptance prose into chunk cards, then left each
implementation branch to translate that prose into executable scenarios. That
made two failures cheap to introduce and expensive to detect:

- a worker could narrow or rewrite the acceptance surface while implementing
  it (F14), and
- a contract naming a real external source could ship only synthetic coverage
  because the real-source scenario was deferred until review (F25).

Both are planning decisions. Discovering either after a branch, diff, and model
run already exist repeats F53's failure mode: a correct finding delivered at
the most expensive point in the workflow.

## Decision

### D14.1 — One planning pass emits prose and executable acceptance

`/roadmap` writes each chunk contract and its Gherkin feature together. Every
chunk has:

```markdown
- **Acceptance:** tests/features/chunk_<id>.feature
```

The feature contains one `Scenario` for every contract bullet, in the same
order, with matching Given/When/Then step text. Planning emits no step
definitions; implementations add those without changing the frozen feature.

A contract declares every external source explicitly as
`` **Real sources:** `<label>` → scenario <n> `` (or `none`). Each mapped
scenario must actually exercise that source and carries `@real-source`; no
unmapped scenario may carry the tag. The label is free text rather than a
hard-coded vocabulary, so a novel source cannot silently evade the obligation.
If the planner cannot write the mapped scenario yet, the chunk is incomplete
rather than ready for bootstrap.

### D14.2 — The freeze is a byte-level planning artifact

At the end of the same planning pass,
`scripts/acceptance-freeze.sh <project>` validates the contract/feature pairs
and writes `docs/chunks/contract-freeze.json`. The JSON object maps each sorted,
repo-relative feature path to the lowercase SHA-256 digest of its exact bytes.
The write is atomic; a missing or invalid feature leaves the prior manifest
untouched and names the chunk plus expected path.

Hashes do not grade semantics. They identify the planning artifact whose
meaning a human approved, while the contract-to-feature validation prevents the
first frozen manifest from already disagreeing with its prose source.

### D14.3 — Amendments land before implementation branches consume them

Acceptance can change, but not by self-amendment inside the implementation PR.
The escape hatch is a separate, human-reviewed planning PR that changes the
chunk contract, feature, and regenerated manifest together on the branch from
which implementation starts. After that PR lands, a later implementation
branch consumes the new hash normally.

CHUNK-6 creates the artifact and records this amendment rule. CHUNK-7 enforces
the base-branch hash during implementation and wires the rule into prejudge,
start-chunk, judge, and the stamped project instructions.

This repository's first adoption is explicitly a retrofit: CHUNK-2 through
CHUNK-5 already had implementation branches when CHUNK-6 emitted their initial
contracts and features. Their histories therefore are not evidence that the
receipt existed before implementation. Before merge, the stack is reordered so
the reviewed CHUNK-6 planning artifact is the base consumed by CHUNK-4 and
CHUNK-5; subsequent projects must satisfy the normal pre-token chronology.

## Consequences

- Acceptance exists before the first implementation token is spent.
- Feature scenarios are reviewable in the planning PR and selectable by normal
  BDD tooling; step definitions remain implementation work.
- `@real-source` becomes a planning obligation rather than a late advisory
  receipt, and its explicit source-to-scenario mapping is reviewable.
- Formatting-only feature edits change the digest. That is intentional: the
  manifest identifies exact approved bytes, not an attempted semantic normal
  form.
- CHUNK-6 alone does not block an implementation PR that edits a feature. Until
  CHUNK-7 lands, the manifest is an emitted artifact without enforcement.

## Rejected

- **Hash only the scenario prose in the card.** That leaves executable
  acceptance to be invented on the implementation branch, which is the defect
  this decision closes.
- **Let the implementation PR regenerate its own manifest.** A branch could
  rewrite the test and the receipt together; CHUNK-7 explicitly compares both
  to the approved base.
- **Treat a hash match as semantic correctness.** SHA-256 proves byte identity,
  not that a scenario is strong, feasible, or adequately implemented.

> **Amendment, 2026-09-27 (epic S5, MS1/MS2).** The manifest is no longer
> feature paths only. A milestone gate (`GATE-<milestone>` in `graph.json`) has
> no feature; what it freezes is its declared probe,
> `tests/probes/gate_<milestone>.json` (`forge.probe.v1`), plus every input file
> the probe runs on. The same reasoning applies: the milestone probe is the
> backstop for what per-chunk review cannot see, so an implementation branch
> must not be able to weaken it. `load_manifest` accepts a path under
> `tests/probes/` beside `.feature` paths. `--check-base` compares those entries
> exactly as it compares features (`roadmap/a-weakened-probe-is-refused-at-review`).
> A contract's `Multi-record fixtures` line joins the frozen acceptance surface
> beside `Scenarios`, `Real sources` and `Acceptance`.

> **Amendment, 2026-10-01 (epic S5b, MS2).** What a valid probe is, and which
> files it freezes, is now defined once, in `scripts/forge_probe.py`.
> `acceptance-freeze` freezes by it, and `scripts/probe-run.sh`, which executes
> the probe on the gate card, refuses any probe that does not match the
> manifest. Three freeze rules are new:
> - `.DS_Store` is never part of a probe, and a `run` may not name one.
> - A symlink in an input is refused, because its target's bytes are not what
>   the freeze would hash.
> - An expectation that cannot discriminate is refused: an empty `stdout`, or
>   an exit outside 0–255.
>
> v1's shape is unchanged, and no frozen plan changed under these rules. The
> Squatfather's re-freeze is byte-identical. So v1 was tightened, not bumped.
