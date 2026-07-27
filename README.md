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
make verify                     # cli + config + substrate + template
make verify SUITES="cli config" # one or more suites
make verify WITH_CODEX=1        # + sandbox probes (spends tokens)
./scripts/verify.sh --list      # what it checks, without running it
```

| Suite | What it executes |
|---|---|
| `cli/` | every long flag named beside a command in `skills/`, `hermes/`, `docs/` must exist in that command's live `--help`; skill bodies carry no unverified-claim markers; descriptions fit the budget |
| `config/` | timeout, consent gate, external dirs and skill scoping, read **per profile** — not from the gateway's profile, which no worker uses |
| `substrate/` | behaviour we depend on and do not control: worktree ownership, `.git`-is-a-file, the codex sandbox commit |
| `template/` | stamp → `make setup` → hooks really installed → `make check` green |

Run it in CI, after every `hermes update`, and after every `codex`/`claude`
upgrade. A tool version bump that changes a flag or a sandbox rule should fail a
check, not a night run. When it disagrees with this README, **it is right and
the prose is stale** — that is the whole point of having it.

## Day-one risk burn-down: the hello-chunk test

**This is the next thing to do, and nothing has been dispatched yet.** What is
verified is what `make verify` executes — run it, and read its output rather
than this sentence. Everything outside that suite is a claim, including the big
one: that a real card flows end to end. Run the deliberately tiny path before
trusting the lane with real work:

```bash
make preflight                      # must be FAIL 0 before anything is dispatched
make new NAME=hello-forge           # then push it to GitHub
cd ../hello-forge
../forge/hermes/board-bootstrap.sh forge-hello --hello
hermes kanban --board forge-hello watch
hermes kanban --board forge-hello tail <task-id>    # live worker output
```

Pass means the whole chain: claim → worktree → `codex exec` → `make check` green
→ push → PR → `kanban_complete` with metadata → prejudge card appears.

Everything that can break — board flag placement, worktree lifecycle, the codex
sandbox, gh auth, the lane model holding the protocol, metadata plumbing — breaks
here, cheaply. When it does, `hermes kanban runs <task-id>` shows how the run
ended; a `crashed` reap means the worker exited without a terminator. That is
**not** automatically a model problem: skill text causes it too — a lane told to
run a command that cannot succeed dies with no terminator and ticks the failure
counter, which is exactly what the worktree-creation fallback did before F2
removed it. Read the run output before blaming the model
(see `docs/open-questions.md`).

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
- Bodies stay well under ~150 lines; long material goes to `rubrics/` or a
  skill-local `references/` dir (progressive disclosure).
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
- [ ] Provider terms for automated subscription use, before this runs anywhere
      but the operator's own machine. ADR-0004 settles what *works* headlessly
      (measured); it deliberately does not answer what is *permitted*.
