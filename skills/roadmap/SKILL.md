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
4. **Emit the board.** Print (do not execute unless asked) the bootstrap
   commands, one per chunk, matching `hermes/board-bootstrap.sh` conventions:

   ```bash
   hermes kanban create "CHUNK-<id>: <title>" \
     --assignee <lane> --tenant <project> \
     --body-file docs/chunks/CHUNK-<id>.md        # exact flags: VERIFY vs docs
   # + link commands expressing the Depends-on graph
   ```

   Also write each chunk spec to `docs/chunks/CHUNK-<id>.md` (the card body and
   the ROADMAP entry must be the same text — generate both from one source).

## Definition of done
ROADMAP.md + docs/chunks/* committed; dependency graph acyclic; every FR covered
by ≥1 chunk; human sign-off; board bootstrap block printed.

## Handoff
Human runs `hermes/board-bootstrap.sh <project>`; implementation proceeds via
/start-chunk (interactive) or the forge-codex-lane profile (unattended).
