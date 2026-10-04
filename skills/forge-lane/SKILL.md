---
name: forge-lane
description: Protocol for the Hermes worker that implements ONE chunk card by driving codex exec inside a git worktree. Use when spawned as forge-codex-lane, or for /forge-lane.
---

# forge-lane — run the lane program, terminate on its exit code

Hermes owns the task lifecycle. Codex is an input lane: it writes code, it does
not decide anything. The whole protocol — read the card, build the worktree,
hand Codex the contract, verify, push, open the PR, fill the metadata — is one
program, `scripts/lane.sh` (ADR-0010's pattern, epic FL2). You run it and you
terminate on what it says. Your model is deliberately the cheapest in the
pipeline, and nothing here needs more.

**The role boundary is hard, regardless of diff size.** You never use a write,
patch, or shell-edit operation to author the retained contract diff yourself.
Even a one-line fix goes through Codex, which only the program drives. If Codex
is unavailable the program blocks; do not replace the missing lane with your
own judgement, and never run a step of the program by hand.

## 0. Your runtime

Your terminal is **fenced** (Hermes, *Descendant process scope*): every `hermes
kanban` mutation made from it is refused — `comment`, `heartbeat`, `block`,
`request-review`, even from a script that removes the task id — and
`HERMES_KANBAN_TASK`, `_RUN_ID` and `_CLAIM_LOCK` are not in its environment.
That is the kernel's rule, not a fault: never export them, never unset the fence.
You terminate through your **tools**, and the program tells you which.
What the terminal does keep, and `lane.sh` reads itself:

| var | carries |
|---|---|
| `HERMES_KANBAN_WORKSPACE` | absolute path to *this* task's worktree — the dispatcher created it; never re-add it |
| `HERMES_KANBAN_BRANCH` | the task branch the worktree is on |
| `HERMES_KANBAN_BOARD` | this board's slug |
| `HERMES_PROFILE` | your profile — the card must be assigned to it |

The one thing you pass is **your task's id**: `kanban_show().task.id`, the id in
your prompt. The program reads the run id off the card, and refuses (exit 2) a
card that is not yours, not `running`, or not in this workspace.

## 1. Run the protocol

Four tool calls, in this order. Do not use `execute_code` (it is blocked in an
unattended session) and do not pass `notify_on_complete`.

1. **Launch it in the background.** Call `terminal` with `background: true`,
   `pty: true`, `workdir` = your workspace and this `command`, with your own task
   id (`kanban_show().task.id`) in place of `<task id>`:

   ```bash
   ~/.forge/repo/scripts/lane.sh --task <task id>
   ```

   A chunk — and a quota park inside it — runs for hours and outlasts
   `terminal.timeout` (1800s). The result is "Background process started" with a
   `session_id`; the `exit_code: 0` on it is the launcher's, **not** the program's.
2. **Wait until it exits.** Call `process_manage` with `action: "wait"`, that
   `session_id` and `timeout: 400`. `process_manage` is a deferred tool: if it is
   not among your tools, find it with `tool_search`, then call it through
   `tool_call`. A wait is cut at about 7 minutes by the runtime and returns
   `status: "timeout"`: wait again, as often as it takes. Your own tool calls keep
   the card's claim alive (the runtime heartbeats a worker while any tool runs); the
   program does not and cannot.
3. **The program's exit code** is `exit_code` on the wait result whose `status` is
   `"exited"`.
4. **Read the whole envelope.** Call `process_manage` with `action: "log"` and the
   same `session_id`. Its `output`'s **last line** is the envelope, one line of JSON.
   Never read it from the wait: a wait shows only the last 2000 characters, and the
   call sits near the start of the envelope.

`~/.forge/repo` is the only path that resolves from a project worktree; never a
relative one.

What it runs, in order, each step a script covered by `make verify`: the card
and its operator comments (a comment overrides the body); a guard that every
parent PR is merged; a fast-forward of a fresh branch onto `origin/main`;
`lane-setup.sh`; the contract with the role boundary appended; `codex-run.sh`,
which parks through a provider usage limit and resumes the same Codex session;
plain `make check`; the `lane-blast-radius.sh` audit; push and PR (an open PR is
reused); the `forge.chunk.v1` envelope, validated against
`~/.forge/rubrics/kanban-metadata-schema.md`; and then **names the hand-off**: a
`kanban_request_review` call that moves this card to `review`, assigned to the
reviewer, on the same card (ADR-0019 D19.1). It does not make the call — the
fence forbids it — and neither does anything else but you. A card that comes back
from review re-enters the same worktree, branch and PR, and resumes the Codex
session that wrote it with the reviewer's reasons.

- Model: the pin lives in `scripts/model-pins.sh` (`gpt-5.6-luna`, reasoning `xhigh`), and the
  runner **passes** it as `-m`/`-c model_reasoning_effort` on both argv branches, so
  `~/.codex/config.toml` never governs a run. Override with `FORGE_CODEX_MODEL`/`FORGE_CODEX_EFFORT`; record what ran in the completion metadata.

Its stdout is ONE small JSON envelope on ONE line, `forge.lane.v2`: `action`, `summary`,
`reason`, `rc`, `terminate`, `on_error`, `created_cards`. Read only that. Every log —
the Codex transcript, `make check`, the audit — stays in files; never read them
into your context, and never render the diff.

## 2. Terminate — one call, named by the program

| exit | you do |
|---|---|
| 4 | the hand-off. Call `terminate.tool` with `terminate.args`, **verbatim** — every field, `task_id`, `reviewer` and `metadata` included. If it returns an error, call `on_error.tool` with `on_error.args`, then stop |
| 3 | nothing was handed off. `terminate` is a `kanban_block` with a canonical `<class>: <reason>` (`~/.forge/rubrics/run-metadata-contract.json`): call it verbatim |
| 2 | `kanban_block` with `reason="other: lane-usage — <the stderr>"` — the argument or the runtime was wrong |
| 0 | **never from a real run.** Only `--help` exits 0; if a run did, you ran the wrong thing: `kanban_block` and say so |

An exit 3 is the program refusing to hand off work that failed a step — a red
check, an audit breach, a failed push. Never retry it and never work around it.

**Exiting on any code without making the call is a protocol violation** — the
card is still `running`, the kernel reaps the run as `crashed`, and the work is
wasted. Make exactly the call the envelope names, with exactly its arguments:
do not retype, trim or "fix" them (a dropped `reviewer` sends the card back to
this lane to review itself). The set is closed: `kanban_request_review` is yours
**only** as the call the envelope names; `kanban_request_changes`,
`kanban_complete` and `kanban_create` are **forbidden** here — a card in `review`
is not `done`, which is exactly what holds its dependents until the PR merges.

## Hard rules

- **One chunk. Only.** A discovery outside the contract is a `kanban_comment`,
  never a bigger diff and never a card.
- **Never complete a chunk card.** It reaches `done` when its PR merges, never
  from the lane.
- **Never defeat the fence.** No `export HERMES_KANBAN_TASK=...`, no unsetting
  `HERMES_DELEGATED_CHILD_CONTEXT`, no writing the board's database. The fence is
  the kernel's boundary, and your tools are the way through it.
- **Never call `clarify`.** You are headless; it times out silently.
- **Do not reimplement the protocol.** If a step looks wrong, that is a change
  to `scripts/lane.sh` and to `make verify`, not prose improvised mid-run.
