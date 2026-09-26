# ADR-0019: One card per chunk, review on that card, and the verifier merges

- Status: accepted · 2026-09-25
- Supersedes: ADR-0007 **D7.1, D7.2 and D7.3**. D7.4 (a structured verdict)
  stands; ADR-0007 has no further decisions.
- Amends: ADR-0008 — its *mechanism* changes, its *rule* does not.
- Constrains: ADR-0009 (what tier 1 decides), ADR-0010 (a protocol is a
  program), ADR-0017 (an ungatable repository).
- Context: `docs/epic-hands-free.md`, item FL1, and its evidence ledger.

## Context

Two near-complete product runs — JobApp (`jobapp-second-instance`) and redglass
(`redglass-run-1`, `wielas/vault`) — finished with **0 %** of chunks merged
without the operator. Lane compute was 2.4 h and ~8 h; the runs spanned 8 and 20
days. The difference is not compute and it is not the model. It is that every
chunk needs at least one human round trip — `/judge`, then merge, then the
dependent child unblocks — so throughput equals operator availability. Redglass
CHUNK-15–19, driven interactively, merged five chunks in about a day.

ADR-0007 built that round trip on purpose, and said so: D7.2 called keeping a
human at final approval "a deliberate choice … not a stopgap". The runs are the
evidence that the choice, as built, does not survive contact with an unattended
system. Three measurements decide this ADR.

**1. Tier 2 was skipped, not performed.** Several redglass tier-2 cards were
closed with "merged", "Approved", or CHUNK-8's "merged out of band" — no `/judge`
run happened. *Several* is the ledger's word and is deliberately not sharpened
into a count here. A gate the operator routes around is not a gate; it is latency
with a ceremony attached. Tier-2 caught a real defect in 3 of 5 JobApp chunks and
**0 of 9** redglass chunks.

**2. The backtest says the cheap tier already agrees with the expensive one.**
Tier-1's derived verdict was `approve` every time:

| Chunk | Tier-1 scores | Tier-2 outcome |
|---|---|---|
| JobApp C10 | 3/2/3/3/3/3 | approve, agreed exactly |
| JobApp C19 | 2/3/3/3/3/3 | approve (doc nit) |
| JobApp C17 | 3/3/3/3/3/2 | approve-with-nits; found a provably dead scenario predicate |
| JobApp C20 | gate hand-completed | approve-with-nits, scenario_integrity 1 |
| JobApp C21 | 2/2/3/3/3/3 | **bounce** 2/1/1/3/2/3 — two mutation-proven blockers |
| redglass 2, 3, 5, 7, 8, 11 | 3/3/3/3/3/3 | approved or merged; no defect found |
| redglass 1, 10, 12 | one 2 | approve(-with-nits); PR #9's merge exposed a 5-test union failure |

"Tier-1 approve **and all 3s** ⇒ auto-merge" would have merged 6/14 redglass and
0/5 JobApp PRs, and **held every PR where tier-2 found a defect.** That rule is
not the one adopted below, but it bounds the risk: on the recorded runs, a
machine merge on unanimous agreement would have let nothing through that a human
caught.

**3. Neither tier caught the biggest defect.** The redglass CHUNK-15.0 probe
found the core gates fail-open — demand cleared by another country's evidence,
economics called "moderate" with 15 of 16 inputs assumed, risk passing with
safety unknown. Every one of those chunks had passed both tiers. Per-chunk
review, however many tiers it has, cannot see a whole-system property. The
backstop for that class is a probe over the assembled milestone, not a third
reader of one diff.

Two structural costs sit on top of the three measurements. Cards per chunk ran
1.9 (JobApp) and 3.5 (redglass) because judge and fix cards are children; the
CHUNK-8 card storm was a cheap model making board calls, and C20's respawn-guard
trap was the same shape. ADR-0007 itself named the remedy and the trigger, in the last of its
consequences rather than in a decision: *"If the hello-chunk run shows the child
card is unreliable, switch to `review-required` — that is the honest fallback,
and this decision is the weakest one here."* The runs are that showing.

## Decision

**D19.1 — One card per chunk, for its whole life.** A chunk card is created
once, is implemented once, is reviewed on itself, and reaches `done` only when
its PR is merged. No judge card, no fix card, no handoff card. Hermes 0.21.5
supplies the mechanism: `request-review` claims the card for the verifier,
`request-changes` and `reopen-review` return it to `ready` with the original
implementer restored and the reason recorded as a comment.

**D19.2 — The verifier merges, and the operator is not a per-chunk step.**
Approval is granted by `forge-verifier` (today's `forge-prejudge` profile) on
the evidence of the deterministic gate plus verification that *executes*: a
mutation probe of the frozen scenarios and `make check` on the merged tree, not
a reading of the diff. ADR-0007 D7.2's human tier is retired as a per-chunk
stage; the operator's remaining per-run touchpoints are planning, the milestone
checkpoint, and exceptions.

**D19.3 — Recommend-only is the default, and merge mode is earned.** The
verifier ships in **recommend-only**: it reaches its verdict exactly as it would
in merge mode, and then, on approve, blocks the card `needs_input` instead of
merging. The operator merges, the merge-watcher moves the card to `done`. This
is the shadow arm — it produces the disagreement data the flip criterion needs
while the blast radius of a wrong approval is still zero.

Half of this state machine is **executed** and half is **read in source**, and
the difference is recorded rather than blurred (ADR-0017's fixture-proof rule).
Executed against the installed Hermes under an isolated `HERMES_HOME`,
2026-09-24: `review → complete → done` releases the child; `reopen-review`
returns the card to `ready` with the implementer restored and the reason
recorded as a comment, three rounds running; an operator-level `block` of a card
in `review` is refused. Read in Hermes 0.21.5's source and **not yet executed**:
that a claimed review run is `running` with `source_status=review`, so the
verifier's own block lands in `blocked` and `unblock` returns it to `review`;
that `complete_task` accepts `blocked → done` given a result; and the
`BLOCK_RECURRENCE_LIMIT=2` triage route. FL4's fixtures must execute those three
before anything depends on them.

> **Correction, 2026-09-26 (epic S3, FL4).** All three were executed, and the
> third one changes this decision. `complete_task` does accept `blocked → done`,
> and the verifier's own block of a claimed review run does land in `blocked`
> with `unblock` returning it to `review`. But the `BLOCK_RECURRENCE_LIMIT` route
> is **not usable as this ADR assumed**: a card in `triage` refuses `complete`,
> `complete --force`, `promote` and `unblock`, and its one CLI exit
> (`hermes kanban specify`) calls an auxiliary model and lands the card in
> `todo` — back with an *implementer*, never at `done`. A chunk whose PR is
> merged and whose card reached triage therefore cannot be completed, and its
> children never release.
>
> Two consequences. First, the verifier **never re-blocks with the kind of the
> last block on that card**: the kind is read out of the last `blocked` event's
> payload (the columns are not exposed by `show --json`) and rotated to the other
> sticky kind on a collision, so an ordinary sequence — recommend, the operator
> disagrees, the lane repairs, recommend again — stays a completable hold. The
> recurrence guard exists to stop a *worker* looping unblock/re-block; a re-block
> that follows the operator's own `reopen-review` is not that loop. Second, the
> bounce budget of D19.3's paragraph and FL4's text is **counted by the script**,
> from `changes_requested` events since the last operator decision, and its
> exception is an ordinary block. `verifier/a-hold-is-never-triage` and
> `verifier/hold-kind-mutation-is-caught` execute both halves, the second by
> pinning the kind and showing the card strand.

Merge mode is not a configuration the verifier may choose. It is switched on by
the operator, once, after the flip criterion below is met.

**D19.4 — The flip criterion, copied from the epic and not restated.** Merge
authority moves to the verifier only if, over milestone 1: the verifier bounced
every seeded defect; the operator bounced no PR the verifier recommended (each
disagreement is triaged, fixed in FL5 and replayed); and every defect the milestone
probe found was one per-chunk verification could not have seen. Otherwise
milestone 2 runs in shadow too. Each proving run changes **one** variable.

**D19.5 — ADR-0008's rule stands; its mechanism changes.** The rule is
unchanged and non-negotiable: *children build on merged parents.* What changes is
how it is enforced. ADR-0008 was written when a card went `done` at PR-open, so
`parent done` meant "implementation handed off" and dependents promoted against
code that was not on `main` — which is how PR #8 came to contain all six D1+D2
files and invent a stacked-branch policy. Under D19.1 a card is `done` only
after merge, and Hermes's `_parents_satisfied` counts only `done` and
`archived`. The gate is therefore native: holding the card short of `done` until
merge gates its children with no extra machinery. ADR-0008's compensating
mechanisms become redundant rather than wrong, and are retired only when a run
shows the native gate holding.

**D19.6 — Merge method: squash, delete the branch, sweep the worktree.** This
settles the epic's first open question, all three parts yes.

- **Squash.** One chunk is one contract and one reviewed unit; its internal
  retries, park-and-resumes and fixup commits are lane mechanics, not history
  anyone will bisect. A squashed merge also makes "what did this chunk change"
  answerable by one commit, which is what the milestone probe and `/retro`
  read.
- **Delete the branch on merge.** A merged chunk branch that survives is a
  branch a resumed or respawned lane can still push to, and the verifier's
  evidence is the merge commit, not the branch.
- **`worktree-sweep` after each merge.** F40 requires every slice to run in its
  own worktree, and each run recorded one blast-radius false positive whose
  class the ledger names *sibling worktree*. Whether sweeping at merge would
  have prevented those two specific events has not been checked; what is true
  without checking is that a merged chunk's worktree is provably spent, and
  merge is the one moment that is knowable.

**D19.7 — The tier-1 scorer is not removed here.** ADR-0009's `claude -p`
control arm and the `prejudge/scorer-is-the-control-arm` pin stay exactly as
they are. This ADR supersedes D7.1's *decision* — that the unattended tier may
only bounce — not its implementation, and the scorer is retired only once the
executing verifier has superseded it on measured data. Removing it now would
change two variables at once.

## The new risk, stated plainly

**A machine approval can reach `main`.** ADR-0007 rejected "a single strong
judge with merge rights" on the grounds that it "makes a false approval
unrecoverable". That objection is answered, not dismissed, and it is answered by
four things rather than by confidence:

1. **Verification executes.** Read-and-score bounced nothing in either run. The
   mutation probe and the merged-tree `make check` are what caught defects, and
   they are what the verdict rests on.
2. **The milestone probe is the backstop** for the class per-chunk review
   structurally cannot see — the CHUNK-15.0 fail-open class. A milestone closes
   on a gate card carrying a whole-system probe, and a failed probe stops the
   run and waits for the operator.
3. **A revert path.** A squashed chunk is one commit; a wrong merge is
   `git revert` of that commit plus a reopened card. This is only true because
   of D19.6, which is part of why D19.6 is here.
4. **Branch protection — where it exists.** `wielas/forge` is gated by ruleset
   `mainprotect` (PR required, `validate` and `verify` green). Both product
   repos so far are private on a free plan, where `scripts/merge-gate.sh`
   returns 5 / `UNAVAILABLE` (ADR-0017), branch protection **cannot exist**, and
   `gh pr merge` will merge a red PR without complaint.

That last point is the honest weak spot of this ADR and must not be softened:
**on an ungated product repository the verifier is the only gate.** ADR-0017
already requires every commissioning report to carry `posture: UNGATED` beside
`overall:` for exactly this reason. Recommend-only exists so that the first
milestone run does not take this risk at all, and the flip criterion exists so
that taking it later is a decision made on measured data rather than on the
argument above.

## Consequences

- Cards per chunk falls from 1.9 / 3.5 toward 1, plus one gate card per
  milestone. The card-storm and respawn-guard failure modes lose their
  substrate: there are no child cards for a cheap model to create in a loop.
- `forge-lane` §7 keeps its existing prohibition on `kanban_request_review` and
  `kanban_request_changes` — those are the verifier's calls, not the lane's, and
  a card left in `review` is not `done`.

  > **Correction, 2026-09-26 (epic S2, FL3).** Half of that sentence is wrong
  > about the kernel. `request-review` is the *implementer's* transition —
  > `running → review`, recording the implementer so a bounce can route back —
  > and D19.1 cannot happen without the lane making it. Only `request-changes`
  > is the reviewer's. What survives, and is still asserted by
  > `lane/terminator-set-is-closed`, is the prohibition on the *model's tools*:
  > the driver may call neither. The handoff is made by
  > `scripts/lane-handoff.sh` through the Hermes CLI, after the envelope is
  > validated and with the reviewer named, and the CLI binds the run id from
  > the worker's environment, so it proves ownership of the live claim.
  > `lane/bounce-round-trip-on-real-hermes` executes the whole trip, including
  > that the lane's own run cannot complete the card after handing it off.
- The tier-2 handoff, the judge child and the fix child become dead machinery,
  along with the `verify` cases guarding them. They are removed in their own
  slices, each one after the replacement is green, never in the same change.
- `/judge` survives as an operator tool for exceptions and for the milestone
  checkpoint. It stops being a per-chunk stage.
- Nothing in this ADR is implemented by this ADR. It records the decision; FL2
  through FL8 build it, and no claim here may appear in a skill body until a
  check in `scripts/verify.sh` executes it (ADR-0003).

## Rejected

- **Keep tier 2 and make it mandatory.** The runs show what "mandatory" is worth
  against a tired operator at 2 a.m.: several redglass closures that never ran
  `/judge` — "merged", "Approved", CHUNK-8's "merged out of band".
  A gate that is routed around is worse than one that was never claimed, because
  the board still records it as passed.
- **Auto-merge only on unanimous agreement** (the backtest's own rule). It is a
  good bound and a bad policy: it merges 6 of 14 and leaves the rest waiting on
  the operator, so it buys a fraction of the throughput while keeping the whole
  round trip. It is kept above as the risk bound it is.
- **Merge on the deterministic gate alone.** The gate is necessary and not
  sufficient: JobApp C21 was CI-green with two mutation-proven blockers.
- **A third, stronger reading tier.** The defect neither tier caught was not a
  reading failure. Another reader is the one addition guaranteed not to help.
