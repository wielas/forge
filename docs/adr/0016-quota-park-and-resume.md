# ADR-0016: A usage-limit window is waited out, not lost

- Status: accepted
- Date: 2026-08-31
- Supersedes: nothing. Constrains ADR-0015's escalation path (see D16.5).

## Context

Codex quota stopped being a flat weekly allowance and became a rolling window.
The lane had no concept of either shape. `forge-lane` §4 invoked `codex exec`
as prose, nothing read its exit code, `codex-last.md` was written and never
read, and the repo contained no `429`, no backoff, and no retry-on-limit. A
chunk that ran out of quota was a `kanban_block`, and the next attempt started
from zero.

That last part is the cost. The expensive half of a chunk is Codex reading
itself into the problem; the diff is the cheap half. `docs/first-run-execution-log.md`
already records the same lesson from the Claude side — *"Run them serially, and
**resume** rather than restart, so the comprehension is paid once."* Throwing
away a run because a window closed pays that comprehension twice for reasons
that have nothing to do with the work.

Two observations set the design, both measured rather than assumed:

- **The provider states the reset.** Every `token_count` event on a
  `codex exec --json` stream carries `rate_limits`, and each window in it has
  `used_percent`, `window_minutes` and `resets_at` — an absolute epoch. Rollouts
  under `~/.codex/sessions` on the machine this was written on still show the
  older single-window shape (`window_minutes: 10080`, `secondary: null`).
- **`codex exec resume <session-id>` exists**, and continues the same session.

## Decision

**D16.1 — The wait comes from `resets_at`, never from a duration we choose.**
A window length we hardcode is correct for exactly one quota policy. The
provider's own epoch is correct for all of them, including the one that replaces
this month's.

**D16.2 — Windows are enumerated, not named.** A window is any member of
`rate_limits` carrying `used_percent`/`resets_at`, whatever it is called. There
is no branch on `window_minutes`. This is why the same code reads the old
weekly-only shape and the new short-window shape without being told which it is
looking at — and both are in `scripts/fixtures/quota/`.

**D16.3 — Wake to the LATEST reset among exhausted windows.** If a short window
clears in two hours and the weekly one clears in four days, the run is blocked
until both clear. `max`, never `min`: waking at the nearest reset wakes straight
back into a block, and a lane doing that in a loop burns a night making no
progress. `quota/latest-reset-wins` fails if `min` is substituted.

**D16.3a — …but only over the windows that are actually blocked, and when the
provider names one, only that one.** D16.3 is half a rule; on its own it fails
the other way round. A spent short window beside a healthy weekly one is the
*ordinary* shape under the rolling regime, and taking the weekly reset there
sleeps five days because five hours filled — the same wasted night D16.3 exists
to prevent, reached from the opposite direction. So `max` runs over the blocked
set, not over every window reported, and a `rate_limit_reached_type` that names
its window blocks that window alone. Both halves have their own mutation case;
the second was invisible to the first because the hard-limit fixture had a null
secondary.

**D16.3b — A reset that has already passed is stale evidence, not a block.**
The snapshot describes a window that has since reset. Believing it is how a
pre-flight read of an old rollout, or a reactive read of a log holding an
earlier attempt, parks on a limit that expired hours ago — with nothing
bounding the wait by default. For the same reason a reset beyond a 400-day
horizon is not believed either: that is what an epoch reported in
*milliseconds* looks like, and sleeping on it is indistinguishable from
hanging. Neither case invents a number; both degrade to a bounded re-probe.

**D16.3c — Quota is judged on the current attempt's stream, never the run's
log.** The runner keeps two: an append-only `codex-events.jsonl` for the
operator and the audit trail, and a `codex-events.current.jsonl` truncated for
each attempt. Only the latter answers a quota question, because an append-only
log cannot answer a question about *now* — the exhausted `token_count` and the
`usage_limit_reached` marker from a failed attempt sit in it forever, so a
later failure for an unrelated reason (a dropped connection, an expired token)
reads as a limit that is no longer real and parks against it. `MAX_WAIT` is 0
by default, so nothing bounds that loop, and each pass spends quota on a fresh
`codex exec resume` while the card heartbeats and looks healthy. This is not
theoretical: it was built, measured, and is now the thing
`quota/the-reactive-check-reads-the-current-attempt` exists to hold.

**D16.4 — A park is not a retry, because the run never ends.** This is what
lets the feature exist at all. The repo is deliberately anti-retry —
`--max-retries 1`, "block, never retry" in five places, and single-use run-id
guards in `lane-setup.sh` and `lane-blast-radius.sh` that hard-fail a second
attempt on the same id. Sleeping *inside* one lane run engages none of them:
the run id is never reused, the scratch directory is never recreated, and the
blast-radius baseline captured before Codex started still governs the whole
run, park included.

**D16.5 — Waiting is the default; escalation is the exception.** ADR-0015
(proposed) makes `env:` — "CLI absent, auth expired, rate-limited, overloaded" —
the only class eligible for consent-gated escalation down an implementer ladder.
Waiting and escalating answer the same signal, and they must not race. A rate
limit is a *temporary* unavailability with a stated end time, so it is waited
out; escalation remains for unavailability with no stated end. If ADR-0015
lands, its consent gate applies after this one has given up, not before.

**D16.6 — The park record is durable and keyed by task.** A supervisor killed
during a multi-hour park would otherwise take the session id with it — the
successor run gets a new run id and therefore a new, empty scratch directory.
`~/.forge/lane-parks/<task-id>.json` sits beside `~/.forge/lane-audits/` and
outside every Codex-writable root, and carries the session id, workspace,
blocked windows and wake time. The successor adopts the session only when the
workspace matches.

**D16.7 — The invocation becomes a program (ADR-0010 D10.2), which is not a
lane runner.** ADR-0006 says a lane is a Hermes profile, not a program we
write, and `README.md` says flatly that there is no lane runner. That still
holds: `codex-run.sh` is a protocol *step* the driver calls, exactly like
`lane-setup.sh` (§3) and `lane-blast-radius.sh` (§5). It does not claim a card,
own the lifecycle, heartbeat, terminate, or decide anything about the run —
Hermes still does all of that, and the driver still calls each step in order.
What moved into it is control flow that a prose protocol cannot express. A sleep-and-
resume loop is not a protocol a driver model can be told to follow; it is
control flow. `scripts/codex-run.sh` owns it, and §4 calls it through the
literal `~/.forge/repo/...` form. Per ADR-0003, everything the skill now claims
about parking is asserted by the `quota/` group against fixtures and a stubbed
`codex`, at no token cost.

## Consequences

**The lane can now outlive the dispatcher's patience, and that is a new failure
mode.** Hermes reclaims a task running past `dispatch_stale_timeout_seconds`
(4h) with no heartbeat in the last hour. A window can outlast the 4h mark, so
the heartbeat is the only thing keeping a parked card alive. §4 says so; if a
parked run is silently reclaimed, this is the first thing to check.

**The respawn guard may refuse the cross-run resume.** `hermes-field-notes.md`
records that the guard "already refuses re-spawn on `blocker_auth` (quota/auth)".
If a give-up blocks with a reason Hermes classifies that way, the card will not
redispatch on its own and the park record needs an operator nudge. This is
**not measured yet** and must not be written into a skill body as though it were.

**The resumed sandbox grant is parse-proven, not grant-proven.** `codex exec
resume` takes neither `-s`, `-C` nor `--add-dir`, so the resume path restates
the grant as `-c sandbox_mode` and `-c sandbox_workspace_write.writable_roots`.
Those *parse* — confirmed through `codex debug prompt-input`, which validates
config with no API call, against a bogus-value control. That is the whole of
the evidence. Nothing here shows a resumed session can actually commit into the
shared `.git`, and there is a specific reason not to assume the equivalence:
`--add-dir` adds to the default writable roots while `writable_roots=[…]` sets
a list, so the override may replace what the flag extends. The failure mode is
a silent loss of write access mid-run. It is in `state.md`'s not-proven list,
one real chunk settles it, and until then it stays out of every skill body.

**A resumed run's audit baseline is fresh.** The cross-run path (a new run
adopting a parked session) captures a new blast-radius baseline over a worktree
that already holds the earlier run's work. Mutations made before the park are
therefore outside the new run's audit. The in-run park — the common case — does
not have this gap, because there is only one capture and it predates everything.

**`--json` replaced the human-readable stream.** The lane needs JSON because
that is where the window data is. `scripts/codex-progress.py` condenses it back
into a readable log so the driver's `process(action="log")` is not left watching
raw JSONL scroll past.

**Waiting is unbounded by default.** `FORGE_QUOTA_MAX_WAIT=0` means persist
through whatever the window costs, which is the point. An operator who does not
want a card holding a worktree across a multi-day weekly reset sets a bound and
gets an `env:` block with the park record named.
