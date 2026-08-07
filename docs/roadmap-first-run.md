# Roadmap — the first genuine product run

**Status: proposal, uncommitted.** Reviewed against `docs/state.md`,
`docs/audit-forgeboard-2026-07-30.md` (F1–F78), `docs/open-questions.md`,
`skills/roadmap`, `hermes/board-bootstrap.sh`, `skills/forge-lane` §4 and a live
`make verify` (133/0/3) on 2026-08-06.

---

## 0. The reframe, and why it changes the plan

The draft is a **build** roadmap with a launch appendix. It should be a **run**
roadmap in which the build is the smallest prerequisite subset.

`docs/state.md` says this in two places and the draft crosses both:

> The next run should introduce **exactly one** new variable.

> Prefer running the smallest real thing over reasoning about the large one.

Ten new chunks — a roadmap validator, a frozen-acceptance gate, a Codex
launcher program, a snapshot primitive, a live metadata sweep, a driver-metrics
joiner, a commissioning gate, and a staged bootstrap mode — are eight or nine
new unknowns standing between here and the run. Every slice in the last two
weeks (F65, F66, F67, F68–F78) produced findings *that were not catchable by
reading*, discovered only after merge. Ten more chunks means ten more of those,
and each one delays the run and contaminates it: when the run misbehaves, the
cause set now includes everything built to prepare for it.

So the question every item below has to answer is not "is this a good idea?" —
most of them are — but **"without this, does the run produce no evidence, or
destroy something?"** If neither, it goes after the run.

### What the run must produce (work backwards from here)

| | Evidence | Closes | Needs built first |
|---|---|---|---|
| E1 | Canonical `forge.chunk.v1` on real cards, and a consumer that reads them | F1, F2, F44 | the live sweep (B2) |
| E2 | Every model-authored block reason inside the registry regex | F26 | the live sweep (B2) |
| E3 | ADR-0008's corrected parent-**merged** path, proven live on a fresh graph | state.md gap 2 | nothing |
| E4 | ≥10 gate-cleared reviews carrying `derived_verdict` | unblocks ADR-0011 → S6, bounce budget, scorer decision | nothing |
| E5 | `/retro` produces a `--markdown-row` for a genuine product run, and it lands in `retro-metrics.md` | state.md "the flywheel" | nothing (smoke-tested in D2) |
| E6 | Metered driver cost, or a recorded substrate limitation | F48 | the spike (D2) |
| E7 | Operator touches per merged chunk | F31 | nothing (metrics.sh emits it) |
| E8 | Chunk sizes and bounce counts under the new planning rules | F11, F28, F53 | the planning gates (C) |
| E9 | Wasted dispatches on the dependency edge, counted | F10, F52 | nothing |

E3, E4, E5, E7 and E9 need **no new machinery at all**. That is the single
biggest correction to the draft: five of the nine evidence items are already
purchasable today, and the draft blocks all of them behind ten chunks.

---

## 1. Verdict on the draft

### What is right, and should survive unchanged

- **The staged launch is the best idea in the document.** Root-only bootstrap →
  merge → validate → full bootstrap is exactly "one new variable at a time"
  applied to a board. It also works with the existing script for a reason worth
  writing down: `create_card` is idempotent on `--idempotency-key "$BOARD-$id"`
  and returns the existing id, so the second, full invocation re-maps CHUNK-1
  rather than duplicating it.
- **Abandoning forgeboard** rather than migrating it. Correct, and it makes ~12
  findings moot — see §4's disposition table.
- **Scoping the run so its evidence is provable rather than archaeological.**
  The draft did this with a timestamp; §3 now does it with a **new, empty
  board**, which is stronger and which `scripts/metrics.sh` can actually honour
  (it takes only `YYYY-MM-DD`, local). The instinct was right; the mechanism
  moved.
- **Refusing to invent driver-cost fields** in `forge.chunk.v1`. Matches F48's
  own fix ordering and `state.md` item 4.
- **Deferring S6, bounce budgets and any scorer change** until ADR-0011.
  `open-questions.md` pre-commits the decision rule; do not touch it.
- **Dry-run-by-default worktree sweep with non-forced branch deletion.**

### Five structural problems

**P1 — The plan violates its own size budget, which is F28 happening to the
chunk that fixes F28.** CHUNK-2 (a validator with six rule families plus
fixtures plus verify cases), CHUNK-4 (a launcher script enforcing six flags with
argv-exact fake-Codex tests) and CHUNK-9 (commissioning) each land well past
"~400 lines and six files". For calibration, the comparable existing artifacts
are `lane-blast-radius.sh` 363 lines, `prejudge-review.sh` 443, `prejudge.sh`
537 — and every one of those chunks must also add cases to `verify.sh`, which is
already 2,421 lines. Counting `Makefile` + `verify.sh` + one doc, three of the
six file slots are gone before any real work.

**P2 — The dependency graph is a chain, and most of its edges are false.**
`CHUNK-2 depends on CHUNK-1` (roadmap validation has nothing to do with durable
project paths), `CHUNK-4 depends on CHUNK-1` (same), `CHUNK-9 depends on
CHUNK-1..8`. The true structure is five independent tracks. A spurious edge is
not free: F10 measured what the board does with one, and a serialised plan
defers every item behind whichever chunk bounces.

**P3 — CHUNK-4 changes the most load-bearing proven artifact in the repo,
immediately before the run.** `state.md` explicitly names §4 as "the identified
next lever" *and* says it "is a different unknown (how Codex is launched) and
belongs in its own slice". The lane was sliced, bounced twice, and live-validated
five days ago (`verify-codex-1786010605-22305`). Re-cutting its Codex invocation
in the week before the first genuine run is the two-unknowns error.

Also, the stated justification is currently false. Measured just now:

```
~/.codex/config.toml : model = "gpt-5.6-sol", model_reasoning_effort = "xhigh"
forge-lane §4        : "gpt-5.6-sol, reasoning xhigh"
docs/state.md        : "codex pinned gpt-5.6-sol xhigh"
```

All three **agree today**. F22/F36's staleness self-corrected when the pin was
changed back (F39). The real defect is that nothing *enforces* the agreement, and
that is a ~10-line verify case — not a launcher program. Take the 10 lines now
(D1b); take the program after the run. Put it in the **`cli`** group, not
`config`: see D1b's note on why an offline assertion in `config` never runs in CI.

One flag check the draft would have needed anyway: `codex exec` has no
reasoning-effort flag. It has `-m/--model`, `-c key=value` config overrides,
`--strict-config`, and `-p/--profile` which layers **`$CODEX_HOME/<name>.config.toml`**
— i.e. not a repo file. A repo-versioned runtime pin therefore has to be
translated into explicit `-c` overrides; pointing `CODEX_HOME` at the repo would
take `auth.json` with it and break the OAuth path ADR-0004 depends on. Worth
knowing before that chunk is written rather than during it.

**P4 — CHUNK-7 presumes the answer to a question nobody has asked yet.** It
specifies joining Hermes profile `state.db` sessions to runs "by profile,
workspace and start time". `state.md` item 4 and F48's own fix say the opposite
ordering: *establish what Hermes exposes* first, and if it exposes nothing,
record a substrate limitation in `hermes-field-notes.md` and use a wall-clock /
tool-call proxy. Written as an implementation chunk, this either ships a
speculative joiner or bounces on discovery. Written as a spike, it costs an hour
and its output decides whether a chunk exists at all.

**P5 — Two things that block execution are missing entirely.**

- **`./hermes/profiles-bootstrap.sh` after merge.** F60: a SOUL edit
  desynchronises the live profile, `config/soul-in-sync` reddens on the branch,
  and the fix is a post-merge republish. Any chunk touching
  `hermes/profiles/*.SOUL.md` — CHUNK-4 and CHUNK-8 in the draft — needs this in
  its done-when. The draft never mentions the script.
- **`make preflight` after every merge**, per `CLAUDE.md`, and the knowledge
  that a *red* preflight on a branch adding a lane-critical script is **correct**
  (`~/.forge/repo` is the main checkout; it clears on merge). Without that stated,
  the first chunk to add a script will be treated as broken.

Related: the draft's "remove the empty Anthropic/OpenAI key lines so the money
invariant is warning-free" is chasing green. `state.md` records `PASS 82 / WARN 3
/ FAIL 0` as the healthy baseline. Reconcile against that number; do not
suppress a warning to reach zero.

### Two smaller corrections

- **The ledger's status headers are stale and cannot be planned against.**
  F7's header says `OPEN`; its body says **FIXED 2026-08-05**. F27's says `OPEN`;
  S1 shipped it. F29's header says `FIXED`, F2/F26 say `OPEN` over bodies
  recording a shipped contract. The draft's per-chunk `Serves:` lines inherit
  that ambiguity. Reconcile the headers *before* the roadmap is signed — §4 is a
  first pass.
- **`board-bootstrap.sh --root-only` needs one more assertion than the draft
  gives it.** Full mode ends with `[ "$created" = "$declared" ]` and a FATAL. In
  root-only mode zero parents are attached against a non-zero `declared`, so that
  guard must be scoped, not deleted — and the mode must additionally verify the
  graph has exactly one root and that every chunk is reachable from it, *before*
  it mutates anything.

---

## 2. The refined roadmap

Five tracks. **D1a goes first, alone. Then A, B and C run in parallel; E waits.**

*Corrected 2026-08-07. The draft said "A, B, C, D run in parallel" and, four
lines later, that "F-numbers for new findings are allocated in D1 before any
track starts". Both cannot hold: D1 owns the allocation table every other track
mints from. In practice D1's ledger half was split out and shipped first as
**D1a** (PR #25), and A/B/C were branched before it — which is exactly how #26,
#27 and #28 each ended up naming F-numbers only in their PR bodies, with no
allocation table in their base. The rule that survives: **the allocator lands
before anything that spends a number.***

Every chunk's done-when implicitly includes: `make verify` green, `make validate`
green, worktree tracked-clean, its own negative/mutation test, and — **after
merge to main** — `make verify` **and** `make preflight`, plus
`./hermes/profiles-bootstrap.sh` if a SOUL changed. Every chunk runs in its own
worktree (F40). F-numbers for new findings are allocated in **D1a, which lands before any
other track starts**, so two slices cannot mint the same number again (F40's
second symptom).

### Track A — the artifact survives

#### A1 · Durable destinations and a safe worktree sweep
- **Serves:** F19, F18 · **ADRs:** 0003, 0008 · **Risk:** low
- **Goal:** the product cannot be stamped somewhere macOS purges, and finished
  chunks stop holding 50 MB and a branch each.
- **Touches:** `Makefile`, one lifecycle script, `verify.sh`, `docs/operator-guide.md`
- **Scenarios:**
  - Given `DEST` resolves under `/tmp`, `/private/tmp` or the active `$TMPDIR`,
    When `make new` runs, Then it refuses and names a durable location.
  - Given a relative or non-absolute `DEST`, When `make new` runs, Then it
    refuses (today it defaults to `..`, relative to whatever CWD the operator
    happened to be in — which is how the first product landed in `/private/tmp`).
  - Given a merged PR and a clean worktree, When `make worktree-sweep` runs with
    no `APPLY`, Then it prints what it would remove and changes nothing.
  - Given `APPLY=1` and a worktree whose branch is unmerged or whose tree is
    dirty, Then it is refused and named.
  - Given `APPLY=1` and a clean worktree on a merged branch, Then
    `git worktree remove` runs, `git branch -d` (never `-D`) runs, and the
    `.venv` and `.forge/uv-cache` go with it.
- **Not in scope:** recovering forgeboard; removing worktrees outside
  `<repo>/.worktrees/`.
- **Note for the implementer:** `gh pr merge --delete-branch` fails while a
  worktree holds the branch (measured, PR #1), so sweep runs *after* merge and
  must tolerate a remote branch that is already gone.

### Track B — the instrument (B1 → B2)

#### B1 · One fail-closed WAL snapshot primitive
- **Serves:** F47, F51, F67 · **ADRs:** 0003 · **Risk:** low-medium
- **Goal:** every reader of a live board gets identical WAL-safe behaviour, from
  one implementation instead of three.
- **Touches:** new `scripts/board-snapshot.sh`, `scripts/metrics.sh`,
  `verify.sh`, `docs/operator-guide.md`
- **Scenarios:**
  - Given a WAL board with no `-shm`/`-wal` sidecars, When snapshotted, Then it
    reads (this is F67's exact failure: `mode=ro` fails when the board is *idle*).
  - Given a board being written during the copy, When the pre/post fingerprints
    differ, Then it retries three times and then **fails**, never returning a
    partial success.
  - Given an unreadable input, Then exit is non-zero and stdout is empty — F47's
    second half was a silent empty result at exit 0, because `sqlite3` writes its
    error to *stdout*.
  - Given any invocation, Then the source database and its sidecars are
    byte-identical afterwards.
- **Not in scope:** adding live-board checks to the default `make verify` (F67 is
  why any live sweep is explicit and opt-in).
- **This is an extraction, not an invention.** The behaviour already exists
  correctly in `metrics.sh` and in `verify.sh`'s live-schema check; the defect is
  that it exists twice and drifted once already.

#### B2 · `make metadata-live BOARD=<slug> SINCE=<ts>`
- **Serves:** F1, F2, F26, F44 · **ADRs:** 0003, 0009 · **Depends on:** B1 · **Risk:** medium
- **Goal:** make the producer contract provable on reality instead of on fixtures.
  This is the instrument E1 and E2 are read from, and `state.md` item 3 names it.
- **Touches:** new sweep script, `scripts/validate-metadata.py` (a batch entry
  point — today it takes one envelope and `--profile`), `Makefile`, `verify.sh`,
  `rubrics/kanban-metadata-schema.md`
- **Scenarios:**
  - Given no `SINCE`, Then the command refuses — an unscoped sweep silently reads
    the historical nested envelopes and reports a contract breach that predates
    the contract.
  - Given a post-cutoff completed run per contracted profile, When each is
    validated against `run-metadata-contract.json`, Then all pass.
  - Given a nested envelope, a null field, or a profile emitting a schema it is
    not contracted to emit, Then each fails and is named.
  - Given a blocked event whose reason falls outside `blocked_reason_pattern`,
    Then it fails and the reason is printed.
  - Given rows before `SINCE`, Then they are ignored and counted separately.
- **Output contract:** explicit `valid / invalid / unjudged` counts. `unjudged`
  is not `valid` — `validate-metadata.py` already separates exit 1 (wrong) from
  exit 2 (unreadable) for exactly this reason, and the sweep must preserve it.

### Track C — planning-time gates (C1 → C2)

Both of these move a check from review time to plan time, which is F53's
central ruling: *"F28 and F25 are planning defects being surfaced at review
time, and review time is the most expensive place to learn that a planner wrote
a 3,700-line chunk."*

**Both ship warn-first, and C1 stays advisory through this run.** F53's other
half is that a gate blocking 11 of 11 PRs is not a filter either. Procedure:
build the check, run it against the real product roadmap, and iterate *the
roadmap* until it passes. Loosening a threshold after seeing the data is the move
F53 explicitly forbids; fixing the plan is not.

**Decided 2026-08-07: there is no flip to blocking before this run.** The draft
said to "flip the severity to blocking — before bootstrap, and recorded", and
ADR-0012 D12.5 claims the severity map "is a single table at the top of the
script so that each flip is one line, deliberately taken". Neither is true of
what shipped: the map is prose inside a header comment, the severity is a
literal word at each of twenty-one `emit` call sites, and the script has no exit
path other than `exit 0` and `exit 2`. Editing the comment table changes nothing,
so an operator following the draft would have made a no-op change and believed
the gate had flipped.

Building a real strict mode is a chunk's worth of work and a new failure mode in
the week before the run — the two-unknowns error again. So: **C1 warns, this run
measures whether a warning is enough, and F11/F28/F53 stay open through the
run.** The prediction in §3 is what tests it: if the plan was genuinely fixed at
step 10, `prejudge`'s `size-budget` warns on none. A warning nobody acts on is
its own finding, and a cheaper one to learn than a gate that blocks everything.

**ADR-0012 must be corrected in the same PR that ships this**, because the ADR is
what a future editor reads. It should say what the code does — advisory, with
severity at the call sites — and record the flip as deferred, not as one line
away.

#### C1 · `make roadmap-check PROJECT=<abs-path>`
- **Serves:** F11, F12, F28, F53 · **ADRs:** 0003, 0008, new ADR-0012 · **Risk:** medium
- **Goal:** reject an oversized or internally inconsistent plan before a board
  exists and before any model is spawned.
- **Touches:** new validator, `Makefile`, `skills/roadmap/SKILL.md`, `verify.sh`,
  ADR-0012
- **Scenarios:**
  - Given `graph.json` and `docs/chunks/*.md`, Then the id sets are bijective and
    the graph is acyclic.
  - Given the graph, Then exactly one root exists and every chunk is reachable
    from it (this is also what `--root-only` in E1 depends on).
  - Given a chunk spec, Then `Serves:` names ≤4 requirements, `Touches` names ≤6
    non-process paths, and `Scenarios:` has ≤5 entries each containing exactly
    one Given/When/Then.
  - Given a `Lane:` that is neither `claude-interactive` nor a live Hermes
    assignee, Then it fails — an unknown assignee strands the card in `ready`,
    silently, for half an hour.
  - Given a missing required contract field, Then it fails and names the field.
- **Not in scope:** predicting final line count; judging whether the requirements
  are any good.
- **Process-doc exclusion is load-bearing.** F55 counted the drift: three of the
  five drifting paths were `docs/decision-log.md`, `docs/ROADMAP.md` and
  `docs/chunks/*` — files every chunk must edit and no contract may declare.
  Counting them manufactures a finding on every PR.
- **Deliberately deferred to after the run:** demoting `ROADMAP.md` to a
  generated summary. It is a nice consolidation and it is not a precondition.

#### C2 · Freeze acceptance scenarios at planning time
- **Serves:** F14, F25, F53 · **ADRs:** 0003, 0012 · **Depends on:** C1 · **Risk:** high
- **Goal:** stop the implementer authoring and grading its own acceptance
  criteria. F25 calls this "the single highest-value change in this document".
- **Touches:** `skills/roadmap/SKILL.md`, `scripts/prejudge.sh`,
  `skills/judge/SKILL.md`, template `AGENTS.md`, `verify.sh`
- **Scenarios:**
  - Given a chunk spec, Then it names an existing `tests/features/*.feature`
    file and its scenario titles match the contract's.
  - Given a chunk whose contract names an external source, Then the feature file
    carries at least one `@real-source` scenario.
  - Given an implementation PR that modifies a frozen feature file, Then the gate
    blocks.
  - Given an implementation PR that adds step definitions for those scenarios,
    Then it passes — implementing a step is the job.
- **Not in scope:** mutation testing; semantic judgment of step bodies.
- **Name the freeze mechanism explicitly.** "Signed" is not a mechanism. Use a
  hash manifest committed by the planning PR — forgeboard's own
  `contract-freeze.json` is the precedent the audit's §G says should be
  "promoted into the Forge proper". Then the gate compares hashes, not prose.
- **Budget for the escape hatch, because it will be used.** F8/F55 proved a plan
  written before the code is wrong about paths; the same will be true of scenario
  details. Amendment goes through a human planning PR on main; the run's evidence
  must record how many times that happened, because that count is the honest
  measure of whether planning-time freezing is affordable.
- **Highest-uncertainty item in this roadmap.** `/roadmap` currently emits
  Given/When/Then *one-liners* that "BECOME the .feature file" — the implementer
  writes the Gherkin. Making the planner emit feature files that parse under
  pytest-bdd against steps that do not exist yet is a larger change than
  "commit the file". If this bounces twice, ship C1 alone and run without C2,
  recording that F14/F25 stay open for the run. C1 without C2 is still worth the
  run; C2 half-built is not.

### Track D — cheap hygiene and one spike (one PR each, all independent)

**D1 is split, because as drafted it broke C1's own rule.** Its `Serves:` line
named five requirements against the `≤ 4` limit C1 exists to enforce, it carried
six unrelated work items, and it had no `Touches:` and no `Scenarios:` at all —
F28 happening to the chunk that fixes F28, which §1's P1 warns about. It is now
two chunks, each inside the rule:

#### D1a · Ledger reconciliation and the F-number allocator *(shipped as PR #25)*
- **Serves:** F40 · **ADRs:** 0002 · **Risk:** low
- **Touches:** `docs/audit-forgeboard-2026-07-30.md`, `docs/state.md`, `CLAUDE.md`, `Makefile`
- Bring every `### F<n>` status header into agreement with its body, and add a
  disposition row for each (see §4). **This lands before any other track**, because
  the rest of the roadmap cites F-numbers.
- Reserve an F-number block per track in the ledger, so two worktrees cannot mint
  the same number (F40's second symptom did exactly that).

#### D1b · Deterministic hygiene sweep
- **Serves:** F34, F36, F55, F57 · **ADRs:** 0003, 0010 · **Risk:** low
- **Touches:** `scripts/verify.sh`, `hermes/profiles-bootstrap.sh`, `docs/state.md`, `docs/open-questions.md`
- `config/codex-pin-agrees`: the live `~/.codex/config.toml` pin, `forge-lane`
  §4's prose, and `docs/state.md` must agree, or the suite fails. ~10 lines,
  closes F36 without touching §4's invocation.
- ~~The *driver* half of the same idea.~~ **Shipped 2026-08-07 (PR #29)** ahead
  of this chunk, because it stopped being hypothetical: `MODEL_DRIVER` spent a
  day reading `deepseek-v4-flash-latest-latest` — an id that resolves nowhere,
  one `./hermes/profiles-bootstrap.sh` away from every unattended run — with
  every check in this repo green. `cli/model-pin-documented` (offline, in CI) and
  `config/model-pin-live/<profile>` now hold it. The lesson for the Codex half
  above: **put the offline assertion in `cli`, not `config`.** `config` returns
  early without `hermes` and is not in CI's suite list, so an offline check
  placed there would only ever run on the operator's machine.
- `cli/skill-section-references-resolve`: every `<skill> §<n>` reference resolves
  to a heading that exists. F34's cross-reference — the one whose whole purpose
  was preventing drift — is itself wrong today (`end-chunk` §4 points at
  `forge-lane` §5 for the PR step; the PR step is §6).
- `touches` reports **widening**: compare base and head contracts and report the
  self-amendment rather than passing on it (F57), with process docs excluded
  (F55). Stays advisory.
- **Decide the `skill_manage` question** — but measure before asserting. The
  draft states as fact that "v0.19 cannot disable only `skill_manage`";
  `open-questions.md` states the opposite, that `hermes tools disable
  skill_manage` per lane profile is "one line of work". One of the two is wrong.
  Run the command, then write the ADR around what happened.

#### D2 · Spike: what can the metered driver actually see? *(timeboxed, ~1h, no PR required)*
- **Serves:** F48, F31 · **Risk:** low
- **Goal:** answer, with commands, whether Hermes exposes per-run usage at all —
  `task_runs` has no usage column (measured in F48), so the question is whether
  any other route does.
- **Output:** a paragraph in `docs/hermes-field-notes.md` recording what exists.
  If a route exists, a chunk follows. **If none exists, that is a finding, not a
  failure** — record the substrate limitation and put a wall-clock/tool-call
  proxy in the run's evidence plan. F48's own fix text prescribes exactly this.
- Rehearse `/retro` here too, against an existing board (`forge-ladder`). It has
  **never executed**. Discovering that during the product run's retro is the
  worst possible time; discovering it now costs nothing.

  **This makes E5's wording wrong, and E5 is the one that gets corrected.** E5
  said "`/retro` executes for the first time" *during the run*; if D2 rehearses
  it first, that is false. Keep the rehearsal — finding out that `/retro` is
  broken during the product run's retro is the expensive order — and read E5 as
  **the first execution that produces a real `--markdown-row` for a genuine
  product run**. The rehearsal against `forge-ladder` is a smoke test whose
  output is thrown away.

### Track E — the staged launch

#### E1 · `--root-only` and the launch sequence
- **Serves:** ADR-0008 re-proof, E1/E2/E3 above · **Depends on:** A1, B2, C1 (C2 if it ships) · **Risk:** medium
- **Touches:** `hermes/board-bootstrap.sh`, new `scripts/commission.sh`,
  `Makefile`, `verify.sh`, `docs/operator-guide.md`, `docs/state.md`
- **Scenarios:**
  - Given a graph with exactly one root, When `board-bootstrap.sh <board>
    --root-only` runs, Then only that card is created.
  - Given a graph with zero or multiple roots, or an unreachable chunk, Then it
    fails **before creating any card**.
  - Given a prior `--root-only` run, When the full invocation runs, Then the root
    is re-mapped via its idempotency key rather than duplicated, and the
    remaining cards attach the correct parents.
  - Given `--root-only`, Then the trailing `created == declared` parent assertion
    is scoped to the created set rather than tripping on the full graph.
  - Given any check `make commission` runs exits non-zero, Then the evidence
    report records **which** check failed and `make commission` exits non-zero —
    a commissioning gate that reports success on a partial run is worse than no
    gate, because it is the last thing read before money is spent.
- **`make commission` is deliberately thin.** Not a new gate — a script that runs
  the checks that already exist (`make verify WITH_CODEX=1`, `make preflight`,
  `make roadmap-check`, durable-path and clean-tree checks, remote and branch
  protection present) and writes a timestamped evidence report. It adds no new
  decision logic, so it cannot fail in a new way. The draft's version depends on
  CHUNK-1..8 and is marked high risk; a wrapper depends on nothing and is
  low risk. Document it as **paid** (it runs `WITH_CODEX=1`) and non-mutating.

---

## 3. The run itself

```
 1.  record RUN_START (UTC) in the log — but see "scoping" below: the run is
     scoped by using a NEW, EMPTY board, not by a timestamp
 2.  make new NAME=<product> DEST=<durable>          # A1 refuses a temp path
 3.  cd <durable>/<product>                          # EVERY step below is in the product
 4.  git init -b main && make setup && make check
 5.  git add -A && git commit -m "chunk 0: stamped from templates/python-service"
 6.  gh repo create <product> --private --source=. --remote=origin --push
 7.  gh repo view --json nameWithOwner       # the remote resolves, or protect cannot run
 8.  make protect                            # requires the repo created in step 6
 9.  /scope → /architect → /roadmap                  # planning PRs on main
10.  make roadmap-check PROJECT=<abs>         # ADVISORY. Fix the PLAN until clean.
11.  make commission PROJECT=<abs> BOARD=<slug>      # paid; evidence report
12.  ./hermes/board-bootstrap.sh <slug> --root-only
13.  … the root chunk runs unattended: lane → PR → prejudge → tier 2 → merge …
14.  make metadata-live BOARD=<slug>                 # <- THE CHECKPOINT. It can say stop.
     make metrics BOARD=<slug>                       # E7, E9
15.  ./hermes/board-bootstrap.sh <slug>              # the rest of the graph
16.  … the remaining chunks run; wait for the graph to complete …
17.  make metadata-live BOARD=<slug>                 # final sweep — E1, E2
     make metrics BOARD=<slug>                       # final numbers — E7, E9
18.  /retro                                          # E5 — its first execution ever
19.  append /retro's --markdown-row output to docs/retro-metrics.md
20.  compare against the three predictions below; record each as held or
     falsified, with the number that decided it
21.  reconcile docs/state.md and the audit ledger with what the run showed —
     F1/F2/F44 and F26 close only if E1 and E2 came back clean
```

**Steps 3–8 are separate lines on purpose.** The draft compressed them into one
that could not run. It never changed directory, so `make setup`, `make check` and
`make protect` would have executed against the Forge's own root `Makefile`, which
has none of those targets. And it called `make protect` before any GitHub repo
existed, where the template's own target exits with `no GitHub repo yet — 'gh
repo create' first`. `README.md` already carries the working sequence; this is it,
expanded and checked against the template's `Makefile`.

**Scoping: a new empty board, not a timestamp.** The draft promised "RUN_START
(UTC, to the second)" and then scoped the live checks with
`make metrics SINCE=…`. `scripts/metrics.sh` accepts only `YYYY-MM-DD`, rejects
anything else with exit 2, and converts that date to **local** midnight — so
second-level UTC scoping was never available from that command. A fresh board is
stronger than any cutoff anyway: there are no pre-run rows to exclude, so no
filter can be wrong. Record `RUN_START` for the narrative and pass no `SINCE`.

**Step 14 is the checkpoint, and it can say stop.** Its pass condition: the root
card carries canonical `forge.chunk.v1`; a consumer read it; the review path
completed with a stored `derived_verdict`; every block reason matched the
registry; the PR merged. Anything red there is repaired before step 15 — that is
the entire point of staging.

**Steps 16–21 are the half the draft was missing.** It ended at "bootstrap the
rest of the graph", which produces E3 and nothing else. Six of the nine evidence
items — E1, E2, E4, E5, E7, E9 — are only *collected* after the graph completes,
and `/retro` executing for the first time is itself one of them. A run that stops
at step 15 has spent the money and bought one result.

**Predictions to record before the run, so they can be falsified:**

- The dependency edge will still burn one wasted dispatch per chunk 2..N (F10 is
  a *dispatcher* defect and F52 proved a PR-time gate is structurally incapable of
  catching it). Count them. That count is the case for or against the scheduler.
- `prejudge`'s block rate should collapse versus the audited run: four of its
  eight blocks were `branch-name`, now enforced at push and in CI by the template
  (F7 fixed). If it still blocks on branch names, the template fix did not reach
  the new project.
- `size-budget` warned on 11 of 11 last time. C1 runs at plan time and **warns**;
  step 10 fixes the plan until it is clean. So `prejudge`'s `size-budget` should
  warn on none. If it still warns, the plan was not actually fixed — C1 was
  written and not obeyed. This is the one prediction C1 can falsify while
  remaining advisory, which is why advisory is enough for this run.

**Do not run the second unknown.** Timeout/reclaim and circuit-breaker recovery
stay off the table until this run is finished and read.

---

## 4. Ledger disposition — do this first

The headers cannot currently be planned against. First pass, from reading the
bodies; D1a makes it authoritative.

| Disposition | Findings |
|---|---|
| **Fixed / resolved** (header agrees) | F29, F42, F43, F45, F47, F49, F50, F51, F56, F64–F78 |
| **Fixed, header says OPEN** | F7 (2026-08-05), F27 (S1/PR #3), F30 (S2), F35 (ADR-0009/0010), F37 (S2), F3 (partly — metric 0 exists) |
| **Contracted, awaiting live proof** — the run closes these | F1, F2, F26, F44 |
| **Blocking the run — this roadmap** | F11, F14, F18, F19, F25, F28, F34, F36, F53, F55, F57 |
| **Blocked on ADR-0011 data** — the run supplies it | F4, F6, F15, F20, F21, F32, F33, F38, F58 |
| **Deferred, post-run** | F46, F52, F62, F63, F5 |
| **Read by the run, fixed after it** | F31 (E7 counts operator touches), F48 (D2's spike answers whether the substrate can report cost at all, and E6 records the answer) |
| **Moot with forgeboard abandoned** | F9, F12, F13, F17, F23, F24, F54, F59 (product-specific evidence only; the *methodology* halves are already carried by F11/F14/F25/F53) |

Two of these deserve a sentence rather than a row:

- **F52 is a real constraint on the run, not an item to fix.** `parents-merged`
  cannot work at PR time by construction. Accept the wasted dispatches, count
  them (E9), and let that number decide the scheduler afterwards.
- **"Deferred, post-run" and "the run supplies evidence for it" are different
  things, and the draft put F31 and F48 in the wrong one.** Both were listed as
  deferred while also being evidence items (E7 and E6) that the run produces
  — a contradiction a reader has to resolve by guessing. They now have their own
  row: nothing is *built* for them before the run, and the run *reads* them.
- **F31 (operator touches) needs no code.** `scripts/metrics.sh` already emits it
  (11 = 2 comments + 9 unblocks on the audited board). It needs a column in
  `retro-metrics.md`, which is one line in D1b if you want it before the run.

---

## 5. What moved, and why

| Draft | Here | Reason |
|---|---|---|
| CHUNK-1 | **A1**, unchanged in substance | correct as written |
| CHUNK-2 | **C1**, warn-first, no `ROADMAP.md` restructure | F53: a gate that blocks everything is not a filter; the restructure is not a precondition |
| CHUNK-3 | **C2**, freeze mechanism named, escape hatch budgeted, drop-if-it-bounces rule | highest value **and** highest uncertainty; needs a stated failure mode |
| CHUNK-4 | **split** — 10-line pin check in D1b now; launcher program **after the run** | P3: two unknowns, and the pin is not currently stale |
| CHUNK-5 | **B1**, unchanged | correct; it is an extraction, not an invention |
| CHUNK-6 | **B2**, `unjudged ≠ valid` made explicit | correct; the validator already distinguishes exits 1 and 2 |
| CHUNK-7 | **D2**, a spike producing a field note | P4: it presumed the discovery result |
| CHUNK-8 | **D1a + D1b** — the ledger/allocator half lands first and alone | correct; measure the `skill_manage` claim before the ADR asserts it. Split because one chunk named 5 requirements against C1's own limit of 4 |
| CHUNK-9 | **E1's thin wrapper**, no dependency chain | P1/P2: a gate over existing gates that can fail in new ways is negative value |
| CHUNK-10 | **E1**, plus the scoped parent assertion and single-root check | correct idea, one real implementation gap |
| — | **the run's evidence plan and its predictions** | the draft had no falsifiable output; five of nine evidence items needed nothing built |
| — | **post-merge `preflight` + `profiles-bootstrap.sh` per chunk** | F60/F66: this is how a check goes blind at the merge that moved it |
