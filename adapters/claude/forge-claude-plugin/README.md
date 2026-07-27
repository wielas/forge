# forge Claude Code plugin (L3 adapter)

Interactive-lane sugar only. Install for local dev:

    claude --plugin-dir /path/to/forge/adapters/claude/forge-claude-plugin

Contents: hooks/hooks.json (tripwires: block --no-verify & direct main pushes;
end-of-turn nudge on dirty chunk branches — VERIFY schema against current docs),
agents/judge-assist.md (pre-PR advisory judge).

Skills are NOT bundled here — install.sh symlinks the shared skills into
~/.claude/skills so all harnesses read the same files (ADR-0002).
