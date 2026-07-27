# Kickoff prompt for a session on the mini

Paste this into a fresh Claude Code session in `~/dev/forge` on the mini. It is
short on purpose: it points at durable docs rather than restating them, and it
front-loads verification because every serious error in this project so far came
from an unverified claim.

---

```
You're taking over the Forge on the machine that runs it. Ground yourself before
you touch anything.

1. Read, in this order:
   - README.md — what this is and what's next
   - docs/hermes-field-notes.md — how the substrate really behaves, and the
     traps that have already cost us a day
   - docs/adr/ — the decisions and why. 0004, 0006 and 0007 are the recent ones;
     0005's lane shape is superseded by 0006 and says so.
2. Run: make preflight OUT=../preflight-$(date +%F).md
   That establishes the live state — versions, auth, config, board, profiles.
   No document in this repo records that state; preflight is the source.
   Read every FAIL and WARN before proposing anything.
3. Report back: what's green, what's blocking, and the single smallest next
   action. Then stop and wait for me.

Rules for this session:
- Verify before asserting. --help beats your memory; the running CLI beats the
  docs; the docs beat your training data. Say which one you used.
- If you measure something that contradicts a doc in here, the measurement wins
  — fix the doc in the same change, and record the command that showed it.
- Always pass --board explicitly, BEFORE the subcommand:
  `hermes kanban --board <slug> create …`.
- No metered API tokens, ever. If something seems to need one, stop and say so.
- Ask me first before: deleting files, pushing, creating cards, or editing
  anything under ~/.hermes.
- I'm still learning this system. When you do something non-obvious, tell me what
  you did and what to watch for — two lines, not an essay.
```

---

## Why it's shaped this way

- **Durable docs, not a handoff.** An earlier version of this pointed at a dated
  handoff file that had become the project's decision store. It went stale inside
  a single session — still claiming `gh` was unauthenticated hours after we fixed
  it — because a document that records live state is a copy that starts rotting
  the moment it is written. Decisions live in ADRs, substrate behaviour in field
  notes, live state in `make preflight`, and nowhere else.
- **Preflight before proposals** — it converts a dozen assumptions into evidence
  in one read-only run, and it costs nothing.
- **"Then stop and wait"** — the failure mode of a capable agent in a repo full of
  TODOs is enthusiastic unrequested implementation.
- **The `--board` rule** is the mistake that produces silent, confusing failure
  rather than a loud error.
