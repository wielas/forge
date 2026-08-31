# Staged unattended run

This is the canonical procedure for the first genuine product run. It keeps the
unattended surface deliberately small: commission without mutation, release one
root chunk, inspect its evidence, and only then release the rest of the graph.

“Unattended” covers implementation and tier-1 filtering. It does not remove the
human tier-2 judgment, merge decision, or the checkpoint between the root and
the full graph.

## The release shape

```text
interactive planning
        |
        v
roadmap CLEAR -> paid commission -> root-only bootstrap
                                      |
                                      v
                         tier 1 -> human /judge -> merge
                                      |
                                      v
                         metadata + metrics checkpoint
                                      |
                                      v
                              full graph bootstrap
                                      |
                                      v
                         final evidence -> /retro -> cleanup
```

Use a clean, reviewed Forge checkout on `main` as the manager checkout. Use one
new board per product run. Reserve the product's main checkout for planning and
orchestration; workers own the generated chunk worktrees.

## 0. Prepare the host once

From the durable Forge checkout:

```bash
cd /absolute/path/to/forge
./install.sh
./hermes/profiles-bootstrap.sh
make validate
make verify
make preflight
```

Run `profiles-bootstrap.sh` on first installation and after changing its
checked-in profile configuration or SOUL files. It rewrites the generated
`forge-*` profile configuration; edit the checked-in source, not the generated
files. Re-run `make verify` and `make preflight` after any Hermes, Codex, Claude,
or profile upgrade.

`preflight` must report zero failures. Warnings are not automatically fatal,
but read every one. In particular, remove an empty API-key placeholder before a
night run and always pass an explicit board. Do not use the unproven Telegram
approval path as a dependency of this first run; operate from the desktop or
CLI.

## 1. Make the product launchable

For a new Python service, stamp it into a durable absolute path:

```bash
FORGE=/absolute/path/to/forge
PROJECT=/absolute/path/to/product
BOARD=product-run-1

cd "$FORGE"
make new NAME=product DEST=/absolute/path/to
cd "$PROJECT"
git init -b main
make setup
```

Create the GitHub repository, commit and push the initial project, then run the
template's `make protect`. Before commissioning, the product must have:

- a clean worktree and a GitHub `origin` whose identity resolves exactly;
- a protected default branch requiring the `check` status;
- `.forge/` ignored, so local run evidence cannot dirty the product;
- a committed `ROADMAP.md`, chunk contracts, graph, frozen features, and
  acceptance hashes; and
- a new board slug that has never been used.

Existing projects need the same contract. Do not weaken their current gates to
fit Forge; commissioning intentionally fails if the product does not expose the
expected `check` merge gate.

## 2. Plan interactively

Run `/scope`, `/architect`, then `/roadmap` with the human present. Planning is
the cheapest place to remove ambiguity. A good unattended chunk is a small
closed contract, not a miniature project:

- about 400 changed lines or less, six touched files or less, five scenarios or
  less, and four served requirements or less;
- exactly one graph root for the staged launch;
- `forge-codex-lane` on that root for this unattended pilot;
- only real dependencies: a child waits when it truly needs its parent's merged
  output;
- explicit `Touches`, `Scenarios`, `Lane`, `Acceptance`, and real-source tags;
- `forge-codex-lane` only for work that is actually safe to delegate, with
  interactive work marked `claude-interactive`; and
- frozen acceptance before implementation begins.

From Forge, run the advisory checker until its summary begins `CLEAR —`; an exit
code of zero with warnings is not launch approval. Then validate and write the
acceptance manifest:

```bash
cd "$FORGE"
make roadmap-check PROJECT="$PROJECT"
./scripts/acceptance-freeze.sh "$PROJECT"
```

Fix the plan and repeat both commands after any contract or feature edit. Commit
and push the final plan and generated manifest before commissioning.

Treat a lane `WARN` or `SKIP` as a hard stop. The bootstrap validates the
default lane before mutation, but graph entries can name other lanes; every
declared unattended lane must exist in the live Hermes assignee list.

## 3. Commission without launching

First prove that the chosen board is absent:

```bash
hermes kanban boards list --json \
  | jq --arg board "$BOARD" 'any(.[]; .slug == $board)'
# Must print: false
```

If it prints `true`, choose another slug. A board with old rows is not a clean
run boundary.

Then run the paid commissioning gate from Forge:

```bash
cd "$FORGE"
make commission PROJECT="$PROJECT" BOARD="$BOARD"
```

Commissioning checks the durable path, clean tree, exact remote identity, merge
gate, roadmap report, live preflight, and paid Codex sandbox probe. It also
fingerprints the board before and after to prove it did not mutate it. Read the
generated `$PROJECT/.forge/commission-*.md`; continue only when it ends in
`overall: PASS` and the separately run roadmap check was `CLEAR`.

Record the evidence boundary immediately before creating the root card:

```bash
RUN_START="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
FORGE_SHA="$(git -C "$FORGE" rev-parse HEAD)"
PRODUCT_SHA="$(git -C "$PROJECT" rev-parse HEAD)"
printf '%s\n' "$RUN_START" "$FORGE_SHA" "$PRODUCT_SHA"
```

Save those values with the board slug and commissioning report path in
`$PROJECT/.forge/`. They make the result reproducible without putting transient
run exhaust in git.

## 4. Release only the root

Run the bootstrap from the product root. The installed Forge pointer keeps this
command on the version that passed commissioning:

```bash
cd "$PROJECT"
"$HOME/.forge/repo/hermes/board-bootstrap.sh" "$BOARD" --root-only
hermes kanban --board "$BOARD" watch
```

The bootstrap validates the complete graph before it creates anything, requires
one root, pins the board and product workdir, and uses idempotency keys. Do not
run the full command yet, even if the root looks healthy.

Let the root proceed through its unattended lane and tier-1 gate. Inspect the
card, runs, PR, CI, and tier-1 findings. Then perform tier 2 with `/judge
<chunk-id>`. Only the human merges an approved PR. A root card reaching `done`
or opening a PR is not equivalent to its code being merged.

Steer with a card comment when possible; the next run reads it and reuses the
same worktree. Do not kill and recreate a card merely to change direction.

## 5. Pass the root checkpoint

After the approved root PR is merged, run both read-only checks from Forge:

```bash
cd "$FORGE"
./scripts/metadata-live.sh "$BOARD" --since "$RUN_START"
make metrics BOARD="$BOARD"
```

Interpret `metadata-live` exactly:

| Exit | Meaning | Action |
|---|---|---|
| `0` | Every scoped completed run and block satisfies the contract | Continue if the PR is merged and metrics are readable |
| `1` | Producer metadata is invalid | Stop; preserve evidence and repair the producer |
| `2` | The board, schema, snapshot, or cutoff could not be read | Stop; this is not an empty success |

The root checkpoint is green only when all of these are true:

- commissioning passed and the roadmap was `CLEAR`;
- the root received tier-2 approval and its PR is merged;
- `metadata-live` exits `0`; and
- `metrics` reads the board and reports no unexplained envelope bucket.

Anything else means stop at one card. Do not expand a questionable run to make
the sample larger.

## 6. Release the full graph

The second invocation is idempotent: it reuses the root card and creates the
remaining cards with dependency parents attached atomically.

```bash
cd "$PROJECT"
"$HOME/.forge/repo/hermes/board-bootstrap.sh" "$BOARD"
hermes kanban --board "$BOARD" watch
```

The board may run independent chunks concurrently. Code dependencies remain
serial: a child must wait for its parent's PR to merge, not merely for the
parent card to finish. Do not invent stacks to bypass this rule.

During the run, favor observation over intervention:

```bash
CARD=t_replace_with_card_id
hermes kanban --board "$BOARD" show "$CARD" --json
hermes kanban --board "$BOARD" runs "$CARD"
```

Read the latest run before assigning blame. A reclaimed card, a quota/auth
failure, an open-PR guard, and a genuine implementation failure need different
responses. Stop and inspect repeated retries, a circuit-breaker event, an
unknown assignee, a red dependency PR, invalid metadata, or an unjudged result.

## 7. Close the run

Once every intended chunk is approved and merged, repeat the evidence checks:

```bash
cd "$FORGE"
./scripts/metadata-live.sh "$BOARD" --since "$RUN_START"
make metrics BOARD="$BOARD"
./scripts/metrics.sh "$BOARD" --markdown-row
```

Run `/retro` interactively. Paste the generated metrics row into
`docs/retro-metrics.md` as the skill instructs, reconcile the decision log, and
turn only repeated findings into Forge changes. The retro proposes a reviewed
PR; it does not self-merge.

Reclaim merged worker worktrees only after the evidence is captured. Preview
first, inspect every candidate, then apply the same bounded sweep:

```bash
make worktree-sweep PROJECT="$PROJECT"
make worktree-sweep PROJECT="$PROJECT" APPLY=1
```

The sweep only reaches `$PROJECT/.worktrees/`, requires a clean worktree and a
merged remote PR, and uses non-forced branch deletion. Review anything outside
that boundary manually.

## Stop rules

Stop before creating or expanding cards when any of these is true:

- `preflight` has a failure, the roadmap is not `CLEAR`, or any declared lane
  is unresolved;
- the board slug already exists, commissioning fails, or its report is missing;
- the product or Forge checkout changes after commissioning and before launch;
- the root PR is unapproved, red, open, or unmerged;
- metadata exits `1` or `2`, metrics cannot read the board, or completed work is
  unjudged; or
- a dependency is only PR-open rather than merged.

Preserve the board, worktrees, PRs, commissioning report, `RUN_START`, and
command output when stopping. They are the failure evidence. Diagnose from
those artifacts before unblocking or rerunning; bootstrap is idempotent, but an
unexplained failure is not made safe by repetition.

## Operating habits that pay off

- Keep one manager checkout and one board per run. Never let concurrent human
  slices share the manager's branch or decision ledger.
- Spend human attention on contracts and tier-2 review. Those are the two
  highest-leverage points; routine implementation belongs in the lane.
- Keep comments concrete and actionable. They steer the next attempt without
  losing the worktree, history, or linked PR.
- Make merge state explicit. Forge's dependency safety is about integrated
  code, so “PR open” and “card done” are intermediate states.
- Measure before interpreting. `metadata-live` decides whether exhaust is
  canonical; `metrics` computes the numbers; `/retro` decides what they mean.
- Change one system variable at a time. After a model, CLI, profile, or Forge
  upgrade, revalidate before combining that change with a new product run.
