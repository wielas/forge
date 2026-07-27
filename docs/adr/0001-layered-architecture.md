# ADR-0001: Five-layer architecture with strict methodology/harness separation

**Status:** accepted · 2026-07-09

## Context
The previous workflow (scope → architecture+ADRs → roadmap → BDD chunk loop) worked
but lived in the operator's head and per-project prompt ceremony. Every new project
paid a manual setup tax; rules were re-stated; nothing compounded. The harness
landscape is volatile (Claude Code, Codex, Hermes; policies and pricing shifting
quarterly).

## Decision
Split the system into five layers with one-way dependencies (upper layers may know
about lower ones, never the reverse):
L1 methodology (portable skills + rubrics) · L2 enforcement (repo template: git
hooks + CI) · L3 harness adapters (thin sugar only) · L4 orchestration (Hermes
board + worker lanes) · L5 flywheel (learning loop editing L1 via staged,
human-approved diffs).

## Consequences
- Switching or losing any harness costs a config edit, not a rebuild.
- Methodology is versioned, diffable, and improvable like code.
- Discipline required: any methodology text found in L3/L4 is a bug; move it to L1.

## Options considered
1. **Single Claude Code plugin holding everything** — best UX in one harness;
   rejected: couples the soul of the system to one vendor's packaging.
2. **Fork spec-kit** — mature scaffolding, 28+ agent integrations; rejected as the
   core (its spec-first flow drifts; our BDD gating is stronger), but its
   /clarify + /analyze phase design is borrowed in the scope/roadmap skills.
3. **Custom orchestrator from scratch on the mini** — maximal control; rejected:
   re-implements Hermes kanban (dispatcher, circuit breaker, crash reclaim) badly.
4. **Five layers (chosen)** — more moving parts, but each independently useful and
   independently replaceable.
