# Kanban metadata schema — the structured exhaust contract

Every completed chunk card carries machine-readable metadata (Hermes
`kanban_complete(summary=…, metadata=…)`). Downstream consumers: judge (inputs),
morning digest cron (reporting), /retro (pattern mining), lane runner (plumbing).
Keys are a convention in the Hermes spirit: enough evidence that the next reader
answers "what happened, what changed, what's risky, what's next" without prose
scraping.

The machine contract is [`run-metadata-contract.json`](run-metadata-contract.json):
it maps each worker profile to the schema ids it may emit. The versioned JSON
Schemas live beside this document, and `scripts/validate-metadata.py` checks the
contract with a locked JSON Schema runtime. `make verify SUITES=metadata` runs a
recorded PR through the real gate producer and validates its output alongside
chunk/judge fixtures, without reading a live board.

## Scoped live proof

The fixture gate proves the contract; the opt-in live sweep proves that the
model-controlled producers obeyed it on an actual run:

```bash
make metadata-live BOARD=<slug> SINCE=2026-08-09T12:34:56Z
```

`SINCE` is mandatory RFC3339 with a timezone. Use the recorded run-start
instant, not a calendar date. The cutoff is validated before the board path is
resolved, so historical envelopes cannot be judged accidentally. Rows before
the cutoff are counted as `ignored` and are never normalized or validated.

The command routes through `scripts/board-snapshot.sh`; the live WAL database
is copied but never opened. From the snapshot it checks:

- every post-cutoff `outcome=completed` run from a profile registered in
  `run-metadata-contract.json`;
- presence of every registered producer profile after the cutoff; and
- every post-cutoff `blocked` event carrying a run id, which is the board's
  durable marker that the reason came from a worker rather than a manual block.

Every bad item is printed with its task and run. `valid` includes conforming
envelopes and block reasons; the additional `profile=… schema=… valid=…` lines
break envelope successes down by producer contract. `invalid` is a readable
contract violation. `unjudged` is an item whose JSON cannot be read, and it is
never counted as valid. `ignored` is relevant producer output before `SINCE`.

`scripts/metadata-live.sh` exits 0 only when every expected producer is present
and all scoped items are valid, 1 for contract violations or a missing producer,
and 2 when any item is unjudged or the source/scope cannot be read. When both
invalid and unjudged items exist, exit 2 dominates because the sweep could not
form a verdict over its whole source. `make` reports any failed recipe with its
own generic nonzero status; the printed classification and summary retain the
distinction.

## Chunk completion — `forge.chunk.v1`

Defined by [`chunk-handoff.schema.json`](chunk-handoff.schema.json). The
`schema` discriminator and every Forge field are top-level. Consumers reject
historical nested envelopes rather than normalizing them into the contract.

```json
{
  "schema": "forge.chunk.v1",
  "chunk_id": "CHUNK-7",
  "project": "gym-coach",
  "branch": "chunk/7-sync-engine",
  "pr": "https://github.com/example/gym-coach/pull/42",
  "lane": "forge-codex-lane",
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
  "worker": "codex/gpt-5.6-sol xhigh"
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
Defined by [`gate-result.schema.json`](gate-result.schema.json).

```json
{
  "schema": "forge.gate.v1",
  "gate": "forge-prejudge-gate",
  "pr": "https://github.com/wielas/forgeboard-report/pull/8",
  "repo": "wielas/forgeboard-report",
  "number": 8,
  "chunk": "CHUNK-5",
  "branch": "chunk/5",
  "head": "67c1a1201234567890abcdef1234567890abcdef",
  "base": "b71fc9601234567890abcdef1234567890abcdef",
  "checks": [
    { "id": "branch-name", "status": "block",
      "evidence": "chunk/5 has no <slug> — AGENTS.md requires chunk/<id>-<slug>",
      "action": "rename the branch and force-push, keeping the same PR: …" }
  ],
  "counts": { "pass": 0, "block": 1, "warn": 0, "skip": 0 },
  "blocks": ["branch-name"],
  "result": "block"
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
Its machine contract is
[`judge-verdict.schema.json`](judge-verdict.schema.json). Nothing ADR-0011
measures has moved: the scorer's brief, the dimensions and the verdict logic are
untouched, and `prejudge/scorer-is-the-control-arm` still pins the call. What
changed on 2026-09-02 is the envelope's own shape, because the first `--hello`
rehearsal to run end to end produced one the schema refused — see the
`tokens_estimate` and `worker_session_id` notes in that file.

**This is the one envelope the additive rule below does not cover.** It is
`additionalProperties: false`, deliberately: the operator stamps five fields
into it after the model has written the rest, and an undeclared key there is an
invented one. So a sibling key that genuinely belongs — Hermes's own
`worker_session_id` — is DECLARED rather than tolerated, and
`prejudge/stamped-envelope-declares-every-key` fails the suite when the stamp
writes a key the schema does not name.

## Blocked card reasons

There is no `forge.block.v1` metadata envelope. Hermes `kanban_block` stores a
reason string and accepts no metadata argument. The reason must start with one
of these documented class prefixes: `stale-spec`, `failing-prereq`, `env`,
`ci-red`, `judge-bounce`, `gate-misrouted`, `gate-unrunnable`, or `other`.
`scripts/metrics.sh` derives the class from the `task_events.reason` prefix and
uses the registry regex to decide whether it is documented. The registry owns
the regex; `metadata/blocked-reason-contract` checks every literal program/SOUL
producer and the metrics consumer against it. The scoped live sweep checks the
durable model-authored events, proving terminators obey the prompt rather than
merely reading it.

## Rules
- Additive top-level keys are allowed and ignored by consumers. Changing a
  required field or an existing meaning requires a `.v2` schema id.
- A completed `forge-codex-lane` run may emit only `forge.chunk.v1`; a completed
  `forge-prejudge` run may emit `forge.gate.v1` or `forge.judge.v1`. Null
  metadata and cross-profile schema ids are invalid.
- Everything here is also human-scannable in the PR body — the board is a
  mirror, git is the source of truth.
- /retro mines `decisions[]`, `debt[]`, the blocked-event reason prefix, and
  judge `findings[]` across cards; keep them honest and specific or the
  flywheel learns nothing.
