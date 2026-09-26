# Epic — hands-free Forge

**Opened 2026-09-24** from the JobApp (`jobapp-second-instance`) and redglass
(`redglass-run-1`, repo `wielas/vault`) runs; revised the same day after a
gap review. Nothing here is built yet. Item ids use track prefixes (`Q`, `FL`,
`MS`, `GW`, `EN`, `PL`, `WL`) so they never collide with audit findings
(`F<n>`) or roadmap chunks (`CHUNK-<n>`).

## Why

Forge was meant to be a "dream and do" tool: scope an idea interactively, then
let the machine build it. After two near-complete runs it is the opposite — the
unattended path costs more operator attention than doing the work by hand.

Lane compute was **2.4 h** on JobApp and **~8 h** on redglass, but the runs
spanned **8 and 20 days**. Every chunk needs at least one human round trip —
`/judge`, merge, then unblock the dependent child — so throughput equals the
operator's availability. Redglass CHUNK-15–19, driven interactively, merged
five chunks in about a day.

| Baseline | JobApp | redglass |
|---|---|---|
| Cards per chunk | 28 / 15 = 1.9 | 70 / 20 = 3.5 |
| Operator actions on the board per chunk (`make metrics`) | 42 / 15 = 2.8 | 37 / 20 = 1.9 |
| …plus, per chunk, a `/judge` session and a merge | yes | yes |
| Chunks merged without the operator | 0 % | 0 % |
| Lane-chunk PR open → merge, median (tail) | 3.4 h (30 h) | ~5 h (23 h; one judge card waited 334 h) |
| Chunks routed to a human by the roadmap | 7 / 16 | 8 / 20 |
| Tier-1 bounces | 0 of 6 chunks | 0 of 9 chunks |
| Chunks where tier-2 caught a real defect | 3 of 5 | 0 of 9 * |

\* Several redglass tier-2 cards were closed without a real `/judge` run
("merged", "Approved", CHUNK-8 "merged out of band") — the operator was
already skipping the step.

Two findings shape the design:

- **Neither tier caught the biggest defect.** The redglass CHUNK-15.0 probe
  found the core gates fail-open (demand cleared by another country's evidence;
  economics "moderate" with 15/16 inputs assumed; risk passing with safety
  unknown) in code that scored 3s at both tiers. The advancing fixtures held
  exactly one claim. Per-chunk scoring cannot see system-level wrongness.
- **What caught JobApp's defects was execution, not taste.** C21's bounce was
  two mutation-proven blockers; C17's finding was a provably dead predicate.
  An agent that runs things did that, and that can be automated.

The evidence ledger is the appendix at the end of this file.

## Decisions — 2026-09-24

1. **A verifier pass merges — eventually.** The deterministic gate plus an
   unattended verifier that *executes* (mutation probe of the frozen
   scenarios, `make check` on the merged tree) is enough to merge; the
   operator is not a per-chunk step, and the milestone probe is the backstop.
   The verifier runs **recommend-only** until the mutation probe and the
   milestone probe exist and a shadow run meets the flip criterion below.
2. **The operator's attention goes through the Hermes gateway** — a milestone
   checkpoint and a daily digest that say plainly what was done, and replies
   that act on the board.
3. **Retire what the runs disproved** — child judge/fix cards, the tier-1
   `claude -p` scorer once the verifier supersedes it, `start-chunk`/`end-chunk`
   as separate ceremonies, and `verify` cases that guard retired machinery.
4. **Scope, architect and roadmap stay interactive.** Architect becomes a
   *practical* stage: it spikes what can be done, how, and with what effort,
   and the plan adjusts on the spot when something turns out cheap or very
   expensive. Roadmap stays with the operator because it sets the contract
   every chunk is verified against; revisit after run B.
5. **The proving vehicle is a new small Python project.** Its three milestones
   are the three proving runs, one new variable each. Python because the
   template, gates and mutation tooling exist for it — any other stack would
   put a second template on the critical path.
6. **A passing milestone proceeds on its own.** The checkpoint informs; `park`
   or `redirect` stops or steers the run. A failed probe or a cost overrun
   against the architect's estimate waits for the operator.
7. **Hermes stays the orchestrator; the implementer is swappable.** The
   overseer drives on the OpenAI subscription through Hermes's native OAuth.
   Which harness implements the cheap and local tiers — Pi or Hermes-native —
   is decided on measured data (EN3), not now.

## Principles

Every item below follows from these; a new item that breaks one needs an ADR.

- **Scripts run protocols; models make judgements.** Board writes, handoffs,
  merges and quota parking are programs (ADR-0010, extended to the lane). The
  CHUNK-8 storm was a cheap model making board calls.
- **Numbers come from scripts, never from a model.** Digests and checkpoints
  may phrase, never compute — Forge once published a bounce rate of 0.00 for a
  run with 12 bounces.
- **Verification executes.** Read-and-score never bounced anything in these
  runs; mutation, merged-tree checks and probes did the catching.
- **One card per chunk, one message per decision.** No decision, no message.
- **Scarcity order:** operator attention, then OpenAI quota, then dollars.
- **Authority moves to the machine only after its safeguard exists and has
  been measured.** One new variable per run.

## Roles

| Role | Who | Runs on | When |
|---|---|---|---|
| Operator | you | — | scope, architect, roadmap (interactive); milestone checkpoints; exceptions |
| Planner | Claude Code, interactive | Claude subscription | `/scope`, `/architect` (with spikes), `/roadmap` |
| Overseer | `forge-overseer` (Hermes) | GPT-6-Astra, OpenAI OAuth | milestone gates, exceptions, triage, contract amendments — never per chunk |
| Lane | `forge-codex-lane` driving `scripts/lane.sh` | cheapest driver model | per chunk |
| Implementer | Codex, Pi or Hermes-native, by tier | cheap: OpenRouter · strong: Codex (OpenAI) · local: 128 k model | per chunk |
| Verifier | `forge-verifier` (today's `forge-prejudge`) | cheapest driver + deterministic tools | per chunk |
| Digest | `forge-digest` | cheap model relaying script output | daily |

Codex and the overseer may draw on the same OpenAI quota — unverified; run B
measures it. If they do, the cheap tier becomes the default implementer and
Codex the escalation tier (EN4).

## North-star metrics

`/retro` and `make metrics` lead with these (GW6). Targets are proposals.
Baselines are JobApp / redglass; *derived* values are arithmetic over measured
counts — recompute them rather than trusting this table.

| Metric | Baseline | Target |
|---|---|---|
| Operator actions per merged chunk (board + one merge each; judge sessions not counted) | ≥ 3.8 / ≥ 2.9 *(derived)* | ≤ 0.3 |
| Chunks merged without the operator | 0 % / 0 % | ≥ 80 % |
| Lane-chunk PR open → merge, median | 3.4 h / ~5 h | < 1 h |
| Cards per chunk | 1.9 / 3.5 *(derived)* | 1 plus one gate card per milestone |
| Human-implemented chunks | 7 / 16 and 8 / 20 | ≤ 1 per milestone, by exception |
| Defects the milestone probe catches before the operator does | n/a | tracked |
| Architect estimate vs actual cost, per milestone | n/a | tracked |

## Target flow

```
/scope → /architect (spikes, effort ledger) → /roadmap      interactive
        │  milestones, each closed by a gate card carrying a whole-system probe
        ▼
forge run <project>                                          one command
        ▼
chunk card ─ lane.sh ─► PR ─ handoff ─► forge-verifier         (same card)
   ▲                                      │ gate · merged-tree check · mutation probe
   └── reopen / request_changes ◄─────────┤ fail (budget 2, then exception)
                                          ├ pass, merge mode ──► merge ─► done ─► children promote
                                          └ pass, recommend ───► blocked (needs_input)
                                                operator merges ─► merge-watcher ─► done
milestone chunks done ─► gate card: probe ─► overseer ─► checkpoint
      probe pass ─► gate done ─► next milestone starts  (reply park / redirect to stop or steer)
      probe fail or cost overrun ─► gate blocked ─► waits for the operator
daily ─► metrics script ─► forge-digest ─► Telegram: landed · in flight · waiting on you · spend
```

Hermes 0.21.5 supplies the mechanism: same-card review (`request-review`,
`request-changes`, `reopen-review`) routes changes back to the original
implementer, and `_parents_satisfied` releases a child only when its parent is
`done` or `archived`, so holding a card short of `done` until merge gates its
children natively. ADR-0007 named switching to `review-required` as its own
fallback if child cards proved unreliable; the CHUNK-8 card storm and C20's
respawn-guard trap are that proof. The recommend-only state machine was
probed on an isolated board (appendix).

---

## Track Q — quick fixes

**Q1. Codex's plain-text usage limit is a usage limit.** redglass CHUNK-6 and
CHUNK-8 got "You've hit your usage limit … try again at 11:55 AM" with no
`rate_limits` object; `quota-window.py` returned `unknown no-rate-limit-data`,
`codex-run.sh` exited 4 ("not a usage limit"), and the lane improvised a ~3 h
heartbeat wait. *Done when* a `quota/` fixture of that event parks with the
parsed reset time.

**Q2. Skills cite rubrics through `~/.forge/rubrics/`.**
`skills/judge/SKILL.md:18` and `skills/end-chunk/SKILL.md:46` use bare
`rubrics/…`, which resolves against the project cwd; redglass's closing
session concluded the rubrics did not exist. *Done when* `verify` rejects a
bare `rubrics/` path in any skill body, as it already does for `scripts/`.
**Settled in S1:** the form is `~/.forge/rubrics/`, not `~/.forge/repo/rubrics/`
as first written here. `install.sh` symlinks both, and the shorter one is
already what `forge-lane` §7, the three SOULs, `prejudge-review.sh` and the
control-arm fixture use; a second spelling of one directory is the drift this
item exists to stop.

**Q3. Operator setup** *(operator actions)*. Remove the unused `builder`
profile: it holds the same `TELEGRAM_BOT_TOKEN` as `default`, so the gateway
serves only `default` and every forge profile's bot is silent. It is also the
gateway's `kanban.default_assignee`, so that setting goes with it. No open
card on any board is assigned to it (checked 2026-09-25), and Forge
references it only in comments. Then authenticate Hermes against the OpenAI
subscription. *Done when* `hermes gateway status` shows no conflict and a
Hermes profile can call the overseer model.

**Q4. The epic is where a fresh session looks.** Link this file from
`docs/state.md`'s next-action section and from the `CLAUDE.md` router, keeping
the `docs/` group green.

## Track FL — flow

**FL1. ADR-0019: one card per chunk, same-card review, the verifier merges.**
*(Written in S1:* `docs/adr/0019-one-card-per-chunk-same-card-review.md`. *It is
a decision, so it has no* done when *and adds no proven claim to* `state.md`.*)*
Supersedes ADR-0007 D7.1–D7.3; changes ADR-0008's *mechanism* (native parent
gating) but not its rule (children build on merged parents). Records the
backtest and the new risk: a machine approval can reach `main`. Mitigations:
execution-based verification, the milestone probe, a revert path, and branch
protection **where it exists** — both product repos so far are private on a
free plan (`merge-gate.sh` exit 5), where `gh pr merge` will merge a red PR
and the verifier is the only gate. Defines recommend-only, merge mode and the
flip criterion.

**FL2. The lane is a program.** `forge-lane`'s remaining prose sections
(read card, parent check, implement, push, hand off) become `scripts/lane.sh`;
the SOUL shrinks to "run it, terminate on its exit code" (ADR-0010's pattern,
proven on prejudge). §1a's parent-merged check is deleted — native gating makes
it unreachable. The driver can then run on the cheapest model with almost no
skills (feeds EN5). *Why:* the driver made 1,166 tool calls over 28 sessions,
and its free-form board calls produced the CHUNK-8 storm. *Done when* the lane
cases pass, and the checks that anchor on `forge-lane` §3/§5's literal
`~/.forge/repo` call style (`verify.sh`, `preflight.sh`) are re-anchored on
`lane.sh` — confirmed by comparing PASS/skip counts before and after, since a
lost anchor turns into a skip, not a failure (CLAUDE.md).

**FL3. Same-card handoff and bounce re-entry.** `scripts/lane-handoff.sh`
moves the card to `review` (`hermes kanban request-review <task> --reviewer
forge-verifier --summary … --metadata …`); no model creates cards. On a bounce
the lane re-enters the same worktree, branch and PR with the verifier's reasons,
and **resumes the implementer's own session** — cached context and its earlier
exploration are reused instead of re-read. The handoff script is
harness-agnostic, so human-tier chunks finished in Claude Code or Pi end the
same way (redglass left three such cards open). *Done when* one bounce round
trip runs on fixtures and the `failing-prereq` block class (7 blocks in these
runs) cannot occur.

**FL4. `forge-verifier` v1 — gate, merged-tree check, recommend-only.**
Rename `forge-prejudge` rather than add a profile. Keep `prejudge.sh`'s
deterministic stage, including `ci-state`, which the verifier must enforce
itself because an ungated repo will not. Execute in a **separate temporary
worktree** from the PR head — merging `origin/main` into the card's own
worktree would dirty the tree the implementer resumes on a bounce — then run
`make check`. Outcomes:
- fail → `request-changes` with actionable reasons;
- pass, recommend-only → `block --kind needs_input` with a decision-first
  message (GW1); the operator merges on GitHub, and a **merge-watcher** cron
  completes cards whose PR merged (`complete` accepts `blocked → done`);
- operator disagrees → `forge bounce <task> "<reason>"`: `unblock` then
  `reopen-review` back-to-back, re-checking the end state because a dispatcher
  tick can land between the two;
- pass, merge mode → `gh pr merge --squash`, then complete.

~~Same-kind re-blocks route to triage at `BLOCK_RECURRENCE_LIMIT=2`, so a chunk
gets at most two operator disagreements before it becomes an exception.~~
**Amended in S3, on measurement:** that route strands the chunk. A card in
`triage` refuses `complete`, `complete --force`, `promote` and `unblock`, and its
one CLI exit (`specify`) calls an auxiliary model and returns the card to an
*implementer*, never to `done` — so a merged PR whose card reached triage can
never be completed and its children never release (ADR-0019's dated correction).
The verifier therefore never re-blocks with the last block's kind, and the budget
is counted by the script from `changes_requested` events. *Why:* redglass PR #9's
union with post-CHUNK-8 `main` failed 5 tests neither branch failed alone.
*Done when* fixture-proven, including a red-CI PR on an `UNAVAILABLE` repo that
must not merge, and the disagree path under a live dispatcher.

**FL5. `forge-verifier` v2 — the mutation probe.** Mutate implementation lines
inside the diff's hunks (evaluate `mutmut` / `cosmic-ray` before writing one)
within a time budget; surviving mutants become deterministic, actionable
bounce reasons (file, line, the mutation, what no test detected). *Why:* JobApp
C21, C17, and C23's check that could not fail (#41 → #44). *Done when*
recorded replays of C21 and C17 bounce, an assertion-free PR in the style of
the July ladder's `t_624586d7` bounces, and redglass's all-3s PRs pass.

**FL6. Bounce budget → exception.** Two bounce rounds, then one decision-first
exception to the operator. *Done when* (**proposed in S3 — this item had no
done-when**) two `request-changes` rounds on one card are followed by a
**completable** decision-first block rather than a third bounce, executed on the
real kernel, and the count is **windowed**: only the rounds since the last
operator decision (`unblocked` / `review_reopened`) count, so a chunk the
operator deliberately sends back gets its budget again instead of re-tripping the
exception on its first bounce. Escalating to a stronger implementer instead
arrives with EN4 — Hermes `set-model` changes the lane *driver's* model, not the
implementer's, so tier escalation needs EN1's implementer config first.

**FL7. The blast-radius audit ignores sibling lanes.** JobApp C11 blocked on a
sibling's branch-tracking entry in `.git/config`; redglass CHUNK-9 blocked
because a sibling `git pull` moved `main`. *Done when* fixtures of both pass
clean and the existing positive cases still fire.

**FL8. Spend caps per board** *(moved off S3 in S3 — row S3c, beside EN1/EN4)*.
An OpenRouter dollar cap and a card-creation rate limit per parent; exceeding
either parks the board and sends one message. FL2 removes the storm's cause; this
bounds the next unknown one once cheap implementers bill per token — which is
EN1's configuration and EN4's ladder. Run A implements on Codex against the
OpenAI subscription, so until then there is no per-token spend to cap, and a cap
on a number nothing produces is an unmeasured guard.

**FL9. Quota parking without a waiting worker.** Hermes `schedule` parks a card
until `unblock` — it has no timer, and `scheduled_at` is not on the CLI. The
lane schedules with the parsed reset time in metadata; a `hermes cron` waker
unblocks due cards; past a threshold, the card re-routes to the cheap tier
(EN4). Until then Q1 plus ADR-0016's in-lane park covers runs A and B.

## Track MS — milestones and the overseer

**MS1. Milestones are gate cards.** `graph.json` gains one gate node per
milestone: its parents are that milestone's chunks, and the next milestone's
chunks depend on it — so milestone gating is native too. This is a contract
change, not an addition: `acceptance-freeze.sh`, `roadmap-check.sh` (every id
matches a chunk file) and `board-bootstrap.sh` (single root, atomic parents)
all assume every node is a chunk with a frozen feature. The gate's assignee
must be a real profile, or the card strands silently. *Done when* the
`roadmap/` and `bootstrap/` groups cover gate nodes.

**MS2. The milestone probe runs on the gate card.** Realistic multi-record
fixtures plus adversarial input mutations that must be rejected, declared at
roadmap time (PL3) and executed when the gate card starts. Failures become
chunk cards. *Why:* redglass CHUNK-15.0. *Done when* a replay on redglass's
pre-CHUNK-15 tree flags the fail-open gates.

**MS3. `forge-overseer` on GPT-6-Astra.** Invoked by gate cards, exceptions
and triage — never per chunk. Absorbs `forge-orchestrator`'s routing role.
Quota use recorded per invocation.

**MS4. The milestone checkpoint.** On the gate card, after the probe: delivered
vs FRs, the probe result, cost against the architect's estimate, batched
follow-ups, the next milestone. Numbers from scripts; the overseer phrases and
judges. On a pass the overseer completes the gate and the next milestone
starts (decision 6); `park` or `redirect <text>` stops or steers it. On a
failed probe or a cost overrun the gate blocks with a decision-first message
and waits for `accept`, `redirect <text>` or `park`. Before run B, it runs once
against M1's finished milestone, so run B does not introduce it untested.

**MS5. Triage and contract amendments have an owner.** Thirteen redglass
`CARD?` items sit stranded in triage, and a verifier finding like CHUNK-8's
"fix the contract, not the PR" has no path today. The overseer promotes,
folds or closes each follow-up (`hermes kanban specify`/`decompose` where they
fit) and may amend a chunk contract — re-freezing acceptance and recording a
decision entry — shown at the checkpoint. *Done when* triage is empty at every
checkpoint.

## Track GW — gateway and legibility

**GW1. One decision-first message format.** Every human-facing card or
message: what happened (one line), what it means, the one decision needed or
"none", risk, the one reply. No decision, no message. *Why:* judge card
`t_7ad8d58e` is gate jargon, then a spot-check concluding "not a defect",
then "Run /judge, then merge or bounce."

**GW2. The daily digest, wired.** `forge-digest` has existed since July and was
never scheduled. A script computes the content — landed (PR links), in flight,
waiting on you, spend — and the profile relays it via `hermes cron` to
Telegram. *Done when* a week of digests lets the operator tell a run's state
from a phone.

**GW3. Replies act through allowlisted scripts** — accept/redirect/park a
milestone, merge or bounce in recommend-only mode, switch the implementer,
retry a card. Commands are accepted only from the operator's paired chat
(`telegram.allowed_chats` is empty today). `docs/state.md` still lists the
Telegram approval flow as unproven.

**GW4. A coloured, live dependency graph.** `forge graph <project>` renders
`docs/chunks/graph.json` with live board status: colour by status, outline by
implementer tier, grouped by milestone, each node linking its PR. Static HTML,
linkable from the digest.

**GW5. A `forge` meta-skill and `forge status`** — lifecycle stage, where
artifacts live, the next command — for any agent in a Forge project and for
the operator.

**GW6. North-star metrics in `make metrics`**, before run A, so the first run
is measured by the numbers this epic is judged on.

## Track EN — engines

**Position.** Hermes stays the orchestrator either way — board, dispatcher,
gateway, cron, profiles. The open choice is the implementer inside the lane
and, separately, the operator's interactive coding tool. **Pi** is the leading
candidate for the cheap and local tiers: a lean prompt, SKILL.md skills,
TypeScript extensions (published examples for sandboxing, path protection,
permission gates and micro-VM tool routing — unverified on macOS), scriptable
print, JSON and RPC modes, and OpenRouter. If it works it can also be the
operator's everyday coding tool, one harness learned deeply. **Hermes-native**
(`hermes -z`) is the zero-install baseline: same config and usage accounting,
but a ~20 k-token fixed prompt and approvals bypassed. EN3 compares both on the
same chunk and model; nothing Pi-specific is built before it. Using Pi
interactively for a human-tier chunk is a free way to learn it without adding
a pipeline variable.

**EN1. ADR-0015, built — the implementer is a configured component.** Per
board: implementer (codex / pi / hermes), model, provider, effort, tier;
per-chunk override; usage recorded per run; consumed by `lane.sh`. Subsumes
`scripts/set-model.sh`.

**EN2. Sandbox spike.** Neither Hermes nor Pi confines writes. Compare Pi's
micro-VM and Docker patterns, the Hermes docker terminal backend, and macOS
`sandbox-exec`. *Done when* a verdict rests on a measured escape test (a write
outside the worktree is refused) and the implementer's environment holds no
`gh` credentials — `lane.sh` pushes from outside the sandbox. Gates unattended
EN3/EN4.

**EN3. The harness spike.** Replay one finished chunk of the new project with
Pi and with `hermes -z`, same OpenRouter model; the verifier judges both.
Measure tokens, wall-clock, cost and verdict against the Codex original.

**EN4. The implementer ladder, live.** Cheap tier first; escalate on the bounce
budget (completes FL6); fall back to cheap while Codex is parked (FL9).
Caution from the `builder` experiment: glm-5.3-flash's C23 shipped a check that
could not fail, which is why FL5 precedes this.

**EN5. Lean worker prompts.** The lane profile carries 37 KB of system prompt
and 42.5 KB of tool schemas (~20 k tokens), including an index of ~80
unrelated skills. Scope forge profiles to the skills and toolsets they use.
*Done when* `hermes prompt-size` shows the drop.

**EN6. Local-model readiness.** A context budget per chunk (spec, touched
files, tests and prompt within ~60 % of 128 k), checked at roadmap time for the
local tier.

**EN7** *(optional experiment)*. **Session affinity** — a dependent chunk
continues its parent's implementer session. Measure tokens per chunk; Codex
re-read ~1.5–2 M mostly-cached tokens per chunk in these runs.

**EN8** *(conditional on EN3)*. **A Forge Pi package** — an L3 adapter carrying
the skills, a role-boundary extension (worktree-only writes, no push) and the
sandbox, usable unattended and interactively.

## Track PL — planning skills

Read ADR-0003 and ADR-0010 before editing any skill.

**PL1. `/scope`: ambition and restraint.** An ambition dial (toy / tool /
product), a complexity budget, a "make it delightful" pass, explicit
non-goals, and a gold-plating check.

**PL2. `/architect`: a practical feasibility stage.** Architect proves what can
be done, how, and with what effort before anything is planned on it:
- a prior-art scan — libraries and services before code;
- time-boxed spikes for each risky assumption, as throwaway code under
  `spikes/`, run in the interactive session;
- `docs/feasibility.md`: per component, the approach, the spike verdict, the
  estimated chunks, tier and cost, and a keep / cut / defer / swap call —
  something cheap may be pulled in, something expensive cut or deferred, right
  there, looping back to scope when the ambition shifts;
- a "decisions for you" list for what surfaced.

The ledger is a file a check can assert, not prose (ADR-0003).

**PL3. `/roadmap`: milestones, probes, tiers.** Milestones end in gate cards
(MS1) with declared probes (MS2). `lane` becomes an implementer tier (cheap /
strong / local / human); `human` only where a decision genuinely needs the
operator. Chunk size scales with tier; estimates carry over from the
feasibility ledger. A spec budget, because every lane re-reads the plan
(JobApp's `ROADMAP.md` is 94 KB).

**PL4. Realistic fixtures in chunk contracts.** Any scenario touching
aggregation or gating gets at least one multi-record fixture — the redglass
one-claim lesson.

## Track WL — weight loss

**WL1. Retire the tier-1 `claude -p` scorer** when the flip criterion is met.
The strong evidence is not "zero bounces" — that alone could mean nothing bad
came through — but that it approved JobApp C21 at 2/2/3/3/3/3, a PR tier-2
then bounced on two mutation-proven blockers. It bounced none of 15 reviewed
chunks at ~$1–1.7 per review. In fairness it bounced the deliberately
assertion-free `t_624586d7` in July, which is why FL5 must catch that class
first. Answers ADR-0011's open question; the deterministic gate stays.

**WL2. One `/chunk` skill** replaces `/start-chunk` and `/end-chunk` for human-tier
work and ends in FL3's handoff script. `docs/open-questions.md` has asked since
day one; the lane never invoked them.

**WL3. `forge run <project>`** — preflight, commission and bootstrap in one
command, replacing the staged-run guide's ritual. Root-first stays a flag.

**WL4. `verify` diet.** Classify the ~9.7 k-line suite into guards-the-flow,
guards-retired-machinery and historical; delete the latter two after WL1–WL3.
The CLAUDE.md invariants stay.

**WL5. Retro retargeted.** `/retro` proposes changes that move the north-star
metrics, runs on the gate card, and posts through the checkpoint. The one
retro that ran (PR #58) spent its diff on metrics plumbing.

**WL6. Short docs.** A one-page `docs/state.md` and a one-page operator guide;
history archived. `state.md` is 518 lines, last reconciled 2026-08-11.

**WL7. Drop the carried Hermes patch if nothing needs it.** It exists so an
`unblock` lifts the `active_pr` guard for lanes that blocked on an unmerged
parent; FL2/FL3 remove that path, and with it the `hermes update` hazard.
Verify before dropping.

---

## Session plan

The critical path runs to run A; items tagged optional stay off it. This table
is the epic's only progress record: a session updates its own row when it
closes.

| Session | Items | Why here | Status | PR |
|---|---|---|---|---|
| S0 | this document; operator: merge it, Q3, remove `builder` | Plan agreed | open | #73 |
| S1 | Q1, Q2, Q4, FL1 | Decisions recorded; epic discoverable | done | #74 |
| S1b | P1 *(promoted from the parking lot when S2 opened)* | A red baseline on clean `main` weakens every closing comparison to "the same 4" | done | #75 |
| S2 | FL2, FL3, FL7 | Lane as a program; one card per chunk | done | #76 |
| S3 | FL4, FL6 *(FL5 and FL8 split out at S3's opening)* | The verifier complete, but only recommending | done | #78 |
| S3b | FL5 *(split from S3)* | The mutation probe is what caught JobApp C21; its replays have to be recovered from the boards first, which is its own half of the work | planned | |
| S3c | FL8 *(split from S3)* | Nothing bills per token until EN1 configures a cheap implementer, so the cap has nothing to measure before then | planned | |
| S4 | GW1, GW2, GW4, GW6, WL3 | Runs become observable and start with one command | planned | |
| S5 | PL1–PL4, MS1, MS2 | The new project is planned with the new skills | planned | |
| S6 | Plan the new project — operator-led | Scope → architect with spikes → roadmap, three milestones | planned | |
| S7 | **Run A = milestone 1** | Variable: the flow. Codex, recommend-only, the operator merges, one seeded defect | planned | |
| S8 | MS3, MS4, MS5, GW3, WL1 | Overseer and two-way gateway; checkpoint rehearsed on M1 | planned | |
| S9 | **Run B = milestone 2** | Variable: merge authority | planned | |
| S10 | EN5, EN1, EN2 | Engine groundwork | planned | |
| S11 | EN3 (decides EN8) | Pi vs Hermes-native, on data | planned | |
| S12 | EN4, FL9; **run C = milestone 3** | Variable: the implementer tier | planned | |
| S13 | WL2, WL4–WL7, GW5, EN6 | Consolidate, trim, re-document | planned | |
| any | EN7 *(optional)*, EN8 *(conditional)* | Experiments | — | |

**Flip criterion (run A → run B).** Merge authority moves to the verifier only
if, over milestone 1: the verifier bounced every seeded defect; the operator
bounced no PR the verifier recommended (each disagreement is triaged, fixed in
FL5 and replayed); and every defect the milestone probe found was one
per-chunk verification could not have seen. Otherwise milestone 2 runs in
shadow too.

**The operator's involvement.** Run A: planning sessions, then a merge per
recommended PR from the phone. After the flip: planning sessions, a daily
digest, a reply at each milestone checkpoint, and rare exceptions.

## How we run this epic

**Three places, kept apart.**
- `~/dev/forge` — the dev checkout. Slices are built here on `slice/*`
  branches. Nothing live reads it, so a half-finished branch cannot reach a
  running lane.
- `~/dev/forge-runtime` — what every Hermes profile executes (`~/.forge/repo`
  points at it). It changes only by a deliberate deploy after a merge.
- This document — the only status record. Its session table says what is
  done; nothing else does.

**Who does what.** Claude builds in the dev checkout, runs the offline suites,
and opens the PR. The operator merges, deploys, and performs every host
mutation — `hermes config`, profiles, the gateway, launchd — and every live
run. Claude hands those over as exact commands and never runs them itself.

**One session, one PR.** A session delivers the items in its row and nothing
else. When an item turns out bigger than its row, it is split and the new
piece gets its own row; the PR is never widened. Anything discovered on the
way goes to the parking lot below, with its evidence, and is triaged when the
next session opens.

**Opening a session.**
1. Start from a clean `main`: `git switch main && git pull --ff-only`.
2. Run `make verify` and record the baseline: passed / failed / skipped.
3. Read this document's session table and parking lot, then write the session
   brief: the items, each item's *done when* copied verbatim, what is out of
   scope, which `verify` group proves each item, and any operator step.
4. `git switch -c slice/s<n>-<short-name>`.

**Building.** Test first: add the `verify` case, watch it fail, implement,
watch it pass. Then prove the case can fail: reintroduce the defect, confirm
red, restore. Anything that needs real Hermes runs under an isolated
`HERMES_HOME`, never against a live board or the running gateway. No paid
probes (`WITH_CODEX=1`) unless the brief names them.

**Closing a session.**
1. Run `make validate` and a full `make verify`, and compare with the
   baseline: failed stays 0, passed rises by the new cases, and any rise in
   skipped is explained. A drop in passed is a regression, even when nothing
   fails.
2. Update the session's row in this document (status, PR), and `state.md`
   only where a proven or not-proven claim changed.
3. Open the PR. Its body is the brief plus the before/after counts. CI must
   pass.

**Landing (operator).**
1. Merge, then run `make verify` and `make preflight` on `main` (CLAUDE.md).
2. If the slice changes anything a profile executes, deploy:
   `git -C ~/dev/forge-runtime pull --ff-only`. If profile files changed, also
   run `./hermes/profiles-bootstrap.sh` from the runtime — under bash, never
   zsh. Then run `make preflight` again; a drop in PASS count is the signal.
3. Rollback is `git -C ~/dev/forge-runtime checkout <previous-sha>`, then
   `make preflight`.

**Proving runs are their own sessions,** with a protocol written before the
run starts: the runtime SHA, what is measured, the flip criterion, and the
stop rules. The results section is filled only from pasted output, never from
a model's arithmetic.

**Hold still during the epic.** No Hermes, Codex or Claude Code upgrade
mid-epic except as its own session, using the carried-patch procedure. Never
two new variables in one run.

**Starting a session.** Open a fresh Claude Code session in `~/dev/forge` and
say: *"Run epic session S<n> per docs/epic-hands-free.md, § How we run this
epic."*

## Parking lot

Discoveries made during a session that are not its items. Each carries its
evidence and is triaged when the next session opens: promoted to an item,
folded into an existing one, or closed with a reason.

**P1 (S1). `config/external-dirs/*` is red on a clean `main`, and the epic
made it so.** *Triaged at S2's opening: promoted to row S1b, its own PR ahead
of S2, and fixed there with the third arm described below —
`external_dirs_verdict` in `scripts/verify.sh`, every arm executed offline by
`cli/external-dirs-arms`.* Four cases — `forge-codex-lane`, `forge-digest`,
`forge-orchestrator`, `forge-prejudge` — fail with

```
does not point at /Users/goonlab/dev/forge/skills
  (got '- /Users/goonlab/.forge/repo/skills')
```

The check (`scripts/verify.sh`, the `config` group) knows two worlds: the
profiles point at *this* checkout (ok), or at the main checkout while you work
in a linked worktree (skip, F49). *§ How we run this epic* introduced a third:
`~/.forge/repo` now symlinks `~/dev/forge-runtime`, which is deliberately **not**
this checkout, so the live profiles can never satisfy it again. This is the
epic's own three-places design surfacing as a red baseline, not a defect in the
profiles — and nothing here may be fixed by a host mutation, which is the
operator's.

Consequence, and why this wants deciding before S2: every session's closing
comparison is *"failed stays 0"*. It is now *"failed stays 4, and the same 4"*,
which is a weaker instrument. CI is unaffected — the `config` group skips
wholesale without Hermes.

Shape of the fix: the check gains a third arm — a match on
`~/.forge/repo/skills` passes when that symlink resolves to a real forge
checkout, and reports which one, so it keeps asserting something rather than
being deleted. Read on 2026-09-25: `~/.forge/repo → ~/dev/forge-runtime`, whose
HEAD is `f1ca5fe` (#72), one merge behind `main`.

**P2 (S1). The quota runner's stubs write the wrong envelope.** *Triaged at
S2's opening: **closed** — no structured stream exists to recover. The lane
profile's full session history (a WAL-safe copy of
`~/.hermes/profiles/forge-codex-lane/state.db`, 2026-09-26) holds 12 messages
naming `rate_limits` and 4 naming `thread.started`, and **none** naming both:
both real limit events (session `01a07acc…`, 2026-09-07; run 57, 2026-09-09,
"try again at 12:58 PM") carried a prose refusal and zero `rate_limits`
objects in the `--json` stream. So the proven reactive path is the prose one
(S1's Q1). The structured reactive arm is unobserved, and the pre-flight gate
reads the rollout, which does carry `rate_limits`. S2 rewrote `forge-lane`
without restating the structured path as proven. Still true and not fixed:
`quota-window.py`'s header says every `token_count` event `codex exec --json`
emits carries `rate_limits`, and the `--json` stream has no `token_count`
events at all. Correct it when FL9 next touches the parser.* Every stub in
`quota`'s end-to-end cases writes rollout-shaped lines into `$CURRENT`, but
`$CURRENT` holds the `codex exec --json` stream, whose events are
`thread.started` / `turn.started` / `item.completed` with a flat `usage` object
— no `payload` wrapper, no `rate_limits` key, no timestamp anywhere. Key list
taken 2026-09-25 from the one real stream on this machine,
`~/.forge/lane-quarantine/20260902-142534/scratch-forge-lane-1/codex-events.current.jsonl`:

```
type · thread_id · usage.{input_tokens,output_tokens,cached_input_tokens,
cache_write_input_tokens,reasoning_output_tokens} · item.{id,type,status,
text,command,exit_code,aggregated_output,changes[].{kind,path}}
```

S1 fixed the refusal half of this: `quota/the-reactive-exec-json-refusal-parks`
now drives the real stream shape, recovered from the lane board. **The
structured half is untested.** Nothing has ever exercised the reactive park
path against a real `--json` stream carrying `rate_limits`, so it is not known
what a *structured* limit looks like in that envelope, or whether
`find_rate_limits` finds it — and run A depends on that path. Triage: either
recover such a stream from a board, or accept that only the prose path is
proven and say so where the claim is made.


**P3 (S2). `lane/terminators-match-the-substrate` has been blind since
Hermes 0.21.5.** Under `--with-hermes` it fails with
`toolsets-source-yielded-no-kanban-tools`: upstream moved the kanban tool list
out of the `"kanban": {"tools": [...]}` literal into a module-level list
passed to a `_ts(...)` helper (`~/.hermes/hermes-agent/toolsets.py`, lines
31–37 and 163), so the reader's window matches nothing. It is red on a clean
`main` too, and it is skipped by default, which is why no baseline shows it.
The reader fails loudly rather than letting the MCP source stand in, as
designed. Checked by hand for S2: the four terminators in that list
(`complete`, `block`, `request_review`, `request_changes`) are all named in
the new `forge-lane` §2. Fix: re-point the reader at the list, not the literal.

**P4 (S2). Metrics cannot see chunk envelopes after FL3.** Since FL3 a chunk's
`forge.chunk.v1` rides its `review_requested` run, not a completion.
`scripts/metrics.sh` (lines 471, 515, 564) and `scripts/metadata-live.sh`
(line 108) read only `task_runs.outcome = 'completed'`. The next live run's
chunk rows would therefore be invisible to `make metrics` and to the live
metadata sweep, and `rubrics/kanban-metadata-schema.md` still states the
producer rule as "a *completed* `forge-codex-lane` run". This belongs with
GW6 (S4), which rebuilds `make metrics` around the north-star numbers anyway.
Before run A, either way. *S3 adds the other half: a `forge-verifier` run ends in
`request-changes` or a block, so no verifier envelope rides a `completed` run
either. S3 renamed the producer and aliased both names in `metrics.sh` and
`rubrics/run-metadata-contract.json`, so the recorded rows still count — but the
`outcome = 'completed'` filter is untouched and is GW6's to fix. The rubric's
producer line now names both profiles.*

**P5 (S2). How S2 lands decides S3's baseline.** S2 changes the lane's SOUL
and adds two scripts the runtime does not have yet. Until the operator deploys
it (`git -C ~/dev/forge-runtime pull --ff-only`, then
`./hermes/profiles-bootstrap.sh` under bash), `make verify` carries
`config/soul-in-sync/forge-codex-lane` red and `make preflight` two FAILs
(`~/.forge/repo/scripts/lane.sh` and `lane-handoff.sh` do not resolve; PASS
stays 90). Deploying right after merge clears all three. The cost: a lane card
dispatched live would run a full, paid chunk and hand it to a `forge-prejudge`
that still expects a child card; `prejudge-review.sh` then blocks on its
`chunk-identity` guard, so it fails closed, but after the spend. Read on
2026-09-26 through `board-snapshot.sh`: no `forge-codex-lane` card on any board
is `ready` or `running`; three are dormant (`forge-dependency-probe-20260728`
one `blocked` and one `todo`, `forge-ladder` one `blocked`), and none moves
unless someone unblocks it. S3 opens against whichever state the operator
chose, and its brief should say which. *Triaged at S3's opening: **closed**. The
operator deployed S2 before S3 opened — `~/.forge/repo → ~/dev/forge-runtime`,
whose HEAD read `68724a4`, identical to `main` — so S3's baseline is a deployed
lane, with `config/soul-in-sync` green and neither S2 preflight FAIL present.
S3's own landing repeats the same step for the same reason.*

**P8 (S3). Triage needs a model to empty, and it is a dead end for a chunk
card.** Executed 2026-09-26 in an isolated `HERMES_HOME`: a card in `triage`
refuses `complete`, `complete --force`, `promote` and `unblock`. Its one CLI exit
is `hermes kanban specify`, which calls an auxiliary model — it failed here with
`LLM error: AuxiliaryClientUnavailable` — and lands the card in `todo`, i.e. back
with an *implementer*, never at `done`. FL4 routes around it (the block kind
rotates, so a hold never reaches triage) and nothing in the per-chunk flow depends
on it. **MS5 does.** It says the overseer "promotes, folds or closes each
follow-up (`hermes kanban specify`/`decompose` where they fit)" and that triage is
empty at every checkpoint — which needs an auxiliary model configured on whichever
profile runs it, and means any card that does land in triage is a manual recovery.
Triage it with MS3/MS5 in S8.

## Open questions

1. ~~Merge method: squash with branch deletion, and `worktree-sweep` after each
   merge?~~ **Settled in FL1: yes to all three** — ADR-0019 D19.6, which also
   records why each part is load-bearing (the revert path depends on the
   squash).
2. Do Codex and Hermes's OpenAI OAuth draw on the same quota? Run B measures.
3. Roadmap authorship: revisit after run B whether the overseer drafts it and
   the operator approves through the gateway.
4. A second project template (web / TypeScript, with a JS mutation tool) —
   after run C, if the next creative project needs one.

`~/dev/forge-tutorials` rung 4 (prejudge + judge) is not written yet and would
teach the flow this epic retires; hold it until run B.

---

## Appendix — evidence ledger (2026-09-24)

Sources: WAL-safe snapshots via `scripts/board-snapshot.sh`; project git
history and `gh pr list`; project decision logs; Hermes 0.21.5 source;
per-profile Hermes `state.db`; Codex session logs; `make metrics`.

**Block taxonomy** (every `blocked` event):

| Class | JobApp | redglass |
|---|---|---|
| Tier-2 human judge | 5 | 14 (5 duplicates) |
| Parent PR not merged (ADR-0008) | 2 | 5 |
| Human-implemented chunk | 6 | 3 |
| Driver card-creation error | 0 | 3 |
| Quota | 1 | 1 (+1 misclassified) |
| Blast-radius false positive (sibling worktree) | 1 | 1 |
| Gate substrate / handoff faults | 3 | 0 |

**Tier-1 vs tier-2 backtest.** Tier-1's derived verdict was `approve` every
time.

| Chunk | Tier-1 scores | Tier-2 outcome |
|---|---|---|
| JobApp C10 | 3/2/3/3/3/3 | approve, agreed exactly |
| JobApp C19 | 2/3/3/3/3/3 | approve (doc nit) |
| JobApp C17 | 3/3/3/3/3/2 | approve-with-nits; found a provably dead scenario predicate |
| JobApp C20 | gate hand-completed | approve-with-nits, scenario_integrity 1 |
| JobApp C21 | 2/2/3/3/3/3 | **bounce** 2/1/1/3/2/3 — two mutation-proven blockers |
| redglass 2, 3, 5, 7, 8, 11 | 3/3/3/3/3/3 | approved or merged; no defect found |
| redglass 1, 10, 12 | one 2 | approve(-with-nits); PR #9's merge exposed a 5-test union failure |

"Tier-1 approve and all 3s ⇒ auto-merge" would have merged 6/14 redglass and
0/5 JobApp PRs, and held every PR where tier-2 found a defect.

**Merge gates on the product repos.** `wielas/vault` and `wielas/JobApp` are
both private; `scripts/merge-gate.sh` exits 5 (`UNAVAILABLE`) for each, as
read 2026-09-24.

**Recommend-only state machine**, probed 2026-09-24 against the installed
Hermes under an isolated `HERMES_HOME`:
- *executed:* `review → complete → done` releases the child to `ready`;
  `reopen-review` from `review` returns the card to `ready` with the
  implementer restored and the reason recorded as a comment, three rounds
  running, with no recurrence counting; an operator-level `block` of a card in
  `review` is refused;
- *read in source, not yet executed:* `block_task` accepts only `running` or
  `ready`, and a claimed review run is `running` with `source_status=review`,
  so the verifier's own block lands in `blocked` and `unblock` returns the card
  to `review`; `complete_task` accepts `blocked → done` given a result; same-
  kind re-blocks after an unblock route to triage at
  `BLOCK_RECURRENCE_LIMIT=2`. FL4's fixtures must execute these.

**Cost.** Lane driver (deepseek-v4-flash-0731, 28 sessions, 1,030 API calls,
1,166 tool calls): $2.38. Prejudge driver: $0.42. Tier-1 scorer: $0.98–1.72
per review (subscription). Codex (gpt-5.6-luna, xhigh) exec sessions: ~1.5–2 M
input tokens per chunk, over 90 % cached, ~0.1 M output — subscription quota
is the binding constraint, not dollars.

**Hermes 0.21.5 facts used above.** Same-card review with `request-review`,
`request-changes` and `reopen-review` (review-lane spawns are exempt from the
`active_pr` and `recent_success` guards); `_parents_satisfied` counts only
`done`/`archived`; `schedule` parks until `unblock`; `set-model --provider`
overrides the worker's own model; per-task `reasoning_effort`, `max_retries`,
`goal_mode`; `swarm`, `specify`, `decompose`; `hermes -z` is one-shot with
approvals auto-bypassed and a `--usage-file` report — not a sandbox;
`hermes cron` for schedules; `notify-subscribe` for per-task delivery to a
gateway chat.

**Fixed since the runs:** §7 child-body assert (#58), tier-2 handoff with a
running parent (#60), model pins (#61–#69). **Still open:** Q1, Q2, the 13
redglass `CARD?` items.

**Size of the machine.** ~19.9 k lines under `scripts/` (`verify.sh` 9.7 k),
17 ADRs, 98 F-findings, 319 commits since 2026-07-25.
