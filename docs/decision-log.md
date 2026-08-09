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
