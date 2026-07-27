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
`forge-lane`, but it also grants `skill_manage` — write access. With
`skills.write_approval: true` a write attempt needs an approval no unattended
worker can obtain, so it would hang until reclaimed. The forge skills themselves
are safe (external-dir skills are guarded), but the tool has no business being in
a lane's hands.
*Settled by:* `hermes tools disable` per tool, if the first night run shows any
worker reaching for it.
