# Hermes field notes — how the substrate actually behaves

Durable reference for the parts of Hermes, Codex and Claude Code that cost us a
day to learn and that no amount of reading the docs would have taught us. Every
entry is something a running system told us, with the command that showed it.

**This file holds no state.** Versions, board names, config values and auth
status change under you; `make preflight` establishes those in one read-only run,
and a written copy would just be a lie with a date on it. Run preflight after
every `hermes update` — config drifts across upgrades (0.18.2 → 0.19.0 silently
changed `approvals.mode` and `goals.max_turns`).

Decisions live in `docs/adr/`. This file is evidence, not intent.

---

## The traps: documented-but-untrue, or silent

**`custom_toolsets:` does nothing.** It is documented in
`website/docs/reference/toolsets-reference.md`, and no code in 0.19.0 reads it. A
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

## How things really connect

**Profiles** are separate `HERMES_HOME` directories created with `hermes profile
create <name> --description "<role>"`; the description feeds orchestrator routing.
There is no `profiles:` block in `config.yaml`.

**Worker lifecycle.** A dispatched worker must end in exactly one of
`kanban_complete` or `kanban_block`. Exiting without either is reaped as
`crashed`: `consecutive_failures` ticks and the breaker blocks the card once it
trips (`--max-retries`, default `kanban.failure_limit`=2). Heartbeat at least
hourly on long work — the dispatcher reclaims a task running past
`kanban.dispatch_stale_timeout_seconds` (4h) with no heartbeat in the last hour.
A reclaim re-queues without penalty but loses the run's progress.

**Long work does not need forge machinery.** `terminal.timeout` (1800s) caps a
*synchronous* command, but the terminal tool takes `background=True, pty=True,
notify_on_complete=True` and the `process` tool polls it. That is native, so cap
chunk size for good reasons — not to dodge a timeout.

**Bounce dynamics are board-native.** The respawn guard already refuses re-spawn
on `blocker_auth` (quota/auth), `recent_success` and `active_pr`. Use
`--max-retries` per card; do not invent a bounce loop.

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
