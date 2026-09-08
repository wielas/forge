# ADR-0018: A pin stated four times is four pins; there is one file and `source` is its only parser

- Status: accepted
- Date: 2026-09-08
- Constrains: ADR-0003 (a claim in a skill body must be assertable), and every
  future model bump — router, driver, or Codex.

## Context

Forge pins three models. Until this ADR each pin was stated in **four places in
four different shapes**, and each shape had its own `sed` in `scripts/verify.sh`
that existed only to reconcile it with the others:

| # | Where | Shape | Read by |
|---|---|---|---|
| 1 | `hermes/profiles-bootstrap.sh:56-57` | `MODEL_ROUTER="${FORGE_MODEL_ROUTER:-z-ai/glm-5.3-flash}"` | `cli/model-pin-documented` (offline) and `config/model-pin-live/<profile>` (live) |
| 2 | `docs/state.md` environment block | prose, **vendor-stripped** (`glm-5.3-flash`) | a `sed` range `/^profiles: forge-orchestrator/,/codex pinned/` |
| 3 | `docs/state.md` again | prose, `codex pinned gpt-5.6-luna xhigh` | a second `sed`, positional |
| 4 | `skills/forge-lane/SKILL.md` §4 | prose, ``(`gpt-5.6-luna`, reasoning `xhigh`)`` | a `sed` RANGE anchored on two literal sentences |

A fifth statement was pure prose with no reader at all: the comment above
`profiles-bootstrap.sh:56` recording *when* the pin moved and to what.

Two costs, both measured on this repository rather than imagined:

**Swapping a model is a five-file hand-edit.** Nothing links the five, so the
cost is paid in attention every time, and F22 measured what a half-applied pin
costs: a pin that moved mid-run confounded the one chunk that failed, because
nothing recorded that it had moved.

**A reworded edit makes the guard go blind, not red.** Every one of those
readers is a `sed` anchored to text a human is expected to keep intact —
shape 4 is anchored to two *English sentences*. That is F65 exactly: reword
"the pin lives in `~/.codex/config.toml`" and the extraction yields the empty
string, `load_checked_in_codex_pins` returns non-zero, and what the operator
sees depends entirely on whether the author of that arm wrote `bad` or `skip`.
F65, F66 and PR #20's reason sweep are all the same defect: **a check anchored
to content that moved degrades quietly.**

## Decision

**D18.1 — One machine-readable source of truth: `scripts/model-pins.sh`.** Four
assignments, nothing else:

```
FORGE_PIN_ROUTER="z-ai/glm-5.3-flash"
FORGE_PIN_DRIVER="z-ai/glm-5.3-flash"
FORGE_PIN_CODEX_MODEL="gpt-5.6-luna"
FORGE_PIN_CODEX_EFFORT="xhigh"
```

It is **sourced, never executed**, so it is checked in non-executable
(`rw-r--r--`) — the same shape as `scripts/touches-exempt.sh`, the existing
precedent for "one definition, two readers". Naming it `.sh` earns it `bash -n`
coverage from `make validate`, which is added to that target's hardcoded list in
the same commit.

The prose statements do not go away — a skill body and a state document must
still *say* what is pinned, for a reader who is a human or a model. What goes
away is prose being a **source**. Every prose copy is now a derived statement
checked against the file.

**D18.2 — `source` is the only parser.** This is the load-bearing rule. If
`profiles-bootstrap.sh` sources the file and `verify.sh` `sed`s it, four shapes
have become one file read two ways, and the second reader can drift from the
first exactly as before — the same defect one layer down, with a reassuring
filename on it. Every consumer is bash, so every consumer sources it.

`verify.sh` sources it through one helper, `load_model_pins`, which runs the
`.` **inside a command substitution** so the suite's own environment is never
mutated by the file it is judging, and which `unset`s the four names first so a
value leaking in from the environment cannot mask a pin the file fails to
define.

**D18.3 — Env-shaped, not JSON, because `jq` is `skip`-guarded eleven times.**
JSON is the obvious answer and it is wrong here. `scripts/verify.sh` guards
`jq` at eleven sites with `skip … "jq not on PATH"`, correctly — a suite that
hard-fails on a missing optional tool is a suite people stop running. But the
core pin checks live in `cli/`, the **offline** group that runs in CI precisely
so a pull request cannot merge with a drifted pin. A JSON pin would make that
check `skip` on a jq-less runner: the guard against the pin going wrong would
itself go quiet, which is F65's shape aimed at F65's own defence. A bash file
sourced by bash needs no tool that might be absent.

**D18.4 — `FORGE_PIN_*` is namespaced away from the override knobs.** The
operator overrides are `FORGE_MODEL_ROUTER`, `FORGE_MODEL_DRIVER` and
`FORGE_CODEX_MODEL`. The pin file **must not** define those names: sourcing it
would clobber an override that was deliberately exported, silently, and the
run would use the checked-in value while its operator believed otherwise. So
the file defines `FORGE_PIN_*` and the consumer composes:

```
MODEL_ROUTER="${FORGE_MODEL_ROUTER:-$FORGE_PIN_ROUTER}"
```

The override shape at the point of use is unchanged. `FORGE_PIN_*` is the
*default*; `FORGE_MODEL_*` still wins.

**D18.5 — The file is data, and a check says so.** `source` executes whatever
it is handed, so the safety of D18.2 rests on the file containing no code.
`cli/model-pin-file-is-data-not-code` requires every non-comment, non-blank
line to match `^FORGE_PIN_[A-Z_]+="[^"$\`\\]*"$` — no substitution, no
backtick, no escape — **and** requires all four names to be present, because
"no offending lines" is also true of an empty file, and a check that passes on
a file with nothing in it has gone blind again.

**D18.6 — `scripts/codex-run.sh` is deliberately not converted here, and a
separate `CODEX_HOME` was rejected outright.** codex-run.sh is the next slice.
Recording the rejected design now, because it is the option a future reader
will reach for first:

*Rejected: give forge its own `CODEX_HOME` and run `codex --ignore-user-config`.*
It looks clean — a fully reproducible Codex config under version control — and
it breaks two live facts. First, the operator's `~/.codex/config.toml` carries
roughly **thirty** `[projects."…"] trust_level = "trusted"` entries, including
the forge directory itself; dropping them makes a headless `codex exec` inside a
worktree prompt for trust or refuse, which in an unattended lane is a hang.
Second, codex **rename-replaces `auth.json` on token refresh**, so a symlink
from a forge-owned `CODEX_HOME` back at the real one survives exactly until the
first refresh and is then a dangling path — an auth failure appearing hours
into unattended work, attributable to nothing. The pin must therefore be
written *into* the operator's own config rather than replacing it.

## Consequences

- Bumping a model is **one edit** to `scripts/model-pins.sh`, then whatever
  prose `make verify` names as disagreeing. The suite enumerates the remaining
  work instead of the author remembering it.
- The prose readers still exist and are still `sed`-anchored — shape 4 in
  particular. They are now *comparators*, not sources, and every one of their
  "could not extract" arms is `bad` with the literal
  `the check went blind, which is not a pass (F65)`. Blindness reddens.
- `cli/` grew four cases: the repointed pair plus the data-not-code assertion
  and three mutations. Every one is offline, so all of it runs in CI on every
  pull request — which is where a pin drifts.
- A missing or unreadable `scripts/model-pins.sh` is `bad`, never `skip`, in
  `verify.sh`; and `exit 1` with a named path in `profiles-bootstrap.sh`, the
  guard shape `prejudge.sh` and `roadmap-check.sh` already use for
  `touches-exempt.sh`.
- The pin file is the natural place for provenance. The dated "confirmed
  present in the live OpenRouter catalogue" note moved out of
  `profiles-bootstrap.sh`'s comment and into the file's header, so the record
  of *why* a value is what it is sits next to the value.
