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
  "lane": "codex-worker | claude-interactive",
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
to watch. The lane runner scrapes this JSON from worker stdout between
`FORGE_METADATA_BEGIN` / `FORGE_METADATA_END` markers.

## Judge completion — `forge.judge.v1`
Defined in `rubrics/judge-rubric.md`. Stored as the judge card's metadata.

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
