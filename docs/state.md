# Forge — current state

**Updated 2026-07-28, after a second full climb of the ladder on a fresh
project (`ladder-forge`). The first run proved the chain runs; this one
attacked it.**

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
4. `docs/ladder-2026-07-28.md` — the second climb, on a fresh project. Eight
   findings with the commands that produced them, including the two that
   defeated a gate: a `make check` green that CI rejected, and a tier-2 human
   card the dispatcher claimed.
5. `docs/audit-2026-07-27.md` — historical. All findings closed; kept as a
   record of what reading-only analysis can and cannot catch.
6. `docs/retro-metrics.md` — the only numbers that can falsify "Forge is
   improving".

---

## Proven (a command was run and its output observed)

| Claim | Evidence |
|---|---|
| A chunk flows card → PR → merge, unattended | `forge-hello` board, card `t_1b7be3bb`, PR #1 merged 2026-07-28, 4 min, one run, no retries |
| The cheap driver holds the 7-section lane protocol | `deepseek-v4-flash` executed every section in order, narrating its position |
| Both metadata schemas populate | `forge.chunk.v1` and `forge.judge.v1` complete on the real cards |
| Tier-1 review works | prejudge waited for CI, invoked `claude -p --json-schema`, returned a schema-valid verdict |
| The template stamps green and installs hooks | `make verify` template group, plus a real repo |
| Branch protection is a real merge gate | a red or unreviewed merge is refused by GitHub, not by prose |
| Codex commits inside a worktree | `--add-dir "$(git rev-parse --git-common-dir)"`, measured both ways |

A second, independent climb on 2026-07-28 (`ladder-forge`, three chunks, one
per rung) reproduced the whole chain and found eight more findings — see
[`docs/ladder-2026-07-28.md`](ladder-2026-07-28.md). Both fixes from the first
run were confirmed working under load: Codex never read `forge-lane`, and it
hit zero sandbox denials because §3 had built the venv first.

`make verify` — 43 cases — is the executable form of most of the above. Run it
in CI, after every `hermes update`, and after every `codex`/`claude` upgrade.

## Not proven (do not write these into a skill body)

- **Anything beyond n=2.** Two board-driven chunks, both small and both
  written to be easy. The protocol held twice; the *judgement* is still
  untested, because nothing has yet been hard enough to judge.
- **A bounce.** Tier 1 has never rejected anything. Until it does, its filtering
  is unproven in the only direction that matters.
- **Retries, blocks, reclaims, the respawn guard.** No run has failed yet.
- **Dependency graphs.** `graph.json` → `kanban link` has never run on a real
  multi-chunk roadmap.
- **The flywheel.** `/retro` has never executed. `retro-metrics.md` has two
  rows, both written by hand after a run rather than by the ceremony.
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

0. **The tier-2 card is not reliably a human gate.** Measured 2026-07-28: an
   approval created the tier-2 card with `assignee="forge-prejudge"` and
   `status="running"` despite the SOUL asking for neither, the dispatcher
   claimed it, and tier 2 became a second tier 1 by the model that had just
   approved. Only that run noticing and blocking itself prevented a
   self-approval. The first mitigation was itself impossible: the tool requires
   an assignee, `kanban_update` does not exist, and an unassigned
   `initial_status=blocked` probe was promoted and dispatched to the global
   `builder` default. The SOUL now uses the CLI to create on a non-spawnable
   sentinel, emits a sticky human block, unassigns, and reads the card back.
   The first live rerun proved that state was durable, then found that nested
   CLI creation stamped `created_by=user`; the completion kernel rejected the
   hand-off manifest and the worker improperly retried without it. Creation now
   stamps the current task id and a rejected manifest must fail closed.
   **Re-run approval once more before testing bounce.**
1. **Nothing sweeps merged worktrees.** `worktree` workspaces are preserved on
   completion, so each finished chunk leaves a full checkout plus a `.venv`
   behind, holding its branch — measured at **50 MB per chunk**, and
   `gh pr merge --delete-branch` fails every time because the worktree still
   holds the branch. Manual today (`docs/operator-guide.md`).
2. **`forge-lane` is 220 lines** against README's "well under ~150". Was 194;
   the 2026-07-28 ladder run added the `--add-dir` blast-radius note and the
   ruff-cache warning, so this got worse rather than better. Either the budget moves and `verify` enforces the new one, or
   the skill splits into a body plus `references/`. Unresolved on purpose — it
   is a judgement call, not a defect.
3. **Perfect scores are not yet distinguishable from an undiscriminating filter.**
   Now 3/3 on all six dimensions **twice in two chunks** (2026-07-28). Both were
   written to be easy, so this still is not evidence either way — but the
   pattern is now a streak, and only a deliberate bounce will break the tie.
4. **`start-chunk`/`end-chunk` may be redundant** — `open-questions.md` has asked
   since day one whether they should merge. The lane never invoked them.

---

## Next test, and what it must be

The next run should introduce **exactly one** new variable. In rough order of
value:

1. **A chunk that should bounce.** Deliberately ship scenario theater — an
   assertion-free Then-clause — and confirm tier 1 catches it, creates the fix
   card, and the fix card gets picked up. This exercises the whole bounce path,
   which has never run, and it is the cheapest way to learn whether the rubric
   discriminates.
2. **Two chunks with a real dependency edge**, to exercise `graph.json` →
   `kanban link` and gated promotion.
3. **A chunk with genuine ambiguity**, to test judgement rather than protocol.

Do **not** run these together. The whole reason the first run succeeded is that
nothing was ever tested with two unknowns in play.

Two things ride along free on whichever you pick, because they need only
looking rather than a run of their own:

- **Gap #0's mitigation.** The tier-2 read-back has never executed. It is
  exercised by an *approve*, not a bounce — so if you run the bounce test
  first, this stays unproven and must be checked on the next approval instead.
- **Whether the rubric can say a number other than 3.** Two chunks, twelve
  dimension scores, twelve 3s.

---

## Environment as of this writing

```
Hermes 0.19.0 · codex-cli 0.145.0 · Claude Code 2.1.220 · gh 2.96.0
lefthook 2.1.10 · uv 0.11.32 · copier 9.17.0
mini: Goons-Mac-mini.local, gateway supervised by launchd, dispatch every 60s
profiles: forge-orchestrator (glm-5.2) · forge-codex-lane, forge-prejudge,
          forge-digest (deepseek-v4-flash) · codex pinned gpt-5.6-sol xhigh
```

`make preflight` on the mini: PASS 78 / WARN 3 / FAIL 0.
