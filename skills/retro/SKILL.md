---
name: retro
description: Mine decision logs and board metadata for lessons; propose diffs to the Forge repo itself. Use for /retro, milestone sweeps, or the weekly flywheel cron.
---

# Retro — the flywheel. The Forge improves itself here, with consent.

Purpose: turn implementation exhaust into durable methodology improvements.
Output is a PROPOSAL (branch + PR against the forge repo), never a direct edit.

## Inputs
1. `docs/decision-log.md` entries since the last retro (each retro ends by
   writing a `RETRO-MARKER <date>` line — read from the previous marker).
2. Board exhaust for the period: completed cards' metadata + judge verdicts
   (`hermes kanban runs/list` — flags: VERIFY) or the metadata JSONs in PRs.
3. Current forge repo state: `skills/`, `rubrics/`, `templates/`.

## Process
1. **Cluster** the raw material: repeated surprises, repeated judge findings,
   repeated bounce reasons, repeated manual corrections, DEBT: and CARD? items.
   One-off events are noted but do NOT drive changes; twice is a pattern.
2. **Map each pattern to the cheapest durable fix, at the LOWEST layer:**
   - Agents keep violating a hard rule → lefthook/CI gate in `templates/` (L2),
     not more prose.
   - Workers keep needing the same knowledge → skill edit or new
     `references/` file (L1).
   - Judge keeps flagging the same class → rubric dimension update.
   - Chunks keep bouncing for size → roadmap skill sizing-heuristic edit.
   - Project-specific-only lesson → that project's AGENTS.md, not the Forge.
3. **Propose**: create branch `retro/<date>` in the forge repo, apply the edits,
   and open a PR whose body lists, per change: the evidence (≥2 incidents,
   linked), the change, and the expected effect. Small PRs — max ~5 changes;
   park the rest for next retro.
4. **Debt map**: refresh `docs/DEBT.md` in each affected project (aggregate the
   DEBT: entries, rank by interest rate — what gets worse if ignored).
5. **Mark**: append `RETRO-MARKER <date>` to each mined decision log.

## Guardrails (read carefully — you are editing your own instructions)
- Never merge your own PR. Human approves; that is the consent gate, same
  spirit as Hermes `write_approval`.
- Never grow a skill past ~150 lines; if a fix needs more, split into a
  reference file and justify it in the PR.
- Never remove a gate (lefthook/CI/rubric) without citing evidence it caused
  ≥2 false positives. Weakening verification requires the strongest case.
- If Hermes's own staged skill proposals (~/.hermes/pending/skills/) overlap
  with yours, reconcile: adopt theirs into the PR or explain why not.
