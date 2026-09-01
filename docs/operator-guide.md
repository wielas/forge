# Operator guide — the 20% you'll use 80% of the time

Organised by what you want to do, not by which tool owns it. Everything here was
reconciled against the readiness stack on 2026-08-11; re-check after a
`hermes update`.

## Launch a genuine product run

The canonical, copyable procedure is
[`docs/staged-run-guide.md`](staged-run-guide.md). It includes host preparation,
the new-board assertion, exact checkpoint exit codes, stop rules, and closeout.
The abbreviated contract below is only a reminder.

Once a product has a durable absolute path, a protected remote, a committed
frozen roadmap, and a new empty board slug, run this sequence from the Forge
checkout. The next command is deliberately advisory: repeat it and fix the plan
until it prints `CLEAR`.

```bash
PROJECT=/absolute/path/to/product
BOARD=product-slug

make roadmap-check PROJECT="$PROJECT"   # repeat until CLEAR
make commission PROJECT="$PROJECT" BOARD="$BOARD"   # paid; must be green
(cd "$PROJECT" && "$HOME/.forge/repo/hermes/board-bootstrap.sh" "$BOARD" --root-only)
```

After the root PR merges, run the post-`RUN_START` metadata and metrics checks
described below. Stop on invalid or unjudged metadata. Only a green checkpoint
authorises full bootstrap; after the graph completes, repeat both checks, run
`/retro`, and reconcile the live-proof findings. Commissioning is readiness
evidence, not a substitute for the lifecycle.

## The daily loop

```
plan (you + Claude Code, MacBook)   /scope → /architect → /roadmap
        ↓  cards
board (Hermes, mini)                dispatcher spawns forge-codex-lane per card
        ↓  PR
prejudge (unattended)               bounces ci-red / scenario theater / scope creep
        ↓  survivors
judge (you + Claude Code)           /judge — the only step that needs your taste
        ↓
merge                               auto only if approved AND tagged low-risk
```

You are tier 2. That is the design, not a fallback: it is the one step where
human judgement is the product.

## Steering the board from your phone

`/kanban` works inside Telegram **and bypasses the running-agent guard** — you can
drive the board while an agent is mid-turn.

| You want to | Command |
|---|---|
| See what's happening | `/kanban list` · `/kanban stats` |
| Read one card fully | `/kanban show t_abc` |
| Steer a stuck worker | `/kanban comment t_abc "use the 2026 schema"` |
| Release a blocked card | `/kanban unblock t_abc` |
| Stop something | `/kanban block t_abc "wrong approach"` |

**Comments are the inter-agent protocol.** A comment doesn't interrupt the running
worker — it lands on the thread and the *next* run reads it in `kanban_show()`.
That's how you correct a card without killing it.

## When a night run goes wrong

In escalating order of detail:

```bash
hermes kanban watch              # live event stream, all cards
hermes kanban tail <id>          # one card's events
hermes kanban runs <id>          # attempt history — one row per try
hermes kanban log <id>           # the worker's raw stdout
hermes kanban context <id>       # exactly what the worker was shown
```

`context` is the one to reach for when a worker did something baffling: it shows
the card as the model saw it. Usually the card was ambiguous, not the model stupid.

**A parked lane is working, not stuck.** A card whose log shows `PARKED on
primary,secondary until …` hit a Codex usage limit and is sleeping until the
provider's own stated reset, then resuming the same session (ADR-0016). Leave
it. `~/.forge/lane-parks/<task-id>.json` says which windows blocked, when it
wakes, and which session it will resume; the same facts are on the card as a
`PARK-COMMENT` comment. Two things are worth checking rather than assuming:
that heartbeats are still landing (a window can outlast the 4h stale timeout,
and the heartbeat is all that keeps the card alive), and — if you need the
worktree back sooner — that you set `FORGE_QUOTA_MAX_WAIT`, since the default
is to wait however long it takes. **It is a whole number of seconds**, not a
duration: `14400`, not `4h`. Every knob is validated at startup and a value the
runner cannot read exits `2` naming the knob, rather than quietly dropping the
bound you thought you had set.

**Things that look like bugs but aren't:** a card that reverted to `ready` was
*reclaimed* (no heartbeat in an hour) — benign, it re-runs. A card that refuses to
re-spawn hit the **respawn guard**: quota/auth error, a recent success, or a
comment linking an open PR.

## Claude Code, the parts that matter here

- **Plan mode** (Shift+Tab) before anything non-trivial — it explores and proposes
  before editing. Cheapest way to avoid expensive wrong turns.
- **`/rewind`** or double-Esc restores conversation *and* code to a checkpoint.
- **`/clear` between unrelated tasks.** Your full conversation is re-sent every
  message; a stale session silently burns your plan limits.
- **`/usage`** shows what's eating your allowance, attributed to skills,
  subagents, plugins and MCP servers. Check it weekly.
- **`/context`** shows what's filling the window right now.
- **Subagents vs agent teams:** subagents report back to you; teammates talk to
  each other. Teams are experimental, session-scoped, and don't survive `/resume`
  — good for parallel review, wrong for unattended work.
- Skills are invoked as `/skill-name`, and that works in `-p` mode too.

## Codex, the parts that matter here

- `codex exec "<prompt>" < /dev/null` — non-interactive. The redirect is not
  optional; it reads stdin.
- `--output-schema <file>` forces schema-valid JSON out. This is how the prejudge
  verdict stays machine-readable.
- `-o <path>` writes just the final message.
- Sandbox: `-s read-only | workspace-write | danger-full-access`. There is **no
  `--full-auto`** in 0.145. `workspace-write` grants the workdir plus `/tmp` and
  `$TMPDIR` — which means a probe run under `/tmp` proves nothing about the
  sandbox. Inside a git worktree, committing also needs
  `--add-dir "$(git rev-parse --git-common-dir)"`; without it `git commit` dies
  with `Unable to create …/index.lock: Operation not permitted` (measured).
- `AGENTS.md` in the repo is how you configure Codex per project — the template
  already ships one.

## Hermes housekeeping

```bash
hermes doctor                    # diagnose a broken install
hermes config check              # after every update — config drifts
hermes config migrate
hermes profile list              # who exists
hermes kanban assignees          # who the board can actually route to
```

`hermes update` syncs bundled skills to every profile and never overwrites ones
you modified. **Re-run `make preflight` after every update** — v0.18.2 → v0.19.0
silently changed `approvals.mode` and `goals.max_turns`.

**Isolate every human-driven slice; the manager owns the ledger.** Reserve the
main checkout for the manager/orchestrator. Before an implementer starts a
slice, create its branch in a separate sibling worktree:

```bash
git worktree add ../forge-slices/<slice-id> -b slice/<slice-id> main
```

The audit ledger is the manager's file. A slice may read it and commit it once
as a source document when its signed contract requires that baseline, but it
must never be the only writer or receive manager edits while it is running.
New findings and number allocation stay with the manager in the main checkout.
At handoff, the slice reports its exact worktree path, branch, HEAD, clean/dirty
status, and any unpushed commits. The manager integrates that branch before
deliberately reviewing and removing the named worktree; a handoff is never
permission to sweep sibling worktrees.

**Reclaim merged chunk worktrees — nothing else will.** `worktree` workspaces
are *preserved* on completion (only `scratch` is deleted), so every finished
chunk leaves `<repo>/.worktrees/<task-id>` behind, holding its branch. You
notice when `gh pr merge --delete-branch` fails with *"cannot delete branch …
used by worktree"* (measured 2026-07-28, PR #1). Each is a full checkout plus
the `.venv` the lane built — 50 MB a chunk.

```bash
make worktree-sweep PROJECT=$HOME/dev/my-project           # dry run: prints, changes nothing
make worktree-sweep PROJECT=$HOME/dev/my-project APPLY=1   # act
```

Dry-run is the default and `APPLY=1` is the whole difference — literally `1`,
and nothing else. `APPLY=0`, `APPLY=false` and `APPLY=no` are **refused with an
error**: on a command that removes worktrees and deletes branches, quietly doing
the opposite of what you typed is worse than making you type it again. Omit
`APPLY` entirely for a dry run.

What it will and will not do, because you should not have to read the script to
trust it:

- It only reaches worktrees under `<project>/.worktrees/`. Anything else — a
  sibling checkout, an agent worktree, the main checkout — is printed `REFUSE`
  and left alone. `PROJECT` must be absolute.
- It removes a worktree only if it is clean **and** GitHub reports a merged PR
  on that head branch **whose head commit is the one checked out here**. Merge
  state is read from the remote, not from local ancestry: a squash merge leaves
  no local ancestry, so a local test would call every squash-merged chunk
  unmerged and sweep nothing. The commit comparison is what stops a branch that
  was merged once, deleted, and later recreated with new work from reading as
  merged — a branch name is not the identity of the work on it.
- **Every git question it asks is checked for failure.** A worktree whose
  `git status` cannot be read is kept and named as unreadable, never assumed
  clean; and if it cannot enumerate the worktrees at all it exits non-zero
  rather than reporting that there was nothing to sweep.
- It deletes branches with `git branch -d`, never `-D`. When `-d` refuses — a
  squash merge makes the commit unreachable from `main`, so this is common —
  the worktree is still reclaimed and the branch is reported `RETAINED` for you
  to delete by hand once you have checked nothing is unpushed.

Sweep when the board is idle.

**Explicit review outside the bound.** Anything the sweep refuses stays in
place until a human targets that exact worktree and checks its path, branch,
`git status`, unpushed commits, and remote PR/merge state. **Never widen the unattended sweep.**
It must not reach a sibling checkout merely to make F80 disappear. Only after
that review may the operator deliberately run `git worktree remove --force
<path>` and `git branch -D <branch>` for the named checkout; those destructive
commands are not part of the unattended procedure.

**Reading a live board is never a direct read.** `make metrics` and the suite's
live-board checks both go through `scripts/board-snapshot.sh`, which copies the
board and its durable sidecars and opens the *copy*. This is not caution, it is
the only thing that works: every Hermes board is `journal_mode=wal`, and a
read-only open of a WAL database fails when the board is **idle** — the reverse
of the intuition, and exactly the state a board is in when you sit down to run
`/retro` (audit F47/F67). A `cp` only reads, so the live board is never opened,
locked or written.

What you will see if it refuses, and what each one means:

| exit | meaning |
|---|---|
| 2 | bad usage, no `sqlite3`, or no board at that path |
| 3 | the board changed under all three copy attempts — a torn read, refused rather than reported |
| 4 | the copy is zero bytes or will not open as a database |

On 3 and 4 nothing is printed to stdout and the partial copies are removed, so
there is never a half-written board left for a later reader to trust. **A number
you did not get is the point**: reporting a board that could not be read as a
board with no runs is the failure this replaced.

**Prove metadata after a real run with an explicit cutoff.** Live-board access
is opt-in; default `make verify` executes only the checked-in metadata fixture.
Automation that needs the sweep's exact status classification must call its
machine interface directly:

```bash
./scripts/metadata-live.sh <slug> --since 2026-08-09T12:34:56Z
```

That interface exits 0 for a satisfied contract, 1 for a readable contract
violation, and 2 when its source or cutoff cannot be read. `make metadata-live
BOARD=<slug> SINCE=<timestamp>` remains a human-facing convenience wrapper, but
GNU Make maps any failed recipe to its own generic nonzero status; do not use
the Make process status when automation must distinguish 1 from 2.

Copy the exact RFC3339 start instant from the run log. A missing value, a bare
date, or a timestamp without a timezone is refused before the command resolves
the board path. The sweep reads only a WAL-safe snapshot and reports
`valid`, `invalid`, `unjudged`, and `ignored` totals. It also prints valid
envelope counts by producer profile and schema, and names every bad item by task
and run. Historical rows before `SINCE` contribute only to `ignored`.

A clean result requires a post-cutoff completed run from every producer in
`rubrics/run-metadata-contract.json`, every such envelope to match that
profile's allowed schema, and every worker-authored block reason to match
`blocked_reason_pattern`. An invalid readable row is a contract failure;
malformed JSON is `unjudged`, never valid. Run the command at each staged
metadata checkpoint and stop the launch on either outcome.

## Where projects go

`make new` requires an absolute, durable `DEST`. There is no default, and a
destination that resolves under `/tmp`, `/private/tmp` or `$TMPDIR` is refused.

```bash
make new NAME=my-project DEST=$HOME/dev
```

This is not tidiness. `forgeboard-report` — the first real product the Forge
built — was stamped into `/private/tmp`, which macOS purges and Spotlight does
not index; it took a filesystem sweep to find it, and by then local `main` was
41 commits behind origin (audit F19). Nobody chose that directory. `DEST`
defaulted to `..`, a *relative* path, so the project landed next to whatever
directory the operator happened to be standing in. Symlinks are resolved before
the check, so `/tmp` and `/private/tmp` are the same refusal.

## Commission before the board can spend

Commissioning is the one intentionally paid readiness command. Run it from the
Forge checkout only after the product has a clean tree, an `origin` remote and
an ignored `.forge/` directory:

```bash
PROJECT=$HOME/dev/my-project
BOARD=my-project
make commission PROJECT="$PROJECT" BOARD="$BOARD"
```

It runs `make verify WITH_CODEX=1`, `make preflight`, the product roadmap check,
the durable-path and clean-tree guards, remote resolution, and the existing
merge-gate check. Every result and its exact output lands in
`$PROJECT/.forge/commission-<UTC>.<unique>.md`; roadmap `WARN` text remains a
warning. The GitHub repository is parsed from the product's exact `origin` URL,
passed explicitly to `gh repo view`, compared with GitHub's returned identity,
and then passed unchanged to the merge gate. Ambient `gh` context cannot
silently select a different repository. The report is published atomically;
failure to create, write, or publish it makes commissioning fail. That ignored
report is the only permitted project change, and commissioning fingerprints
the board files before and after without opening them or calling Hermes.

Once the inputs pass the initial structural checks, expect the paid Codex probe
to run even when another prerequisite fails: the command completes the evidence
report instead of stopping at its first error. Any nonzero prerequisite makes
commissioning exit nonzero. Repository visibility is never evidence of a gate;
a private repository without enforceable PR protection and required `check`
status is refused.

## Stage the first board card

Do not release a new product graph all at once. After the roadmap is clear and
commissioning is green, create only its root card:

```bash
PROJECT=$HOME/dev/my-project
BOARD=my-project
(cd "$PROJECT" && "$HOME/.forge/repo/hermes/board-bootstrap.sh" "$BOARD" --root-only)
```

`--root-only` checks the complete graph before its first Hermes command: ids and
dependencies must be well formed, exactly one root must exist, every chunk must
be reachable in topological order, and every named chunk file must exist. A bad
graph therefore creates neither a board nor a card. A good graph creates only
the root, using the same `$BOARD-$CHUNK_ID` idempotency key as full bootstrap,
so repeating the command is safe.

Let that root complete, then run the live metadata checkpoint described by the
roadmap. Stop on red or unjudged evidence. Only after it is green, extend the
same board with the rest of the graph:

```bash
(cd "$PROJECT" && "$HOME/.forge/repo/hermes/board-bootstrap.sh" "$BOARD")
```

Full mode reuses the existing root mapping and creates each remaining card with
all of its parent ids in the same Hermes transaction. Its final reconciliation
still compares every attached parent with every edge declared by the graph;
root-only's zero-parent created set does not weaken that assertion. If the root
is `claude-interactive`, full mode also accepts its documented `done` checkpoint
without re-blocking it or erasing the human assignee; any nonterminal state
other than the original sticky block fails closed.

## Landing a stack of PRs

Slices stack: #B is based on #A's branch, #C on #B's. Two things about that are
easy to get wrong, and both cost time on 2026-08-08.

**Retarget the child BEFORE you delete the parent's branch.** GitHub is
documented to auto-retarget a PR when its base branch is deleted. When the base
branch is deleted *separately* from the merge — `git push origin --delete`, or
`gh pr merge --delete-branch` after its local step already failed — the child PR
is **CLOSED** instead, and it cannot be reopened while its base ref is missing:

```
$ gh pr reopen 27
GraphQL: Could not open the pull request. (reopenPullRequest)
$ gh pr edit 27 --base main
GraphQL: Cannot change the base branch of a closed pull request.
```

The recovery is to push the merged commit back under the old branch name, reopen,
retarget, and delete again — four remote round trips to undo one. Do this instead:

```bash
gh pr merge <parent> --merge          # no --delete-branch
gh pr edit <child> --base main        # retarget FIRST
git push origin --delete <parent-branch>
```

**Merge forward, never rebase.** Bring `main` into the bottom of the stack and
each branch into the next. Every conflict this produces is append-at-the-same-
offset — a suite name, a `bash -n` entry, a CI suite list, a ledger section
appended against an empty base — and the resolution is always to keep **both**
sides. Resolving one by choosing a side silently drops a slice's work.

## Learning to judge — the skill that makes this work

The judge rubric is your curriculum. Six dimensions, but only three catch what CI
cannot:

1. **Spec fidelity** — does the code do what the contract promised, literally?
2. **Scenario integrity** — would the test fail if the feature broke? Look for
   mocked-away core paths and assertion-free steps. This is where "green" lies.
3. **Scope discipline** — is the diff inside the contract's `Touches` list?

Read the diff and the contract. Not the repo. If you can't judge without more
context, that's a signal the *chunk spec* was weak — which is itself the most
useful thing you'll learn in a review.

Every finding needs `file:line` evidence, and every bounce reason must be
executable by a fresh worker with no questions: *"scenario 3 asserts nothing"*,
not *"tests could be better"*.

## Cost intuition

- `total_cost_usd` in `claude -p` output is computed at list rates and is **not a
  bill** on a subscription. Use it to compare chunks, never as spend.
- Your real budget is the rolling session/weekly usage windows.
- The lane's Hermes model is cheap on purpose — Codex does the thinking.
- Every MCP server on the mini's `~/.claude` is paid for on *every* lane
  invocation. Keep it lean.
