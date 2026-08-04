# Kanban metadata schema — the structured exhaust contract

Every completed chunk card carries machine-readable metadata (Hermes
`kanban_complete(summary=…, metadata=…)`). Downstream consumers: judge (inputs),
morning digest cron (reporting), /retro (pattern mining), lane runner (plumbing).
Keys are a convention in the Hermes spirit: enough evidence that the next reader
answers "what happened, what changed, what's risky, what's next" without prose
scraping.

## Chunk completion — `forge.chunk.v1`

```json
{
  "schema": "forge.chunk.v1",
  "chunk_id": "CHUNK-7",
  "project": "gym-coach",
  "branch": "chunk/7-sync-engine",
  "pr": "https://github.com/…/pull/42",
  "lane": "forge-codex-lane | claude-interactive",
  "scenarios": { "added": 4, "passing": 4, "feature_files": ["tests/features/chunk_7.feature"] },
  "check": { "green": true, "coverage_pct": 91.4 },
  "files_changed": 6,
  "lines_changed": 312,
  "decisions": [
    "uv+watchfiles conflict on macOS: pinned watchfiles<0.22, see decision-log 2026-07-12"
  ],
  "debt": ["DEBT: retry policy duplicated in two modules"],
  "card_proposals": ["CARD?: extract shared retry helper"],
  "docs_reconciled": ["ROADMAP.md", "adr/0007 (updated: consequence note)"],
  "duration_min": 23,
  "worker": "codex/gpt-x | claude-code/opus"
}
```

`summary` (the human-readable sibling): one sentence of what landed + one of what
to watch. The lane worker passes this JSON directly to
`kanban_complete(metadata=…)` — there is no stdout scraping. Hermes's own
recommended keys (`changed_files`, `tests_run`, `decisions`) are welcome
alongside the forge keys; the dashboard renders them for free.

## Tier-1 gate result — `forge.gate.v1`

Emitted by `scripts/prejudge.sh --json` and stored **unmodified** as the
prejudge card's metadata when the gate blocks (ADR-0009 D9.4).

```json
{
  "schema": "forge.gate.v1",
  "gate": "forge-prejudge-gate",
  "pr": "https://github.com/…/pull/8",
  "repo": "wielas/forgeboard-report",
  "number": 8,
  "chunk": "CHUNK-5",
  "branch": "chunk/5",
  "head": "67c1a12…", "base": "b71fc96…",
  "checks": [
    { "id": "branch-name", "status": "pass | block | warn | skip",
      "evidence": "chunk/5 has no <slug> — AGENTS.md requires chunk/<id>-<slug>",
      "action": "rename the branch and force-push, keeping the same PR: …" }
  ],
  "counts": { "pass": 2, "block": 2, "warn": 2, "skip": 1 },
  "blocks": ["branch-name", "scenario-count"],
  "result": "block | clear"
}
```

**This is deliberately not `forge.judge.v1`, and the distinction is the point.**
A gate block costs zero model tokens and happens before any scorer is spawned; a
bounce costs a full review. Expressing "the branch name is wrong" as a verdict
with six zeroed dimensions would invent five scores — the same defect as the
zeroed cost object the prejudge SOUL already refuses to write — and would make
the two events indistinguishable in the one metric built to tell a filter from a
judge. `scripts/metrics.sh` counts them separately and `docs/retro-metrics.md`
says what each number means.

`action` is null on `pass` and `skip` and **required on every `block`**: gate
findings are copied verbatim into the repair card, so a finding a fresh worker
cannot execute is an unworkable card. `skip` is a real outcome and never
collapses into `pass` — a check that could not run has not passed.

## Judge completion — `forge.judge.v1`
Defined in `rubrics/judge-rubric.md`. Stored as the judge card's metadata — by
tier 1's model stage when the gate cleared and the scorer ran, and by tier 2.

## Blocked card — `forge.block.v1`

```json
{
  "schema": "forge.block.v1",
  "chunk_id": "CHUNK-9",
  "reason_class": "stale-spec | failing-prereq | env | ci-red | judge-bounce | other",
  "reason": "chunk expects src/api/v1 but CHUNK-6 moved it to src/api",
  "needs": "human decision: update chunk spec or revert move",
  "state": "branch chunk/9-… pushed with WIP commit; HANDOFF entry in decision-log"
}
```

## Rules
- Additive evolution only: bump `.v2` rather than mutating `.v1` meanings;
  consumers ignore unknown keys.
- Everything here is also human-scannable in the PR body — the board is a
  mirror, git is the source of truth.
- /retro mines `decisions[]`, `debt[]`, `reason_class`, and judge `findings[]`
  across cards; keep them honest and specific or the flywheel learns nothing.
