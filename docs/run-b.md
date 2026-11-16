# Run B — the first hands-free run

Run B began with milestone 2 of The Squatfather (CHUNK-6, CHUNK-7, CHUNK-8, then `GATE-M2`)
on board `squatfather-run-a2`, and extended through milestone 3 on 2026-11-16. It is epic
session S9, as amended by decisions 15 to 17. The launch sheet below is historical; both
milestones and the final gate are now complete.
This page is the whole protocol. It is short on purpose: `docs/run-a.md` is the record
of what a long one cost.

## What is different from run A

| | Run A | Run B |
|---|---|---|
| Who merges a lane-built chunk | the operator, from the hold | the verifier, under a board grant |
| Who merges a hand-built chunk | the operator | the operator (unchanged) |
| Who completes a gate whose probe passes | nobody (held) | the checkpoint cron, when the gate is armed `apply` |
| How the board follows a plan change | by hand | `hermes/board-sync.sh` |
| What reports a dead gateway or cron | nothing | `scripts/watchdog.sh` |
| Who brings the product checkout up to date before a checkpoint | the operator, by hand | the checkpoint cron (fetch, fast-forward only) |

## What it measures

The north-star rows of `make metrics`, read at the end: operator actions per merged
chunk, chunks merged without the operator, PR open to merge. Run A's baseline is in
`docs/run-a.md`'s Results. Also read at `GATE-M2`: what the mutation probe said about
each merged PR (it still only reports), and whether the M2 probe finds a defect the
verifier merged.

## Stop rules

1. **A merged PR the owner would have bounced:** revoke the grant
   (`~/.forge/repo/scripts/merge-authority.sh revoke squatfather-run-a2`) and record
   the PR here. The run continues in recommend-only.
2. **A merge at a head the verdict did not cover** (the digest says `HEAD DRIFT`):
   same as rule 1.
3. **The watchdog alerts and does not recover within an hour:** stop and look. Nothing
   is lost; cards wait.
4. **Two bounce rounds on one chunk:** the card raises an exception hold by itself
   (FL6). That is the operator's decision, not a stop.

To stop everything at once: revoke the grant, and disarm the gate
(`~/.forge/repo/scripts/checkpoint-arm.sh disarm --board squatfather-run-a2 --gate GATE-M2`).
Neither undoes a merge.

## Launch, in order

Every step is the operator's, or is run with the operator's go. Each is one command and
is safe to stop after. Read the output of each before the next.

1. **Deploy.** `git -C ~/dev/forge-runtime pull --ff-only`, then `make -C ~/dev/forge-runtime preflight`.
   Expect one FAIL, for step 2, and WARNs for the steps below that are not done yet.
   Never `make verify` in the runtime.
2. **Turn the kernel's auto-decomposer off.** `hermes config set kanban.auto_decompose false`.
   Preflight's FAIL clears. Epic P45 says why.
3. **Install the watchdog.** `~/.forge/repo/scripts/watchdog-install.sh`. Optional and
   recommended: put a heartbeat URL in `~/.forge/watchdog.env` (operator guide,
   *Liveness*); with FileVault on it is the only thing that can report a restart.
4. **Create the checkpoint cron,** paused, as #106's operator steps give it, then
   resume it when step 8 is reached. The forge-gate bot (BotFather, the plugin) can be
   set up now or later: without it a checkpoint that blocks is answered from a terminal,
   and a checkpoint that passes needs no answer.
5. **Reconcile the board with the plan.** In the product checkout, on a clean `main`
   at `origin/main`:
   `~/.forge/repo/hermes/board-sync.sh squatfather-run-a2 --branch-suffix a2` (a dry
   run; on 2026-11-13 it named 14 steps and no refusal), then the same with `--apply`.
   It must end in sync. Nothing it does can release a card.
6. **Rehearse merge mode once on hello-forge.** Merge mode has never run live. In
   `~/dev/hello-forge`: bootstrap a one-card board with the next unused suffix (`a2h`
   per `docs/run-a.md`), grant that board merge authority, and watch one card go from
   PR to merged to done with no operator action. Revoke the grant and archive the
   board afterwards. If the card holds instead of merging, stop: that is the finding.
   `forge rehearse` now does this in one command.
7. **Grant merge authority to the run's board.**
   `~/.forge/repo/scripts/merge-authority.sh grant squatfather-run-a2 --by <you> --reason "run B"`.
8. **Release milestone 2.** Arm `GATE-M1` with `--mode rehearse` first and read the
   checkpoint the cron delivers; it writes nothing. Then arm it `--mode apply
   --confirm-release`. On its next tick the cron probes M1, completes the gate, and
   CHUNK-6 and CHUNK-8 become ready. From here the run needs no one.
   `forge go squatfather-run-a2 --project ~/dev/the-squatfather --branch-suffix a2` does 7 and 8 and resumes the cron.
9. **Arm `GATE-M2` `apply`** when you are content for milestone 3 to start by itself,
   or leave it unarmed and the run stops at the gate.

**Launch record, 2026-11-14.** Steps 1 to 6 are done (the epic's *S9 launch record* has the
detail). Step 6 passed: `wielas/hello-forge#13` went from ready to merged to done in about three
minutes on board `hello-rehearsal-a2h`, with no operator action. Steps 7 to 9 are the owner's;
`docs/state.md` gives the command (`forge go`). #112 is deployed, so the checkpoint probes what was merged.

## What the operator does during the run

Reads the digest. Answers a hold if one appears (a bounce budget spent, a blocked
checkpoint, a substrate fault). Applies the stop rules. That is all.

## Results

Milestone 2, 2026-11-15, on the deployed forge `653fa2b` (later `689cbca`); every number below is pasted
from a command, a card or GitHub.

**Launch.** `forge go` was confirmed at 08:20:50Z. The checkpoint cron's first tick completed `GATE-M1`
at 09:36 local (`checkpoint pass: probe GATE-M1: PASS — 5 of 5 cases passed (realistic 2/2,
adversarial 3/3) at ac06baf`) and CHUNK-6 and CHUNK-8 became ready.

**Merged PRs** (`wielas/Squatfather`; each merged by the verifier at the head its verdict covers, CI green):

| Chunk | PR | Merged (UTC) | Head | Verdict | Judge cost |
|---|---|---|---|---|---|
| CHUNK-6 | #13 | 12:31:31 | `a34f974` | approve-with-nits, 2 findings | $0.414155 |
| CHUNK-8 | #14 | 12:40:31 | `883962f` | approve-with-nits, 3 findings | $0.3926328 |
| CHUNK-7 | #15 | 13:18:39 | `dbb25ec` | approve-with-nits, 2 findings | $0.4527846 |

All three final approvals were judged by Claude opus. **Corrected 2026-11-16 from board events:**
the verifier bounced two cards once each: CHUNK-6 at 08:57:45Z (`scenario_integrity`: the steps
checked the exercise name on three sets only), and CHUNK-7 at 13:07:12Z (one actionable fix
and two nits). Both were repaired. Earlier prose omitted CHUNK-7. The dollar figures above
are the retained approving verdicts only; the overwritten bounce verdict costs are unknown. The mutation probe's line is on CHUNK-8's card only: `report-only — 11/46 probed lines observed by
no test`. It was not written to the other two cards.

**`metrics.sh squatfather-run-a2 --since 2026-11-15`:**

```
merged without the operator  1.00 (3/3)
operator actions per merged chunk  0.67 (2 = 2 board touches + 0 merges, over 3 merged)
PR open -> merge  median 3.26 h · max 3.72 h over 3
gate completions  1 = 1 by the checkpoint + 0 by the operator
bounce rate  tier 1  0.00 (0/3 chunk cards)   from 0/3 verdicts
```

Run A read 0.00 (0/5) and 2.40. The historical bounce-rate line above is wrong: it misses both
verifier bounces (epic P40). The corrected event metric reads 2 applied bounces on 2 chunks
for 2026-11-15; it counts observed transitions, not retained verdict recommendations. The two board touches and the 3-hour median are one event: at 10:08 and 10:32
local both reviews ended `env: judge-envelope — claude -p reported an API failure before returning a
verdict (is_error=true, api_error_status=429)`, the account's 5-hour Claude limit, which the overseeing
session shared with the judge. Both cards were unblocked by hand at 13:22 after the reset. CHUNK-7,
which met no limit, went from ready to merged in about 37 minutes.

**Stop rules.** None fired. No merge was at a head its verdict did not cover.

**The M2 checkpoint** (rehearse). First report, 14:24 local: `probe GATE-M2: FAIL — 3 of 4 cases passed
(realistic 1/2, adversarial 2/2); failed: partial-push-then-retry-leaves-one-workout-per-session at
4f560a0`, classified ambiguous. It was a probe defect: `tests/probes/m2/run.py` checked `"complete" not
in text` and the product's failure line is `Push incomplete: upload failed for session B`. The owner
confirmed the amendment; `amend-contract.sh --apply` changed the check to whole words together with the
freeze and the decision log (`wielas/Squatfather#16`, `3a96dd4`). Next report, 19:44: `probe GATE-M2:
PASS — 4 of 4 cases passed (realistic 2/2, adversarial 2/2) at 3a96dd4`, 3 of 3 chunks against an
estimate of 3, 11 of 11 requirements delivered. So the M2 probe found no product defect the verifier
had merged.

**What the run changed in Forge** (rows S9h to S9k and after): the push watcher (#122), the bounds on a
Codex attempt and a quota park (#123), the judge's wait on a usage limit and the failing case's output
in the checkpoint report (#124), and the judge on OpenAI first with Claude as the fallback (#125 to #127).


## Milestone 3 continuation — 2026-11-16

This extended Run B with the existing strong implementer; it was **not** the planned Run C
experiment with a cheaper implementer. Launch/grant at 08:57:08Z; final GitHub merge at
13:11:59Z: 4 h 14 min 51 s, calculated from the recorded timestamps.

| Chunk | PR | GitHub merged (UTC) | Reviewed head | Final judge |
|---|---|---|---|---|
| CHUNK-13 | #17 | 10:53:38 | `4cc9013` | Codex / gpt-6-astra |
| CHUNK-11 | #18 | 11:29:11 | `141b4a9` | Codex / gpt-6-astra |
| CHUNK-9 | #19 | 12:05:58 | `35069da` | Codex / gpt-6-astra |
| CHUNK-10 | #20 | 12:44:44 | `7c38c23` | Codex / gpt-6-astra |
| CHUNK-12 | #21 | 13:11:59 | `d34e1a3` | Codex / gpt-6-astra |

GitHub read-back confirms all five PRs merged. Each retained verdict approves its listed
head with zero final findings; each board completion attributes the merge to the verifier.
Board completion timestamps trail the actual merges by seconds, so they are not substituted
for `mergedAt` here.

**Recovery.** Three `changes_requested` events survive: CHUNK-11 at 11:18:14Z, CHUNK-9 at
11:55:18Z, CHUNK-10 at 12:33:52Z. Each was repaired and approved. CHUNK-12 instead held on
`env: diff-unavailable` at 13:01:12Z and was unblocked at 13:03:21Z: the one operator touch.
Its next review succeeded. CHUNK-13's lane reports one quota park, then resumed itself.
The earlier session reported roughly 1 h 20 min waiting; retained state does not establish
the exact interval, and the completed run's 94-minute duration is not all quota time.

**One-command reading**, `scripts/metrics.sh squatfather-run-a2 --since 2026-11-16 --json`
with the recovery slice:

- Merged without the operator: 5/5, rate 1.00.
- Operator actions per merged chunk: 0.20 (one unblock, no operator merges).
- Applied bounces: 3 events on 3 chunks. The old verdict-only rate misses these.
- Review-request to completion proxy: median 0.33 h, max 0.34 h. Actual GitHub PR
  open-to-merge: median 19 min 38 s, maximum 20 min 24 s, computed from GitHub timestamps.
- Full review cost: unknown. Older bounced verdict payloads were overwritten; subscription
  usage is not a measured dollar charge. New history starts with this recovery deployment.

**Final checkpoint.** The takeover fast-forwarded the clean product checkout to `9136771`
and ran the frozen M3 probe: 6/6 (3 realistic, 3 adversarial). The deployed runtime's normal
`checkpoint.sh --apply` then rechecked and completed GATE-M3 (`t_7af4caeb`): 5/5 chunks,
8/8 named requirements delivered, zero triage follow-ups and no downstream cards. The
milestone probe found no product defect. `forge stop squatfather-run-a2` then revoked the
spent grant and confirmed no gates armed. No new milestone was released.

**Watchdog finding.** The job remained loaded and enabled with interval 600; no watchdog
process was stuck, and observed runs exited 0. Recorded passes on November 16 were 01:31,
09:57, 11:41, 12:30 and 14:02 local. The power log shows no sleep/wake cycle explaining the
missed intervals. Unified launchd logs were denied by macOS even with sandbox escalation.
#129's silence detector worked at the state-file level; Telegram delivery and the scheduler
cause remain unproven. A separate timestamp-only experiment at 16:42–16:45 local recorded
zero runs from a 30-second interval job, versus calendar runs at 16:43, 16:44 and 16:45.
Both jobs were removed. This supports the recovery slice's switch to calendar boundaries
(00, 10, 20, 30, 40, 50), but does not prove full-day reliability.

Private supporting records are in `~/forge-evidence/takeover-2026-11-16/`: GitHub read-back,
the checkpoint report, probe logs and corrected metrics. The source board was read through
`board-snapshot.sh`, preserving the WAL rule. Future original review payloads live under
`~/.forge/verdicts/history/`; their action records intent, while board events prove a bounce
actually happened.
