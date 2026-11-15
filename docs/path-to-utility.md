# Path to utility

What Forge has to become to be worth using, and the order to get there. It replaces the
session plan in `docs/epic-hands-free.md` as the thing that decides what is built next;
the epic stays as the record of what was built and why. One page: when a stage closes,
its lines shrink to one.

**Written 2026-11-15**, from two read-only audits of the code and the host on that day.

## Where Forge is

The loop works. Run A built milestone 1 of a real product (five chunks, the probe passes
5 of 5), and merge mode has run live on a rehearsal board. Once the seams held, a lane
run took 3 to 4 minutes, a verifier run 3 to 8, and a PR went from open to merged in a
median of 1.1 hours.

What it is not yet is a product a person can leave alone:

- **It does not speak.** A new hold, a merged chunk and a stalled worker reach the
  operator only through the 09:00 digest, or when they run `forge status`. A loop that
  turns in minutes waits a day for each human answer.
- **It can wedge without a sound.** Hermes runs one worker at a time for the whole host, so
  one hung worker stops every board. A Codex attempt and a quota park are now bounded and
  end in a hold (built in #123, not yet seen live); a worker that dies some other way, or a
  card nothing picks up, is still reported by no one.
- **Its numbers leave out the money.** The judge's cost is recorded per verdict and never
  summed; Codex tokens are read and dropped; the bounce rate misses the verifier's own
  bounces.
- **It has built one product.** `forge new` and the board-creating rung of `forge start`
  have only run against fixtures. Everything stack-specific assumes Python.
- **It is heavy to read.** 29 of the epic's 46 parking-lot entries are closed, and they are
  about 1,300 lines every session pays for.

## The stages

Each stage is done when its *proof* has been observed, not when its code is merged.

| # | Stage | What is built | Proof |
|---|---|---|---|
| 1 | **The run talks** | `scripts/run-watch.sh` on a ten-minute cron: one message for each new hold, landing and stall. Fault holds name their risk instead of "unknown". A hold made by a worker that gave up says so. The gate verbs answer from the phone (the forge-gate bot: owner's setup) | During run B the operator learns of every hold and every merge within 15 minutes, without opening a terminal |
| 2 | **The run cannot wedge silently** | A bound on a Codex run and on a quota park, after which the card holds with a reason (built in #123, not yet seen live); the same for a judge usage limit, waited out for at most 30 min and then held with nothing to fix. An alert for a `ready` card nothing picks up and for an armed gate whose cron is paused. A heartbeat URL (owner's setup), so a reboot is noticed | A killed worker and a paused cron are each reported within 30 minutes on a rehearsal board |
| 3 | **The numbers are true** | `make metrics` and the digest show, per chunk and per run: judge cost, Codex tokens, wall-clock. The bounce rate counts the verifier's bounces. `metadata-live` stops failing on a producer no flow runs | Run B's results are filled from one command, and the cost of milestone 2 is a number |
| 4 | **A second product** | `forge new` run for real. The plan checks that stop a second project (a `proven` verdict with no spike, an unhashed probe driver, a probe that passes on a crash). A board that does not start chunks before a grant exists. `forge rehearse` against the new repository, not only hello-forge | A second, different product goes from `forge new` to its first verifier-merged chunk in one sitting |
| 5 | **Less to carry** | Closed parking-lot entries move to the archive. The finished August plan in `docs/ROADMAP.md` is retired with the checks that read it. The operator guide is one page. The verify suite loses the cases that guard retired paths | A new session reads the plan and the state in under 300 lines |

Run B (milestone 2 of The Squatfather) runs alongside stage 1 and is its test. Run C
(milestone 3) follows stage 3, so that its question — a cheaper implementer — is answered
with real cost numbers.

## What is deliberately not next

The engine experiments (Pi against Hermes-native, local models, session affinity), the
coloured board graph, per-board spend caps and a second template. Each is worth doing
only after a second product has shipped through the front door; before that they
optimise a loop only one product has used.

## The owner's steps

Three things only the owner can do, in order of how much they are worth:

1. `forge go squatfather-run-a2 --project "$HOME/dev/the-squatfather" --branch-suffix a2` — run B.
2. The forge-gate Telegram bot. Until it exists a checkpoint that blocks is answered from
   a terminal. `make preflight` section 14 lists the four steps.
3. A heartbeat URL in `~/.forge/watchdog.env`. With FileVault on, it is the only thing that
   can say the machine restarted.
