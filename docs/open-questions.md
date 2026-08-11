# Open questions

Design questions we have deliberately not answered yet, with what would settle
each. Anything here that gets decided becomes an ADR and leaves this file;
anything that gets measured becomes a line in `docs/hermes-field-notes.md`.

**Does the Opus scorer earn its latency? (ADR-0009 D9.5 — PARKED, WAITING ON
DATA.)** This is the one open question with a pinned control arm attached, and
it is the only thing blocking the last tier-1 changes. It is parked
deliberately: the instrument is built and running, and what it now needs is
*reviews*, not work. Everything needed to resume is below — read it before
touching `scripts/prejudge-review.sh` lines 306–331.

### Where this stands

- **F29 is closed.** Routing reads `.derived_verdict`; the model's asserted
  `verdict` is recorded and no longer obeyed (PR #17). No pinned bytes were
  touched — the routing line sits below `# --- end pinned region ---`, which the
  plan had wrongly assumed was inside it for two revisions.
- **The scorer still asserts `verdict` on purpose.** With routing derived it
  decides nothing, so it is free to record — which makes every review from here
  a **post-gate sample**. That is the instrument. Do not add `verdict` to
  `STAMPED` before this question is answered: it ends the measurement
  permanently and cannot be undone for reviews already run.
- **The 34-verdict replay cannot answer this.** All 34 predate
  `scripts/prejudge.sh`, so they measure the scorer with nothing in front of it.
  D9.5 asks what it adds *given* a gate.

### The two measurements, and why the obvious one is the wrong one

**Divergence does not answer D9.5.** It compares the scorer's *asserted verdict*
against its *own scores* — so it measures whether the verdict field is
redundant, which is F29's question and is already settled. It says nothing about
whether the scorer adds anything over the gate. Anyone who resumes here by
collecting divergence numbers and declaring D9.5 answered has measured the wrong
thing.

Both queries below read a live board, so **snapshot first — never open one
`mode=ro`** (F67: hermes boards are WAL, and a read-only open fails when the
board is *idle*):

```sh
b=~/.hermes/kanban/boards/<board>/kanban.db
t=$(mktemp -d); cp "$b" "$t/k.db"; [ -f "$b-wal" ] && cp "$b-wal" "$t/k.db-wal"
```

**(A) How many post-gate samples exist yet?** Rows carrying a `derived_verdict`
key are exactly the reviews run since shadow stamping shipped, and all of them
are post-gate.

```sh
sqlite3 -box "$t/k.db" "
SELECT count(*) AS post_promotion,
       sum(json_extract(metadata,'\$.verdict_divergence') = 1) AS diverged,
       sum(json_type(metadata,'\$.derived_verdict') = 'null')  AS underivable
  FROM task_runs
 WHERE json_extract(metadata,'\$.schema') = 'forge.judge.v1'
   AND json_type(metadata,'\$.derived_verdict') IS NOT NULL;"
```

**(B) The actual D9.5 question.** A gate block short-circuits and stores
`forge.gate.v1` without spawning a model (`prejudge/review-routes-by-gate-result`
asserts this), **so every stored `forge.judge.v1` envelope is by construction a
review the gate already cleared.** What the scorer found on those rows *is* its
marginal contribution over the gate:

```sh
sqlite3 -box "$t/k.db" "
SELECT count(*) AS gate_cleared,
       sum(json_extract(metadata,'\$.derived_verdict')='bounce') AS scorer_bounced,
       sum((SELECT count(*) FROM json_each(task_runs.metadata,'\$.findings'))>0) AS any_finding,
       sum((SELECT min(value) FROM json_each(task_runs.metadata,'\$.scores'))<3) AS marked_down
  FROM task_runs
 WHERE json_extract(metadata,'\$.schema')='forge.judge.v1'
   AND json_type(metadata,'\$.derived_verdict') IS NOT NULL;"
```

Both queries were run against a synthetic board before being written here; they
execute as given.

### The decision rule — pre-committed, on purpose

**Write the threshold down before looking at the data, and honour it.** The
previous plan pre-committed to "zero divergence in 17" and the measurement
returned 1 in 34; that bar was honoured rather than moved, which is the only
reason the number means anything. Do the same here.

- **Minimum sample: 10 gate-cleared reviews.** Below that, stop and keep
  collecting — a rate estimated from single digits cannot carry an ADR that
  retires a control.
- **If the scorer marked something down on a meaningful fraction of
  gate-cleared reviews** — it is finding what the gate cannot, and it stays.
  Retire the pin, and go to Phase 4's `--resume` work with the scorer intact.
- **If the scorer cleared essentially everything the gate cleared** — it is
  paying Opus latency to agree. That is the case for removing or downgrading
  it, and it is the answer D9.5 was written to receive.
- **Either way ADR-0011 states the sample size and the limitation.** No dollar
  figure: there is no instrument, and this audit has already published one cost
  model that was backwards (§M). Latency and spawn counts are measurable — say
  those.

*Settled by:* ~10 real post-gate reviews, then ADR-0011. Until that ADR exists
the pin holds and **nothing edits lines 306–331.** Only ADR-0011 may retire
`prejudge/scorer-is-the-control-arm`.

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

**~~Does the lane's model hold the protocol?~~ SETTLED 2026-07-28 — yes.**
`deepseek/deepseek-v4-flash` drove `CHUNK-HELLO-1` through all seven sections of
`forge-lane` on the first run: it tracked its own position ("*step 3 — make it
usable*"), ran the environment prep, appended the role boundary, backgrounded
Codex, re-verified with a plain `make check`, read the diff as a hostile
reviewer ("*no dead code, no scope creep*"), checked for a pre-existing PR
because Codex *might* have ignored the boundary, and terminated once with valid
`created_cards`. No `crashed` reap, no retry. The cheap-driver bet in ADR-0004
is correct, and the run cost 4 minutes.

Caveat worth keeping: this was a six-line function. The protocol held; whether
the *judgement* holds on a chunk with real ambiguity is a different question,
and `docs/retro-metrics.md` is where it gets answered.
