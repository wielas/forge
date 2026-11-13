# Run B — the first hands-free run

Run B is milestone 2 of The Squatfather (CHUNK-6, CHUNK-7, CHUNK-8, then `GATE-M2`) on
board `squatfather-run-a2`. It is epic session S9, as amended by decisions 15 to 17.
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
7. **Grant merge authority to the run's board.**
   `~/.forge/repo/scripts/merge-authority.sh grant squatfather-run-a2 --by <you> --reason "run B"`.
8. **Release milestone 2.** Arm `GATE-M1` with `--mode rehearse` first and read the
   checkpoint the cron delivers; it writes nothing. Then arm it `--mode apply
   --confirm-release`. On its next tick the cron probes M1, completes the gate, and
   CHUNK-6 and CHUNK-8 become ready. From here the run needs no one.
9. **Arm `GATE-M2` `apply`** when you are content for milestone 3 to start by itself,
   or leave it unarmed and the run stops at the gate.

## What the operator does during the run

Reads the digest. Answers a hold if one appears (a bounce budget spent, a blocked
checkpoint, a substrate fault). Applies the stop rules. That is all.

## Results

*Filled from pasted output when the run ends: `make metrics` for the board, the list
of merged PRs with the verifier's verdict and the probe's line for each, any stop rule
that fired, and the M2 checkpoint.*
