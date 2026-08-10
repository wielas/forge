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

A contract naming an external source must include a scenario that actually
exercises it and tags that scenario `@real-source`. If the planner cannot write
that scenario yet, the chunk is incomplete rather than ready for bootstrap.

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

## Consequences

- Acceptance exists before the first implementation token is spent.
- Feature scenarios are reviewable in the planning PR and selectable by normal
  BDD tooling; step definitions remain implementation work.
- `@real-source` becomes a planning obligation rather than a late advisory
  receipt.
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
