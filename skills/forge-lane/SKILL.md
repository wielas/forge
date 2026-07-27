---
name: forge-lane
description: Protocol for the Hermes worker that implements ONE chunk card by driving codex exec inside a git worktree. Use when spawned as forge-codex-lane, or for /forge-lane.
---

# forge-lane — implement one chunk card by driving Codex

Hermes owns the task lifecycle. Codex is an input lane: it writes code, it does
not decide anything. You are the operator of another agent — set it up
correctly, verify the result yourself, leave evidence.

Your own model is deliberately cheap. The thinking happens inside Codex.

## 0. Your runtime

Set by the dispatcher (verified, Hermes 0.19.0 `kanban-worker-lanes` contract):

| var | carries |
|---|---|
| `HERMES_KANBAN_TASK` | your task id |
| `HERMES_KANBAN_WORKSPACE` | absolute path to *this* task's workspace |
| `HERMES_KANBAN_BRANCH` | branch name for `worktree` tasks (may be unset) |
| `HERMES_KANBAN_RUN_ID` | this run's id — pass as `expected_run_id` on terminators if you suspect a reclaim |

Use the `kanban_*` tools for every board operation. Never shell out to
`hermes kanban <verb>` — the tools write the DB directly and work on every
terminal backend.

## 1. Orient

`kanban_show()` — no args, it defaults to your task. Read the body (the chunk
contract), the parent handoffs, prior attempts if you are a retry, and the whole
comment thread. **An operator comment overrides the card body.**

## 2. Land in the worktree

The dispatcher created the worktree **before it spawned you** and checked it out
on `$HERMES_KANBAN_BRANCH`. Do not create it. Land in it and verify:

```bash
cd "$HERMES_KANBAN_WORKSPACE" || exit 1
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "workspace $HERMES_KANBAN_WORKSPACE is not a git checkout" >&2
  exit 1   # a substrate fault — block the card, do not try to repair it
}
```

If that check fails, the substrate is broken; report it via `kanban_block` and
stop. Creating the worktree yourself cannot work — the branch is already checked
out at that exact path, so any attempt to re-add it fails, and you then exit
without a terminator, which is reaped as `crashed`.

For a project-linked card the workspace is `<repo>/.worktrees/<task-id>` and the
main repo is two levels up. Worktrees are **preserved** on completion (scratch
workspaces are deleted — chunk cards must never use `scratch`).

## 3. Hand Codex the contract

Write the contract to a file rather than interpolating it into a shell string:

```bash
mkdir -p .forge && kanban_show body → .forge/contract.md
```

Then, from inside the worktree:

```bash
codex exec \
  -C "$HERMES_KANBAN_WORKSPACE" \
  -s workspace-write \
  --add-dir "$(git rev-parse --git-common-dir)" \
  --output-last-message .forge/codex-last.md \
  "$(cat .forge/contract.md)" < /dev/null
```

- **`< /dev/null` is mandatory.** `codex exec` reads stdin; without it, it
  consumes whatever the parent had queued.
- **`--add-dir "$(git rev-parse --git-common-dir)"`** — in a worktree the real
  `.git` lives in the main repo, so `workspace-write` alone cannot commit.
- **There is no `--full-auto`** in codex-cli 0.145; `-s workspace-write` is the
  sandbox flag. Never use `--dangerously-bypass-approvals-and-sandbox`.
- Model: the pin lives in `~/.codex/config.toml` (`gpt-5.6-sol`, reasoning
  `xhigh`). Override per card with `-m <model>`; record whichever you used in
  the completion metadata.
- Tell Codex explicitly: work only in this worktree, commit in small scoped
  commits, never `--no-verify`, never touch the board.

Run it in the background so a long chunk cannot hit `terminal.timeout` (1800s):

```python
r = terminal(command=..., workdir=WS, background=True, pty=True,
             notify_on_complete=True)
process(action="poll", session_id=r["session_id"])   # then "log", "wait", "kill"
```

`kanban_heartbeat(note=...)` every few minutes while it runs — the dispatcher
reclaims a task that has been silent for an hour (stale timeout 4h). Kill the
lane if Codex asks for credentials, edits outside the worktree, or starts
unrelated refactors; that is a `kanban_block`, not a retry.

## 4. Verify it yourself

```bash
make check
```

Codex's claim that it passed is advisory. **Not green is not done** — no
`--no-verify`, and never weaken a scenario to make it pass. Read
`git diff origin/main...HEAD` as a hostile reviewer before you believe the diff:
dead code, debug leftovers, scope beyond the contract.

## 5. PR

```bash
git push -u origin HEAD
gh pr create --title "<chunk id>: <title>" --body-file .forge/pr-body.md
```

Reuse the PR if one already exists (`gh pr view --json url`). Never push to
`main`.

## 6. Terminate — exactly once

Success path: create the tier-1 review card, then complete.

```python
child = kanban_create(title="prejudge: <chunk id>", assignee="forge-prejudge",
                      parents=[HERMES_KANBAN_TASK], body="<PR url> + what to check")
kanban_complete(summary="<one sentence landed, one sentence to watch>",
                metadata={...forge.chunk.v1..., "pr": ..., "check": {"green": true}},
                created_cards=[child_id])
```

`created_cards` ids must come back from a real `kanban_create` — the kernel
rejects invented ids and refuses the completion. Metadata keys: see
`rubrics/kanban-metadata-schema.md`; keep Hermes's own (`changed_files`,
`tests_run`, `decisions`) alongside the forge keys so the dashboard reads them
for free. No secrets in `summary` or `metadata` — run rows are durable forever.

Failure path: `kanban_block(reason="<the contradiction, plainly>")`, after a
`kanban_comment` carrying the evidence (`kanban_block` only stores the reason
string).

**Exiting without one of these is a protocol violation** — the kernel reaps the
run as `crashed`, the failure counter ticks, and the work is wasted.

## Hard rules

- **One chunk. Only.** A discovery outside the contract becomes a comment or a
  `kanban_create` child card for the right profile — never a bigger diff.
- **Never mark done what you did not verify.** Block it instead.
- **Never call `clarify`.** You are headless; it times out silently. Comment,
  then block.
- Small contract drift (a moved path) is yours to adapt to and note. A
  contradiction is a block.
