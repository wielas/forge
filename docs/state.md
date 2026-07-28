# Forge — current state

**Updated 2026-07-28, after the first successful end-to-end run.**

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
4. `docs/audit-2026-07-27.md` — historical. All findings closed; kept as a
   record of what reading-only analysis can and cannot catch.
5. `docs/retro-metrics.md` — the only numbers that can falsify "Forge is
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

`make verify` — 34 cases — is the executable form of most of the above. Run it
in CI, after every `hermes update`, and after every `codex`/`claude` upgrade.

## Not proven (do not write these into a skill body)

- **Anything beyond n=1.** One chunk, six lines, written to be easy. The
  protocol held; the *judgement* is untested.
- **A bounce.** Tier 1 has never rejected anything. Until it does, its filtering
  is unproven in the only direction that matters.
- **Retries, blocks, reclaims, the respawn guard.** No run has failed yet.
- **Dependency graphs.** `graph.json` → `kanban link` has never run on a real
  multi-chunk roadmap.
- **The flywheel.** `/retro` has never executed. `retro-metrics.md` has one row.
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

Ten findings. **None were catchable by reading**, and none by `make verify` as
it then stood, because it never pushed, never invoked Codex on a real chunk, and
never left the host. A day of careful analysis the day before found seventeen
findings — and not one of these ten.

**The lesson, stated plainly so it survives a context reset:** this system's
failure modes live in the seams between tools, and seams are only visible under
load. Prefer running the smallest real thing over reasoning about the large one.

---

## Known gaps — open, with the shape of the fix

1. **Nothing sweeps merged worktrees.** `worktree` workspaces are preserved on
   completion, so each finished chunk leaves a full checkout plus a `.venv`
   behind, holding its branch. Manual today (`docs/operator-guide.md`).
2. **`forge-lane` is 194 lines** against README's "well under ~150". Pre-existing
   and now wider. Either the budget moves and `verify` enforces the new one, or
   the skill splits into a body plus `references/`. Unresolved on purpose — it
   is a judgement call, not a defect.
3. **Perfect scores are not yet distinguishable from an undiscriminating filter.**
   First verdict was 3/3 on all six dimensions. Watch whether that persists.
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
