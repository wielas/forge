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
2026-08-10 CHUNK-5: The repository still has no `tests/features` BDD runner or
`make check` target. The five Given/When/Then cases are executable in the
`metrics/` group of `scripts/verify.sh`; the chunk contract's `make validate`
and `make verify` remain the definition of done.

2026-08-10 CHUNK-5: CHUNK-5 started from the completed local CHUNK-4 tip to
preserve the current serial stack. The readiness source, roadmap and chunk
cards remain local untracked planning inputs and are not included in the
implementation commits.

2026-08-10 CHUNK-5: Hermes 0.19 stores missing actual cost differently across
the joined substrates: `sessions.actual_cost_usd` is null, while
`session_model_usage.actual_cost_usd` is `NOT NULL DEFAULT 0`. Metrics preserves
that zero only when the same row's `cost_status` says actual; estimated rows
render actual cost as missing.

2026-08-10 CHUNK-5: A read-only replay of `forge-ladder` for
2026-07-29..2026-07-30 joined 15/17 completed chunk sessions, reported
$1.518740104 estimated driver cost with actual cost absent, and reproduced 9
visible operator touches. The retro log records this as executable backfill,
not recollection.

2026-08-10 CHUNK-5: The sandboxed full verification attempt reproduced the
known home-directory lab, live-profile and UV-cache restrictions and was not a
valid repository verdict. The approved host-level rerun completed with 261
passed, 0 failed and 3 skipped; `make validate` also reports OK.

HANDOFF: CHUNK-5 is green and locally complete on
`chunk/5-join-exact-driver-usage`, rebased onto the exact exported CHUNK-4 tip
`3d6f7e3` / PR #36. External approval rejected the push because this request
did not explicitly authorize disclosure to the configured remote. After the
human explicitly authorizes GitHub export, run `git push -u origin HEAD`, open
a PR against `chunk/4-scoped-live-metadata-sweep` with
`.forge/chunk-5-pr-body.md`, then write and validate
`.forge/chunk-5-metadata.json` with the resulting PR URL. Do not merge; retarget
only after PR #36 and the lower stack land.

2026-08-10 CHUNK-5: The preceding HANDOFF is resolved. The human explicitly
authorized GitHub export; branch `chunk/5-join-exact-driver-usage` was pushed
and stacked PR #37 opened against CHUNK-4's exact remote branch / PR #36.
GitHub reports the intended base and head, the PR is open and mergeable, and
`.forge/chunk-5-metadata.json` validates against the `forge-codex-lane`
completion contract. Do not merge before the lower stack lands.

2026-08-11 CHUNK-5: Independent review found that completed runs 37 and 60 on
the 2026-07-29..2026-07-30 `forge-ladder` replay share
`forge-codex-lane/20260730_091931_9a5faf`. The original replay charged that
session twice. Coverage remains 15/17 joined runs, but those joins represent 14
unique sessions and the corrected estimated cost is `$1.452335808` with actual
cost absent. Metrics now preserves both run mappings and aggregates each unique
profile/session tuple once.

2026-08-10 CHUNK-4: CHUNK-4 initially started from CHUNK-1's tip, its declared
dependency. During the run, the tracked CHUNK-3 handoff recorded the human's
explicit serial-stack decision, so the four unpublished CHUNK-4 commits were
rebased without conflict onto the verified CHUNK-3 head `0fb1a9a`.

2026-08-10 CHUNK-4: The five Given/When/Then cases and the snapshot dependency
proof are executable mutations in `scripts/verify.sh`. This repository still
has no `tests/features` runner or `make check`; the chunk's explicit
`make validate` and `make verify` done condition remains authoritative.

2026-08-10 CHUNK-4: `scripts/metadata-live.sh` owns the exact 0/1/2 contract.
The Make wrapper is the documented operator vocabulary, but make itself maps a
failed recipe to a generic nonzero status; diagnostics and the four printed
counts retain the contract-vs-unjudged distinction for Make callers.

2026-08-10 CHUNK-4: The required host-access proof on the final rebased stack
completed with `make validate` green and `make verify` at 252 passed, 0 failed,
7 skipped. The skips are the paid Codex probe, two non-spawnable assignees, and
four linked-worktree profile-path checks against the main checkout.

2026-08-10 CHUNK-4: The local untracked roadmap is marked done. As for CHUNK-2
and CHUNK-3, the readiness planning bundle remains outside implementation
commits; the tracked append-only decision log carries the durable reconciliation.

HANDOFF: CHUNK-4 is green and locally complete on
`chunk/4-scoped-live-metadata-sweep`, stacked on PR #35's exact remote head.
No branch or payload has been exported. After the human explicitly authorizes
GitHub export, push the branch, open a PR against
`chunk/3-deterministic-diagnostics` with `.forge/chunk-4-pr-body.md`, then write
and validate `.forge/chunk-4-metadata.json` with the resulting PR URL. Do not
merge; retarget only after the lower stack lands.

2026-08-10 CHUNK-4: The preceding HANDOFF is resolved. The human explicitly
authorized GitHub export; the branch was pushed and stacked PR #36 opened
against `chunk/3-deterministic-diagnostics`, whose exact remote head remains
CHUNK-4's merge-base. The PR is intentionally unmerged and must stay stacked
until PR #35 and the lower chain land.
2026-08-11 CHUNK-4: Independent review rejected the operator guide's use of the
Make wrapper as though it preserved `metadata-live.sh`'s exact 0/1/2 machine
contract. GNU Make cannot preserve a recipe's 1-versus-2 distinction. The guide
now directs automation to the script, labels Make as a human-facing generic
success/failure wrapper, and the metadata suite asserts that distinction. The
planning artifact must carry the same clarification before integration.

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

2026-08-11 CHUNK-8: Independent review drove `CHUNK 1` through three Hermes
mutations before structural failure and found that a human-completed
interactive root was rejected by full bootstrap. Canonical chunk-id validation
now runs before the first Hermes command in both root-only and full modes, with
space, slash, traversal, and malformed-dependency mutations. Terminal
interactive roots retain their done state and human assignee. An opt-in run
against the installed Hermes CLI in an isolated temporary home proved the real
one-root-to-two-card extension and its actual `task_links` edge (7/0/0).

2026-08-11 CHUNK-9: The human explicitly authorized a convergence stack for the
two open prerequisite lines. `integration/chunk-9-prerequisites` starts at the
CHUNK-8 head and merges the CHUNK-5 head; the CHUNK-9 branch and PR use that
synthetic branch as their base so prejudge and judge see only the CHUNK-9 diff.
Merge the existing chains in their declared parent-first order, retarget CHUNK-9
to `main` only after both prerequisite heads are integrated, and delete no base
branch until its child PR has been retargeted. The synthetic base is never
merged independently; it exists only to give the authorized stack one complete
review base.

2026-08-11 CHUNK-9: Commissioning is an evidence aggregator over existing
controls, not a new launch policy. After safe inputs and the ignored evidence
path are established, it runs every prerequisite even if an earlier one fails,
so the report is complete and the single paid Codex probe still spends. Any
nonzero result makes the aggregate fail; roadmap output is stored verbatim and
is never renamed PASS.

2026-08-11 CHUNK-9: Board invariance is measured without opening SQLite. The
commissioner fingerprints the selected database plus `-wal`, `-shm`, and
`-journal` sidecars before and after, calls no Hermes command, and separately
requires both clean git states. Remote visibility is deliberately not queried:
the existing `merge-gate.sh` must prove a PR rule and the product template's
required `check` context.

2026-08-11 CHUNK-9: This repository still has no `make check` target. The
chunk's frozen done condition names `make validate` and `make verify`, so those
are the end-ceremony proof. The intentional host run used `WITH_CODEX=1` and
completed at 281 passed, 0 failed, 2 skipped; its live probe id was
`verify-codex-1786433343-27716`. No requirements or architecture decision moved.

2026-08-11 CHUNK-9 audit correction: The earlier paid verification was not an
end-to-end commissioning run. Independent review also found that ambient
`gh repo view` could identify a repository different from the product's
`origin`, and that report writes were unchecked. Commissioning now parses and
validates GitHub HTTPS/SSH origin forms, queries that explicit slug, requires
the returned identity to match exactly, and publishes a uniquely named report
atomically with every write checked. Regressions cover a mismatched GitHub
identity and failed final publication.

2026-08-11 CHUNK-9 live correction: A control run against `wielas/forge`
correctly failed closed because its real required contexts are `validate` and
`verify`, not the product contract's `check`. The definitive `make commission`
run then used the real protected first-run product `wielas/forgeboard-report`:
all nine report sections exited zero; protection was `GATED via=classic
pr=yes checks=check`; paid verification was 289/0/3 with live run
`verify-codex-1786440235-35663`; clean tree and absent-board fingerprints were
unchanged; and the atomic report ended PASS with SHA-256
`813af7f013c301869079d49b408e53788049dd0bfec1e4a57c652066fb72bc80`.

2026-08-11 CHUNK-10 planning amendment: Independent review found that the
reconciliation branch already changes `scripts/verify.sh` to enforce its four
documentation scenarios, but the frozen contract authorized only the four
documents. Before CHUNK-10 implementation is integrated, its Touches surface is
widened on the approved base to include that executable verifier. Scenarios,
real-source declarations, acceptance path, and feature bytes do not change.

2026-08-11 CHUNK-10: The frozen planning bundle and all three prerequisite
heads are present on the CHUNK-9 convergence stack but not yet on `origin/main`.
CHUNK-10 therefore branches from the exact CHUNK-9 tip `52b4be0` instead of
dropping its approved feature, freeze manifest, or prerequisites. Retarget only
after the lower stacks integrate.

2026-08-11 CHUNK-10: The repository still has no BDD step runner or `make check`
target. The four documentation scenarios are executable as the new `docs/`
group in `scripts/verify.sh`; this is a small declared-path widening required by
ADR-0003, while the frozen feature and manifest remain byte-identical.

2026-08-11 CHUNK-10: Final host proof completed with `make validate` OK,
`make verify` at 285 passed / 0 failed / 3 skipped, `make preflight` at PASS 85 /
WARN 3 / FAIL 0, and the ten-chunk roadmap CLEAR at 9 pass / 0 warn / 0 skip
when supplied the live `forge-codex-lane` assignee. Preflight measured Claude
Code 2.1.227, one patch newer than the readiness source; `docs/state.md` records
the live version while the dated 2026-08-09 measurement remains unchanged.

HANDOFF: CHUNK-10 is green on `chunk/10-reconcile-launch-ledger-and-operator-contract`; GitHub export was rejected absent explicit authorization.
After authorization: push, open the stacked PR against `chunk/9-commission-product-run-with-existing-gates` with `.forge/chunk-10-pr-body.md`, then write/validate metadata with its PR URL.
Do not merge; retarget only after the lower readiness stacks integrate.

2026-08-11 CHUNK-10 audit correction: F40 was promoted to fixed while the
operator guide still omitted the exact slice-worktree creation command, the
main-checkout reservation, ledger ownership, and the handoff boundary. Those
rules are now explicit and mutation-tested. F102's original CHUNK-9 attribution
was also unsupported by the earlier standalone paid verifier; the audited full
commission against `wielas/forgeboard-report` now supplies the real six-chunk
roadmap input (6 pass / 3 warn / 0 skip) without pretending those advisories are
CLEAR or authorizing the future blocking flip.

2026-08-11 CHUNK-10: The preceding HANDOFF is resolved. Human authorization exported the branch and opened stacked PR #42 against CHUNK-9's exact remote branch.
GitHub reports the intended seven-file diff as open and mergeable; `.forge/chunk-10-metadata.json` validates against the lane completion contract.
Do not merge; retarget only after the lower readiness stacks integrate.

2026-08-11 CHUNK-10 final audit proof: The earlier 285/0/3 entry predates the
independent repairs and remains historical. The reviewed stack completed
`make validate` OK, default `make verify` at 297/0/4, clean-tree preflight at
PASS 85 / WARN 3 / FAIL 0, the ten-chunk roadmap at CLEAR 9/0/0 with both
declared assignees supplied, and the opt-in installed-Hermes bootstrap at 7/0/0.
