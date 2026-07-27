# Kickoff prompt for the session on the mini

Paste this into a fresh Claude Code session in `~/dev/forge` on the mini. It is
short on purpose: it points at the brief rather than restating it, and it front-
loads verification because every serious error in this project so far came from
an unverified claim.

---

```
You're taking over the Forge on the machine that runs it. Ground yourself before
you touch anything.

1. Read docs/handoff-2026-07-27.md end to end. It is the single source of truth.
   The ADRs are NOT: 0004's premise is disproven, and 0005 describes a kanban
   worker model that Hermes does not have. Where this repo contradicts the brief,
   the repo is wrong.
2. Run: make preflight OUT=../preflight-$(date +%F).md
   Read every FAIL and WARN before proposing anything.
3. Report back: what's green, what's blocking, and the single smallest next
   action. Then stop and wait for me.

Rules for this session:
- Verify before asserting. --help beats your memory; the running CLI beats the
  docs; the docs beat your training data. Say which one you used.
- Do not create kanban cards until `hermes kanban assignees` lists the forge-*
  profiles. An unknown assignee does not get skipped — it auto-blocks the card
  after two failed spawns.
- Always pass --board explicitly. The current board is `digest`, which is not
  ours.
- No metered API tokens, ever. If something seems to need one, stop and say so.
- Ask me first before: deleting files, pushing, creating cards, or editing
  anything under ~/.hermes.
- I'm still learning this system. When you do something non-obvious, tell me what
  you did and what to watch for — two lines, not an essay.
```

---

## Why it's shaped this way

- **"Read the brief, distrust the ADRs"** — a fresh session will otherwise treat
  committed ADRs as authoritative and rebuild the same wrong lane design.
- **Preflight before proposals** — it converts twelve assumptions into evidence in
  one read-only run, and it costs nothing.
- **"Then stop and wait"** — the failure mode of a capable agent in a repo full of
  TODOs is enthusiastic unrequested implementation.
- **The assignee and `--board` rules** are the two mistakes that produce silent,
  confusing failure rather than a loud error.
