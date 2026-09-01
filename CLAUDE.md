# Forge — agent orientation

Forge is a development methodology as a versioned artifact. This file is a router
and a list of invariants, not documentation — the repo already documents itself,
and a second description here would drift from the first.

## Read in this order, before proposing anything

1. `docs/state.md` — what is *proven* vs merely *claimed*, and what to do next.
   It is written for a session starting with no context. Start here, not at the README.
2. `README.md` — the five-layer architecture (L1 methodology → L5 flywheel) and why.
3. `docs/hermes-field-notes.md` — how the substrate actually behaves. Every trap in
   it cost a run to find.
4. `docs/adr/` — rationale for every major decision. ADR-0003 and ADR-0010 constrain
   how skills may be written; read those two before editing anything in `skills/`.

**If two files disagree, `make verify` arbitrates.** Do not resolve a contradiction
between docs by reasoning about it — run the suite and believe the result.

## Invariants that break things when violated

- **A claim that cannot be asserted may not appear in a skill body** (ADR-0003).
  Skill bodies are executed by machines that cannot tell aspiration from observation.
  If you add a claim to `skills/*/SKILL.md`, add the check to `scripts/verify.sh`
  that executes it.
- **Skills reach scripts through `~/.forge/repo/scripts/...`, never a relative path.**
  A bare relative path cannot resolve from a project worktree. `verify.sh` and
  `preflight.sh` both assert this for `forge-lane` §3 and §5 by grepping for the
  literal `~/.forge/repo` form — changing the call style silently degrades those
  checks to a skip.
- **Hermes boards are WAL. Never open one `mode=ro`** — a read-only open fails when
  the board is *idle*, not busy. Snapshot with `cp` and open the copy.
- **`adapters/` carries no methodology** (L3). Per-harness sugar only. Methodology
  lives in `skills/` and `rubrics/`.

## Commands

- `make validate` — frontmatter + `bash -n`. Cheap, syntactic only.
- `make verify` — the conformance suite; executes this repo's claims. `SUITES=` to
  narrow (groups: cli, config, substrate, template, lane, bootstrap, commission,
  metrics, metadata, prejudge, sweep, roadmap, gate, docs, quota, manifest).
- `make verify WITH_CODEX=1` — **spends tokens** on live sandbox probes. Not casual.
- `make preflight` — read-only revalidation of the mini before unattended work.
- `make prejudge PR=<url|number>` — tier-1 stage 1. Exit 1 = block, exit 2 = the gate
  failed to run. These are deliberately different; do not conflate them.

**After every merge to main, run `make verify` AND `make preflight`.** Checks anchored
to content that moved degrade to skip/warn rather than failing loudly, so a merge that
relocates what a check reads can blind it without turning anything red.

## Conventions

- Work happens on `slice/*` branches merged via PR, and since 2026-08-07 that is
  **enforced**: `wielas/forge` is public and ruleset `mainprotect` requires a PR,
  blocks deletion and non-fast-forward pushes, and requires the `validate` and
  `verify` checks to be green. It requires **zero approving reviews**, which is
  deliberate for self-authored PRs — the gate is CI, not a second person.
  No pre-push hook is installed; the ruleset is the whole gate (audit **F79**).
  `make verify SUITES=gate` asserts the *logic* of this against a stubbed `gh`,
  and `make preflight` asks GitHub itself through `scripts/merge-gate.sh` — treat
  a preflight FAIL here as authoritative. **A product repo need not be gated:**
  since ADR-0017 a private repo on a free plan reports `UNAVAILABLE` (exit 5),
  which commissions and records `posture: UNGATED` rather than refusing. Exit 2
  still refuses — "cannot be asked" is not "could not ask". Neither can prove what the live ruleset
  says today, so confirm that part rather than trusting this paragraph:
  `gh api repos/wielas/forge/rulesets`.
- Findings carry stable `F<n>` identifiers across the audit docs. Reuse the existing
  number when revisiting one; do not renumber.
