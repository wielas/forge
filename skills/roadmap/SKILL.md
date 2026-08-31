---
name: roadmap
description: Slice architecture into single-session chunks and emit kanban cards. Use for /roadmap, "plan the implementation", or "create the chunks".
---

# Roadmap — from architecture to a board of executable chunks

Fresh context. Inputs are `docs/REQUIREMENTS.md`, `docs/ARCHITECTURE.md`,
`docs/adr/*`, `AGENTS.md`. If architecture is missing → send human to /architect.

## What a chunk is
The unit of unattended work: one fresh-context session, one branch, one PR.
A mid-weight model must be able to finish it without asking questions.

Sizing rules:
- Fits comfortably in a single session INCLUDING tests and doc updates
  (heuristic: ≤ ~400 lines changed, ≤ ~6 files, ≤ 5 BDD scenarios).
- Independently green: after merge, `make check` passes and the system still runs.
- Code dependencies integrate through `main`: a dependent lane waits until each
  parent PR is merged (ADR-0008). Do not assume Forge silently creates stacked
  branches.
- States its own context: everything the implementer needs is IN the chunk spec
  or explicitly linked (ADR ids, file paths). Never "see discussion above".

## Process
1. Derive milestones (2–5) from the architecture; order by risk (riskiest
   integration first, polish last).
2. Slice milestones into chunks. For EVERY chunk write into `docs/ROADMAP.md`:

   ```markdown
   ### CHUNK-<id>: <imperative title>
   - **Goal:** one sentence.
   - **Milestone:** M<n>  ·  **Depends on:** CHUNK-a, CHUNK-b | none
   - **Serves:** FR-x, NFR-y  ·  **Relevant ADRs:** 0003, 0007
   - **Touches:** paths/likely/to/change
   - **Scenarios:** Given/When/Then one-liners (these BECOME the .feature file)
   - **Real sources:** none | `<source label>` → scenario <n>[; ...]
   - **Acceptance:** tests/features/chunk_<id>.feature
   - **Out of scope:** what the implementer must NOT do
   - **Done when:** make check green + scenarios pass + docs updated
   - **Lane:** forge-codex-lane | claude-interactive  ·  **Risk:** low|med|high
   ```

   Lane heuristic: `claude-interactive` for chunks needing judgment or human
   taste (API shape, UX, tricky refactors); `forge-codex-lane` for well-bounded
   build-out. The lane name IS the card's `--assignee`, so it must match a real
   Hermes profile (`hermes kanban assignees`) — an unknown assignee leaves the
   card stranded in `ready`, silently. Risk `high` ⇒ note "docker backend".
3. **Self-review pass:** simulate being the implementer of the 3 gnarliest
   chunks; if you would need to ask a question, the spec is incomplete — fix it.
4. **Emit acceptance and board inputs — as files, not as prose to be retyped.**

   Write each chunk spec to `docs/chunks/CHUNK-<id>.md` (the card body and the
   ROADMAP entry must be the same text — generate both from one source).

   In the same planning pass, write the chunk's `Acceptance` path as
   `tests/features/chunk_<id>.feature`, where `<id>` is the lower-case portion
   after `CHUNK-` (hyphens become underscores). Translate every scenario bullet
   into one Gherkin `Scenario` with exactly one `Given`, `When`, and `Then`; the
   step text must match the contract. Scenario titles are descriptive labels,
   not a second contract.

   Declare every real external system or source explicitly in `Real sources`
   and map it to the one-based scenario that exercises it, for example
   `` `Hermes board` → scenario 2; `GitHub protection API` → scenario 4 ``.
   Use `none` only when no external source is part of the contract. Every mapped
   scenario carries `@real-source`, and no unmapped scenario does. Source labels
   are deliberately free text: the validator checks the explicit mapping, not
   a finite vocabulary that silently misses a new kind of source. If no planned
   scenario can exercise a declared source, the contract is incomplete: fix or
   split it now, before implementation.

   Then write **`docs/chunks/graph.json`**, the machine-readable dependency
   graph. This is the contract with `hermes/board-bootstrap.sh`, which creates
   the cards and the edges itself. Do not print `hermes kanban` commands for a
   human to paste; a graph rebuilt by hand from prose is a graph that silently
   loses edges.

   ```json
   [
     {"id": "CHUNK-1", "lane": "forge-codex-lane",   "depends_on": []},
     {"id": "CHUNK-2", "lane": "claude-interactive", "depends_on": ["CHUNK-1"]},
     {"id": "CHUNK-3", "lane": "forge-codex-lane",   "depends_on": ["CHUNK-2"]}
   ]
   ```

   - `id` must match a `docs/chunks/<id>.md` file exactly.
   - `lane` is the card's `--assignee` and must be a real Hermes profile, or the
     literal `claude-interactive` for chunks a human drives.
   - `depends_on` lists chunk ids, and must be acyclic. Every "Depends on" in
     ROADMAP.md appears here; if the two disagree, this file is authoritative
     and the prose is a bug.
   - The bootstrap attaches these parents in the card's create transaction.
     It never creates a ready child and links it in a later pass.

   Finally run:

   ```bash
   ~/.forge/repo/scripts/acceptance-freeze.sh "$PWD"
   ```

   This validates every `Acceptance` field and Given/When/Then sequence, then
   atomically writes `docs/chunks/contract-freeze.json`, mapping sorted
   repo-relative feature paths to SHA-256 digests. A failure is a planning
   failure: do not bootstrap a board with a missing or mismatched feature.

   Note `hermes kanban create` takes **`--body` only** — there is no file-taking
   variant of that flag, however natural it looks. The bootstrap script passes
   `--body "$(cat …)"`. Do not invent flags; check `--help` first.

## Definition of done
ROADMAP.md + docs/chunks/* + docs/chunks/graph.json + tests/features/chunk_*.feature
committed; `contract-freeze.json` hashes every Acceptance path; graph acyclic
and its ids match the chunk files 1:1; every FR covered by ≥1 chunk; human
sign-off. Every contract has an explicit `Real sources` declaration whose
scenario mappings exactly match its `@real-source` tags.

Before sign-off run `~/.forge/repo/scripts/roadmap-check.sh <project>`. It is
advisory (ADR-0012). It counts the `Serves:`, `Touches:` and `Scenarios:` caps
stated above, off the plan; it does not evaluate the line budget.

Then run `~/.forge/repo/scripts/acceptance-freeze.sh <project>`. Unlike the
advisory sizing check, an incomplete acceptance set cannot be frozen and must
be fixed before sign-off.

Read every finding and fix the plan. Do not adjust the numbers to clear it.
Where a finding is wrong about your plan, record why in the sign-off instead of
editing the plan to satisfy it.

## Handoff
Follow `~/.forge/repo/docs/staged-run-guide.md`; never release the full graph
first. From Forge, run `make roadmap-check PROJECT=<absolute-path>` until its
status is `CLEAR`. Then run
`make commission PROJECT=<absolute-path> BOARD=<new-slug>`.
From the project root, bootstrap `--root-only`. After its approved PR is merged
and the metadata/metrics checkpoint is green, run the full bootstrap.
Interactive chunks use /start-chunk; unattended chunks use the forge-codex-lane
profile.
