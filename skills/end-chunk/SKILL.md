---
name: end-chunk
description: Closing ceremony for a chunk - reconcile docs, open the PR, emit structured metadata. Use for /end-chunk <id> or "wrap up this chunk".
---

# end-chunk — prove it, reconcile it, hand it off

Run ONLY on a `chunk/<id>-*` branch with /start-chunk steps complete.

## 1. Final green proof
`make check` — full output must end green. If anything fails, you are still in
/start-chunk step 5. Never skip hooks, never `--no-verify`.

## 2. Spec reconciliation (anti-drift — do not skip)
Diff reality against the paper trail, update IN THIS BRANCH:
- `docs/ROADMAP.md`: chunk status → done; adjust downstream chunk specs if this
  chunk changed their ground truth (say so in the PR body).
- `docs/ARCHITECTURE.md` / ADRs: if implementation deviated from a recorded
  decision, either update the ADR (small drift, note why) or add a new
  superseding ADR (real change). An architecture doc that lies is worse than none.
- `docs/REQUIREMENTS.md`: only if scope genuinely moved — flag loudly.
- `AGENTS.md`: new commands, conventions, or gotchas the next session needs.

## 3. Self-review
`git diff origin/main...HEAD` — read it as a hostile reviewer: dead code, debug
leftovers, missing edge-case scenarios, naming drift from AGENTS.md. Fix now.

## 4. PR
```bash
git push -u origin HEAD
gh pr create --title "CHUNK-<id>: <title>" --body-file .git/PR_BODY.md
```
PR body (write `.git/PR_BODY.md`): chunk goal · scenario list with pass status ·
`make check` tail · decision-log entries added · doc reconciliation summary ·
DEBT/CARD? items. The template in `.github/PULL_REQUEST_TEMPLATE.md` matches.

## 5. Emit metadata (the structured handoff)
Produce the JSON defined in `rubrics/kanban-metadata-schema.md` and:
- Unattended lane: print it between `FORGE_METADATA_BEGIN` / `FORGE_METADATA_END`
  markers on stdout — the lane runner scrapes it into `kanban_complete`.
- Interactive: save as `.git/chunk-<id>-metadata.json` and paste into the card's
  completion if you have board access.

## 6. Stop
Do not merge. Do not start the next chunk. Merging happens after the judge
verdict + human gate. Fresh context is the next worker's right.
