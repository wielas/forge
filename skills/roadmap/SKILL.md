---
name: roadmap
description: Slice architecture into single-session chunks and emit kanban cards. Use for /roadmap, "plan the implementation", or "create the chunks".
---

# Roadmap — from architecture to a board of executable chunks

Fresh context. Inputs are `docs/REQUIREMENTS.md` (its complexity budget),
`docs/ARCHITECTURE.md`, `docs/feasibility.md` (its estimates), `docs/adr/*`,
`AGENTS.md`. If architecture or the ledger is missing → send human to /architect.

## What a chunk is
The unit of unattended work: one fresh-context session, one branch, one PR.
A mid-weight model must be able to finish it without asking questions.

Sizing rules (the `strong` tier's; no other tier has its own caps yet):
- Fits comfortably in a single session INCLUDING tests and doc updates
  (heuristic: ≤ ~400 lines changed, ≤ ~6 files, ≤ 5 BDD scenarios).
- Independently green: after merge, `make check` passes and the system still runs.
- Code dependencies integrate through `main`: a dependent card is released
  only when its parent card is done, and a chunk card is done when its PR is
  merged (ADR-0008, ADR-0019).
- States its own context: everything the implementer needs is IN the chunk spec
  or explicitly linked (ADR ids, file paths). Never "see discussion above".
- Spec budget: a contract of at most 6000 bytes. Rationale goes to an ADR or the
  decision log, linked.

## Process
1. **Milestones.** Derive milestones from the architecture, within the scope's
   budget; order by risk (riskiest integration first, polish last). Every
   milestone ends in a **gate** (below).
2. **Chunks.** Write every contract to `docs/chunks/CHUNK-<id>.md`:

   ```markdown
   ### CHUNK-<id>: <imperative title>
   - **Goal:** one sentence.
   - **Milestone:** M<n>  ·  **Depends on:** CHUNK-a, GATE-M<n-1> | none
   - **Serves:** FR-x, NFR-y  ·  **Relevant ADRs:** 0003, 0007
   - **Touches:** paths/likely/to/change
   - **Scenarios:** Given/When/Then one-liners (these BECOME the .feature file)
   - **Real sources:** none | `<source label>` → scenario <n>[; ...]
   - **Multi-record fixtures:** none | `<path>` (<n> records) → scenario <n>[; ...]
   - **Acceptance:** tests/features/chunk_<id>.feature
   - **Out of scope:** what the implementer must NOT do
   - **Done when:** make check green + scenarios pass + docs updated
   - **Lane:** forge-codex-lane | claude-interactive  ·  **Risk:** low|med|high
   ```

   **Tier.** Give each chunk a tier in `graph.json`: `strong` (lane
   `forge-codex-lane`) or `human` (lane `claude-interactive`). `human` only where
   a decision genuinely needs the operator — at most one per milestone. `cheap`
   and `local` have no implementer until the implementer ladder is configured,
   and `roadmap-check` warns on them. The lane is the card's `--assignee`, so it
   must match a real Hermes profile. Risk `high` ⇒ note "docker backend".

   **Realistic fixtures.** Any scenario that aggregates, counts or gates over
   records gets a fixture of at least two records, declared in
   `Multi-record fixtures` and tagged `@multi-record` in the feature. A gate
   exercised on one record cannot tell "all" from "any".
3. **Gates.** Each milestone M<n> gets `docs/chunks/GATE-M<n>.md`:

   ```markdown
   ### GATE-M<n>: Milestone <n> — <what it delivers>
   - **Milestone:** M<n>
   - **Delivers:** FR-x, NFR-y
   - **Probe:** tests/probes/gate_m<n>.json
   - **Estimate:** <n> chunks
   - **Lane:** claude-interactive
   ```

   `Estimate` comes from the ledger rows the milestone delivers; the gates must
   add up to the ledger's kept estimate. The probe tests the whole milestone,
   which per-chunk review cannot see: `{"probe": "forge.probe.v1", "milestone":
   "M<n>", "cases": [...]}`. A case has a `name`, a `kind`, an `input` under
   `tests/probes/`, a `run` argv naming `{input}`, and an `expect` holding an
   `exit` and an optional `stdout` substring. At least one case is `realistic`
   with `records` ≥ 2. At least one is `adversarial`: a mutated input the system
   must reject. Write the input fixtures now, as part of the plan.
4. **Self-review pass:** simulate being the implementer of the 3 gnarliest
   chunks; if you would need to ask a question, the spec is incomplete — fix it.
5. **Emit acceptance and board inputs — as files, not as prose to be retyped.**

   `docs/ROADMAP.md` is an **index**: milestones, then one line per chunk and
   gate linking its contract, an index of at most 16000 bytes. The contract in
   `docs/chunks/` is the only full text, and it is the card body.

   Write each chunk's `Acceptance` path as `tests/features/chunk_<id>.feature`,
   where `<id>` is the lower-case portion after `CHUNK-` (hyphens become
   underscores). Translate every scenario bullet into one Gherkin `Scenario`
   with exactly one `Given`, `When`, and `Then`; the step text must match the
   contract. Scenario titles are labels, not a second contract.

   Map every real external system in `Real sources` to the one-based scenario
   that exercises it (`` `Hermes board` → scenario 2 ``), or write `none`. Each
   mapped scenario, and only those, carries `@real-source`. If no scenario can
   exercise a declared source, fix or split the contract now.

   Then write **`docs/chunks/graph.json`**, the contract with
   `hermes/board-bootstrap.sh`, which creates the cards and edges itself. Never
   print `hermes kanban` commands for a human to paste.

   ```json
   [
     {"id": "CHUNK-1", "lane": "forge-codex-lane",   "tier": "strong", "depends_on": []},
     {"id": "CHUNK-2", "lane": "claude-interactive", "tier": "human",  "depends_on": ["CHUNK-1"]},
     {"id": "GATE-M1", "lane": "claude-interactive", "depends_on": ["CHUNK-1", "CHUNK-2"]},
     {"id": "CHUNK-3", "lane": "forge-codex-lane",   "tier": "strong", "depends_on": ["GATE-M1"]}
   ]
   ```

   - `id` matches a `docs/chunks/<id>.md` file exactly.
   - A gate's `depends_on` is exactly its milestone's chunks; every chunk of the
     next milestone depends on the gate. Its `lane` is `claude-interactive`: the
     card is held for the operator. It is never `forge-codex-lane`.
   - `depends_on` is acyclic and authoritative over ROADMAP.md's prose.

   Finally run `~/.forge/repo/scripts/acceptance-freeze.sh "$PWD"`. It validates
   every `Acceptance`, `Real sources` and `Multi-record fixtures` field, and
   every gate's probe. Then it atomically writes
   `docs/chunks/contract-freeze.json`, the SHA-256 of every feature, probe and
   probe input. A failure is a planning failure: do not bootstrap past it.
   `hermes kanban create` takes **`--body` only**; do not invent flags.

## Definition of done
ROADMAP.md, docs/chunks/*, graph.json, the feature files and probes are
committed. `contract-freeze.json` hashes every one of them. Every FR is covered
by ≥1 chunk, and the human has signed off.

Before sign-off run `~/.forge/repo/scripts/roadmap-check.sh <project>`. It is
advisory (ADR-0012). It checks the following:
- the caps above and the spec budget;
- the gates;
- the tiers;
- the scope's budget;
- the ledger's estimate.

Then run `~/.forge/repo/scripts/acceptance-freeze.sh <project>`. It is not
advisory: an incomplete acceptance set cannot be frozen. Read every finding and
fix the plan, not the numbers. Where a finding is wrong about your plan, record
why in the sign-off.

## Handoff
Follow `~/.forge/repo/docs/staged-run-guide.md`; never release the full graph
first. From Forge, run `make roadmap-check PROJECT=<absolute-path>` until its
status is `CLEAR`. Then run
`make commission PROJECT=<absolute-path> BOARD=<new-slug>`.
From the project root, bootstrap `--root-only`. After its approved PR is merged
and the metadata/metrics checkpoint is green, run the full bootstrap.
Interactive chunks use /start-chunk; unattended chunks use the forge-codex-lane
profile.
