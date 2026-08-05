# ADR-0010: A driver's identity is prose; its protocol is a program

**Status:** accepted · 2026-08-05
**Supersedes:** nothing. ADR-0003 is extended, not replaced. ADR-0007 D7.1 and
ADR-0009 both stand in full.

## Context

ADR-0003 decided that "anything that MUST hold is expressed as a machine gate at
the lowest layer that sees every actor," and named the layers: git hooks, CI,
the Makefile. ADR-0009 applied that rule to what tier 1 *decides*, moving eight
mechanical properties out of a language model's brief and into
`scripts/prejudge.sh`.

Neither ADR was ever applied to what a driver *does*. The result, measured
2026-08-05 on the branch that shipped ADR-0009:

| profile | SOUL lines | fenced blocks | protocol lives in |
|---|---|---|---|
| `forge-digest` | 27 | 0 | three prose steps |
| `forge-codex-lane` | 29 | 0 | `skills/forge-lane/SKILL.md` |
| `forge-orchestrator` | 32 | 0 | four prose steps |
| **`forge-prejudge`** | **404** | **11** | **itself** |

144 of those 404 lines were executable bash: a `jq` schema reduction, a
`claude -p` invocation, a fifteen-line stamping `jq`, a create/block/unassign
sentinel sequence and two `jq -e` read-backs. None of it required a model. All
of it was retyped by one — `deepseek-v4-flash`, the only metered agent in a
review — on every run, with no gate on the transcription.

Two further consequences made this more than an aesthetic problem.

**The suite could only approximate it.** Eleven `lane/prejudge-*` cases asserted
runtime behaviour by substring match against the prompt, and one compared the
line numbers of two `grep -n` results to assert ordering. `verify.sh` carried a
comment admitting that this is how a check and the SOUL "silently diverged for a
commit in the first place." A protocol in prose cannot be tested, only
described twice and diffed by hand.

**Editing the protocol touched a live install.** A SOUL edited in git does not
reach the worker until `hermes/profiles-bootstrap.sh` copies it into
`~/.hermes/profiles/<p>/SOUL.md`. So every protocol change desynchronised the
running profile and its documented remedy was to publish unmerged work to an
always-on install (audit F60).

## Decision

**D10.1 — A SOUL is identity.** It states who the profile is, what it must never
do, which artifact carries its protocol, and how to terminate. It does not
contain the protocol. `forge-codex-lane` has worked this way since it was
written; this generalises its pattern rather than inventing one.

**D10.2 — A protocol is an artifact under `scripts/`.** `prejudge-review.sh`
runs the gate, assembles the prompt, invokes the scorer, stamps the provenance
and creates the routed card. `install.sh` already symlinks the checkout at
`~/.forge/repo`, so the protocol reaches the worker without a bootstrap step.

**D10.3 — The seam is the terminator.** Exactly two operations stay with the
model, because the completion kernel binds them to the identity of the running
task: `kanban_complete` and `kanban_block`. The program emits one
`forge.review.v1` envelope — `action`, `summary`, `reason`, `metadata`,
`created_cards` — and the model calls the terminator the exit code names. Exit 0
is a routed outcome, exit 3 a substrate fault, exit 2 a usage error. 1 is
deliberately unused so a caller under `set -e` cannot mistake a bounce for a
crash.

**D10.4 — Both prompt kinds have a budget.** `cli/soul-body-budget` caps every
SOUL at 60 lines. `cli/no-programs-in-souls` caps any fenced block at 6 lines —
a profile may show the one command it runs; it may not carry a program. The
budget exists because the slice that eventually fixed this grew the same file by
65 lines first, and nothing in the suite could see it happen (F62).

**D10.5 — The control arm moved and was not modified.** The `claude -p --model
opus` call and its stamping `jq` are S5's experimental baseline. They were
carried into `prejudge-review.sh` byte-for-byte, including the three-space indent
inherited from the markdown list item they came out of.
`prejudge/scorer-is-the-control-arm` diffs 24 lines against
`git show main:hermes/profiles/forge-prejudge.SOUL.md` and fails the suite on any
difference, whitespace included. Whether the scorer survives at all remains
ADR-0009 D9.5's open question with S5's experiment attached; this ADR does not
touch it. Moving the bytes makes the control *stronger*: they are now executed
by bash and pinned by a test, where before they were prose a cheap model
re-enacted each run.

## Consequences

- What the protocol does is now testable by running it.
  `prejudge/review-routes-by-gate-result`, `review-emits-a-terminator-envelope`
  and `review-never-prints-the-diff` execute the real script against recorded
  `gh` responses with no network, replacing eleven substring matches (F63).
  `review-never-prints-the-diff` reports an actual measurement — 63,164 bytes
  moved into the prompt file, 2,599 bytes observed by the driver — where the
  rule used to be a promise the suite grepped for.
- The metered driver reads a ~2 KB envelope instead of a 404-line system prompt.
  That is a real reduction in metered input tokens per review, because the SOUL
  is the driver's system prompt and is read in full on every run. **It has not
  been measured.** The instrument is `hermes kanban runs`; §M of the audit is why
  this record does not publish a cost model it has not read. No dollar figure is
  claimed here, and the scorer is OAuth and free at the margin either way.
- Rationale that used to be billed on every run is now a comment in a script,
  where it is free and still stops the next editor deleting a load-bearing line
  cheaply. Every measured incident in the old SOUL — the invented
  `claude-opus-4-8`, the promoted sentinel card, the strand at
  `REVIEW_REQUIRED` — survives the move.
- Protocol changes stop desynchronising the live profile, which is F60's
  structural fix rather than its workaround. Identity changes still need
  `profiles-bootstrap.sh`, and they should be rare.

  **This ADR is itself one of those rare changes, and it has an ordering
  requirement: merge first, then bootstrap.** The new SOUL points at
  `~/.forge/repo/scripts/prejudge-review.sh`, and `~/.forge/repo` symlinks the
  main checkout. Bootstrapping before the merge would publish an identity that
  names a script `main` does not have yet, and the live tier-1 driver would fail
  on a missing file. So `config/soul-in-sync/forge-prejudge` fails for the
  duration of this branch on purpose. It is the last time a protocol change will
  cost that.
- `skills/forge-lane/SKILL.md` sits at 299 lines against a 300 budget with 12
  fenced blocks — the same shape, one layer over, recorded as resolved in
  `docs/state.md` by raising the limit to admit it. It is deliberately untouched
  here (F64): it is the most load-bearing proven artifact in the repo, four
  climbs depend on it, and `state.md` is explicit that nothing should ever be
  tested with two unknowns in play.
