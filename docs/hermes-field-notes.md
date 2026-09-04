# Hermes field notes — how the substrate actually behaves

Durable reference for the parts of Hermes, Codex and Claude Code that cost us a
day to learn and that no amount of reading the docs would have taught us. Every
entry is something a running system told us, with the command that showed it.

**This file holds no state.** Versions, board names, config values and auth
status change under you; `make preflight` establishes those in one read-only run,
and a written copy would just be a lie with a date on it. Run preflight after
every `hermes update` — config drifts across upgrades (0.18.2 → 0.19.0 silently
changed `approvals.mode` and `goals.max_turns`), and an update can reset the
checkout out from under you (0.19.0 → 0.20.4 did; see below).

Decisions live in `docs/adr/`. This file is evidence, not intent.

---

## The traps: documented-but-untrue, or silent

**`custom_toolsets:` does nothing.** It is documented in
`website/docs/reference/toolsets-reference.md`, and no code in 0.20.4 reads it —
re-measured on the upgrade: `custom_toolsets` still appears in no `.py` file. A
profile whose `toolsets:` names a custom bundle gets **zero tools** — no terminal,
no kanban, not even the ability to terminate its own run — and nothing warns you.

```
$ python -c "import toolsets; print(toolsets.resolve_toolset('forge'))"
[]
```

`toolsets:` must list real names, one per line, from
`toolsets.get_toolset_names()`. `messaging` is not one of them.

**`hermes config set` cannot write lists.** `hermes config set
skills.external_dirs '["/path"]'` stores the *string* `'["/path"]'`;
`get_external_skills_dirs()` then treats it as a single path, fails to stat it,
and skips it silently. Same class of failure as `custom_toolsets`. Write
list-valued keys as real YAML by hand.

**An unknown assignee is not an error.** The dispatcher drops the card. It sits
in `ready` forever with a `skipped_nonspawnable` event and surfaces only in
`hermes kanban diagnostics` as `stranded_in_ready`, after
`kanban.stranded_threshold_seconds` (default 30 min). Every assignee must exist
in `hermes kanban assignees` before a card names it.

**A human card needs a real block event, not `initial_status=blocked`.** The
`kanban_create` tool and CLI differ: the tool requires `assignee`; the CLI
allows none. More subtly, `initial_status=blocked` records only a `created`
event whose payload says blocked. `recompute_ready()` treats a blocked task as
dependency-blocked unless its latest `blocked`/`unblocked` event is a real
`blocked` event. Measured 2026-07-28: an unassigned probe created with
`--initial-status blocked` was promoted on the next tick, assigned to
`kanban.default_assignee=builder`, and dispatched. To park human work durably:
create on a non-spawnable sentinel assignee, call `kanban block --kind
needs_input` to make the state sticky, then `kanban assign <id> none` and read
back `.task.assignee`, `.task.status`, and the `blocked` event. There is no
`kanban_update` tool.

**Nested CLI creation needs explicit provenance.** The CLI defaults
`created_by=user`, even when a profile invokes it inside a dispatched task.
`kanban_complete(created_cards=[...])` then rejects the card because the
completion kernel cannot prove that worker created it. Pass
`--created-by "$HERMES_KANBAN_TASK"`; the kernel accepts the current task id as
provenance. If manifest verification still fails, block with the evidence.
Never retry completion without `created_cards` — that turns an unverified
hand-off into apparent success.

**`--board` goes *before* the subcommand.** `hermes kanban --board <slug> create
…` — the flag belongs to the kanban parser; after `create` it is an unrecognized
argument. It works by pinning `HERMES_KANBAN_BOARD` for the call, so exporting
that variable is equivalent and survives into anything the script spawns. Without
either, board resolution falls back to the *persisted current board*, and cards
land somewhere you did not intend. `hermes kanban link` takes positionals:
`link <parent-id> <child-id>`.

**A done parent card is not merged code.** Chunk cards complete when their PR
opens, and Hermes promotes children on card completion. Measured on D1 → D2:
D2 promoted in the same second PR #7 opened, found its required file absent
from `main`, used a `dependency` block, and was promoted again one second later
because D1 was already done. The retry rebased onto the unmerged D1 branch and
opened a green PR whose diff contained both chunks; Tier 1 still scored scope
discipline 3/3. Attach graph parents atomically with `--parent`, but separately
gate code dependencies on the parent PR's non-null `mergedAt`. Wait with a
sticky `needs_input` block, never `dependency`, and never invent a stacked PR.

**Local and external skills with the same name collide at force-load time.**
`hermes skills list` presents the local copy as enabled, but
`hermes --skills <name>` searches every configured root and refuses two
matches. Measured when `forge-lane` existed both in the profile-local skills
directory and `skills.external_dirs`: the dispatcher worker exited immediately
with `Unknown skill(s): forge-lane`. Keep exactly one live source. During this
isolated exercise the lane profile's external directory points at the exercise
worktree; the recoverable local duplicate is at
`/private/tmp/forge-lane-local-override.before-dependency-20260728`.

**`scratch` workspaces are deleted on completion.** Chunk cards must use
`--workspace worktree`, which is preserved. The worktree is created **dispatcher-side**,
before the worker exists: the dispatch loop calls
`_resolve_worktree_workspace` → `_ensure_git_worktree` (`kanban_db.py:8388`) and
only then `_spawn` (`:8405`). By the time `$HERMES_KANBAN_WORKSPACE` is set it is
already a checkout on `$HERMES_KANBAN_BRANCH`. A worker that runs `git worktree
add` itself is adding a branch that is already checked out in that same path,
which fails — the worker then exits without a terminator and is reaped as
`crashed`. Land with `cd "$HERMES_KANBAN_WORKSPACE"` and fail hard if it is not a
git checkout; never create it.

**A bounce must return to the rejected branch, not just to a worker.** A
`kanban_create` follow-up defaults to isolated `scratch` and does not inherit
the parent's forced skills. Measured 2026-07-28: the first real fix card cloned
the repo into scratch, the cheap driver authored the change itself instead of
driving Codex, its first HTTPS push failed, and it spent 57 tool calls on a
one-line repair. For a completed chunk, sharing its preserved linked worktree
is intentional and safe: create the fix with `workspace_kind="dir"`,
`workspace_path=<completed chunk worktree>`, and `skills=["forge-lane"]`.
Read those fields back before completing prejudge. Do not request a new
`worktree` at the occupied path; Hermes correctly falls back to a fresh branch
from `main`, which is not the rejected PR.

**Force-loading a skill does not enforce its component boundary.** The corrected
bounce card carried `skills=["forge-lane"]`, landed on the right PR worktree,
and explicitly reasoned from the lane steps—then the cheap driver patched the
one-line fix itself and never invoked Codex. "Operator, not author" was too easy
to rationalize away for a trivial diff. State the prohibition literally in both
the profile and skill: no driver-authored retained implementation diff; even one
line goes through `codex exec`, and an unavailable Codex blocks the card.

**A verification probe that exits nonzero proved nothing.** The lane used
`git -C <common .git dir> status --short hooks`; Git exits 128 because that is
not a worktree. The driver noticed, called it "fine", and completed with
Codex-created `.orig` and `.rej` files still untracked. Snapshot hook hashes
before/after with `shasum`, compare them, and require an empty
`git status --porcelain --untracked-files=all` after all temporary mutations
are restored. A driver may mutate a file temporarily to prove a test, but no
driver-authored byte or test artifact may survive into the push.

**`skill_manage` CAN write external-dir skills; only `write_approval` stops it.**
Measured 2026-07-27 by calling the real tool against a throwaway
`skills.external_dirs` skill:

```
write_approval off → {"success": true, "message": "Skill 'probe-skill' updated
                      (full rewrite)."}          # file mutated on disk
write_approval on  → {"success": true, "staged": true, "pending_id": "7854a351",
                      "message": "Staged for approval … Not yet saved."}
```

The curator's "DO NOT touch … external-dir skills" text
(`agent/curator.py:434`) is a *prompt*, and the real guard next to it
(`tools/skill_manager_tool.py:_background_review_write_guard`) fires only when
the write origin is `background_review`. `get_current_write_origin()` documents
its default `foreground` as "any tool call made by a regular (non-review) agent,
from the CLI, **the gateway**, cron, or a subagent" — which is exactly a
dispatched lane worker. So a lane is not covered by that prohibition.

Two corollaries: the forge skills are protected by `skills.write_approval`
alone, and a staged write does **not** hang the worker waiting for an approval
it cannot get — it returns success immediately and the edit silently does not
land. Anything relying on "the worker will block" is wrong.

**Skills are per profile.** Every profile is its own `HERMES_HOME` with its own
skills tree, so anything installed in `~/.hermes/skills` reaches only the
**default** profile. A lane sees none of it. Verify per profile:
`hermes -p forge-codex-lane skills list`.

**`ps eww` cannot see a Hermes process's credentials.** macOS `ps` reports the
environment a process was *exec'd* with; `hermes` calls `load_hermes_dotenv()` at
import, i.e. after exec. Measured: a Python process that sets `os.environ[X]`
post-exec shows zero `ps` matches. A preflight check built on `ps` WARNed on a
perfectly healthy gateway for a whole afternoon.

**`hermes update` destroys carried commits.** It fetches, then runs `git merge
--ff-only origin/<branch>`; a locally carried commit is precisely what makes
that fail, and the fallback is `git reset --hard origin/<branch>`
(`hermes_cli/update_cmd.py`, the ff-only branch of the "→ Pulling updates…"
path). It warns first — `⚠ Fast-forward not possible (history diverged),
resetting to match remote...` — and `_stash_local_changes_if_needed` autostashes
the working tree, so uncommitted work survives and **committed** divergence does
not. The 0.19.0 → 0.20.4 upgrade took that branch and deleted the carried
`fix(kanban): let unblock supersede prior PR guard`; it was restored by hand.
Anything carried in `~/.hermes/hermes-agent` must be re-appliable from a source
that is not that checkout.

**0.20.4's banner no longer prints a carried-commit count.** The one signal that
made a carried patch visible at a glance is gone, so the reset above is silent
in both directions:

```
$ hermes --version
Hermes Agent v0.20.4 (2026.8.18)
Install directory: /Users/goonlab/.hermes/hermes-agent
Python: 3.11.15
OpenAI SDK: 2.24.0
```

The replacement is behavioural, not a SHA — a SHA changes on every
re-cherry-pick and says nothing about what the code does.
`scripts/respawn-guard-probe.py` asserts four contracts against
`check_respawn_guard` (two of them upstream's own, so "the patch is gone" is
distinguishable from "the function changed shape"), and preflight §11 runs it
and refuses to read a bare exit code as a verdict.

**The 0.20.4 memory guard is Linux-only, and on macOS it protects nothing.**
Two production OOM incidents (`larrikin-lollies`, `synclare-task-manager`) where
the dispatcher fanned out 26–31 workers added two safeguards in
`hermes_cli/kanban_db.py`: a memory-derived default for `kanban.max_in_progress`
(`derive_default_max_in_progress`, `clamp(MemTotal/512 MiB, 2, 8)`) and a live
pressure guard (`_memory_pressure_level`). Both read `/proc`, and both fail
open. Measured on this mini through the Hermes venv interpreter:

```
$ ~/.hermes/hermes-agent/venv/bin/python3 -c 'from hermes_cli import kanban_db as k; \
    print(k._system_memory_sample(), k.derive_default_max_in_progress(), \
          k.resolve_max_in_progress(None), k._memory_pressure_level())'
{} None None unknown
#  ^  ^    ^    ^-- no spawn restriction
#  |  |    +------- no cap
#  |  +------------ no derived default
#  +--------------- macOS has no /proc
```

`hermes` on PATH is a bash shim whose last line execs the real entrypoint; the
interpreter that can import `hermes_cli` is the `python3` beside that entrypoint.
Derive it, never hardcode it — that path has already moved once.

`config_defaults.py` says it beside the key: *"On hosts where total memory can't
be read (macOS/Windows), unset falls back to no cap."* So on macOS **unset means
unbounded**, not "a sensible default" — and with
`kanban.dispatch_in_gateway=true` this is the host doing the spawning. Set
`kanban.max_in_progress` explicitly; `configured_max_in_progress()` accepts only
a positive integer and silently falls through for `0`, negatives and non-numerics.
`kanban.max_in_progress_per_profile` bounds one lane rather than the machine.
Preflight §4 checks this.

## How things really connect

**Live schema inspection checks every board, by name.** There is no meaningful
"first" board: the persisted default can change, and filesystem enumeration is
not a selection policy. `make verify` enumerates every immediate
`boards/<slug>/kanban.db` in bytewise path order, snapshots each through
`scripts/board-snapshot.sh`, and reports a separate named result for each slug.
An unreadable board is a failure for that named board, never a reason to fall
through to another one. The sweep remains an operator-host diagnostic; CI does
not gain live-board access.

**Profiles** are separate `HERMES_HOME` directories created with `hermes profile
create <name> --description "<role>"`; the description feeds orchestrator routing.
There is no `profiles:` block in `config.yaml`.

**Worker usage joins exactly across two SQLite databases.** Hermes 0.20.4 stamps
the dispatched worker's session id at top-level
`task_runs.metadata.worker_session_id`; `task_runs.profile` names the only state
database allowed to satisfy it:
`$HERMES_HOME/profiles/<profile>/state.db`. Measured on historical
`forge-codex-lane` runs, the id equals `sessions.id`; no title, timestamp or
model-name inference is needed. Inspect the contract only through snapshots:

```
board=$(scripts/board-snapshot.sh ~/.hermes/kanban/boards/<slug>/kanban.db /tmp/board-snap)
state=$(scripts/board-snapshot.sh ~/.hermes/profiles/<profile>/state.db /tmp/state-snap)
sqlite3 "$board" "select profile,json_extract(metadata,'$.worker_session_id') from task_runs"
sqlite3 "$state" ".schema sessions"
sqlite3 "$state" ".schema session_model_usage"
```

`sessions` carries the per-session totals: model, `billing_provider`, API calls,
input/output/cache-read/cache-write/reasoning tokens, estimated and actual cost,
status and source. `session_model_usage` carries one or more rows for the same
session and is the per-model breakdown; keep every matching row. On the live
profile databases measured 2026-08-10, all 44 lane sessions said
`cost_status=estimated`, all 44 had an estimate, and all 44 had null actual
cost. The per-model schema instead declares `actual_cost_usd REAL NOT NULL
DEFAULT 0`; 55/55 rows held that zero, including the 44 explicitly estimated
rows. That zero is storage, not evidence. Unless the row's status says actual,
render actual cost as missing. If the id or profile database is unavailable,
the run is unjudged and base board metrics remain readable.

**Worker lifecycle.** A dispatched worker must end in exactly one of
`kanban_complete` or `kanban_block`. Exiting without either is reaped as
`crashed`: `consecutive_failures` ticks and the breaker blocks the card once it
trips (`--max-retries`, default `kanban.failure_limit`=2). Heartbeat at least
hourly on long work — the dispatcher reclaims a task running past
`kanban.dispatch_stale_timeout_seconds` (4h) with no heartbeat in the last hour.
A reclaim re-queues without penalty but loses the run's progress.

**Crash-after-push is recoverable when the worktree and intent are durable.**
Measured on card `t_6e2b8528`: run 8 pushed SHA `88ad60f`, recorded that SHA in
a card comment, then was killed with signal 9 before PR creation. The dispatcher
recorded the crash and immediately started run 9 against the same linked
worktree. The retry read the durable marker, verified the clean tree and remote
SHA, skipped the one-shot pause, did not invoke Codex again, and opened exactly
one PR in 55 seconds.

**Codex states its own usage windows, and the shape is not ours to assume.**
Every `token_count` event on a `codex exec --json` stream carries `rate_limits`:

```
"rate_limits": {"limit_id":"codex","primary":{"used_percent":31.0,
 "window_minutes":10080,"resets_at":1787200231},"secondary":null,
 "credits":{...},"plan_type":"plus","rate_limit_reached_type":null}
```

`resets_at` is an absolute epoch — the only trustworthy input to a wait, since
a duration we pick is right for exactly one quota policy. Read on 2026-08-31,
every rollout under `~/.codex/sessions` on this machine still reports ONE
window of 10080 minutes with a null `secondary`, even though quota had already
moved to shorter rolling windows elsewhere. So do not read the absence of a
short window as evidence there is none; enumerate whatever members carry
`used_percent`/`resets_at` and never branch on `window_minutes` (ADR-0016).

**The reasoning-effort pin flaps under the desktop app.** ADR-0015 recorded
`config/codex-pin-live` FAILing at `gpt-5.6-sol/high` against a checked-in
`xhigh`. On 2026-08-31 the same file was read twice about two hours apart in
one session: `high` at 20:15, `xhigh` at 22:50, with no human edit in between —
the Codex desktop app rewrites `~/.codex/config.toml` while running. So this
check is not merely drift-prone, it is *intermittent*, and a green run proves
only what the file said at that moment. Effort is also a quota lever — the CLI
warns that it "can quickly consume Plus plan rate limits" — so an unattended
lane can inherit a different cost profile than the one the repo claims, in
either direction, without anything changing in version control.

Two more things measured against codex-cli 0.148.0, both load-bearing:

- **`codex exec resume <session-id>` takes neither `-s`, `-C` nor `--add-dir`.**
  So a resumed run cannot restate the sandbox grant the way the first call
  does. `-c sandbox_mode="workspace-write"` and
  `-c sandbox_workspace_write.writable_roots=[…]` do parse — confirmed through
  `codex debug prompt-input`, which validates config without an API call, with
  a bogus value rejected as the control.

  **Parsing is not granting, and only the parsing is measured.** Nothing here
  establishes that those two overrides actually let a *resumed* session commit
  into the shared `.git`, and there is a specific reason to doubt the
  equivalence rather than assume it: `--add-dir` is documented as adding to the
  default writable roots, while `writable_roots=[…]` sets a list, so the
  override may replace what the flag would have extended. The failure mode is
  silent loss of write access mid-run — the defect that cost this repo a rung
  the first time it was met. Settling it costs one real chunk; until then it is
  in `state.md`'s not-proven list and stays out of every skill body.
- **`--json` replaces the human-readable stream rather than adding to it.** A
  driver watching a `--json` run through `process(action="log")` sees raw JSONL
  and nothing else, which is why `scripts/codex-progress.py` exists.

**Long work does not need forge machinery.** `terminal.timeout` (1800s) caps a
*synchronous* command, but the terminal tool takes `background=True, pty=True,
notify_on_complete=True` and the `process` tool polls it. That is native, so cap
chunk size for good reasons — not to dodge a timeout.

**Bounce dynamics are board-native.** The respawn guard already refuses re-spawn
on `blocker_auth` (quota/auth), `recent_success` and `active_pr`. Use
`--max-retries` per card; do not invent a bounce loop.

**A prejudge card's PR-URL comment is a life sentence.** `check_respawn_guard`
skips `active_pr` entirely when `lane == "review"` — a PR-URL comment there is
the review handoff's *precondition*, not evidence of duplicate work (see the
contract-4 note above and `scripts/respawn-guard-probe.py`). A prejudge card
dispatches in the `ready` lane instead, so it gets no such exemption: any
comment matching a GitHub PR URL, posted on THAT card, inside the 24h
`_RESPAWN_GUARD_PR_WINDOW`, defers its own respawn every tick, indefinitely.
`skills/forge-lane` §7 always meant the PR URL to travel as the child's
`kanban_create(body=...)` — `task.body` is never read by the guard, only
`task_comments` is — but nothing enforced that until this note. Measured live
on `jobapp-second-instance`, 2026-09-04: CHUNK-C20's prejudge child
(`t_3e676b10`) was created with an EMPTY body and the PR summary posted as a
separate `kanban_comment` 5 seconds later, 8 seconds before the card
auto-promoted to `ready`. It logged `respawn_guarded: active_pr` on every
~60s dispatcher tick from 10:22:22 to 13:14:48 — 173 consecutive events,
~2h52m, zero spawns, `last_failure_error` NULL and no run on record the whole
time. (CHUNK-C10/C13/C19's prejudge children never comment their own card at
all — the PR URL lives only in `body`, per protocol, and none of the three
ever guarded. This is not a promotion-vs-comment race: only the deviating card
ever carried a comment to race against.)

**There is no clean operator recovery once this fires**, because every event
that clears `active_pr` requires the card to already be `blocked`:
`hermes kanban promote` refuses a task whose `status` is not `todo`/`blocked`
(`promote_task`, kanban_db.py ~6797) — and a prejudge card is `ready` the
instant it is created, since its sole parent (the chunk it reviews) is already
`done`. The only path is `kanban block --kind needs_input <id> "<reason>"`
then `kanban unblock <id>` — which burns a `block_recurrences` slot toward the
triage cutoff and is not offered anywhere in `skills/forge-lane` or
`skills/prejudge`. The live incident above was resolved by running
`scripts/prejudge.sh` by hand and completing the card from that output
directly — an out-of-band workaround, not a supported recovery path, and
consistent with what the run row shows: `started_at == ended_at`, no
`claim_lock`, no `worker_pid`, no `spawned` event, `metadata` NULL.
`kanban_db.py` is Hermes's, not Forge's, so the `lane` classification a
prejudge dispatch gets is not ours to change; what Forge owns is making sure
`forge-lane` never hands the guard the evidence in the first place (§7's
read-back, added 2026-09-04) and documenting the block→unblock recovery here
for the case where it does.

**A prejudge scratch workspace has no GitHub repository context.** Numeric
commands such as `gh pr checks 10` fail there. On the first CI-red probe the
worker spent a minute searching unrelated board workspaces for a clone before
it could inspect the check. Pass the canonical PR URL to `gh pr checks` and
`gh pr diff`; it carries owner, repository and number and works from scratch.

**CI-red still needs canonical verdict metadata.** "No scoring" means skip the
judging model, not skip `forge.judge.v1`. The first live red review routed its
fix correctly but emitted one-off `forge.prejudge.v1.*` keys; `/retro` therefore
could not count the observed bounce. Emit the schema's deterministic all-zero
CI sentinel with a `ci-red` finding, `judge_model: "ci"` and zero model tokens.

**`approvals.mode` cuts both ways.** `manual` makes an unattended worker wait for
an approval nobody is there to give; `off` checks nothing on a `local` backend
with a reachable bot. `smart` is the only mode that is both safe and viable
unattended.

**How the token reaches a worker.** Not by env injection: `hermes` loads
`~/.hermes/.env` at import, so the **gateway's live `os.environ`** holds the
credentials, and the dispatcher spawns children with `env = dict(os.environ)`.
The child's `HERMES_HOME` is set to the *profile* directory, so its own dotenv
load reads `~/.hermes/profiles/<name>/.env` — not the root one. Dispatched
workers are covered by inheritance; a hand-run `hermes -p <name>` is not, unless
the profile's own `.env` carries the token.

**Something writes credentials into profile `.env` files.** All four forge
profiles gained a `CLAUDE_CODE_OAUTH_TOKEN=` line, within the same minute, at a
gateway restart — nobody typed it. `hermes -p <name> skills list`, `kanban
assignees`, `profile list` and `config get` do **not** reproduce it, so the
gateway start path is the likely writer (`profiles.py` has backfill machinery,
though the code path was not pinned down). Useful here, because it is exactly
what a hand-run worker needs. Worth knowing because the same mechanism would
propagate a metered `ANTHROPIC_API_KEY` into every profile just as quietly.

## Codex

**There is no `--full-auto` in codex-cli 0.145.0.** The sandbox flag is
`-s {read-only|workspace-write|danger-full-access}`. Hermes's own bundled
`kanban-codex-lane` skill still says `--full-auto`; it is stale.

**`workspace-write` cannot commit inside a git worktree.** Measured both ways:

```
without --add-dir:  fatal: Unable to create '…/.git/worktrees/<id>/index.lock':
                    Operation not permitted        exit 128
with    --add-dir "$(git rev-parse --git-common-dir)":            exit 0
```

The real `.git` lives in the main repo, outside the workspace. **Anyone
re-testing this: do not build the lab under `/tmp`.** Codex announces `sandbox:
workspace-write [workdir, /tmp, $TMPDIR]`, so a probe there passes for the wrong
reason — ours did, on the first attempt.

**`codex exec` reads stdin.** Always `< /dev/null`, or it consumes whatever the
parent had queued. It also refuses to run outside a git repo (fine inside a
worktree; `--skip-git-repo-check` otherwise), and takes `--output-schema` for
structured verdicts.

**`workspace-write` has NO network.** Measured 2026-07-28 on the first real
chunk: `git fetch origin` dies with `ssh: Could not resolve hostname
github.com: -65563`, and `uv` cannot fetch a package. This matters more than it
sounds, because a dispatcher worktree is a fresh checkout with **no `.venv`** —
so `make check` cannot run inside the sandbox unless someone built the
environment first. Codex does not stop when it hits this; it improvises. Ours
copied the whole 1.3 GB `~/.cache/uv` into `/tmp` (writable under
`workspace-write`) and ran everything under `UV_CACHE_DIR=… UV_OFFLINE=1` — 29
shell calls before writing any code, and a "green" from a command CI never
runs. `forge-lane` §3 now runs `make setup` + `git fetch` before handing over.

**Only WRITES are sandboxed; reads are not.** Same run: Codex read
`/Users/goonlab/dev/forge/skills/forge-lane/SKILL.md` and `start-chunk`, then
announced it was *"using the Forge lane protocol"* — the calling agent's
playbook, including "push, open the PR, operate the board". It followed the
pointer in the project's own `AGENTS.md`. Nothing in the sandbox prevents this,
so the role boundary has to be **stated in the prompt** (`forge-lane` §4) and
`AGENTS.md` must scope the ceremony skills to the interactive operator.

## lefthook

**Pre-push commands without file templates run on an empty commit.** An earlier
measurement claimed lefthook 2.1.10 skipped them:

```
│  lint (skip) no files for inspection     # pre-COMMIT, expected
┃  full-check ❯ FORGE CHECK: GREEN         # pre-push RAN
┃  no-main-push ❯                          # pre-push RAN
```

The skipped line was the pre-commit `lint` command carrying a staged-file
template, misread as the later pre-push result. `full-check` and
`no-main-push` carry no file template and both ran on a genuinely empty commit,
measured three times on 2026-07-28. Do not restore the old “known hole” comment
or add `skip_empty`; there is no empty-commit bypass to close.

One more reason the merge gate is `make protect`, not the hook.

## Claude Code, headless

**`claude -p` authenticates headlessly with `CLAUDE_CODE_OAUTH_TOKEN`** — proven
in a stripped `env -i` shell that mimics a dispatcher-spawned child (preflight
§3). Credentials otherwise live in the macOS Keychain, which a non-GUI session
may be unable to unlock; that is what makes an SSH run fail while a local
Terminal works. `claude setup-token` mints a one-year token that needs no
keychain. It does not auto-refresh: **cron the renewal date**, because silent
expiry kills every lane at once.

**Pin `--model` and keep `~/.claude` lean.** A bare `claude -p "reply OK"`
defaulted to **Opus** and burned ~20k tokens of auto-discovered context (hooks,
skills, plugins, MCP servers, CLAUDE.md) to answer with two characters. Every MCP
server installed there is re-paid on every invocation.

**`--bare` is not available to us.** It would skip that discovery but cannot read
`CLAUDE_CODE_OAUTH_TOKEN`, and the only other credential is a metered key.

**`total_cost_usd` is not a bill.** It is computed locally at list rates; on a
subscription it means nothing in dollars. Use it as a relative signal between
runs, never as spend.

**`ANTHROPIC_API_KEY` outranks the OAuth token.** This is why the money invariant
is a preflight gate rather than a note: one pasted value converts every lane to
per-token billing with no other visible change. `claude -p` tolerates the
variable being present but *empty* (`is_error:false`), so an empty assignment
breaks nothing today — it is just a slot waiting for a paste.

## Known-bad in this repo

- **`adapters/claude/.../hooks.json`** — its PreToolUse regex duplicates what
  lefthook already blocks (ADR-0003). A breakage source, not a gate. Remove it
  or reduce it to a genuine tripwire.
