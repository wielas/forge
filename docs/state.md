# Forge — current state

One page, for a session or a person starting with no context. It says what works, what is
not proven, and what is next. History lives in [`docs/archive/`](archive/); the plan and
the only progress record is [`docs/epic-hands-free.md`](epic-hands-free.md) (its *Session
plan* table, and *§ How we run this epic* for how a session is run). If this page and
another file disagree, `make verify` arbitrates.

**As of 2026-11-14.** `main` and the live runtime (`~/dev/forge-runtime`) are at `46d8eb8`.
`make preflight` in the runtime reads PASS 143 / WARN 5 / FAIL 0; the five WARNs are the
optional global lefthook and the four forge-gate bot steps (below).

## What Forge is

A way to build software from a plan with the operator out of the per-chunk loop. The plan
is made interactively (`/scope`, `/architect`, `/roadmap`). After that a Hermes board runs
it: a lane drives Codex in a worktree and opens a PR, a verifier executes the checks and
judges it, and the PR is merged — by the operator from a hold, or by the verifier where the
board has a merge-authority grant. Each milestone ends in a gate card with a whole-system
probe. The operator reads a daily digest and answers holds.

## Next: the owner's go for run B

Run B is milestone 2 of The Squatfather (CHUNK-6, 7, 8, then `GATE-M2`) on board
`squatfather-run-a2`, and the first run in which the verifier merges. The protocol is
[`docs/run-b.md`](run-b.md). Steps 1 to 6 of its launch are done (2026-11-14). What is
left is the owner's, because it hands merge authority to the machine:

```bash
~/.forge/repo/scripts/merge-authority.sh grant squatfather-run-a2 --by <you> --reason "run B"
~/.forge/repo/scripts/checkpoint-arm.sh arm --board squatfather-run-a2 --gate GATE-M1 --project "$HOME/dev/the-squatfather" --mode apply --confirm-release
hermes cron resume 3f8cc5b95565     # the forge-checkpoint job, created paused
```

Within 15 minutes the cron probes M1 (it passes 5 of 5 today), completes `GATE-M1`, and
CHUNK-6 and CHUNK-8 start. To stop: `merge-authority.sh revoke squatfather-run-a2`.
Leave `GATE-M2` unarmed until the checkpoint-freshness fix is deployed (see *Known gaps*).

## Proven (a command was run and its output observed)

| Claim | Evidence |
|---|---|
| A plan becomes merged, probed code | Run A, Squatfather M1: CHUNK-1 to 5 merged on green CI, four of them lane-built; the M1 probe passes 5 of 5. [`docs/run-a.md`](run-a.md) *Results* |
| The verifier's recommendations can be trusted so far | Run A: the operator merged everything it recommended and bounced nothing; it bounced CHUNK-4 itself first |
| **Merge mode works live** | 2026-11-14, board `hello-rehearsal-a2h`, card `t_35fdac2e`: ready → PR `wielas/hello-forge#13` → CI green → verifier approve → merged → done in about 3 minutes, no operator action. Evidence: `~/forge-evidence/run-b-launch-2026-11-14/` |
| A board follows a changed plan | `hermes/board-sync.sh --apply` on the live Squatfather board, 2026-11-14: 14 steps, each read back, ends in sync, releases nothing |
| The checkpoint cron reports once and writes nothing in rehearse | `GATE-M1` armed `rehearse`, the cron script run twice: one report (pass, 5 of 5), then silence; the gate stayed held |
| A bounce, a crash after push, a red CI and a quota park each recover | July ladder and fault exercises; run A's D-1 drill and resumed Codex run. Details in the archive |
| The tier-1 gate, the lane protocol and the gate verbs behave as written, offline | `make verify` (CI runs all of it on every PR; it is a required check) |

## Not proven

- **Hands-free merges on a real product.** That is run B. One hello-forge card is not a milestone.
- **The gate verbs over Telegram** (`/accept`, `/redirect`, `/park`). The forge-gate bot does
  not exist yet (BotFather, the profile, the plugin, `FORGE_OPERATOR_TELEGRAM_ID`). Without
  it a checkpoint that blocks is answered from a terminal; one that passes needs no answer.
- **Recovery from a restart.** FileVault is on, so nothing runs after a reboot until someone
  unlocks the disk, and nothing on the host can say so. Only an external heartbeat URL in
  `~/.forge/watchdog.env` would report it; none is configured.
- **A real watchdog alert.** It has only ever read healthy.
- **The mutation probe's precision.** It reports and never bounces; read at the M2 checkpoint.

## Known gaps, with the fix in hand

- **The checkpoint probes the local product checkout, and nothing fast-forwards it.** After
  the verifier merges on GitHub the local `main` is stale, so `GATE-M2`'s probe would judge a
  tree without milestone 2. Fix: the cron fetches and fast-forwards first
  (`slice/checkpoint-fresh-checkout`). Until it is deployed, do not arm `GATE-M2`.
- **The verifier's token is checked for presence, not life.** A dead `CLAUDE_CODE_OAUTH_TOKEN`
  passed preflight and failed two rehearsals in October. The stripped-environment probe in
  `docs/run-a.md` (precondition 9, T1) is the manual check; it belongs in the watchdog.
- **The operator's surface is a dozen script paths.** A `forge` command (`status`, `stop`,
  then `go` and `rehearse`) is being built (`slice/forge-cli`).

## Starting a new project

```bash
make new NAME=my-project DEST=$HOME/dev
# in Claude Code, in the project: /scope, then /architect, then /roadmap
PROJECT=/absolute/path/to/product
make roadmap-check PROJECT="$PROJECT"   # repeat until CLEAR
make commission PROJECT="$PROJECT" BOARD=<slug>       # paid; optional evidence
cd "$PROJECT" && ~/.forge/repo/hermes/board-bootstrap.sh <slug>
```

[`docs/operator-guide.md`](operator-guide.md) is the long form.

## Where things live

- `~/dev/forge` — the dev checkout. Slices are built here on `slice/*` branches, merged by PR;
  ruleset `mainprotect` requires green `validate` and `verify`.
- `~/dev/forge-runtime` — what every Hermes profile executes (`~/.forge/repo` points at it).
  It changes only by `git pull --ff-only` after a merge, followed by `make preflight`.
  **Never `make verify` there:** its mutation harnesses edit scripts the live cron runs.
- `~/.forge/` — host state: verdicts, grants, gate arming, the watchdog's log.
- `~/forge-evidence/` — pasted evidence that is not committed (the products are private).

## Environment as of this writing

Tool versions as recorded on 2026-11-06; `make preflight` section 10 compares them with the
live binaries and WARNs on drift.

```
Hermes 0.21.5 · codex-cli 0.164.0 · Claude Code 2.1.318 · gh 2.103.2
lefthook 2.1.10 · uv 0.13.5 · copier 9.17.0
mini: Goons-Mac-mini.local, gateway supervised by launchd, dispatch every 60s
profiles: forge-orchestrator, forge-codex-lane, forge-verifier,
          forge-digest (glm-5.3-flash) · codex pinned gpt-5.6-luna xhigh
```
