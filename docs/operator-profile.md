# Operator profile

> Curated onboarding record, 2026-07-10. Future sessions: read this before
> assuming anything about the operator. Labels: [V] verified this session,
> [I] interview answer this session, [H] inherited from prior-session capsule.

## Identity & style
- [H] AI-fascinated CS MSc; creative builder. Python strongest, pragmatically
  polyglot. Confirmed "roughly right" by operator.
- [H] Dislikes grinding on bug fixes; loves tinkering with the AI setup itself.
- [H] Involvement level: judge report + spot-checks, NOT reviewing every PR.
- [H] Pain ranking: 1) repeated per-project setup, 2) can't trust unreviewed
  output, 3) serial execution slow, 4) knowledge doesn't carry over.

## Environment
- [V] Interactive dev machine: MacBook Air (M1), fish shell, macOS (Darwin 25.5).
- [V] Codex CLI 0.143.0 installed, logged in via ChatGPT plan (headless-capable).
- [V] gh authenticated as `wielas` (ssh, repo scope). Repos live under
  github.com/wielas (personal account).
- [V] uv + jq present; `copier` and `lefthook` NOT installed on the MacBook.
- [V] Always-on Mac mini: ssh alias **`macminlab`**, user **`goonlab`**, host
  `Goons-Mac-mini.local`, arm64, Darwin 25.5. (Corrected 2026-07-27 — the
  earlier `macmini`/`goonlagoon` entry was wrong.) Non-interactive ssh from
  sandboxed sessions fails (agent signing); ask the operator to run
  `! ssh macminlab '...'` for ground truth, and use a **login** shell
  (`bash -lc`) or PATH will be bare.
- [V] On the mini: hermes gateway running with the embedded dispatcher, a hermes
  launchd job, `kanban.db` present, `terminal.timeout=1800`,
  `approvals.mode=off`, `skills.write_approval=false`, `goals.max_turns=60`,
  one profile (`builder`). `claude`/`gh`/`git`/`make` reachable from the
  gateway's PATH; **`codex` is not**.
- [V] On the mini: **Hermes Agent v0.18.2** (2026.7.7.2), **Claude Code 2.1.204**
  installed at `~/.hermes/node/bin/claude` (under Hermes's bundled node, not a
  standalone install), **gh 2.92.0**, git/jq/uv via Homebrew, `copier` missing,
  `codex` **not installed**. Claude Code is **not logged in** as `goonlab`.
- [V] `forge/` is a git repo as of 2026-07-27, remote
  `git@github.com:wielas/forge.git`, push pending.

## Decisions from onboarding interview (2026-07-10)
- [I] First Forge tenant after hello-chunk: a FRESH project (no migration debt),
  not AnkiAI/JobApp/HermesCoach.
- [I] Two-week "done": one real unattended night-run that produced a mergeable
  PR, with the first tenant on the board. Not full daily-driver yet.
- [I] Judge lane budget: NO metered API spend. Judge runs on subscription —
  tier-1 `claude -p` with the OAuth token, tier-2 interactive. ADR-0004 was
  rewritten on 2026-07-27 to match: its old "Lane C = metered strong model" is
  withdrawn, so this is no longer an exception to the ADR but the ADR itself.
- [I] Merge policy: auto-merge judge-approved PRs ONLY when the chunk was
  tagged low-risk at roadmap time; everything else waits for a human tap.
- [I] Notification channel: iMessage (NOT Telegram as prior session assumed).
  Scriptable from the mini; native on all devices.

## Standing corrections to the prior-session capsule
- Telegram → iMessage everywhere (board pings, judge verdicts, gate prompts).
- Lane C "metered strong model" is deferred; design the judge path to work
  without API billing first.
