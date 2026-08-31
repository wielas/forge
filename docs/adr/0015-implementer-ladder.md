# ADR-0015: The implementer is a configured component, not a hardcoded command

**Status:** proposed · 2026-08-19 · supersedes nothing; amends ADR-0004 D4.1

## Context

The implementer — the agent that actually writes the retained diff — is named
in exactly one place that matters: the literal string `codex exec` in
`skills/forge-lane/SKILL.md` §4, a skill body executed by a machine. Changing
provider today means editing a protocol document and the six conformance checks
that grep it.

Its configuration is spread across three unrelated mechanisms, none of which
describe a *provider*:

| what | where | how it is checked |
|---|---|---|
| Codex model + effort | `~/.codex/config.toml` — outside version control | `verify.sh` `sed`-scrapes prose from `forge-lane` §4 **and** `docs/state.md`, compares them to each other and to the live file |
| Hermes driver/router models | `FORGE_MODEL_*` shell defaults in `hermes/profiles-bootstrap.sh` | compared against a prose block in `docs/state.md` |
| the provider itself | hardcoded in a skill body | `verify.sh:1442`, `:1469` grep for the literal command |

A pin whose source of truth is an operator's home directory, cross-checked by
scraping English out of two documents, is the shape of problem ADR-0003 exists
to forbid. There is also no fallback of any kind: `forge-lane` §4 says that if
Codex is unavailable, block the card.

### What was measured, 2026-08-19

Against the installed `hermes` (`~/.local/bin/hermes`) and `codex`, reading
`--help` only — no model was spawned and nothing was spent:

- **`hermes -z/--oneshot` is a real headless implementer**, structurally
  parallel to `codex exec`: `-m MODEL`, `--provider`, `--reasoning`,
  `-t TOOLSETS`, `--in DIR`, `--skills`, `--worktree`. It prints only the final
  response, and `--usage-file PATH` writes a JSON cost/token report **even when
  the run fails** — strictly better telemetry than Codex offers today.
- **`hermes -z` has no sandbox, and bypasses the approval gate.** Its own help
  states: *"approvals are auto-bypassed. Intended for scripts / pipes."* Hermes
  has no OS-level write confinement at all — `hermes security` is an OSV
  dependency scan and `hermes approvals` is a command-allowlist policy, which a
  direct `file`-toolset write never reaches. This is the load-bearing
  asymmetry against `codex exec -s workspace-write`, which is kernel-enforced.
- **`hermes fallback` exists and is the wrong layer.** It retries the *primary
  model* on rate-limit/overload/connection errors, silently and automatically,
  inside one agent. It cannot express "a different implementer component, with
  a human's consent." It is currently empty (`No fallback providers
  configured.`) and this ADR does not populate it.
- **The live pin has already drifted, and `make verify` caught it today.**
  `config/codex-pin-live` FAILs on this machine: *"live Codex pin is
  `gpt-5.6-sol/high`; checked-in pin is `gpt-5.6-sol/xhigh`."* The implementer's
  reasoning effort was silently lowered in a home-directory file. Nothing in
  version control changed, no run recorded the change, and every chunk
  implemented since then ran at an effort the repo still claims it does not use.
  This is the motivating defect, observed rather than hypothesised — and it is
  the F22 failure shape (*"a model pin changing mid-run confounded the one chunk
  that failed, because nothing recorded that the pin had moved"*, `verify.sh:516`)
  recurring on the one pin that has no checked-in home.

- **`kanban_block` carries no metadata** (`scripts/metrics.sh:450`). Structured
  facts cannot be attached to a block; only the reason string survives.
- **`metrics.sh` derives a block's class generically** from the `<token>:`
  prefix (`:466-471`) and *retains the whole reason string alongside it*
  (`:456`). New classes are countable without code changes — but
  `blocked_reason_pattern` in `rubrics/run-metadata-contract.json` is a closed
  enum that `validate-metadata.py` enforces.

## Decision

**D15.1 — One checked-in ladder, read by a program.** The ordered implementer
ladder lives in `config/implementers.json`, in version control. A new
`scripts/implementer.sh` is its only reader; skills reach it as
`~/.forge/repo/scripts/implementer.sh` (the CLAUDE.md invariant), and
`forge-lane` §4 runs the command the resolver returns instead of naming one.
This is ADR-0010's pattern — the protocol is a program — applied to the last
piece of the lane that is still prose.

Each rung declares, at minimum, what the resolver and the gates need to read:
identity, provider, model, effort, whether it is `subscription` or `metered`,
which credential it uses, whether consent is required, whether it is enabled,
and how to build its argv. **The exact field names and file shape are decided
when the file is written, not here** — this ADR fixes the requirement, and the
schema is settled in the implementing chunk alongside the check that asserts
it. Nothing below should be read as a normative key list.
Changing model or provider is then a one-line edit to one file, and the same
file is what `verify.sh` and `preflight.sh` read — so the pin cannot drift from
its own documentation, because there is only one of it.

Initial ladder: rung 0 `codex exec` / `gpt-5.6-sol` / `xhigh` / subscription;
rung 1 `hermes -z` / `deepseek/deepseek-v4-flash-0731` / metered, consent
required.

**D15.2 — Only *availability* escalates. Difficulty never does.** This is the
spine of the design. A weaker model retrying work a stronger one failed spends
money to produce worse code, and it corrupts the one signal the flywheel has.

- `env:` — the provider could not run (CLI absent, auth expired, rate-limited,
  overloaded) → **eligible** for the consent gate.
- `ci-red`, `stale-spec`, `failing-prereq`, `judge-bounce` → block exactly as
  today. **Never eligible**, regardless of what a card body or an operator
  comment says.

`implementer.sh` refuses to resolve any rung above 0 unless handed a class from
the eligible set. The rule is a program, not an instruction an LLM re-reads.

**D15.3 — Escalation is consent-gated, per card, and fail-closed.** The lane
never auto-escalates. On an eligible failure it comments the evidence, then
blocks `needs_input` and stops without touching the branch. The operator
unblocks with a comment carrying an explicit token:

```
forge: approve-fallback rung=1 model=deepseek/deepseek-v4-flash-0731
```

`implementer.sh consent-check` re-resolves the ladder and **invalidates the
token if the named model differs from what rung 1 now resolves to** — an
approval granted on Monday for a cheap model must not authorize whatever the
ladder says on Friday. No token, or a stale one, blocks again. This reuses the
substrate exactly as `forge-lane` §1a's bounce-remediation path already does,
and honours the standing rule that a headless lane must never call `clarify`.

**D15.4 — Reuse the `env:` block class; do not bump the contract.** The
consent-wait blocks as
`env: fallback-consent rung=1 <provider>/<model> awaits approval — <evidence>`.
Because `metrics.sh` keeps the whole reason beside the derived class, the
`fallback-consent` marker is greppable and countable without migrating
`run-metadata-contract.json` to v2 — which would otherwise split every existing
completed run row across two contract versions to buy one counter.

**D15.5 — Rung 1 has no containment, so it does not ship without one.**
Under `codex exec`, `lane-blast-radius.sh` is a *second* layer behind an
OS-enforced sandbox. Under `hermes -z` it would be the *only* layer, and it
runs after the fact. That is a materially different risk posture and it is the
one thing that could sink this design, so it is called out as a decision rather
than a risk note. Rung 1 stays `enabled: false` in the ladder until one of:

- **(a) Impose a sandbox.** Wrap `hermes -z` in a macOS `sandbox-exec` profile
  mirroring `workspace-write` (worktree + `$TMPDIR` + the shared `.git`).
  Restores parity; costs a hand-written and separately verified profile.
- **(b) Deny it `.git` and let the driver commit.** Run the implementer with
  the worktree writable but the shared `.git` outside its reach, then have the
  lane commit the inspected result. Committing a diff is not authoring one, so
  D15.7 survives — but it diverges from rung 0's flow.
- **(c) Accept audit-only containment**, with the consent gate as the
  compensating control and the blast-radius audit as the sole check.

**(a) is recommended but UNPROVEN.** No `sandbox-exec` profile has been
written or measured, and `hermes -z` has never been run under one; whether it
survives that confinement — `uv`, git, and the toolset writes all included — is
an open measurement, not a result. Treat (a) as the preferred hypothesis until
a probe says otherwise. (c) is defensible only because rung 1 cannot run
without a human first approving that specific card.

**D15.6 — The rung that implemented is recorded.** `forge.chunk.v1` is
`additionalProperties: true`, so `implementer_rung`, `implementer_consent` and
`implementer_fallback_reason` are added alongside the existing required
`worker` string (`"codex/gpt-5.6-sol xhigh"`) without a schema break. A
fallback that is not recorded is a silent quality change; recorded, implementer
choice becomes a measured variable the L5 flywheel can compare chunks across.

**D15.7 — The role boundary is restated provider-neutrally, not weakened.**
"The driver never authors the retained diff" becomes "the driver never authors
the retained diff with its own tools; it delegates to the resolved implementer
process." Both rungs are separate processes, so the invariant is unchanged in
substance — but its conformance checks currently grep for the literal string
`codex exec` and must be rewritten to the resolved command, or they degrade to
a skip exactly as CLAUDE.md warns.

## Consequences

**This ADR amends ADR-0004 D4.1.** That table lists the implementation lane as
`codex exec` on a ChatGPT subscription, marginal cost *none*, and permits
OpenRouter only for "Hermes's own routing / aux — small, bounded." Rung 1 makes
the **heaviest token consumer in the system** a metered call site. D4.1 demands
that metering be justified per call site; D15.3's consent gate *is* that
justification, and the bound is now the human approval plus whatever
`--usage-file` records. D4.2's preflight gate is unaffected — deepseek routes
on `OPENROUTER_API_KEY`, which that gate deliberately permits.

**The real scope is the checks, not the resolver.** Every one of these reads
the current hardcoded shape and will break or silently degrade:

| site | what it does today |
|---|---|
| `verify.sh:181` `load_checked_in_codex_pins` | `sed`-scrapes the §4 prose bullet + `docs/state.md` |
| `verify.sh:196` `codex_live_pin_diagnostic` | reads `~/.codex/config.toml` |
| `verify.sh:470-482` `cli/codex-pin-documented` | asserts the two prose pins agree |
| `verify.sh:531-548` `config/model-pin-documented` | scrapes `FORGE_MODEL_*` vs `docs/state.md` |
| `verify.sh:560-587` `config/codex-pin-live` | live pin comparison + two-value diagnostic |
| `verify.sh:1442` `lane/env-prepared-before-codex` | greps `UV_CACHE_DIR=.*codex exec` for ordering |
| `verify.sh:1469` `lane/driver-never-authors-diff` | greps `` goes through `codex exec` `` in the SOUL |
| `preflight.sh:419` | per-profile live config readback |

Per ADR-0003, each replacement claim needs its check in the same change —
and here the usual reassurance is inverted. CLAUDE.md warns that a moved anchor
degrades a check to a skip; these do the opposite. `verify.sh:537-542` calls
`bad` unconditionally when the scrape returns empty, so deleting the prose pin
block from `docs/state.md` *before* landing its replacement turns
`config/model-pin-documented` and `cli/codex-pin-documented` red rather than
quiet. The removal and the replacement must land together, in that one change.

- `hermes/profiles-bootstrap.sh` keeps `FORGE_MODEL_DRIVER` — the *driver's*
  model is a different thing from the *implementer's*, and conflating them is
  the confusion this ADR removes. That it is already
  `deepseek/deepseek-v4-flash-0731` is a coincidence of naming, not a shared
  setting.
- `docs/state.md` stops carrying pins as prose to be scraped and points at
  `config/implementers.json` instead.

## Rejected

- **`hermes fallback add`.** Wrong layer: automatic, silent, model-only, and
  invisible to the board. It cannot express consent, and a fallback nobody
  observes is the failure mode D15.6 exists to prevent.
- **Bumping `run-metadata-contract.json` to v2** for a `fallback-consent`
  class — a contract migration bought for one counter that D15.4 obtains free.
- **Auto-escalation on any failure.** See D15.2. This is the design's spine.
