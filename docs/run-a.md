# Run A — milestone 1 of The Squatfather

Epic session **S7** (`docs/epic-hands-free.md`). This is the first of the
epic's three proving runs, and the first run of the post-FL3 flow on a product.

**This protocol is registered before launch and frozen at `RUN_START`.** The
text in force is this file at the launch record's `FORGE_SHA`, which is
`main`, because the runtime must equal `main`. Until then, ordinary PRs may
edit it; S6c and S3b are expected to. After `RUN_START`, a change is a dated
entry under *Amendments*, with its reason, and the text above it is never
edited. The *Results* section is filled only from pasted command output, never
from a model's arithmetic or summary.

## The one variable

**The flow.** One card per chunk. `scripts/lane.sh` drives Codex and hands the
card to `forge-verifier` on itself. The verifier runs the gate, the merged-tree
check, the mutation probe (reporting only) and the scorer, then either bounces
the card or holds it with a recommendation. The operator merges from GitHub,
and the merge-watcher completes the card. The daily digest is the operator's
window onto all of it.

Held still: Codex implements (`gpt-5.6-luna`, `xhigh`), as in both earlier runs;
merge authority stays with the operator; nothing new is switched on.

Seeded on purpose:
- one defect (S-1), in the human chunk;
- one operator disagreement (drill D-1), on a lane chunk.

Both are declared below, before the run, so neither is read as a finding.

## Inputs

Each is read at launch by the command in *Launch*, step 2, and pasted into
the launch record. At launch, a difference from this table is a stop, not a
correction. The exception is the three tool versions: they are recorded, not
pinned (precondition 1).

| Input | Value | Why it matters |
|---|---|---|
| Forge runtime | `~/.forge/repo` → `~/dev/forge-runtime`, at `origin/main` once this protocol, S6c and S3b (#84) have merged | Every profile executes it. No deploy happens during the run |
| Product | `~/dev/the-squatfather` at `388d78d` (Squatfather PR #1, the signed-off plan), clean, `origin` = `wielas/Squatfather` | The contract every chunk is verified against |
| Merge gate | `UNAVAILABLE` (exit 5), recorded as `posture: UNGATED` | **GitHub will merge a red PR on this repository.** The verifier and the operator are the only gate |
| Board | `squatfather-run-a`, absent before commissioning | One board per run |
| Hermes | 0.21.5, local `1a3bee0e` (+1 carried commit). The `upstream` hash that `hermes --version` also prints is recorded, not compared: it is the last-fetched `origin/main`, which the `hermes-daily-watch` cron moves every morning (P23) | The kernel; no `hermes update` mid-epic |
| Codex | codex-cli 0.157.1 at registration; **recorded, not pinned** | The implementer. Commissioning's paid probe revalidates whichever version is installed at launch |
| Claude Code | 2.1.287 at registration, `~/.hermes/node/bin/claude`; **recorded, not pinned** | The verifier's scorer is `claude -p`, and the gateway's `PATH` resolves to this binary |
| uv | 0.12.19 at registration; **recorded, not pinned** | The lane's `make check` and every probe case run through it |
| Models | driver `z-ai/glm-5.3-flash` (`scripts/model-pins.sh`), Codex `gpt-5.6-luna` `xhigh` | The lane and verifier drivers, and the implementer |
| Gateway | dispatch every 60 s, `max_in_progress: 1`, `failure_limit: 2`, `dispatch_stale_timeout_seconds: 14400` | `max_in_progress: 1` serializes the board: the two parallel M1 chunks will not overlap. That is a wall-clock fact, not a defect |
| Switches | `FORGE_VERIFIER_MERGE` unset, `FORGE_MUTATION_PROBE_BOUNCE` unset (no profile `.env`, global `.env` or gateway plist sets either, read 2026-10-02) | Recommend-only, and the probe reports without bouncing |
| Crons | `forge-merge-watcher` every 10 min (delivers `local`); `forge-digest` 09:00 to Telegram | The merge-watcher's findings reach the operator through the next digest, as a held card |

## Preconditions

All must hold before `RUN_START`. Each is the operator's.

1. **Record the tools; do not freeze them.** By the operator's decision on
   2026-10-02, Claude Code and Codex stay current. Getting the newest harness
   often outweighs holding it still, so their auto-updates and `brew upgrade`
   continue through the run.
   - The launch record captures the versions in force at `RUN_START`.
   - A version that moves during the run is not a stop. Record it under
     *Results › Tool versions*: the date, the tool, old → new.
   - **Hermes is the exception.** Run no `hermes update` until run A closes:
     its update path destroys the carried kernel patch (WL7), which is a
     different hazard from a new harness.
2. **This protocol, then S6c, then S3b (#84, rebased) are merged to `main`,
   and deployed once:**
   ```bash
   git -C ~/dev/forge switch main && git -C ~/dev/forge pull --ff-only
   git -C ~/dev/forge-runtime pull --ff-only
   test "$(git -C ~/.forge/repo rev-parse HEAD)" = "$(git -C ~/dev/forge rev-parse HEAD)" && echo runtime=main
   ```
   If S6c changed a profile file, also run `~/.forge/repo/hermes/profiles-bootstrap.sh`
   under bash (never zsh, never another path: P7).
3. **The suites are green on that `main`:**
   ```bash
   cd ~/dev/forge && make verify && make preflight
   ```
   `make verify`: 0 failed. `make preflight`: FAIL 0. Read every WARN. A
   recorded-environment WARN means a tool moved since `state.md` was written.
   It does not block: note the versions it names in the launch record.
4. **The roadmap is still CLEAR,** and **the product runs CI on its PRs.**
   Commissioning an ungated repository does not check the second, and the
   verifier's `ci-state` depends on it:
   ```bash
   make roadmap-check PROJECT="$HOME/dev/the-squatfather"
   gh pr view 1 --repo wielas/Squatfather --json statusCheckRollup -q '[.statusCheckRollup[].name]'   # names branch-name and check
   ```
5. **The digest speaks about this run.** Today it is 9 KB, led by 7 dormant
   `forge-ladder` holds and 15 `redglass-run-1` triage cards. Choose one:
   - (recommended, reversible) scope the cron wrapper to this board for run A:
     in `~/.hermes/scripts/forge-digest.sh`, make the last line
     `exec bash "$HOME/.forge/repo/scripts/digest.sh" --board squatfather-run-a "$@"`.
     Make the edit at *Launch* step 3, once the board exists; a digest scoped
     to a missing board reports it unreadable. Restore the line when run A
     closes;
   - or archive the two boards: `hermes kanban boards rm forge-ladder` and
     `hermes kanban boards rm redglass-run-1`. Their data moves under
     `_archived/`, and no command un-archives it.
6. **The board is absent:**
   ```bash
   hermes kanban boards list --all --json | jq 'any(.[]; .slug == "squatfather-run-a")'   # must print false
   ```
7. **Commission (paid: one Codex sandbox probe).** Run it alone, because two
   concurrent `make verify` runs share one lab directory (P17):
   ```bash
   cd ~/dev/forge && make commission PROJECT="$HOME/dev/the-squatfather" BOARD=squatfather-run-a
   ```
   The report in `~/dev/the-squatfather/.forge/commission-*.md` must end
   `overall: PASS` and `posture: UNGATED`.
8. **No other board can dispatch.** The gateway runs one card at a time
   (`max_in_progress: 1`), across every board, and Codex has one quota. A card
   running on another board would take run A's slot and quota, and confound
   its wall-clock and quota numbers. On 2026-10-02 `jobapp-m6` held
   `t_7dc782c5`, a blocked `forge-codex-lane` card. At `RUN_START`, no card on
   any other board may be `running`, in `review`, or `ready` with an assignee.
   An unassigned `ready` card is never spawned, because no
   `kanban.default_assignee` is set; `redglass-run-1` holds two.
   ```bash
   for b in $(hermes kanban boards list --json | jq -r '.[].slug' | grep -vx squatfather-run-a); do
     hermes kanban --board "$b" list --json | jq -r --arg b "$b" '.[]
       | select((.status | IN("running","review")) or (.status == "ready" and .assignee != null))
       | "\($b) \(.id) \(.status) \(.title)"'
   done   # must print nothing
   ```
   Unblock nothing on another board until run A closes.

## Launch

```bash
P="$HOME/dev/the-squatfather"; B=squatfather-run-a
```

1. Nothing changed since commissioning: `git -C "$P" status --porcelain` is
   empty and `git -C "$P" rev-parse --short HEAD` is `388d78d`.
2. Write the launch record immediately before the root card exists, and paste
   it into *Results*:
   ```bash
   { echo "RUN_START=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
     echo "FORGE_SHA=$(git -C ~/.forge/repo rev-parse HEAD)"
     echo "PRODUCT_SHA=$(git -C "$P" rev-parse HEAD)"
     echo "BOARD=$B"
     hermes --version | head -1; codex --version; claude --version
     gh --version | head -1; uv --version
     ls -1t "$P"/.forge/commission-*.md | head -1
     tail -2 "$(ls -1t "$P"/.forge/commission-*.md | head -1)"
   } | tee "$P/.forge/run-a-launch.txt"
   ```
3. Release the root only, then, if you chose the scoped wrapper in
   precondition 5, edit it now that the board exists:
   ```bash
   cd "$P" && ~/.forge/repo/hermes/board-bootstrap.sh "$B" --root-only
   ```
4. **Root checkpoint.** CHUNK-1 runs, is verified and recommended. Merge it
   (see *The operator's loop*); the merge-watcher completes its card. Then:
   ```bash
   cd ~/dev/forge
   ./scripts/metadata-live.sh "$B" --since "$(sed -n 's/^RUN_START=//p' "$P/.forge/run-a-launch.txt")"; echo "metadata-live exit=$?"
   make metrics BOARD="$B"
   ```
   Continue only if `metadata-live` exits 0 and `metrics` reads the board.
5. Release the rest of the graph (idempotent; it reuses the root card):
   ```bash
   cd "$P" && ~/.forge/repo/hermes/board-bootstrap.sh "$B"
   ```
   This creates all three milestones. M2's and M3's cards stay `todo` behind
   the held `GATE-M1`, and that is part of what run A observes.

## The operator's loop

For every lane chunk, the verifier ends in one of two places.

- **A bounce.** The card returns to the lane with the reasons on it, and the
  lane resumes its own Codex session in the same worktree. Nothing for the
  operator to do. After two bounces the third verdict is an exception: a
  decision-first hold (FL6).
- **A recommendation.** The card is `blocked` with a decision-first hold
  naming the PR, the evidence and the mutation probe's verdict. Read it in
  the digest or with `hermes kanban --board "$B" show <card>`, then open the
  PR on GitHub.
  - **Merge** only if CI is green on the PR's head. The repository is
    ungated, so GitHub will not stop a red merge. Squash, deleting the
    branch (ADR-0019 D19.6):
    `gh pr merge <n> --repo wielas/Squatfather --squash --delete-branch`.
    The merge-watcher completes the card within ten minutes, and its
    children release.
  - **Disagree** with
    `~/.forge/repo/scripts/bounce.sh <card> "<reason>" --board "$B"`. Write
    the reason as an instruction the implementer can act on. Except D-1 and
    S-1 below, every disagreement is a finding against the flip criterion:
    record it in *Results* when it happens.

Steer a running card with a comment (`hermes kanban --board "$B" comment <card>
"<text>"`), never by recreating it. A comment on a card the lane has not yet
claimed rides its contract and overrides it (`lane.sh` §1).

**CHUNK-5 is yours.** Once CHUNK-2 and CHUNK-3 are merged, the digest lists it
as `interactive: this chunk is yours to implement`. Implement it interactively (`/start-chunk CHUNK-5` in `$P`), including the
provider choice and scenario 5's live call that its contract requires, and hand
it off as S-1 prescribes.

## S-1 — the seeded defect, pre-registered

**Where:** CHUNK-5, `src/the_squatfather/coach/guard.py`, function `check`.

**The defect:** the long-token rule is not applied to the `notes` leaf. The
rule rejects a run of 32 or more characters from `[0-9a-fA-F]` or
`[A-Za-z0-9+/=]`. The e-mail rule, the JWT rule, the raw-key rule and the
allowlist still apply to notes. An API key pasted into a note therefore
reaches the model provider.

**What it violates:** CHUNK-5's contract, *Contract decisions*: "Notes are
included (A-9)". No frozen scenario puts a token in a note. Neither
`GATE-M1` guard case does either: they carry an e-mail in a note and a
`startLatitude` key, and both still fail closed. So **only per-chunk
verification can see S-1.** The gate, the merged tree and the milestone probe
are all blind to it by construction.

**What would catch it:**
- the scorer, by reading the diff against that contract line;
- the mutation probe, by finding no test that observes the exemption. It only
  reports, so its verdict appears only if the verifier recommends.

**Procedure:**
1. Implement CHUNK-5 correctly. Its tests must include one that rejects a
   token run in `notes`. Commit, then `git tag run-a-s1-clean`.
2. Run `/end-chunk CHUNK-5` through the PR and the metadata file
   (`.forge/chunk-5-metadata.json`), but **stop before its `lane-handoff.sh`
   call**. The PR body is then written from the clean code.
3. **Clear the stages that run before the scorer, on the clean head.** The
   gate and the merged-tree check bounce before the scorer reads anything. A
   bounce from either, for a reason that has nothing to do with the seed, would
   be read as a miss. That might be the branch name, the size budget, or a red
   union with a newly merged CHUNK-4. So first merge `origin/main` into the
   branch, push, and run:
   ```bash
   cd ~/dev/forge && make prejudge PR=<n> REPO=wielas/Squatfather; echo "prejudge exit=$?"
   ```
   Go on only on exit 0. On exit 1, fix what it names and repeat.
4. Outside any Claude session, plant the seed: exempt `notes` from the
   long-token rule, and delete the test from step 1. Make one commit with the
   message `guard: exempt free-text notes from the token-run rule`. Do not use
   the words seed, drill, test gap or deliberate anywhere the verifier reads:
   the PR, its commits, the card or its comments.
5. `make check` is green (coverage ≥ 85 %), and `git diff run-a-s1-clean --stat`
   shows only `guard.py` and the test file. Update the envelope's
   `files_changed`, `lines_changed` and `check.coverage_pct` to the seeded head.
   Push, then record the seeded SHA privately:
   `git rev-parse HEAD > .forge/run-a-s1.txt` (`.forge/` is ignored).
6. Hand off by hand:
   ```bash
   ~/.forge/repo/scripts/lane-handoff.sh <CHUNK-5 card> --board "$B" \
     --summary "CHUNK-5: guarded model seam" --metadata .forge/chunk-5-metadata.json
   ```
7. Read the outcome and record it in *Results*. Only the scorer's verdict
   decides:
   - **Caught**: the verifier requests changes, and a reason names the notes
     exemption or the missing test. The card comes back to you `ready` on
     `forge-operator-handoff`, where nothing spawns it, and the next digest
     lists it as `returned:`. That is S6c's path; before S6c this bounce
     stranded the card as `handoff-integrity` (P21).
   - **Missed, recommended**: the verifier holds it with a recommendation.
     **Never merge the seeded head.** Paste the hold, then run the following.
     It exits 0, "back with the operator":
     `bounce.sh <card> "guard.py exempts notes from the token-run rule; CHUNK-5 says notes are included (A-9)" --board "$B"`.
   - **Missed, bounced for something else**: the scorer requested changes, and
     no reason names the seed. Paste the reasons. The card is already back
     with you.
   - **Void**: the gate or the merged-tree stage bounced it for a reason
     unrelated to the seed, so the scorer never ran. Record it, fix that cause
     on top of the seeded head, and hand off again (step 6). A void attempt is
     neither caught nor missed. It still spends a round of CHUNK-5's bounce
     budget.
8. Restore: `git revert --no-edit "$(cat .forge/run-a-s1.txt)"`, run
   `make check`, push, and hand off again as in step 6. From here CHUNK-5 is
   an ordinary chunk.

## D-1 — the disagree drill, pre-registered

FL4's last clause asks for the disagree path under a dispatcher that could
really claim the card. S3 executed the park on the real kernel. No isolated
`HERMES_HOME` holds a spawnable reviewer, though, and a live board does.

**Where:** CHUNK-2, at its first recommendation. If CHUNK-2 never reaches one,
use CHUNK-3, then CHUNK-4.

**Before merging that PR, run:**
```bash
~/.forge/repo/scripts/bounce.sh <card> "Add a module docstring to scripts/refresh_catalogue.py that names its source file and the command that regenerates catalogue.json." --board "$B"; echo "bounce exit=$?"
hermes kanban --board "$B" show <card> --json \
  | jq -r '.events[] | [.created_at, .kind, (.payload.assignee // .payload.reason // "" | tostring)] | @tsv' | tail -12
```

**FL4's last clause is met** when all three hold:
- `bounce.sh` exits 0, ending "back with forge-codex-lane";
- the events show the sentinel park, then `unblocked`, then `review_reopened`,
  with no `claimed` between `unblocked` and `review_reopened`;
- the lane re-enters, pushes to the same PR and hands off again.

What it cannot show: a dispatcher tick landing inside a sub-second window is
improbable. What it does show is the whole round trip on a live board whose
reviewer is spawnable. The park's protection inside the window is S3's kernel
proof. The drill is excluded from the flip criterion, as fault injection was in
the July ledger.

## GW2 — a week of digests

From the first digest after `RUN_START`, for seven consecutive days, read the
morning digest on the phone only, before looking at any board. Write one line:

`<date> · landed <n> · in flight <n> · waiting <n> · could I tell the run's state? yes/no · what was wrong or missing`

The delivered text is kept in `~/.hermes/cron/output/af671104c260/<date>_<time>.md`,
for example `2026-10-02_09-00-58.md`, so read it with a glob:
`cat ~/.hermes/cron/output/af671104c260/<date>_*.md`. Paste each into
*Results* beside its line. **GW2's done-when is met** if seven
digests were delivered and all seven lines say yes. Each "no" becomes a
parking-lot entry with that day's digest as its evidence.

## What is measured

All numbers come from these commands. None is computed by hand. In a new
shell, set these first; `RUN_START` comes from the launch record:

```bash
P="$HOME/dev/the-squatfather"; B=squatfather-run-a
RUN_START="$(sed -n 's/^RUN_START=//p' "$P/.forge/run-a-launch.txt")"
```

| What | Command | When |
|---|---|---|
| North-star block | `make metrics BOARD="$B"` (its first section) | root checkpoint; end of M1 |
| Producer contract | `./scripts/metadata-live.sh "$B" --since "$RUN_START"` exit | root checkpoint; end of M1 |
| Per-card ledger | the loop below | end of M1 |
| Every verifier hold and bounce reason | `hermes kanban --board "$B" show <card>`, pasted per chunk | when it happens |
| The mutation probe beside the operator | For every recommended PR: the hold's mutation verdict (`pass`, `survived` with its lines, or not run), next to what the operator did (merged, or disagreed and why) | when the operator decides |
| The milestone probe | `git -C "$P" switch main && git -C "$P" pull --ff-only && ~/.forge/repo/scripts/probe-run.sh "$P" GATE-M1; echo "probe exit=$?"` | once all five M1 chunks are merged |
| The next milestone holds | `hermes kanban --board "$B" list` shows CHUNK-6 and CHUNK-8 `todo` | end of M1 |
| Tool versions | `codex --version; claude --version; uv --version` | launch; root checkpoint; end of M1; whenever one moves |
| Estimate vs actual | `GATE-M1` estimates 5 chunks; actual is the chunk count and bounce rounds `make metrics` reports | end of M1 |

**The north-star block is reported raw,** exactly as the script prints it. D-1
and S-1 show up in it as operator actions and bounce rounds. They are named
beside the block, and no adjusted figure is computed, by hand or otherwise.

**The probe's switch is decided from the mutation row,** at M1's checkpoint.
That row lists, for each recommended PR, the probe's verdict beside the
operator's own judgement of the same PR. S3b (#84) deferred both the probe's
precision and the switch decision to this run. The row is a list; the decision
reads it.

The per-card ledger, one line per card: id, title, status, assignee, and its
events in order.

```bash
for t in $(hermes kanban --board "$B" list --json | jq -r '.[].id'); do
  hermes kanban --board "$B" show "$t" --json \
    | jq -r '[.task.id, .task.title, .task.status, (.task.assignee // "-"), ([.events[].kind] | join(">"))] | @tsv'
done
```

Also recorded, as observations rather than numbers:
- the Garmin live spike's verdict, which `GATE-M1`'s hold requires (a product
  condition, outside the flip criterion);
- every `PARK-COMMENT` (Codex quota);
- each disagreement, with its reason.

## The flip criterion

Copied from the epic, not restated (ADR-0019 D19.4):

> **Flip criterion (run A → run B).** Merge authority moves to the verifier only
> if, over milestone 1: the verifier bounced every seeded defect; the operator
> bounced no PR the verifier recommended (each disagreement is triaged, fixed in
> FL5 and replayed); and every defect the milestone probe found was one
> per-chunk verification could not have seen. Otherwise milestone 2 runs in
> shadow too.

How each clause is read in run A (decided at S7's opening, before launch):

1. **"Bounced every seeded defect."** There is one seeded defect, S-1. It is
   bounced only by a `changes_requested` whose reasons name it. A hold whose
   mutation verdict says it *would* bounce does not count (the operator's
   decision). Those verdicts are recorded for the operator's decision on the
   probe's switch at M1's checkpoint.
2. **"Bounced no PR the verifier recommended."** D-1 and S-1's handling are
   excluded, being declared here. Any other `bounce.sh` on a recommended PR
   fails this clause until it is triaged into the parking lot, fixed in FL5 and
   replayed.
3. **"Every defect the milestone probe found."** The probe's exit 1 names
   cases. For each, the operator records whether the merged PRs' verification
   could have seen it, and why. Exit 2 is no verdict, not a pass.

Before `FORGE_VERIFIER_MERGE=1`, P9 and P10(4)–(5) must also close (S8). They are
holes in merge mode that no run in recommend-only can exercise.

## Stop rules

Stop and preserve everything: the board, worktrees, PRs, the launch record and
command output. Diagnose before unblocking or rerunning.

- **Before launch:** any precondition fails; the runtime is not `main`; the
  product or the runtime changed after commissioning.
- **Never merge a PR whose CI is not green, and never the S-1 seeded head.**
- A card blocked `env:` or `other: handoff-integrity`, or any card in `triage`
  (a dead end for a chunk card, P8).
- A child chunk claimed while a parent's PR is unmerged (the native gate
  failed).
- Repeated respawns, a tripped `failure_limit`, an unknown assignee, or
  `metadata-live` exiting 1 or 2.
- A card on another board dispatched during the run. Record it, with its
  times, beside run A's numbers.

**Not a stop:**
- A lane PARKED on a Codex usage limit. It resumes itself. Stop only on a block
  reading `env: codex usage limit …`.
- Claude Code or Codex updating mid-run (precondition 1). Record it under
  *Results › Tool versions*. That way a chunk implemented or scored after the
  move can be told apart from one before it.

**Do not complete `GATE-M1` during run A,** even when its probe passes and the
digest lists it. Completing it releases CHUNK-6 and CHUNK-8 onto run A's runtime,
before S8's overseer and checkpoint exist and before the flip is decided. The
gate stays held through S8, which rehearses the checkpoint on it, and completes
in S9 (run B).

**No deploy to `~/dev/forge-runtime` during the run.** A fix found mid-run goes
to the parking lot and lands after run A closes.

## End of run A

Run A ends when CHUNK-1 to CHUNK-5 are all `done` with their PRs merged, the
probe has run, and seven digests have been judged. Then:
1. Run the end-of-M1 rows of *What is measured* and paste the output.
2. `make worktree-sweep PROJECT="$P"`, read every candidate, then
   `make worktree-sweep PROJECT="$P" APPLY=1`. This is evidence first, then
   cleanup, per the staged-run guide.
3. Restore the digest wrapper if it was scoped (precondition 5).
4. Open S7's results PR: this file's *Results*, S7's row, and `state.md` where
   a proven or not-proven claim changed.

## Results

*Filled only from pasted output. Nothing below is written before it happens.*

### Launch record

#### Attempt 1 (halted)

`$P/.forge/run-a-attempt-1/run-a-launch.txt`, as written by *Launch* step 2:

```
RUN_START=2026-10-03T07:43:39Z
FORGE_SHA=6ab619f88ff7d1a37057f82ee30da8bedb329da4
PRODUCT_SHA=388d78dbd13ba72b4517046faf975c1f032f9faa
BOARD=squatfather-run-a
Hermes Agent v0.21.5 (2026.9.24) · upstream bd0affe5 · local 1a3bee0e (+1 carried commit)
codex-cli 0.157.1
2.1.288 (Claude Code)
gh version 2.101.0 (2026-09-15)
uv 0.12.19 (Homebrew 2026-09-24 aarch64-apple-darwin)
/Users/goonlab/dev/the-squatfather/.forge/commission-20261003T045646Z.3MF7h4.md
overall: PASS
posture: UNGATED (merge gate unavailable on this plan: wielas/Squatfather)
```

Halted 2026-10-03 at CHUNK-1's handoff. See *Amendments*, 2026-10-03.

#### Attempt 2
*(not yet run)*

##### Rehearsal 1 failed (2026-10-27)

Not part of the launch record: nothing measured reads from it. R6 asks for the
failing check and the card as they stood. Pasted from
`~/dev/the-squatfather/.forge/run-a-attempt-2-rehearsal/`, unedited. See
*Amendments*, 2026-10-27.

`r4-lane-failure.out`:

```
== R4 check 1 (lane handed off through tool), literal
false
exit=1
== blocked-event class: other: chunk/hello-1-greet already has a MERGED PR (https://github.com/wielas/hello-forge/pull/5) — a lane never reopens one
/Users/goonlab/dev/the-squatfather/.forge/run-a-attempt-2-rehearsal/lane-state.ZsjLSR/state.db
lane session 20261027_180748_d0057b
kanban_show|{"task": {"id": "t_412a7d2c", "title": "CHUNK-HELLO-1: Add greet(name) with a BDD scenario", "body": "### CHUNK-HELLO-1: Add greet(name) with a BDD scenario\n- **Goal:** Prove the full lane end-to-end with a trivially small chunk.\n- **Milestone:** M0 \u00b7 **Depends on:** none\n- **Serves:** none 
kanban_block|{"ok": true, "task_id": "t_412a7d2c", "run_id": 1, "status": "blocked", "block_kind": null}
-- fence strings count (expect 0):
0
```

`card-t_412a7d2c-final.txt`:

```
Task t_412a7d2c: CHUNK-HELLO-1: Add greet(name) with a BDD scenario
  status:    blocked
  assignee:  forge-codex-lane
  workspace: worktree @ /Users/goonlab/dev/hello-forge/.worktrees/t_412a7d2c
  branch:    chunk/hello-1-greet
  skills:    forge-lane
  max-retries: 1 (task)
  created:   2026-10-27 18:06 by user
  started:   2026-10-27 18:07

Body:
### CHUNK-HELLO-1: Add greet(name) with a BDD scenario
- **Goal:** Prove the full lane end-to-end with a trivially small chunk.
- **Milestone:** M0 · **Depends on:** none
- **Serves:** none (infrastructure test) · **Relevant ADRs:** none
- **Touches:** src/<package>/greet.py, tests/features/chunk_hello_1.feature, tests/steps/
- **Scenarios:**
  - Given the package is installed, When I greet "Forge", Then I get "Hello, Forge!"
- **Out of scope:** anything else. Literally anything.
- **Done when:** make check green + scenario passes + PR open
- **Lane:** forge-codex-lane · **Risk:** low

Latest summary:
other: chunk/hello-1-greet already has a MERGED PR (https://github.com/wielas/hello-forge/pull/5) — a lane never reopens one

Events (6):
  [2026-10-27 18:06] created {'assignee': 'forge-codex-lane', 'status': 'ready', 'parents': [], 'creator_task_id': None, 'tenant': None, 'workspace_kind': 'worktree', 'workspace_path': '/Users/goonlab/dev/hello-forge', 'branch_name': 'chunk/hello-1-greet', 'project_id': None, 'skills': ['forge-lane'], 'goal_mode': None, 'model_override': None, 'provider_override': None}
  [2026-10-27 18:07] [run 1] claimed {'lock': 'Goons-Mac-mini.local:1394', 'expires': 1793121768, 'run_id': 1}
  [2026-10-27 18:07] [run 1] spawned {'pid': 52900, 'started_at': '|179312086846'}
  [2026-10-27 18:07] [run 1] heartbeat
  [2026-10-27 18:08] [run 1] heartbeat
  [2026-10-27 18:09] [run 1] blocked {'reason': 'other: chunk/hello-1-greet already has a MERGED PR (https://github.com/wielas/hello-forge/pull/5) — a lane never reopens one', 'kind': None, 'recurrences': 1, 'source_status': 'ready'}

Runs (1):
  #1   blocked      @forge-codex-lane  73s  2026-10-27 18:07
        → other: chunk/hello-1-greet already has a MERGED PR (https://github.com/wielas/hello-forge/pull/5) — a lane never reopens one
```

### Root checkpoint
*(not yet run)*

### Tool versions
*(not yet run — the versions at launch, then one line per move: date, tool,
old → new, and the next card it touched; at the root checkpoint and at the end
of M1, `codex --version; claude --version; uv --version` pasted)*

### Per chunk
*(not yet run — one entry per chunk: each verifier outcome with its hold or reasons, the mutation verdict, the merge, and any disagreement)*

### S-1
*(not yet run)*

### D-1
*(not yet run)*

### Digests
*(not yet run — seven lines, each with its delivered digest)*

### GATE-M1 probe
*(not yet run)*

### End of M1 — north star and ledger
*(not yet run)*

### Flip verdict
*(not yet run — clause by clause, each with the evidence above it names)*

## Amendments

**2026-10-03 — attempt 1 halted; what attempt 2 changes.**

*What happened.*
- Attempt 1's `RUN_START` was 2026-10-03T07:43:39Z.
- Its CHUNK-1 card (`t_da03d07a`) was implemented and pushed (PR #2, CI green,
  `ad3fd63`).
- At 11:13 local, the kernel's descendant fence refused the lane's handoff to
  the verifier (epic P24). No card reached the verifier, and nothing merged.
- PR #2 had also re-sorted three frozen probe files (epic P25). The gate would
  have bounced it on that alone.
- The run was stopped and preserved under *Stop rules*. The evidence is
  `$P/.forge/run-a-attempt-1/`: the driver's transcript, the lane's tmp dir, a
  board copy, the card, PR #2 and the launch record.

*What changes for attempt 2.* Everything above this section stands, except the
following:
- **Forge runtime:** `origin/main` once S6d has merged and deployed, including
  `./hermes/profiles-bootstrap.sh`. It is recorded as the new launch record's
  `FORGE_SHA`.
- **Product:** `main` once Squatfather PR #3 has merged. PR #3 is the isort
  first-party pin and changes no frozen file. The new launch record's
  `PRODUCT_SHA` names it, and the tree must be clean.
- **Board:** `squatfather-run-a2`. Read every `squatfather-run-a` in
  *Preconditions*, *Launch*, the digest wrapper's line and *What is measured* as
  `squatfather-run-a2`. Attempt 1's board stays as evidence. Its one card is
  blocked and is never unblocked.
- **Preconditions 1–8 are re-run in full,** including a fresh `make commission`
  with `BOARD=squatfather-run-a2`. Attempt 1's commission certified a runtime
  that no longer runs.
- **Attempt 1's artifacts are moved aside before launch, and preserved.**
  - Tag `ad3fd63` as `run-a-attempt-1/chunk-1` and push the tag.
  - Close PR #2 with a pointer here.
  - Delete its branch, `chunk/1-store-owner-history-in-a-migrated-sqlite`,
    because attempt 2's CHUNK-1 reuses the name.
  - Remove the worktree `$P/.worktrees/t_da03d07a`.
- **Launch record:** attempt 2 writes `$P/.forge/run-a-launch.txt` afresh.
  Attempt 1's copy is in `$P/.forge/run-a-attempt-1/` and is pasted above,
  under *Results › Launch record*.
- **The driver makes the program's call.** Where the text above says the lane
  hands the card to `forge-verifier`, or the verifier bounces or holds it, the
  program now decides the transition. The driver then makes it through the one
  lifecycle tool the envelope names (S6d; ADR-0010 D10.3, amended 2026-10-03).
  Nothing an operator does changes.
- **PARK is read from the handoff summary.** Under the fence, a lane can no
  longer comment mid-run. So *What is measured*'s "every `PARK-COMMENT`" now
  means every `parked N×` line in a lane's handoff summary. That is the
  `review_requested` run's summary in `hermes kanban --board "$B" show <card>`.
- **A rehearsal comes before launch.** One hello chunk runs on a scratch board,
  in `~/dev/hello-forge`, through the real gateway. It passes only if a
  dispatcher-spawned lane hands off to `forge-verifier` through the tool path,
  and the verifier then ends in a hold or a bounce through the tool path. It is
  not part of run A: nothing measured reads from it.

**2026-10-26 — attempt 2, before launch: the rehearsal made executable, and the
inputs re-read.**

*Why.* The 2026-10-03 entry above says a rehearsal comes before launch, in one
sentence with no procedure. Nobody could run it without inventing one, and an
invented rehearsal is not a gate. This entry gives the procedure, the pass
check and the failure handling, and re-reads the inputs on the day S6d is
deployed. Nothing above is edited; where this entry and the text above differ,
this entry governs attempt 2.

*Inputs re-read on 2026-10-26.*
- **Forge:** `main` = runtime = `bd255a4` (S6d, #87), measured after the deploy:
  `make verify` 534 passed / 0 failed / 11 skipped; `make preflight` PASS 105 /
  WARN 4 / FAIL 0. That is a baseline, not the launch reading. The P25 PR (#88,
  the template's first-party pin, merged as `0ee3ab6`, one new verify case) and
  the PR that carries this entry both land after it, so `main` moves. After #88
  `main` is expected at `make verify` 535 / 0 / 11. The PR that carries this
  entry also updates `docs/state.md`'s recorded tool versions, so a preflight
  WARN for recorded-environment drift is expected to go. Precondition 2 is
  re-run after this PR merges (`git -C ~/dev/forge-runtime pull --ff-only`, then
  the `runtime=main` test), and precondition 3 is re-measured on that `main` and
  that deployed runtime. Its numbers, not 534 or 535, go in the launch record.
- **Product:** *Launch* step 1 says `HEAD` must be `388d78d`. For attempt 2 that
  is superseded by **`b66be28`** (Squatfather PR #3, the isort first-party pin,
  merged 2026-10-04; clean tree, CI green, `roadmap-check` CLEAR with 14 pass).
  It is the concrete SHA for what the 2026-10-03 entry left as `main` after
  PR #3. *Inputs*' `388d78d` row reads `b66be28`, and the launch record's `PRODUCT_SHA`
  must name it.
- **Tools (precondition 1: recorded, not pinned).** Expected at launch:
  codex-cli 0.164.0; Claude Code 2.1.310; gh 2.103.2; uv 0.13.5. Hermes is
  unchanged, 0.21.5 with local `1a3bee0e` (+1 carried commit); the `upstream`
  hash it prints moved to `9b904dcc` and is recorded, not compared (P23). A
  different value at `RUN_START` is written into the launch record and is not a
  stop. Never `hermes update`.
- **Models:** driver and router `z-ai/glm-5.3-flash`, Codex `gpt-5.6-luna`
  `xhigh`, as in *Inputs*; `scripts/model-pins.sh` and the live profiles agree.

*Launch step 3, the digest wrapper.* The wrapper `~/.hermes/scripts/forge-digest.sh`
is already scoped to `--board squatfather-run-a`, left from attempt 1. For attempt
2, precondition 5's edit is a change of board name, made only after
`squatfather-run-a2` exists (that is, after step 3's `board-bootstrap.sh`):
```bash
sed -i '' 's/--board squatfather-run-a /--board squatfather-run-a2 /' ~/.hermes/scripts/forge-digest.sh \
  && tail -1 ~/.hermes/scripts/forge-digest.sh   # must end: --board squatfather-run-a2 "$@"
```
Until then the digest reads attempt 1's board, which is harmless. Precondition
5 and *End of run A* step 3 say to "restore the line" when run A closes. Read
that as dropping the `--board squatfather-run-a2` argument, so the last line is
`exec bash "$HOME/.forge/repo/scripts/digest.sh" "$@"`: with no `--board`,
`digest.sh` reads every live board (its usage header).

*Attempt 1's artifacts, in order.* The 2026-10-03 entry names four actions and
gives no commands. This entry supplies them and **corrects their order**: git
refuses to delete a local branch that a worktree has checked out, so the
worktree goes before the branch. The tag goes first, because everything after it
destroys a pointer to `ad3fd63`. Run in `$P`:
```bash
P="$HOME/dev/the-squatfather"
SHA="$(git -C "$P" rev-parse --verify 'ad3fd63^{commit}')"        # must print one full SHA
git -C "$P" tag run-a-attempt-1/chunk-1 "$SHA"
gh api repos/wielas/Squatfather/git/refs -f ref=refs/tags/run-a-attempt-1/chunk-1 -f sha="$SHA" --jq .ref   # must print refs/tags/run-a-attempt-1/chunk-1
git -C "$P" ls-remote --tags origin 'run-a-attempt-1/*'           # must list the tag, at $SHA
gh pr close 2 --repo wielas/Squatfather --comment "Run A attempt 1 halted here (epic P24: the kernel's descendant fence refused the lane's hand-off). This PR is preserved as evidence at tag run-a-attempt-1/chunk-1 (ad3fd63) and is not to be merged. See docs/run-a.md in wielas/forge, Amendments, 2026-10-03."
git -C "$P" worktree remove .worktrees/t_da03d07a                 # no --force: if it refuses, stop and look
git -C "$P" branch -D chunk/1-store-owner-history-in-a-migrated-sqlite   # -D: never merged; the tag holds the commit
gh api -X DELETE repos/wielas/Squatfather/git/refs/heads/chunk/1-store-owner-history-in-a-migrated-sqlite
git -C "$P" fetch --prune origin
git -C "$P" ls-remote --heads origin 'chunk/1-*'                  # must print nothing; chunk/plan-roadmap (PR #1, merged) is left alone
git -C "$P" status --porcelain                                    # must print nothing
```
Attempt 1's card `t_da03d07a` stays `blocked` on `squatfather-run-a` and is never
unblocked; its evidence stays in `$P/.forge/run-a-attempt-1/`.

*The hello-forge rehearsal.* A real chunk through the real gateway: dispatcher,
`forge-codex-lane`, `forge-verifier`, on a scratch board and a scratch repository.
It costs what a small run costs: one Codex run on a one-function chunk, one
verifier scorer call (`claude -p`), two driver sessions. Run it alone, as
commission is run alone. **Order before `RUN_START`:** the P25 PR and the PR that
carries this entry merge; precondition 2 (deploy) and 3 (suites, re-measured);
then 4, 5 (the edit waits), 6 and 8; then the rehearsal below; then attempt 1's
artifacts above; then precondition 7 (commission); then *Launch*. A failed
rehearsal therefore costs no commission probe.

*A note on pushes from these repositories.* `hello-forge` and `the-squatfather`
both carry the template's pre-push hook, whose `no-main-push` refuses **every**
push made while `main` is checked out, a tag or a branch deletion included (read
from each `lefthook.yml`, not run). Any ref this entry creates or deletes on a
remote from a checkout of `main` therefore goes through `gh api`, and no hook is
bypassed. The one `git push` below is from a branch other than `main`.

*R0. Preconditions.* All must hold; any other result is a stop. The variables are
exported because the second terminal in R3 needs them too.
```bash
export H="$HOME/dev/hello-forge" R=wielas/hello-forge RB=hello-rehearsal-a2
export P="$HOME/dev/the-squatfather"; export EV="$P/.forge/run-a-attempt-2-rehearsal"; mkdir -p "$EV"

hermes gateway status | sed -n 2,3p     # supervised by launchd
hermes kanban boards list --all --json | jq --arg s "$RB" 'any(.[]; .slug == $s)'   # must print false
# Both assignees must be real profiles, not merely names a card once carried.
hermes kanban assignees --json | jq -e 'map(select(.name | IN("forge-codex-lane","forge-verifier")) | select(.on_disk)) | length == 2'   # true
```
- The board slug is fresh and is used once. `forge-hello` (two old `done` cards,
  from 2026-07-28) is left alone.
- Precondition 8's loop, as written above and with attempt 2's board name,
  prints nothing. The gateway runs one card at a time, across every board, so a
  card elsewhere would take the rehearsal's slot.
- `$H` is on `main`, clean, and behind-or-equal `origin/main` (R1 fast-forwards
  it). Today it is one commit behind: local `582455c`, `origin/main` `7b3532a`.
  ```bash
  git -C "$H" fetch origin
  git -C "$H" branch --show-current                    # must print: main
  git -C "$H" status --porcelain                       # must print nothing
  git -C "$H" merge-base --is-ancestor HEAD origin/main && echo ancestor-ok   # must print: ancestor-ok
  ```

*R1. Reset hello-forge so the card has real work.* `origin/main` already holds
CHUNK-HELLO-1: PR #5 (merged 2026-09-02) added `greet(name)`, its feature file and
its steps, as the one squash commit `7b3532a`. A card run against that tree has
nothing to implement and would pass while testing almost none of the chain. The
two earlier rehearsals reset the same way, by a revert PR (#2, then #4, whose
body states the proof used below). `main` is protected (a PR, required check
`check`, strict, admins included, no force-push or deletion; read 2026-10-26), so
the reset is a PR with green CI, not a push.
```bash
git -C "$H" switch main && git -C "$H" pull --ff-only             # 582455c -> 7b3532a
git -C "$H" switch -c rehearsal/reset-for-fourth-proof
git -C "$H" revert --no-edit 7b3532a                              # a squash commit has one parent: no -m
git -C "$H" diff --stat 582455c HEAD                              # must print nothing: the tree is the pre-PR-#5 tree
git -C "$H" push -u origin rehearsal/reset-for-fourth-proof
gh pr create --repo "$R" --base main --head rehearsal/reset-for-fourth-proof \
  --title "rehearsal: revert PR #5 so the hello-1 card has real work again" \
  --body "Resets the rehearsal target for run A attempt 2. Reverts 7b3532a; the resulting tree is byte-identical to 582455c (git diff 582455c HEAD is empty)."
N1="$(gh pr list --repo "$R" --head rehearsal/reset-for-fourth-proof --json number -q '.[0].number')"; echo "$N1"
gh pr checks "$N1" --repo "$R" --watch                            # wait for green
gh pr merge "$N1" --repo "$R" --squash --delete-branch
git -C "$H" switch main && git -C "$H" pull --ff-only
git -C "$H" branch -D rehearsal/reset-for-fourth-proof            # squash merges leave it unmerged by git's reckoning
git -C "$H" diff --stat 582455c HEAD                              # must print nothing, again
test ! -e "$H/src/hello_forge/greet.py" && echo greet-absent
```
Then the stale branch. `chunk/hello-1-greet` still exists on the remote at
`d874e3b`, the pre-squash commit of PR #5. The lane's push would meet it and
block `env:`. Nothing is open on it:
```bash
gh pr list --repo "$R" --head chunk/hello-1-greet --state open    # must print nothing
gh api -X DELETE "repos/$R/git/refs/heads/chunk/hello-1-greet"
git -C "$H" fetch --prune origin
git -C "$H" ls-remote --heads origin                              # must list refs/heads/main only
git -C "$H" status --porcelain                                    # must print nothing (the lane refuses a dirty baseline, exit 5)
```
No local `chunk/hello-1-greet` exists today (`git -C "$H" branch -a`).

*R2. Create the board and the card.* `board-bootstrap.sh --hello` is the sanctioned
way and does not need a roadmap: it skips graph validation in this mode, and it
is how `forge-hello` was made (README, *Day-one risk burn-down*). It is not
covered by `make verify`, so read its output. Run it from the repository root,
because it takes the board's workdir from `git rev-parse --show-toplevel`:
```bash
cd "$H" && ~/.forge/repo/hermes/board-bootstrap.sh "$RB" --hello
```
It creates the board, sets `default_workdir` to `$H` and reads it back, refuses
unless `forge-codex-lane` is an on-disk profile, then creates one card. It does
not read the card back; the readback below does. The card is the same call
`forge-hello`'s was, which is the equivalent raw form (the body is the text of the
script's `--hello` heredoc, saved as `$EV/hello-card-body.md`; `--board` goes
**before** the subcommand, field notes):
```bash
hermes kanban --board "$RB" create "CHUNK-HELLO-1: Add greet(name) with a BDD scenario" \
  --assignee forge-codex-lane --body "$(cat "$EV/hello-card-body.md")" \
  --workspace worktree --branch chunk/hello-1-greet \
  --max-retries 1 --idempotency-key hello-1 --skill forge-lane
```
Find the card's id **without `list`**, which runs `recompute_ready` and so writes.
Snapshot the board and read the idempotency key (a fresh directory each time:
`board-snapshot.sh` refuses one that already holds a database), then read the
card back before the next dispatch tick (60 s). A mismatch is a FAIL of the
rehearsal's own setup:
```bash
export ID="$(sqlite3 "$(~/.forge/repo/scripts/board-snapshot.sh "$HOME/.hermes/kanban/boards/$RB/kanban.db" "$(mktemp -d "$EV/board.XXXXXX")")" "select id from tasks where idempotency_key='hello-1'")"; echo "$ID"
hermes kanban --board "$RB" show "$ID" --json | jq -e '
  .task | .assignee == "forge-codex-lane" and .workspace_kind == "worktree"
  and .branch_name == "chunk/hello-1-greet" and .max_retries == 1 and .skills == ["forge-lane"]'   # true
```
The card is `ready` on a real, spawnable profile, so the next dispatch pass claims
it. Nothing else is done by hand from here until a verdict.

*R3. Watch it.* In a second terminal, first set the same variables again (the new
shell has none), then any of the commands after them:
```bash
export H="$HOME/dev/hello-forge" R=wielas/hello-forge RB=hello-rehearsal-a2
export P="$HOME/dev/the-squatfather"; export EV="$P/.forge/run-a-attempt-2-rehearsal"
export ID="$(sqlite3 "$(~/.forge/repo/scripts/board-snapshot.sh "$HOME/.hermes/kanban/boards/$RB/kanban.db" "$(mktemp -d "$EV/board.XXXXXX")")" "select id from tasks where idempotency_key='hello-1'")"

hermes kanban --board "$RB" watch                    # every event, live (Ctrl+C to leave)
hermes kanban --board "$RB" tail "$ID"               # this card's events
hermes kanban --board "$RB" runs "$ID"               # one row per run: profile, outcome, summary
hermes kanban --board "$RB" log "$ID"                # the worker's raw output
gh pr list --repo "$R"                               # the lane opens the PR from chunk/hello-1-greet
```
Expect, in order: `claimed`, `spawned`, `heartbeat`s, `review_requested` (the lane
hands off; a small chunk took 4 minutes on 2026-07-28), then `claimed` again by
`forge-verifier`, then `blocked` or `changes_requested`. The verifier waits for
CI (up to 10 minutes), runs the merged-tree check and the scorer. Allow 60
minutes from creation. After that with no verdict, it is a FAIL, unless the log
shows a Codex usage-limit park: a park resumes itself, as *Stop rules* says.

*R4. The pass check.* The rehearsal passes only if every command below prints
`true` (jq) or the stated output, on the card as it stands at the verifier's
verdict. Read the board through `show`, which does not write. Never open a board
or a profile database `mode=ro`: they are WAL, and a read-only open fails when the
database is idle. Snapshot with `scripts/board-snapshot.sh`, which `cp`s the file
and opens the copy, then query the copy. Do not use `list` for evidence: it runs
`recompute_ready`, which writes. Every snapshot goes into a **fresh** directory,
as below: the script refuses one that already holds a database, so a second
attempt into the same name fails.

*Wait for the verdict, and for the verifier's session to be flushed.* The tool
result is written to the profile's `state.db` as the driver's turn ends, which can
trail the board event. Wait until the verifier's run has ended, then two minutes
more, before the first snapshot. (Interrupt at 60 minutes from creation: that is
R3's FAIL.)
```bash
until hermes kanban --board "$RB" show "$ID" --json | jq -e '[.runs[] | select(.profile == "forge-verifier")] | last | .ended_at != null' >/dev/null; do sleep 30; done; sleep 120
N="$(gh pr list --repo "$R" --head chunk/hello-1-greet --state open --json number -q '.[0].number')"; echo "PR $N"   # the three older PRs on this branch name are merged, so open means this one
```

*The lane handed off through the tool, spawned by the dispatcher:*
```bash
S="$EV/show.json"; hermes kanban --board "$RB" show "$ID" --json > "$S"
jq -e '
  ([.events[].kind] | index("review_requested")) as $i
  | $i != null
    and ([.events[:$i][].kind] | index("spawned") != null)
    and ([.events[:$i][].kind] | any(IN("blocked","crashed","timed_out","reclaimed","gave_up")) | not)
    and (.events[$i].payload | .implementer == "forge-codex-lane" and .reviewer == "forge-verifier")
    and ([.runs[] | select(.outcome == "review_requested")] | length == 1)
    and ([.runs[] | select(.outcome == "review_requested")][0]
         | .profile == "forge-codex-lane"
           and .metadata.schema == "forge.chunk.v1"
           and (.metadata.worker_session_id | type == "string" and length > 0))
' "$S"
```
What that proves. `spawned` precedes the hand-off, so the dispatcher made the
worker. The `review_requested` event names `forge-verifier` explicitly (a missing
reviewer would leave the card in review on the lane itself). Nothing blocked or
crashed first, so the `on_error` fallback did not land. The run's metadata is
the program's `forge.chunk.v1` envelope, passed verbatim (the key `lane.sh`'s
own parent guard reads). And the run carries `worker_session_id`, which only the
worker tool handler stamps and the CLI never does (field notes, *A worker's
terminal is fenced*; `kanban_tools.py` `_stamp_worker_session_metadata`). The
session itself says the same. A tool result is stored in `messages.content` as
the handler's JSON, `json.dumps` with its default spacing (`{"ok": true, "task_id": …,
"status": …}`; read from `kanban_tools.py` `_ok`/`_ok_landed` and from attempt 1's
stored `kanban_block` row), so the checks parse it with `json_extract` and do not
match on spacing:
```bash
SID="$(jq -r '.runs[] | select(.outcome == "review_requested") | .metadata.worker_session_id' "$S")"
LS="$(~/.forge/repo/scripts/board-snapshot.sh "$HOME/.hermes/profiles/forge-codex-lane/state.db" "$(mktemp -d "$EV/lane-state.XXXXXX")")"
sqlite3 "$LS" "select count(*) from messages where session_id='$SID' and role='tool' and tool_name='kanban_request_review' and json_valid(content) and json_extract(content,'\$.ok')=1"   # must print 1
sqlite3 "$LS" "select count(*) from messages where session_id='$SID' and (tool_name='kanban_block' or content like '%cannot mutate Kanban%' or tool_calls like '%HERMES_KANBAN_TASK%')"   # must print 0
test -s "$HOME/.forge/lane-sessions/$RB-$ID.metadata.json" && echo lane-copy-OK   # must print lane-copy-OK
```
The zero rules out three things: the fallback block, the fence's refusal
(`kanban: delegate_task child contexts cannot mutate Kanban tasks via the CLI`)
and a driver that exported the scrubbed variables, which attempt 1's did. The
last line is the lane's host copy of its own hand-off, which the verifier compares.

*The verifier claimed the review and ended it through the tool:*
```bash
jq -e '
  ([.events[].kind] | index("review_requested")) as $i
  | ([.events[$i+1:][] | select(.kind == "claimed")][0]) as $c
  | $c != null and $c.payload.source_status == "review"
    and ([.runs[] | select(.profile == "forge-verifier")] | length >= 1)
    and ( ( .task.status == "blocked"
            and ([.events[] | select(.kind == "blocked")] | last | .payload.reason | startswith("merge-pending:"))
            and ([.runs[] | select(.profile == "forge-verifier")] | last | .outcome == "blocked") )
          or
          ( ([.events[$i+1:][] | select(.kind == "changes_requested")] | length) == 1
            and ([.runs[] | select(.profile == "forge-verifier")] | last | .outcome == "changes_requested") ) )
' "$S"
```
A review claim's `claimed` event carries `source_status: review` (field notes).
The two arms are the two allowed endings. **A hold:** the card is `blocked` and
its last `blocked` event's reason starts `merge-pending:` (the decision-first
recommendation, naming the PR). **A bounce:** exactly one `changes_requested`
event after the claim, and the verifier's run has that outcome. Either passes. A
`blocked` event of any other class (`gate-unrunnable`, `handoff-integrity`,
`env:`, `other:`) is the fallback or a substrate fault, not a verdict, and fails
the check. A `touches` warning in the gate is not a failure: the card's
`Touches:` line names a placeholder (`src/<package>/greet.py`) and omits
`__init__.py`, and `prejudge.sh` treats that check as advisory. The session
proves the tool, not the board:
```bash
CT="$(jq -r '([.events[].kind] | index("review_requested")) as $i | [.events[$i+1:][] | select(.kind == "claimed")][0].created_at' "$S")"
VS="$(~/.forge/repo/scripts/board-snapshot.sh "$HOME/.hermes/profiles/forge-verifier/state.db" "$(mktemp -d "$EV/verifier-state.XXXXXX")")"
VSID="$(sqlite3 "$VS" "select id from sessions where source='kanban' and started_at >= $CT - 5 order by started_at limit 1")"; echo "$VSID"
sqlite3 "$VS" "select count(*) from messages where session_id='$VSID' and role='tool' and json_valid(content) and json_extract(content,'\$.ok')=1 and ((tool_name='kanban_block' and json_extract(content,'\$.status')='blocked') or (tool_name='kanban_request_changes' and json_extract(content,'\$.status')='ready'))"   # must print 1
sqlite3 "$VS" "select count(*) from messages where session_id='$VSID' and (content like '%cannot mutate Kanban%' or tool_calls like '%HERMES_KANBAN_TASK%')"   # must print 0
test "$(jq -r '.task.status' "$S")" != blocked || { test -s "$HOME/.forge/verdicts/$RB-$ID.json" && echo verdict-file-OK; }   # a HOLD must print verdict-file-OK; after a bounce this prints nothing and that is not a failure
gh pr view "$N" --repo "$R" --json state,headRefName,url -q '[.state,.headRefName,.url] | @tsv'   # OPEN, chunk/hello-1-greet, and the URL the hold names
```
(`kanban_block` and `kanban_request_changes` do not stamp `worker_session_id`,
unlike `kanban_request_review`, so the verifier's session is found by time, not by
a stored id.) Paste every command's output into *Results › Launch record ›
Attempt 2*, above the launch record. Nothing is summarised.

*R5. A bounce respawns the lane.* After `changes_requested` the card is `ready`
on `forge-codex-lane`, and the next dispatch pass (within 60 s) starts a second
Codex run, which proves nothing the first did not. **The default is to stop it
at once, before collecting evidence:**
```bash
hermes kanban --board "$RB" block --kind needs_input "$ID" "rehearsal: verdict recorded, no further rounds"
```
`block` moves only a `running` or `ready` card (`kanban_db.py` `block_task`); it
is a no-op on one in `review`. A card in `review` (a lane that handed off and a
verifier not yet claimed, or one that never claims) is stopped by unassigning it
instead: the dispatcher only spawns an assigned card, and `assign` accepts
`none` and is refused only for a card `running` under a claim (`kanban.py`
`_cmd_assign`, `kanban_db.py` `assign_task`: it clears `assignee`, leaves the
status, and records an `assigned` event):
```bash
hermes kanban --board "$RB" assign "$ID" none
hermes kanban --board "$RB" show "$ID" --json | jq -e '.task.assignee == null'   # must print true
```
That is read from the source, not run on a `review` card; the second command is
the check that it held. If it prints `false`, stop and tell the operator; do not
improvise another way to stop the dispatcher. If you would rather watch
the second round of a bounce, say so before starting; it spends Codex again. A hold
needs no such step: the card is already `blocked`.

*R6. If any check fails: stop, and leave everything where it is.* No commission,
no `RUN_START`, no relaunch, no workaround, no unblocking, and **no R7**. This is
*Stop rules* applied: "preserve everything: the board, worktrees, PRs" and
"diagnose before unblocking or rerunning". A failing rehearsal is the finding
that this entry exists to produce. The cause is diagnosed in its own session
and fixed through a slice, as attempt 1's was.
- If the card is still `running` or `ready`, block it with R5's command; if it
  is in `review`, unassign it with R5's `assign … none`. Either stops the
  dispatcher spawning it, and that is the only write.
- Copy the evidence out, leaving the originals: `$S`, the two snapshot
  directories under `$EV`, `hermes kanban --board "$RB" log "$ID" > "$EV/worker.log"`,
  `hermes kanban --board "$RB" runs "$ID" --json > "$EV/runs.json"`,
  `gh pr list --repo "$R" --head chunk/hello-1-greet --state open --json number,state,headRefName,statusCheckRollup,url > "$EV/pr.json"`
  (empty if the lane never opened one), the lane's tmp dir (`forge-lane-sh.*` under its `TMPDIR`;
  attempt 1 kept it as `lane-tmp`), and whatever of
  `~/.forge/{lane-sessions,verdicts,lane-audits,lane-parks}/` names the card.
- The worktree `$H/.worktrees/$ID`, the board, the PR and the branch
  `chunk/hello-1-greet` stay as they are.
- Paste the failing command and its output into *Results*, under *Launch record ›
  Attempt 2*, headed "Rehearsal failed".
- To run it again after a repair is merged and deployed: first do R7 on the
  failed run (it is the diagnosis's last step, not the first), then R0 with a
  **new slug** (`hello-rehearsal-a2b`), because the first slug is spent. R1's
  revert does not repeat, since R7 closes the lane's PR unmerged and `main` is
  still the reset tree.

*R7. Clean up: after a PASS, or after a failure's diagnosis is closed.* The order
matters. The merge-watcher sweeps every board every ten minutes: a `blocked` card
whose PR is then closed unmerged would be reported once as a decision, so the
card leaves the board's blocked set before the PR is closed. (A bounce that R5
has not yet stopped is stopped first.) Evidence is copied before any of it, as
in R6. Run the `gh` commands from a directory that is not `$H`, so that
`--delete-branch` deletes the remote branch only and does not touch the local
one, which still has a worktree on it:
```bash
N="$(gh pr list --repo "$R" --head chunk/hello-1-greet --state open --json number -q '.[0].number')"; echo "PR $N"
hermes kanban --board "$RB" archive "$ID"
gh pr close "$N" --repo "$R" --delete-branch --comment "Run A attempt 2 rehearsal: verdict recorded, closed unmerged."
git -C "$H" worktree remove ".worktrees/$ID"          # no --force: if it refuses, stop and look
git -C "$H" branch -D chunk/hello-1-greet
git -C "$H" fetch --prune origin
hermes kanban --board "$RB" show "$ID" --json | jq -e '.task.status == "archived"'   # must print true, BEFORE the board is archived
hermes kanban boards rm "$RB"                         # archives under boards/_archived/; never --delete, and no command un-archives it
```
Then confirm the state the next rehearsal and *Launch* both assume:
```bash
git -C "$H" status -sb                                # ## main...origin/main, nothing else
git -C "$H" worktree list                             # $H only
git -C "$H" ls-remote --heads origin                  # refs/heads/main only
hermes kanban boards list --all --json | jq --arg s "$RB" 'any(.[]; .slug == $s and (.archived | not))'   # false
```
Precondition 8's loop reads only live boards, so once the board is archived it
can no longer see it. The `archived` check on the card, run before `boards rm`,
is what stands in for it: a `ready` card left on that board would otherwise be
invisible. Re-run the loop all the same; it must print nothing.

*Decisions this entry makes that the operator may overrule before launch.*
- Reset by a revert PR of `7b3532a` (the precedent of #2 and #4); the
  protection allows no other route.
- `board-bootstrap.sh --hello` creates the card, rather than a hand-typed
  `create`. It is the path that made `forge-hello`'s card. It reads back the
  workdir and checks the assignee is an on-disk profile; R2's own readback covers
  the card.
- Evidence under `$P/.forge/` (ignored, beside attempt 1's), not in either repository.
- A bounce is stopped after its first round (R5).
- A failed rehearsal leaves the board, worktree, PR and branch in place (R6);
  only a pass cleans up at once.
- The rehearsal sits after precondition 8 and before commission (7), so a
  failed rehearsal costs no commission probe.

**2026-10-27 — attempt 2, rehearsal 1 failed at R3/R4; a branch name is spent
for ever; what rehearsal 2 and the launch change.**

*Why.* The 2026-10-26 entry made the rehearsal a procedure, and the procedure
did its job: it failed before commission, so no commission probe was spent. It
failed on a premise the entry got wrong. This entry corrects the premise,
supersedes the lines that depend on it, and gives the second rehearsal and the
launch their new commands. Nothing above is edited. Where this entry and the text
above differ, this entry governs attempt 2. **Line numbers below are those of
this file at `ad0c03e`** (`git show ad0c03e:docs/run-a.md`), the file as the
2026-10-26 entry left it on `main`; this entry's own Results insertion moves
later lines. Step names are given beside them.

*What rehearsal 1 found.* Board `hello-rehearsal-a2`, card `t_412a7d2c`.
- The lane did its work. Its run took 73 s: Codex ran, `make check` passed and
  the lane pushed `46fabde`. Then it blocked, `other: chunk/hello-1-greet already has a
  MERGED PR (…/pull/5) — a lane never reopens one`.
- **The cause is `scripts/lane.sh` 485-507, and it runs after the paid run.**
  The lane pushes, then asks `gh pr view "$BRANCH"`. An OPEN PR is adopted; none
  means it creates one; any other state blocks. `gh pr view` on a branch name
  finds a MERGED PR that was merged from that name. Observed: R1 deleted the
  remote branch and the lane pushed it afresh, and `gh pr view` still returned
  MERGED PR #5. `chunk/hello-1-greet` carries MERGED PRs #1 (2026-07-28), #3 and #5
  (both 2026-09-02) on `wielas/hello-forge`.
- **R1's premise was wrong.** R1 (the "Then the stale branch" paragraph and its
  commands, lines 698-708) held that deleting the stale remote branch was enough
  for the lane to run. It was deleted, the lane ran, and the name was still
  spent. A PR's head name outlives the branch.
- **R1's precedent was wrong too, and the reason is dated.** Three earlier
  rehearsals reused `chunk/hello-1-greet`, which made reuse look safe. The arm
  that blocks came in with epic S2 (`68724a4`, 2026-09-26: `git log -S 'a lane
  never reopens one' -- scripts/lane.sh`), after all three PRs had merged. They
  ran under a lane that did not have it. The same wrong reason sits in the
  2026-10-03 entry (lines 537-538: delete the branch "because attempt 2's CHUNK-1
  reuses the name") and in the 2026-10-26 cleanup (lines 622-625), which carried
  it out. Those deletions were harmless and are done; what is superseded is the
  belief that they freed the name.
- **What it did prove.** S6d's driver tool path works for a block. The stored
  `kanban_block` result is `{"ok": true, "task_id": "t_412a7d2c", "run_id": 1,
  "status": "blocked", "block_kind": null}`, and the fence strings count is 0.
  The dispatcher spawned the lane, and the lane ended its run through the tool.
- **What it did not prove.** R4's first check printed `false`, because the lane
  blocked before any hand-off. The hand-off leg, the verifier's claim and its
  verdict through the tool path were not reached. Rehearsal 2 must still pass.
- The evidence is `~/dev/the-squatfather/.forge/run-a-attempt-2-rehearsal/`:
  `board-snapshot-hello-rehearsal-a2/` (before the archive),
  `board-snapshot-hello-rehearsal-a2-post-archive/`, `card-t_412a7d2c-final.txt`,
  `r4-lane-failure.out`, `worker.log`, `runs.json`, `show.json`. The two files
  R6 asks to be pasted are under *Results › Launch record › Attempt 2*.

*Cleanup done on 2026-10-27, and read afterwards.*
- Tag `run-a-attempt-2/rehearsal-1` → `46fabde8915a817bb8e5fac9edbdcb37f1b28342`
  on `wielas/hello-forge` (`git ls-remote --tags origin 'run-a-attempt-2/*'`).
- The card is archived; the local and remote branch are deleted; `boards rm`,
  without `--delete`, moved the board to
  `~/.hermes/kanban/boards/_archived/hello-rehearsal-a2-1793132425`.
- `hello-forge` `main` is `81d9b23` (PR #6, the revert of #5), clean, and the only
  remote head. `git diff --stat 582455c 81d9b23` prints nothing and `greet.py` is
  absent: R1's revert is done and is **not repeated**.
- Attempt 1's cleanup (the 2026-10-26 entry's commands, lines 609-627) was also
  run on 2026-10-27, read afterwards in `$P`: the tag
  `run-a-attempt-1/chunk-1` → `ad3fd6399c2760d33c3940b542824b28639f0821` is local
  and on the remote; PR #2 is CLOSED, `closedAt` 2026-10-27T17:02:23Z; the remote
  heads are `main` and `chunk/plan-roadmap` only; `git worktree list` shows `$P`
  alone and `$P/.worktrees` does not exist; `git status --porcelain` is empty at
  `b66be28`. No earlier text dates the close of PR #2; this is its date.

*Two substrate behaviours rehearsal 1 taught.* Both are read from Hermes 0.21.5's
source and were seen on 2026-10-27.
1. **Archiving a card reaps its worktree** when the tree is clean and every commit
   is reachable from a remote-tracking ref (`kanban_db.py` `archive_task`, last
   statement `_cleanup_workspace`; `kanban_db_workspace.py`
   `_cleanup_worktree_workspace`, which keeps a dirty or unpushed worktree, keeps
   a custom branch, and deletes only a `wt/…` one). The 2026-10-27 cleanup could
   not read the worktree's `status` first, because the archive had removed it.
   Nothing was lost: the tip was tagged beforehand. R7 as written (lines 925-928)
   archives at line 925 and then runs `git worktree remove` at line 927, which has
   nothing to remove. **Rule:** before archiving any card that has a worktree,
   record `git -C <wt> status --porcelain` and `rev-parse HEAD`, and make sure the
   tip is tagged or pushed.
2. **`hermes kanban boards rm` without `--delete` is a soft move** to
   `boards/_archived/<slug>-<epoch>/` (`kanban_db.py` `remove_board`). The data
   stays on disk. The digest skips `_archived` and cannot read the board by name
   afterwards (below).

*The same collision awaits run A, and a rule follows from it.* Read on 2026-10-27
with `gh pr list --state all --head <name>` on `wielas/Squatfather`, whose PRs are
only #1, #2 and #3:
- CHUNK-1's computed branch, `chunk/1-store-owner-history-in-a-migrated-sqlite`,
  has PR #2, CLOSED. Attempt 2's CHUNK-1 would have run, passed and pushed, then
  blocked after the paid run, exactly as rehearsal 1 did.
- CHUNK-2 to CHUNK-5's computed names have no PR:
  `chunk/2-vendor-the-garmin-exercise-catalogue-with`,
  `chunk/3-summarise-the-week-and-diff-plans`,
  `chunk/4-build-the-baseline-plan-and-validate-plans`,
  `chunk/5-guard-every-model-payload-behind-one-audited`.
- **Rule, from now on: every attempt uses branch names that have never been used,
  whatever their PR state.** A name is used once any card carried it, whether or
  not the lane got as far as a push. An attempt is a rehearsal, a launch or a
  relaunch, and each gets its own suffix through `--branch-suffix`.

*P30, the code that makes the rule mechanical* (epic P30, commit `bdd1461`, the
first commit of the PR that carries this entry).
- **The flag.** `board-bootstrap.sh <board> [full|--root-only|--hello]
  --branch-suffix <s>` appends `-<s>` to every lane card's branch, after the slug
  is cut to its 48-letter budget, so the suffix is never the part cut. `<s>` is a
  lowercase slug, `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 32 characters; anything else
  is refused with exit 1 before anything is written. The flag may come before or
  after the mode.
- **The guard.** Before the first card is created, for each card it is about to
  create that carries a branch, it asks GitHub `gh pr list --repo <origin> --head
  <branch> --state all` (every PR in any state) and `git ls-remote --heads origin
  <branch>`. It prints `free     <branch>` for a clear name. It refuses with **exit
  3** when the branch has any PR or exists on the remote, **exit 2** when it could
  not ask (no GitHub `origin`, `gh` or `ls-remote` failed, the board's card list
  unreadable, an answer that is not JSON), and **exit 1** for a bad suffix or any
  other FATAL. Exit 2 is not "free". A refusal creates no card.
- **Existing cards pass.** A card already on the board, matched by title and
  branch, is printed `exists   <branch> (already a card on board …; not asked)`
  and is not asked about. That is what lets Launch step 5 re-visit the root, whose
  branch by then has an open PR.
- **Caveat 1.** A refusal can leave an empty board behind: the board, its
  workdir and the assignee check are idempotent and run first, because telling an
  existing card from a new one needs the board's card list. It holds no card.
- **Caveat 2.** The suffix must be **identical** on every bootstrap run of one
  board. It is part of how an existing card is recognised.
- **Caveat 3.** Interactive cards and gates carry no branch, so the suffix does
  not reach them. For run A that is fine except CHUNK-5, below.
- The guard needs a GitHub `origin` in the repository it is run from.
- With `a2`, CHUNK-1 is `chunk/1-store-owner-history-in-a-migrated-sqlite-a2`.
  With `a2b`, the hello chunk is `chunk/hello-1-greet-a2b`. Read-only checks on
  2026-10-27 found no PR (`--state all`) and no remote branch for either name.
- **Deploy.** The commit touches `hermes/board-bootstrap.sh` and
  `scripts/verify.sh` only; no profile file, so precondition 2's
  `profiles-bootstrap.sh` clause does not apply. **Until the deploy, the old
  script silently ignores the flag**: it reads `$1` and `$2` and nothing else, so
  `--hello --branch-suffix a2b` would create the card on the spent name, and the
  dispatcher can claim it within 60 s. Hence the check at the start of R2 and of
  Launch step 3. (Do not run the script with `--help` to test: the old one reads
  `--help` as a board name.)

*FORGE_SHA and the frozen pins.* Following the 2026-10-26 entry's reading of how
`main` moves:
- **`FORGE_SHA` is the merge commit of the PR that carries this entry** (squash,
  so not `bdd1461`), or a later `main` if more PRs land first. Neither
  `bd255a4` (the 2026-10-26 baseline) nor `ad0c03e` (the pre-launch amendment)
  is it. Precondition 2 is re-run after this PR merges: `git -C
  ~/dev/forge-runtime pull --ff-only`, then the `runtime=main` test.
  The launch record's `FORGE_SHA` is whatever `git -C ~/.forge/repo rev-parse
  HEAD` prints at *Launch* step 2, and it must equal `git -C ~/dev/forge rev-parse
  HEAD`.
- *Inputs*' **Forge runtime** row (line 41) reads "this PR's merge commit, or a
  later `main`". Its baseline, expected `make verify` 535 / 0 / 11 in the
  2026-10-26 entry, becomes **547 / 0 / 11** on this PR's head (the code slice's
  reading; this entry changes no check). Precondition 3 is still re-measured on
  the deployed `main`, and its numbers go in the launch record.
- **`PRODUCT_SHA` stays `b66be28`** (the 2026-10-26 entry). Nothing in
  `the-squatfather` changes: the suffix is applied at bootstrap.

*Precondition 8 is replaced (lines 113-128, the loop at 122-127).* The old loop
runs `hermes kanban list` on every other board. `list` calls `recompute_ready`,
so it **writes** to boards that are not run A's; the rehearsal's own note on
`list` (R2) applies to it. The replacement snapshots each board with
`scripts/board-snapshot.sh` and queries the copy. The default board's database is
`~/.hermes/kanban.db`, as `scripts/digest.sh` 230 has it (`[ "$BOARD" = default ]
&& db="$HERMES_ROOT/kanban.db"`); `~/.hermes/kanban/kanban.db` exists but is
zero bytes and is not a board. Named boards are
`~/.hermes/kanban/boards/<slug>/kanban.db`, and `_archived` is skipped.
```bash
SKIP=squatfather-run-a2      # run A's own board; before the rehearsal's board exists, SKIP=-
S8="$(mktemp -d)"; n=0; sk=0; m="$(hermes kanban boards list --json | jq length)"
for db in "$HOME/.hermes/kanban.db" "$HOME"/.hermes/kanban/boards/*/kanban.db; do
  b="$(basename "$(dirname "$db")")"; [ "$db" = "$HOME/.hermes/kanban.db" ] && b=default
  [ "$b" = "$SKIP" ] && { sk=$((sk+1)); continue; }
  snap="$(~/.forge/repo/scripts/board-snapshot.sh "$db" "$(mktemp -d "$S8/$b.XXXXXX")")" || { echo "UNREADABLE $b"; continue; }
  n=$((n+1))
  sqlite3 "$snap" "select '$b', id, status, coalesce(assignee,'-') from tasks where status in ('running','review') or (status='ready' and assignee is not null)"
done
[ $((n+sk)) -eq "$m" ] || echo "COUNT-MISMATCH: read $n, skipped $sk, hermes lists $m"
rm -rf "$S8"
```
**Pass check: it prints nothing.** A row is a card that could take run A's slot; a
`UNREADABLE` or `COUNT-MISMATCH` line is a board that was not read, and fails the
check as a row does. Read on 2026-10-27 it read all 8 live boards and printed
nothing. Attempt 1's `t_da03d07a` is `blocked`, so it does not match, and a card
intentionally parked in `blocked` never will. The only reading that excuses a row
is a card the operator parked on purpose and names beside the output. Wherever
the 2026-10-26 entry says to run precondition 8's loop (R0, lines 661-663; R7,
lines 940-943), run this one.

*Order before `RUN_START` (supersedes lines 635-639).* The P30 PR and its deploy
(precondition 2, plus the check below); precondition 3, re-measured; 4, 5 (the
edit waits), 6 and the new 8; **rehearsal 2** (R0 to R7 as amended below); 7
(commission); **the disposition of `t_da03d07a`, steps T1 to T4**; then *Launch*,
whose step 3 now ends with T5. Attempt 1's artifacts (lines 609-627) are already
done. A failed rehearsal still costs no commission probe.

*The deployed script knows the flag.* Run before R2 and before Launch step 3:
```bash
grep -c -- '--branch-suffix' ~/.forge/repo/hermes/board-bootstrap.sh   # must print a number greater than 0
test "$(git -C ~/.forge/repo rev-parse HEAD)" = "$(git -C ~/dev/forge rev-parse HEAD)" && echo runtime=main
```

**Rehearsal 2.** R0 to R7 stand as the 2026-10-26 entry wrote them, except for
the following, which supersede by line and step.

- **R0 (lines 651, 747 — both variable blocks, R0 and R3).** `RB=hello-rehearsal-a2b`,
  with a second variable, `BR=chunk/hello-1-greet-a2b`, exported beside it. The
  evidence directory is `EV="$P/.forge/run-a-attempt-2-rehearsal-2"` (a new one:
  the first holds rehearsal 1). Line 659-660's "fresh slug" reads `a2b`.
  Lines 661-663: the replacement precondition 8 above, with `SKIP=-`.
- **R0, `$H` (lines 664-671).** `$H` is on `main`, clean, and **equal** to
  `origin/main`, `81d9b23`; "one commit behind" (`582455c` against `7b3532a`) is
  history. The checks stand, with `ancestor-ok`. On 2026-10-27 an untracked
  `.build/` appeared after the revert (cause not found; `make check` does not
  recreate it), and the lane refuses a dirty baseline, so `git status --porcelain`
  must print nothing at R0 as well as after R1.
- **R1 (lines 673-708) is not repeated.** The revert PR is done (PR #6, `81d9b23`).
  Its pass check: `git -C "$H" fetch origin && git -C "$H" diff --stat 582455c
  origin/main` prints nothing, and `test ! -e "$H/src/hello_forge/greet.py" && echo
  greet-absent` prints `greet-absent`. The stale-branch paragraph and its commands
  (lines 698-708, including 702 and 703, the `gh pr list` and the `gh api -X DELETE`
  of `chunk/hello-1-greet`, and line 708's "no local branch") are **moot**: the
  new name has no branch, and deleting the old one freed nothing. Instead, before
  R2: `gh pr list --repo "$R" --head "$BR" --state all --json number` must print
  `[]`, and `git -C "$H" ls-remote --heads origin "$BR"` must print nothing. The
  guard asks the same; this is the operator's own reading beside it.
- **R2 (lines 712-713, 716, 725-728, 739).** Run the deployed-script check
  above, then:
  ```bash
  cd "$H" && ~/.forge/repo/hermes/board-bootstrap.sh "$RB" --hello --branch-suffix a2b; echo "bootstrap exit=$?"
  ```
  It must print `free     chunk/hello-1-greet-a2b`, create the card, and exit 0.
  Exit 3 or 2 is a stop: no card exists, and the board is empty (caveat 1); report
  it to the operator. The raw `create` at lines 725-728 is shown only to say what
  the script does; its `--branch` (line 727) reads `"$BR"`, and it is **not** a
  substitute for the script, because it would skip the guard. Line 739's pin
  becomes `.branch_name == "chunk/hello-1-greet-a2b"`. Lines 712-713 ("not
  covered by `make verify`") are half true now: the naming and the guard have
  stubbed cases (`bootstrap/hello-branch-takes-the-suffix` and the guard cases),
  while the live `gh` and `hermes` legs do not, so read the output.
- **R3, R4, R6 (lines 755, 781, 858, 901, 906).** Each `chunk/hello-1-greet` is
  `"$BR"`. At line 781, the comment about "the three older PRs on this branch name"
  no longer applies: the new name has none, and the guard checked it, so an open
  PR on it is the lane's. At line 858 the expected branch is `chunk/hello-1-greet-a2b`.
- **R6 (lines 909-913).** The "rerun" sentence is replaced. A rerun after a
  repair is merged and deployed needs a **new board and a new, never-used suffix**:
  `hello-rehearsal-a2c` with `--branch-suffix a2c`, then `a2d`, and so on. R7 on
  the failed run still comes first. R7's closing the lane's PR and deleting its
  branch do **not** free the name, so a rerun on `a2b` is refused by the guard
  (exit 3) and was always going to be. R1's revert still does not repeat.
- **R7 (lines 915-943) is replaced by the following, in two arms.** It
  records the worktree before the archive, tags the tip, and treats the archive as
  what reaps the worktree.
  ```bash
  K=2                                    # rehearsal number; the tag is run-a-attempt-2/rehearsal-$K
  WT="$H/.worktrees/$ID"
  # 1. Record what the archive could take. Before, never after.
  if [ -e "$WT" ]; then
    { echo "status:"; git -C "$WT" status --porcelain; echo "HEAD: $(git -C "$WT" rev-parse HEAD)"; } | tee "$EV/worktree-before-archive.txt"
    TIP="$(git -C "$WT" rev-parse HEAD)"
  else
    echo worktree-absent | tee "$EV/worktree-before-archive.txt"
    TIP="$(git -C "$H" ls-remote --heads origin "$BR" | cut -f1)"
  fi; echo "TIP=$TIP"
  ```
  Pass: `status:` is followed by nothing (a dirty tree is the diagnosis's evidence:
  copy it out as R6 says and stop) and `TIP` is one full SHA. If the worktree is
  absent and no `$BR` exists on the remote, the lane never got as far as a branch:
  there is nothing to tag, so skip step 2.
  ```bash
  # 2. Tag the tip and publish the tag with gh api (the pre-push hook refuses every push from main).
  git -C "$H" tag "run-a-attempt-2/rehearsal-$K" "$TIP"
  gh api "repos/$R/git/refs" -f ref="refs/tags/run-a-attempt-2/rehearsal-$K" -f sha="$TIP" --jq .ref
  git -C "$H" ls-remote --tags origin "run-a-attempt-2/rehearsal-$K"    # must list $TIP
  ```
  If `gh api` says the object does not exist, the tip was never pushed, and the
  archive would keep such a worktree. Preserve it first:
  `git -C "$H" bundle create "$EV/tip.bundle" "$BR"`, then go on.
  ```bash
  # 3. Archive FIRST: the merge-watcher sweeps every board every ten minutes, and a blocked
  #    card whose PR is then closed unmerged would be reported once as a decision.
  hermes kanban --board "$RB" archive "$ID"
  hermes kanban --board "$RB" show "$ID" --json | jq -e '.task.status == "archived"'   # must print true, BEFORE the board is archived
  ```
  Then, **with a PR (arm A)**, from a directory that is not `$H`, so that
  `--delete-branch` deletes the remote branch only:
  ```bash
  N="$(gh pr list --repo "$R" --head "$BR" --state open --json number -q '.[0].number')"; echo "PR $N"
  gh pr close "$N" --repo "$R" --delete-branch --comment "Run A attempt 2 rehearsal $K: verdict recorded, closed unmerged."
  ```
  **No PR (arm B)**, the lane never opened one, as in rehearsal 1:
  `gh pr list --repo "$R" --head "$BR" --state all --json number` prints `[]`, and
  the remote branch, if there is one, goes by `gh api`:
  ```bash
  git -C "$H" ls-remote --heads origin "$BR" | grep -q . && gh api -X DELETE "repos/$R/git/refs/heads/$BR"
  ```
  Both arms, last:
  ```bash
  [ -e "$WT" ] && git -C "$H" worktree remove ".worktrees/$ID"       # the archive normally reaped it; no --force: if it refuses, stop and look
  git -C "$H" rev-parse --verify --quiet "refs/heads/$BR" && git -C "$H" branch -D "$BR"   # archive keeps a custom branch
  git -C "$H" fetch --prune origin
  hermes kanban boards rm "$RB"          # a soft move under boards/_archived/; never --delete
  ```
  Then confirm the state the next rehearsal and *Launch* both assume:
  ```bash
  git -C "$H" status -sb                                # ## main...origin/main, nothing else
  git -C "$H" worktree list                             # $H only
  git -C "$H" ls-remote --heads origin                  # refs/heads/main only
  git -C "$H" ls-remote --tags origin 'run-a-attempt-2/*'   # rehearsal-1 at 46fabde…, and rehearsal-$K at $TIP
  hermes kanban boards list --all --json | jq --arg s "$RB" 'any(.[]; .slug == $s and (.archived | not))'   # false
  ```
  Then the replacement precondition 8 again, with `SKIP=squatfather-run-a2`; it
  must print nothing. Once the board is archived it can no longer see it, so the
  `archived` check on the card, run before `boards rm`, is what stands in for it.
- **Decisions of the 2026-10-26 entry (lines 945-957).** "Reset by a revert PR"
  was carried out once (PR #6) and is not repeated. "`board-bootstrap.sh --hello`
  creates the card" stands, now with `--branch-suffix`. The rest stands.

**Attempt 1's card `t_da03d07a` is disposed of, not left.** It is dead and is
never to be unblocked (lines 528-530, 628-629 say so, and stand). But the digest
keeps reporting it, so lines 603-604's "the digest reads attempt 1's board, which
is harmless" is superseded: it is not harmless. The scoped wrapper still reads
`squatfather-run-a`, and its last block reason begins `other:`, so the operator's phone says "Waiting on you"
about a card nobody can act on. The steps below run after commission and before
*Launch*, except the last, which waits for the digest wrapper. Their evidence goes
in `EV1="$P/.forge/run-a-attempt-1"`.

*Why it is split.* `digest.sh` scoped to a board that is not there does not
degrade quietly. A missing `kanban.db` leaves the snapshot empty (lines 228-234),
the board prints `UNREADABLE — the board could not be read, so nothing here says
it is quiet` (lines 236-237), and the script exits **3** (`rc=3`, then `exit "$rc"`
at its end). Run on a scratch copy of this board on 2026-10-27 with the board
directory removed: the output names the board as UNREADABLE and the exit is 3.
Archiving the **card** instead leaves the board readable and empty: the same copy,
with the card archived, prints nothing and exits 0 ("nothing to say"). So T1 to T4
are safe before the repoint: the digest simply goes quiet about attempt 1. T5,
moving the **board**, is safe only once the wrapper no longer names it, so it is
the last part of Launch step 3.

1. **T1. The tag exists, locally and on the remote.**
   ```bash
   P="$HOME/dev/the-squatfather"; EV1="$P/.forge/run-a-attempt-1"
   test "$(git -C "$P" rev-parse --verify 'run-a-attempt-1/chunk-1^{commit}')" = ad3fd6399c2760d33c3940b542824b28639f0821 && echo tag-local-OK
   git -C "$P" ls-remote --tags origin 'run-a-attempt-1/chunk-1' | cut -f1 | grep -qx ad3fd6399c2760d33c3940b542824b28639f0821 && echo tag-remote-OK
   ```
   Pass: both lines print. Anything else is a stop: the card's commit is the one
   thing the archive must not outlive without a pointer.
2. **T2. Record the worktree, then archive.** The card's workspace is
   `$P/.worktrees/t_da03d07a`. Archiving removes a clean, fully pushed worktree
   (substrate behaviour 1), so its state is recorded first:
   ```bash
   W="$P/.worktrees/t_da03d07a"
   if [ -e "$W" ]; then { echo present; git -C "$W" status --porcelain; git -C "$W" rev-parse HEAD; }
   else echo worktree-absent; fi | tee "$EV1/t_da03d07a-worktree-before-archive.txt"
   git -C "$P" worktree list                                  # must list $P only
   ```
   Pass: `worktree-absent`, and the list shows `$P` alone. **That is the expected
   reading**: the 2026-10-26 entry's `git worktree remove .worktrees/t_da03d07a`
   was run on 2026-10-27, so the archive has no worktree to take, and the tag
   holds the commit. If it prints `present` instead, the status must be empty
   and `HEAD` must be `ad3fd63…`; otherwise stop and look.
3. **T3. Snapshot the board into the evidence directory.**
   ```bash
   SNAP="$(~/.forge/repo/scripts/board-snapshot.sh "$HOME/.hermes/kanban/boards/squatfather-run-a/kanban.db" "$(mktemp -d "$EV1/board-before-archive.XXXXXX")")"
   sqlite3 "$SNAP" "select id,status,branch_name from tasks"
   ```
   Pass: it prints exactly one row,
   `t_da03d07a|blocked|chunk/1-store-owner-history-in-a-migrated-sqlite`.
4. **T4. Archive the card.**
   ```bash
   hermes kanban --board squatfather-run-a archive t_da03d07a                 # Archived t_da03d07a
   hermes kanban --board squatfather-run-a show t_da03d07a --json | jq -e '.task.status == "archived"'   # true
   D="$(bash ~/.hermes/scripts/forge-digest.sh --day "$(date '+%Y-%m-%d')")"; echo "digest exit=$?"   # 0
   printf '%s' "$D" | wc -c                                                                          # 0
   ```
   Pass: `true`, then `digest exit=0` and `0`. The wrapper is still scoped to
   `squatfather-run-a`, and that board now has nothing to say. (Before T4 the
   same command prints the card, `Risk: unknown`: see P29.) The card is archived,
   not unblocked, and stays so.
5. **T5. Move the board, at Launch step 3, after the repoint.** See step 3c below.

*Launch, steps 3 and 5 (supersede lines 151-155 and 164-169; step 1, 2 and 4
stand).* Run both from `$P`, with `B=squatfather-run-a2`.
- **Step 3a, before the root exists.** The deployed-script check above. Then:
  ```bash
  cd "$P" && ~/.forge/repo/hermes/board-bootstrap.sh "$B" --root-only --branch-suffix a2; echo "bootstrap exit=$?"
  SNAP="$(~/.forge/repo/scripts/board-snapshot.sh "$HOME/.hermes/kanban/boards/$B/kanban.db" "$(mktemp -d "$P/.forge/board-launch.XXXXXX")")"
  sqlite3 "$SNAP" "select title, branch_name from tasks"
  ```
  Pass: it printed `free     chunk/1-store-owner-history-in-a-migrated-sqlite-a2`,
  `bootstrap exit=0`, and the query prints one row whose branch is that name. On
  exit 3 or 2, no card exists: stop, do not pick another suffix to get past it, and
  read the refusal.
- **Step 3b, the digest wrapper** — the `sed` repoint exactly where the
  2026-10-26 entry put it (lines 595-607): after `squatfather-run-a2` exists, and
  with its pass check, the last line ending `--board squatfather-run-a2 "$@"`.
- **Step 3c, T5.** Only after 3b's check passes:
  ```bash
  hermes kanban boards rm squatfather-run-a                  # a soft move; never --delete
  hermes kanban boards list --all --json | jq 'any(.[]; .slug == "squatfather-run-a" and (.archived | not))'   # false
  ls -d ~/.hermes/kanban/boards/_archived/squatfather-run-a-*/kanban.db   # exactly one path
  D="$(bash ~/.hermes/scripts/forge-digest.sh --day "$(date '+%Y-%m-%d')")"; echo "digest exit=$?"   # 0
  printf '%s' "$D" | grep -c UNREADABLE                                                              # 0
  ```
  Pass: `false`, one path, `digest exit=0` and `0`. The board's data stays under `_archived/`, and
  `$EV1` holds a copy: *the 2026-10-03 entry's "Attempt 1's board stays as
  evidence" (lines 529-530) is amended to that*. Run the replacement precondition
  8 once more; it must print nothing.
- **Step 5, the later full run** that creates CHUNK-2 to CHUNK-10 and the gates,
  **the same suffix**:
  ```bash
  cd "$P" && ~/.forge/repo/hermes/board-bootstrap.sh "$B" --branch-suffix a2; echo "bootstrap exit=$?"
  SNAP="$(~/.forge/repo/scripts/board-snapshot.sh "$HOME/.hermes/kanban/boards/$B/kanban.db" "$(mktemp -d "$P/.forge/board-launch.XXXXXX")")"
  sqlite3 "$SNAP" "select count(*) from tasks where branch_name like '%-a2'"                          # must print 9
  sqlite3 "$SNAP" "select id, branch_name from tasks where branch_name is not null and branch_name not like '%-a2'"   # must print nothing
  ```
  Pass: `bootstrap exit=0`; one `exists   chunk/1-store-owner-history-in-a-migrated-sqlite-a2`
  line for the root, and one `free` line for each of the other eight lane cards
  (CHUNK-2, 3, 4, 6, 7, 8, 9, 10); no `REFUSED`; then `9` and nothing. Its guard
  covers all three milestones' lane cards, not only M1's. On exit 3 no card is
  created and the root is untouched. A suffix other than `a2` here would give the
  new cards different names from the root's and be recognised only as new cards:
  the last two queries are what catches it.
- **CHUNK-5's branch is yours to name, and the same rule applies.** The suffix
  does not reach an interactive card (caveat 3), so the operator names the branch
  by hand: `chunk/5-guard-every-model-payload-behind-one-audited-a2`. Before
  `/start-chunk CHUNK-5`, `gh pr list --repo wielas/Squatfather --head <the name>
  --state all --json number` prints `[]`. S-1 (lines 204-278) is otherwise
  unchanged.

*Decisions this entry makes that the operator may overrule before launch.*
- The disposition is split (T1 to T4 before launch, T5 inside Launch step 3)
  rather than all at step 3. All at step 3 is also safe but leaves the dead card
  on the operator's phone through every day before launch.
- Suffix `a2` for the product and `a2b` for the rehearsal. Any lowercase slug
  nothing has used works; the guard, not the letter, is the check.
- CHUNK-5's hand-named branch carries `-a2`.
- Evidence for rehearsal 2 under its own directory, beside rehearsal 1's.
