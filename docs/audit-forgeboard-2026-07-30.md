# Audit — the Forge, as measured by the `forgeboard-report` run (2026-07-30)

**Subject: the methodology, not the product.** `wielas/forgeboard-report` is the
first genuine idea driven through the whole Forge lifecycle — the exact test
`docs/state.md` names as gap #1 ("A genuine idea through the full lifecycle").
This file audits what that run reveals about the Forge.

**Where things are:** repo at `/private/tmp/forgeboard-report` (NOT in `~/dev`;
local `main` is 41 commits behind `origin`). Board `forge-ladder`, live db at
`~/.hermes/kanban/boards/forge-ladder/kanban.db`. Hand-assembled review prompts
and verdicts are loose in `/private/tmp/*.json|txt|md`.

Status legend, as actually used below — the original three-word legend had
drifted from the headers it describes, so this is the vocabulary reconciled
against the file rather than the one it was opened with:

| Status | Means |
|---|---|
| `OPEN` | no fix has shipped |
| `PARTLY FIXED <date>` | one half of the finding's own fix shipped; the body names which half and what is left |
| `FIXED <date>` / `RESOLVED <date>` | the fix is in the tree and something executes it |
| `CONTRACTED — AWAITING LIVE PROOF` | the fix shipped and is fixture-proven; one genuine lifecycle run must show it holds on reality |
| `RESOLVED-BY-DECISION <date>` | the finding asked a question; data answered it and the answer is implemented |
| `RESOLVED-BY-RECORD` | nothing to fix; the finding exists so the event is on the record |
| `MEASURED` / `RECORDED` | an observation, not a defect with a fix |
| `WONTFIX` / `NEEDS-DECISION` | reserved; unused today |

---

## Disposition — what is done, what waits, what was dropped

*Reconciled 2026-08-06 (slice D1a). Before this pass the `### F<n>` headers had
drifted from their own bodies. F7's header read `OPEN` over a body that records
**FIXED 2026-08-05**; twenty headers in total disagreed with their body, with
the tree, or with both, which is why nothing downstream could be planned against
them.*

**The body is the evidence and the header is the bug — but a body is a claim,
not a proof.** Every promotion below was checked against the tree before it was
made, so the "why" column names the file, the verify case or the slice that
executes it. Findings whose bodies proposed a fix that has **not** shipped kept
their `OPEN` header regardless of how confident the prose around them sounds.

**Nothing here is marked fixed on a body's word alone.** Every body that claimed
a fix turned out to have one in the tree; there is no claimed-but-unverifiable
row. Two bodies claimed *more* than the tree supports and were demoted rather
than promoted — F35 (the gate shipped, the scorer it wanted deleted did not) and
F3 (the metric split shipped, the producer gate is fixture-proven only). Both
now read `PARTLY FIXED`.

Exactly one bucket per finding. `docs/roadmap-first-run.md` §4 — the first-run
roadmap, which is what the "Track" column below refers to; it is on
`slice/run-roadmap` at the time of writing — carries a first pass of this table.
Where the two disagree, this one is the one that was checked against the tree,
and the differences are listed under "Where this table corrects the roadmap's
draft" below.

### Fixed — the fix is in the tree and something executes it

| Finding | Status | Why, and what executes it |
|---|---|---|
| F5 | `FIXED 2026-08-04` | ADR-0009's gate: `scripts/prejudge.sh:209` blocks on an empty `statusCheckRollup` after `--wait`; `prejudge/absent-ci-is-not-a-pass`. The SOUL's missing fourth row is moot — the SOUL no longer decides |
| F7 | `FIXED 2026-08-05` | `templates/python-service/template/scripts/branch-name.sh`, called from `lefthook.yml:96` (pre-push) and `.github/workflows/ci.yml:16` (`pull_request`, not skippable); `template/branch-rule-has-one-source`, `template/branch-name-judges-by-argument` |
| F8 | `RESOLVED-BY-DECISION 2026-08-04` | F55 counted the drift and the number chose: `Touches` is advisory. Implemented at `scripts/prejudge.sh:299` (`TOUCHES_EXEMPT`) with `touches` emitting `warn`. The residual — a branch legalising its own drift — is F57, not F8 |
| F27 | `FIXED 2026-07-30` | S1 / PR #3. `scripts/metrics.sh` (23 KB), `make metrics`, the `metrics/` verify group |
| F29 | `FIXED 2026-08-06` | header already agreed. `prejudge-review.sh` routes on `.derived_verdict`; `prejudge/derived-verdict-routes` |
| F30 | `FIXED 2026-07-31` | S2. `prejudge-review.sh:310–332` stamps `tokens_estimate`, `cost` and `session_id` from the harness envelope. Formula refined 2026-08-03 by F45 |
| F37 | `FIXED 2026-07-31` | S2. `prejudge-review.sh:252` redirects `gh pr diff` into the prompt file; `lane/driver-never-reads-the-diff`, `prejudge/review-never-prints-the-diff` (63,164 bytes moved, 2,599 observed) |
| F39 | `RESOLVED-BY-RECORD` | header already agreed. Its live carry-forward hazard (CHUNK-6 resuming under a new pin) died with the product |
| F41 | `FIXED 2026-07-30` | corrected in `docs/retro-metrics.md:306–309`; the audit body is left as written on purpose, so the error stays legible |
| F42, F43, F45, F47, F49, F50, F51, F56 | as headed | headers already agreed with their bodies; re-checked, not changed |
| F55 | `RESOLVED-BY-DECISION 2026-08-04` | the exclusion list is `scripts/prejudge.sh:299`, and it is documented there as methodology-obliged paths rather than a convenience list |
| F61 | `FIXED 2026-08-05` | ADR-0010. `forge-prejudge.SOUL.md` is 56 lines; `cli/soul-body-budget` (60) and `cli/no-programs-in-souls` (6) hold every SOUL |
| F62 | `FIXED 2026-08-05` | the fix F62 prescribes is a number, and both numbers shipped with ADR-0010 — same two cases |
| F63 | `FIXED 2026-08-05` | the eleven `grep -Fq` cases are gone; the `prejudge/` group is four identity assertions plus executions against recorded `gh` responses |
| F64–F78 | as headed | the lane slice and its two review rounds; headers already agreed, re-checked, not changed |

### Contracted, awaiting live proof — the run closes these

*The contract shipped, `make verify SUITES=metadata` executes it against
fixtures, and `forge-lane` gates its own envelope before `kanban_complete`.
None of that is a live lifecycle. F67 is why the default suite does not open a
live board, so the proof has to be an explicit, snapshot-based sweep after a
genuine run.*

| Finding | Status | What is still owed |
|---|---|---|
| F1 | `CONTRACTED — AWAITING LIVE PROOF` | one real card carrying canonical flat `forge.chunk.v1`, read by a consumer |
| F2 | `CONTRACTED — AWAITING LIVE PROOF` | the same card, complete rather than a 3-of-15 subset |
| F3 | `PARTLY FIXED 2026-08-04` | the metric half is closed — `retro-metrics.md` §0 adds gate block rate and §1 splits tier 1 from tier 2, and the missing row for the largest run now exists. The producer half (a card cannot complete without canonical metadata) is contracted and unproven live |
| F26 | `CONTRACTED — AWAITING LIVE PROOF` | one sweep showing every **model-authored** block reason inside the registry regex. Literal producers are already checked |
| F44 | `CONTRACTED — AWAITING LIVE PROOF` | the same proof on the review producer. F1 and F44 are one defect on two producers |

### Blocking the run — this is what the roadmap's tracks are for

| Finding | Status | Track |
|---|---|---|
| F11 | `OPEN` | C1 — cap contracts by countable scenarios, split on `Serves:` > ~4 |
| F14 | `OPEN` | C2 — freeze acceptance scenarios at planning time |
| F18 | `OPEN` | A1 — the worktree sweep |
| F19 | `OPEN` | A1 — `make new` refuses a temp destination |
| F25 | `OPEN` | C2 — a `@real-source` scenario per contract naming an external source |
| F28 | `OPEN` | C1 — size budget at plan time, where the contract is still editable |
| F34 | `OPEN` | D1 — the `<skill> §<n>` cross-reference check. Still reproducible today, and it has widened: `end-chunk/SKILL.md:37` points at `forge-lane` §5 for `.forge/pr-body.md`, but the PR step is §6 **and** the path became `$FORGE_LANE_RUNTIME/pr-body.md` with F68 |
| F36 | `OPEN` | D1 — `config/codex-pin-agrees`. The three sites happen to agree today (`~/.codex/config.toml` `gpt-5.6-sol`/`xhigh`, `forge-lane` §4, `docs/state.md`); nothing enforces that they keep agreeing, which is the finding |
| F40 | `PARTLY FIXED 2026-08-06` | second symptom closed here — the F-number allocator below. First symptom (the slice-worktree rule written into `docs/operator-guide.md`) still owed |
| F53 | `OPEN` | C1/C2 — move `size-budget` and `real-source` to plan time; both still `warn` at review time |
| F57 | `OPEN` | D1 — report the *widening* rather than passing on it |
| F79 | `OPEN` | new, below. `wielas/forge` has no branch protection and no installed pre-push hook, so the roadmap's own PRs land through no gate at all, and E1's `make commission` cannot assert what it is specified to assert |

### Blocked on ADR-0011 data — the run supplies it

*`docs/open-questions.md` carries the pre-committed decision rule. Nothing here
is actionable until ~10 post-gate reviews accrue, and **adding `verdict` to
`STAMPED` first ends the measurement permanently.***

| Finding | Status | Note |
|---|---|---|
| F4 | `OPEN` | "delete tier 1's model call" is D9.5's question, not a decision anyone may take now |
| F6 | `OPEN` | bounce budget is S6, gated on the pin |
| F15, F21, F32, F33, F38 | `OPEN` | the delta-review cluster; S6 edits the pinned `claude -p` call |
| F20 | `OPEN` | the *observation* stands; §M reversed its **recommendation**, so read it with §M |
| F35 | `PARTLY FIXED 2026-08-05` | the mechanical half is a program (ADR-0009/0010) and the scorer's brief is now explicitly disjoint from the gate's — `prejudge-review.sh:223–226` tells it the gate already decided CI, branch name, scenario count, `Touches` and assertion shape. **Not fixed:** the scorer still reads tier 2's `judge-rubric.md` and still emits the same six-dimension shape, and whether it should exist at all is D9.5. Two of its eight checks were also wrong (F52) |
| F58 | `OPEN` | this is the *number to beat* for D9.5 — 6 bounces on the 2 PRs the gate clears |

### Deferred, post-run

| Finding | Status | Note |
|---|---|---|
| F9 | `OPEN` | **moved out of the draft's "moot" bucket.** The evidence is forgeboard's commits, but the fix is a live methodology rule — a contract must not restate a signed constraint in looser words — and no other finding carries it |
| F10 | `OPEN` | a *dispatcher* defect. F52 proved a PR-time gate is structurally incapable of catching it. The run counts the wasted dispatches (E9) and that number decides the scheduler |
| F16 | `PARTLY FIXED 2026-08-05` | tier 1's prompt is now assembled by a program (`prejudge-review.sh` stages 2–4). Tier 2's is still hand-written per pass, which is the half that mattered |
| F17 | `OPEN` | **moved out of the draft's "moot" bucket.** `forge-ladder` is the Forge's own board and still exists; "a card title is not a verdict" applies to every future run |
| F22 | `PARTLY FIXED` | the record F22 asked for exists (F39) and `state.md` is corrected. Enforcement is F36's; the `sol xhigh` vs `terra high` re-run is post-run and needs a mid-size chunk to run against |
| F31 | `OPEN` | needs no code — `scripts/metrics.sh` already emits operator touches. It needs a column in `retro-metrics.md` |
| F46 | `OPEN` | stamping the resolved id changes what `lane/prejudge-judge-model-is-observed` asserts; that case gets rewritten on purpose or not at all |
| F48 | `OPEN` | D2's spike answers *what the substrate exposes* before any chunk is written. Do not stamp invented zeroes |
| F52 | `OPEN` | a constraint on the run, not an item to fix. Accept the wasted dispatches and count them |
| F60 | `RECORDED` | the workaround is standing policy (post-merge `./hermes/profiles-bootstrap.sh`); the policy question — merge-base comparison vs an explicit post-merge gate — is unanswered |

### Moot with forgeboard abandoned

**This means the *product-specific evidence* is moot. It does not mean the
lesson is.** `wielas/forgeboard-report`'s code is not being maintained, so a
finding whose subject is a line of `normalize.py` or a ratio between two of its
files can never be "fixed" — there is nothing to fix it in. Each of these has a
methodology half that is alive and tracked under a different number, and the
right reading of this bucket is *"the instance is closed, the class is open
elsewhere"* — not *"seven findings were waved away"*.

| Finding | Its evidence | Where the methodology half lives |
|---|---|---|
| F12 | 1,250 lines of signed planning for a read-only CLI | F11 (contract sizing), C1 |
| F13 | feature files at 10% of their step files | F14 (scenario theater), C2 |
| F15b | that run's 386,300 tier-2 tokens | F28/F53 (size drives cost); F45 marked the series break, so these numbers cannot be carried forward even as a baseline |
| F23 | 230 hand-rolled validator lines in `normalize.py` | F25 (strictness ratchet), and the live dependency-allowlist question in `AGENTS.md` |
| F24 | coverage inverted against integration risk | F25 (nothing ran against reality) |
| F54 | `render(report) == render(report)`, still on that repo's `main` | F14 (the defect class), F6 (the judge relents) |
| F59 | the gate's blocks decompose to one convention and one tautology | F53 (a gate that fires on everything is not a filter). Its live half is a **prediction** the roadmap records: the severity map was validated on two defects and must be re-validated on the next real run |

### Where this table corrects the roadmap's draft

`docs/roadmap-first-run.md` §4 was a first pass from reading the bodies. Checked
against the tree, five rows move:

- **F5 → Fixed**, not "deferred, post-run". The draft read F52's "the backtest
  can say nothing about `ci-state`'s recall" as the fix being absent. It is
  present: `prejudge.sh:209` blocks, and `prejudge/absent-ci-is-not-a-pass` runs it.
- **F35 → partly, not delivered.** ADR-0009/0010 shipped the gate; the scorer
  still reads tier 2's rubric and its existence is D9.5's open question.
- **F62, F63 → Fixed**, not "deferred". Both bodies name a fix, and both fixes
  are in `verify.sh` today.
- **F9, F17 → out of "moot".** Neither is about forgeboard's code.
- **F8, F10, F15b, F16, F22, F40, F41, F55, F60, F61** were absent from the draft
  entirely and are classified here.

---

## F-number allocation

F78 was the highest number ever minted; F79 is minted below. This section exists
because **F40's second symptom happened for real** — two disjoint F37s existed
until someone renumbered at review — and the ledger has no allocator that
`make verify` can read. It is prose, so it is a convention, not a gate; the gate
is that every track owns a disjoint block and nobody mints outside their own.

| Range | Owner |
|---|---|
| F1–F78 | this audit and the S1–S5 slices. **Spent.** |
| F79 | slice D1a (ledger reconciliation). **Spent.** |
| F80–F89 | Track A — the artifact survives |
| F90–F99 | Track B — the instrument |
| F100–F109 | Track C — planning-time gates |
| F110–F119 | Track D — hygiene and the spike |
| F120–F129 | Track E — the staged launch |
| F130+ | the run itself, and anything found while reading it |

Rules, because a range alone did not stop it last time:

1. **Mint only from your own block.** A finding discovered by track B while
   reading track C's code is still a B number — the block follows the *finder*,
   because the finder is the one worktree that knows what it has spent.
2. **Spend a number in the same PR that writes the finding.** A reserved-but-unwritten
   number is exactly the state that produced the two F37s.
3. **If a block is exhausted, take the next unallocated block and record the
   extension in this table in the same PR** that spends its first number.
4. **Never renumber, ever** (`CLAUDE.md`). Reuse the existing number when
   revisiting a finding.
5. **`F<n>b` suffixes** (there is one, F15b) are for a further *measurement of
   the same defect*, never for a new one. A new defect gets a new number.

---

## Verdict in one paragraph

The Forge **works**: 6 planned chunks, 5 merged, 187 tests green, 92.9% coverage,
CI green on all 10 PRs, unattended lane → PR → tier-1 → tier-2 → merge held
throughout. But it spent **48 of 54 cards on overhead**, bounced 12 times, and
produced a tool that **exits 4 on the board that built it** — because the one
thing no gate ever did was run the product against real data. Every finding
below is a variant of that sentence.

**On efficiency specifically:** roughly **60–65% of the ~520k review tokens were
avoidable without weakening a single gate.** The three causes are structural, not
model-quality problems: Opus is spent on the tier that has never once bounced
(F20), every bounce re-reviews a diff that is >95% identical to the one it just
reviewed (F21), and deterministic rules a 4-line git hook could enforce are
adjudicated by frontier models after the fact (F7). The cheap, cache-friendly
model in the stack — `deepseek-v4-flash` — is used well by the lane and thrown
away by the reviewers.

**On efficacy:** the 12 bounces caught real scenario theater and one genuine
escaping bug, but **missed the only defect that makes the product unusable**, and
CHUNK-3's five bounces actively *worsened* it by hardening the consumer while
nothing was asked of the producer (F25).

**Second pass (§H–L), and the sentence the whole document reduces to:** the
Forge's founding commitment is ADR-0003 — *deterministic enforcement lives in
the repo, never in harness prompts; skills persuade, gates enforce*. It is
rigorously observed inside L2 and **abandoned in every layer built after it**.
Branch names, diff budgets, CI state, parent-merge gates, scope containment,
verdict arithmetic, the flywheel's own three metrics and the token counts used
to judge all of it are decidable by `git`, `jq` and `sqlite3`, and are instead
adjudicated by language models in prose, after the fact, at frontier prices —
and, in the cases this audit could check, **wrongly** (F26–F30, F35). That is
not eight problems; it is one problem eight times. The upgrade is not new
machinery. It is applying the Forge's own best idea to the parts of the Forge
that were built after it was written down (§L).

---

## The run, in numbers

| Measure | Value |
|---|---|
| Planned chunks | 6 (CHUNK-1…6) |
| Chunks merged | 5 · CHUNK-6 still open at PR #11, bounce-2 card `t_d13daaf6` **blocked** |
| Cards created | **54** — 6 chunk, 12 fix/bounce, 17 prejudge, 17 judge, 2 archived dupes |
| Productive-to-overhead card ratio | **6 : 48** |
| Tier-2 bounces | **12** — C1:0 C2:0 C3:**5** C4:3 C5:2 C6:2(unfinished) |
| Tier-1 bounces | **0** — but out of only **7 readable verdicts**; 10 of the 17 tier-1 runs emitted no canonical metadata at all (F44) |
| Mean tier-2 score, dims 1–3 | **1.88** (17 verdicts, 96/51 points) — vs tier-1's near-uniform 3.00 |
| Tier-2 review tokens (self-reported) | **386,300** — 65% of it on CHUNK-3 alone |
| Tier-1 review tokens (extrapolated) | ~134,000, on **Opus**, for zero bounces |
| Est. avoidable review tokens | **~60–65%** of ~520k, without weakening a gate (F20/F21) |
| Models in play | lane driver `deepseek-v4-flash` · codex `gpt-5.6-terra/high` · tier-1 **`opus`** · tier-2 four different `gpt-5*` |
| PRs opened / merged / closed-unmerged | 11 / 6 / **4** (all 4 closed for branch naming alone) |
| Wasted lane dispatches (dependency gate) | **5** — one per chunk 2–6, 25s–1m each |
| Wall clock | planning 1h50m; implementation ~7h13m active across 2 days |
| Delivered code | 8,746 lines (2,063 stmts src / ~4,800 tests) for a read-only report CLI |
| Saved review prompt bytes in `/private/tmp` | **300 KB**, largest single **127 KB** |
| Agent sessions | ≥57 (prejudge each spawns a nested `claude -p`, so ≈74 model contexts) |

**Bounce concentration:** CHUNK-3 alone consumed 5 bounces, 6 judge passes, 6
prejudge passes, and 20 hours wall clock. It is also the largest module
(`normalize.py`, 1,193 lines). Bounce count tracks chunk size, nothing else.

---

## A. The integration hole (the finding that matters)

### F1 — The product cannot read the board that produced it · `CONTRACTED — AWAITING LIVE PROOF` · **critical**

`forgeboard-report` exits **4** (invalid-core) on `forge-ladder`:

```
$ forgeboard-report --board forge-ladder --graph docs/chunks/graph.json \
    --from 2026-07-29T00:00:00+00:00 --to 2026-07-31T00:00:00+00:00 \
    --operator wielas --output /tmp/out
forgeboard-report: graph:CHUNK-1->CHUNK-2: required parent completed-run handoff is missing
EXIT=4
```

**Root cause — producer and consumer disagree on the envelope shape.**

The consumer treats `task_runs.metadata` as *being* the envelope and requires a
top-level `schema` string:

- `src/forgeboard_report/normalize.py:733` — `schema = decoded.get("schema")`;
  absent ⇒ `noncanonical-metadata` warning, envelope dropped
- `src/forgeboard_report/normalize.py:952` — `_require_keys(value, {"schema","chunk_id","pr"}, …)`
- dropped envelope ⇒ no `ChunkHandoff` (`normalize.py:435`) ⇒
  `dependencies.py:121` raises

The producer (the lane) instead **nests** the envelope under an outer key named
for the schema, and omits the inner `schema` field. All six chunk cards:

```json
t_5c2f7f61 {"forge.chunk.v1":{"chunk_id":"CHUNK-1","pr":"…/pull/2","model":"gpt-5.6-sol",
             "check":{"green":true,"tests_passed":40,"coverage":100.0}},
            "changed_files":[…],"tests_run":40,"decisions":[…]}
```

`rubrics/kanban-metadata-schema.md` **supports both readings** and is the real
defect: its example is a flat object with an inner `"schema": "forge.chunk.v1"`
(consumer-correct), but the prose immediately says Hermes's own keys
(`changed_files`, `tests_run`, `decisions`) are "welcome alongside the forge
keys" — which invites the nested form the lane chose. Both readings were
implemented, in the same repo, over the same two days, and nothing noticed.

**The decisive evidence that this is a lane defect, not a product defect:** the
*other* envelope in the same pipeline gets it right. All 17 judge cards store
`forge.judge.v1` **flat, with the inner `schema` field** — exactly what the
product's decoder expects:

```
t_3f29bbf6 | (completed run) | flat schema=forge.judge.v1     ← correct
t_5c2f7f61 | (completed run) | {"forge.chunk.v1":{…}}          ← nested, no inner schema
```

So `forge.judge.v1` and `forge.chunk.v1` — two envelopes, one contract doc, one
pipeline, two days — use two incompatible shapes. The judge path is canonical;
the lane path is the outlier. The fix is in `skills/forge-lane/SKILL.md`'s
completion step plus an unambiguous schema doc.

**Fix:** make the schema doc state one canonical shape unambiguously, and add a
gate that validates real card metadata against
`rubrics/judge-verdict.schema.json`'s sibling (a `forge.chunk.v1` JSON Schema,
which does not exist yet). Candidate: extend `make verify` with a `metadata/`
suite that reads the last N completed cards off a live board and validates them.

**Contract status, 2026-08-06.** The producer defect this finding names is
closed *in contract*. `rubrics/run-metadata-contract.json` maps each producing
profile to the only completed-run schemas it may emit; `forge.chunk.v1` is now a
flat Draft 2020-12 schema; and the `metadata/` verify group rejects the
historical nested envelope by name (`metadata/rejects-nested-chunk`) along with
reserved nested copies, missing required fields and the `coverage` /
`coverage_pct` drift. `forge-lane` validates its exact object before
`kanban_complete` (`metadata/lane-validates-before-complete`).

**That is why this header says `CONTRACTED` and not `FIXED`.** Every one of
those cases runs against a fixture. What F1 records is a *producer under a
model's control* — the failure was never that the shape was undocumented, it was
that a model emitted a different shape and nothing looked. The proof is one
genuine lifecycle: a real card carrying canonical flat `forge.chunk.v1`, and a
consumer that reads it. F67 records why that sweep must be explicit and
snapshot-based rather than folded into the default suite.

### F2 — Not one field of `forge.chunk.v1` is canonical · `CONTRACTED — AWAITING LIVE PROOF` · **high**

Measured against `rubrics/kanban-metadata-schema.md`, every one of the six
envelopes is a different, smaller, ad-hoc subset.

Present: `chunk_id`, `pr`, `check{green,tests_passed,coverage|coverage_pct}`,
`model`, sometimes `reasoning_effort`.

**Missing from all six:** `schema`, `project`, `branch`, `lane`, `scenarios`,
`files_changed`, `lines_changed`, `debt`, `card_proposals`, `docs_reconciled`,
`duration_min`, `worker`. Invented, not in schema: `model`, `reasoning_effort`,
`tests_passed`.

**The producer also drifted mid-run, silently:** CHUNK-1 and CHUNK-2 write
`check.coverage`; CHUNK-3–6 write `check.coverage_pct`. Nothing caught the
change of key between two consecutive cards.

**Contract status, 2026-08-06.** The repository now has a flat
`forge.chunk.v1` JSON Schema, a profile-to-schema registry, and a fixture-only
`make verify SUITES=metadata` gate that rejects the historical nested shape,
missing required fields, `coverage`/`coverage_pct` drift, reserved nested copies
and cross-field contradictions. A recorded PR now runs through the real gate
producer and that output is validated, rather than copied into a parallel
fixture. `forge-lane` gates its complete flat file before `kanban_complete`.
This is not closure: one genuine lifecycle proof must show that the model obeys
the producer gate and that the consumer reads the resulting card. The default
suite does not open a live board; F67 records why any live sweep must be
explicit and snapshot-based.

At audit time `docs/state.md` claimed as *proven*: "Both metadata schemas
populate — `forge.chunk.v1` and `forge.judge.v1` **complete** on the real
cards." That claim was false: they were *present*, not both complete. The
2026-08-06 contract slice corrects the state document; a genuine lifecycle is
still required before it may claim the chunk producer fixed in reality.

### F3 — The official bounce-rate metric reads 0.00 on a run with 12 bounces · `PARTLY FIXED 2026-08-04` · **high**

`docs/retro-metrics.md` defines bounce rate as *tier-1* verdicts where
`.verdict == "bounce"`. Tier-1 bounced **0 of 17** times this run, so the
official bounce rate for the largest run to date reads **0.00 (0/6)** while the
truth is **12 tier-2 bounces across 4 of 6 chunks**. The metric is blind to the
run's dominant failure mode by construction.

Good news, and a correction to an earlier draft of this audit: **metric 2 is
computable.** All 17 tier-2 verdicts *are* stored canonically as card metadata
and can be queried directly:

```sql
SELECT json_extract(metadata,'$.chunk_id'), json_extract(metadata,'$.verdict'),
       json_extract(metadata,'$.scores.spec_fidelity')
FROM task_runs WHERE json_extract(metadata,'$.schema')='forge.judge.v1';
```

Mean d1–3 across the 17 tier-2 verdicts is **1.88** — the first genuinely
discriminating number this rubric has produced, and exactly the falsification
`retro-metrics.md` asked for when it warned that a standing 3.00 would be
"decorative".

**But tier-1's own metadata discipline degraded across the run:** only **7 of
17** prejudge cards carry canonical `forge.judge.v1`. The 10 that don't are
clustered late (`t_faf57139` onward, all but two). Same silent-drift pattern as
F2's coverage-key change.

`retro-metrics.md` has **no row for this run**, and `/retro` has still never
executed (state.md gap: "The flywheel").

**Fix:** count bounces at the tier that bounces; gate card completion on
canonical metadata so tier-1 cannot complete without it.

**Status, 2026-08-06 — the first half shipped, the second is contracted.**

*Counting at the tier that bounces:* done, and it required two changes rather
than one. `docs/retro-metrics.md` §1 now reports tier 1 and tier 2 side by side
and says why a blended rate would hide the same defect from the other side; §0
adds **gate block rate** as a separate number, because since ADR-0009 a block
costs zero model tokens and a bounce costs a full review, and averaging them
would make D9.5's experiment unreadable. The missing row for the largest run to
date also now exists (`retro-metrics.md`, the 2026-07-30 `forge-ladder` row).

*Gating card completion on canonical metadata:* contracted, not proven. It is
the same producer contract F1/F2/F44 wait on, and it is fixture-proven only —
see F1's contract-status note. `/retro` has still never executed.

The header therefore reads `PARTLY FIXED`, not `FIXED`: the metric can no
longer read 0.00 on a run with 12 bounces, but nothing has yet observed a live
producer refusing to complete without canonical metadata.

---

## B. Review economics — tier 1 costs and does not filter

### F4 — Tier-1 prejudge is a rubber stamp · `OPEN` · **critical**

**17 prejudge runs, 0 bounces.** Every recorded verdict is `approve` or
`approve-with-nits`, mostly 3/3 on all six dimensions — including on the exact
PRs tier-2 then bounced with 0s and 1s:

| PR | tier-1 said | tier-2 said |
|---|---|---|
| #8 (C5) | approve, 3/3/3/3/3/2 | **bounce** — 1/1/3/**0**/3/3 |
| #9 (C5 repair 1) | approve, 2/3/3/3/2/2 | **bounce** — 1/1/1/1/3/1 |
| #10 (C6) | approve, **3/3/3/3/3/3** | **bounce** — 1/1/**0**/3/3/3 |
| #11 (C6 repair 1) | approve, **3/3/3/3/3/3** | **bounce** — 1/1/3/3/3/3 |

ADR-0007 justifies tier 1 as "an unattended filter that can only bounce". It
never bounced. It is pure cost: 17 sessions, each spawning a nested `claude -p`
judging call, filtering nothing.

`retro-metrics.md` predicted this in writing on 2026-07-28 — *"If d1–3 stays at
3.00 across the next few chunks, the score is decorative"* — and then 17 more
3.00s arrived. The watch item fired and nothing acted on it.

**Fix options (needs decision):** (a) delete tier 1 and route straight to tier
2, spending the tokens once on the review that actually discriminates; (b) demote
tier 1 to deterministic pre-checks only (CI settled, branch name, Touches
boundary, metadata schema valid) with **no model call at all**; (c) keep the
model but give it a bounce quota / adversarial framing. **(b) is the
recommendation** — every tier-1 finding of value this run was mechanical.

### F5 — Tier-1 reports CI state it never actually observed · `FIXED 2026-08-04` · **medium**

Four prejudge summaries claim "CI unreported (no checks configured)" or "No CI
checks configured (empty statusCheckRollup)" — e.g. `t_faf57139`, `t_f41b333c`,
`t_e8d612af`. **CI ran and was green on all 10 PRs** (`gh run list`: 15 runs,
all success, 12–21s each).

`t_faf57139` ran 07:28–07:32Z; the CI run for that head
(`30523157794`) started **07:29:59Z**. Prejudge queried before checks
registered, got an empty rollup, and **approved on absent CI** rather than
waiting.

`forge-prejudge.SOUL.md` §2 is explicit and correct — "Wait for CI before you
read anything", `gh pr checks --watch` — and enumerates three states
(`pass`/`fail`/`pending`). It has no row for the **fourth** state: *no checks
registered yet*, which is what a just-pushed PR returns. Unhandled state,
resolved by the model in the unsafe direction.

**Fix:** L2, not prose. Absent-checks must be a hard wait-then-block, and the
SOUL's table needs the fourth row.

**FIXED 2026-08-04, by ADR-0009's gate.** `scripts/prejudge.sh` owns CI state
now, and its fourth state is a block, not a pass:

```
scripts/prejudge.sh:209
  emit ci-state block "empty statusCheckRollup after ${WAIT_SECS}s
                       — absent CI is not green CI (F5)"
```

It waits `--wait` seconds (default 180) first, so the race F5 measured is
absorbed rather than merely detected, and a still-pending rollup after the wait
blocks too (`prejudge.sh:220`). Pinned by `prejudge/absent-ci-is-not-a-pass`.

The second half of the fix — *"the SOUL's table needs the fourth row"* — is moot
in the way ADR-0010 makes things moot: there is no table, because the SOUL no
longer decides anything. It is 56 lines of identity and the protocol is a
script. That is the correct disposition for a prose fix whose prose was deleted.

**What F52 says about this, so the two are not read as contradicting.** F52
records that `ci-state` returns zero findings across all 11 backtested PRs and
that the backtest *cannot* measure its recall, because the race is seconds wide
and the rollup is populated forever after. That is a statement about what the
backtest can prove, not about whether the fix shipped. It shipped.

### F6 — The judge does not converge; it relents · `OPEN` · **high**

CHUNK-5's arc, from `/private/tmp/chunk5-tier2-*.json`:

- 11:21 bounce 1 — `scope_discipline: 0`, 3 findings
- 11:53 bounce 2 — **five** findings, scores 1/1/1/1/3/1 — *worse than bounce 1*
- 12:19 approve — 3/2/3/3/3/3, one nit

The nit in the approval is **the same defect** bounce 2 scored as `fix`/1:
subprocess determinism variants not combined with shuffled inputs. Same rubric,
same reviewer model, ~25 minutes apart: `fix` → `nit`, 1 → 2, bounce → approve.
CHUNK-6 PR #11 was bounced with **no `block` findings at all** — two `fix`
findings — which under a sane reading is `approve-with-nits` plus two cards.

**CHUNK-3's approval came from a model swap, not from convergence.** The verdict
ledger records `judge_model` per pass:

| pass | model | verdict | d1–3 |
|---|---|---|---|
| `t_a66935b1` | `gpt-5` | bounce | 1/2/1 |
| `t_746d64ff` | `gpt-5` | bounce | 1/1/3 |
| `t_6535f9be` | `gpt-5` | bounce | 1/2/1 |
| `t_8975bc1e` | `gpt-5` | bounce | 0/1/3 |
| `t_f87330e6` | `gpt-5` | bounce | 1/2/2 |
| `t_c0deaf82` | **`gpt-5.6`** | **approve** | **3/3/3** |

Five bounces from `gpt-5`, then a jump straight to a perfect 3/3/3 from a
different model. Across the run tier 2 used four different reviewers
(`gpt-5.6-sol`, `gpt-5`, `gpt-5.6`, `gpt-5.6-terra`) with no policy governing
which. A review tier whose verdict depends on which model was configured that
hour is not a gate; it is a sampling process.

**Mechanism:** the rubric's verdict logic (`rubrics/judge-rubric.md:19-23`) is
tuned to bounce — *any* single `1` on dimensions 1–3 defeats `approve`, and a
`spec_fidelity: 1` finding is by definition not a nit. Combined with chunk
contracts that enumerate dozens of independently checkable properties (F7), a
sufficiently careful judge can always find one more. There is no bounce budget,
no convergence criterion, and no notion of "good enough to merge, remainder as
cards".

**The strictness ratchet actively caused F1.** All 5 CHUNK-3 bounces demanded the
*consumer* validate `forge.chunk.v1`/`forge.judge.v1` ever more strictly
("exact schema validation", "tri-level unknown-field rejection"). That
strictness is precisely why the tool now rejects the real board. Meanwhile
nothing was ever asked of the *producer* of those envelopes, running in the same
pipeline, the same two days.

**Fix:** a bounce budget (e.g. 2 per chunk, then operator decides); `fix`-only
verdicts become `approve-with-nits` + cards; require the judge to state what
changed since its own prior verdict on the same chunk.

---

## C. Deterministic rules enforced by expensive models

### F7 — Branch naming burned 4 PRs and 4 bounce cycles · `FIXED 2026-08-05` · **high**

`AGENTS.md:27` requires `chunk/<id>-<slug>`. The lane pushed `chunk/1`…`chunk/6`
every time. Consequences:

- CHUNK-1, CHUNK-2 merged on `chunk/1`, `chunk/2` — **policy violated, judge
  approved anyway**
- CHUNK-3–6: tier-2 bounced on branch name, PR closed, branch recreated, PR
  reopened — PRs **#4, #6, #8, #10** all closed unmerged for this alone
- The bounce arrived *after* implementation, prejudge, and tier-2 review had all
  been paid for
- **`t_298e46f4` is the purest case: verdict `bounce` with d1–3 scored
  `3/3/3`.** The work was exemplary on every dimension that measures whether it
  was *right*. The only defect was the branch name — 9,500 review tokens and a
  full re-push cycle to enforce a regex.

Same rule, opposite verdicts, chunk 2 vs chunk 3. The lane learned nothing
because nothing told it at push time.

This is a **one-line pre-push hook**. ADR-0003 is titled "Deterministic
enforcement lives in the repo (lefthook + CI), never in harness prompts", and
the README states "skills persuade, gates enforce". This is the flagship
counter-example inside the Forge's own doctrine.

**Fix:** lefthook `pre-push` regex on the branch name, in
`templates/python-service/`. Cost: ~4 lines. Saved: 4 PRs, 4 review rounds.

**FIXED 2026-08-05.** The rule is `templates/python-service/template/scripts/branch-name.sh`,
called from two tiers: lefthook `pre-push` (fast, local, and skippable with
`--no-verify`) and a `branch-name` CI job on `pull_request` (authoritative, not
skippable). ADR-0003 names both tiers, so enforcing only at the skippable one
would have half-closed the finding.

Three details cost more than the regex did, and each is a defect the first
draft actually had:

- **`main` must pass.** `no-main-push` owns main-branch policy including its
  bootstrap exception, and a second opinion here re-blocks the push that
  *creates* main — the rung-1 failure recorded in `docs/state.md`.
- **`[[ =~ ]]` is bash; lefthook runs `sh`.** A command that dies on its own
  syntax fails OPEN, so the gate would have passed every branch while reading
  correctly in review.
- **The pattern is written once.** AGENTS.md states it in prose; a copy in
  `lefthook.yml` and another in `ci.yml` is F30's defect, and the copies
  disagree the first time one is edited — surfacing as a branch that passes
  locally and fails in CI, which is F7's cost in a new costume.
  `template/branch-rule-has-one-source` fails the suite if either tier inlines
  the pattern.

Verified against a real bare remote in two states with opposite verdicts
(`chunk/7-render-report` pushes, `chunk/8` is refused, and the two pushes differ
only in branch name), plus eight names driven through the script directly to
exercise the CI path, which takes the branch as an argument because a
`pull_request` checkout is a detached merge ref whose HEAD is not the branch.

### F8 — The `Touches` list is planner fiction, and the judge scores against it · `RESOLVED-BY-DECISION 2026-08-04` · **medium**

Contract `Touches` lists were written by `/roadmap` before any code existed and
are repeatedly wrong. The judge treats them as authoritative and bounces
`scope_discipline`:

- CHUNK-3: 6-path list omitted `tests/fixtures/normalize.py` (which the work
  necessarily needed) → bounce + a "remediation deviation" decision-log entry
- CHUNK-5: PR touched `errors.py` and `tests/test_graph.py`, neither listed →
  `scope_discipline: 1` (`/private/tmp/chunk5-tier2-bounce2.json`)

These are bounces on a defect in the **plan**, not the implementation — the
most expensive possible way to discover that a planner guessed a file list.

**Fix (needs decision):** either (a) `Touches` is advisory and scope is judged
against the Goal, or (b) the lane may amend `Touches` in-branch with a one-line
justification, making the deviation visible without a bounce.

**DECIDED 2026-08-04 — (a), and the data decided it, not an argument.** F55
counted the drift across all six chunks rather than reasoning about it: three of
the five distinct drifting paths are process documents every chunk is *required*
to change and no contract in the entire run ever listed, and a fourth is the
contract recording its own amendment. Exactly one of five was real
implementation outside its plan.

Implemented at `scripts/prejudge.sh:299`, where the exclusion is written down as
a rule rather than a convenience list — *"each entry is a path the METHODOLOGY
obliges a chunk to touch and the contract template has no slot to declare"*:

```
TOUCHES_EXEMPT='^docs/decision-log\.md$|^docs/ROADMAP\.md$|^docs/chunks/'
```

with `touches` emitting `warn`, never `block`. With the exclusion the check
fires on 2 of 10 PRs instead of 5, and both remaining hits are the same real one.

**The residual is F57, not F8.** Reading the contract from the PR's own tree
makes the check self-certifying — a branch can legalise its own drift in the
same commit. That is a new check (report the *widening*), not a reopening of
this decision.

### F9 — Judge oscillation on operator-identity escaping · `OPEN` · **medium**

Two bounces to return to the starting point:

- bounce 1 demanded "escape arbitrary source text… including operator IDs"
- the lane implemented a character blacklist rejecting backticks/newlines
  (`domain.py:688-689`) — commit `94ed814`
- bounce 2 ruled that blacklist violates signed `ARCHITECTURE.md:99-103`
  assumption A-6 and demanded its removal — commit `3821fac` reverts exactly 6
  lines

Cause: the contract says "Escape arbitrary source text safely"
(`CHUNK-5.md:9`) without saying *escape, do not reject*, while the signed
architecture said the opposite more precisely elsewhere. The lane cannot see the
conflict; the judge reads both.

**Fix:** contracts must not restate a signed constraint in looser words. Where
they must, `/architect` sign-off should name the authoritative sentence.

### F10 — Every chunk 2–6 burns a dispatch on the dependency gate · `OPEN` · **low-medium**

Run 1 of every chunk card from 2 to 6 is `blocked` after 25s–1m:

```
t_6bb7c902 run1 blocked 27s  → failing-prereq: parent PR #2 (CHUNK-1) is OPEN
t_51461118 run1 blocked 33s  → failing-prereq: parent PR #3 … still OPEN, not merged
t_9655fc6b run1 blocked 25s  → …
t_72b4a5bd run1 blocked 42s  → …
t_6b41c3db run1 blocked 1m   → …
```

ADR-0008 correctly gates on parent `mergedAt`, but the **dispatcher** promotes on
parent card `done`, and a card goes `done` when the PR *opens*. So the board
reliably spawns a worker that reliably discovers it cannot work. 5 wasted
spawns, each paying full prompt cost. `lifecycle-ledger.json` records a related
respawn-guard incident (`respawn_guarded: active_pr after explicit unblock`).

**Fix:** make the card-level dependency edge resolve on parent-PR-merged rather
than parent-card-done, so promotion and the gate agree.

---

## D. Planning and sizing

### F11 — Chunks are not single-session; contracts are mini-projects · `OPEN` · **high**

`skills/roadmap/SKILL.md` promises "single-session chunks". Delivered:

| Chunk | +lines | files | tests at merge | bounces |
|---|---|---|---|---|
| 1 | 800 | 7 | 40 | 0 |
| 2 | 1,576 | 6 | 55 | 0 |
| 3 | **3,699** | 11 | 148 | **5** |
| 4 | 1,083 | 6 | 153 | 3 |
| 5 | 1,644 | 7 | 177 | 2 |
| 6 | 853 | 6 | 187 | 2+ |

Each contract is ~22 lines of extremely dense prose carrying 7 "contract
decisions" and 5 "scenarios" — but the scenarios are compound. CHUNK-6 scenario
2 is *"Given invalid input, an unknown/changing board, cyclic graph,
unavailable/old GitHub CLI, malformed canonical evidence, or publication
failure"* — six scenarios in one bullet. CHUNK-6 `Serves:` **FR-1…FR-9 and
NFR-1…NFR-5** — i.e. every requirement in the project.

Density is what makes F6 possible: a contract enumerating ~40 checkable
properties guarantees the judge finds an unmet one.

**Fix:** cap contracts by countable scenarios (one Given/When/Then each, ≤6 per
chunk) rather than by line count; make `/roadmap` split any chunk whose
`Serves:` list exceeds ~4 requirements.

### F12 — Planning docs outweigh the problem · `OPEN` · **low**

`ARCHITECTURE.md` 534 lines, `ROADMAP.md` 165, `REQUIREMENTS.md` 161, 6 ADRs
(~390 lines) — ~1,250 lines of signed planning for a read-only report CLI, then
8,746 lines of code. The signed surface is large enough that F9-style
contract/architecture conflicts become likely, and every judge pass re-reads it.

### F13 — Feature files are 10% of their step files · `OPEN` · **medium**

| feature | lines | its step file | lines |
|---|---|---|---|
| `report_output.feature` | 42 | `test_report_output_steps.py` | 300 |
| `dependency_audit.feature` | 26 | `test_dependency_audit_steps.py` | 371 |
| `report_command.feature` | 27 | `test_report_command_steps.py` | 310 |

"Scenarios are the living spec" (`AGENTS.md`) does not hold when the spec is 26
lines and its meaning is 371 lines of Python the same agent wrote. This is the
structural reason scenario theater (F14) keeps recurring.

### F14 — Scenario theater is the single most-cited defect, every chunk · `OPEN` · **high**

Tier-2 cited it in essentially every bounce. Representative, all confirmed in
the verdicts:

- `test_report_command_steps.py:179-184` — `cli.run` replaced with a lambda that
  raises, so **all four failure scenarios** test only `main`'s exception
  translation, not orchestration (`chunk6-tier2-bounce1.json`)
- `test_render.py:198-200` — determinism defined as `render(report) == render(report)`
- `test_read_only.py:162-182` — sets `PYTHONHASHSEED`/`TZ`/`LC_ALL` inside one
  already-running process, without `tzset()`, so neither hash seed nor locale
  varies
- `test_performance.py:65-72` — 99 handoffs all sharing the default PR URL, so
  the "bounded multi-batch 100-card acquisition" never batches
- `test_report_command_steps.py:304-310` — weakens "no report directory" to
  checking two filenames

The implementer writes the scenarios, marks them green, and self-reports
coverage; tier-1 approves 3/3; only tier-2 reads the steps. That is one careful
reader guarding a 4,800-line test surface.

**Fix (needs decision):** scenarios (`tests/features/*.feature` Then-clauses)
should be authored or frozen *before* the lane runs — either by `/roadmap` into
the contract, or by a separate cheap adversarial pass whose only job is
"would this test fail if the feature broke?". A mutation-testing gate at L2
would catch most of this deterministically.

---

## E. Process and token burn

### F15 — Review prompts are hand-assembled and enormous · `OPEN` · **high**

17 prompt files survive in `/private/tmp`, **300 KB** total:

```
127,738  forge-prejudge-prompt-full.txt
 67,796  forge-prejudge-prompt.txt
 33,575  forge-prejudge-prompt-738212f7.txt
 28,474  forge-prejudge-prompt.XXXXXX
```

These are diffs pasted wholesale into prompts. The 127 KB file is ~32k tokens of
input for one review. Because a bounce re-reviews the *whole* PR rather than the
delta, CHUNK-3's six review passes re-read a growing 3,699-line diff six times.

**Fix:** review the delta since the last verdict, not the full base..head diff,
and pass the prior verdict as context. This alone is likely the largest single
token saving available.

### F15b — Measured review token burn, from the cards themselves · `OPEN` · **high**

`forge.judge.v1.tokens_estimate` is populated, so review cost is measurable
without guessing:

| Chunk | tier-2 passes | tier-2 tokens | share |
|---|---|---|---|
| CHUNK-1 | 1 | 18,000 | 5% |
| CHUNK-2 | 1 | 24,000 | 6% |
| **CHUNK-3** | **6** | **252,000** | **65%** |
| CHUNK-4 | 4 | 37,800 | 10% |
| CHUNK-5 | 3 | 35,500 | 9% |
| CHUNK-6 | 2 | 19,000 | 5% |
| **total** | **17** | **386,300** | |

Tier-1's 7 recorded verdicts average ~7,900 tokens; extrapolated over 17 runs
that is a further **~134,000 tokens spent on a tier that bounced nothing** (F4).

**One chunk consumed 65% of all review tokens.** CHUNK-3 is also the largest
diff (3,699 lines) and the only one whose reviewer model changed mid-stream. The
three biggest levers are therefore, in order: cap chunk size (F11), delete or
demote tier 1 (F4), and cap bounces (F6). Note also that the per-pass cost
*rose* through CHUNK-3's bounce sequence (46k → 34k → 56k → 38k → 48k) rather
than falling as the delta shrank — direct evidence for F15's delta-review fix.

### F16 — Review prompts were assembled by the operator, off-board · `PARTLY FIXED 2026-08-05` · **medium**

*(Corrected from an earlier draft: every prejudge and judge card **was**
dispatched and **does** have `task_runs` rows. The dispatch machinery worked.)*

What was hand-driven is the *prompt construction*. Each tier-2 pass has a
bespoke operator-authored prompt — `.forge/judge-chunk-1.md`,
`judge-chunk-3-remediation.md`, `judge-chunk-3-bounce5.md`, and 17 files in
`/private/tmp` — each hand-listing which ADRs, docs and evidence the judge should
read, and each summarising the prior bounce in prose. Nothing in `skills/judge/`
generates these; the quality of every review depended on the operator writing a
good prompt that hour. Two duplicate bounce cards (`t_a45a1d8e`, `t_9b38b5b4`)
were created and archived within 90 seconds — manual retries.

The tier-2 sticky handoff, by contrast, worked exactly as designed: each judge
card has a `forge-operator-handoff` run that ends `blocked`, then an unassigned
`completed` run carrying the verdict. ADR-0007's human gate held 17 times.

**Fix:** `skills/judge/SKILL.md` should emit the prompt from the card + contract
+ prior verdict mechanically, so review quality stops being operator-dependent
(and so F15's delta-only reviewing becomes possible).

**PARTLY FIXED 2026-08-05 — at tier 1 only, which is the half that was easier
and not the half that mattered.** `scripts/prejudge-review.sh` assembles the
tier-1 prompt as a program: a pinned scorer brief, then the contract, then the
diff moved byte-wise into the file (F37). Review quality at tier 1 no longer
depends on who wrote the prompt that hour, and the assembly is pinned by
`prejudge/scorer-is-the-control-arm`.

**Tier 2's prompt is still hand-written per pass**, and tier 2 is the tier this
audit found worth its cost (§G). Nothing in `skills/judge/` generates it.
Mechanising it is also the precondition F31 names for counting operator touches
honestly, so this remains open on the axis the finding was about.

### F17 — Card titles record outcomes that did not happen · `OPEN` · **low**

`t_9036ab5a` is titled "judge: CHUNK-6 — **bounce 1 repair approved**". The
verdict for that pass (`/private/tmp/chunk6-pr11-judge.json`) is
`"verdict":"bounce"`, and its successor card `t_d13daaf6` is a bounce-2 repair,
blocked. Anyone reading the board believes CHUNK-6 was approved.

### F18 — Worktrees are still not swept, now measured on a real project · `OPEN` · **low**

`state.md` gap #1, confirmed: `/private/tmp/forgeboard-report/.worktrees/` holds
6 full checkouts (`t_51461118`, `t_5c2f7f61`, `t_6b41c3db`, `t_6bb7c902`,
`t_72b4a5bd`, `t_9655fc6b`), each with its own `.venv`, plus `.forge/uv-cache`.

### F19 — The project itself lives in `/private/tmp` · `OPEN` · **medium**

`forgeboard-report` — the first real product the Forge built — sits in
`/private/tmp`, which macOS periodically purges and Spotlight does not index. It
took a filesystem sweep to find it. Local `main` is 41 commits behind `origin`,
so the working copy does not even reflect the delivered work.

**Fix:** `make new` should refuse to stamp into a temp directory, or the operator
guide should name a durable location.

---

## F. Model economics — the expensive half is the half that does nothing

### F20 — The cost structure is inverted: Opus rubber-stamps, cheap models judge · `OPEN` · **critical**

Measured configuration:

| Role | Model | Source | Bounces produced |
|---|---|---|---|
| Lane driver (Hermes profile) | `deepseek/deepseek-v4-flash` | `~/.hermes/profiles/forge-codex-lane/config.yaml` | n/a — drives |
| Lane implementer (`codex exec`) | `gpt-5.6-terra`, effort `high` | `~/.codex/config.toml` | n/a — implements |
| **Tier-1 scoring** | **`opus`** | `forge-prejudge.SOUL.md` §4 → `claude -p --model opus` | **0 of 17** |
| Tier-2 scoring | `gpt-5` / `gpt-5.6` / `gpt-5.6-terra` / `gpt-5.6-sol` | verdict `judge_model` field | **12 of 17** |

Note the prejudge *profile* is `deepseek-v4-flash` — cheap and correct — but its
SOUL instructs it to shell out to **Opus** for the actual scoring. So the single
most expensive model in the stack is spent on the tier that has never rejected
anything, while the tier that catches every real defect runs on mid-tier models.

`hermes/config-examples.yaml` states the right principle for a different
component — *"~200 output tokens, once per turn. **Never let it inherit an
expensive main model**"* — and tier 1 is precisely the case that violates it.

**Fix, in order of preference:**
1. Delete the tier-1 model call (F4). Its every useful finding this run was
   mechanical.
2. If tier 1 survives, run its scoring **in-profile on `deepseek-v4-flash`**
   rather than shelling out to Opus. That is a straight cost reduction on a tier
   whose measured discrimination is zero, and it makes F21's caching available.
3. Spend the saved budget on tier 2 — the only reviewer that earns its tokens —
   ideally pinning **one** model rather than four (F6).

### F21 — Review payloads are cache-hostile, and 99% of each re-review is identical · `OPEN` · **critical**

CHUNK-3's six review passes re-sent an almost unchanged diff each time:

| pass | insertions in `base..head` | delta vs prior | tier-2 tokens |
|---|---|---|---|
| 1 | 3,638 | — | 46,000 |
| 2 | 5,514 | +1,876 | 34,000 |
| 3 | 5,555 | **+41** | 56,000 |
| 4 | 5,632 | **+77** | 38,000 |
| 5 | 5,792 | **+160** | 48,000 |
| 6 | 6,066 | **+274** | 30,000 |

Passes 3–6 each changed **under 5%** of the reviewed diff and were charged full
price. Three compounding causes:

1. **No delta review.** Every pass reads `base..head` in full (F15).
2. **No cache continuity.** Each pass writes a fresh `mktemp` prompt file and
   pipes it to a **new `claude -p` process** (`forge-prejudge.SOUL.md` §4). There
   is no session reuse, so nothing guarantees a prefix cache hit across passes.
3. **Cache-hostile ordering, by accident.** The stable prefix (rubric + verdict
   schema + contract) is only ~57 lines of a ~3,000-line payload; everything
   after is `git diff` output in path order. The repair commits touch
   `src/forgeboard_report/domain.py` and `normalize.py`, which sort **early**, so
   the changed bytes land near the front and invalidate the cacheable prefix for
   everything behind them.

This is where `deepseek-v4-flash`'s strengths — cheap long context, strong
caching, tolerance for long-running tasks — are being thrown away. The lane uses
them well (1800s timeout, a 283-line protocol held across a 21-minute run). The
review tiers discard them by starting a fresh expensive context per pass.

**Fix:** structure the review payload as
`[rubric + schema + contract]` → `[files unchanged since last verdict]` →
`[files changed since last verdict]` → `[prior verdict]`, and keep the reviewer
in one session across a chunk's bounce sequence.

**Estimated saving (explicitly an estimate):** reviewing deltas for passes 3–6
at ~5k each instead of 56k/38k/48k/30k takes CHUNK-3 from 252k to roughly 100k.
Combined with F20's tier-1 removal (~134k), of the ~520k tokens this run spent
on review, **roughly 60–65% was avoidable without weakening a single gate.**

### F22 — The Codex model pin changed mid-run, undocumented, confounding the one chunk that failed · `PARTLY FIXED` · **high**

- `docs/state.md` documents the pin as `gpt-5.6-sol xhigh`.
- `~/.codex/config.toml` today reads `model = "gpt-5.6-terra"`,
  `model_reasoning_effort = "high"` — a different model *and* a lower effort.
- Card metadata dates the switch precisely: CHUNK-1 and CHUNK-2 recorded
  `"model":"gpt-5.6-sol"`; CHUNK-3 onward recorded
  `"model":"gpt-5.6-terra","reasoning_effort":"high"`.

**CHUNK-3 is both the first `terra` chunk and the 5-bounce chunk.** It is also by
far the largest (3,699 lines). So two variables changed simultaneously — model
and chunk size — and the run cannot distinguish which caused the collapse.

That directly violates the Forge's own stated method, the sentence `state.md`
says should survive a context reset: *"each rung adds exactly one new thing that
can break, so a failure names its own cause."* The most expensive chunk in the
project's history is uninterpretable as evidence because of it.

**Fix:** record the codex model + effort in `forge.chunk.v1` (it already is —
keep it), treat a pin change as a ladder rung requiring its own row in
`retro-metrics.md`, and correct `state.md`. Then re-run one mid-size chunk on
`sol xhigh` vs `terra high` to get a clean read.

**Status, 2026-08-06 — partly, and the part that is done is the part that
records rather than the part that enforces.**

*Done:* the next pin change was recorded as it happened (F39), which is what
this finding says should have existed. `docs/state.md` is corrected. Measured on
the mini today, all three sites agree:

```
~/.codex/config.toml   model = "gpt-5.6-sol", model_reasoning_effort = "xhigh"
skills/forge-lane §4   "gpt-5.6-sol, reasoning xhigh"
docs/state.md          "codex pinned gpt-5.6-sol xhigh"
```

*Not done, and the agreement above is luck rather than enforcement.* Nothing
executes that comparison — the staleness self-corrected when the pin was changed
back, which is not the same as being prevented. That check is **F36**, and it is
where the live work on this belongs.

*Not done, deferred:* the clean `sol xhigh` vs `terra high` read. It needs a
mid-size chunk to run against and is therefore post-run.

### F23 — 230 lines of hand-rolled validator duplicating a JSON Schema the repo already ships · `OPEN` · **high**

`rubrics/judge-verdict.schema.json` is **110 lines of machine-readable JSON
Schema**. The lane hand-wrote its equivalent in Python:

- `normalize.py:760-930` — `_decode_judge`, **170 non-blank lines**
- `normalize.py:1011-1071` — `_validate_judge_consistency`, 60 lines
  reimplementing `judge-rubric.md`'s verdict logic in code

Project-wide: **169 `raise` sites, 61 `isinstance` checks, zero runtime
dependencies**; `normalize.py` alone holds 48 raises and 30 isinstance checks
across 1,193 lines. The module is, in substance, a hand-written schema validator.

Two Forge rules combined to cause this: the judge's escalating strictness demands
across 5 bounces ("exact schema validation", "tri-level unknown-field
rejection"), and `AGENTS.md`'s *"new runtime dependency ⇒ new/updated ADR in the
same branch"*, which makes reaching for `jsonschema` more expensive than
hand-rolling. The lane took the cheaper local path five times in a row.

To be fair to the code: it is **well decomposed** — 32 small named functions in
`normalize.py`, not spaghetti — and it is the strictness, not the craft, that is
excessive. The bloat is a process artifact.

**Fix:** allow a pre-approved dependency allowlist (a validator library is not an
architectural decision), or have the contract say "validate against the shipped
schema file" so the schema stays the single source of truth.

### F24 — Coverage is highest where risk is lowest · `OPEN` · **medium**

From the green `make check` on PR #11 (92.92% total, 187 tests):

| module | coverage | what it does |
|---|---|---|
| `graph.py` | **100%** | pure, in-memory |
| `metrics.py` | 99% | pure |
| `domain.py` | 98% | pure |
| `normalize.py` | 97% | pure |
| `render.py` | 91% | pure |
| `publish.py` | 88% | touches the filesystem |
| `hermes.py` | 81% | touches the real database |
| **`github.py`** | **75%** | **the only module that talks to the outside world** |

The ranking is an almost perfect inverse of integration risk. Combined with F14
(mocked-above-the-behavior scenarios), the 92.92% headline overstates assurance:
the covered lines are mostly pure functions exercised against synthetic fixtures,
and the uncovered ones are the boundaries where F1 actually lives.

### F25 — Nothing ever ran the product against reality, and the plan deferred that to the chunk that never finished · `OPEN` · **critical**

This is the efficacy summary, and the reason F1 survived every gate.

`tests/fixtures/hermes_019.py` and `tests/fixtures/normalize.py` are synthetic.
CHUNK-2 built the entire Hermes adapter against them. The real-source check was
deliberately deferred to CHUNK-6's final gate — *"Verify Hermes 0.19
fixture/public-JSON agreement and GitHub CLI 2.96+ response contracts in the
final gate while ordinary tests remain executable with neither program
installed"* (`CHUNK-6.md`). **CHUNK-6 never finished.** The single acceptance
criterion that would have caught F1 was scheduled last and cut.

Tally of what the 12 bounces and ~520k review tokens actually bought:

- **Caught:** branch names (mechanical, F7), `Touches` drift (planner error, F8),
  scenario theater (real, F14), one genuine escaping bug, one architecture
  conflict the judge itself created (F9).
- **Missed:** the only defect that makes the product unusable.
- **Actively caused:** F1's severity. Five CHUNK-3 bounces hardened the
  *consumer* against non-canonical envelopes while nothing was ever asked of the
  *producer* emitting them in the same pipeline. A more permissive decoder would
  have run.

**Fix, and it is the single highest-value change in this document:** every chunk
whose contract names an external source must include one scenario that runs
against the **real** source, marked skip-if-absent. "Run the smallest real
thing" is already `state.md`'s stated lesson from the ladder; it was applied to
the Forge and not to the projects the Forge builds.

## G. What worked — keep these

- **The chain itself.** Card → worktree → `codex exec` → `make check` → push →
  PR → CI → tier-1 → tier-2 → merge ran 6 times over 2 days without an operator
  babysitting the mechanics.
- **The bounce repair path.** Every one of 11 fix cards resumed the rejected PR's
  own branch and repaired it in place. ADR-0008's worktree routing held under 12
  bounces — the fix that rung 3 paid for is working.
- **Repairs are real, not cosmetic.** `010dfcc` (+79 in `render.py`), `84913ec`
  (+157 tests), `4ca1997` (+216 tests) are substantial responses to specific
  findings, produced in ~12 minutes each.
- **CI was never wrong.** 15 runs, 12–21s, green every time, and the merge gate
  refused what it should.
- **Executable bounce contract.** `rubrics/judge-rubric.md`'s "action must be
  executable by a fresh mid-weight worker" holds: findings copied verbatim into
  card bodies were acted on correctly every time.
- **Tier-2 review genuinely discriminates.** Every serious defect in this
  document was first found by tier 2 reading test *steps* rather than test
  results. It is the one component whose cost is justified.
- **The cheap-driver / expensive-thinker split is correct and now proven at
  scale.** `deepseek-v4-flash` drove the 283-line `forge-lane` protocol across 22
  lane runs, including a 21-minute CHUNK-3 run and 11 bounce repairs, without
  losing its place — exactly what `skills/forge-lane/SKILL.md:12` claims ("Your
  own model is deliberately cheap. The thinking happens inside Codex"). It is
  cache-friendly and tolerant of long tasks, which is why F20/F21 recommend
  using it *more*, not less. The mistake was never the lane's model; it was
  exempting the review tiers from the same reasoning.
- **`tokens_estimate` in `forge.judge.v1`.** Because the field is populated, this
  audit could cost the review process from the cards instead of guessing. Keep
  it, and add the same for lane runs so implementation cost becomes measurable
  too.
- **`lifecycle-ledger.json` / `contract-freeze.json`.** Hashing the signed
  planning surface and recording plumbing incidents separately from contract
  bounces is a good idea that should be promoted into the Forge proper.

---

## H. The unifying defect — ADR-0003 is honoured at L2 and abandoned above it

*Second pass, 2026-07-30. Where the first pass listed symptoms, this section
names the single design error that produces most of them.*

ADR-0003 is the Forge's sharpest commitment: **"Deterministic enforcement lives
in the repo (lefthook + CI), never in harness prompts."** `README.md` restates it
as the slogan every stamped project is told: *skills persuade, gates enforce.*
It is rigorously observed inside L2 — the template really does install lefthook,
CI really does refuse a red merge, `make verify` really does execute the claims.

Above L2 it is abandoned completely. Every layer the Forge added *after* the
template re-adopts exactly the pattern ADR-0003 was written to forbid: a
deterministic property, checked by a language model, in prose, after the fact.

| Property | Actually is | Currently enforced by | Finding |
|---|---|---|---|
| Branch name matches `chunk/<id>-<slug>` | a regex | Opus, post-hoc, after the PR exists | F7 |
| CI is green before review | a shell exit code, already captured | prose narration in the SOUL | F5 |
| Parent PR `mergedAt` is non-null | a `jq` predicate over `gh` JSON | 40 lines of lane prose (§1a) | F10 |
| Diff stays inside `Touches` | a set difference over path lists | a scored rubric dimension | F8 |
| Verdict follows from the six scores | a 4-line decision table | the model asserts it | **F29** |
| Diff ≤ 400 lines / ≤ 6 files | `git diff --numstat` | nothing at all | **F28** |
| Bounce rate, mean d1–3, `reason_class` | three SQL queries | a model reading prose | **F27** |
| Review token cost | a field in the harness's own JSON | the model's own guess | **F30** |

Every expensive finding in sections A–G is a row in that table. This is not
eight problems; it is one problem eight times. **The correct frame for the next
pass is not "make the models cheaper" — it is "stop asking models questions that
`sqlite3`, `jq` and `git` already answer exactly."** That single move is worth
more tokens than every prompt optimisation in section F combined, and unlike
those it also makes the answers *correct*, which the models' answers were not.

---

### F26 — `forge.block.v1` has never existed; one third of the flywheel is unpopulatable by construction · `CONTRACTED — AWAITING LIVE PROOF` · **high**

`rubrics/kanban-metadata-schema.md` defines `forge.block.v1` with a
`reason_class` enum, and `docs/retro-metrics.md` makes its distribution one of
the three numbers that decide whether the Forge is improving.

Measured across the entire history of the `forge-ladder` board:

```sql
SELECT COUNT(*) FROM task_runs
 WHERE json_extract(metadata,'$.schema')='forge.block.v1';
-- 0
```

**Zero rows. Ever.** Not on this run, not on the ladder runs, not on the
dependency or CI-red exercises. The schema has never been emitted once.

The reason is structural, and the Forge's own documents state it twice without
drawing the conclusion. `forge-lane` §7: *"`kanban_block` only stores the reason
string"*. The block event payload confirms it:

```json
{"reason": "...", "kind": "needs_input", "recurrences": 1}
```

There is no metadata parameter on the block path. **`forge.block.v1` cannot be
attached to anything.** A `reason_class:` prefix inside the free-text reason is
the convention that emerged instead — and it is followed about a quarter of the
time. Of the block events on this board:

- `failing-prereq: parent PR #2 …` — parseable ✓ (×3, all from `forge-lane` §1a)
- `tier-2 operator review required: run /judge…` — no class (×7)
- `Tier-2 judge card dispatched to wrong profile…` — no class
- `mechanical tier-2 handoff probe` — no class

So the metric that is supposed to name *which layer is losing runs* is 0%
populated through its documented mechanism and ~25% populated through an
undocumented one that nothing parses.

**Fix (cheap, and it is the ADR-0003 move).** Drop `forge.block.v1` — it is
decoration for an API that cannot carry it. Replace it with a hard contract on
the string that *does* get stored: every `kanban_block` reason must match
`^(stale-spec|failing-prereq|env|ci-red|judge-bounce|gate-misrouted|other): `.
Add that regex to `make verify`'s `config/` suite reading live boards, and
compute the distribution in SQL from `task_events`. Cost: one sentence in two
skill bodies, one regex, one query. `gate-misrouted` is the class
`retro-metrics.md` already said should be added after it happened twice, and
never was.

**Contract status, 2026-08-06.** The impossible `forge.block.v1` envelope has
been removed. One registry regex now owns the vocabulary (including
`gate-unrunnable`); literal script/SOUL producers and the metrics consumer are
checked against it, and the historical unclassified tier-2 sentinel reason is
now `other:`. F26 remains open until a live sweep proves model-authored
terminators obey the contract.

---

### F27 — The flywheel's three numbers are computed by a model reading prose · `FIXED 2026-07-30` · **critical**

`/retro` step 1 opens: *"Compute the three in `docs/retro-metrics.md` — bounce
rate, mean judge score on dimensions 1–3, and the `reason_class` distribution."*
The inputs it is pointed at are `hermes kanban runs/list`, *"or the metadata
JSONs in PRs"*. In other words the Forge asks a language model to do arithmetic
over a SQLite database by reading its printed output.

This is ADR-0003's exact prohibition, applied to the one component whose entire
purpose is to be trustworthy. And it has already failed in every way it could:

- **F3** — the bounce rate reads `0.00` on a run with 12 bounces.
- `retro-metrics.md` carries a row reading *"n/a — observed bounce used
  noncanonical metadata"* — a metric defeated by a key name.
- No row exists at all for the largest run in the project's history.
- The one number the file *does* report consistently (3.00, five rows running)
  is the number the file itself flags as probably decorative.

All three numbers are pure SQL over `task_runs.metadata`. Here is the whole
thing, written and executed against the live board during this audit:

```sql
-- 1. verdict distribution → bounce rate
SELECT json_extract(metadata,'$.verdict') v, COUNT(*)
  FROM task_runs
 WHERE json_extract(metadata,'$.schema')='forge.judge.v1'
 GROUP BY v;
-- approve 15 | approve-with-nits 1 | bounce 14   (board lifetime)

-- 2. mean judge score, dimensions 1-3
SELECT ROUND(AVG((json_extract(metadata,'$.scores.spec_fidelity')
                + json_extract(metadata,'$.scores.scenario_integrity')
                + json_extract(metadata,'$.scores.architectural_conformance'))/3.0),2),
       COUNT(*)
  FROM task_runs
 WHERE json_extract(metadata,'$.schema')='forge.judge.v1';
-- 2.31 over 30 verdicts   (board lifetime; 1.88 over this run's 17)

-- 3. reason_class distribution  (see F26 — currently from the reason string)
SELECT json_extract(payload,'$.reason'), COUNT(*)
  FROM task_events WHERE kind='blocked' GROUP BY 1;
```

That is the deliverable: **`scripts/metrics.sh <board>` — roughly 30 lines,
zero tokens, exact.** It should be wired to `make metrics`, run in `/retro` step
1 as a *command whose output the model reads*, and added to `make verify` so a
schema drift fails a check rather than a quarter.

**It would also have caught F1 on day one.** The same script that counts
verdicts counts chunk envelopes:

```sql
SELECT COUNT(*) FROM task_runs WHERE json_extract(metadata,'$.schema')='forge.chunk.v1';
-- 0
SELECT COUNT(*) FROM task_runs WHERE json_extract(metadata,'$.\"forge.chunk.v1\"') IS NOT NULL;
-- 22
```

Twenty-two chunk completions, **not one of them in the documented shape**, and
the Forge ran for three days without noticing because nothing ever queried its
own exhaust. At audit time `docs/state.md` asserted *"Both metadata schemas
populate"* on the strength of a human having looked at one card once; the
2026-08-06 contract slice corrects that claim.

**This is the highest value-per-line fix in the entire audit.** It is under an
hour of work, it costs nothing to run, it converts the flywheel's inputs from
narrative to data, and it retroactively detects the critical finding.

**FIXED 2026-07-30 — slice S1, PR #3.** `scripts/metrics.sh` exists (93 lines of
bash over 130 of SQL at the time; 23 KB today), wired to `make metrics` and to
`/retro` step 1 as a command whose output the model reads. The `metrics/` verify
group executes it, and the fixture it runs against was corrected to
`journal_mode=wal` by F51 so the group can reach the failure modes a live board
has.

The finding's own claim about itself held: the slice found three errors in this
document within one slice (F41, F42, F44), every one of them a number the audit
had produced by prose rather than by query. Two later findings (F47, and its
unrecorded second half) came from running the deliverable rather than reading
it, which is the same lesson one layer down.

---

### F28 — The sizing rule is the most-violated rule in the Forge, and the only major rule with no gate · `OPEN` · **high**

`skills/roadmap/SKILL.md` states the sizing contract precisely: *"Fits
comfortably in a single session INCLUDING tests and doc updates (heuristic: ≤
~400 lines changed, ≤ ~6 files, ≤ 5 BDD scenarios)."*

Measured on every PR this run produced (`gh pr view --json additions,deletions,changedFiles`):

| PR | Chunk | Lines changed | Files | vs 400-line budget |
|---|---|---|---|---|
| #2 | CHUNK-1 | 800 | 7 | **2.0×** |
| #3 | CHUNK-2 | 1,576 | 6 | **3.9×** |
| #5 | CHUNK-3 | 3,707 | 11 | **9.3×** |
| #7 | CHUNK-4 | 1,105 | 6 | **2.8×** |
| #9 | CHUNK-5 | 1,645 | 7 | **4.1×** |
| #11 | CHUNK-6 | 853 | 6 | **2.1×** |

**Six chunks, six violations, mean 4.0× over, worst 9.3×.** Not one chunk in the
project's only real run came within budget. The planning PR added another 1,421
lines of documentation for a read-only report CLI (F12).

Three consequences follow directly, and each is already a separate finding:

- **Review cost is linear in diff size.** CHUNK-3 is 9.3× the budget and
  consumed **65% of all review tokens** (F15b). The sizing rule *is* the token
  budget; it was simply never connected to anything.
- **Bounce count tracks diff size and nothing else** (F6, F11): 3,707 lines → 5
  bounces; 800 lines → 0.
- **"Single session" was never true**, so the premise the whole lane rests on —
  a mid-weight model finishing without questions — was false for every chunk.

Nothing anywhere checks this. It is a parenthetical heuristic in a skill body,
and skills persuade. Meanwhile the same repo enforces *ruff formatting* with a
git hook.

**Fix.** The most mechanical property in the system deserves the most mechanical
gate. A `pre-push` check plus a CI job:

```bash
read -r add del files < <(git diff --numstat origin/main...HEAD |
  awk '{a+=$1; d+=$2; f++} END {print a, d, f}')
budget=$(grep -oE '^size-budget: [0-9]+' .forge/contract.md | awk '{print $2}')
: "${budget:=400}"
[ $((add+del)) -le "$budget" ] || fail "diff $((add+del)) exceeds $budget"
```

with a required `size-exception: <reason>` line in the PR body to override — so
that going over becomes a *recorded decision* rather than the silent default it
is today. Then add "chunks over budget" as the fourth retro number: it is the
leading indicator for both bounce rate and token burn, and it is knowable
*before* any model is spawned.

---

### F29 — The verdict is a pure function of the scores, and the model is asked to assert it anyway · `FIXED` · **high**

`rubrics/judge-rubric.md` § *Verdict logic*:

> - Any dimension = 0 → `bounce`.
> - Dimensions 1–3 all ≥2 AND none = 1 → `approve`.
> - Otherwise, if every 1-scored finding is a genuinely non-blocking nit →
>   `approve-with-nits`; else `bounce`.

Two defects, both load-bearing.

**1. The quantifier in rule 2 is undefined.** "Dimensions 1–3 all ≥2 **AND none
= 1**" — none of *what*? If it ranges over dimensions 1–3 the clause is vacuous
(≥2 already excludes 1). So it must range over all six, making dimensions 4–6
blocking for approval. But `docs/retro-metrics.md` excludes exactly those three
from the metric on the grounds that they *"measure hygiene, which gates already
enforce"*. The same three dimensions are simultaneously blocking and decorative,
depending on which file you read.

This is not pedantry: it is why `forgeboard-report` had to hand-write
`_validate_judge_consistency` (60 lines, `normalize.py:1011–1071`) on top of
`_decode_judge` (170 lines) to reimplement a rule the repo ships as prose —
F23's 230 lines exist because this paragraph is ambiguous.

**2. Asking the model for the verdict is what makes rubber-stamping possible.**
The verdict is a total function of six integers and a per-finding severity flag.
When the model emits both the scores *and* the conclusion, nothing forces them
to agree — and they didn't: `t_298e46f4` returned `bounce` on scores of 3/3/3
(F7), and tier 1 returned `approve` seventeen times on scores it produced itself
(F4). Either could have been caught by a four-line check.

**Fix — and this is the single best structural change available.** Make the
verdict **derived, never asserted**:

- Replace the prose with a decision table, and encode it in
  `rubrics/judge-verdict.schema.json` as a computed field.
- The judge model emits **scores + findings + evidence only**. It is not asked
  for, and cannot state, a verdict.
- A ~15-line function derives `verdict` from `scores` and finding severities.
  It runs in the SOUL, in `make verify`, and in any consumer.

Three things fall out at once: the tier-1/tier-2 disagreement becomes
*measurable* (same function, different scores — a real signal instead of two
opinions); rubber-stamping now requires the model to fabricate *evidence-bearing
scores*, which is far harder than fabricating a word; and `forgeboard-report`'s
230 hand-rolled lines collapse to a schema import (F23).

**SHADOWED 2026-08-05.** The rules are now a program — `scripts/verdict.sh`,
sourced by `prejudge-review.sh` — and every review records `derived_verdict`
and `verdict_divergence` beside the model's word. **Nothing routes on the
derived value yet.** The scorer's `verdict` still decides, exactly as before.

Shadow rather than enforcement, because the derivation is only worth acting on
once it has been measured against real reviews, and because the alternative
touches the pinned control arm. Adding `verdict` to `STAMPED` is an edit inside
`prejudge-review.sh`'s pinned region, which ADR-0009 D9.5 forbids until its
experiment concludes — and F65 is what happened the last time that pin stopped
holding. The shadow record is what that experiment reads.

**Rule 2's quantifier, resolved.** `derive_verdict` reads "none = 1" across all
six dimensions, for the reason defect 1 gives: over dimensions 1–3 the clause is
vacuous. That is now a line of code rather than a paragraph two documents
disagree about.

**First measurement — replay of every stored verdict on this machine:**

| | |
|---|---|
| verdicts replayed | **34** |
| agreed with the derivation | **33** |
| diverged | **1** |
| underivable (invalid input) | **0** |
| of those, *discriminating* (not all-3s-no-findings) | **18** — 17 agree, 1 diverge |

The single divergence: scores `3/3/3/2/3/3` with one `nit` finding, stored as
`approve-with-nits`, derives to `approve` — rule 2 is satisfied, since no
dimension scored 1. It is also the only `approve-with-nits` in the entire
population, and it has **no routing consequence**: `prejudge-review.sh` sends
`approve` and `approve-with-nits` down the same branch.

**FIXED 2026-08-06 — promoted from shadow to blocking.** `prejudge-review.sh`
now routes on `.derived_verdict`. The scorer's own word is recorded and no
longer obeyed, which closes the defect this finding names: an asserted verdict
can no longer decide anything by itself.

**No pinned bytes were touched.** `end pinned region` is line 331; the routing
line is 52 lines below it, so the promotion needed no ADR and no edit to the
control arm — `prejudge/scorer-is-the-control-arm` still reports 24 lines
byte-identical. The plan had this blocked on retiring the pin for two
revisions; the block was never real, and nobody had checked the line numbers.

**The model is still asked for `verdict`, deliberately.** That is what keeps
the instrument running. With routing derived, an asserted verdict decides
nothing and is free to record — so every review from here is a **post-gate**
divergence sample, the one thing the 34-verdict replay could not supply (all 34
predate `prejudge.sh`). Adding `verdict` to `STAMPED` would end that
measurement permanently, and is now explicitly the last step of the arc, gated
on D9.5 being answered.

**The risk being accepted, stated plainly.** Divergences now change routing —
the replay's reassurance that its one divergence had "no routing consequence"
described *shadow mode* and does not carry forward. Concretely, a scorer that
says `bounce` on scores of 3/3/3 with no findings will now route `approve`.
That is not hypothetical: `t_298e46f4`, cited at the top of this finding, did
exactly that. The rubric is the authority here — a dimension marked down must
name a finding (V4), so an unevidenced `bounce` is the same rubber stamp as an
unevidenced `approve`, in the other direction. The blast radius is bounded by
ADR-0007: `approve` routes to a durable human gate, never to a merge.

**The fallback is load-bearing, not defensive.** `.derived_verdict` is null on
two paths — the stamp could not be applied, or derivation itself failed — and a
bare `jq -r '.derived_verdict'` returns the *string* `"null"` on both, which
Stage 5's `case` sends to `*)` and `substrate()`. That is the PR #14 bug
rebuilt one line lower: a completed, paid-for review reported as an outage.
`// .verdict` is asserted against both null shapes by
`prejudge/undecidable-derivation-falls-back-to-the-scorer`. Verified end-to-end
across five inputs — agreement, divergence, unevidenced score, absent scores,
non-JSON. Only the last reaches `substrate()`, which is correct and unreachable
in practice: Stage 4's `jq -ce` validates the envelope before it is written.

**Two limitations, stated because they bound what this can conclude.** First,
these are *not* the seventeen approvals F4 counted — that run was on
`forgeboard-report`, whose board database is not on this machine, so it cannot
be replayed. This population is `forge-ladder` (30), `forge-dependency-clone`
(3) and `forge-hello` (1). Second, all 34 predate `scripts/prejudge.sh`, so they
measure the scorer with nothing in front of it; D9.5 asks what it adds *given*
the gate. What the replay does establish is the weaker and still useful claim:
across every scored review available, the verdict field carried information its
own scores did not exactly once, and that once changed nothing.

**Also fixed here, and not cosmetic:** `judge-verdict.schema.json` says "a score
below 3 with no corresponding finding is invalid" inside a `description`, where
no validator reads it. Rule 3 quantifies over 1-scored findings, and `all` over
an empty list is *true* — so a dimension scored 1 that named no finding at all
would have derived to `approve-with-nits`, the least evidenced verdict possible.
`derive_verdict` exits 3 on that input instead. All 34 stored verdicts pass it,
so the rule is calibrated against real data rather than against the schema's
prose.

---

## I. Provenance — the Forge measures itself with numbers it asks models to invent

### F30 — `tokens_estimate` is self-reported by the model being measured, and the fix is written one paragraph away · `FIXED 2026-07-31` · **high**

Every cost number in this audit — the 386,300 tier-2 tokens, the 65%
concentration on CHUNK-3, the ~520k total — descends from one field:
`"tokens_estimate": 0` in `rubrics/judge-rubric.md`'s verdict schema. It is
filled in by the same model whose consumption it purports to measure, from
introspection it does not have.

The Forge already knows this class of error, and documented it with unusual
precision. `hermes/profiles/forge-prejudge.SOUL.md` §4:

> The `jq` normalization is mandatory: it overwrites `judge_model` with `opus`
> … **A model cannot reliably report its own id**: on 2026-07-28 real verdicts
> came back claiming `claude-opus-4-8` and `claude-opus-4`, neither of which was
> the observed CLI argument. … an invented value silently poisons every
> provenance question later. **Yours is the only trustworthy source.**

That paragraph is exactly right, and it is applied to `judge_model` and to no
other field — including the one sitting immediately beside it in the same JSON
object, filled in by the same untrustworthy narrator, for the same reason.

**Fix (five minutes).** `claude -p` already returns real usage;
`--output-format json` is a live flag (verified against
`claude -p --help` on this machine: *"json (single result)"*). Capture it and
stamp it exactly as `judge_model` is stamped:

```bash
raw="$(claude -p --model opus --output-format json \
        --json-schema "$VERDICT_SCHEMA" < "$prompt_file")"
verdict="$(jq -ce --arg pr "$pr_url" --argjson u "$(jq '.usage' <<<"$raw")" '
  .pr = $pr
  | .judge_model = "opus"
  | .tokens_estimate = ($u.input_tokens + $u.output_tokens)
  | .tokens = $u                      # keep the real breakdown
' <<<"$(jq -r '.result' <<<"$raw")")"
```

Keeping `.usage` whole matters more than the total, because it carries
`cache_read_input_tokens` — **without which F21's cache-hostility finding cannot
be verified after the fix, only asserted.** Every token-efficiency change
proposed in this document is unfalsifiable until this field is real. Do this
first, before any optimisation, or the next audit will be guessing too.

Do the same for the lane: `codex exec` reports usage, and `forge.chunk.v1` has
no cost field at all, so implementation cost is currently invisible.

**FIXED 2026-07-31 — slice S2; the stamping moved to `scripts/prejudge-review.sh`
with ADR-0010 and is pinned there.** The model is no longer asked for any of it:

```
prejudge-review.sh:310   STAMPED='["pr","judge_model","tokens_estimate","cost","session_id"]'
prejudge-review.sh:316   claude -p --model opus --output-format json …
prejudge-review.sh:329   .tokens_estimate = ($u.input_tokens + $u.cache_creation_input_tokens
                                             + $u.output_tokens)
prejudge-review.sh:331   .cost = ($u | del(.iterations)) + {total_cost_usd: …}
prejudge-review.sh:332   .session_id = …
```

`STAMPED` is subtracted from the schema the model is shown
(`prejudge/schema-hides-stamped-fields`), so a field the operator stamps cannot
be invented — which is stronger than the fix this finding proposed.

Two follow-ons rather than caveats. **F45** measured that the original formula
counted output alone, because Claude Code bills the prompt to
`cache_creation_input_tokens`; the corrected formula above is the ruling, with
the series break marked at 2026-08-01. **F46** notes that the CLI *argument* is
still not the best source for `judge_model` — the envelope carries the resolved
id — and is deliberately left open.

The lane half of the fix is **not** done: `forge.chunk.v1` still has no cost
block, and that is F48, which also records that the metered engine has no
telemetry to put in one.

---

### F31 — The board records zero operator activity, so "unattended" cannot be measured or falsified · `OPEN` · **high**

The Forge's entire value proposition is unattended work. Its three metrics are
bounce rate, mean score, and `reason_class`. **None of them can see a human.**

Comment authors across the whole board:

```
forge-prejudge   27
forge-codex-lane 15
default           2
builder           1
```

**Not one comment authored by the operator.** Yet the operator personally drove
17 tier-2 reviews, hand-assembled the review prompts off-board (F16), left the
verdicts as loose JSON in `/private/tmp`, closed 4 PRs by hand for branch naming
(F7), and manually unblocked cards. By the board's own record, none of that
happened.

The consequence is not bookkeeping: **a change can improve all three metrics
while costing more operator time, and the Forge would call it an improvement.**
Shrinking chunks until every one passes tier 1 would drive bounce rate to zero
and mean score to 3.00 while multiplying the number of PRs a human must look at.
Nothing in the metric set would object.

**Fix.** Add a fourth number — *operator touches per merged chunk* — and make it
countable, which requires making operator work land on the board at all:

- Tier-2 verdicts go into card metadata (they already do, F3) **and** the
  tier-2 prompt is assembled by the board, not by hand (F16).
- Count from the board: comments by a human author + manual unblock events +
  cards created by a human + `hermes kanban` invocations from an interactive
  shell. This run's honest value is roughly **17 review sessions + 4 manual PR
  closures + ~6 unblocks ≈ 27 touches for 5 merged chunks — 5.4 per chunk.**

That number, not bounce rate, is the one the Forge exists to reduce. It is
currently the only important quantity nobody has ever recorded.

---

## J. "Fresh context" is charged where it costs the most and helps the least

### F32 — Judge oscillation is a designed-in consequence of the fresh-context rule, not a model defect · `OPEN` · **high**

Fresh context appears as a hard rule at four points: `scope` → *"next step is
/architect in a FRESH session (fresh context is deliberate — the architect must
challenge this doc without anchoring on the conversation that produced it)"*;
`roadmap` → *"Fresh context"*; `judge` → *"You are a fresh-context reviewer"*;
`end-chunk` §6 → *"Fresh context is the next worker's right."*

The justification given is always the same and is always about **anchoring on a
conversation**. That justification is sound at ceremony boundaries, where the
reviewer must not inherit the author's framing.

It is **actively harmful within a bounce sequence**, and the run proves it in
both currencies:

- **Correctness.** F9 recorded the judge approving operator-identity escaping in
  one pass and flagging it in the next, on the same code. That is not
  inconsistency in the model — it is the *specified* behaviour of a reviewer
  built to have no memory of what it already accepted. The rule guarantees it.
- **Cost.** F21 measured >95% of each re-review payload as byte-identical to the
  pass before. Fresh context means paying full price for that 95%, six times on
  CHUNK-3.

The rule is stated once, globally, with a rationale that only covers one of the
places it is applied.

**Fix — scope the rule to where its rationale holds.** Amend `skills/judge` and
the prejudge SOUL:

> Fresh context is required **per chunk** — you must not inherit the
> implementer's framing. Within a bounce sequence for the same chunk, **continue
> the existing review session**: you are checking whether *your own* prior
> findings were addressed, and a reviewer who cannot remember its findings
> cannot tell a fix from a coincidence.

This is one paragraph that simultaneously fixes an accuracy bug and unlocks the
largest single token saving in the audit. It also finally uses
`deepseek-v4-flash` for what it is best at — a long-running session with a
growing stable prefix — instead of spawning a cold Opus per pass (F20).

---

### F33 — The verdict schema cannot express a re-review, so delta review is not merely unimplemented — it is inexpressible · `OPEN` · **high**

`forge.judge.v1` has: `chunk_id`, `pr`, `verdict`, `scores`, `findings`,
`nits_as_cards`, `spot_check_suggestion`, `judge_model`, `tokens_estimate`.

It has **no field linking a verdict to the verdict it supersedes**, no field
recording *which prior findings a repair addressed*, and no field marking a
dimension as *unchanged since last pass*. Fourteen bounce verdicts sit on this
board as fourteen unrelated opinions about the same six PRs. Reconstructing
which finding drove which repair required reading commit diffs by hand during
this audit — the board cannot answer it.

So F21's proposed delta review is not a prompt-engineering change waiting to be
written. **The data model forbids it.** A reviewer cannot say "dimensions 3–6
unchanged, I re-scored 1–2 against the 41-line repair" because the schema has
nowhere to put that sentence, and every downstream consumer (`/retro`, the
digest, `forgeboard-report`) would read a partial verdict as a full one.

**Fix — three additive fields, `.v1` stays compatible** (the schema's own rule is
*"additive evolution only … consumers ignore unknown keys"*):

```json
{
  "supersedes": "<run id of the prior verdict on this PR>",
  "findings_addressed": [
    {"finding_ref": "<prior finding id>", "status": "fixed | not-fixed | disputed",
     "evidence": "src/x.py:88 — assertion now on the returned payload"}
  ],
  "scores_carried_forward": ["scope_discipline", "debt_honesty", "doc_reconciliation"]
}
```

with `findings[]` gaining a stable `id`. Then a re-review's contract becomes:
*read the repair diff (`git diff <prior-head>..<head>`), resolve every prior
finding, re-score only the dimensions the repair touched, carry the rest.* For
CHUNK-3 that is under 5% of the payload per pass. It also produces the first
honest answer to the question `retro-metrics.md` is built to ask — *did the fix
fix it?* — at the level of individual findings rather than quarterly vibes.

---

## K. Duplication in the methodology layer

### F34 — The chunk protocol is maintained twice, and the cross-reference has already drifted · `OPEN` · **medium**

Two documents encode the same protocol:

- `skills/start-chunk` (69 lines) + `skills/end-chunk` (54) = **123 lines**
- `skills/forge-lane` §1–7 = **299 lines**

Both cover: orient on the contract, land on the branch, scenarios first,
`make check` as the definition of green, self-review the diff as a hostile
reader, `.forge/pr-body.md`, `gh pr create`, emit `forge.chunk.v1`, do not merge.
`docs/state.md` known gap #3 records that `start-chunk`/`end-chunk` *"may be
redundant — `open-questions.md` has asked since day one … The lane never invoked
them."* They have now never been invoked across three runs.

The duplication is managed by prose, and the prose is already wrong.
`skills/end-chunk/SKILL.md` §4:

> `forge-lane` **§5** already uses `.forge/pr-body.md`; these must not disagree.

`forge-lane` §5 is *"Verify it yourself"*. The PR step is **§6**. The
cross-reference that exists specifically to prevent drift has itself drifted —
which is the cleanest possible demonstration that ADR-0003 applies to skills as
much as to code. `make verify`'s `cli/` suite checks that every CLI *flag* named
in a skill exists; it does not check that a section a skill points at exists.

**Fix, in order of preference:**

1. **Delete `start-chunk`/`end-chunk`.** Three runs say the lane is the
   protocol. The interactive path can invoke `forge-lane` §§2–7 directly; the
   only genuinely interactive-only content is start-chunk §3's network
   assumption, which is four lines.
2. If they stay, extend `make verify cli/` with a cross-reference check: every
   `<skill> §<n>` reference must resolve to a heading that exists. Twenty lines
   of `grep`, and it would have caught this.

---

### F35 — Tier 1 is given tier 2's rubric and a narrower mandate, so it can only ever duplicate · `PARTLY FIXED 2026-08-05` · **critical**

The two tiers are not two tiers. They read the same PR, against the same rubric
file, scoring the same six dimensions:

- `skills/judge`: *"`rubrics/judge-rubric.md` — the scoring dimensions and
  verdict schema. **READ IT NOW**; it is the authoritative definition of your
  output."*
- `forge-prejudge.SOUL.md` §4: *"Scoring and verdict logic live in
  `~/.forge/rubrics/judge-rubric.md` — read it before scoring."*

The SOUL then narrows the mandate to three things — CI red, scenario theater,
scope creep — while still demanding a full six-dimension scored verdict.
Tier 1's *job* is a strict subset of tier 2's, its *output* is identical in
shape, and ADR-0007 gives it no authority tier 2 lacks. It is a second opinion
purchased before the first one.

The measurement is unambiguous. Same diffs, same rubric, same days:

| | Tier 1 (Opus) | Tier 2 (operator) |
|---|---|---|
| Passes | 17 runs, **7 readable** | 17 |
| Bounces | **0** | **12** |
| Mean d1–3 | ~3.00 | **1.88** |

A 1.1-point spread on identical inputs is not a filter and a judge; it is one
judgement with enormous variance, of which the expensive half is the wrong half.

**Fix — make tier 1 a program, which is ADR-0003 applied to review.** Everything
tier 1 is actually mandated to catch is decidable without a model:

| Tier-1 check | Mechanism | Model needed |
|---|---|---|
| CI green | `gh pr checks` exit code | no (already true, F5) |
| Branch name | regex | no (F7) |
| Diff within `Touches` | set difference on paths | no (F8) |
| Diff within size budget | `git diff --numstat` | no (F28) |
| Parent PRs merged | `jq '.mergedAt'` | no (F10) |
| Every `Then` step asserts on a value | AST walk of `tests/steps/*.py` | no (F14) |
| Scenario count matches contract | count `Scenario:` in the feature file | no (F13) |
| `forge.chunk.v1` is schema-valid | JSON Schema | no (F1, F2) |

That list is **higher recall than the model tier achieved** — it deterministically
catches F7 (which cost 4 PRs), F8, F10, F28 and F1, none of which tier 1 caught
in 17 attempts — at **zero tokens**, in seconds, with no variance. The assertion
check alone addresses F14, *the most-cited defect in every chunk*, better than
prose ever will: pytest-bdd steps that return a boolean instead of asserting are
a five-line AST visitor.

Tier 1 becomes `make prejudge PR=<n>` — a gate, which can only bounce, which is
exactly what ADR-0007 says tier 1 is. The saving is the full ~134k Opus tokens
per run (F20), and the accuracy goes **up**.

What is left for a model is what genuinely needs one: does this code do what the
contract *meant*. That is tier 2, it is the one component whose cost this audit
found justified (§G), and it should get the whole budget.

**PARTLY FIXED 2026-08-05, and the header says `PARTLY` on purpose.**

*Delivered.* ADR-0009 made tier 1 two stages and put the mechanical half in a
program: `scripts/prejudge.sh` runs `ci-state`, `branch-name`, `then-asserts`,
`scenario-count` at `block` and `touches`, `size-budget`, `real-source` at
`warn`, with the severity map set by backtesting all 11 PRs of the audited run
rather than written first. ADR-0010 made the surrounding protocol
`scripts/prejudge-review.sh`. The scorer's brief is now explicitly *disjoint*
from the gate's, which is the sentence this finding asked for
(`prejudge-review.sh:223–226`):

> Machines already checked what machines can check … a deterministic gate
> cleared this PR's CI state, branch name, scenario count, `Touches` boundary
> and assertion shape before you were called. Do not spend a line re-deciding
> any of them. Look for the one thing no program can see.

*Not delivered, and not deliverable yet.* The model call still exists, still
reads `~/.forge/rubrics/judge-rubric.md`, and still emits the same
six-dimension shape. Whether it earns its latency is ADR-0011 / D9.5's
experiment, `docs/open-questions.md` carries the pre-committed decision rule,
and this finding is not licence to pre-empt it.
`prejudge/gate-is-a-stage-not-a-replacement` pins exactly that: no model in the
gate, and the scorer still there.

*Two of the eight checks in the table above were wrong.* F52 measured it:
`parents-merged` is a **dispatcher** check and is structurally incapable of
firing at PR time, and `ci-state`'s recall cannot be established by backtest.
Six checks, not eight — and per F56 the `no-assertion` walker F35 singles out as
"a five-line AST visitor" found **nothing at all** across 11 PRs, while the
recall actually delivered for F14 comes from a tautology detector this finding
never mentions. The conclusion survives; the specific mechanisation it proposed
did not survive contact.

---

### F36 — The stale Codex pin is in a load-bearing skill body, not just `state.md` · `OPEN` · **medium** *(extends F22)*

F22 recorded that `docs/state.md` documents the pin as `gpt-5.6-sol xhigh` while
`~/.codex/config.toml` reads `gpt-5.6-terra` / `high`. The same stale claim is
also in `skills/forge-lane/SKILL.md` §4:

> Model: the pin lives in `~/.codex/config.toml` (`gpt-5.6-sol`, reasoning
> `xhigh`). Override per card with `-m <model>`; record whichever you used in
> the completion metadata.

This one matters more than the `state.md` copy, because the lane skill is read
by every lane run — it is the sentence that tells the driver what it is running,
and it is wrong. It also asks the driver to *"record whichever you used"*, which
is F30's problem again: the driver records what the skill told it, not what the
process actually loaded.

**Fix.** Delete the parenthetical from both files and have the lane read the
live value (`codex --version` / the config) into `forge.chunk.v1`. A pin
duplicated into prose is a pin that will be wrong; a pin read at runtime cannot
be. Add it to `make verify config/`, which already reads live profile config for
exactly this reason.

---

## L. The upgrade, as one design

Sections H–K describe eleven findings that reduce to four moves. Sequenced by
dependency, with the token effect of each.

**Move 1 — Instrument before optimising.** F30 + F27.
Real `usage` from `--output-format json`; `scripts/metrics.sh` computing the
retro numbers in SQL. *Effect: none directly — but every number below is
unfalsifiable without it, and it retroactively detects F1.* **Do this first.**

**Move 2 — Demote tier 1 from a model to a gate.** F35 + F20 + F7 + F8 + F10 +
F28 + F14 (partially) + F5.
`make prejudge PR=<n>`: CI state, branch regex, `Touches` set difference, size
budget, parent `mergedAt`, scenario count, assertion AST walk, chunk-envelope
schema validation. Bounce-only, deterministic, board-native.
*Effect: −134k tokens/run, four fewer wasted PRs, five fewer wasted dispatches,
and higher recall than the tier it replaces.*

**Move 3 — Make review incremental and continuous.** F32 + F33 + F21 + F15.
Scope "fresh context" to the chunk, not the pass. Add `supersedes` /
`findings_addressed` / `scores_carried_forward` to `forge.judge.v1`. One
`deepseek-v4-flash` session per bounce sequence with a monotonically growing
stable prefix; re-reviews read the repair diff, not the whole diff.
*Effect: the ~60–65% of tier-2 tokens F21 identified, plus it removes the
oscillation in F9 rather than tolerating it.*

**Move 4 — Derive, don't assert.** F29 + F26 + F23 + F2 + F1.
Verdict computed from scores by a shared function; one canonical `forge.chunk.v1`
shape with a real JSON Schema; `reason_class` as an enforced prefix on the
string the API actually stores. `make verify` validates live board metadata
against all three.
*Effect: no direct token saving; it is what makes the other three trustworthy,
collapses F23's 230 hand-rolled lines, and closes the critical finding.*

**The through-line.** The Forge's founding insight — *skills persuade, gates
enforce* — is correct, was proven at L2, and was then not carried upward as the
system grew. Every layer added after the template re-solved a decidable problem
with a language model. The upgrade is not new machinery; it is applying the
Forge's own best idea to the parts of the Forge that were built after it was
written down.

---

## M. Correction — the cost model this audit assumed was wrong

*Third pass, 2026-07-30, after measuring the auth topology on the mini instead
of inferring it. Sections B, F and L were written against a cost model that
counted tokens without asking who pays for them. This section corrects it and
supersedes the parts of F20/F21 that follow from the error.*

### The auth topology, measured

| Role | Engine | Auth | Marginal cost |
|---|---|---|---|
| Lane driver | `deepseek/deepseek-v4-flash` via Hermes profile | **metered API key** | **real dollars** |
| Prejudge driver | `deepseek/deepseek-v4-flash` via Hermes profile | **metered API key** | **real dollars** |
| Implementer | `codex exec` | OAuth (ChatGPT subscription) | none |
| Tier-1 scorer | `claude -p --model opus` | OAuth (Claude subscription) | none |
| Tier-2 judge | operator in Claude Code | OAuth (Claude subscription) | none |

`~/.hermes/profiles/{forge-prejudge,forge-codex-lane}/config.yaml` both read
`model.default: deepseek/deepseek-v4-flash`. That is the only metered path in
the system. Everything the audit called "expensive" — Opus at tier 1, the
operator's tier-2 sessions — is subscription-covered and costs **nothing at the
margin**.

**What this breaks.** F20 is titled *"the cost structure is inverted: Opus
rubber-stamps, cheap models judge"* and recommends moving tier-1 scoring
in-profile to `deepseek-v4-flash`. Under the real topology that recommendation
**moves work from a free OAuth path onto the only metered one.** It is exactly
backwards. The same error is latent in F21 and in §L Move 2's framing.

**What survives.** F20's *observation* is untouched and still critical: tier 1
bounced 0 times in 17, so its output is worthless regardless of who pays. F35's
conclusion — that tier 1 should be a deterministic program — is strengthened,
not weakened, because a program costs nothing on *either* axis. What changes is
the reason: tier 1 should be deleted because it does not discriminate, and the
residual model judgment should stay **on the OAuth CLIs**, not be migrated to
the metered profile.

**The corrected objective function**, and the one every later slice optimises:

> Minimise **metered Hermes API tokens**. Treat OAuth CLI usage (`codex exec`,
> `claude -p`) as free at the margin, bounded by subscription quota and latency
> rather than dollars. Spend the cheap metered driver on *driving* — tool calls,
> board lifecycle, protocol — and never on *reading*.

---

### F37 — The metered driver reads the 127 KB diff into its own context, then pays a second time to send it somewhere free · `FIXED 2026-07-31` · **critical**

This is the largest metered cost in the system, and the audit missed it by
counting reviewer tokens instead of driver tokens.

`hermes/profiles/forge-prejudge.SOUL.md` step 3, addressed to the driver
(deepseek, metered):

> **3.** Read the diff and the contract, nothing more:
> ```
> gh pr diff "$pr_url" < /dev/null
> ```

Then step 4 tells the same driver to write the rubric, contract **and diff** to
`$prompt_file` and hand it to `claude -p` (OAuth, free).

So the diff is paid for **twice**: once as metered deepseek input tokens when
the driver executes step 3 and the output lands in its context, and once as
free OAuth tokens when Claude scores it. The largest saved prompt in
`/private/tmp` is **127,738 bytes ≈ 32k tokens** (F15). Across 17 prejudge runs
plus 22 lane runs, the driver has been metered on diff bytes it never needed to
see — it is not the scorer.

The root cause is a role confusion in the SOUL itself. Its *"What you are
looking for"* section instructs the driver to hunt for scenario theater and
scope creep — but the driver does not score anything; `claude -p` does. The
SOUL addresses two different agents in one voice, and the driver acts on
instructions meant for the scorer.

**Fix (one character, essentially).** The driver must move bytes, never read
them:

```bash
# step 3 — never render the diff into the driver's context
gh pr diff "$pr_url" >> "$prompt_file" < /dev/null || exit 1
wc -c < "$prompt_file"        # the driver sees a byte count, not a diff
```

and split the SOUL's voice explicitly: everything under *"What you are looking
for"* belongs in `$prompt_file` as instructions **to the scorer**, not in the
driver's protocol. Add a `lane/driver-never-reads-the-diff` verify case beside
the existing `lane/driver-never-authors-diff`.

Apply the identical rule to `forge-lane`: the lane driver should never `cat` the
Codex transcript or the full `git diff` into its own context. §5's hostile-reader
step is the one place it genuinely must look — and that is an argument for
bounding diff size (F28), not for reading unboundedly.

**FIXED 2026-07-31 — slice S2; carried into `scripts/prejudge-review.sh` by
ADR-0010.**

```
prejudge-review.sh:252   gh pr diff "$PR_URL" >> "$prompt_file" < /dev/null
```

and the SOUL's two voices are split: everything under *"What you are looking
for"* is now the pinned scorer brief inside the prompt file, addressed to the
scorer, not to the driver.

This is one of the few findings whose fix is **measured rather than asserted**.
`prejudge/review-never-prints-the-diff` replays a recorded 63,164-byte patch and
observes that 63,164 bytes reach the prompt file while the driver sees 2,599
(F63 records why that matters: the old check was a `grep` for the sentence
promising it). `lane/driver-never-reads-the-diff` pins the redirect itself.
The comment above the code names the reasoning so a later editor cannot undo it
by accident — *"sampling it with `head` or a summariser is the same purchase at
a discount."*

---

### F38 — `claude -p` supports cached session continuity, which makes delta review free on the OAuth path · `OPEN` · **high** *(supersedes the mechanism half of F21/F33)*

F21 assumed cache reuse required moving review to `deepseek-v4-flash`. Measured
on the mini, 2026-07-30, that assumption is unnecessary — the OAuth Claude CLI
does it natively.

**Probe 1** — `--output-format json` and `--json-schema` compose cleanly
(exit 0). The envelope carries far more than the audit hoped for:

```
usage.input_tokens · usage.output_tokens
usage.cache_creation_input_tokens · usage.cache_read_input_tokens
total_cost_usd · modelUsage · session_id · structured_output
```

`structured_output` returns the schema-valid object already parsed, so the
SOUL's `.result | fromjson` dance is unnecessary. `total_cost_usd` is a real
number, not an estimate — **F30's fix is strictly better than F30 proposed**:
the Forge can record actual cost, not a token guess.

**Probe 2** — `--resume <session_id>` preserves both the schema and the cache:

| pass | `cache_creation` | `cache_read` | output |
|---|---|---|---|
| 1 (cold) | 19,480 | **0** | 163 |
| 2 (`--resume`) | 1,011 | **19,480** | 110 |

The entire prior context was served from cache. This is the mechanism F32 and
F33 need, available today, on a subscription-covered engine, with no model
change and no metered spend.

**Consequence for the design.** A bounce sequence becomes: score cold once,
capture `session_id` into the verdict metadata, and every re-review runs
`claude -p --resume <sid>` with **only the repair diff** as new input. Prior
findings are in the session, so the reviewer remembers what it already
accepted — which is the accuracy half of F32 (oscillation) solved by the same
change as the cost half. `session_id` must therefore be added to the fields F33
proposes for `forge.judge.v1`.

---

### F39 — The Codex pin was changed again on 2026-07-30; this is the F22 hazard, handled correctly this time · `RESOLVED-BY-RECORD` · **medium**

`~/.codex/config.toml` changed from `gpt-5.6-terra` / `high` to **`gpt-5.6-sol`
/ `high`** on 2026-07-30 at operator instruction. Previous value backed up at
`~/.codex/config.toml.bak-20260730`.

F22 exists because the previous pin change (`sol` → `terra`) happened silently,
mid-run, between CHUNK-2 and CHUNK-3 — and CHUNK-3 was simultaneously the first
`terra` run, the largest chunk, and the 5-bounce chunk, making all three
uninterpretable as evidence. **This entry is what F22 says should have existed.**

Live hazard to carry forward: **CHUNK-6 is still open at PR #11 with bounce
card `t_d13daaf6` blocked.** Its next run will be the first under `sol`. Do not
read a change in its behaviour as evidence about the repair, the contract, or
the bounce budget — the model changed underneath it. Either note this on the
card before resuming, or finish CHUNK-6 under the old pin.

Both `docs/state.md` (which says `sol` / `xhigh`) and
`skills/forge-lane/SKILL.md` §4 (same) are now wrong on the effort level only.
The durable fix remains F36's: read the pin at runtime, stop duplicating it
into prose.

---

### Revised Move 2 and Move 3

Superseding the versions in §L.

**Move 2 — delete tier 1's model call; do not relocate it.**
`make prejudge PR=<n>` (deterministic, §F35's table) becomes the whole of tier
1. The residual judgment it cannot make is *not* re-hosted on the metered
profile — it is deferred to tier 2, which is OAuth and already does it better
(1.88 vs 3.00 means tier 2 is the only tier producing signal). *Effect: removes
a filter that bounced 0 times in 7 readable verdicts, adds deterministic checks with higher recall, and touches the
metered path only by making the driver's job smaller.*

**Move 2b (new, and the biggest metered saving) — the driver moves bytes, never
reads them.** F37. Redirect every `gh pr diff` / transcript / large `git diff`
straight to a file; the driver sees byte counts and exit codes. Split the
prejudge SOUL's two voices. *Effect: removes ~32k metered input tokens per
review-bearing run, the single largest line item in actual dollars.*

**Move 3 — incremental review on `claude -p --resume`.** F38 + F32 + F33.
Cold-score once per chunk, persist `session_id`, re-review the repair diff only.
*Effect: the ~60–65% reduction F21 identified, achieved on the OAuth path at
zero metered cost, and it removes F9's oscillation as a side effect.*

The deepseek long-session idea from F21 is **not** adopted for review. It remains
correct for what it already does — driving the lane protocol across long
unattended runs, where its caching and cheapness are the right trade and the
derailment risk is bounded by §5's verification. Review does not need it,
because review has a free cached engine.

---

### F40 — The orchestrator and the implementer shared one working tree, with no isolation · `PARTLY FIXED 2026-08-06` · **medium**

Measured 2026-07-30 during slice S1. The implementing session ran in
`/Users/goonlab/dev/forge` — the main checkout — on branch
`slice/metrics-command`. It committed `docs/audit-forgeboard-2026-07-30.md`
unchanged as `1f79839`, per its contract. The orchestrator then appended §M
(F37–F39) to the same file on disk, producing a 251-line uncommitted delta
inside the implementer's working tree. The next `git add -A` would have swept an
unrelated audit revision into a metrics commit under a metrics commit message.

This is F1's defect class applied to the Forge's own process: **two writers, one
mutable artifact, no canonical owner and no versioning.** Nothing detected it;
it was found by inspecting `git status` for an unrelated reason.

The Forge already solved this for the work it automates and did not apply the
solution to the work it does by hand. Chunk cards get
`<repo>/.worktrees/<task-id>`, created by the dispatcher *before* the worker is
spawned (`forge-lane` §2). Slices driven by a human operator get the main
checkout, because nobody wrote that rule down for them.

**Second symptom, same root, same day.** The slice filed its three new findings
as F37–F39 — numbers the orchestrator had already spent in this very section,
on a revision that had been reverted out of the implementer's tree so it could
not be seen. Two disjoint F37s existed until the slice renumbered to F41–F43 at
review. Nothing would have caught it: the ledger has no allocator, and
`make verify` does not read it.

**Fix.** Every slice runs in its own worktree, exactly as a chunk card does:

```bash
git worktree add ../forge-slices/<slice-id> -b slice/<slice-id> main
```

The orchestrator keeps the main checkout and can edit the audit ledger freely
while a slice runs. Add it to `docs/operator-guide.md` alongside the manual
worktree sweep (F18), and state the ownership rule explicitly: **the audit
ledger is the orchestrator's file; a slice may read it and commit it once as a
source document, and must never be the only writer.**

**PARTLY FIXED 2026-08-06.**

*The second symptom is closed.* The ledger now has an allocator — see
**F-number allocation** near the top of this file. Every track owns a disjoint
block, a number is spent in the PR that writes the finding rather than reserved,
and an exhausted block extends the table in the same PR. That is the control
whose absence produced two disjoint F37s.

*The first symptom is closed in practice and not in writing.* Every slice since
2026-08-04 has run in its own worktree, including this one — and F49 exists
because the suite had to be taught that a linked worktree is where the work now
happens. But `docs/operator-guide.md` still carries no slice-worktree rule and
no ownership sentence for this file, so the practice is a habit rather than an
instruction a fresh session would find. That is what is left, and it belongs
with F18's sweep in the same guide.

**The allocator is prose, and prose is not a gate.** `make verify` does not read
this ledger, so nothing executes the block boundaries. Stating that plainly is
ADR-0003's own rule applied here: the honest claim is a convention two
orchestrators can follow, not an enforcement.

---

## Priority order for the follow-up passes

Sequenced by the four moves in §L **as corrected by §M**, which is dependency
order, not severity order. Slice labels are the orchestration units actually
being implemented; F-numbers are what each closes.

**S1 — Instrument · `SHIPPED` 2026-07-30, PR #3**

1. ~~**F27 + F3**~~ — `scripts/metrics.sh` / `make metrics`: the three retro
   numbers in SQL, wired into `/retro` step 1 and a `metrics` verify group.
   93 lines of bash over 130 of SQL. **It found three errors in this audit
   within one slice** (F41, F42, F44) and every one of them was a number this
   document had produced by prose rather than by query. F27 is now the
   best-evidenced finding in the file, and the evidence is the audit itself.

**S2 — The prejudge SOUL cost slice (one file, one bootstrap, one live run)**

2. **F37** — the driver moves bytes, never reads them. Redirect `gh pr diff`
   into `$prompt_file`; split the SOUL's two voices so scorer instructions stop
   being addressed to the driver. **One line, and the largest real-dollar saving
   in the document** (~32k metered tokens per review-bearing run).
3. **F30** — capture the real envelope from `claude -p --output-format json`:
   `total_cost_usd`, full `usage` including `cache_read_input_tokens`,
   `structured_output`, and **`session_id`** (which S6 requires).

**S3 — `make prejudge` in shadow mode (repo-only, free)**

4. **F35 + F7 + F8 + F10 + F28 + F5 + F25** — the deterministic tier-1 gate.
   Runs **alongside** the model tier and logs agreement; gates nothing yet.
   Note F44: the model tier's historical agreement data is a third the size this
   audit assumed, so the shadow run is now the *only* usable comparison.
   Before F28's size budget becomes a gate, decide what counts against it —
   S1 came in at 741 lines of which 193 were fixture and 99 were the metrics
   doc. A budget that counts fixtures will be routed around immediately.

**S4 — Delete tier 1's model call (do not relocate it)**

5. **F35 + F20 + F4**, as corrected by §M and F44. Tier 1 becomes the S3 gate;
   residual judgment is **deferred to tier 2 (OAuth)**, not migrated to the
   metered deepseek profile. Requires S3's agreement data.

**S5 — Derive, don't assert (repo-only, free)**

6. **F29** — verdict becomes a computed field; the model emits scores and
   evidence only.
7. **F1 + F2 + F23 + F44** — one canonical `forge.chunk.v1` shape, a real JSON
   Schema, and `make verify` validating **every completed run's metadata against
   the schema its profile is contracted to emit**, failing on a run that emits
   none. F1 and F44 are the same defect on two different producers.
8. **F26** — drop `forge.block.v1`; enforce a `reason_class:` prefix regex, add
   `gate-misrouted`. S1 measured the damage: `(unclassified)` ×27 against
   `failing-prereq` ×8.

**S6 — Incremental review on `claude -p --resume`**

9. **F38 + F32 + F33 + F21 + F15** — scope "fresh context" to the chunk, not the
   pass; persist `session_id`; add `supersedes` / `findings_addressed` /
   `scores_carried_forward`. *Measured mechanism: 19,480 tokens served from
   cache on resume.*
10. **F6 + F11** — bounce budget, `fix`-only verdicts become
    `approve-with-nits` + cards, one pinned reviewer model.

**S7 — Hygiene**

11. **F43** — `make verify` exits 1 on the operator's own machine and has for
    some time; the `config/` group should `skip` a sentinel assignee, not fail
    it. **Promote this above the rest of S7:** a suite that is already red
    cannot report a new failure, which silently disarms every gate S3–S5 add.
12. **F31** — operator touches per merged chunk. S1 emits it (11 = 2 comments +
    9 unblocks); it now needs a column in `retro-metrics.md`.
13. **F40** — every slice runs in its own worktree; the audit ledger is the
    orchestrator's file, and finding numbers need an allocator.
14. **F34 + F36 + F22 + F39** — cross-reference check in `make verify cli/`;
    read the Codex pin at runtime rather than duplicating it into two prose
    files that are both currently wrong on the effort level.
15. **F24 + F12**, then F19 (move the repo out of `/private/tmp`), F17, F16, F18.

---

## Corrections this audit owes the Forge's own docs

- ~~`docs/state.md` "Proven": *"Both metadata schemas populate — complete on
  the real cards"*~~ — **corrected 2026-08-06** (F2). The historical chunk
  objects are recorded as incomplete; the replacement contract remains
  lifecycle-unproven.
- `docs/state.md` "Not proven": *"A genuine idea through the whole lifecycle"* —
  now largely **proven** (5/6 chunks merged), with F1 as the caveat.
- `docs/retro-metrics.md` — **no row exists** for the largest run to date. The
  row it should carry: bounce rate **0.67 (4/6)** counted at tier 2 (0.00 (0/17)
  as currently defined at tier 1), mean d1–3 **1.88**, `reason_class`
  `failing-prereq` ×5 (F10) — the first row in the file whose mean score is not
  3.00, which is what the 2026-07-28 watch item asked for.
- `README.md` VERIFY list: *"The bounce path"* is checked `[x]` on n=1. It has
  now run 12 times; the finding is that it works mechanically and does not
  converge (F6).
- ~~`docs/state.md` "Proven": *"Branch protection is a real merge gate — a red or
  unreviewed merge is refused by GitHub, not by prose"*~~ — **corrected
  2026-08-06** (F79). Measured true on `wielas/forgeboard-report` (public,
  `enforce_admins: true`) and **false on `wielas/forge` itself**, which is
  private on a free plan and returns 403 for both protection and rulesets. The
  row now names where it was proven and says it does not hold here. `CLAUDE.md`
  and `Makefile:44` carried the same claim as an unconditional statement and now
  state the condition instead.

---

## Ledger additions from the F27 remediation slice (`scripts/metrics.sh`)

Appended 2026-07-30 while implementing F27. Each was found by running the
queries rather than by reading, which is the point.

### F41 — This audit's own tier-2 mean is wrong, and only the number with a query attached survived · `FIXED 2026-07-30` · **medium**

Three places in this document report mean tier-2 d1–3 as **1.90** (§"The run, in
numbers", F3, and the parenthetical in F27's SQL block). The value is **1.88**:

```
SELECT SUM(spec_fidelity), SUM(scenario_integrity), SUM(architectural_conformance), COUNT(*)
-- 28 + 31 + 37 = 96 over 17 verdicts × 3 dimensions = 51 → 1.88235…
```

No null scores, no excluded rows, no rounding path that reaches 1.90 (averaging
per-verdict means first still gives 1.88). Every *board-lifetime* figure in F27
reproduces exactly — 30 verdicts, 15/1/14, mean 2.31, 0 flat and 22 nested
envelopes — and those are the ones F27 published with an executed query beside
them. 1.90 appears only in prose.

**This is F27 happening to the document that reports F27**, one day early and at
its own expense, and it is the strongest available evidence for the finding:
the numbers a model computes by reading are wrong at a rate you cannot predict
from how confident the surrounding text sounds. Corrected in
`docs/retro-metrics.md`; the audit body is left as written so the error stays
legible.

**FIXED 2026-07-30.** Verified in the tree: `docs/retro-metrics.md:306–309`
carries the correction and the reason — *"the number that survived came with an
executed query attached; 1.90 was asserted in prose beside it."* The three
prose occurrences in this document are still 1.90, deliberately, per the
paragraph above. Do not "fix" them; that would delete the evidence.

### F42 — Kanban timestamps are true epoch, not local-epoch · `FIXED` · **low**

Working notes and this slice's contract both warned that kanban timestamps are
local-epoch. They are not. `hermes_cli/kanban_db.py` writes `int(time.time())`
throughout, and `MAX(created_at)` equals the database file's own mtime to the
second on three separate boards.

The trap is real but sits on the other side of the boundary: `--since` is a
**local calendar date**, and `strftime('%s','2026-07-29')` is UTC midnight —
wrong by the UTC offset, silently, and in the direction that quietly drops or
adds the first hours of a run. `strftime('%s', <date>, 'utc')` is the conversion
that makes a day boundary mean the operator's midnight.
`scripts/metrics.sh` does that and says why.

### F43 — `make verify` has been red on the operator's own machine, and nobody noticed · `FIXED 2026-08-04` · **medium**

`./scripts/verify.sh config` fails six cases on the live host, on `main`, before
this slice touched anything:

```
config/{terminal-timeout,write-approval,external-dirs}/forge-operator
config/{terminal-timeout,write-approval,external-dirs}/forge-operator-handoff
```

Both names come back from `hermes kanban assignees` and neither has a Hermes
profile, because neither is *supposed* to — `forge-operator-handoff` is the
deliberately non-spawnable sentinel the tier-2 hand-off parks on
(`lane/prejudge-tier2-card-is-sticky`), and `forge-operator` is the ghost
assignee from the rung-4 row in `docs/retro-metrics.md`. The `config/` group
reads assignees and assumes every one is a profile it can interrogate.

The consequence is the one that matters: **`make verify` has been exiting 1 on
this machine continuously**, so the suite's headline result carries no
information and a seventh, real failure would land in a list already red. A
suite that cries wolf gets switched off — `verify.sh` says exactly this in the
comment above its own `skip` helper, about a different case.

**Fix (out of scope here, and small):** the `config/` group should judge
assignees that resolve to a profile, and `skip` — with the sentinel named — the
ones that deliberately do not exist. Not fixed in this slice: it is the
`config/` group's contract, not the `metrics/` group's.

**Fixed 2026-08-04 (S3 step 0).** `hermes kanban assignees --json` already
carries an `on_disk` boolean; the group now filters on it and emits one `skip`
per ghost, naming it. The six failures became two skips.

The count was wrong, and the direction it was wrong in matters. The suite was
red for **three** independent causes, not one: these six, plus F49 (four more,
in any worktree) and F50 (one, on `main`, since the commit that resolved F45).
F43's own thesis — that a red suite hides the next failure — was demonstrated by
F43's own write-up, which recorded a third of the redness.

### F44 — More than half of all tier-1 runs left no readable verdict · `CONTRACTED — AWAITING LIVE PROOF` · **high**

Found while validating the F27 slice, by running the query the slice made
possible. The board's own producers, board lifetime:

```sql
prejudge cards                                        27
prejudge runs                                         28
runs carrying canonical forge.judge.v1                13
runs whose metadata has no $.schema key at all        15
```

and scoped to the `forgeboard-report` run window (`started_at >= 2026-07-29`):

```sql
prejudge runs 17 · canonical verdicts 7 · bounces 0
```

**Every tier-1 figure in this audit was computed over a set that does not
exist.** §"The run, in numbers" reported *"Tier-1 bounces: 0 out of 17"*, and F4
built the rubber-stamp case on 17 uniform approvals. The measured statement is
**0 bounces out of 7 readable verdicts, with 10 of 17 runs emitting nothing
countable.**

The conclusion survives and arguably hardens — a tier that produces no readable
verdict 59% of the time is worse than one that rubber-stamps, because its
output cannot even be audited — but the *evidence base* was a third the size
this document claimed. F4, F20 and F35 should be read with that denominator.

This is **F1's defect, one layer up**: the same board, the same two days, a
producer writing metadata in a shape its consumers cannot read, undetected
because nothing ever queried it. F1 is the lane's chunk envelope; this is the
prejudge profile's verdict envelope. Both are closed by S5's schema validation
against live board metadata, and both would have surfaced on day one had
`scripts/metrics.sh` existed — which is now the third independent vindication
of F27 in a single slice.

**Fix.** S5 extends `make verify` to validate every completed run's metadata
against the schema its profile is contracted to emit, and fails on a run that
emits none. Until then, treat every tier-1 count in this document as an upper
bound.

**Contract status, 2026-08-06.** The fix above is implemented as a contract and
proven on fixtures. `rubrics/run-metadata-contract.json` names, per producing
profile, the only completed-run schemas it may emit;
`metadata/profile-contract-is-explicit` asserts that mapping exists for every
producer, `metadata/rejects-profile-schema-mismatch` fails a valid envelope from
the wrong producer, and `metadata/rejects-missing-metadata` fails the exact shape
this finding measured — a completed producer run carrying null metadata. A
recorded PR runs through the **real** gate producer and that output is validated,
rather than a parallel fixture being hand-copied.

**Still `CONTRACTED`, not `FIXED`, and this finding is the clearest case for
why.** What F44 measured is not a schema that was missing; it is a producer that
silently stopped emitting one, 10 times in 17, clustered late, with nothing
looking. A fixture cannot fail that way. The proof is a snapshot-based sweep of
one genuine run's completed rows, scoped to a recorded run-start, reporting
`valid / invalid / unjudged` separately — `unjudged` is not `valid`, and
`scripts/validate-metadata.py` already separates exit 1 from exit 2 for exactly
that reason. Until that sweep runs, every tier-1 count in this document remains
an upper bound.

F1 and F44 are one defect on two producers and close together or not at all.

---

## Ledger additions from the prejudge cost slice (S2, F30 + F37)

Appended 2026-07-31 while implementing F30 and F37. Both were found by reading
a real `claude -p` envelope instead of the one this audit imagined, in a
hand-driven review of merged PR #9 on `wielas/forgeboard-report`.

### F45 — `tokens_estimate` measures almost nothing on `claude -p`, because the prompt is billed to the cache and not to `input_tokens` · `RESOLVED 2026-08-03` · **medium-high**

F30 is fixed: `tokens_estimate` is now stamped from the harness envelope rather
than invented by the model. But the `[DEFAULT]` that governs it — *input +
output, excluding cache reads, so the number stays comparable period over
period* — turns out to exclude the prompt itself. Measured on the S2 probe, a
66,189-byte prompt of which 63,164 bytes were diff:

```
prompt_file                    66,189 bytes
usage.input_tokens                     10      <- the whole prompt is not here
usage.cache_creation_input_tokens  55,121      <- it is here
usage.cache_read_input_tokens     186,468
usage.output_tokens                 8,513
tokens_estimate (input+output)      8,523      <- 99.9% of it is output
total_cost_usd                   0.878421
```

Claude Code caches the prompt by default, so `input_tokens` counts only what
fell outside a cache block — here, ten tokens. **`tokens_estimate` is now
effectively an output-token count**, and moves with verdict verbosity rather
than with review size. A 127 KB diff and a 6 KB diff produce nearly the same
figure.

Three consequences, none of them fixed by this slice:

1. **The old series and the new one are not comparable**, and not only because
   one was invented. F15b's table — 386,300 tier-2 tokens, CHUNK-3's 252,000,
   tier-1's ~7,900 average — reads as prompt-inclusive review cost. The
   post-fix field does not count the prompt at all. Any line drawn from those
   figures to a post-2026-07-31 one compares two different quantities.
   (`docs/retro-metrics.md` publishes no token series, so nothing there is
   invalidated; the exposure is F15b and everything derived from it.)
2. **The `[DEFAULT]`'s own justification is inverted on this engine.** Cache
   reads were excluded to keep a cold pass and a resumed pass comparable; the
   effect is that neither pass counts its input at all.
3. **`cost.total_cost_usd` is the only scalar in the verdict that tracks review
   size**, which is an argument for `/retro` keying off `cost` and treating
   `tokens_estimate` as a compatibility field.

Not changed here, because the `[DEFAULT]` was given and silently redefining the
field is precisely the failure mode this slice exists to stop. The decision
belongs to whoever owns `docs/retro-metrics.md`: either redefine
`tokens_estimate` as `input + cache_creation + output` and mark the series
break, or retire the scalar and report `cost`.

**Ruling, 2026-08-03 — redefine, do not retire.**

Reproduced independently before deciding. A ~30-byte prompt returned
`input_tokens 10 / cache_creation 19,480`; a 131 KB prompt returned
`input_tokens 9 / cache_creation 50,759`. Content moves `cache_creation`
one-for-one and leaves `input_tokens` flat at ~9. The `[DEFAULT]` was wrong and
the slice was right to flag it rather than silently redefine it.

**`tokens_estimate = input + cache_creation + output`** — tokens new to the
model on this call. Three reasons, in order of weight:

1. **Excluding `cache_read` is the load-bearing part.** It double-counts
   multi-turn re-reads, and including it would make a *resumed* session score
   higher than a cold one — inverting the exact signal S6's delta review exists
   to produce. A metric that punishes the optimisation it is meant to measure is
   worse than no metric.
2. **Retiring it costs a `.v2`.** The field is `required`; removing it breaks
   the schema's own additive-evolution rule for no gain, since the corrected
   formula is well-defined and cheap.
3. **Tokens are work; price is work × tariff.** A provider price change would
   break a cost series silently, with no marker — which is precisely the failure
   `retro-metrics.md` exists to prevent. Tokens degrade more honestly.

**`cost.total_cost_usd` is recorded but is *not* promoted to a retro headline
number.** On the OAuth path it is a notional price nobody pays. §M established
that the objective function is **metered Hermes API spend**, and neither
candidate in this finding measures that side at all — see F48, which is the
finding this decision actually surfaced.

**Series break: 2026-08-01.** Verdicts before that date carry `input + output`,
which on `claude -p` measured output alone. The break is marked in the schema's
`tokens_estimate` description and here. No row of `retro-metrics.md` has ever
carried a token figure, so no published series is affected — only stored card
metadata, and only for the S2 probe run.

Applied 2026-08-03: one line in `forge-prejudge.SOUL.md` step 4, plus the schema
description. F30's other stamped fields are unaffected.


### F46 — `judge_model` is still an alias, and a two-model bill is recorded as one number · `OPEN` · **low-medium**

F30's fix stamps `judge_model` from the observed `--model` argument, on the
correct principle that the model cannot report its own id. The envelope shows
that the CLI argument is not the best available source either:

```
modelUsage: ["claude-haiku-4-5-20251001", "claude-opus-5"]
judge_model as stamped: "opus"
```

Two things follow. The alias `opus` resolved to **`claude-opus-5`**, and the
exact id is sitting in the envelope we already parse — so provenance can be
recorded exactly rather than as the alias the operator happened to type. And
the run billed **two** models: the harness used `claude-haiku-4-5` alongside
the scoring model, and `total_cost_usd` aggregates both. `modelUsage` carries
the per-model split, and this slice discards it.

This is F30's own defect class one level finer: we stopped trusting the model
about itself and started trusting the *argument*, when the harness reports the
resolved truth. Deliberately not fixed here — stamping the resolved id changes
what `lane/prejudge-judge-model-is-observed` asserts, and that case should be
rewritten on purpose rather than as a side effect of a cost slice.
### F47 — `scripts/metrics.sh` fails on a quiescent board, which is exactly when a retro runs · `FIXED 2026-08-04` · **high**

Found while reviewing S2, by running S1's own deliverable and watching it die.

```
$ ./scripts/metrics.sh forge-ladder
Parse error near line 3: unable to open database file (14)
```

then succeeding on retry, with nothing changed. Reproduced deterministically:

| board db | `-shm` sidecar | `sqlite3 "file:…?mode=ro"` |
|---|---|---|
| WAL mode | present | works |
| WAL mode | **absent** | **`unable to open database file (14)`** |

Every Hermes board is `journal_mode=wal`. A **read-only connection cannot create
the `-shm` file that WAL requires**, so `mode=ro` succeeds only while some other
process happens to be holding the board open. The failure window is the board at
rest — no dispatcher, no worker, sidecars checkpointed away. **That is the state
a board is in when someone sits down to run `/retro`.**

The bug is intermittent in the worst direction: it works every time you test it
by hand right after touching the board, and fails when the tool is used for its
actual purpose. Nothing detected it; it surfaced because a review happened to
run the command in the wrong second.

**Fix — the pattern already exists in this project's own output.**
`forgeboard-report`'s `hermes.py` snapshot-copies the database *and its
sidecars* to a temp directory, fingerprints them before and after, and reads the
copy. That is both the fix for this defect and the fix for the consistency
問題 `mode=ro` never solved: a report assembled from a board being written
underneath it is torn regardless of whether it opens. The product the Forge
built solved this correctly; the Forge's own script did not, having been given
`[MEASURED] Open read-only: mode=ro` by an orchestrator who had not tested it
against a quiescent board.

That last clause is the transferable lesson, and it belongs beside F41 and F42:
this is the **third** `[MEASURED]` tag in this audit that turned out to be an
inference dressed as a measurement.

---

### F48 — The metered half of the system has no cost telemetry, and no slot to put it in · `OPEN` · **critical**

The finding F45's decision surfaced, and the largest remaining blind spot.

§M established the objective function: `codex exec` and `claude -p` are OAuth
and free at the margin; the `deepseek-v4-flash` Hermes profiles are the **only
metered path**. S2 then instrumented `claude -p` beautifully — real `usage`,
real `total_cost_usd`, `session_id`, all stamped from the harness.

**All of it measures the free engine.** Checked on the live board:

```sql
PRAGMA table_info(task_runs);
-- id task_id profile step_key status claim_lock claim_expires worker_pid
-- max_runtime_seconds last_heartbeat_at started_at ended_at outcome summary
-- metadata error
--                            ^ no usage, no tokens, no cost column
```

`hermes kanban runs` exposes no usage flag. `forge.chunk.v1` defines no cost
field. So the driver's consumption — the only consumption that is billed — is
**not recorded anywhere, and there is no column, flag or schema key that could
hold it.**

Worse, the envelope that exists is nearly empty. The documented
`forge.chunk.v1` has 15 fields; what the lane actually emits is:

```
branch, chunk_id, pr
```

**Three.** F2 said "not one field is canonical"; the measured answer is that 12
of 15 are simply absent, on top of F1's nesting defect.

**Consequence.** Every efficiency claim in this document — including the
60–65% saving in F21 and the whole justification for S6 — is measured on the
side of the system that does not cost anything. The Forge can currently prove
it made the free half cheaper and cannot say whether the billed half moved at
all.

**Fix, in the order the layers allow:**

1. **`forge.chunk.v1` gains a `cost` block** mirroring `forge.judge.v1`'s, and
   the lane stamps it from `codex exec`'s reported usage plus whatever the
   driver can observe of its own. Additive; no `.v2`.
2. **Establish what the driver can see.** Hermes may expose per-run usage
   through a route `hermes kanban runs` does not; if it does not, that is a
   substrate limitation to record in `docs/hermes-field-notes.md` and route
   around — a wall-clock and tool-call proxy beats nothing.
3. **Fix the producer first.** A cost field added to an envelope that emits 3 of
   15 documented fields will simply be the 13th absent one. S5's schema
   validation against live board metadata is the prerequisite, not a follow-up.

Until then, treat every token figure in this audit as describing the
subscription-covered half of a two-engine system.

---

## Ledger additions from the prejudge-gate slice (S3, step 0)

*All three found while executing F43 and F47 — that is, by running the suite
the audit had just declared red and watching what else was wrong underneath it.
F43 recorded six failures from one cause. There were eleven, from three.*

### F49 — `make verify` cannot be green in a worktree, which is where F40 requires every slice to run · `FIXED 2026-08-04` · **medium**

`config/external-dirs/<profile>` asserts that each live Hermes profile's
`skills.external_dirs` points at `$REPO_ROOT/skills`, where `REPO_ROOT` is
wherever `verify.sh` was invoked from. The profiles are bootstrapped once,
against the main checkout. So from a linked worktree the check compares

```
/Users/goonlab/dev/forge-slices/s3-prejudge-gate/skills   (REPO_ROOT)
/Users/goonlab/dev/forge/skills                           (what the profiles hold)
```

and fails once per profile — **4 more failures on top of F43's 6**, measured on
this host before this slice changed anything.

The two rules are in direct contradiction. F40 says a slice must run in a
worktree and not in the main checkout. This case says a worktree is red. Taken
together they say: do the work where the suite cannot pass. That is F43's
disease with a different cause — the suite is red for a reason unrelated to the
change under test, so it carries no information about the change under test.

**Fixed** by judging the two roots separately. A match on this checkout is a
`pass`. A match on the *main* checkout, from a linked worktree, is a `skip`
naming the consequence out loud: *the skills you are editing are not the ones
any run would read.* That consequence is real and worth stating on every slice —
it is why a SOUL edit in a worktree changes nothing until it is merged and
`profiles-bootstrap.sh` is re-run — but it is not a defect in the slice, and a
`skip` says so where a `fail` did not.

### F50 — The commit that resolved F45 broke the check that asserts F45, and `make verify` has been red on `main` since · `FIXED 2026-08-04` · **medium**

`lane/prejudge-cost-is-observed` asserts the SOUL's token formula with a
line-anchored regex:

```
\.tokens_estimate *= *\(\$u\.input_tokens \+ \$u\.output_tokens\)
```

Commit `2055929` ("resolve F45") changed the SOUL to the formula F45 measured to
be the true one —

```jq
.tokens_estimate = ($u.input_tokens + $u.cache_creation_input_tokens
                    + $u.output_tokens)
```

— and did not touch `verify.sh`. `git log -S` puts the divergence in that single
commit. The case has failed on `main` ever since, which means **F43 was still
true on the day it was written up**, just for a second, newer reason: this
slice's step 0 found the suite red for three independent causes, of which the
audit had recorded one.

Two things made it invisible for a commit. The expression is wrapped across two
lines in the SOUL, so a line-anchored grep could not match the correct formula
even in principle — the check could only ever pass on the *old* text. And the
number the case exists to protect is the one F45 proved was wrong.

**Fixed** by flattening newlines before matching and asserting the F45 formula
including `cache_creation_input_tokens` — the term whose omission *was* F45.

**The transferable lesson, and it is the one this slice keeps re-learning:** a
`make verify` case that asserts the text of a skill body is a second copy of
that skill body, and F34 already named duplication in the methodology layer as a
defect class. Nothing links the two copies. The suite cannot tell "the SOUL
regressed" from "the SOUL was corrected and I was not told", and it reports both
as `FAIL` in the same words.

### F51 — The `metrics/` fixture is not `journal_mode=wal`, and that is why the suite could not have caught F47 · `FIXED 2026-08-04` · **medium**

`scripts/fixtures/metrics-board.sql` created its board with no `PRAGMA
journal_mode`, so `sqlite3` built it as `delete` — SQLite's default. **Every
Hermes board is `wal`** (measured on `digest`, `forge-ladder`,
`forge-dependency-clone-20260728`).

F47 is reachable *only* on a WAL database with no `-shm` beside it. On a
`delete`-mode fixture, `mode=ro` opens fine every time. So the six-case
`metrics/` group could not have found F47 however many cases were added to it,
and the regression case written for F47 in this slice **passed against the
reintroduced bug** on the first attempt — which is how this was found.

The fixture's own header claims fidelity: *"the names and NOT NULL constraints
the live Hermes schema uses"*, checked against a real board by
`metrics/live-schema-has-fixture-columns`. That case reads columns. Journal mode
is not a column, so nothing compared it, and the one production property that
mattered to the one bug in this script was the property the fixture did not
reproduce.

**Fixed**: the fixture is `wal`, and `metrics/reads-a-quiescent-board`
checkpoints and strips the sidecars to build the resting state explicitly. The
case has been mutation-tested — with the `mode=ro` read restored it fails, and
the failure text is F47's exact error.

**The transferable lesson:** `live-schema-has-fixture-columns` exists precisely
because a hand-written fixture drifts from production. It compares the one
dimension somebody thought of. A fixture is a claim about *every* property of
production, and only the enumerated ones are ever checked.

### An unrecorded second half of F47

The audit records F47 as `metrics.sh` *failing* on a quiescent board. Measured
here: it fails and **exits 0**, printing a single blank line.

```
$ HERMES_KANBAN_HOME=<quiescent> ./scripts/metrics.sh forge-ladder --json
                      # one empty line
$ echo $?
0
```

`sqlite3` writes `Error: unable to open database file` to **stdout**, not
stderr. The guard was `[ -n "$JSON" ] || exit 2` — satisfied by the error text
itself. `jq` then failed on it, and with `set -uo pipefail` but no `-e`, the
script printed the empty result and reported success.

So a `/retro` consuming `--json` on a resting board does not get an error; it
gets nothing, from a command that says it worked. Fixed with the sqlite3 exit
code plus a `jq -e` parse check. Recorded because it changes F47's severity: the
failure is not loud, it is silent, and the flywheel's numbers are exactly where
a silent empty result is least likely to be questioned.

---

## Ledger additions from the prejudge-gate slice (S3)

*Produced by backtesting `make prejudge` against all 11 PRs of the run that
produced this audit. F35's claim is that a program has higher recall than the
model tier achieved, at zero tokens. It is partly true, and the parts that are
false are more useful than the parts that are true.*

### F52 — Two of F35's eight checks cannot work at prejudge time, and one of them is at the wrong layer entirely · `OPEN` · **high**

`ci-state` and `parents-merged` both return **zero findings across all 11 PRs**.
Their zeroes have different causes and only one is benign.

**`ci-state` (F5) — benign, and unmeasurable by backtest.** CI was green on all
11 PRs, confirmed here against the live rollup. The defect F5 records is a
*race*: prejudge queried before checks registered, got an empty rollup, and
approved. That window is seconds wide and cannot be reproduced retroactively —
the rollup is populated forever after. The check is still right, and its
fourth-state handling is the point, but **the backtest can say nothing about its
recall** and this write-up will not pretend otherwise.

**`parents-merged` (F10) — not benign. The check is at the wrong layer.** It
passes on all 11 PRs because *by the time a PR exists, the parent has merged* —
the lane cannot open a PR before it has done the work, and it cannot do the work
until it is unblocked. F10's waste is five spawned workers that discover they
cannot work, and every one of them dies **before any PR exists**. A prejudge gate
runs on a PR. It is structurally incapable of preventing F10.

F35's fix table lists "Parent PRs merged · `jq '.mergedAt'` · no" as a tier-1
check. It is not one. It is a **dispatcher** check, and F10's own fix text says
so correctly — *"make the card-level dependency edge resolve on parent-PR-merged
rather than parent-card-done"* — while the F35 table then files it under review.
The two findings disagree and F35 is the one that is wrong.

**Consequence for S4.** Deleting tier 1's model call on the strength of "a
program has higher recall" must not carry `parents-merged` along as evidence. It
contributes nothing at this layer and never will. Six checks, not eight.

### F53 — The two highest-severity checks fire on everything, so neither can filter · `OPEN` · **high**

| check | fires on |
|---|---|
| `size-budget` (F28) | **11 of 11** |
| `real-source` (F25) | 8 of 11 — every chunk whose contract names an external source |

Not one PR in the project's only real run came within the size budget, the
planning PR included (1,421 lines, 3.6×). And no feature file in the repository
carries a `@real-source` tag, because the convention did not exist until this
slice; 5 of the 6 chunks name an external source and all 5 fail. CHUNK-5 passes
because its contract genuinely names none.

Both results are correct and both were predicted. The consequence was not: **a
gate that blocks every PR is not a filter either.** Turned on as blocking on day
one, `size-budget` would have stopped the project at PR #2 and never let it
resume, because nothing in the run's methodology produces a 400-line chunk.

The conclusion is not to loosen the threshold — the threshold is the roadmap's
own and moving it after seeing the data is exactly what this slice was told not
to do. It is that **F28 and F25 are planning defects being surfaced at review
time**, and review time is the most expensive place to learn that a planner
wrote a 3,700-line chunk. Both belong at `/roadmap`, where the contract is still
editable and no model has been spawned. As a PR gate they are a receipt for a
decision made days earlier.

### F54 — The judge cited a defect, bounced the PR, accepted the fix, and the defect is still on `main` · `OPEN` · **high** *(instance of F6)*

The tier-2 bounce of PR #8 cites, verbatim:

> `tests/test_render.py:198-200` defines determinism as
> `render(report) == render(report)`

The gate finds that exact tautology on PR #8 at **line 200**. It then finds it on
PR #9, PR #10, PR #11 — and on `main` today, at `tests/test_render.py:259`,
where reading the file confirms it:

```python
assert render(report) == render(report)
```

So: named by the judge, in writing, with a line number. Bounced on. Fix
delivered, re-reviewed, approved, merged. **The cited line was never changed.**
The bounce was resolved by adding coverage elsewhere and the specific defect
survived four more reviews and the merge.

This is F6 — *"the judge does not converge; it relents"* — with a surviving
artifact rather than an inference. It also sharpens F32: the fresh-context rule
means the reviewer of PR #9 never knew that the tautology it was looking at had
been the subject of the previous bounce.

**The cheap fix is the one this slice already built.** A finding that names a
`file:line` is checkable at the next push for nothing. Nothing checked it.

### F55 — `Touches` drift is dominated by process files no contract has ever listed, which decides F8 · `RESOLVED-BY-DECISION 2026-08-04` · **medium** *(resolves the F8 decision)*

F8 was left deliberately undecided: `Touches` advisory, or amendable in-branch.
The instruction was to count the drift across the six chunks and let the number
choose. Counted:

`touches` warns on **5 of the 10 chunk PRs** (#2, #4, #5, #8, #9). The distinct
drifting paths are five, and they are not the same kind of thing:

| path | PRs | what it is |
|---|---|---|
| `docs/decision-log.md` | #2, #5 | process doc every chunk must write |
| `docs/ROADMAP.md` | #5 | process doc |
| `docs/chunks/CHUNK-3.md` | #5 | **the contract amending itself** |
| `tests/fixtures/normalize.py` | #4 | a fixture the work necessarily needed |
| `src/forgeboard_report/errors.py` | #8, #9 | genuine implementation, outside the plan |

**Three of the five are process documents that no contract in the entire run
ever listed in `Touches`, and every chunk is required to change them.** They
cannot be scope creep; a contract that omitted them was never going to include
them. A fourth is the contract file recording its own amendment — drift created
by the remediation of a previous drift bounce.

**Exactly one of five is a real implementation file outside its plan.** That is
`errors.py`, on CHUNK-5, and it is the case the audit already cites — tier 2
scored `scope_discipline: 1` for it.

**The data decides F8, and it decides it against the bounce.** `Touches` should
be **advisory**, and the comparison must exclude `docs/decision-log.md`,
`docs/ROADMAP.md` and `docs/chunks/*` outright — not as a convenience, but
because including a file every chunk must edit and no chunk may declare
manufactures a finding on every single PR. With that exclusion the check fires
on 2 of 10 PRs instead of 5, and both remaining hits are the same real one.

**Implemented 2026-08-04**, and the exclusion is written down as a rule rather
than as a list, so a later reader cannot mistake it for convenience —
`scripts/prejudge.sh:297–299`:

```
# Not a convenience list: each entry is a path the METHODOLOGY obliges a chunk to
# touch and the contract template has no slot to declare.
TOUCHES_EXEMPT='^docs/decision-log\.md$|^docs/ROADMAP\.md$|^docs/chunks/'
```

`touches` emits `warn`, never `block`, which is the other half of the ruling.
This closes **F8**'s open decision; what remains is F57's self-certification
problem, which is a new check rather than a re-opening of this one.

### F56 — The gate's first version produced four false positives, and only reading the flagged code found them · `RESOLVED 2026-08-04` · **medium**

Recorded because it is the methodological lesson of this slice, not a defect
that survived it.

The `Then`-step walker reported four steps in PR #11's
`tests/steps/test_report_command_steps.py` as making no assertion at all. They
delegate to a module-private `_assert_failures` helper which asserts four times.
The prefix test matched `assert*` and not `_assert*`, and one underscore turned
four correct steps into four fabricated findings.

Nothing about the output looked wrong. The count was plausible, the file was the
file the audit cites for CHUNK-6's scenario theater, and the finding class was
the one being looked for. **It was found by opening the file the gate pointed
at** — which is the check this slice's own standing instruction demanded and
which no automated case would have performed.

The number that matters: after the fix, `then-asserts` fires on 4 PRs and every
one of them is the **same single defect** (F54's tautology). The `no-assertion`
detector — the half F35 singles out, *"a five-line AST visitor"* — found
**nothing at all** across all 11 PRs. F14 is real and is the most-cited defect in
the run; the specific mechanization F35 proposed for it has zero recall against
the run that motivated it. The recall this slice does deliver for F14 comes
entirely from the tautology detector, which F35 does not mention.

---

## Ledger additions from the gate-blocking slice (S4)

*Produced by re-running `make prejudge` against all 11 PRs of the audited run
with the blocking severity map live, and by reconciling what it clears against
what tier 2 actually did. The severity map is unchanged by these findings; what
changes is what may honestly be claimed for it.*

### F57 — `touches` reads the contract from the PR's own tree, so a branch that amends its own `Touches` list clears the check by construction · `OPEN` · **medium**

The gate reports `touches: pass` on **PR #5**. Tier 2 bounced PR #5 for
`scope_discipline`, citing:

> `docs/chunks/CHUNK-3.md:5` and `docs/ROADMAP.md:69` authorize six Touches
> paths, but `origin/main...05b6d30` changes two additional implementation-test
> paths

Both readings are correct, and the difference is *which copy of the contract was
read*. `CHUNK-3.md` in PR #5's own tree says, verbatim:

> **Touches:** … `tests/fixtures/normalize.py`, `tests/fixtures/hermes_019.py`
> (grew from 6 to 8 files because the judge bounce required both canonical
> fixture sources)

The branch amended its own `Touches` list to authorize its own drift, in the
same PR. The gate reads the PR tree — deliberately, and S3 documented why: the
contract as it stood on the branch is the one the implementer worked against.
Combined with F8's still-undecided "the lane may amend `Touches` in-branch",
that makes the check **self-certifying**: any drift can be legalised by editing
one line in the same commit, and the check will agree.

**This does not change F55's ruling.** `touches` is advisory precisely because
its findings are dominated by paths no contract may declare, and an advisory
check that can be talked out of a finding is a smaller problem than a blocking
one. What it changes is the claim: `touches` measures *drift the branch did not
declare*, not drift. Its recall is bounded by the honesty of the branch it reads,
and the one case in the run where that mattered is the one case tier 2 caught.

**The fix is not to read the base contract instead** — that would resurrect
CHUNK-3's original bounce, where the plan omitted a fixture the work genuinely
needed, which is the defect F8 exists to avoid. The candidate is to compare the
two copies and report *the amendment itself* as the finding: "this PR widened its
own `Touches` by 2 paths" is a true, cheap, non-self-certifying statement, and it
is the one a reviewer actually wants. Not built here; it is a new check, not a
severity change.

### F58 — The gate clears 3 of 11, and 2 of those 3 carry six tier-2 bounces between them · `OPEN` · **high**

The residual, measured rather than estimated, because S5 is sized against it.

| PR | gate | tier-2 verdicts |
|---|---|---|
| #1 `planning/lifecycle` | clear | none recorded — not a chunk |
| #5 `chunk/3-lifecycle-metrics` | clear | **4 bounces**, 1 approve |
| #7 `chunk/4-dependency-audit` | clear | **2 bounces**, 1 approve |

Every other PR the gate blocks. So the deterministic stage lets through
**exactly the two chunk PRs that cost tier 2 six review cycles**, and nothing
about their findings is mechanical:

- **#5** — the `forge.judge.v1` decoder accepts scores serialised as strings and
  a fractional `2.5` where the schema names six integer dimensions; the evidence
  index sorts by id where `ARCHITECTURE.md` specifies otherwise; a per-chunk
  rescan of every card where the doc specifies linear scans plus an index.
- **#7** — `started_at == wait.occurred_at` treated as a retry, where CHUNK-4
  and ADR-0005 require strictly later; and the BDD scenario *codifying* that
  wrong behaviour, which is scenario theater that asserts confidently on the
  wrong rule.

**This is the case for keeping a semantic reader at tier 1, and it is also the
case against assuming the current one would find these.** Tier 1's model
approved both PRs at the time. The residual is real; whether an Opus pass told
to pass anything subtler than obvious through can address it is exactly what
ADR-0009 D9.5 leaves open, and the number to beat is **6 bounces on 2 PRs**.

### F59 — "The gate blocks 8 of 11" decomposes into one naming convention and one tautology · `OPEN` · **medium**

The headline is true and reads as broader recall than it is:

| check | PRs blocked |
|---|---|
| `branch-name` | 6 — #2, #3, #4, #6, #8, #10 |
| `then-asserts` | 4 — #8, #9, #10, #11 |
| `scenario-count` | 1 — #8 |

**Four PRs (#2, #3, #4, #6) block on `branch-name` alone.** Fix the lane's branch
naming — a one-line change at the point of creation, which is where it belongs —
and the gate's block count falls from 8 to 4. And per F56, all four
`then-asserts` hits are the **same single defect**: the `render(report) ==
render(report)` tautology, which is F54, still on `main` today.

So the honest statement of what the blocking gate catches on this run is: **one
misapplied naming convention, and one tautology that four reviews failed to
remove.** That is worth having — it is 8 blocked PRs at zero model tokens, and
`branch-name` alone cost the run four closed-and-recreated PRs after full review
had been paid for. But it is two defects, not eight, and a severity map validated
on two defects should be re-validated on the next real run before anyone
concludes the other checks are earning their place.

`size-budget` warns on **11 of 11** and `real-source` on **8 of 11**, exactly as
F53 measured. Both reproduce; neither has been moved to `/roadmap` yet.

### F60 — A SOUL edit desynchronises the live profile, and `make verify` is the only thing that says so · `RECORDED` · **low**

`config/soul-in-sync/forge-prejudge` fails on this slice's branch and passes on
`main`. That is the check working exactly as designed — it exists because a fix
can look committed and merged while every run still reads the old identity
(measured 2026-07-28) — but it means **every slice that edits a SOUL ships with
one red case**, and the remedy (`./hermes/profiles-bootstrap.sh`) publishes an
unmerged protocol to the operator's always-on install.

Recorded rather than fixed, because the resolution is a policy question this
slice should not settle unilaterally: either the check learns to compare against
the merge-base for a branch, or SOUL publication becomes an explicit post-merge
step with its own gate. Publishing from an unmerged branch — the current
instruction — is the one option that is actively wrong while a board is live.

### F61 — ADR-0003 is unenforced above L2 for *drivers*, and F35 named only half the problem · `FIXED 2026-08-05` · **high**

F35 found eight mechanical properties being checked by a language model, in
prose, and called it "ADR-0003's obituary above L2". The fix, ADR-0009, moved
what tier 1 **decides** into `scripts/prejudge.sh`. Nobody applied the same test
to what tier 1 **does**.

Measured 2026-08-05 on `slice/gate-blocks`:

| profile | SOUL lines | fenced blocks | protocol lives in |
|---|---|---|---|
| `forge-digest` | 27 | 0 | three prose steps |
| `forge-codex-lane` | 29 | 0 | `skills/forge-lane/SKILL.md` |
| `forge-orchestrator` | 32 | 0 | four prose steps |
| **`forge-prejudge`** | **404** | **11** | **itself** |

144 of those 404 lines were executable bash — a `jq` schema reduction, a
`claude -p` invocation, a fifteen-line stamping `jq`, a create/block/unassign
sentinel sequence and two `jq -e` read-backs. None of it required a model. All
of it was retyped by one on every run: `deepseek-v4-flash`, the only metered
agent in a review, with no gate on the transcription.

The comparison inside the repo is the finding. `forge-codex-lane` is 29 lines
because it says *"Your protocol is the `forge-lane` skill. Load it and follow
it… This file is only your identity."* The pattern existed, was proven across
four climbs, and was never applied to the one profile that needed it most.

Closed by ADR-0010: the protocol is `scripts/prejudge-review.sh`, the SOUL is 56
lines, and `cli/soul-body-budget` holds every SOUL at 60.

*Header promoted `MEASURED` → `FIXED` 2026-08-06 after re-measuring: the four
SOULs are 30 / 27 / 34 / 56 lines, `cli/soul-body-budget` and
`cli/no-programs-in-souls` both exist in `verify.sh` and both fail on breach.*

### F62 — A slice can satisfy its contract and still move the measured quantity backwards · `FIXED 2026-08-05` · **medium**

S4's thesis was that properties a program can decide belong in a program. It
narrowed the tier-1 scorer's brief by two bullets — and grew the driver's system
prompt from 339 lines to 404. **Net prompt surface went up 19%.**

Both halves were contract-compliant. Deliverable 2 asked for exactly the two
bullets to go; nothing asked what the slice was adding elsewhere. `make verify`
could not see it either: `cli/skill-body-budget` covers `skills/*/SKILL.md` and
there was no equivalent for `hermes/profiles/*.SOUL.md`, so the file with the
largest per-run context cost in the repo was the only prompt with no budget.

This is a general shape worth naming: **a slice that measures the thing it
removes and not the thing it adds will report a saving it did not make.** The
fix is a number, not a review — `cli/soul-body-budget` (60 lines) and
`cli/no-programs-in-souls` (6-line fenced blocks) both land with ADR-0010.

*Header promoted `MEASURED` → `FIXED` 2026-08-06. Both numbers are in
`verify.sh` and both are enforced; the largest per-run prompt in the repo is no
longer the only one with no budget. The general shape this finding names —
**a slice that measures the thing it removes and not the thing it adds will
report a saving it did not make** — is a standing rule, not a closed item.*

### F63 — Eleven `make verify` cases asserted runtime behaviour by substring, and one by comparing line numbers · `FIXED 2026-08-05` · **medium**

Because tier 1's protocol lived in prose, the suite could only describe it a
second time and diff the descriptions. As of `slice/gate-blocks`, the `lane/`
group carried eleven `prejudge-*` cases that were `grep -Fq` against
`forge-prejudge.SOUL.md`. `lane/prejudge-runs-the-gate-first` asserted execution
order by taking `grep -n` line numbers of two strings and comparing them.
`lane/prejudge-cost-is-observed` matched a newline-flattened regex, and
`verify.sh` carried a comment conceding that this *"is how the check and the
SOUL silently diverged for a commit in the first place."*

These were the best available proxy **given the protocol was prose**, and they
did catch real regressions. The finding is not that they were badly written; it
is that a protocol in a prompt is not testable, only approximable — and the
suite said so about itself in a code comment for a whole commit before anyone
read it as a defect.

ADR-0010 replaces them with four identity assertions and six executions against
recorded `gh` responses. `prejudge/review-never-prints-the-diff` is the clearest
of them: F32's rule used to be a `grep` for the sentence promising it, and is now
a measurement — **63,164 bytes moved into the prompt file, 2,599 bytes observed
by the driver.**

*Header promoted `MEASURED` → `FIXED` 2026-08-06. Re-checked in the tree: the
`prejudge/` group is 23 cases, none of them a `grep -Fq` against a SOUL, and
`prejudge/scorer-is-the-control-arm` compares against a recorded fixture rather
than a git ref — which is the repair F65 forced after the first version of that
pin went inert at a merge.*

### F64 — `forge-lane` is at 299 against a 300 budget that was raised to admit it · `FIXED` · **low**

`skills/forge-lane/SKILL.md` is 299 lines with 12 fenced blocks — the same shape
as F61, one layer over. `docs/state.md` records it as **resolved** on 2026-07-29
"by splitting the budget rather than the skill", raising the ceiling from 150 to
300 with the file at 283. It has since grown 16 more lines into that headroom.

The argument given for the raise is a real one and still stands: the lane is the
whole job of one dedicated unattended profile, and its length is accumulated
measured failures rather than prose. But that is also precisely the argument
`forge-prejudge` would have made at 404 lines, and F61 is what came of not
testing it. The distinction that survives is not length — it is whether the
content is *executable*. Twelve fenced blocks say some of it is.

**Recorded, deliberately not acted on.** The lane is the most load-bearing
proven artifact in the repo; four climbs depend on it; and `state.md:116` is
explicit that this system's failures live in seams visible only under load and
that nothing should ever be tested with two unknowns in play. It needs its own
slice, with a real run behind it.

**Sliced, bounced twice, narrowed.** PR #19 moved setup and the final audit into
scripts; a post-merge review found six fail-open classes in that implementation
(F69–F74); a second review found the repair for those fail-*closed* on normal
non-Codex activity (F75, F76). What shipped protects a named set and states what
it cannot protect. The skill is 299/300 and `make verify` is 117/0/3 with 35
lane cases.

**Live-validated against what shipped.** The earlier probe
(`verify-codex-1786005619-80398`) exercised the *retired* wide design and is not
evidence for this one; citing it would be exactly the claim ADR-0003 exists to
prevent. Re-run on the narrowed audit: setup → immutable capture → real
`codex exec` commit → `make check` → final audit clean, as run
**`verify-codex-1786010605-22305`**. The probe now prints its run id, so the
next such claim can be checked rather than taken.

### F65 — The control arm's pin went inert at the merge that created it · `FIXED` · **high**

`prejudge/scorer-is-the-control-arm` compared the scorer block in
`scripts/prejudge-review.sh` against
`git show main:hermes/profiles/forge-prejudge.SOUL.md`. That was correct for
exactly as long as the arm lived in that SOUL — which is to say, while ADR-0010
was an open branch.

ADR-0010's entire purpose was to move the arm *out* of the SOUL and into the
script. So the moment it merged, the comparison target stopped existing.
`arm_extract` returned zero lines from main's SOUL, the check took its
`[ -z "$arm_main" ]` branch, and reported:

```
skip  prejudge/scorer-is-the-control-arm (main has no pinned scorer block to compare)
```

Measured on `main` at `5f3c38c`, immediately after the stack landed. The bytes
themselves were never harmed — the 24 lines in the script are byte-identical to
`6b4c419`'s SOUL, sha256 `7f9ddf38…` — but nothing was checking that any more,
and nothing would have said so.

**This is the F62 shape at the layer above.** F62 recorded that a slice can
satisfy its contract and still move the measured quantity backwards with no
check able to see it. Here a slice satisfied its contract and disabled the check
itself. ADR-0010 D10.5 argued the move made the control *stronger* because the
bytes were now "pinned by a test"; that sentence was true on the branch and
false one commit later. The ADR is otherwise sound and its bytes were carried
faithfully — the defect is in the pin, not in the move.

**Three things made it invisible:**

1. **The baseline was a moving branch, not a record.** Any check anchored to
   `main` is a check whose baseline the next merge can redefine.
2. **The failure mode was `skip`, and a skip is quiet.** The suite ended
   `0 failed` and the summary line read as success. A control that cannot find
   its baseline is not a passing control; it is a failing one.
3. **The check that would have caught it is the one that broke.** There was no
   outer assertion that this case must never skip.

**Fix (this slice):** the baseline is now `scripts/fixtures/control-arm.txt`,
recorded from `6b4c419` and verified identical to the moved bytes. Both the
missing-fixture and the empty-extraction paths call `bad()`, so this case can
no longer skip for any reason. Verified by negative test — one added space
inside the stamping `jq`, `--model opus` → `sonnet`, a deleted fixture, and a
renamed marker each fail the suite; the unmodified arm passes.

A sweep for the same shape found no other case in `verify.sh` anchored to a git
ref. This was the only one.

**Consequence for S5.** The plan's ordering assumed this pin held while the
derivation work proceeded around it. For four commits it did not hold at all.
Nothing edited the arm in that window — `sha256` confirms it — so the baseline
is intact and the experiment is still runnable, but the margin was luck rather
than enforcement.

### F66 — `make preflight` failed because the system was correct, and stopped checking the human gate · `FIXED` · **high**

Measured on `main` at `515229c`, immediately after the stack landed:

```
PASS 79   WARN 6   FAIL 6
Not ready for unattended work. Fix every FAIL, then re-run.
```

`docs/state.md` records `PASS 78 / WARN 3 / FAIL 0`. Every one of the six
failures was preflight being wrong, and one of the warnings was preflight
having gone blind.

**All six FAILs were profiles that are supposed not to exist.** Section 4 built
its profile list as

```sh
hermes kanban assignees | grep -oE '\bforge-[a-z-]+\b' | sort -u
```

`kanban assignees` lists every name that has ever appeared on a card and marks
each `yes`/`no` under `ON DISK`. The `grep` discards that column. So preflight
ran `hermes -p <name> config get` against `forge-operator` — a ghost assignee
from the rung-4 row of `retro-metrics.md` — and against
`forge-operator-handoff`, **the tier-2 sentinel, whose entire purpose is to have
no profile**. Neither has config, so three checks failed apiece.

Preflight was reporting "not ready for unattended work" *because ADR-0007's
human gate was intact.* A readiness gate that reddens when the system is right
trains its operator to ignore it, which is how the real failure gets missed.

`make verify`'s config group had already been fixed for exactly this, as **F43**
— its comment describes the same six failures and switched to
`assignees --json` / `.on_disk`. The fix was never carried across to preflight.
Two scripts answering "which profiles are real" differently is how one of them
gets to be wrong.

**And the sentinel check had stopped checking anything.** It reads the sentinel
name out of the hand-off rather than hardcoding it twice, then asserts in
reverse — the failure is that name *existing* on disk, because if a profile is
ever created there, every parked tier-2 card becomes claimable and ADR-0007's
second tier silently collapses into the first. It read the name with

```sh
sed -n 's/.*--assignee \(forge-operator-handoff\).*/\1/p' \
    hermes/profiles/forge-prejudge.SOUL.md
```

ADR-0010 moved `route_tier2()` out of that SOUL and into
`scripts/prejudge-review.sh`. The sed then matched nothing, `$SENTINEL` went
empty, and the check fell to its "could not read" branch — a **WARN**. From
that merge onward nothing verified that the human gate was still unclaimable,
and the only signal was a warning about the check's own blindness.

**This is F65 exactly, one script over**: a check anchored to a location whose
content moved, going quiet at the merge that moved it. F65 was found by running
`make verify` on `main` after merging; this was found by running `make
preflight` for the same reason. Neither was catchable by reading.

**Fix (this slice):**

- profiles are filtered by `.on_disk` via `assignees --json`, matching F43's fix
  in `verify.sh`; assignees without a profile are named and skipped rather than
  silently dropped, because a check that could not run has not passed
- the sentinel is read out of `route_tier2()` in `scripts/prejudge-review.sh`,
  capturing whatever name is there rather than asserting a known one, so it is
  still never written twice
- an unreadable sentinel is now a **FAIL**, not a WARN. F65's lesson generalised:
  a control that cannot find the thing it guards is not passing
- `config/preflight-agrees-about-real-profiles` fails the suite if preflight
  goes back to either mistake

After: `PASS 79 · WARN 4 · FAIL 0`, and the sentinel check makes a real
assertion — `tier-2 sentinel 'forge-operator-handoff' is correctly absent from
disk`. Negative-tested: pointing `route_tier2()` at an existing profile fails;
renaming the function so the name cannot be read fails.

---

### F67 — The suite's one live-board check flaked, and the recorded cause was backwards · `FIXED` · **medium**

`metrics/live-schema-has-fixture-columns` reddened roughly one run in four,
reporting *"a live board no longer has: \<every column\> — the fixture is
testing a schema that no longer exists"*. The schema had not changed. The
message described a defect that did not exist, in a suite `docs/state.md`
nominates as the arbiter when two files disagree.

**The recorded diagnosis (audit V8) was wrong in both halves, and its
prescribed fix would not have worked.** V8 recorded that the check "races the
launchd gateway" and "collides with a write window", and proposed a
retry/quiescence wait. Measured on a WAL board built for the purpose:

| condition | `mode=ro` open on the live file |
|---|---|
| concurrent writer holding an open write transaction | **succeeds** |
| `-shm` absent, no writer at all | **fails 10/10**, sqlite error 14 |
| `-shm` absent, retried five times | **fails 5/5** |

Every hermes board is `journal_mode=wal`. A `mode=ro` connection to a WAL
database cannot create the `-shm` file it requires, and SQLite deletes `-shm`
and `-wal` when the **last** connection closes. So the check failed in exactly
the windows when the gateway was **idle** — the reverse of the recorded cause.
Both obvious remedies make it worse: retrying never recreates `-shm`, and
waiting for quiescence waits for the very condition that triggers it.

Two failure modes also shared one message. Twelve column probes each swallowed
their own error, so an open failure presented as twelve missing columns —
sending the next reader to rewrite a fixture that was correct.

**F47 is the same defect, found earlier and never carried across.**
`metrics/reads-a-quiescent-board` has asserted since F47 that a board with no
WAL sidecars stays readable. That fix landed on `metrics.sh` and stopped there,
while the check forty lines below went on opening a live board `mode=ro`. This
is the third time the pattern has cost a finding — F43 → F66, F65, now
F47 → F67 — and the standing remedy holds: **when a check is fixed, grep for
its siblings.**

**Fix.** Snapshot the board with `cp` (which only reads, so the live file is
never opened, locked or mutated) and open the *copy* read-write, which is what
lets SQLite build the `-shm` the original could not be given. A `SELECT 1`
probe — needing no table and no column — then separates *unreadable board*
from *schema changed*, so every column failure below it is unambiguously about
the column.

Measured after: **0/10 → 10/10** under the reproduced condition. Negative-tested
both paths: a board missing `task_runs.profile` reports schema drift; a file
that is not a database reports `could not read a snapshot … which is not a
schema change; the fixture is unverified this run, not disproven`.

Pinned by a new offline case, `metrics/live-schema-read-survives-an-idle-board`,
which builds a WAL board and deletes its sidecars deliberately — the flake was
invisible to every previous run because a live board usually *has* an `-shm`.

---

### F68 — §5's clean-worktree check only worked on projects stamped from our own template · `FIXED` · **medium**

Found while slicing F64, by running the extracted script against a repository
the forge template did not generate.

`forge-lane` §5 wrote its evidence — `.forge/hooks.before`, `.forge/hooks.after`,
the contract, the codex transcript — into `.forge/`, and then asserted
`test -z "$(git status --porcelain --untracked-files=all)"`. **The lane's own
bookkeeping is untracked, so that check reports the lane's own files as a dirty
worktree.** It passed for a year because
`templates/python-service/template/.gitignore:11` carries `.forge/`, so every
project the ladder ever ran on happened to ignore it.

On any repo not stamped from that template the lane blocks a clean chunk and
reports it as Codex exceeding its contract — the most alarming block the
protocol can raise, for a file the lane wrote itself. `docs/open-questions.md`
records that the operator's projects are **not** all Python and pulls toward a
`forge graft` skill, which is exactly the case that would have hit this.

Reproduced directly: a fresh `git init` repo, `capture` then `check`, no Codex
involved at all, exits 3 `worktree-dirty`.

**The first fix was unsafe.** PR #19 excluded all of `.forge/` by pathspec. The
review then modified a tracked `.forge/policy`, added `.forge/patch.orig`, and
observed exit 0. Worse, the supposedly immutable hook/ref baselines also lived
there, inside Codex's write grant. Avoiding the false positive had created both
a worktree blind spot and an audit-bypass path.

**Repair implemented.** All contract, transcript, PR-body
and UV-cache scratch now lives under one run-specific `$TMPDIR`; immutable audit
state lives at `~/.forge/lane-audits/<run-id>`. Final status has no exclusions,
so tracked and untracked `.forge/` dirt both exit 3. Pinned independently by
`blast/forge-dirt-is-not-hidden` and `blast/baseline-is-outside-codex-roots`.

**The general shape:** a check whose correctness depends on a *sibling file in
someone else's repository* is passing by luck. This one had no way to notice —
the dependency was invisible from inside the lane, and the only project anyone
tested it on satisfied it.

---

### F69 — The audit baseline was ordered after Codex and stored inside Codex's write grant · `FIXED` · **high**

`forge-lane` ran `codex exec` in §4 and only showed the capture command in §5.
The script wrote `.forge/main.before` and `.forge/hooks.before`, so Codex could
run capture again after moving `main` or editing hooks. Reproduced: the first
check exited 3, post-breach recapture exited 0, and the next check exited 0.

**Repair implemented.** `lane-setup.sh` now takes the capture before it can
return ready. State is keyed by `HERMES_KANBAN_RUN_ID` outside every sandbox
write root, and capture refuses overwrite. `blast/capture-is-single-use` and
`blast/baseline-is-outside-codex-roots` pin both halves. (The live run that
exercised this was against the pre-F75 audit; see F64 for what is still owed.)

### F70 — Hook hashing discarded hook identity and swallowed read failures · `FIXED` · **high**

The extracted hash reduced every hook to its content digest. Renames, executable
mode changes and symlink retargeting could preserve that multiset; an unreadable
hook produced an empty manifest and still returned clean.

**Repair implemented.** Manifests bind the relative path, node type, mode,
symlink target, resolved target mode/content, and file content; every
traversal/hash error fails closed. Independent `blast/hook-*` cases reproduce
rename, chmod, retarget, target-content change and unreadable inputs, and
`blast/clean-linked-worktree` proves the nominal hook set passes. Since F77 the
manifest covers **both** the worktree's own hooks and the shared directory.

### F71 — Three checks did not bound the shared `.git` grant, and status errors read as clean · `FIXED` · **high**

The script named config, every ref and every worktree admin directory as writable
but checked only `main`, default hooks and worktree stdout. A sibling ref and
local config both changed with exit 0. A corrupt index made `git status` exit 128
with empty stdout, which the command substitution interpreted as clean.

**First repair overshot; see F75/F76.** It asserted that the whole shared `.git`
was frozen except a small allow-list, which is false under normal operation and
blocked clean chunks. What shipped is a **named protected set**, not a freeze:

| protected | why it is the escape that matters |
|---|---|
| both hooks directories | they execute on the operator's machine |
| `--local` and `--worktree` config | `core.hooksPath`, aliases, credential helpers |
| `refs/heads/main` | the protected branch |
| `objects/info/alternates` | redirects object lookup elsewhere |
| object reachability (`fsck --connectivity-only`) | history cannot silently lose objects |
| worktree cleanliness | the measured `.orig`/`.rej` leftovers |

Any unreadable surface still exits 3, and each line has an independent `blast/*`
regression. **Deliberately not protected:** sibling branches, `refs/remotes/*`
and other worktrees' admin directories — see F75 for why that is a limit of the
instrument rather than an omission.

This remains a final-state audit, not a syscall log: identical
modify-and-restore activity is not observable, and the hostile diff review is
still the semantic control on the task commit itself.

### F72 — Setup suppressed fetch failure and accepted a bare repository as a worktree · `FIXED` · **medium**

`git fetch origin || true` reported ready against a broken remote. Checking only
the exit status of `git rev-parse --is-inside-work-tree` accepted its literal
`false` output from a bare repository. Both contradicted the skill's promise
that origin was fresh and the dispatcher worktree verified.

**Repair implemented.** Fetch failure exits 4; the probe must output `true`;
detached HEAD, `main`, and a mismatch with `HERMES_KANBAN_BRANCH` exit 3. The
setup case now runs a linked worktree and pins exits 0/2/3/4/5/6, and asserts
the emitted `FORGE_LANE_RUNTIME` path and the per-worktree hooks directory.

### F73 — Setup-created dirt would be blamed on Codex by the final audit · `FIXED` · **medium**

The configured `forge-hello` sample exposed this before a board task was
created: `make setup` generates an untracked `uv.lock` in that older checkout.
The old sequence captured shared Git after setup but did not require a clean
worktree, so the final audit would report setup's own artifact as Codex escaping
its contract — F68's attribution error one phase earlier.

**Fix.** `lane-setup.sh` now requires a readable, clean worktree after setup and
baseline check. Dirt exits 5 as `failing-prereq`, before Codex and before audit
capture. The linked setup fixture creates `generated.lock` and requires exit 5.

### F74 — A failed final audit could be repaired and replayed under the same run id · `FIXED` · **high**

Capture was single-use, but check was not. After a breach produced exit 3, the
offending state could be restored and the same run checked again; that second
check overwrote the `after` manifests and produced a clean completion marker.
A clean check could likewise be replayed and overwrite its evidence timestamp.

**Repair implemented.** Check now atomically creates `check.started` in the
protected audit directory before reading any post-Codex state. That marker is
never removed, so every run id gets one final-audit attempt whether it passes,
finds a breach or fails to inspect. `blast/check-is-single-use` and
`blast/failed-check-cannot-be-retried` pin the pass and breach paths. Recovery
from a spent run id is a new card, which is already how the protocol handles a
block — deliberately not a second attempt.

### F75 — The audit blamed Codex for a sibling lane doing its job · `FIXED` · **high**

F71's first repair froze the shared `.git`. A dispatcher runs lanes as worktrees
off **one** shared `.git`, so that assertion is false whenever anything else
touches the repository. All three reproduced against a clean worktree with no
Codex involved:

```
lane B commits on its own branch  -> non-task-ref-edited shared-git-edited (exit 3)
any `git fetch origin`           -> non-task-ref-edited shared-git-edited (exit 3)
`git pack-refs` / `commit-graph` -> shared-git-edited / object-config-edited
```

Each blocks a clean chunk with the most alarming block the protocol raises.

**The instrument has a hard limit, and this is it.** From inside lane A,
`refs/heads/taskB` moving is *indistinguishable* from Codex moving it — the
shared `.git` carries no signal separating a sibling lane from an escape. So
sibling branches, `refs/remotes/*` and other worktrees' admin directories cannot
be protected from here, only false-positived on. The audit now names what it
protects (F71) and says what it does not, rather than claiming a guarantee it
cannot keep.

**Pinned by a positive case.** `blast/sibling-lane-is-not-a-breach` commits from
a sibling worktree *and* fetches, and requires exit 0 — a negative-only suite
passes a wide audit that is still unusable.

### F76 — `git fsck --full` is an absolute check inside a differential audit · `FIXED` · **high**

Every other surface compared before against after. `fsck --full` alone asked an
absolute question, and it also validates object **content** — so a repository
carrying malformed history failed it forever. Reproduced with **zero** changes
after capture, on a commit whose `committer` line lacks a space before the email
(what CVS/SVN-imported history looks like):

```
capture exit=0
check   -> reason_class=other: ...invalid object database (exit 3)
```

That blocked *every* chunk on such a repo permanently, attributing pre-existing
history to Codex — F68's shape again, one layer down.

**Fix.** `--connectivity-only`, which asks the question that belongs here: can
everything the refs reach still be found. Measured on the same repository,
`--full` exits 1 and `--connectivity-only` exits 0. It is also the cheap half —
the content scan was the dominant cost on any real repo. Pinned by
`blast/pre-existing-fsck-damage-is-not-a-breach`.

### F77 — `make setup` writes the shared hook, so two lanes race on one file · `FIXED` · **medium**

Recorded during the ladder run (`docs/ladder-2026-07-28.md`): lefthook bakes the
*installing* checkout's `.venv` path into `.git/hooks/pre-push`, which
`--git-path hooks` resolves to the **shared** directory. It was called real but
harmless. Protecting hook content makes it a hard block — a sibling lane's
`make setup` rewrites the file and the loser's audit reports `hooks-edited`.

**Fix.** `lane-setup.sh` enables `extensions.worktreeConfig` and points the
worktree at its own `core.hooksPath` before `make setup` runs, so each lane owns
its hooks and the shared directory stops being written by lanes at all. Probed
first: lefthook honours `core.hooksPath`, hooks land per-worktree, the shared
directory stays empty, and the template's own post-install assertion still passes.

That is also what makes the shared directory *safe to protect strictly* — it is
the one the operator's own checkout runs. The audit therefore watches **both**
directories; watching only the resolved path would leave the highest-value
target in the `--add-dir` grant unaudited. `blast/shared-hooks-are-protected`
and the `env-prepared-before-codex` per-worktree assertion pin the two halves.

### F78 — A breach named a category but never what moved · `FIXED` · **low**

`record_node` hashed the relative path so odd path bytes could not break the
line format, and the reason line emitted bare tokens
(`— non-task-ref-edited shared-git-edited`). Nothing anywhere held a readable
path: on a misfire the operator got an alarming block and could not tell what
changed, even by diffing the retained manifests.

**Fix.** Manifest lines carry a trailing display-only path column (hash stays
first, so ordering is unchanged); a breach writes the differing lines to
`<audit-root>/<run-id>/breach.txt` and names the first offending path in the
classified reason line. Pinned by `blast/breach-names-what-moved`.

---

## Ledger addition from the ledger-reconciliation slice (D1a)

*Found 2026-08-06 while orchestrating the first-run roadmap, by running the
commands three documents assert the answer to. Minted from D1a's reservation —
see **F-number allocation** above.*

### F79 — Branch protection does not exist on this repository, and three documents say it is the merge gate · `OPEN` · **high**

**Measured, 2026-08-06, against `wielas/forge`:**

```
$ gh api repos/wielas/forge/branches/main/protection
{"message":"Upgrade to GitHub Pro or make this repository public to enable
 this feature.", "status":"403"}

$ gh api repos/wielas/forge/rulesets
{"message":"Upgrade to GitHub Pro or make this repository public to enable
 this feature.", "status":"403"}

$ gh repo view wielas/forge --json visibility,isPrivate
{"isPrivate":true,"visibility":"PRIVATE"}
```

Both classic protection and rulesets are unavailable on a private repository on
a free plan. There is no protected-branch configuration on `main` because there
cannot be one.

**And the documented fallback is not there either.** The three claim sites all
say the pre-push hook is the *advisory* backstop. On this repository it is not
installed at all:

```
$ git rev-parse --git-common-dir            → /Users/goonlab/dev/forge/.git
$ ls .git/hooks | grep -v '\.sample$'       → (nothing)
$ git config --get core.hooksPath           → (unset)
```

The Forge is not stamped from its own template, and `make protect` — the target
that installs protection — exists only in
`templates/python-service/template/Makefile`. The root `Makefile` has no
`protect` target and never had one. So the repository that *ships* the merge
gate has never run it.

**What it falsifies, exactly, in three places:**

| Where | The claim |
|---|---|
| `docs/state.md` **Proven** table | "Branch protection is a real merge gate \| a red or unreviewed merge is refused by GitHub, not by prose" |
| `CLAUDE.md` Conventions | "`main` is protected, and branch protection is the only real merge gate — the pre-push hook is advisory" |
| `Makefile:44` (`make new` output) | "(branch protection is the ONLY merge gate — the pre-push hook is advisory)" |

The `state.md` row is the one that matters, because `CLAUDE.md` routes every
cold session to that file first and the whole point of the **Proven** table is
that its rows were observed rather than believed.

**The row was not fabricated — it was proven somewhere else and filed without
its subject.** Measured in the same sitting:

```
$ gh repo view wielas/forgeboard-report --json visibility,isPrivate
{"isPrivate":false,"visibility":"PUBLIC"}

$ gh api repos/wielas/forgeboard-report/branches/main/protection
required_status_checks: {"strict":true,"contexts":["check"]}
enforce_admins:         {"enabled":true}
allow_force_pushes:     {"enabled":false}
allow_deletions:        {"enabled":false}
```

`make protect` works, and the evidence for the claim is real — on a **public**
repo, which is where protection is free. The defect is that a proven-on-the-
product row was written into the state document of a **different** repository
where the same command returns 403.

**Why it was invisible, and this is the transferable half.** The failure mode
was known, written down, and never checked. `templates/python-service/template/Makefile:59`
already anticipates this exact case in its own error string:

> `branch protection FAILED (admin rights? private repo on a free plan?)`

So the Forge predicted the failure at the point of **use** and asserted the
success at the point of **claim**, and nothing connected the two. Neither
`make verify` nor `make preflight` has a case that asks GitHub whether the gate
exists — the suite that exists to execute this repo's claims does not execute
this one. That is ADR-0003's own prohibition turned inward: a decidable
property (`gh api …/protection` returns 200 or it does not) asserted in prose,
never executed, for months.

It is also **F65 and F66 a third time**, in the one shape those two did not
cover. F65: a control anchored to a baseline the next merge redefined. F66: a
control that went quiet when its target moved. Here: a control that was never
built, and whose absence reads exactly like a control that passes, because a
claim in a table looks the same either way.

**Consequence, stated without inflation.** On `wielas/forge` the only thing
between a slice branch and `main` is the operator's habit of opening a PR. CI
runs on `pull_request` and on `push: branches: [main]` (`.github/workflows/verify.yml`),
so a red merge is *visible* after the fact but not *refused*, and a direct push
to `main` is refused by nothing at all. No bad merge has been observed — every
merge to date went through a PR — but "no gate, and it has been fine" is the
state `docs/state.md` exists to stop anyone from mistaking for "gated".

**Severity: high, and the argument rather than the label.** Not `critical`:
this repository has one committer, every merge so far went through a PR, and no
defective merge has been measured — the blast radius today is a convention
nobody has broken. Not `medium`: a false row in the **Proven** table is the most
expensive kind of error this repo can hold, because that table is the one thing
CLAUDE.md tells every context-free session to trust, and because the claim
being false is specifically ADR-0003's — *gates enforce* — asserted about a gate
that does not exist. A methodology whose founding commitment is "do not take a
model's word for a decidable property" took its own word for one.

**Fix, in the order the layers allow:**

1. **Correct the three claim sites** — done in this slice. `docs/state.md`'s row
   now names where it *was* proven (`forgeboard-report`, public) and says
   plainly that it does not hold here; `CLAUDE.md` and `Makefile` state the
   condition rather than the conclusion.
2. **Decide the gate, and it is the operator's decision, not a slice's.** Three
   options, all cheap: make `wielas/forge` public (protection is free there, and
   measured working on the sibling repo); upgrade the plan; or accept the
   pre-push hook as the only gate — in which case **install it**, because it is
   not installed, and stop calling it advisory when it is the whole gate.
3. **Add the check that would have caught this**, wherever the decision lands.
   `make preflight` is the natural home: it is the read-only readiness gate, and
   this is a readiness fact. It must distinguish three states, not two —
   *protected*, *not protected*, and **403 / cannot be asked**. A 403 is not a
   pass and it is not a failure of the repository; it is the control being
   unable to run, which F65 and F66 both settled: *a control that cannot find
   the thing it guards is not passing.* If the answer is "we accept no
   protection", the check asserts a recorded, dated waiver rather than skipping.
4. **Do not add it to `make verify`'s default suite.** It needs network and an
   authenticated `gh`, and F67 is the standing reason a live check is explicit
   and opt-in rather than a source of flake in the suite that arbitrates
   disagreements.
