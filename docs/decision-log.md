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

2026-08-09 CHUNK-2: The preceding HANDOFF is resolved. Human approval exported
the branch and opened stacked PR #34 against the CHUNK-1 branch; GitHub reports
the intended seven-file diff as mergeable. Retarget to `main` after PR #33
merges, then run the normal judge and human merge gate.

2026-08-10 CHUNK-3: CHUNK-3 initially started from CHUNK-1's tip because that
was its declared dependency. The human then explicitly requested a serial PR
stack, so its six implementation commits were rebased onto the verified remote
CHUNK-2 head `c618bc6`; PR #34 is open, non-draft, mergeable/CLEAN, with both
required checks passing.

2026-08-10 CHUNK-3: The five Given/When/Then cases are executable mutations in
`scripts/verify.sh`; the repository still has no `tests/features` runner or
`make check`, so the chunk contract's `make validate` and `make verify` remain
the definition of done.

2026-08-10 CHUNK-3: The sandboxed full verify run could not create the protected
home-directory lab or use the UV cache and produced substrate-only failures.
The required host-access rerun completed with 246 passed, 0 failed, 3 skipped.

2026-08-10 CHUNK-3: The local untracked roadmap is marked done, but—as for
CHUNK-2—the readiness planning bundle remains outside implementation commits.
Now that CHUNK-3 is stacked on CHUNK-2, its entries extend the tracked
append-only decision log without an add/add conflict.

2026-08-11 CHUNK-6: Independent review found that the first acceptance freeze
required only one global `@real-source` tag and inferred sources from a finite
word list. CHUNK-4 proved the resulting scenario theater by tagging its
before-any-board-read refusal. Contracts now declare arbitrary source labels
with exact one-based scenario mappings; the checker rejects missing, extra, or
misplaced tags and hashes the same bytes it validated. This first Forge plan is
recorded as a retrofit, and the local stack is reordered so CHUNK-6 follows
CHUNK-3 and precedes CHUNK-4/5 before merge.
2026-08-11 CHUNK-1: Complete hosted-CI review exposed a Linux-only blast-radius
false positive: GNU `stat -f` reports filesystem statistics rather than a
file-mode format, so clean hook state appeared to change between snapshots.
`scripts/lane-blast-radius.sh` now tries GNU `stat -c` before the BSD fallback,
and the lane verifier preserves failed-command output and evidence for future
diagnosis. The CHUNK-1 `Touches` contract is widened to record this repair.

2026-08-11 CHUNK-7: Independent review reproduced a contract-only
self-amendment: weakening a chunk's `Then` while leaving its feature and hash
unchanged passed `--check-base`. The implementation gate now compares the
approved and head Scenarios block, Real sources mapping, and Acceptance path in
addition to manifest and feature bytes. Mutations cover both a weakened Then
and a redirected Acceptance field while ordinary Touches drift remains outside
this blocking surface.
