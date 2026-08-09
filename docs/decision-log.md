# Decision log

Append-only running notes. Formats:
`YYYY-MM-DD CHUNK-<id>: <surprise/workaround/deviation and how it was resolved>`
`DEBT: <what and why it was accepted>` · `CARD?: <follow-up work idea>` ·
`HANDOFF: <exact state + next step>` · `RETRO-MARKER <date>`

---

2026-08-09 CHUNK-2: The Forge repository has no `tests/features` BDD runner or
`make check` target. Following CHUNK-1 and CHUNK-2's explicit contract, the four
Given/When/Then cases are executable in `scripts/verify.sh`; proof uses
`make validate` and `make verify`.

2026-08-09 CHUNK-2: CHUNK-1 is green and mergeable as PR #33 but not yet merged.
CHUNK-2 therefore started as a stacked branch from its tip to preserve the
declared dependency; rebase or retarget it onto `main` after PR #33 merges.

2026-08-09 CHUNK-2: `docs/ROADMAP.md`, `docs/chunks/`, and the readiness source
are local untracked planning inputs. Closing reconciliation marked CHUNK-2 done
in the local roadmap, but the planning bundle remains untracked and was not
swept into the implementation commits.

HANDOFF: CHUNK-2 is green and locally complete on
`chunk/2-report-in-branch`. External approval rejected the first push attempt;
after the human explicitly authorizes export to GitHub, run
`git push -u origin HEAD`, open the PR with base
`chunk/1-enforce-methodology-references-runtime-pins` and body
`.forge/chunk-2-pr-body.md`, then emit `.forge/chunk-2-metadata.json` with the
resulting PR URL.
