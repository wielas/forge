# Judge rubric — dimensions, scoring, verdict schema

The judge scores SIX dimensions, 0–3 each, with evidence. CI-checkable properties
(format, lint, tests passing, coverage floor) are NOT dimensions — CI owns them.

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
- CI red → `bounce` (`ci-red`) without a model call; emit zeroes in every score
  field as the schema's deterministic sentinel.

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
  "tokens_estimate": 0
}
```

## Bounce contract
Every `block`/`fix` finding's `action` must be executable by a fresh mid-weight
worker with no questions. The bounce card body = findings list verbatim.
