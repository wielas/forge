---
name: forge-lane
description: Protocol for the Hermes worker that implements ONE chunk card by driving codex exec inside a git worktree. Use when spawned as forge-codex-lane, or for /forge-lane.
---

# forge-lane — implement one chunk card by driving Codex

Hermes owns the task lifecycle. Codex is an input lane: it writes code, it does
not decide anything. You are the operator of another agent — set it up
correctly, verify the result yourself, leave evidence.

Your own model is deliberately cheap. The thinking happens inside Codex.

**The role boundary is hard, regardless of diff size.** You never use a write,
patch, or shell-edit operation to author the retained contract diff yourself.
Even a one-line fix goes through §4's `codex exec`; your tools are for setup,
evidence, verification, push, and board lifecycle. A temporary mutation used to
prove a test is allowed only if it is restored and the final clean-worktree
check passes. If Codex is unavailable, block the card. Do not replace the
missing lane with your own judgement.

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

### 1a. Gate code dependencies on integration, not card completion

A roadmap dependency releases when its parent **card** is done. Chunk cards
become done when their PR opens, so that release does not prove the parent code
is in the current branch. Before setup or Codex, inspect every parent handoff
whose run metadata contains `forge.chunk.v1.pr`:

```bash
gh pr view "$parent_pr" \
  --json state,mergedAt,baseRefName,headRefName,url
```

Every such PR must have a non-null `mergedAt`. If one is still open:

First test the narrow bounce-remediation exception. The open parent PR is the
repair target only when **all** hold:

1. this card's sole completed parent owns that handoff PR;
2. `workspace_kind="dir"` and `workspace_path` exactly match the parent;
3. the body names the same PR and says `Repair this existing PR branch only.`;
4. `created_by` is a completed judge card parented to that chunk whose canonical
   `forge.judge.v1` says `verdict="bounce"` and names the same PR; and
5. this card carries `skills=["forge-lane"]`.

Then skip that PR only, do not fetch/rebase, and repair the preserved branch.
Every other parent PR still requires a non-null `mergedAt`. A `dir` workspace
alone, a `fix:` title, PR prose, or an operator comment is not an exemption.

Otherwise:

1. comment with the PR, its state, and `reason_class=failing-prereq`;
2. call `kanban_block(kind="needs_input", reason="failing-prereq: parent PR … is not merged")`;
3. stop without changing the branch.

Do **not** use block kind `dependency`: the linked parent card is already done,
so Hermes immediately promotes the card and creates a block/dispatch loop. Do
not rebase onto the unmerged parent branch or silently create a stacked PR;
that is an architecture decision the chunk contract did not authorize.

On a later operator-unblocked retry, after all parent PRs are merged, require a
clean worktree, fetch, and rebase onto their common base before the baseline
check:

```bash
test -z "$(git status --porcelain --untracked-files=all)"
git fetch origin
git rebase "origin/$parent_base"
```

If parent PRs name different bases, or the rebase is not clean, block
`needs_input`; never guess a merge topology.

## 2. Land in the worktree

The dispatcher created the worktree **before it spawned you** and checked it out
on `$HERMES_KANBAN_BRANCH`. Do not create it — the branch is already checked out
at that exact path, so any re-add fails, and you then exit without a terminator,
which is reaped as `crashed`.

```bash
cd "$HERMES_KANBAN_WORKSPACE" || exit 1
```

For a project-linked card the workspace is `<repo>/.worktrees/<task-id>` and the
main repo is two levels up. Worktrees are **preserved** on completion (scratch
workspaces are deleted — chunk cards must never use `scratch`).

## 3. Make the worktree usable — Codex cannot

**You have a network. The `workspace-write` sandbox does not**, and a
dispatcher worktree is a fresh checkout with **no `.venv`**. Build it here or
Codex lands somewhere `make check` cannot run — and it will not stop, it will
improvise an environment and hand you a green from a command CI never runs
(`docs/hermes-field-notes.md` § Codex).

```bash
~/.forge/repo/scripts/lane-setup.sh \
  "$HERMES_KANBAN_WORKSPACE" "$HERMES_KANBAN_RUN_ID"
```

It verifies the checkout, gives this worktree its own hooks directory, fetches,
runs `make setup`, proves the baseline clean and green, creates the per-run
scratch directory, and captures protected Git state **before** the chunk starts.
Non-zero is always a `kanban_block`, never something to hand to Codex. `3` is a
bad worktree, `4` fetch/setup failed, `5` the baseline was red, and `6` the
audit could not capture. Setup-created worktree dirt is also `5`: it predates
Codex and must not later be reported as Codex escaping its boundary. Each
failure prints the `reason_class=` line to quote into the block.

Its last stdout line is `FORGE_LANE_RUNTIME=<path>` — export that value, do not
recompute it. It is the only scratch directory the lane writes to.

## 4. Hand Codex the contract

Write the contract to a file rather than interpolating it into a shell string,
and append the role boundary — **always**, whatever the card body says:

```bash
kanban_show body → "$FORGE_LANE_RUNTIME/contract.md"
cat >> "$FORGE_LANE_RUNTIME/contract.md" << 'EOF'

---
You implement this contract inside this worktree. That is your whole job.
Do NOT push, do NOT open a PR, do NOT run `hermes` or touch the kanban board,
do NOT read or follow `forge-lane`, `start-chunk` or `end-chunk` — those are
the calling agent's protocol, not yours. Commit in small scoped commits.
Never use --no-verify. `make check` must be green when you stop.
EOF
```

Load-bearing, not boilerplate. Reads are **not** sandboxed: the project's
`AGENTS.md` names the ceremony skills, Codex follows the pointer into
`skills/`, and without this it adopts *your* role — push, PR, board included.

Then, from inside the worktree:

```bash
UV_CACHE_DIR="$FORGE_LANE_RUNTIME/uv-cache" codex exec \
  -C "$HERMES_KANBAN_WORKSPACE" \
  -s workspace-write \
  --add-dir "$(git rev-parse --git-common-dir)" \
  --output-last-message "$FORGE_LANE_RUNTIME/codex-last.md" \
  "$(cat "$FORGE_LANE_RUNTIME/contract.md")" < /dev/null
```

- **`< /dev/null` is mandatory.** `codex exec` reads stdin; without it, it
  consumes whatever the parent had queued.
- **`--add-dir "$(git rev-parse --git-common-dir)"`** — in a worktree the real
  `.git` lives in the main repo, so `workspace-write` alone cannot commit. Be
  clear about what this buys: the sandbox banner reads `workspace-write
  [workdir, /tmp, $TMPDIR, <repo>/.git]`, so Codex can write **all** of the
  shared `.git` — `hooks/` (the whole L2 local tier), `refs/heads/main`,
  `config`, and every other worktree's admin dir. Narrower grants were not
  attempted because git needs objects, refs and the worktree admin dir
  together; a wrong guess breaks committing, which cost a rung to get working.
  Treat it as bounded instead: §5 checks the blast radius afterwards.
- **There is no `--full-auto`** in codex-cli 0.145; `-s workspace-write` is the
  sandbox flag. Never use `--dangerously-bypass-approvals-and-sandbox`.
- **`UV_CACHE_DIR` in the per-run temp directory** — `uv run` writes its cache,
  and `~/.cache/uv` is outside the sandbox. `$TMPDIR` is writable by the sandbox;
  keeping all lane scratch there means worktree cleanliness needs no blind
  `.forge/` exclusion.
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

## 5. Verify it yourself

§3 captured an immutable baseline under `~/.forge/lane-audits/<run-id>`, outside
every Codex-writable root. Do not recapture or replay the final audit: each run
id permits one capture and one check.

```bash
make check
```

Run it **plain** — no `UV_CACHE_DIR`, no `UV_OFFLINE`. If §3 did its job this
is the same command CI runs, which is the only reason its green means anything.

That equivalence is not free, and it has already failed once: on 2026-07-28 a
warm `.ruff_cache` in the worktree answered "All checks passed!" for bytes that
a cold clone and CI both rejected. The template's `lint` target now runs ruff
with `--no-cache` so the verdict cannot come from a cache. If you are working a
project whose `Makefile` predates that, `rm -rf .ruff_cache` before you believe
this step — and a green you cannot reproduce in a cold checkout is not a green.

Codex's claim that it passed is advisory. **Not green is not done** — no
`--no-verify`, and never weaken a scenario to make it pass. Read
`git diff origin/main...HEAD` as a hostile reviewer before you believe the diff:
dead code, debug leftovers, scope beyond the contract.

After `make check`, the hostile review, and restoration of every temporary
verification mutation, run the final fail-closed audit:

```bash
~/.forge/repo/scripts/lane-blast-radius.sh check \
  "$HERMES_KANBAN_WORKSPACE" "$HERMES_KANBAN_RUN_ID"
```

It holds a named set immutable: both hooks directories, local and worktree
config, `refs/heads/main`, `objects/info/alternates`, object reachability, and a
clean worktree. Sibling branches, `refs/remotes/*` and other worktrees are
**deliberately** out of scope — from in here they are indistinguishable from a
sibling lane doing its job. Exit `3` includes an unreadable audit — **always
block, never push or retry**; the offending path is named in the reason line and
the full diff is in the run's audit directory. Exit `2` means setup never
captured, or this run's one audit was already spent — recover with a new card.

## 6. PR

```bash
git push -u origin HEAD
gh pr create --title "<chunk id>: <title>" \
  --body-file "$FORGE_LANE_RUNTIME/pr-body.md"
```

Reuse the PR if one already exists (`gh pr view --json url`) — and check,
because a Codex run that ignored §4's boundary may have opened one already.
Never push to `main`.

## 7. Terminate — exactly once

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
