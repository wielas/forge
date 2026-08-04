# Judge rubric — dimensions, scoring, verdict schema

The judge scores SIX dimensions, 0–3 each, with evidence. CI-checkable properties
(format, lint, tests passing, coverage floor) are NOT dimensions — CI owns them.

**Both scoring tiers read this file, and neither of them decides what a program
already decided** (ADR-0009). Tier 1's first stage is `scripts/prejudge.sh`: it
settles CI state, branch naming, `Touches` boundary, assertion shape and
scenario count deterministically, emits `forge.gate.v1`, and never scores. Only
what survives that gate reaches a model. So a dimension here is scored on what
the gate cannot see — dimension 4 in particular is now about scope creep the
`Touches` set difference does not express, not about the set difference itself.

## Dimensions

| # | Dimension | 3 (exemplary) | 1 (deficient) — typical evidence |
|---|-----------|----------------|----------------------------------|
| 1 | **Spec fidelity** | Every chunk-spec scenario implemented as promised; Goal met literally | Then-clause weakened vs spec; goal partially met; renamed behavior |
| 2 | **Scenario integrity** | Scenarios exercise real behavior end-to-end; would fail if the feature broke | Over-mocked core path; assertion-free steps; tautological Given=Then |
| 3 | **Architectural conformance** | Follows referenced ADRs and component boundaries exactly | Bypasses a decided interface; new dependency with no ADR; layer violation |
| 4 | **Scope discipline** | Diff stays inside Touches; out-of-scope untouched | Drive-by refactors; unrelated file churn; feature beyond the Goal |
| 5 | **Debt honesty** | Debt introduced is declared (DEBT:) and justified | Hidden TODO/hack; copy-paste divergence; silent perf/security tradeoff |
| 6 | **Doc reconciliation** | ROADMAP/ADR/AGENTS.md updates match the code truth | Stale roadmap entry; ADR contradicted by code; missing decision-log entry |

Scoring: 3 exemplary · 2 acceptable · 1 deficient (fixable) · 0 disqualifying.

## Verdict logic
- Any dimension = 0 → `bounce`.
- Dimensions 1–3 all ≥2 AND none = 1 → `approve`.
- Otherwise, if every 1-scored finding is a genuinely non-blocking nit →
  `approve-with-nits`; else `bounce`.
- CI red never reaches this rubric. `ci-state` is a tier-1 gate check and blocks
  before any scorer is spawned, so the zeroed-six-scores `ci-red` sentinel is
  **retired** (ADR-0009 D9.4): it invented five numbers to express one exit
  code, and it made a zero-token gate block indistinguishable from a bounce that
  cost a full review. The two are counted separately now — see
  `docs/retro-metrics.md`.

## Verdict JSON (exact shape — consumed by lane runner, Telegram gate, /retro)

```json
{
  "schema": "forge.judge.v1",
  "chunk_id": "CHUNK-7",
  "pr": "https://github.com/…/pull/42",
  "verdict": "approve | approve-with-nits | bounce",
  "scores": {
    "spec_fidelity": 3,
    "scenario_integrity": 2,
    "architectural_conformance": 3,
    "scope_discipline": 3,
    "debt_honesty": 2,
    "doc_reconciliation": 2
  },
  "findings": [
    {
      "dimension": "scenario_integrity",
      "severity": "nit | fix | block",
      "evidence": "tests/steps/test_sync.py:41 — asserts mock called, not result",
      "action": "assert on returned payload; drop the call-count check"
    }
  ],
  "nits_as_cards": ["CARD?: extract retry policy into shared helper"],
  "spot_check_suggestion": "eyeball src/sync/engine.py diff — densest change",
  "judge_model": "<model id>",
  "tokens_estimate": 0,
  "cost": {
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_read_input_tokens": 0,
    "cache_creation_input_tokens": 0,
    "total_cost_usd": 0.0
  },
  "session_id": "<judging engine session id>"
}
```

The last four fields are **stamped by the operator from the judging harness,
never produced by the judging model** — a model cannot report its own id, and
still less its own token consumption. `cost` and `session_id` are optional,
because they can only be stamped where a judging harness reports usage, and an
interactive tier-2 review has no such envelope. The scorer is never asked for
any of them: the schema it receives has them removed, because a field a model is
asked for is a field it will invent.

## Bounce contract
Every `block`/`fix` finding's `action` must be executable by a fresh mid-weight
worker with no questions. The bounce card body = findings list verbatim.

**This binds tier 1's gate too, where it is enforced rather than requested.**
Every blocking check in `scripts/prejudge.sh` emits an `action`, and
`make verify`'s `prejudge/emits-an-action-per-block` fails the suite if one does
not. "branch-name fails" is not an action; a `git branch -m` line with the real
slug in it is.
