# ADR-0004: Worker-lane auth — Codex headless, Claude interactive-only, judge metered

**Status:** accepted · 2026-07-09

## Context (timeline that forced this)
- 2026-02: Anthropic ToS restricts subscription OAuth to Claude Code + Claude.ai.
- 2026-04-04: subscription OAuth blocked for third-party harnesses at infra level.
- 2026-05-14: announced carve-out — Agent SDK, `claude -p` headless, GH Actions,
  ACP third-party apps move to a separate metered "Agent SDK credit" pool.
- 2026-06-15: that billing change paused same-day ("nothing changes for now"),
  revised plan pending. Direction of travel is unambiguous.
- Operator's own test: OAuth does not survive into spawned/headless child sessions;
  only the interactively authenticated shell. Codex (ChatGPT plan) runs headless
  via `codex exec` fine.

## Decision
- **Lane A (unattended implementation): Codex** via `codex exec` on the mini.
  Never build unattended economics on Claude subscription auth.
- **Lane B (interactive): Claude Code** — planning skills, desk implementation,
  supervised parallel sprints (agent teams), phone steering via Remote Control.
  All first-party interactive surfaces, explicitly unaffected by the billing split.
- **Lane C (judge): metered strong model** with a hard monthly budget — default a
  cheap-strong model via OpenRouter under a Hermes profile; optionally Claude via
  API/Agent-SDK credit AFTER re-checking current policy. Judge token footprint is
  small (diff + scenarios + rubric), so per-token pricing is rational here only.
- Lanes are pluggable: any harness that can read a card + SKILL.md is a valid
  worker. A policy change costs a config edit.

## Consequences
- No ToS gray zones; no surprise bills; graceful degradation if policy shifts.
- Claude remains the flagship where it is strongest (planning, judgment, review)
  without carrying the unattended token load.

## Rejected
- tmux-puppeting interactive Claude sessions for unattended work: against the
  spirit (and plausibly the letter) of the interactive carve-out; fragile.
- Claude API for bulk implementation: cost-inefficient vs Codex-plan headless.
