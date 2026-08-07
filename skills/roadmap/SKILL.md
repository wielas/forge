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
4. **Emit the board inputs — as files, not as prose to be retyped.**

   Write each chunk spec to `docs/chunks/CHUNK-<id>.md` (the card body and the
   ROADMAP entry must be the same text — generate both from one source).

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

   Note `hermes kanban create` takes **`--body` only** — there is no file-taking
   variant of that flag, however natural it looks. The bootstrap script passes
   `--body "$(cat …)"`. Do not invent flags; check `--help` first.

## Definition of done
ROADMAP.md + docs/chunks/* + docs/chunks/graph.json committed; graph acyclic and
its ids match the chunk files 1:1; every FR covered by ≥1 chunk; human sign-off.

Before sign-off run `~/.forge/repo/scripts/roadmap-check.sh <project>`. It is
advisory (ADR-0012) and it counts three of the numbers above off the plan: ≤ 4
`Serves:`, ≤ 6 declarable `Touches:`, ≤ 5 scenarios. It cannot evaluate the
≤ ~400-line budget; nothing can, at plan time.

Read every finding and fix the plan — this is the last moment fixing one is
cheap. Do not adjust the numbers to clear it. Where a finding is wrong about
your plan, record why in the sign-off instead of editing the plan to satisfy it.

## Handoff
Human runs `hermes/board-bootstrap.sh <project>`, which reads `graph.json`,
creates every card (interactive chunks included, blocked rather than skipped)
and creates the edges. Implementation proceeds via /start-chunk (interactive) or
the forge-codex-lane profile (unattended).
