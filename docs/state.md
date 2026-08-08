# Forge — current state

**Updated 2026-08-06, after the audit repair slices through the lane boundary
and completed-run metadata producer contract. The 2026-07-28 ladder and fault
exercises remain the live baseline; later sections distinguish repaired code
from behavior that has been re-proven on a genuine lifecycle.**

This is the orientation doc for a session starting with no context. It says what
is *proven*, what is merely *claimed*, and what to do next. `README.md` is the
architecture; this is the status.

If this file and any other file disagree, run `make verify` — it arbitrates.

---

## Read in this order

1. This file — where things stand.
2. `README.md` — the five layers and why.
3. `docs/hermes-field-notes.md` — how the substrate really behaves. Every trap
   here cost a run to find.
4. `docs/ladder-2026-07-28.md` — the second climb, on a fresh project. Sixteen
   findings with the commands that produced them, including the two that
   defeated a gate: a `make check` green that CI rejected, and a tier-2 human
   card the dispatcher claimed.
5. `docs/experiment-2026-07-28.md` — the four exercises that made the system
   fail on purpose: the deliberate bounce, the dependency edge, a killed
   worker, a red CI. Read with `docs/adr/0008-integrated-dependencies.md`,
   which is what the dependency exercise cost.
6. `docs/audit-2026-07-27.md` — historical. All findings closed; kept as a
   record of what reading-only analysis can and cannot catch.
7. `docs/retro-metrics.md` — the only numbers that can falsify "Forge is
   improving".

---

## Proven (a command was run and its output observed)

| Claim | Evidence |
|---|---|
| A chunk flows card → PR → merge, unattended | `forge-hello` board, card `t_1b7be3bb`, PR #1 merged 2026-07-28, 4 min, one run, no retries |
| The cheap driver holds the 7-section lane protocol | `deepseek-v4-flash` (the 0423 snapshot) executed every section in order, narrating its position. **The driver has since moved — see the note below the table** |
| The historical metadata split is measured | judge runs stored flat `forge.judge.v1`; chunk runs stored incomplete nested objects. The new producer contract is fixture-proven, not yet lifecycle-proven (F1/F2/F44) |
| Tier-1 review works | prejudge waited for CI, invoked `claude -p --json-schema`, returned a schema-valid verdict. Since ADR-0009 the waiting is the gate's job; since ADR-0010 the whole protocol is `scripts/prejudge-review.sh`. The scorer call itself is byte-identical to the day it was written, and `prejudge/scorer-is-the-control-arm` fails the suite if that stops being true |
| The tier-1 gate blocks, offline | `make verify prejudge` — two recorded PRs of the audited run reproduce a checked-in severity map with no gh, git or network; PR #8 exits 1 on `branch-name` + `scenario-count` |
| The tier-1 protocol runs, offline | the same fixtures drive `prejudge-review.sh --dry-run`: a block routes to a bounce with no model spawned, a clear assembles a 64 KB prompt, and a recorded 63,164-byte patch reaches the prompt file while the driver observes 2,599 bytes |
| Tier-1 discriminates | deliberate PR #6 was CI-green but assertion-free; prejudge `t_624586d7` scored scenario integrity 1 and bounced |
| A bounce reaches the rejected PR | corrected fix `t_d159a76e` resumed the completed chunk's linked worktree; role probe `t_d36ec44e` made Codex author the repair |
| Dependency gating holds at card level | D1 `t_86aa3f8d` ran while D2 `t_b9fa41cc` stayed `todo`; D2 promoted exactly when D1 completed |
| Crash-after-push recovers idempotently | `t_6e2b8528` run 8 died by signal 9 after pushing `88ad60f`; run 9 reused the same worktree/SHA and opened exactly one green PR in 55s |
| CI-red reaches a repair and returns green | PR #10 failed the injected check; `t_78f86ed9` routed `t_0a443d25` to the same worktree; Codex removed only the probe and the same PR passed |
| Tier-2 is a durable human gate | approval rerun `t_180c38a1` completed with verified child `t_2c0f1f00`; child stayed blocked, unassigned, and undispatched across dispatcher sweeps |
| A card parked on a non-existent profile is detectable | `make preflight` walks every board and WARNs; caught `forge-operator` on `forge-ladder`, the shape the first two tier-2 attempts produced |
| The template stamps green and installs hooks | `make verify` template group, plus a real repo |
| Branch protection is a real merge gate | `wielas/forgeboard-report` (public): `required_status_checks.contexts:["check"]`, `enforce_admins: true`, no force-push, no deletion. **And now on this repository too** — ruleset `mainprotect`, active 2026-08-07, requires a PR plus green `validate` and `verify`; a red PR reports `mergeStateStatus: BLOCKED`. Zero approvals required, deliberately. Asserted by `make verify SUITES=gate` (16 cases, `gh` stubbed) and reported by `make preflight` section 10, through `scripts/merge-gate.sh` (F79, F110) |
| Codex commits inside a worktree | `--add-dir "$(git rev-parse --git-common-dir)"`, measured both ways |

**The driver model moved on 2026-08-07, and that makes one Proven row
historical.** `MODEL_DRIVER` is now `deepseek/deepseek-v4-flash-0731`; every row
above measuring the lane driver was measured on `deepseek-v4-flash`, the 0423
snapshot. Both are pinned snapshots — the floating `-latest` alias was
deliberately rejected, because a pin that moves under a run is F22 verbatim. But
the consequence stands: **the first genuine product run will also be the first
run on this driver**, which is a second new variable alongside the run itself,
against this file's own rule of one at a time. That is an accepted operator
choice, recorded here so the run stays interpretable — if the lane misbehaves,
the driver is in the cause set.

A second, independent climb on 2026-07-28 (`ladder-forge`, three chunks, one
per rung) reproduced the whole chain and found eight more findings — see
[`docs/ladder-2026-07-28.md`](ladder-2026-07-28.md). Both fixes from the first
run were confirmed working under load: Codex never read `forge-lane`, and it
hit zero sandbox denials because §3 had built the venv first.

`make verify` is the executable form of most of the above. Its current count and
the linked-worktree deployment caveat are recorded under “Environment as of
this writing” below. Run it in CI, after every `hermes update`, and after every
`codex`/`claude` upgrade.

## Not proven (do not write these into a skill body)

- **A genuine idea through the whole lifecycle.** The commissioning chunks are
  deliberately small fault probes; none began as a product idea and passed
  through scope, architecture, roadmap and completed implementation chunks.
- **The corrected integration gate.** The first real graph proved card-level
  gating but also proved `done` means PR-open, not merged. ADR-0008 and the
  atomic-parent/merged-PR guards are static and deployed to the lane; a fresh
  graph still needs to prove the corrected path live.
- **Timeout/reclaim and circuit-breaker recovery.** Signal-9 retry is proven;
  stale-heartbeat reclaim and a tripped retry limit are not.
- **The flywheel.** `/retro` has never executed. `retro-metrics.md` has several
  rows, all written by hand after runs rather than by the ceremony.
- **The Telegram approval flow.**
- **Provider terms for automated subscription use** — settled for what *works*
  (ADR-0004), never for what is *permitted*.

---

## How the first run was actually achieved — reuse this

Not by planning. By a ladder where **each rung adds exactly one new thing that
can break**, so a failure names its own cause:

| Rung | New variable | Found |
|---|---|---|
| 1 | none — real repo, no agents | the pre-push hook blocked the push that *creates* `main` |
| 2 | `codex exec`, driven by hand, no board | no network in sandbox; no `.venv`; reads not sandboxed |
| 3 | the board and dispatcher | the driver model holds the protocol; approvals strand |

Climbed a second time on 2026-07-28 against a fresh project, with the gates
attacked rather than merely exercised. Eight more findings, again none
catchable by reading or by `verify` as it stood:

| Rung | New variable | Found |
|---|---|---|
| 1 | none — real repo, no agents | the branch guard failed open and asked the wrong remote; no interpreter pin, so local ran 3.14 and CI 3.12 |
| 2 | `codex exec`, driven by hand, no board | a warm `.ruff_cache` returned a green CI rejected; `--add-dir` grants all of the shared `.git` |
| 3 | the board and dispatcher | the tier-2 *human* card was dispatched to a lane |

Ten findings. **None were catchable by reading**, and none by `make verify` as
it then stood, because it never pushed, never invoked Codex on a real chunk, and
never left the host. A day of careful analysis the day before found seventeen
findings — and not one of these ten.

**The lesson, stated plainly so it survives a context reset:** this system's
failure modes live in the seams between tools, and seams are only visible under
load. Prefer running the smallest real thing over reasoning about the large one.

---

## Known gaps — open, with the shape of the fix

1. ~~**Nothing sweeps merged worktrees.**~~ **Resolved 2026-08-06.**
   `make worktree-sweep PROJECT=<abs-path> [APPLY=1]` reclaims them: dry-run by
   default, path-bounded to `<project>/.worktrees/`, and it removes only a
   worktree that is clean *and* whose head branch has a merged PR **on the
   remote**. Merge state is not a local ancestry test, because a squash merge
   leaves no local ancestry and a local test would sweep nothing. Branch
   deletion is `git branch -d`, never `-D`; when `-d` refuses the worktree is
   still reclaimed and the branch is reported `RETAINED`. A merged PR is not on
   its own enough: its `headRefOid` must equal the worktree's HEAD, because "was
   a PR with this branch NAME ever merged" is answered yes forever — including
   for a branch that was merged, deleted, and rebuilt with new work.

   The group is **29 cases** as of 2026-08-07
   (`./scripts/verify.sh --list | grep -c '^sweep/'`), and CI runs it. Every new
   case was mutation-tested — bug reintroduced, suite re-run, the named case
   confirmed red, tree restored — and two of them were rewritten because of it,
   having passed with their own defect back in place. *The harness is a scratch
   script, not a checked-in artifact: this paragraph records what was done, and
   is not something `make verify` can arbitrate.*

   **The same slice closed F19.** `make new` now requires an absolute, durable
   `DEST` — `/tmp`, `/private/tmp` and `$TMPDIR` are refused, with symlinks
   **and `..`** resolved to a fixed point before judging, and the refusal names
   a durable location instead of only saying no. The judgement is on the final
   `<dest>/<name>`: `NAME` is one path component and goes through the same
   guard, because validating `DEST` and then appending `NAME` to it is not
   validating what gets stamped. The old `DEST ?= ..` default is gone; a
   *relative* default is what put `forgeboard-report` in `/private/tmp`.

   **What this does not reach.** The sweep is path-bounded on purpose, so it
   only sees `<project>/.worktrees/`. This repo's own stale slice worktrees live
   in `/Users/goonlab/dev/forge-slices/*` — a sibling directory, created by hand
   rather than by the dispatcher — and the sweep reports them `REFUSE`. There
   were **16** of them on 2026-08-07 (`git worktree list`), a number that moves
   whenever a slice is opened or cleaned up; the count is not the point and no
   check asserts it. They are still a manual job. See F80.
2. ~~**`forge-lane` exceeds the skill body budget.**~~ **Resolved 2026-07-29**
   by splitting the budget rather than the skill. The seven ceremonies are
   43–89 lines against a 150 limit; `forge-lane` is 283 against a new 300. It
   is not a ceremony — it is the whole job of one dedicated unattended profile,
   so the context cost that justifies 150 barely applies, and its length is
   accumulated measured failures rather than prose. `cli/skill-body-budget`
   now enforces both numbers. The lane's 17 lines of headroom are deliberate:
   the next addition has to argue for itself.

   **Reopened in part, 2026-08-05.** That resolution raised a limit to admit the
   file, which is exactly what `forge-prejudge` then did without a limit at all:
   404 lines against 27/29/32 for the other three profiles, 144 of them
   executable bash. ADR-0010 makes that one a program and gives both prompt
   kinds a number (`cli/soul-body-budget` 60, `cli/no-programs-in-souls` 6). The
   lane is now at **299 against 300 with 12 fenced blocks**, and it is the same
   shape — but it is the most load-bearing proven artifact in the repo, four
   climbs depend on it, and this file says never to test two unknowns at once.
   Measured as audit **F64**; deliberately untouched; its own slice.

   **Sliced, bounced twice, narrowed and live-validated 2026-08-06 (F64 → `FIXED`).**
   §2/§3 and §5's audit became `scripts/lane-setup.sh` and
   `scripts/lane-blast-radius.sh`, and the lane is **299/300** after the metadata
   producer gate. The first
   post-merge review proved the new control fail-open: its baseline was writable
   by Codex, hook identity was discarded, Git inspection errors read as clean,
   and a failed final audit could be replayed after restoring the breach
   (F69–F74). The **second** review proved the repair fail-*closed* on the wrong
   things — it froze the whole shared `.git`, so a sibling lane's commit, any
   `git fetch`, and pre-existing malformed history each blocked a clean chunk
   (F75, F76). The audit now protects a named set and states what it cannot
   protect; `make verify` is 117/0/3 with 35 lane cases, five of them positive
   cases pinning those false positives shut.

   The opt-in live probe was re-run against the audit that shipped —
   setup → immutable capture → real Codex commit → final audit clean, run
   `verify-codex-1786010605-22305`. The earlier `…-80398` run proved the
   retired design and is not evidence for this one.

   **Deliberately not sliced: §4's `codex exec` invocation, and §1a.** §4 is the
   identified next lever — as a script it would *enforce* the three measured
   flags (`< /dev/null`, `--add-dir`, `UV_CACHE_DIR`) rather than describe them,
   and would free ~25 lines of bullet rationale — but it is a different unknown
   (how Codex is launched) and belongs in its own slice. §1a is decision logic,
   which ADR-0010 puts in the prompt, not in a script.
3. **`start-chunk`/`end-chunk` may be redundant** — `open-questions.md` has asked
   since day one whether they should merge. The lane never invoked them.
4. ~~**This repository has no merge gate at all**~~ **Mostly closed 2026-08-07**
   (audit **F79**). On 2026-08-06 `wielas/forge` was private on a free plan, both
   `…/branches/main/protection` and `…/rulesets` returned 403, and no pre-push
   hook was installed — the repository that *ships* the merge gate had never run
   one. It is now public, and ruleset `mainprotect` requires a pull request,
   blocks deletion and non-fast-forward pushes, and requires the `validate` and
   `verify` checks to pass. A red PR reports `mergeStateStatus: BLOCKED`.

   **And the claim is executed now, which is the half that mattered.**
   `scripts/merge-gate.sh` asks the repository directly — both mechanisms, since
   `make protect` creates *classic* protection and no rulesets — and separates
   four outcomes: *gated* (a PR rule **and** required status checks, naming
   `validate` and `verify`) exits 0; *the gate exists and does not gate* exits 3,
   which covers both a PR rule with no required checks **and** required checks
   with no PR rule, since either alone lets a change onto `main` unchecked; *no
   applicable rule* exits 4; and *cannot be asked* (403, no `gh`, no access)
   exits 2 and **WARNs rather than passing**, because a control that could not
   run has not passed (F65/F66).

   `make preflight` section 10 reports that verdict, and `verify.sh`'s `gate`
   group drives the primitive against a `gh` stub for **16 cases**, including the
   two shapes the first version of this check called gated. An earlier draft of
   this paragraph claimed all four branches were exercised while nothing
   exercised any of them; that check shipped broken in four ways and CI stayed
   green throughout (**F110**).

   Two smaller facts worth keeping: `required_approving_review_count` is **0** on
   purpose — every PR here is self-authored, so the gate is CI rather than a
   second person — and `strict_required_status_checks_policy` is **false**, so a
   branch need not be up to date with `main` to merge. Tightening the latter is
   reasonable once nothing is stacked.

---

## Where the work resumes (as of 2026-08-06)

The tier-1 arc is **parked, not stalled**, and the thing it waits on is real
reviews rather than effort. Read `docs/open-questions.md` — "Does the Opus
scorer earn its latency?" — before touching anything under `prejudge`. It
carries the two board queries, the pre-committed decision rule, and the reason
divergence is the *wrong* instrument for that question.

**Blocked on data (no action available):**

- **ADR-0011 / D9.5.** Needs ~10 post-gate reviews. Accrues by itself now that
  routing is derived and the scorer still asserts. **Do not add `verdict` to
  `STAMPED` first** — that ends the measurement permanently.
- **Phase 4 — S6 incremental review** (`--resume "$session_id"`, `supersedes`,
  `findings_addressed`, stable finding ids, bounce budget 2). Edits the pinned
  `claude -p` call, so it is gated on ADR-0011. `session_id` and `cost` are
  *already* contracted and stamped — S6 was never blocked on a schema change,
  only on the pin.
- **Hiding `verdict` from the model** (F29's remainder). One-way, and therefore
  **the last step of the entire arc**, after D9.5 is answered.

**Unblocked, and the right thing to pick up next:**

1. ~~**F64 — slice, narrow and live-validate `forge-lane`**~~ **DONE 2026-08-06.**
   117/0/3 offline with 35 lane cases, and the live probe re-run against the
   shipped audit (`verify-codex-1786010605-22305`). F68–F78 record the seams;
   F75/F76 are why the audit protects a named set rather than the whole `.git`.
2. **Schema canonicalisation — producer contract implemented 2026-08-06.**
   `rubrics/run-metadata-contract.json` maps each producer profile to the only
   completed-run schemas it may emit; chunk and gate now have Draft 2020-12
   schemas beside the unchanged judge schema. `metadata/` runs a recorded PR
   through the real gate producer, rejects shape and semantic contradictions,
   and checks literal block producers plus the metrics consumer against the
   registry regex. `forge-lane` gates its complete flat file before completion.
   The lane is 299/300; §4 is now the only honest lever for another protocol
   addition.
3. **Next: prove the producer on reality** — one genuine lifecycle run, then an
   explicit snapshot-based sweep of its completed rows. F1/F2/F44 and F26 stay
   open until the card is valid, the consumer reads it, and no model-authored
   block reason falls outside the registry. F67 is why this is opt-in, not part
   of the default suite.
4. **Then discover and contract metered-driver telemetry** — establish what
   Hermes exposes before adding F48's optional chunk `cost` block. Do not stamp
   invented zeroes for a signal the substrate cannot report.
5. **Hygiene** — F36, F53/F55, F34. F34's 4-line note now fits.

Ledger and rationale for every F-number: `docs/audit-forgeboard-2026-07-30.md`.

---

## Next test, and what it must be

The next run should introduce **exactly one** new variable. In rough order of
value:

1. **A genuine idea through the full lifecycle**, including a fresh live proof
   of ADR-0008's corrected dependency path.
2. **Timeout/reclaim and circuit-breaker recovery**, after the genuine run so
   the remaining lifecycle failures are tested separately.

Do **not** run these together. The whole reason the first run succeeded is that
nothing was ever tested with two unknowns in play.

The deliberate bounce answered the old watch item: the rubric can say something
other than 3. It scored scenario integrity 1 and routed an executable fix.

---

## Environment as of this writing

```
Hermes 0.19.0 · codex-cli 0.145.0 · Claude Code 2.1.220 · gh 2.96.0
lefthook 2.1.10 · uv 0.11.32 · copier 9.17.0
mini: Goons-Mac-mini.local, gateway supervised by launchd, dispatch every 60s
profiles: forge-orchestrator (glm-5.2) · forge-codex-lane, forge-prejudge,
          forge-digest (deepseek-v4-flash-0731) · codex pinned gpt-5.6-sol xhigh
```

`make verify` on this linked worktree: 126 passed / 3 failed / 7 skipped. The
three failures are the expected live SOUL-sync checks: deploying the new SOULs
before this contract reaches `main` would leave workers referring to a contract
that is not installed yet. Four live profile-path checks also skip outside the
main checkout. After merge, run `./hermes/profiles-bootstrap.sh`; the expected
main-equivalent count is 133 passed / 0 failed / 3 skipped.

`make preflight` on the mini before this slice: PASS 82 / WARN 3 / FAIL 0. It
now reports one FAIL until this branch merges, and that is the check working
rather than a defect: §7 reaches the validator through
`~/.forge/repo/scripts/validate-metadata.py`, `~/.forge/repo` points at the main
checkout, and `main` does not carry that script yet. It clears on merge. Before
this slice the same missing dependency was silent — `uv` was declared optional
and the metadata suite skipped without it, so a host that could not run a lane
to completion still reported a green verify and a green preflight.
