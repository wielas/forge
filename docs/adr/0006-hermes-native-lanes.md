# ADR-0006: A lane is a Hermes profile, not a program we write

**Status:** accepted · 2026-07-27
**Supersedes:** the lane-shape parts of ADR-0005 (external `codex-worker.sh`
puller). ADR-0005's flywheel and board-per-project decisions stand.

## Context

ADR-0005 assumed the dispatcher *skips* cards whose assignee is not a Hermes
profile, leaving them for an external CLI worker to pull. `lanes/codex-worker.sh`
was built on that reading: a polling loop with its own claim, worktree, timeout,
retry, PR and metadata handling — about 140 lines, with four `board_*` functions
marked VERIFY because none of the CLI flags had been checked.

Reading the shipped contract (`kanban-worker-lanes.md`, and the `KANBAN_GUIDANCE`
block injected into every worker's system prompt) shows the opposite:

- The dispatcher matches `task.assignee` against a Hermes profile and spawns
  `hermes -p <assignee> chat -q <prompt>` in the task's pinned workspace, with
  `HERMES_KANBAN_TASK`, `HERMES_KANBAN_WORKSPACE`, `HERMES_KANBAN_BRANCH`,
  `HERMES_KANBAN_RUN_ID` and friends in the environment.
- An assignee that resolves to nothing is **not** handed to some other puller. It
  is dropped: the card stays `ready` with a `skipped_nonspawnable` event and only
  surfaces via `kanban diagnostics` as `stranded_in_ready` after ~30 minutes.
- Non-Hermes lanes are possible but explicitly *"not yet a paved path"* — the
  dispatcher's `spawn_fn` is pluggable, and everything else (exit-code mapping,
  workspace conventions, auth) is per-integration work you own.

So the external puller was not an alternative design. It was a reimplementation
of machinery that already exists, hung off a hook that does not fire.

## Decision

**D6.1 — Each lane is a Hermes profile.** `forge-codex-lane` reads the card via
`kanban_show()`, drives `codex exec` inside the task's worktree, verifies with
`make check`, opens the PR, and terminates with `kanban_complete` or
`kanban_block`. Hermes owns claim, reclaim, retry, circuit-breaking, logging,
run history and the dashboard. We own the protocol and nothing else.

**D6.2 — The protocol is a skill, not a script.** `skills/forge-lane/SKILL.md` is
the single description of the lane; the profile's `SOUL.md` is identity plus a
pointer to it. Skills are per profile (each profile is its own `HERMES_HOME`), so
profiles reach the git checkout through `skills.external_dirs` — never symlinks
into a curated directory, because Hermes runs a curator over that directory and
is contractually forbidden to touch external-dir skills.

**D6.3 — Delegate the failure machinery instead of rebuilding it.** Every
mechanism the runner implemented has a board-native equivalent, and the native
one is better because it survives a worker crash:

| `codex-worker.sh` did | Hermes does |
|---|---|
| `flock` + poll loop | dispatcher, embedded in the gateway |
| `board_claim` fallback chain | atomic claim + `claim_lock` |
| `timeout $CHUNK_TIMEOUT` | `--max-runtime`, SIGTERM then SIGKILL, re-queue |
| retry bookkeeping | `--max-retries` / `kanban.failure_limit` breaker |
| `FORGE_METADATA_BEGIN/END` stdout scraping | `kanban_complete(metadata=…)` |
| runner-side worktree create/remove | `--workspace worktree`, preserved on completion |
| per-run log files | `task_runs.log_path`, `kanban tail`, `kanban runs` |

**D6.4 — Cards carry their own configuration.** `--assignee`, `--workspace
worktree`, `--branch`, `--max-retries`, `--idempotency-key`, `--skill forge-lane`
are set at card creation, so lane behaviour is per-card data rather than a
redeploy. `--board` must be passed explicitly (before the subcommand — it belongs
to the kanban parser), or cards land on whatever board is persisted as current.

## Consequences

- Roughly 140 lines of forge code deleted, and the parts most likely to be wrong
  are the parts we no longer own.
- The lane is only as reliable as the profile's model. The driver is deliberately
  cheap on the theory that Codex does the thinking, but the driver still has to
  heartbeat, verify honestly, and terminate correctly — and a protocol violation
  wastes a whole run. Watch for `crashed` reaps in `kanban runs`; the mitigation
  is per-card (`--model`, or `--goal` for a judge-enforced completion loop), not
  a rewrite.
- We inherit Hermes's release cadence. `preflight.sh` exists precisely for this:
  run it after every `hermes update`, because config drifts across upgrades
  (0.18.2 → 0.19.0 silently changed `approvals.mode` and `goals.max_turns`).
- Two documented-but-unimplemented config surfaces have already burned us
  (`custom_toolsets:` resolves to zero tools; `hermes config set` stores lists as
  strings). Prefer what a running probe confirms over what the docs promise, and
  record the probe.

## Rejected

- **Registering a non-Hermes lane via a `spawn_fn` plugin.** Supported in
  principle, unpaved in practice; it would put us back in the business of mapping
  a CLI's exit codes onto board state.
- **Keeping the runner as a fallback for when the dispatcher misbehaves.** Two
  paths that can both claim a card is a race, and the fallback would rot unused.
- **A `--goal` loop for every chunk card by default.** It buys completion
  pressure at the cost of an auxiliary judge call per turn and a fuzzier
  definition of done than `make check` green. Reserve it for cards that a single
  pass repeatedly fails to finish.
