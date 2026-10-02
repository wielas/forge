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
- pass, merge mode → `gh pr merge --squash`, then complete *(since S3's
  review: if the merge lands and the completion does not, the card is held
  `merge-pending:` and the merge-watcher completes it)*.

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

*S3's status against that done-when: met, except the last clause, which is met
**in part**. The red-CI PR is executed with merge mode ON. The disagree path is
executed on the real kernel, and `bounce.sh`'s own event stream proves it parks on
the non-spawnable sentinel before it unblocks. What a fixture cannot supply is a
dispatcher that could actually claim the card: in an isolated `HERMES_HOME` no
profile is on disk, so nothing is spawnable, and the control — the same window
without the park — leaves the card in exactly the same place. The remaining clause
therefore rides run A, and is carried in **S7's row** — the session table is this
epic's only progress record, so a deferral that lives in prose is a deferral the
next session will not see.*

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
*S5: met. A gate is `GATE-<milestone>` in `graph.json`, with
`docs/chunks/GATE-<milestone>.md` carrying Milestone, Probe, Estimate and Lane.
`board-bootstrap.sh` creates it **held for the operator**, the way it creates an
interactive chunk: blocked, unassigned, and without the lane skill, worktree or
branch. Its reason is decision-first, through the one formatter, and the digest
stays silent about it until every chunk it closes is done. The gate is refused
before any board exists if it is parentless or routed anywhere but
`claude-interactive`. No profile runs a gate card yet, so "a real profile" is
S5b's (the probe runner) and S8's (the overseer). Metrics count a gate as a
card, never as a chunk. Cases: `roadmap/gates-*`, `bootstrap/gate-*`,
`bootstrap/next-milestone-waits-for-the-gate`,
`bootstrap/a-misrouted-gate-is-refused-before-any-board`,
`metrics/a-gate-is-a-card-not-a-chunk`,
`digest/a-gate-speaks-only-when-its-milestone-is-done`. The opt-in
`bootstrap/real-hermes-gate-holds-the-next-milestone` is the real kernel.*

**MS2. The milestone probe runs on the gate card.** Realistic multi-record
fixtures plus adversarial input mutations that must be rejected, declared at
roadmap time (PL3) and executed when the gate card starts. Failures become
chunk cards. *Why:* redglass CHUNK-15.0. *Done when* a replay on redglass's
pre-CHUNK-15 tree flags the fail-open gates.
*S5 built the declaration only. It is `tests/probes/gate_<milestone>.json`,
`forge.probe.v1`. Each case carries a name, a kind (`realistic`, with `records`
≥ 2, or `adversarial`), an `input` under `tests/probes/`, a `run` argv naming
`{input}`, and an `expect` of `exit` plus an optional `stdout` substring.
`acceptance-freeze` validates it and hashes it, with every input file, into
`contract-freeze.json`, so `--check-base` refuses an implementation branch
that weakens the probe (`roadmap/probe-*`,
`roadmap/a-weakened-probe-is-refused-at-review`). **The runner and the replay
are row S5b.** If S5b finds the format wrong, it bumps the schema to
`forge.probe.v2` rather than editing v1 under plans already frozen against it.
The replay must meet three conditions:
- It must not vendor `wielas/vault`, which is private, into this public repo.
  It reads a local checkout, read-only, through `git archive`, and skips when
  that checkout is absent.
- It must be two-sided: the pre-CHUNK-15 tree flags, and a post-CHUNK-16 tree
  clears.
- Its adversarial inputs must be valid under the *old* schema, so that a flag
  is a wrong verdict rather than a load error.*

*S5b: met. `scripts/probe-run.sh <project> GATE-<milestone>` runs a gate's
frozen probe. Each case runs from the project root, with no shell, and ends
when its command exits. Its exit code and stdout are then compared.
- A case that misses either, or times out, is a finding (exit 1).
- A probe or input that the manifest does not hold, an invalid probe, a
  command that cannot start, or an error in the runner itself gets no verdict
  (exit 2).

The last line is the gate card's result. It names the failed cases and the
commit the run was on, and it is safe to paste inside double quotes. The gate
card's hold names the command. It is a script the operator runs; a profile
that runs gate cards is still S8's.*

*v1 is defined once, in `scripts/forge_probe.py`, which `acceptance-freeze`
also imports. Its shape is unchanged, but two things it accepted are now
refused, at freeze time and at run time:
- **A symlink in an input.** This is a freeze bug fix: a linked directory was
  never walked, so its bytes were not hashed and `--check-base` could not see
  them change.
- **Values that cannot discriminate or cannot reach `exec`.** This is a
  deliberate tightening: an empty `stdout` (every output contains it), an exit
  outside 0–255, a string a JSON escape left unencodable, and a `run` that
  names `.DS_Store`, which the freeze ignores.

Neither changes a plan already frozen. The Squatfather's re-freeze is
byte-identical and `--check-base` accepts it. The redglass replay's probe
still validates. So v1 is not bumped.*

*The replay is `probe/redglass-replay-*`. Its probe is the one M4's gate should
have carried, written after the fact. It holds synthetic corpora, a driver and
their generator. The operator committed it once to a private local redglass
branch, `forge/gate-m4-probe`, and this repo pins that commit by SHA and holds
only the harness. On `f32abeb` the old gates advance all three adversarial
corpora, while a sound corpus advances too:
- demand is cleared by evidence it should not count;
- economics is rated `moderate` with almost every input assumed;
- risk passes while safety is unknown.

The old tree also stops the second realistic corpus, a sound one with one
unrelated weak claim (a fail-closed defect CHUNK-16 fixed too). On `713f1eb`
all five cases hold. The third condition is met in its purpose, not its
letter. Each corpus is stored in the newer tree's form. The driver
projects it onto the tree's own schema and validates it clean before the
gates run, so every flag is a wrong verdict, never a load error. The demand
flag rests partly on a link that only the newer schema has: the old tree
counts evidence the newer one scopes out, which is the defect as this epic
first described it. "Failures
become chunk cards" moved to S8, with MS4: which failure is a defect and which
is a probe bug is the checkpoint's judgement.*

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
*Done when* (**proposed in S4 — this item had none**) one formatter,
`scripts/decision-message.sh`, renders every message the machine sends the
operator: the verifier's holds and exception, the merge-watcher's findings,
and the digest's waiting-on-you entries. Every block class the contract
registers has a decision entry there. The merge-watcher's stdout carries only
decisions. *S4: met, executed by `digest/every-block-class-has-a-decision`,
`digest/one-formatter` and the `verifier` group's watcher cases. A lane block
stays one `<class>: <reason>` line, because other programs parse it; the digest
expands it from the class table. A completed merge is no longer a watcher
message: the operator made it, and the digest reports it under* landed.

**GW2. The daily digest, wired.** `forge-digest` has existed since July and was
never scheduled. A script computes the content — landed (PR links), in flight,
waiting on you, spend — and the profile relays it via `hermes cron` to
Telegram. *Done when* a week of digests lets the operator tell a run's state
from a phone.
*S4: `scripts/digest.sh` is built and its whole message is fixture-exact
(`digest/`). The done-when needs a live week, so it is carried in **S7's row**.
**Decided in S4, departing from the Roles table:** no profile relays the
digest. It runs as `hermes cron … --no-agent --script`, and its stdout is the
message, as with the merge-watcher. A relaying model can still restate a
number, and "numbers come from scripts, never from a model" leaves it nothing
else to do (P11).* *Read-only against the live host, 2026-09-26: the first
message would be 12 KB (275 lines), because six dormant boards still hold 29
cards waiting on the operator. Redglass alone has 15, 13 of them in triage.
Hermes's Telegram sender chunks at 4096 UTF-16 units
(`tools/send_message_senders.py`). That was read in the source, not executed,
so a long digest arrives as several messages rather than failing. Archiving
finished boards before the cron is wired is the operator's call.*

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
*Done when* (**proposed in S4 — this item had none**) `make metrics` leads with
the north-star block, and each number is a count with its denominator, or `n/a`
with a reason. The block is computed exactly from a board in the post-FL3
shape, and P4's envelopes are visible to both `metrics.sh` and
`metadata-live.sh`. *S4: met — `metrics/post-fl3-board-numbers-exact`,
`metrics/north-star-numbers`, `metrics/north-star-mutation-is-caught`,
`metrics/text-leads-with-the-north-star`, `metadata/live-valid-counts`.*
- *Who merged* is read from `tasks.result`, which only two producers write on a
  merge: the verifier in merge mode and the merge-watcher.
- *PR open → merge* is a board proxy: the first `review_requested` event to the
  `completed` event, labelled as such.
- The two *tracked* rows are reported as not yet measurable. There is no probe
  until MS2 and no estimate until PL2.
- The retro log's generated row does not carry the block yet (P12).

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
*Done when* (**proposed in S5 — this item had none**) `/scope` writes the dial,
a numeric budget (`<n> milestones, <n> chunks`), a delight pass citing defined
FRs, a recorded gold-plating pass and a non-empty out-of-scope list, in a form
`scripts/plan-check.sh --stage scope` reads. `roadmap-check` warns when a
roadmap exceeds the budget, and removing each field reddens its own case.
*S5: met — the `roadmap/scope-*` cases, `roadmap/delight-cites-a-defined-requirement`
and `roadmap/budget-caps-the-plan`.*

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
*Done when* (**proposed in S5**) `scripts/plan-check.sh --stage architect`
asserts the ledger. Every row carries an approach, prior art, a spike verdict,
an estimate in chunks, a tier, a cost and a call. A `proven` or `disproven`
verdict names a `spikes/` directory that exists. The kept estimate fits the
scope's budget, or the check sends the architect back to scope. The "decisions
for you" list exists. *S5: met — `roadmap/ledger-*`,
`roadmap/architect-requires-decisions-for-you`. The architect's hard rule "no
code" now reads "no product code".*

**PL3. `/roadmap`: milestones, probes, tiers.** Milestones end in gate cards
(MS1) with declared probes (MS2). `lane` becomes an implementer tier (cheap /
strong / local / human); `human` only where a decision genuinely needs the
operator. Chunk size scales with tier; estimates carry over from the
feasibility ledger. A spec budget, because every lane re-reads the plan
(JobApp's `ROADMAP.md` is 94 KB).
*Done when* (**proposed in S5**) `/roadmap` emits:
- a gate node per milestone, with a declared probe;
- a `tier` on every chunk;
- a per-milestone estimate carried from the ledger;
- contracts, and a `ROADMAP.md` that is now an index, both within a byte budget
  (6000 per contract, 16000 for the index).

`roadmap-check` warns on each defect. *S5: met, except that **chunk size does
not yet scale with tier**. Only `strong` and `human` have an implementer before
EN1, so a cap for `cheap`/`local` would be a number with nothing to measure, and
loosening any cap needs an ADR-0012 amendment. The caps stay the strong tier's.
`roadmap-check` warns on a `cheap`/`local` tier, and the scaling rides EN4/EN6
with data. Cases: `roadmap/tier-*`, `roadmap/estimate-carries-the-ledger`,
`roadmap/spec-budget-*`. `/start-chunk` and `/end-chunk` still tick or update a
chunk's line in `ROADMAP.md`. The index keeps one line per chunk for them, and
WL2 retires both.*

**PL4. Realistic fixtures in chunk contracts.** Any scenario touching
aggregation or gating gets at least one multi-record fixture — the redglass
one-claim lesson.
*Done when* (**proposed in S5**) a contract's `**Multi-record fixtures:**`
maps a fixture of two or more records to each `@multi-record` scenario.
`acceptance-freeze` refuses a mismatch either way, or a one-record fixture, and
`roadmap-check` warns on a contract without the field. *S5: met —
`roadmap/multi-record-fixture-is-planned`,
`roadmap/multi-record-fixtures-is-a-contract-field`. Which scenarios aggregate
is the planner's judgement. No script can tell, so the tag is a declaration.*

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
| S2b | P6 *(promoted from the parking lot when S3 opened)* | Every bootstrap ended in FATAL on a correct write, so the one signal the operator reads after a deploy had to be ignored | done | #77 |
| S3 | FL4, FL6 *(FL5 and FL8 split out at S3's opening)* | The verifier complete, but only recommending | done | #78 |
| S3b | FL5 *(split from S3)* | The mutation probe is what caught JobApp C21; its replays have to be recovered from the boards first, which is its own half of the work | planned | |
| S3c | FL8 *(split from S3)* | Nothing bills per token until EN1 configures a cheap implementer, so the cap has nothing to measure before then | planned | |
| S4 | GW6, GW1, GW2 *(GW4 and WL3 split out at S4's opening; P4 and P10(3) folded in)* | Runs become observable: run A is measured by GW6's numbers, and the operator merges it from a phone off GW2's digest | done | #79 |
| S4b | GW4, WL3 *(split from S4)*; P7 triaged with WL3 | Runs start with one command and the graph is visible — convenience, neither changes what run A measures | planned | |
| S5 | PL1–PL4, MS1, MS2's declaration *(MS2's runner and replay split out at S5's opening; PL3's tier-scaled caps deferred to EN4/EN6)* | The new project is planned with the new skills | done | #80 |
| S5b | MS2's runner and its redglass replay *(split from S5; MS2's "failures become chunk cards" moved to S8 at S5b's opening)*. *Done when (**proposed at S5b's opening — the row had none**): `scripts/probe-run.sh <project> GATE-<m>` runs a gate's frozen v1 probe from the project root, with no shell, and keeps three outcomes apart — 0 every case holds, 1 a finding named by case (timeouts included), 2 no verdict; a probe or input the manifest does not hold, and a command that cannot start, get no verdict; v1 has one definition, which both scripts read; the gate card names the command; MS2's replay meets S5's three conditions; every new case is seen red against its defect; and v1 is bumped only if the replay shows it wrong. **Closed 2026-10-01: met.** `scripts/forge_probe.py` holds v1 once, and `acceptance-freeze` imports it; the `probe/` group (16 cases) and `bootstrap/gate-names-its-probe-runner` prove the rest. A case ends when its command exits, its output going to files; the last line names what failed and the commit, and is paste-safe. v1 now refuses a symlink in an input (a freeze bug fix) and expectations that cannot discriminate (a deliberate tightening); no frozen plan changed, so v1 is not bumped. The replay's probe is a synthetic one M4's gate should have carried, committed once by the operator to a private local redglass branch and pinned here by SHA. It flags `f32abeb` (all three adversarial corpora advance; the control advances too) and clears `713f1eb` (5 of 5). Its third condition is met in purpose: each corpus is stored in the newer tree's form and projected onto the tree's own schema, validated clean before the gates run. 28 mutants each reddened their case, as did the old hold text, the two replay trees swapped, and the pre-review pipe-based runner on `a-case-ends-when-its-command-exits`. `make verify` went from 488 / 0 / 11 to 505 / 0 / 11. Two independent reviews found four exit-code or hang defects, two holes in the freeze, and smaller issues; all were fixed before merge, except two additions for S8 (P20). Discoveries: P18, P19, P20.* | Run A's flip criterion counts what the milestone probe finds, so something must execute the probe S5 declares before S7 | done | #83 |
| S6 | Plan the new project — operator-led. *The project is **The Squatfather** (`the-squatfather`), a local AI strength coach for the operator alone. It keeps their training history, notes, goals and weight. Once a week it reviews the week's Garmin Fenix 7 Pro workouts with them and adjusts the plan (progressive overload, new exercises, travel and one-off events), then loads the next week onto the watch. Nutrition and other users are out. It runs on this machine, through Hermes or Claude. It was stamped at `~/dev/the-squatfather` from `templates/python-service` at `78f6f1f`, and its repo is `wielas/Squatfather`, private, so `merge-gate.sh` reports `UNAVAILABLE` and commissioning records `posture: UNGATED`. Done when (**proposed at S6's opening — this row had none**): `plan-check --stage scope` and `--stage architect` are CLEAR, with every verdict backed by a real `spikes/` directory; `roadmap-check` is CLEAR, or the sign-off answers each finding; `acceptance-freeze` writes `contract-freeze.json`; the plan has three milestones, `GATE-M1`–`GATE-M3`, each with a probe holding at least one `realistic` case (records ≥ 2) and one `adversarial` case; and the operator signed off each stage. M3 is tiered `strong` and re-tiered in S12 (operator's call, S6's opening). If S5b bumps the probe to `forge.probe.v2`, these probes are re-declared. Commission and bootstrap are S7's. **Closed 2026-10-01: met.** Scope, architect and roadmap were each signed off by the operator. Read from the runtime at `78f6f1f`: `plan-check` scope CLEAR (6 pass) and architect CLEAR (4 pass), with two spikes, `garmin-lib` proven and `garmin-live` disproven (a 429 on one login attempt); `roadmap-check` CLEAR (14 pass, 0 warn); `acceptance-freeze` 30 contracts, byte-identical to the committed manifest. The plan is 3 milestones and 10 chunks (5 / 3 / 2) against a budget of 3 and 10. The probes hold 2 realistic + 3 adversarial cases (M1), 2 + 2 (M2) and 2 + 1 (M3). There is one root, CHUNK-1. M1's one human chunk, CHUNK-5, has parents, so P13 is promoted to row S6b. `GATE-M1` is also held on a live Garmin spike the operator runs during M1. The plan reaches `main` through Squatfather PR #1.* | Scope → architect with spikes → roadmap, three milestones | done | #81 |
| S6b | P13 *(promoted at S6's close)*. *Done when (**proposed at S6b's opening — neither the row nor P13 had one**): the digest's waiting list skips a `blocked` card whose last block reason is the bootstrap's interactive hold while any parent is not `done` or `archived`, and lists it as before once all are; that reason is one string both scripts source, and what the bootstrap really writes is checked against it; `digest/fixture-message-exact`'s expected text is unchanged; and every new case has been seen red against its defect. **Closed 2026-10-01: met.** Measured first on Hermes 0.21.5 in an isolated `HERMES_HOME`: the hold survives `link`, and `main`'s digest listed the chunk while its only parent was `ready`. Three cases, all red before the fix: `digest/an-interactive-chunk-speaks-only-when-its-parents-are-done` (CHUNK-5's two parents, with four controls), `bootstrap/interactive-hold-is-the-reason-the-digest-skips`, and the opt-in `bootstrap/real-hermes-interactive-chunk-waits-for-its-parents`. Eight mutants each reddened their case. `make verify` went from 486 / 0 / 10 to 488 / 0 / 11; the extra skip is the opt-in case. One discovery, P16.* | M1's human chunk, CHUNK-5, has parents, so without it the digest lists it as waiting on the operator from run A's first day | done | #82 |
| S6c | P16, P21 *(promoted at S7's opening)*. *Done when (**proposed at S7's opening**): a human-tier chunk handed off through `lane-handoff.sh` can be bounced. The kernel records an implementer, so `request-changes` lands the card `ready` on the non-spawnable `forge-operator-handoff`. `bounce.sh` accepts that sentinel as a human chunk's implementer. A bounced human chunk is listed under "waiting on you". Its interactive hold renders decision-first rather than as `other`. Every new case is seen red against its defect, and the human-handoff bounce runs on the installed kernel.* | Run A's seeded defect goes through CHUNK-5, the human chunk. Today any verifier bounce of a human chunk strands it as `other: handoff-integrity`, and its hold reads "risk unknown" | planned | |
| S7 | **Run A = milestone 1**; FL4's last clause *(deferred from S3: the disagree path under a dispatcher that could really claim the card, which no isolated `HERMES_HOME` can supply)*; GW2's done-when *(deferred from S4: a week of digests read from a phone, which only a live run can supply)*. *Opened 2026-10-02. The protocol is `docs/run-a.md`. This row's first PR registers it before launch, and a second PR adds the results at the end of M1. That departs from "one session, one PR" by **the operator's decision at the opening**: the run spans days, and S6c must see its row on `main`. The protocol is frozen at `RUN_START`, as the launch record's `FORGE_SHA`, so S6c and S3b may still edit it. Preconditions: S6c and S3b (#84, rebased) merge and deploy before `RUN_START`. Decided at the opening, before launch:*<br>*– The seeded defect is S-1, which the operator plants in CHUNK-5. Only the scorer's verdict decides whether it was caught. A gate or merged-tree bounce unrelated to the seed voids the attempt.*<br>*– A reporting mutation probe's "would bounce" is not a bounce. S3b defers two things to this row: the probe's precision, measured from the holds, and the operator's decision on its switch at M1's checkpoint. Both read `docs/run-a.md`'s list of each recommended PR's probe verdict beside the operator's judgement of it.*<br>*– FL4's clause is met by drill D-1 on CHUNK-2, declared in advance and excluded from the flip count.*<br>*– Claude Code and Codex are not frozen; they stay current. Run A records the versions it ran on, and a version that moves mid-run is recorded rather than a stop. That amends* Hold still during the epic*. Hermes alone stays held.*<br>*– `GATE-M1` is not completed in run A.*<br>*Done when (**proposed at S7's opening — the row had none**): `docs/run-a.md` is executed to its end state. CHUNK-1 to CHUNK-5 are merged, each on a green PR, and their cards are done. `GATE-M1` has been probed and is still held. S-1 and D-1 are recorded, and seven digests judged. Its* Results *hold only pasted output, and the flip verdict is recorded clause by clause. Baseline at the opening (`main` @ `affc967`): 505 / 0 / 11.* | Variable: the flow. Codex, recommend-only, the operator merges, one seeded defect | in progress — protocol registered, run not started | #85 (registration) |
| S8 | MS3, MS4, MS5, GW3, WL1; MS2's "failures become chunk cards" *(moved from S5b at its opening)* | Overseer and two-way gateway; checkpoint rehearsed on M1 | planned | |
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
two new variables in one run. *Amended 2026-10-02 at S7's opening, by the
operator's decision: Claude Code and Codex are kept current, because getting
the newest harness often matters more than holding it still. A proving run
records the versions it ran on, and a version that moves mid-run is recorded
beside its results rather than stopping it. Hermes still holds still: its
update path destroys the carried patch (WL7).*

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
Hermes 0.21.5.** *Triaged at S4's opening: **left open**. It is independent of
S4 and blind only under `--with-hermes`; promote it when the `lane` group next
changes. Re-triaged at S5's opening: still open, since S5 does not touch the
`lane` group. Re-triaged at S6's opening: still open, since S6 changes no
code.* Under `--with-hermes` it fails with
`toolsets-source-yielded-no-kanban-tools`: upstream moved the kanban tool list
out of the `"kanban": {"tools": [...]}` literal into a module-level list
passed to a `_ts(...)` helper (`~/.hermes/hermes-agent/toolsets.py`, lines
31–37 and 163), so the reader's window matches nothing. It is red on a clean
`main` too, and it is skipped by default, which is why no baseline shows it.
The reader fails loudly rather than letting the MCP source stand in, as
designed. Checked by hand for S2: the four terminators in that list
(`complete`, `block`, `request_review`, `request_changes`) are all named in
the new `forge-lane` §2. Fix: re-point the reader at the list, not the literal.

**P4 (S2). Metrics cannot see chunk envelopes after FL3.** *Triaged at S4's
opening: **folded into GW6** and fixed there. `metrics.sh` reads a chunk's
handoff runs (`completed` or `review_requested`, never a reviewer's) and
attributes a verdict to the chunk's own card first. `metadata-live.sh`
projects `review_requested` runs, and the rubric's producer rule names both
outcomes. The cases that fail on the old filter are
`metrics/post-fl3-board-numbers-exact` and `metadata/live-valid-counts`.* Since FL3 a chunk's
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

**P9 (S3). Nothing re-verifies a card the operator repaired by hand.** An FL6
exception leaves the card blocked with the reasons on it. `bounce.sh` gives it
another machine round, and the merge-watcher now completes it if the PR is merged
— but a push to the PR branch of a *held* card starts no new review, so the
evidence behind a merge can be older than the code. While the verifier only
recommends this is the operator's judgement and nothing is wrong. **It is a hole
before merge mode is switched on** (D19.3/D19.4), because the flip makes the
verifier's last verdict the thing that merges. Options: watch the PR's head SHA
and re-open the review when it moves; or refuse merge mode for a card whose head
has moved since its verdict (`--match-head-commit` already refuses the merge
itself, which turns the hole into a failure rather than a silent one). Decide in
S8, with MS4.

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

**P6 (S2 landing). `profiles-bootstrap.sh` reports FATAL on a correct
write under Hermes 0.21.5.** `hermes config get skills.disabled` now prints
`⚠ 'skills.disabled' is not a recognized config key — Hermes may not read it`
on **stderr**, and `verify_config` compares `2>&1` output, so all four
profiles fail readback with got/want identical apart from that line (operator
run, 2026-09-26). The key IS still read at runtime
(`agent/skill_utils.py:308`, `tools/skills_tool.py:168`; the warning comes
from `hermes_cli/config.py`'s key registry), and `config/lane-skill-scope`
passes live. The script writes every SOUL and config before it reads back, so
nothing was skipped. Fix: compare stdout only, and surface stderr without
comparing it. Until then every bootstrap ends in a FATAL the operator must
learn to ignore, S3's `forge-prejudge → forge-verifier` rename included.

*Triaged at S3's opening: promoted to row S2b, its own PR ahead of S3, and
fixed there — `verify_config` reads each key through `cfg_get`, which compares
stdout and surfaces stderr under a `note (<profile> <key>):` prefix without
comparing it. Executed offline against a stubbed 0.21.5 by
`cli/bootstrap-readback-compares-stdout-only`, which also holds the
fail-closed half: a value that really differs still FATALs. It is in `cli`
rather than `config` because `config` returns early without a live Hermes and
is not in CI. The operator trap in the same paragraph was a second finding and
is split out as P7.*

**P7 (S2 landing, split from P6). The bootstrap records the path it was
invoked from.** *Triaged at S4's opening: **moved to S4b**, with WL3, whose
`forge run` has to reach the runtime the same way.* `skills.external_dirs` is written as `$FORGE_DIR/skills`, where
`FORGE_DIR` is the parent of the script that ran, so the invocation path
decides what every live profile reads. Running it from `~/dev/forge` pointed
all four profiles at the dev checkout; running it from `~/dev/forge-runtime`
writes a form `config/external-dirs` rejects. The one correct form is
**through `~/.forge/repo/hermes/profiles-bootstrap.sh`**, which is what *§ How
we run this epic* means by "from the runtime". Nothing asserts this today: the
live check (`config/external-dirs`, S1b's runtime arm) can only see the result
after the fact, and it skips wholesale without Hermes. Triage: either an
offline case that pins the accepted form, or a refusal in the script itself
when `FORGE_DIR` is not the runtime the `~/.forge/repo` symlink resolves to.
*Open; not fixed in S2b, whose PR is deliberately P6's fix alone.*

**P10 (S3 review). Five edges left open by S3's review fixes.** *Triaged at S4's
opening: (3) is **folded into GW1** and fixed. "Merged but the card did not
complete" is now reported once per hold, decision-first, executed by
`verifier/merge-watcher-reports-once`. (1) and (2) are untouched by S4 and stay
open. (4) and (5) sit in merge mode and stay with P9 in S8.* Each was found
by reading the code and none has been measured. (4) and (5) sit in merge mode,
which is off, so like P9 they must close before `FORGE_VERIFIER_MERGE=1`. (1) `--dry-run` promises that no
board is touched, but a gate-blocked PR routes *before* the dry-run exit. Run
with a live board, it still makes the `request-changes` transition. (2)
`merge-check.sh` prepares the clone once, on the head, before `main` is merged
in. So when `main` changes dependencies, the union can go red for environment
reasons, and that red reads as `check-failed`, a bounce. (3) The merge-watcher's
"merged but the card did not complete" line repeats every sweep. That is the
same noise `merge-watcher-reports-once` removed for a closed PR. (4)
`route_merge` treats any non-zero exit from `gh pr merge` as "nothing merged"
and never reads the state back. If `gh` exits non-zero after the squash has
landed (a failed `--delete-branch`, say), the card is blocked
`other: handoff-integrity`, which the watcher does not sweep. That is the
stranding the `merged-held` path fixed for a failed completion. The cheap fix
is to read the state back on a non-zero exit and take the rc-4 path on
`MERGED`. (5) When the post-merge `merge-pending:` hold itself fails, the
substrate reason is written to start with `merge-pending:` so the watcher can
still find it. No case has executed that fallback.

**P11 (S4). The `forge-digest` profile no longer has a job.** GW2's digest
runs under `hermes cron --no-agent`, so no model reads the boards or relays the
message. The `forge-digest` SOUL still tells a model to `kanban_list` and
compose the numbers, and the Roles table still lists a "cheap model relaying
script output". Neither was ever scheduled, so nothing runs it today. The
profile, its SOUL and the Roles row should go together, once run A's week of
digests confirms nothing wants a model there. Changing a SOUL is a
`profiles-bootstrap.sh` step, so S4 left it alone. Triage with WL retirement
(S13), or earlier if the operator would rather not keep an idle profile.
*Triaged at S5's opening: **moved to S13**, with WL retirement.*

**P12 (S4). The retro log's generated row has no north-star cell.** GW6 says
`/retro` *and* `make metrics` lead with the north-star numbers. S4 did the
second. `metrics.sh --markdown-row` still emits the nine columns
`docs/retro-metrics.md` defines, and `metrics/markdown-row-has-operator-and-driver-cells`
pins that header. Adding a column is a change to the retro log's format, and
WL5 (S13) retargets `/retro` at these numbers anyway. Until then the retro
reads them from `make metrics`' first section. *Triaged at S5's opening:
**folded into WL5** (S13).*

**P13 (S5). An interactive chunk speaks before it has anything to ask.**
`board-bootstrap.sh` blocks a `claude-interactive` chunk at creation. The
digest lists every blocked card, so a human chunk in milestone 3 appears under
"waiting on you" from day one, while its parents are still open. S5 fixed this
for gates only: the digest's waiting list skips a held `GATE-*` card whose
parents are not all done. The same rule for interactive chunks would change
`digest/fixture-message-exact`'s expected text, and S4's row owns that
message. Evidence: `scripts/digest.sh` `board_json`, the `waiting` query.
Triage it with the next digest change, or before run A if the M1 plan has a
human chunk with parents. *Fixed in S6b. The digest leaves out a `blocked` card
whose last block reason is the bootstrap's interactive hold while any parent is
not `done` or `archived`. That reason is now one string,
`INTERACTIVE_HOLD_REASON` in `scripts/decision-message.sh`, which the bootstrap
writes and the digest reads. The rule keys on the reason because it is the one
mark the card carries, so S4's fixture message is unchanged. Executed by
`digest/an-interactive-chunk-speaks-only-when-its-parents-are-done`,
`bootstrap/interactive-hold-is-the-reason-the-digest-skips` and, on the
installed kernel, the opt-in
`bootstrap/real-hermes-interactive-chunk-waits-for-its-parents`.* *Triaged at
S6's close: **promoted to row S6b**,
before S7. The Squatfather's CHUNK-5 is `claude-interactive` and depends on
CHUNK-2 and CHUNK-3. Triaged at S6's opening: **S6's roadmap decides
it.** If The Squatfather's M1 has a human chunk with parents, P13 is promoted to its
own row before S7. Otherwise it waits for the next digest change.*

**P14 (S5). The operator completing a gate is not an operator action in
`make metrics`.** `touches` counts comments and unblocks, and `merges` counts
the operator's merges. The `complete` that releases a milestone is neither. In
run A that is one uncounted action per milestone, and it is the checkpoint
reply MS4 later automates. Decide in S8, with MS4, whether a gate completion
counts, and whether the north-star row "operator actions per merged chunk"
should carry it.

**P15 (S6). Claude Code upgraded itself mid-epic.** `make preflight` on
2026-09-28, after S5's deploy, reported PASS 104 / WARN 4 / FAIL 0. The fourth
WARN is new: `docs/state.md`'s recorded environment says Claude Code 2.1.281,
and the live version is 2.1.283. *Hold still during the epic* rules out an
upgrade except as its own session, and nobody chose this one. S6's planning
runs on 2.1.283, and the lane does not use Claude Code, so run A is not
affected. Triage: pin or disable Claude Code's auto-update before run A, and
update the recorded version in `state.md` when S6 closes. *At S6's close,
2026-10-01, it had moved again, to 2.1.286. `state.md` now records 2.1.286,
so preflight is green until the next unchosen upgrade. The pin is still open
and is the operator's, before run A.*

*At S7's opening, 2026-10-02:*
- Claude Code moved again, to 2.1.287. `~/.hermes/node/bin/claude` was
  re-linked at 01:19 that morning, minutes into S7's opening session.
- Codex and uv moved too, in one Homebrew upgrade at 2026-09-28 12:00:
  codex-cli 0.157.1 against a recorded 0.156.1, and uv 0.12.19 against
  0.12.18. The lane's `make check` runs through uv.
- "The lane does not use Claude Code, so run A is not affected" was incomplete.
  The verifier's scorer is `claude -p`, and the gateway's `PATH` resolves
  `~/.hermes/node/bin` first.

S7's registration PR records all three in `state.md`.
`cli/codex-run-flags-exist` passes against 0.157.1, and commissioning's paid
probe revalidates whichever Codex is installed at launch. **The pin is closed
without one, by the operator's decision at S7's opening:** Claude Code and
Codex stay current (*Hold still during the epic*, amended). Run A records
versions instead: at launch, at the root checkpoint, at the end of M1, and
whenever one moves.

*Triaged at S6's opening: P7 stays with S4b; P9, P10(4)–(5) and P14 stay with
S8; P10(1)–(2) stay open. S6 plans a project and changes no Forge code, so
none of them is in reach.*

*Triaged at S6b's opening: P13 is S6b's item. P3, P7, P9, P10 and P14 stay
where S6 left them, since S6b changes only the digest's waiting list and the
bootstrap's hold string. P15's pin is still the operator's, before run A.*

**P16 (S6b). An interactive chunk that does speak reads as `other`.** Once
its parents are done, the digest renders the bootstrap's hold as an unknown
class. Executed on Hermes 0.21.5 in an isolated `HERMES_HOME` while opening
S6b:

```
other: interactive chunk: human implementation required

What it means: something outside the known block classes stopped this card
Decision needed: read the reason and decide
Risk: unknown — the card holds until someone looks
Reply: `hermes kanban --board p13-probe show t_6ce2b0d6`
```

The card is waiting for the operator to implement it with `/start-chunk`. The
message says neither that nor what releases it, and it calls the risk unknown.
S5 gave a gate a decision-first hold (`milestone-gate`); an interactive chunk
got nothing. The fix would build the interactive hold with `decision_message`,
as the gate's is built. That changes `INTERACTIVE_HOLD_REASON`, and with it
what the digest matches, but that is one string in one place now. In run A
this is CHUNK-5's message once CHUNK-2 and CHUNK-3 merge. Triage with the next
GW1 change, or before run A reaches CHUNK-5. *Fixed in S6c.
`INTERACTIVE_HOLD_REASON` is now a decision-first message,
`interactive: this chunk is yours to implement; no lane will pick it up`,
whose reply is `/start-chunk`. It names no card, so it stays byte-identical
on every card, and the digest's exact match still holds. On the installed
kernel, the opt-in `bootstrap/real-hermes-interactive-chunk-waits-for-its-parents`
passes with the multi-line hold. Executed by
`digest/an-interactive-hold-is-decision-first`.*

*Triaged at S5b's opening: P3, P7, P9, P10 and P14 stay where S6b left them.
S5b adds a runner and changes only the words of the gate's hold, which none of
them reads. P16 is the interactive hold, not the gate's, so it still waits for
its own GW1 change, before run A reaches CHUNK-5. P15's pin is still the
operator's, before run A. MS2's middle sentence, "failures become chunk cards",
moved to S8 with MS4: whether a failed case is a defect or a probe bug is a
judgement, so it belongs to the checkpoint rather than the runner. S5b's items
start at P18, because S3b's open PR #84 claims P17.*

**P18 (S5b). A probe's `run` can name a driver outside its input, and nothing
freezes it.** `validate_probe` hashes every file under each case's `input`.
The argv is hashed as part of the probe file, but a file it names elsewhere is
not. Running the product itself (`src/...`) is the point. A probe-authored
driver outside the input, though, is code an implementation branch could
change without `--check-base` seeing it. The Squatfather's probes and the
redglass replay both keep their drivers inside the input (`{input}/run.py`), so
nothing is exposed today. Fix shape: `/roadmap` says drivers live under the
input, and `acceptance-freeze` refuses an argv path under `tests/probes/` that
lies outside its own case's input. The same holds for a file named indirectly,
such as a `.DS_Store` read by a script. S5b refuses only an argument that names
one. Triage with the next planning change, before a second project plans.

**P19 (S5b). An expected exit of 1 is also what a crash returns.** The
Squatfather's GATE-M3 case `partial-push-reports-scheduled-and-missing`
expects exit 1. Run against a copy of the plan while opening S5b, before any
code exists, it missed only on stdout, because the `ModuleNotFoundError`
traceback also exited 1. Its stdout substring is what keeps it honest. The replay's driver
avoids this: it keeps 1 for a crash and uses 10, 20, 30 and 40. Fix shape: a
`roadmap-check` warning on an expected exit of 1 or 2 (a crash, argparse's
usage error), or a line in `/roadmap`. Triage with P18. The Squatfather need
not amend anything for run A, since its substring already guards the case.

**P20 (S5b review). The runner keeps only a tail of a failing case's output,
and does not re-check its inputs after a run.** A second review proposed two
additions:
- `--logs <dir>`, the full stdout and stderr of every case;
- a digest check after the run, naming the case that changed its own frozen
  input. Today the next run's NO VERDICT names the path but not the cause.

Both serve S8's overseer, which reads a gate's result without an operator
beside it. Neither changes a verdict, so S5b deferred them. Triage with MS4.

**P21 (S7 opening). A human-tier chunk handed off from outside a worker cannot
be bounced.** This was executed on 2026-10-02 against Hermes 0.21.5 in an
isolated `HERMES_HOME`. It mirrored `lane-handoff.sh`'s operator path on a card
held the way `board-bootstrap.sh` holds one: blocked and unassigned.
1. `unblock`, then `request-review --reviewer forge-verifier`: the card reads
   `review/forge-verifier`.
2. The reviewer claims the review run.
3. `request-changes` refuses, and the card stays `running/forge-verifier`:

```
cannot request changes for t_4b955c01: review handoff has no valid implementer provenance
```

The kernel takes the implementer from the `review_requested` event, which
records the assignee at handoff (`hermes_cli/kanban_db.py`, `request_changes`).
The bootstrap takes `forge-operator-handoff` off again (`assign none`), so there
is no assignee to record. `prejudge-review.sh` then exits through
`substrate "other: handoff-integrity — request-changes did not return this card
to its implementer"`. So **any** verifier bounce of a human chunk strands the
card as a substrate block. In run A that is CHUNK-5, whether seeded or not.

Assigning `forge-operator-handoff` before `request-review` fixes the kernel
half. Executed the same way:
- `request-changes` lands the card on `ready/forge-operator-handoff`;
- a second handoff from `ready` reaches `review/forge-verifier`;
- a recommend block lands `blocked`;
- `complete` reaches `done`.

The operator's disagree path also fails on a human chunk. Executed the same
way, on a card held by a recommend block (`--kind needs_input`), `bounce.sh`
exits 1 whether or not the sentinel was assigned before the handoff:
- unassigned: "no review_requested event names an implementer to restore";
- assigned: "still parked on 'forge-operator-handoff'".

Both times the card ends `ready/forge-operator-handoff`, which is the right
place for a human chunk, and the script reports it as a failure (lines 83–93).
`lane/lane-handoff-is-fail-closed` covers the operator path against stubs
only. *Triaged at S7's opening:
promoted to row S6c, with P16.* *Fixed in S6c, in three places:
- `lane-handoff.sh` gives an unassigned card the sentinel before it unblocks
  it, so the kernel records an implementer and a bounce lands the card on
  `ready/forge-operator-handoff`.
- `bounce.sh` accepts the sentinel as a human chunk's implementer, and reports
  "back with the operator".
- The digest lists such a card under "waiting on you" (`returned:`), and no
  longer counts it in flight.

`verifier/a-human-chunk-can-be-bounced` executes the whole loop on the
installed kernel with the real scripts: the bootstrap's card, a bounce, the
digest, a second handoff, a hold, and `bounce.sh`. Before the fix it failed
with this exact `handoff-integrity` refusal.*

**P22 (S7 opening). The cron step that `digest.sh` and `merge-watcher.sh`
document cannot be done.** Both headers tell the operator to symlink the script
into `~/.hermes/scripts/` and name the link in `hermes cron create --script`.
Hermes 0.21.5 resolves the path first, and refuses one that resolves outside
that directory, symlinks included (`hermes_cli/cron.py:579-585`, "script
resolves outside …"). The live crons use two wrapper files instead, which
`exec bash "$HOME/.forge/repo/scripts/…" "$@"`, and whose own comments say why.
`digest/cron-symlinks-reach-their-siblings` still asserts the symlink shape.

Nothing is broken today: the wrappers work, and the scripts still find their
siblings through the symlinked `~/.forge/repo`. But an operator following
either header gets a refusal. Triage with the next change to either script.

*Triaged at S7's opening (2026-10-02):*
- *P16 is promoted to row S6c, with P21, ahead of run A. Run A's seeded defect
  goes through CHUNK-5.*
- *P15 is **closed without a pin**, by the operator's decision. Claude Code
  and Codex stay current, and run A records the versions instead. Its dated
  note above also corrects its claim about run A.*
- *P17 sits in S3b's PR (#84), which lands before run A.*
- *P3, P7, P18, P19 and P20 stay where they were, since none is on run A's
  path.*
- *P10(1) and (2) stay open. (1), `--dry-run`, is not used in run A. If (2)
  bounces a run A chunk on an environment-red union, that bounce is a finding,
  triaged then.*
- *P9, P10(4)–(5) and P14 stay with S8. P14 does not arise in run A, because
  `GATE-M1` is not completed.*
- *P11 and P12 stay with S13.*
- *P22 is new and waits for the next change to either script. S6c's opening
  decides whether S6c, which touches the digest, takes it.*

*Triaged at S6c's opening (2026-10-02):*
- *P16 and P21 are S6c's items.*
- *The review that merged S7's registration (#85) found two defects in
  `docs/run-a.md`. Both are folded in here, because the protocol is open to
  edits until `RUN_START` and S6c rewrites its S-1 steps anyway:*
  - *the delivered digests are named `<date>_<time>.md`, not `<date>.md`;*
  - *`$RUN_START` was used as a shell variable that nothing set.*
- *P22 stays open. S6c touches `digest.sh` but not `merge-watcher.sh`, and
  fixing one header would leave the two disagreeing.*
- *Everything else stays where S7's opening left it.*

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
