# Forge

**Your development methodology as a versioned, self-improving artifact.**

Forge is a personal AI-development operating system: the scope → architect → roadmap →
chunked-BDD-implementation workflow, encoded as portable agent skills, enforced by
repo-level gates, orchestrated by a Hermes kanban board on an always-on Mac mini, and
improved by a consent-gated learning loop.

This README doubles as the architecture document. Rationale for every major decision
lives in [`docs/adr/`](docs/adr/).

---

## The five layers

```
┌──────────────────────────────────────────────────────────────────┐
│ L5  FLYWHEEL      Hermes learning loop, write_approval staging,  │
│                   nightly self-evolution + guardrail cron, /retro│
├──────────────────────────────────────────────────────────────────┤
│ L4  ORCHESTRATION Hermes kanban (board per project)              │
│                   Lane A: Codex unattended (codex exec, worktree)│
│                   Lane B: Claude interactive (desk / phone RC)   │
│                   Lane C: Judge, metered strong model            │
├──────────────────────────────────────────────────────────────────┤
│ L3  ADAPTERS      Thin per-harness sugar. Claude Code plugin     │
│                   (hooks, judge-assist subagent), Codex config.  │
│                   NO methodology lives here.                     │
├──────────────────────────────────────────────────────────────────┤
│ L2  ENFORCEMENT   Copier project template: uv, ruff, pytest+bdd, │
│                   lefthook, CI, Makefile, AGENTS.md as SSOT.     │
│                   Deterministic gates live in the REPO, not the  │
│                   harness. Fire identically for any agent/human. │
├──────────────────────────────────────────────────────────────────┤
│ L1  METHODOLOGY   skills/*/SKILL.md (agentskills.io open format) │
│                   + rubrics/. Read natively by Claude Code,      │
│                   Codex (symlinks) and Hermes (external_dirs).   │
└──────────────────────────────────────────────────────────────────┘
```

## Repository layout

```
forge/
├── README.md                  ← you are here (architecture + quickstart)
├── Makefile                   ← forge-level commands (install, new, check)
├── install.sh                 ← publish skills to every harness
├── docs/adr/                  ← why the Forge is shaped this way
├── skills/                    ← L1: the eight ceremony skills
│   ├── scope/  architect/  roadmap/
│   ├── start-chunk/  end-chunk/
│   ├── judge/  retro/
├── rubrics/
│   ├── judge-rubric.md        ← scoring dimensions + verdict schema
│   └── kanban-metadata-schema.md ← structured handoff contract
├── templates/python-service/  ← L2: copier template ("Chunk 0 is dead")
├── adapters/                  ← L3
│   ├── claude/forge-claude-plugin/
│   └── codex/
├── scripts/
│   └── preflight.sh           ← read-only revalidation of the mini (make preflight)
└── hermes/                    ← L4/L5 config + profile definitions
    ├── config-examples.yaml   ← settings for the DEFAULT profile
    ├── profiles-bootstrap.sh  ← creates the four forge-* profiles
    ├── profiles/*.SOUL.md     ← one identity file per profile
    └── board-bootstrap.sh
```

There is no lane runner. The lane IS a Hermes profile (`forge-codex-lane`)
that the kanban dispatcher spawns; its protocol is `skills/forge-lane/SKILL.md`.

## Quickstart

```bash
# 0. Prereqs on the mini + laptop: git, gh, uv, copier, jq, codex CLI, hermes
uv tool install copier

# 1. Publish skills to every harness (idempotent; symlinks for Claude/Codex,
#    skills.external_dirs for Hermes — the curator must not own these files)
./install.sh

# 2. Stamp a new project — Chunk 0 in one command
make new NAME=my-project           # wraps: copier copy templates/python-service ../my-project
cd ../my-project && make setup

# 3. Plan interactively (Claude Code, subscription-covered, you present)
claude                             # then: /scope → /architect → /roadmap
                                   # /roadmap ends by emitting kanban cards

# 4. Let the board work (on the mini)
./hermes/board-bootstrap.sh my-project
# the gateway's embedded dispatcher spawns forge-codex-lane on each ready card

# 5. Spot-check from anywhere
# Judge verdicts land as card metadata → Telegram gate pings you.
# Approve/bounce from your phone; steer live Claude sessions via /rc.
```

## `make verify` — the only claim in this README that checks itself

Forge tells every project it stamps that *skills persuade, gates enforce*
(ADR-0003). `make verify` is that rule applied to Forge:

```bash
make verify                     # cli + config + substrate + template + lane + metrics
make verify SUITES="cli config" # one or more suites
make verify WITH_CODEX=1        # + sandbox probes (spends tokens)
./scripts/verify.sh --list      # what it checks, without running it
```

| Suite | What it executes |
|---|---|
| `cli/` | every long flag named beside a command in `skills/`, `hermes/`, `docs/` must exist in that command's live `--help`; skill bodies carry no unverified-claim markers; descriptions fit the budget |
| `config/` | timeout, consent gate, external dirs and skill scoping, read **per profile** — not from the gateway's profile, which no worker uses |
| `substrate/` | behaviour we depend on and do not control: worktree ownership, `.git`-is-a-file, the codex sandbox commit |
| `template/` | stamp → `make setup` → hooks really installed → `make check` green → the pre-push gate exercised against a real bare remote, both ways: the push that *creates* `main` is allowed, every later one is refused |
| `lane/` | what the lane must do **for** Codex because Codex cannot: build the venv while a network still exists, and state the role boundary in the prompt (reads are not sandboxed) |
| `metrics/` | the flywheel's own numbers: a checked-in SQL board must reproduce a checked-in JSON expectation field for field, a nonconforming chunk envelope must be reported rather than normalized away, reading a board must not change it, gate blocks must stay counted apart from bounces, and `/retro` must still run the command instead of doing the arithmetic |
| `prejudge/` | the tier-1 gate: two **recorded** PRs of the audited run reproduce a checked-in severity map with no `gh`, no `git` and no network; a blocking check exits 1; every blocking finding carries an action a fresh worker can execute; and the gate contains no model call while the SOUL's scorer is still there |

Run it in CI, after every `hermes update`, and after every `codex`/`claude`
upgrade. A tool version bump that changes a flag or a sandbox rule should fail a
check, not a night run. When it disagrees with this README, **it is right and
the prose is stale** — that is the whole point of having it.

## Day-one risk burn-down: the hello-chunk test — PASSED 2026-07-28

The chain has run end to end, unattended, on the first attempt:

```
card t_1b7be3bb → dispatcher worktree → make setup → codex exec → make check
→ push → PR #1 → CI green (8s) → prejudge approve → operator judge → merged
```

`forge-hello` board, `wielas/hello-forge`, 4 minutes, one run, no retries, no
`crashed` reap. Both metadata schemas populated (`forge.chunk.v1`,
`forge.judge.v1`). The baseline row is in [`docs/retro-metrics.md`](docs/retro-metrics.md).

Reproduce it on any new project:

```bash
make preflight                      # must be FAIL 0 before anything is dispatched
make new NAME=hello-forge
cd ../hello-forge && git init -b main . && make setup
gh repo create hello-forge --public --source=. --remote=origin --push
make protect
../forge/hermes/board-bootstrap.sh forge-hello --hello
hermes kanban --board forge-hello watch
```

**What this proved that reading could not.** The ladder that got here ran in
three rungs — a real repo with no agents, then `codex exec` driven by hand with
no board, then the board — and each rung found defects invisible to the one
below. Ten findings came out of it, none catchable by `make verify` as it stood,
because the suite never pushed, never invoked Codex on a real chunk, and never
left the host. The two that would have quietly ruined everything:

- **`workspace-write` has no network, and a dispatcher worktree has no `.venv`.**
  Codex does not stop when it cannot run `make check` — it improvises. Ours
  copied 1.3 GB of `~/.cache/uv` into `/tmp` and reported a green from a command
  CI never runs. The lane now builds the environment first (`forge-lane` §3).
- **Reads are not sandboxed.** Codex followed the template's `AGENTS.md` into
  `skills/`, read `forge-lane` in full, and announced it was "using the Forge
  lane protocol" — the *caller's* playbook, push and board operations included.
  The lane now states the role boundary in every contract (`forge-lane` §4).

**The ladder was climbed a second time on 2026-07-28**, on a fresh project and
with the gates attacked rather than merely exercised. Sixteen more findings, and
again not one of them catchable by reading or by `make verify` as it then stood.
Two defeated a gate outright: a warm `.ruff_cache` returned a `make check` green
that CI rejected, and the *human* tier-2 review card was dispatched to a lane —
handing the operator's review to the model that had just approved the work.
Those, and the rest, are in
[`docs/ladder-2026-07-28.md`](docs/ladder-2026-07-28.md) with the commands that
produced them; the deliberate bounce, the dependency edge and the CI-red repair
are in [`docs/experiment-2026-07-28.md`](docs/experiment-2026-07-28.md). The
suite is 54 cases now, not because cases are good but because each one is a
defect that got out.

When a run does fail, `hermes kanban runs <task-id>` shows how it ended; a
`crashed` reap means the worker exited without a terminator. That is **not**
automatically a model problem — skill text causes it too. Read the run output
before blaming the model.

## Design commitments (summary — full rationale in ADRs)

| # | Decision | ADR |
|---|----------|-----|
| 1 | Five-layer architecture; methodology strictly separated from harnesses | [0001](docs/adr/0001-layered-architecture.md) |
| 2 | agentskills.io SKILL.md as the portable core; AGENTS.md as project SSOT, CLAUDE.md a thin pointer | [0002](docs/adr/0002-portable-skills-core.md) |
| 3 | Deterministic enforcement lives in the repo (lefthook + CI), never in harness prompts | [0003](docs/adr/0003-enforcement-in-repo.md) |
| 4 | Worker-lane auth: subscriptions everywhere, metering as the justified exception | [0004](docs/adr/0004-worker-lane-auth.md) |
| 5 | Hermes as orchestrator + flywheel; write_approval on; two-cron self-evolution (lane shape superseded by 0006) | [0005](docs/adr/0005-hermes-orchestrator-flywheel.md) |
| 6 | A lane is a Hermes profile, not a program we write | [0006](docs/adr/0006-hermes-native-lanes.md) |
| 7 | Two-tier judging: an unattended filter that can only bounce, then the operator | [0007](docs/adr/0007-two-tier-judge.md) |
| 8 | Code dependencies wait for merged parent PRs; no implicit stacks | [0008](docs/adr/0008-integrated-dependencies.md) |
| 9 | Tier 1 gets a deterministic first stage that blocks before any model runs; the model stage stays, as a control arm under evaluation | [0009](docs/adr/0009-tier-1-gate.md) |

How the substrate actually behaves — the traps, with the commands that exposed
them — is in [docs/hermes-field-notes.md](docs/hermes-field-notes.md). What we
have deliberately not decided yet is in
[docs/open-questions.md](docs/open-questions.md).

## Authoring rules for skills (keep the soul lean)

- Frontmatter: `name` + `description` only (portable core). Descriptions are
  trigger-rich but tight: **≤170 chars**, which is what all eight actually are
  (135–165 as of 2026-07-27). Hermes house style suggests ≤60; no forge skill has
  ever met it, because the description is the only trigger surface a model sees
  and 60 chars cannot carry both the "what" and the "when". If ≤60 is the real
  rule, the skills are wrong and must be rewritten — pick one and let
  `make verify` enforce it. A limit nothing meets is not a rule.
- Bodies have **two** budgets, because one number never fitted both kinds of
  skill, and `make verify` enforces both:
  - **Ceremonies ≤ 150 lines.** The seven are 43–89 and always have been. They
    are read by an interactive operator alongside a whole project's context, so
    every line competes with the work. Long material goes to `rubrics/` or a
    skill-local `references/` dir (progressive disclosure).
  - **`forge-lane` ≤ 300 lines** (283 today). It is not a ceremony: it is the
    entire job of one dedicated unattended profile, so the context argument that
    justifies 150 is at its weakest exactly there — and its length is
    accumulated *measured failures*, not prose. Cutting it means deleting the
    evidence for a defect somebody paid a run to find. The headroom is
    deliberately thin: the next addition should force a decision, not a drift.
- If a rule MUST hold, it does not belong in a skill at all — move it down to
  lefthook/CI (L2). Skills persuade; gates enforce.
- Six sharp skills beat twenty exhaustive ones. Additions go through /retro.

## VERIFY list (known integration unknowns)

Run `make preflight` **on the mini** to burn most of this list down mechanically —
it probes the live CLIs, the running gateway's environment, and headless auth,
and reports PASS/WARN/FAIL. What each burnt-down item actually turned out to be
is in [docs/hermes-field-notes.md](docs/hermes-field-notes.md).


- [x] Exact `hermes kanban` CLI flags & JSON output — burned down by
      `make preflight` §5 on 2026-07-27.
- [x] Hermes skills discovery — skills are PER PROFILE; forge skills are declared
      as `skills.external_dirs`, not symlinked (ADR-0006, preflight §9).
- [ ] Hermes `config.yaml` schema for profiles/cron (`hermes/config-examples.yaml`
      is a commented draft to reconcile against current docs).
- [ ] Claude Code hooks JSON schema in `adapters/claude/.../hooks/hooks.json`.
- [x] Codex non-interactive flags — codex-cli 0.145.0 has NO `--full-auto`;
      the lane uses `-s workspace-write` (`skills/forge-lane/SKILL.md`).
- [x] A real card end to end — burned down 2026-07-28, PR #1 merged.
- [x] The lane's model holds the protocol — `deepseek-v4-flash`, first run.
- [x] GitHub branch protection as the merge gate — active, and it refused a
      merge until `required_approving_review_count` was corrected to 0 (the lane
      pushes as the operator, who cannot approve their own PR).
- [x] The bounce path. Tier 1 rejected deliberate scenario theater, and the
      fix resumed the original PR worktree (`docs/ladder-2026-07-28.md` R3-F4).
- [ ] The Telegram approval flow.
- [ ] Provider terms for automated subscription use, before this runs anywhere
      but the operator's own machine. ADR-0004 settles what *works* headlessly
      (measured); it deliberately does not answer what is *permitted*.

Current status, and what to test next, is in [`docs/state.md`](docs/state.md).
