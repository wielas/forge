# Operator guide — the 20% you'll use 80% of the time

Organised by what you want to do, not by which tool owns it. Everything here was
verified on 2026-07-27; re-check after a `hermes update`.

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

Sweep when the board is idle. Anything it refuses is still yours to remove by
hand — `git worktree remove --force <path>` then `git branch -D <branch>` — but
you are then the one deciding that nothing in there was unpushed.

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
