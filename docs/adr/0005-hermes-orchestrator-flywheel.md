# ADR-0005: Hermes as orchestrator and flywheel host

**Status:** accepted · 2026-07-09

## Context
Hermes (NousResearch) on the always-on M4 mini provides: SQLite-backed kanban with
dispatcher, dependency auto-promotion, decomposer/specify, circuit breaker + crash
reclaim, artifact/metadata handoffs; agentskills.io-compatible skills with /learn;
a consent-aware learning loop (autonomous skill creation, skill self-improvement,
write_approval staging under ~/.hermes/pending/skills/); MEMORY.md + FTS5 cross-
session recall; cron with delivery to 20+ gateway platforms (incl. Telegram and
Home Assistant); 6 terminal backends (local/Docker/SSH/Daytona/Singularity/Modal).
Its docs anticipate external worker lanes: the dispatcher skips cards whose
assignee is not a Hermes profile, so CLI tools pull them instead.

## Decision
- One kanban board per project; roadmap skill ends by emitting dependency-linked
  chunk cards. Judge cards auto-follow completed chunks.
- Orchestrator profile restricted to board/gateway/memory toolsets (cannot
  implement even if it tries). Codex lane = external worker (lanes/codex-worker.sh)
  polling for `assignee: codex-worker` cards. Risky cards → Docker backend.
- `kanban_complete` metadata is the structured exhaust contract
  (rubrics/kanban-metadata-schema.md) consumed by judge, digest, and /retro.
- Flywheel: learning loop ON; `write_approval: true` for skill writes (propose,
  human approves); nightly self-evolution cron + independent guardrail-verification
  cron (auditor must not be the thing improving itself); weekly /retro proposes
  diffs to THIS repo as PRs.
- Human gates via Telegram; morning digest cron summarizes overnight board state.

## Consequences
- L4+L5 are mostly configuration, not construction.
- Hermes config schema volatility is a maintenance surface: all Hermes-specific
  config is quarantined in hermes/ and lanes/ with a VERIFY checklist.

## Deferred (dream-big shelf)
Atropos RL on trajectories; ShareGPT export → fine-tuning on our own history;
Hermes agent-teams-style fan-out for research tasks.
