# Forge — current state

Start here, then read [the path to utility](path-to-utility.md). History and the session
record live in [the epic](epic-hands-free.md), including *How we run this epic*; the current
plan supersedes its old engine-experiment ordering. Run evidence is in [Run A](run-a.md)
and [Run B](run-b.md). If a behavioral claim and the code disagree, `make verify` arbitrates.

**As of 2026-11-16, takeover.** The Squatfather's 13 chunks and all three milestone gates
are complete. M3 was an extension of Run B using the existing strong lane, not the planned
cheaper-implementer Run C. The final frozen probe passed 6/6 at product main `9136771`.

## What Forge does

An interactive plan (`/scope`, `/architect`, `/roadmap`) becomes a Hermes board. A lane
implements a chunk in a worktree, opens a PR, and hands it to the verifier. Deterministic
checks precede an OpenAI judge, with Claude as fallback. A valid board grant permits the
verifier to merge at the reviewed head. Otherwise the operator decides. Milestone gates
probe the integrated product. The digest and run watcher report progress and holds.

## Current implementation

The recovery slice builds on deployed #129 (`c6dc0f0`):

- The watchdog installer uses six calendar minute boundaries per hour. An isolated host
  experiment produced three calendar runs and zero interval runs; sustained operation still
  needs observation after reinstalling the deployed LaunchAgent.
- Lane and verifier blocks rotate the kernel block kind using the identified card's last
  hold, so another recoverable hold stays blocked rather than entering triage. The verifier
  retains its initial trusted snapshot when a later read fails. Existing triage is reported
  with the recovery command.
- Verifier and deterministic gate GitHub reads get three attempts, each bounded at 30 s,
  with 2 s and 4 s backoff. Only successful output is used; merges are never retried.
- Original decision payloads are retained under `~/.forge/verdicts/history/` before a bounce
  or approval. These record intended decisions; board events prove applied transitions.
  The existing latest-verdict file remains compatible with the merge-watcher.
- Metrics report actual `changes_requested` events, including repeat bounces and open
  cards. Legacy verdict recommendation rates are labeled separately.

The runtime changes only after a green PR is merged and deliberately deployed. Read
`git -C ~/dev/forge-runtime log -1` for the installed revision; the source checkout is not
proof of deployment. Validation and rollout evidence are recorded in the recovery epic row.

## Proven

| Claim | Observed evidence |
|---|---|
| A real plan becomes integrated code | Squatfather M1: five chunks, probe 5/5. M2: three chunks, probe 4/4. M3: five chunks, probe 6/6. |
| The verifier can merge an entire milestone | All eight Run B chunks merged by the verifier. M2 required two quota-related unblocks; M3 required one after a transient diff read. |
| The OpenAI judge works on the real product | All five final M3 verdicts name `codex` / `gpt-6-astra`; three M3 cards were sent back and repaired. |
| A quota wait can resume itself | CHUNK-13 parked once on the OpenAI usage limit and then completed. Exact retained pause timestamps are unavailable. |
| The final checkpoint closes the completed run | Runtime `checkpoint.sh --apply` completed GATE-M3 after 6/6 at `9136771`, five of five chunks, eight of eight delivered requirements, no downstream cards. |
| The normal loop can be rehearsed | `forge rehearse` previously merged hello-forge #23 in 4m52s with the Codex judge; rerun after a behavior-changing deploy. |
| Recovery checks execute kernel behavior | Repeated-hold tests use isolated real Hermes cards; GitHub retry and archive tests use subprocess/board fixtures. Required CI covers the complete suite. |

## Gaps that remain

- **Scheduled watchdog liveness is unresolved.** Its job is loaded, not disabled, with no
  running watchdog process; observed passes exit 0. It missed its 600 s interval repeatedly.
  The host reports no sleep/wake cycles explaining the gaps. macOS denied unified-log
  access even outside the sandbox. #129 detects silence. The isolated calendar experiment
  supports a scheduling workaround, not a diagnosis of launchd or a full-day reliability claim.
- **Notification delivery is partly unproven.** Earlier quota holds reached Telegram;
  watchdog-silent state transitions were observed, but their Telegram receipt was not.
  Killed-worker and paused-cron exercises are still owed.
- **Some blocks cannot rotate safely.** Missing jq, an unreadable or untrusted initial card,
  a driver-authored block, or an external mutation after the snapshot can still reach triage.
- **Historical review cost is incomplete.** M2 had two bounces, M3 three. Older bounced
  verdict payloads were overwritten; board reasons survive, their original usage does not.
  New archives cannot reconstruct that missing cost. Subscription usage is not dollar cost.
- **Phone gate replies and restart detection need setup.** No forge-gate Telegram bot and
  no external heartbeat are configured. With FileVault locked after reboot, local tools
  cannot report that the machine is down.
- **One product has been delivered.** `forge new` and the board-creating rung of `forge start`
  still need a real second-product proof. The delivered product also needs a real user journey.

## Commands and locations

`forge status` reads progress; `forge stop <board>` revokes its grant and disarms its gates.
The completed Squatfather run has no merge authority or armed gates after `forge stop`
read them back; there is no next milestone to release. For the next project:

```bash
forge new my-project --dest "$HOME/dev" [--github <owner>/<repo>]
# Plan in the project: /scope, /architect, /roadmap
PROJECT=/absolute/path/to/project
make roadmap-check PROJECT="$PROJECT"
forge start /absolute/path/to/project --branch-suffix <s>
forge go <board> --project /absolute/path/to/project --branch-suffix <s>
```

- `~/dev/forge`: development; changes land through PRs with required `validate` and `verify`.
- `~/dev/forge-runtime`: live scripts, reached through `~/.forge/repo`; deploy by fast-forward
  after merge, then preflight. **Never run `make verify` here**: mutation tests edit scripts.
- `~/.forge`: host grants, latest verdicts, review history and watcher state.
- `~/forge-evidence`: private run evidence; do not commit private product contents.
- [Operator guide](operator-guide.md): detailed setup and recovery commands.
