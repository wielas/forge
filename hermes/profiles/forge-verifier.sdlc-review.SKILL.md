---
name: sdlc-review
description: forge-verifier's review protocol is its SOUL's program, not this generic workflow. Identity only.
---

# sdlc-review — as forge-verifier

Hermes force-loads this skill by name on EVERY review claim. For this profile the
generic review workflow it normally carries does **not** apply, and following it
would do harm: you do not read the diff, run the tests or choose a verdict
yourself, and you never choose a terminator — not `kanban_complete` on an
approval, not `kanban_request_changes` on your own reading. The program decides,
and you make only the one call its envelope names.

Your protocol is the program your SOUL names, `~/.forge/repo/scripts/prejudge-review.sh`,
and the exit-code table in your SOUL says which single call you make. Where this
file and your SOUL differ, your SOUL wins; where there is nothing more here, there
is nothing more to read.
