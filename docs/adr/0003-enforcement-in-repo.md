# ADR-0003: Deterministic enforcement lives in the repo, not the harness

**Status:** accepted · 2026-07-09

## Context
Field reports and our own experience agree: agents eventually ignore some prose
instructions, however well-written. Claude Code hooks enforce architecturally but
are Claude-only. The unattended lane is Codex; humans also commit.

## Decision
Anything that MUST hold is expressed as a machine gate at the lowest layer that
sees every actor:
- lefthook git hooks: format/lint on pre-commit; full test+BDD suite and a
  block-push-to-main guard on pre-push.
- GitHub CI as the final arbiter on every PR (immune to agent persuasion).
- Makefile as the single command vocabulary (`make check` is THE green proof).
Claude Code hooks (L3 adapter) are an optional extra tripwire for interactive
sessions, never the foundation. Skills may REFERENCE gates ("run make check and
paste the tail") but never substitute for them.

## Consequences
- Identical guarantees for Codex workers, Claude sessions, Hermes profiles, humans.
- Slightly slower local pushes (full suite on pre-push) — acceptable; chunks are
  small by design.
