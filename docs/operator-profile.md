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
- [V] Always-on Mac mini: ssh alias `macmini` (user `goonlagoon`,
  host goons-mac-mini). Non-interactive ssh from sandboxed sessions fails
  (agent signing); ask operator to run `! ssh macmini '...'` for ground truth.
- [ ] Hermes version on mini: PENDING (operator to run `! ssh macmini
  'hermes --version'`). Fill in when known.
- [V] The Forge working dir (`~/dev/The Forge`) is not yet a git repository.

## Decisions from onboarding interview (2026-07-10)
- [I] First Forge tenant after hello-chunk: a FRESH project (no migration debt),
  not AnkiAI/JobApp/HermesCoach.
- [I] Two-week "done": one real unattended night-run that produced a mergeable
  PR, with the first tenant on the board. Not full daily-driver yet.
- [I] Judge lane budget: NO metered API spend yet. Hold until Anthropic policy
  dust settles. Judge must run on subscription/interactive or manually for now.
  This supersedes ADR-0004's "Lane C = metered strong model" until revisited.
- [I] Merge policy: auto-merge judge-approved PRs ONLY when the chunk was
  tagged low-risk at roadmap time; everything else waits for a human tap.
- [I] Notification channel: iMessage (NOT Telegram as prior session assumed).
  Scriptable from the mini; native on all devices.

## Standing corrections to the prior-session capsule
- Telegram → iMessage everywhere (board pings, judge verdicts, gate prompts).
- Lane C "metered strong model" is deferred; design the judge path to work
  without API billing first.
