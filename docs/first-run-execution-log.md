# First-run roadmap — execution log

**CLOSED 2026-08-31 and committed as a historical record.** Every PR below is
merged and `main` is past all of them; it is kept for the same reason as
`ladder-2026-07-28.md` — evidence of what the run cost to learn, not a live
state file. Do not update it; open a new log for a new run.

*Original header, true while it was in flight:* Live orchestration state,
untracked on purpose. The plan is
`docs/roadmap-first-run.md` (PR #24). This file is the *state of executing it*,
written so a session starting with no context can take over.

Updated 2026-08-07, after the Phase B gate round (see `docs/pr-repair-plan.md` S7).

---

## Merge state

| PR | Branch | What | CI | State |
|---|---|---|---|---|
| #21 | `slice/agent-config` | `CLAUDE.md` router + allowlist | ✅ | **MERGED** `a4d81c1` |
| #29 | — | (Phase A) | ✅ | **MERGED** `472e11e` |
| #24 | `slice/run-roadmap` | the roadmap doc (docs-only) | ✅ | **MERGED** `8247ae8` (squashed) |
| #23 | `slice/agent-orientation` | allowlist, operator's own PR | ✅ | **MERGED** `e34147a` |
| #25 | `slice/ledger-reconcile` | D1a: reconciliation, F-allocator, F79 | ✅ | **MERGED** `d24f797` |
| #30 | `slice/preflight-f79` | D1e: `merge-gate.sh` + verify `gate` group (F110) | ✅ | **MERGED** `e52a478` |
| #26 | `slice/durable-worktrees` | A1: durable dest + worktree sweep | ✅ | **MERGED** `9e91a80` |
| #27 | `slice/snapshot-primitive` | B1: WAL snapshot primitive | ✅ | **MERGED** `bf9cd1c` |
| #28 | `slice/roadmap-check` | C1: `make roadmap-check` + ADR-0012 | ✅ | **MERGED** `fc006eb` |
| #31 | `slice/state-reconcile` | state.md + ledger + operator-guide reconciliation | — | open |

**`main` is at `fc006eb`.** Phase A landed #29 → #24 → #23 → #25; the repair
effort then landed **#30 → #26 → #27 → #28** on 2026-08-08. Only #31, the
reconciliation, is still open.

**The stack landed by merging forward, never rebasing**, which is how it has been
kept current since S3. Every conflict along the way was an append-at-the-same-
offset union — a suite name, a `bash -n` entry, a CI suite list, a ledger section
appended against an empty base — resolved by keeping **both** sides.

**Correction to what this file used to say:** "GitHub auto-retargets to `main` as
each parent merges" is *not* reliable. It holds when the branch is deleted as part
of the merge; when it is deleted separately, the child PR is **closed** instead.
See the trap below.

**Landed. Nothing remains in that order.** Post-merge on `main`, from the main
checkout: `make validate` OK · `make verify` **231 / 0 / 3** · `make preflight`
**PASS 85 / WARN 3 / FAIL 0**. No SOUL or profile file changed across the four
merges, so `profiles-bootstrap.sh` (F60) was not triggered — checked, not assumed.

**One operational trap, paid for in full:** deleting a parent branch *separately*
from its merge **closes** the child PR rather than retargeting it, and a closed PR
can be neither reopened nor retargeted while its base ref is missing. #27 hit this.
Recovery is to push the merged commit back under the old branch name, reopen,
retarget, delete again. The order that avoids it — merge, retarget the child,
*then* delete — is now in `docs/operator-guide.md`.

All conflicts were append-to-the-same-line and resolved as unions: `.PHONY`, the
`bash -n` list in `validate`, `verify.sh`'s suite-name arg arm, its default
`SUITES` list, and two group definitions appended at the same offset.

**Integrated verification (main + all five, on macOS): `176 passed / 0 failed /
7 skipped`.** That is exactly the 129 linked-worktree baseline plus A1's 17, B1's
7 and C1's 23 — additive with nothing lost, so no slice broke or shadowed
another's cases.

That measurement predates Phase A's merges. **After them, `main` is at `d24f797`**
and its gates are **`make verify` 139/0/3** and **`make preflight`
PASS 84 / WARN 3 / FAIL 0**. The WARN count is the healthy baseline per
`docs/state.md`, not something to chase to zero; the PASS count rises as checks
are added, so compare `FAIL` and investigate a *drop* in PASS.

**Merges are blocked on CI, not on review.** See "The CI wall" below. Do not
merge on a gate that did not run — `Makefile:14` states the repo's own rule that
exit 1 (block) and exit 2 (gate failed to run) must never be conflated.

---

## Track state

| Track | Slice | Branch | State |
|---|---|---|---|
| D | **D1a** ledger reconciliation + F79 | `slice/ledger-reconcile` | **done**, PR #25 |
| A | **A1** durable dest + worktree sweep | `slice/durable-worktrees` | **done**, PR #26 — 146/0/7, 15/15 mutations |
| B | **B1** WAL snapshot primitive | `slice/snapshot-primitive` | **done**, PR #27 — 136/0/7, 8/8 mutations |
| C | **C1** `make roadmap-check` | `slice/roadmap-check` | **done**, PR #28 — 152/0/7, 30 mutations; **over budget, declared** |
| D | **D1e** merge gate as a program (F110) | — | **MERGED**, PR #30 — closes F79 |
| D | **D1e** merge gate as a program (F110) | `slice/preflight-f79` | **done**, PR #30 — 151/0/7, 11/11 mutations; closes F79 |
| D | D1b pin-agrees + section-refs | — | not started |
| D | D1c `touches` widening (F55/F57) | — | not started |
| D | D1d `skill_manage` decision → ADR | — | not started |
| D | D2 F48 spike + `/retro` rehearsal | — | not started |
| C | **C2** frozen acceptance | — | not started — **run interactively**, it has a drop rule |
| E | **E1** `--root-only` + thin `make commission` | — | blocked on A1, B1→B2, C1 |
| B | B2 `make metadata-live` | — | blocked on B1 |

### Partial work on disk (uncommitted, in agent worktrees under `.claude/worktrees/`)

- **A1** — `Makefile` and `scripts/verify.sh` modified; `scripts/new-dest.sh` and
  `scripts/worktree-sweep.sh` created. Furthest along; was placing verify cases.
- **B1** — `scripts/board-snapshot.sh` created. Was about to write the primitive.
- **C1** — `scripts/touches-exempt.sh` created. Was about to write the validator.

**Land order is A1 → B1 → C1**, because all three touch `Makefile` and
`scripts/verify.sh` (2,421 lines). Serial landing keeps conflicts to trivial
rebases.

---

## Decisions taken, with reasons

- **Wave-2 agents may not edit `docs/audit-forgeboard-2026-07-30.md`.** New
  findings go in the PR body under "New findings for the ledger"; the
  orchestrator lands them and allocates the number. This is F40's own rule — the
  ledger is the orchestrator's file and a slice must never be its only writer —
  and it is what removed #25 as a hard prerequisite for wave 2.
- **F-number blocks** are recorded in the ledger by D1a: F79 spent · A → F80–89 ·
  B → F90–99 · C → F100–109 · D → F110–119 · E → F120–129 · the run → F130+.
- **C1 and C2 ship warn-first.** F53: a gate blocking 11 of 11 PRs is not a
  filter either. Fix the *plan* until it passes; never move the threshold after
  seeing the data.
- **The Codex launcher program is deferred until after the run.** It recuts
  `forge-lane` §4, live-validated 2026-08-06, immediately before the run — the
  two-unknowns error. Its premise is also false today: the pin agrees in all
  three places. What is missing is enforcement, which is D1b's ~10-line case.

## Corrections already made to the roadmap by execution

D1a's reading corrected the plan's own §4 disposition table. Carry these:

- **F5 is FIXED**, not deferred. `prejudge.sh:208` blocks an empty rollup citing
  F5; `prejudge/absent-ci-is-not-a-pass` executes it (`verify.sh:1953`).
  Independently verified.
- **F35 is PARTLY fixed.** The gate shipped; the model call still exists and
  still reads tier 2's rubric. Its deletion is D9.5's experiment.
- **F62, F63 fixed. F9, F17 are not "moot with forgeboard"** — neither concerns
  forgeboard's code.
- **Ten findings the plan omitted** are now classified (F8, F10, F15b, F16, F22,
  F40, F41, F55, F60, F61).

---

## Open blockers needing the operator

### 0. New findings awaiting the orchestrator's ledger sweep

Held in PR bodies only, per the no-slice-writes-the-ledger rule. Numbers are
claimed from each track's block but **not yet written**:

- **F79** (D1a, in #25) — **written to the ledger and closed for this repo.** It
  recorded no branch protection and no installed pre-push hook; the repo was made
  public and gated by ruleset `mainprotect` on 2026-08-07. The pre-push hook is
  still absent by decision. See §2 below — the *propagation* to the product repo
  is still open.
- **F80** (A1) — the stale worktrees are **not** under `.worktrees/`: 23 total,
  1 under `.worktrees/` (1.2 MB), **16 under `/Users/goonlab/dev/forge-slices/`
  (15 MB)**. The sweep is correctly bounded and reclaims 1, refuses 22.
  **Operator decision owed:** widen the bound, or a separate explicit pass.
- **F81** (A1) — `docs/audit-2026-07-27.md:220` prescribes
  `make new NAME=probe-$$ DEST=/tmp`. Stamping into `/tmp` was a *documented,
  copy-pasteable instruction*. A fuller root cause for F19 than the `..` default.
- **F82** (A1) — `verify.sh`'s template group asserted a stamp came up green,
  never *where* it landed.
- **F90** (B1) — `sqlite3` open errors go to **stderr/exit 14 in query form** but
  **stdout/exit 1 in script form**; `metrics.sh` uses script form. This is both
  why F47 was silent and why verifying it the obvious way concludes it does not
  exist. **Belongs in `docs/hermes-field-notes.md`, not only the ledger.**
- **F91** (B1) — three of four `sed`-based `--help` extractors print wrong text;
  `verify.sh --help` truncates before `metadata/` and `prejudge/`.
- **F92** (B1) — `metrics/is-read-only` hashes only `kanban.db`, so it passes on
  a reader that creates sidecars.
- **F93** (B1) — the live check picks its board with `ls | head -1`.
- **F100** (C1) — under `set -o pipefail` an output-reading test helper inherits
  the checker's exit status, producing plausible-but-false content claims.
- **F101** (C1) — `reachable` has no recall independent of `acyclic` +
  `single-root`; kept for its evidence, and it `skip`s rather than passes.
- **F102** (C1) — **ADR-0012's flip procedure has an unexecutable step**: there is
  no real product roadmap left to run against, so four rule families have only
  ever seen fixtures. **The warn→block flip must happen during the run's own
  planning phase, not before it.**
- **F103** (C1) — the plan-time and review-time justifications for the `Touches`
  exemption differ; F55's measurement does not transfer to plan time.

### 1. The CI wall

Run history has a hard boundary: everything through **11:37Z succeeded**,
everything from **15:53Z onward failed** — across three branches including
`main`, all at job setup, zero steps executed. First failure text was
`Failed to resolve action download info: Service Unavailable`.

Two candidate causes, not yet distinguished:
- a GitHub Actions platform incident
- **free-plan Actions minutes exhausted** (private repos get 2,000/month)

`gh auth refresh -h github.com -s user` has been run, so
`gh api /users/wielas/settings/billing/actions` can now answer it. Or read
`github.com/settings/billing` directly.

### 2. Product repo visibility — run-blocking, decide before Track E

F79 established, on 2026-08-06, that `wielas/forge` had **no branch protection**
(private repo, free plan → 403 on both the protection and rulesets APIs) **and no
installed pre-push hook** (`.git/hooks` is samples only, `core.hooksPath` unset,
and the root `Makefile` has no `protect` target — only the template does).

**Resolved for this repo on 2026-08-07:** it was made public and ruleset
`mainprotect` is `active` — PR required, deletion and non-fast-forward blocked,
`validate` and `verify` required green, zero approving reviews (deliberate for
self-authored PRs; the gate is CI). Confirm rather than trust this:
`gh api repos/wielas/forge/rulesets`. There is still **no pre-push hook** — the
ruleset is the whole gate.

**The propagation is NOT resolved and is still run-blocking.** E1's
`make commission` is specified to fail when branch protection is absent, and —
more seriously — **if the new product repo is private on a free plan, the run has
no merge gate at all**, which is the assumption ADR-0007's two-tier design rests
on. Options: make the repo public, move to a paid plan, or re-specify ADR-0007.
Decide before Track E.

### 3. C2's execution mode

Recommended **interactive, not delegated**. It is the slice with a drop rule (if
it bounces twice, ship C1 alone and record F14/F25 as open for the run), and a
delegated agent will more likely ship it half-built than invoke the rule.

---

## Operational facts worth not rediscovering

- **`make verify` in a linked worktree is 129/0/7**, versus 133/0/3 on main. The
  four extra skips are F49's live profile-path checks, by design. Not a defect.
- **`make preflight` FAILs on a branch that adds a lane-critical script**,
  because `~/.forge/repo` points at the main checkout. That is the check working;
  it clears on merge.
- **Never run `make verify WITH_CODEX=1`** casually — it spends real tokens.
- **After any merge touching a SOUL, run `./hermes/profiles-bootstrap.sh`** (F60),
  and run `make verify` **and** `make preflight` after every merge (F65/F66:
  checks anchored to moved content degrade to skip/warn rather than failing).
- **Subagent cost on this repo is ~150–210k tokens each**, and most of it is
  comprehension — re-reading `CLAUDE.md`, `state.md`, ledger sections and target
  scripts. Three in parallel exhausted the session quota before any produced
  output. Run them **serially**, and **resume** rather than restart, so the
  comprehension is paid once.
