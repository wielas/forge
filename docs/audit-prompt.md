# Audit prompt — fresh critic session

For a **fresh** Claude Code session in `~/dev/forge`, separate from any session
doing the work. Its job is to learn the three harnesses properly, then attack this
system's design *and its prose*. Run it when you want a second opinion, and re-run
it after any big change — it's cheap relative to a bad night run.

Keep it in a session with no prior context. The value is the absence of anchoring.

---

```
You are auditing a personal AI-development system called the Forge, in this repo.
You did not design it. Your job is to learn the tools it sits on, then tell me
where it is wrong — including where its documentation is badly written, because
prose is the actual interface between this system and the models that run it.

Do not implement anything. Do not create kanban cards, push, or edit files under
~/.hermes. Ask before writing any file. Your deliverable is a document and a
conversation.

## Phase 1 — learn the tools from primary sources (not from memory)

Your training data is stale about all three of these. Read current material:

- Hermes: https://hermes-agent.nousresearch.com/docs/llms.txt is a curated index;
  fetch the pages that matter (kanban, goals, profiles, skills, curator, cron,
  delegation, hooks, toolsets-reference, security).
- Claude Code: https://code.claude.com/docs/llms.txt — same approach (headless,
  agent-sdk, sub-agents, agent-teams, hooks, skills, plugins, permissions, costs).
- Codex: https://developers.openai.com/codex — non-interactive mode, subagents,
  hooks, sandbox/approval modes, output schemas.

Then check the live CLIs, which outrank the docs:
  hermes kanban --help · hermes kanban create --help · hermes profile --help
  codex exec --help · claude --help
  make preflight            # read-only; burns down a dozen assumptions at once

Report anything where the live CLI and the docs disagree. That gap has bitten this
project repeatedly.

## Phase 2 — read the system

In this order: docs/handoff-2026-07-27.md (the brief — the only doc that is
current) → README.md → docs/adr/0001..0005 → skills/*/SKILL.md → rubrics/* →
hermes/profiles/*.SOUL.md → hermes/profiles-bootstrap.sh →
hermes/config-examples.yaml → templates/python-service/ → scripts/preflight.sh.

Also read `git log --stat` from the first commit. The corrections in that history
are evidence about how this project fails — treat the pattern of mistakes as data.

## Phase 3 — the critique

Cover all four:

1. **Design.** Does the architecture serve the operator's actual pain ranking
   (1: repeated per-project setup, 2: can't trust unreviewed output, 3: serial
   execution is slow, 4: knowledge doesn't carry over)? Judge against that, not
   against abstract best practice.

2. **Feature fit.** Now that you know what the three harnesses actually do in
   2026: what is this system building by hand that a harness already does better?
   Name specifics. Conversely, what capability is sitting unused that would remove
   real work?

3. **Prose.** This matters as much as the design, and nobody has audited it:
   - SKILL.md descriptions: trigger-rich enough to fire at the right moment, tight
     enough to survive a truncated skills budget?
   - SKILL.md bodies: is any instruction untestable, ambiguous, or so long the
     model will skim it? Anything that MUST hold belongs in a gate (lefthook/CI),
     not in prose — flag every rule that is prose pretending to be enforcement.
   - SOUL.md files: do they constrain behaviour, or just describe vibes?
   - Chunk-contract template in skills/roadmap: could a fresh mid-weight model
     execute one with zero questions? Try writing one and see where it fails.
   - The brief and README: what would a cold session misread?

4. **Process.** How the operator and the agents actually work together: handoffs,
   fresh-context discipline, where humans gate, what happens on failure. Consider
   at least: what happens when the judge bounces the same chunk twice; how secrets
   reach a dispatched worker; where you look when a night run goes wrong; cost
   telemetry; contention when several projects share one mini; and the operator
   being a single point of failure.

## Output

Write docs/audit-<date>.md, max ~150 lines:

- **Verdict**, 5 lines: is this sound to run this week, and what must change first?
- **Findings**, ranked by likelihood × blast radius. Each one: evidence
  (file:line or a doc URL), the consequence if ignored, and a concrete fix. Ten
  maximum — if you have more, you haven't ranked them.
- **Deletion candidates.** First-class. This system values leanness; name anything
  that is ceremony without payoff, prose that no model will act on, or a file that
  duplicates a harness feature.
- **Provenance table**: label every load-bearing claim `verified` (I ran it),
  `checked` (current docs), or `assumed`.

Then summarise in chat in under 200 words and ask me which findings to act on.

## Rules

- Verify before asserting. Say which source each claim came from. "I ran it" beats
  "the docs say" beats "I recall".
- Don't manufacture criticism. An honest "this is right, and here's the mechanism
  that makes it work" is worth more than theatrical nitpicking. But the base rate
  matters: this system was designed largely in conversation and has never
  completed a single end-to-end run. Assume real flaws exist and go find them.
- Nothing here is settled, including the three decisions in the brief (Hermes-
  native lanes; Codex implements / Claude judges in two tiers; no metered tokens
  for implementation or review). If you think one is wrong, say so and say what
  would change your mind.

## Known dead ends — don't spend budget rediscovering these

- ADR-0004's premise is disproven; ADR-0005 describes a kanban worker model that
  does not exist. Both are known-stale. Critique the *replacements* instead.
- Metered API billing is out of scope: no proposal may require ANTHROPIC_API_KEY
  or OPENAI_API_KEY. Subscription and bounded OpenRouter aux calls only.
- The Docker terminal backend is not a free win: `claude` and `codex` would have
  to exist inside the container. Price that in if you propose it.
- `claude -p --bare` cannot read CLAUDE_CODE_OAUTH_TOKEN, so it is unavailable to
  us despite being the obvious context-cost fix.
```
