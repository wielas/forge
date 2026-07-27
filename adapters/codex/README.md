# Codex adapter (L3)

Codex needs almost nothing — that is the point of the portable core.

1. Skills: install.sh symlinks forge skills into ~/.codex/skills (and
   ~/.agents/skills, which Codex also scans). Codex supports symlinked skill
   folders and discovers on scan.
2. Project context: Codex reads AGENTS.md natively — the template ships it.
3. Unattended invocation: lanes/codex-worker.sh calls `codex exec --full-auto`.
   VERIFY the exact non-interactive/approval flags for your installed version
   and set FORGE_CODEX_MODEL_FLAG if you want a specific model per lane.
4. Auth: ChatGPT-plan login on the mini (headless-friendly per ADR-0004).
   Run `codex login` once in an interactive shell on the mini.

Optional: an openai.yaml sidecar per skill can add Codex-only UI metadata.
Do NOT put methodology in it (ADR-0002) — we skip sidecars until needed.
