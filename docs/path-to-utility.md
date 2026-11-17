# Path to utility

The order of work, updated 2026-11-17 after Run B completed both remaining Squatfather
milestones and recovery release #130 passed its live rehearsal. The epic records history; this page chooses the next work. The owner delegated
implementation direction and Terra/Luna orchestration to the takeover session.

## What the evidence says

Forge has delivered one complete planned product: 13 chunks across three milestones.
Run B merged eight chunks through the verifier. Its M2 and M3 probes pass 4/4 and 6/6;
GATE-M3 is complete. This demonstrates the delivery loop against frozen probes, not that
someone has successfully used the product against their real accounts.

M3 needed one operator unblock after a transient GitHub diff read. Three reviews bounced
and were repaired; the previous metrics hid all three. The watchdog was loaded but missed
its interval repeatedly. The useful next step is reliable recovery and trustworthy evidence,
followed by a real operator journey. Engine comparisons are premature.

## Ordered work and its exit evidence

| Order | Work | Done when |
|---|---|---|
| 1 | **Recover without losing the run.** Keep repeated lane/verifier holds out of triage when the card can be identified; retry read-only GitHub failures with a bound; retain every review decision; report actual bounce events. Recover the existing Slice 2 work. | Focused regression and required CI pass; deploy and one end-to-end rehearsal pass. Completed in #130: required CI, preflight and a 3m31s live rehearsal passed; the live approval payload was archived. Early identity failures and driver-authored blocks remain exceptions. |
| 2 | **Prove unattended liveness.** The calendar workaround is deployed and its first 08:00 scheduled run was healthy. Observe sustained operation. Diagnose the underlying scheduler fault if accessible logs become available. Verify one killed worker and one paused cron are reported within 30 minutes. Add an external heartbeat when the owner has a destination. | Scheduled readings continue for a full day without a manual kick, both fault exercises are observed, and delivery is verified. A healthy manual watchdog run is insufficient. |
| 3 | **Measure the whole run honestly.** Sum retained review cost/usage and lane usage; separate subscription usage from billed dollars; expose missing historical rounds. Replace stale metrics claims and distinguish cards created in the period from work completed in it. | One command produces the results table, with known/unknown totals explicitly distinguished. Historical lost verdicts are not reconstructed as zero cost. |
| 4 | **Prove the front door and actual utility.** Use the delivered Squatfather workflow with the owner, then take a second small, different Python product through `forge new`, planning, `forge start`, one verifier merge and a useful operator action. Fix the friction encountered. | A new project reaches a useful result in one sitting without editing the board or host files by hand. Private account setup and the product choice are the owner's inputs. |
| 5 | **Reduce the maintenance burden.** Archive closed epic entries and retire the completed August roadmap with its obsolete checks; shorten the operator guide around the front-door commands. | State plus this plan stays below 300 lines; retired behavior no longer consumes the verification budget. |

The stages overlap when the evidence is independent. Do not delay recovery fixes for cost
accounting or the Telegram bot. Do not start a new engine experiment just because the next
roadmap row is an old engine row. M3 extended Run B with the existing strong lane; it did not
perform the planned cheaper-implementer Run C comparison.

## Working method

Use Terra for bounded code changes and Luna for bounded evidence gathering. Keep integration,
review and product decisions in the parent session. Separate write ownership; never run two
`verify.sh` processes on this host because its lab path is shared. Start from the last green
main CI baseline, run the affected checks once with usable host dependencies, and let required
CI cover the complete suite. Repeat only for a new change or a real failure. Do not spend model
calls on repetitive monitoring or make a sandbox/cache problem look like a product regression.

## External inputs still needed

The forge-gate Telegram bot enables phone replies to blocked checkpoints. An external
heartbeat destination can detect a restart before FileVault is unlocked. Neither is evidence
of reliability until exercised; neither blocks the code improvements above.
