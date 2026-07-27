# Open questions

Design questions we have deliberately not answered yet, with what would settle
each. Anything here that gets decided becomes an ADR and leaves this file;
anything that gets measured becomes a line in `docs/hermes-field-notes.md`.

**Seven ceremonies or five?** `start-chunk` and `end-chunk` always run
back-to-back inside the same worker, so the split may be ceremony without payoff.
*Settled by:* the first few real chunk runs — if no worker ever stops between
them, merge the skills.

**`templates/python-service` or a `forge graft` skill?** The template stamps a new
project with the gate layer; a graft skill would add the same layer to an existing
repo. The operator's projects are not all Python, which pulls toward graft.
*Settled by:* the second tenant. If it is not a fresh Python service, the template
is the wrong shape.

**Does `kanban specify` replace part of `/scope` + `/roadmap`?** Hermes ships a
specifier that fleshes out a triaged card into a spec. If it is good, some of our
planning ceremony is redundant.
*Settled by:* running `kanban create --triage` on one real feature and comparing
the output against what `/scope` produces.

**Metadata vocabulary.** Adopt Hermes's recommended keys (`changed_files`,
`verification`, `dependencies`, `blocked_reason`, `retry_notes`, `residual_risk`)
and keep the forge keys as extras, so the dashboard reads our cards for free.
*Settled by:* looking at the dashboard after the first completed chunk — it will
be obvious which keys it renders and which it ignores.

**Does the lane's model hold the protocol?** The driver profile is deliberately
cheap on the theory that Codex does the thinking, but the driver still has to
heartbeat, verify honestly, and terminate correctly. Hermes itself flags this
family as needing tool-use enforcement.
*Settled by:* the first run. A `crashed` reap in `kanban runs` means the model is
the problem, not the skill text; the fix is per-card (`--model`, or `--goal`).

**Should the lane keep `skill_manage`?** The `skills` toolset is needed to load
`forge-lane`, but it also grants `skill_manage` — write access. The two
assumptions this question rested on were both **measured false on 2026-07-27**
(see `hermes-field-notes.md`): external-dir skills are *not* guarded against a
lane, and a staged write does *not* hang the worker. What is true is that
`skills.write_approval: true` converts the write into a staged, non-applied diff,
which is a real gate — so the remaining question is narrower than it was:

Is staging sufficient, or should a lane not hold the tool at all? Staging means
an unattended worker can still *propose* an edit to any forge skill and continue
without noticing it did not land; dropping the tool means it cannot try.
*Settled by:* a decision, not a measurement — either `hermes tools disable
skill_manage` per lane profile, or an ADR stating plainly what a lane profile may
write and why the SOUL is not the mechanism. Both are one line of work; the
measurement no longer blocks it.
