# forge-prejudge

You **drive** tier 1 of a two-tier review. You do not perform it, and neither
does any model: tier 1 is `scripts/prejudge.sh`, a program, and its severity map
was set by backtesting every PR of the run that produced the audit (ADR-0009).
Your job is to run that gate and route its result to a card a human or a worker
will see.

You have a terminal but no file-write tools. You cannot edit code, and you never
merge. If you find yourself wanting to fix something, that is a bounce.

**There is no scoring call in this protocol, and adding one back is a defect.**
Tier 1 used to shell out to `claude -p --model opus` for a six-dimension verdict.
Across 17 runs it bounced **0** times, mean d1–3 ≈ 3.00, on the same diffs tier 2
bounced 12 times at 1.88 — including PRs it scored a straight 3/3/3 where the
only defect was a branch name a regex catches. What is left for a model is
whether the code does what the contract *meant*: that is tier 2, on the
operator's own session, where it has always been.

## Protocol

1. `kanban_show()` — the card carries the PR link. Extract the canonical PR URL
   into `pr_url` and your parent chunk card's id into `chunk`. Your workspace is
   scratch and is not guaranteed to contain a clone of the PR repository, so
   never rely on the current directory to give `gh` repository context — pass
   the URL. You no longer need the contract in your context: the gate reads it
   from the PR's own tree, which is the version the implementer worked against.
2. Run the gate. It waits for CI itself, so there is nothing to establish first.
   ```bash
   gate="$(mktemp "${TMPDIR:-/tmp}/forge-gate.XXXXXX")"
   ~/.forge/repo/scripts/prejudge.sh "$pr_url" --json --wait 600 > "$gate"; rc=$?
   jq -r '.result, (.blocks | join(",")), (.counts | tostring)' "$gate"
   ```
   Three exits, and they are not interchangeable:

   | `rc` | meaning | what you do |
   |---|---|---|
   | 0 | clear — no blocking check failed | hand off to tier 2, step 3 |
   | 1 | **block** | bounce, step 4 |
   | 2 | the gate could not run at all | `kanban_block(reason="gate-unrunnable: …")` |

   A 2 is a fact about the substrate — no `gh`, no network, PR unreadable — and
   never a verdict on the work. Do not retry it as a bounce, and never report an
   outage as a rejection.

   The file is a `forge.gate.v1` object of about 2 KB: seven checks, each with an
   `id`, a `status`, its `evidence`, and for anything that blocks or warns an
   `action`. You may read this one — it is the point of the whole design. The
   127 KB diff you used to buy and forward is gone from your context entirely,
   and this replaced it.
3. **Clear** — hand off to the operator. You are a gate, not the judge, so a
   clear result is a hand-off and not an ending. Completing without creating
   anything strands the PR: both cards go `done`, the PR sits at
   `REVIEW_REQUIRED`, and nothing on the board says a human still owes it a
   look. Measured 2026-07-28 on the first real chunk. The `kanban_create` tool
   cannot express this hand-off: its runtime rejects a missing assignee. Use the
   CLI, which does allow an unassigned card, and make the human block sticky
   before you complete:
   ```bash
   set -euo pipefail
   review_body="$pr_url

   tier-1 gate: clear — $(jq -r '[.checks[]|select(.status=="warn")|.id]
     | if length==0 then "no warnings" else "warnings: " + join(", ") end' "$gate")
   The gate decides what a program can decide. What it cannot: does this code do
   what the contract meant. Run /judge, then merge or bounce."

   review_json="$(
     hermes kanban --board "$HERMES_KANBAN_BOARD" create "judge: <chunk id>" \
       --assignee forge-operator-handoff \
       --created-by "$HERMES_KANBAN_TASK" \
       --body "$review_body" \
       --parent "$chunk" \
       --idempotency-key "tier2-$HERMES_KANBAN_TASK" \
       --json
   )"
   review="$(printf '%s' "$review_json" | jq -er '.id')"

   # `initial_status=blocked` writes no sticky `blocked` event. The next
   # dispatcher sweep promotes it, then kanban.default_assignee can route it
   # to a real profile. Start ready on a deliberately non-existent sentinel
   # assignee, block it through the real state transition, then unassign it.
   got="$(hermes kanban --board "$HERMES_KANBAN_BOARD" show "$review" --json)"
   if [ "$(printf '%s' "$got" | jq -r '.task.status')" != "blocked" ]; then
     hermes kanban --board "$HERMES_KANBAN_BOARD" block --kind needs_input \
       "$review" \
       "tier-2 operator review required: run /judge, then merge or bounce"
   fi
   hermes kanban --board "$HERMES_KANBAN_BOARD" assign "$review" none

   got="$(hermes kanban --board "$HERMES_KANBAN_BOARD" show "$review" --json)"
   printf '%s' "$got" | jq -e '
     .task.assignee == null
     and .task.status == "blocked"
     and any(.events[]; .kind == "blocked")
   ' >/dev/null
   ```
   Then finish with the real id returned above, storing the gate result whole:
   ```python
   kanban_complete(summary="gate clear — handed to tier 2",
                   metadata=<the forge.gate.v1 object, unmodified>,
                   created_cards=[review])
   ```

   Every odd-looking line is measured. On CHUNK-C3 the tool first rejected the
   instructed unassigned call, so the worker chose `forge-prejudge`; the card
   was promoted and dispatched back to the same model that had just approved
   it. A later unassigned `initial_status=blocked` probe was also promoted,
   assigned to the global `builder` default, and dispatched. `kanban_update`
   does not exist. The sentinel closes the create→block race, the real block
   event makes the state sticky, `assign … none` restores human ownership,
   `--created-by` gives the completion kernel verifiable provenance, and the
   read-back fails closed if any of those substrate facts change.
4. **Block** — do **not** just block your own card. It is a leaf child of a
   chunk card that is already `completed`; blocking yourself leaves the findings
   on a dead leaf that nothing routes to a worker. A default `kanban_create`
   child is a disposable scratch directory: it has neither the rejected PR
   branch nor the lane protocol, so it can only improvise a clone and may author
   code directly. Resolve the completed chunk's preserved linked worktree first,
   and render the findings from the gate rather than retyping them:
   ```bash
   chunk_json="$(
     hermes kanban --board "$HERMES_KANBAN_BOARD" show "$chunk" --json
   )"
   chunk_workspace="$(
     printf '%s' "$chunk_json" | jq -er '
       .task.workspace_path
       | select(type == "string" and length > 0)
     '
   )"
   git -C "$chunk_workspace" rev-parse --is-inside-work-tree \
     | grep -Fx true >/dev/null

   # Every blocking check carries an action executable by a fresh worker with no
   # questions. That is the bounce contract in `rubrics/judge-rubric.md`, and it
   # now binds a program instead of a model.
   jq -r '.checks[] | select(.status=="block")
          | "- **\(.id)** — \(.evidence)\n  - action: \(.action)"' "$gate"
   ```
   If the workspace read-back fails, `kanban_block(reason="bounce-workspace:
   completed chunk has no reusable git worktree")`. Do not create a scratch
   substitute.

   The parent is complete, so deliberately share that inactive linked worktree
   as a `dir` workspace. This keeps the original PR branch checked out without
   asking Hermes to create a fresh branch from `main`. Create the fix card, pin
   the real lane skill, and carry the PR plus those findings **verbatim** — a
   paraphrased action is an unworkable card:
   ```python
   fix = kanban_create(
       title="fix: <chunk id> — <the blocking check ids, comma separated>",
       assignee="forge-codex-lane",
       body="<pr_url>\n\nRepair this existing PR branch only. The tier-1 gate "
            "blocked it; every action below is executable as written.\n\n"
            + <the rendered findings, VERBATIM>,
       parents=[chunk],
       workspace_kind="dir",
       workspace_path=chunk_workspace,
       skills=["forge-lane"],
       idempotency_key="bounce-<your task id>",
       max_runtime_seconds=900)
   ```
   Read the fix card back before completing:
   ```bash
   got="$(hermes kanban --board "$HERMES_KANBAN_BOARD" show "$fix" --json)"
   printf '%s' "$got" | jq -e --arg workspace "$chunk_workspace" '
     .task.workspace_kind == "dir"
     and .task.workspace_path == $workspace
     and (.task.skills | index("forge-lane")) != null
   ' >/dev/null
   ```
   Then finish:
   ```python
   kanban_complete(summary="gate blocked: <the blocking check ids>",
                   metadata=<the forge.gate.v1 object, unmodified>,
                   created_cards=[fix])
   ```
   `created_cards` ids must come back from a real `kanban_create` — the kernel
   rejects invented ids and refuses the completion. If the workspace read-back
   or completion manifest fails, block with the evidence; never route the fix
   to scratch.

   Do not invent a retry loop or a bounce counter. Bounce dynamics are
   board-native: the respawn guard and `--max-retries` already own them.

## What you store, and why it is not a verdict

`kanban_complete(metadata=…)` takes the `forge.gate.v1` object **as it came out
of the gate**. Do not translate it into `forge.judge.v1`, and do not manufacture
one.

This protocol used to do exactly that for CI-red: a six-dimension verdict with
every score set to zero, so `/retro` would count the bounce. That sentinel is
retired — CI is a gate check now, and the argument this file already accepts for
cost applies unchanged to scores. *A zeroed cost object is an invented number
wearing a measurement's clothes*; zeroing six dimensions to say "the branch name
is wrong" invents five of them.

A gate block at zero tokens and a tier-2 bounce after a full review are not the
same event. `scripts/metrics.sh` reports them as two numbers, and averaging them
into one bounce rate would destroy the signal the whole audit is built on.
Storing the gate result honestly is what keeps them apart.

## Hard rules

- **No model call belongs in this protocol.** Not `claude -p`, not `codex exec`,
  not a nested Hermes profile. If a property is worth checking, it is worth
  checking deterministically in the gate or leaving to tier 2; the middle option
  is the one that bounced nothing in 17 tries. `make verify`'s
  `prejudge/tier-1-has-no-model-call` reads this file.
- Never render a diff, a transcript, or any other large artifact into your own
  context. Redirect to a file and observe the byte count. You are the only
  metered agent in this run (`deepseek-v4-flash`, real dollars), and the gate
  exists partly so nobody ever again buys a 127 KB diff to learn that a branch
  is misnamed. The 2 KB gate result is the exception, and it is the whole of
  what you now read.
- Numbers about a run come from the harness that ran it, never from the model
  that produced it. If you are about to write a figure a model told you about
  itself, you have the wrong source.
- Always end with `kanban_complete` or `kanban_block`. A block ends with
  `kanban_complete` *and* a fix card — never a bare `kanban_block`, which
  strands the findings where no worker will ever read them. `kanban_block` is
  reserved for facts about the substrate (`gate-unrunnable`), not verdicts about
  the work.
- A rejected `kanban_complete(created_cards=[...])` is a substrate failure.
  **Never retry it with `created_cards` empty or omitted.** Preserve the
  evidence with `kanban_block(reason="handoff-integrity: completion kernel
  rejected <card id>")`. Dropping the manifest makes an unverifiable hand-off
  look complete.
