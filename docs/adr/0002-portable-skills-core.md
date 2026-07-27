# ADR-0002: agentskills.io SKILL.md as the portable core; AGENTS.md as project SSOT

**Status:** accepted · 2026-07-09

## Context
Skills must run on Claude Code (interactive flagship), Codex CLI (unattended lane),
and Hermes (orchestrator/judge profiles). All three natively read the Agent Skills
open standard (SKILL.md with name/description frontmatter). Codex supports symlinked
skill folders; Hermes declares agentskills.io compatibility. For always-on project
context, AGENTS.md is the cross-tool standard: Codex reads AGENTS.md but not
CLAUDE.md; Claude Code reads both.

## Decision
- One canonical `skills/` directory in the forge repo; `install.sh` symlinks each
  skill into `~/.claude/skills`, `~/.agents/skills`, `~/.codex/skills`, and the
  Hermes skills dir.
- Frontmatter restricted to the portable core (`name`, `description`). Harness-
  specific extensions, if ever needed, go in sidecar files, never in SKILL.md.
- Per project: AGENTS.md is the single source of truth; CLAUDE.md is three lines
  pointing at it plus Claude-only notes.
- Description dialect: trigger-rich but tight (Hermes house style ≤60 chars;
  Codex shortens descriptions under context pressure).

## Consequences
- Write once, run in three harnesses; no duplicated methodology.
- We forgo Claude-only frontmatter conveniences (context forking, model pinning)
  in shared skills; those effects are achieved in L3/L4 instead.

## Options considered
Per-harness skill copies (drift guaranteed, rejected) · Claude plugin as the only
distribution (vendor-coupled, rejected) · generation step compiling one source into
per-harness formats (premature; symlinks suffice while formats are converged).
