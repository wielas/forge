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

Set by the dispatcher; `lane.sh` reads every one of them itself, so you pass
nothing. It refuses to run (exit 2) if one is missing.

| var | carries |
|---|---|
| `HERMES_KANBAN_TASK` | your task id |
| `HERMES_KANBAN_WORKSPACE` | absolute path to *this* task's worktree — the dispatcher created it; never re-add it |
| `HERMES_KANBAN_BRANCH` | the task branch the worktree is on |
| `HERMES_KANBAN_RUN_ID` | this run's id |
| `HERMES_KANBAN_BOARD` | this board's slug — run ids are board-LOCAL, so the per-run paths carry it |

## 1. Run the protocol

```python
r = terminal(command="~/.forge/repo/scripts/lane.sh", workdir=WS,
             background=True, pty=True, notify_on_complete=True)
process(action="wait", session_id=r["session_id"])   # then read the exit code
```

Background, always: a chunk — and a quota park inside it — outlasts
`terminal.timeout` (1800s). The program heartbeats the card itself and posts
every `PARK-COMMENT` its Codex runner prints, so you do not. `~/.forge/repo` is
the only path that resolves from a project worktree; never a relative one.

What it runs, in order, each step a script covered by `make verify`: the card
and its operator comments (a comment overrides the body); a guard that every
parent PR is merged; a fast-forward of a fresh branch onto `origin/main`;
`lane-setup.sh`; the contract with the role boundary appended; `codex-run.sh`,
which parks through a provider usage limit and resumes the same Codex session;
plain `make check`; the `lane-blast-radius.sh` audit; push and PR (an open PR is
reused); the `forge.chunk.v1` envelope, validated against
`~/.forge/rubrics/kanban-metadata-schema.md`.

- Model: the pin lives in `scripts/model-pins.sh` (`gpt-5.6-luna`, reasoning `xhigh`), and the
  runner **passes** it as `-m`/`-c model_reasoning_effort` on both argv branches, so
  `~/.codex/config.toml` never governs a run. Override with `FORGE_CODEX_MODEL`/`FORGE_CODEX_EFFORT`; record what ran in the completion metadata.

Its stdout is ONE small JSON envelope, `forge.lane.v1`: `action`, `summary`,
`reason`, `metadata`, `created_cards`. Read only that. Every log — the Codex
transcript, `make check`, the audit — stays in files; never read them into
your context, and never render the diff.

## 2. Terminate — exactly once

| exit | you call | with |
|---|---|---|
| 0 | `kanban_complete` | `summary`, `metadata` **from the envelope**, `created_cards` from the envelope — unmodified |
| 3 | `kanban_block` | `reason` from the envelope, verbatim — a canonical class from `~/.forge/rubrics/run-metadata-contract.json` |
| 2 | `kanban_block` | `reason="other: lane-usage — <the stderr>"` — the runtime was incomplete |

An exit 3 is the program refusing to hand off work that failed a step — a red check,
an audit breach, a failed push. Never retry it and never work around it.

**Exiting without one of these is a protocol violation** — the kernel reaps
the run as `crashed`, the failure counter ticks, and the work is wasted. The
set is closed: `kanban_request_review` and `kanban_request_changes` are
**forbidden** here — review is carried by the tier-1 card the program created,
and a card parked in `review` is not `done`, so ADR-0008 never promotes its
dependents. `kanban_create` is not yours either: the program creates the one
card a chunk needs.

## Hard rules

- **One chunk. Only.** A discovery outside the contract is a `kanban_comment`,
  never a bigger diff and never a card.
- **Never complete what the program did not.** Exit 0 is the only road to
  `kanban_complete`.
- **Never call `clarify`.** You are headless; it times out silently.
- **Do not reimplement the protocol.** If a step looks wrong, that is a change
  to `scripts/lane.sh` and to `make verify`, not prose improvised mid-run.
