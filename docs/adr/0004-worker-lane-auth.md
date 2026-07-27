# ADR-0004: Worker-lane auth — subscriptions everywhere, metering as the exception

**Status:** accepted · rewritten 2026-07-27 (replaces the 2026-07-09 version)

## Why this was rewritten, not patched

The original ADR rested on one operator observation: *"OAuth does not survive
into spawned/headless child sessions; only the interactively authenticated
shell."* Everything else followed from it — Claude was confined to interactive
work, and the judge lane was designed around a metered model because it was
assumed no unattended process could authenticate as a subscriber.

**That premise is false.** Measured on the mini, 2026-07-27, `preflight.sh` §3:

```
PASS  claude -p (normal env) responded (rc=0)
PASS  claude -p (stripped env, gateway-like) responded (rc=0)
PASS  codex exec (normal env) responded (rc=0)
PASS  codex exec (stripped env, gateway-like) responded (rc=0)
```

The stripped-env probe is the one that matters: `env -i` carrying only `HOME`,
`PATH`, `TERM` and `CLAUDE_CODE_OAUTH_TOKEN` — what a dispatcher-spawned child
gets. It succeeds. The original observation was almost certainly a **keychain**
artifact rather than an auth policy: on macOS the credentials live in the login
Keychain, which a non-GUI session may be unable to unlock, so the same binary
fails over SSH and works from a local Terminal. `claude setup-token` mints a
one-year subscription token that is read from the environment and needs no
keychain at all.

A whole lane design was derived from the bad premise, so patching would have left
the reasoning intact and changed only the conclusion. Hence a rewrite.

## Decision

**D4.1 — Subscription credentials are the default for every lane; metered access
is an exception that must be justified per call site.**

| Lane | Engine | Credential | Marginal cost |
|---|---|---|---|
| Implementation (unattended) | `codex exec` | ChatGPT plan login on the mini | none |
| Tier-1 prejudge (unattended) | `claude -p` | `CLAUDE_CODE_OAUTH_TOKEN` | none |
| Tier-2 judge (operator) | Claude Code `/judge` | interactive session | none |
| Hermes's own routing / aux | OpenRouter | `OPENROUTER_API_KEY` | small, bounded |

The change from the old ADR is the second row: the judge tier no longer has to be
metered, because a headless `claude -p` can authenticate as a subscriber. The old
"Lane C: metered strong model with a hard monthly budget" is withdrawn.

**D4.2 — The money invariant is a preflight gate, not a guideline.**
`preflight.sh` §2 FAILs on any `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` in the
environment or in `~/.hermes/.env`, and WARNs on an empty assignment. A gate
rather than a note because **`ANTHROPIC_API_KEY` outranks the OAuth token in
Claude Code's precedence order**: one pasted value silently converts every lane
to per-token billing with no other visible change.

**D4.3 — Pin the model, keep `~/.claude` lean.** A bare `claude -p "reply OK"` on
this machine defaulted to **Opus** and consumed ~20k tokens of auto-discovered
context (hooks, skills, plugins, MCP servers, CLAUDE.md) to answer with two
characters. Every MCP server installed there is re-paid on every invocation.
`--bare` would skip that discovery but **cannot read `CLAUDE_CODE_OAUTH_TOKEN`**,
and the only other credential is a metered key — so lanes run non-bare, pin
`--model` explicitly, and state their mode.

**D4.4 — `total_cost_usd` is a relative signal, never spend.** It is computed
locally at list rates; on a subscription it is not a bill. Use it to compare
runs, never to report cost.

## Consequences

- The judge is no longer the expensive tier, which removes the pressure to keep
  tier 1 cheap and shallow. Tier 1 can afford to read the whole diff.
- **Token expiry is now a single point of failure for two lanes.** The token
  lasts a year and does not auto-refresh; silent expiry kills unattended
  implementation *and* prejudge at the same moment. Cron the renewal date.
- How the token reaches a worker is not obvious and must not be re-derived by
  guessing: `hermes` loads `~/.hermes/.env` at import, so the **gateway's live
  `os.environ`** holds it, and the dispatcher spawns children with
  `env = dict(os.environ)`. `ps eww` cannot see it (macOS reports the exec-time
  environment), and a child's `HERMES_HOME` points at the *profile* directory, so
  `~/.hermes/profiles/<name>/.env` is what a hand-run worker reads.
- This ADR settles the **operational** question only. Whether a particular
  automated use is within a provider's terms is a separate question with its own
  timeline, and "the probe returned rc=0" does not answer it. Re-check before
  scaling past one operator's own machine.

## Rejected

- **Metered API keys for bulk implementation or deep review.** Ruled out by D4.2;
  this is the invariant the rest of the design protects.
- **`--bare` for lane invocations.** It cannot read the subscription token, so it
  forces exactly the credential we refuse to use.
- **tmux-puppeting an interactive Claude session** for unattended work: fragile,
  and it fakes interactivity instead of using the supported headless path we have
  now shown to work.
