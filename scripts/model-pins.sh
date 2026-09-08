# shellcheck shell=bash
# =============================================================================
# The model pins. ONE source of truth, sourced by everything that needs one
# (ADR-0018). Sourced, never executed — hence no shebang and no `+x`, the same
# shape as `scripts/touches-exempt.sh`.
#
# WHY THIS FILE EXISTS: these three values used to be stated in four places in
# four different shapes — a shell default in `hermes/profiles-bootstrap.sh`, two
# prose sentences in `docs/state.md`, and a third in `skills/forge-lane/SKILL.md`
# §4 — each reconciled by its own `sed` in `scripts/verify.sh`. Swapping a model
# meant editing all four by hand, and rewording any one of them made its `sed`
# extract nothing, which is F65: the guard goes BLIND rather than red. The prose
# copies remain, because a skill body and a state document must still say what
# is pinned; they are now derived statements checked against this file.
#
# `source` IS THE ONLY PARSER. Do not add a `sed`, `grep -o` or `awk` reader for
# these values anywhere. Every consumer is bash; a second parser is the same
# four-shapes defect one layer down. `cli/model-pin-file-is-data-not-code`
# requires every line below to be a plain quoted assignment — no substitution,
# no backtick, no escape — which is what makes sourcing it safe.
#
# NAMESPACE: `FORGE_PIN_*`, deliberately NOT the operator override knobs
# `FORGE_MODEL_ROUTER`, `FORGE_MODEL_DRIVER`, `FORGE_CODEX_MODEL`. Sourcing this
# file must never clobber an override someone exported on purpose. Consumers
# compose: `MODEL_ROUTER="${FORGE_MODEL_ROUTER:-$FORGE_PIN_ROUTER}"`.
#
# The lane, prejudge and digest models only DRIVE another agent — the reasoning
# happens inside Codex — so cheap and fast is correct, not a compromise. Confirm
# ids against `hermes model` / OpenRouter before bumping them.
#
# Provenance:
#   2026-07-27  the checked-in values first matched the running system.
#   2026-09-08  both OpenRouter roles moved to `z-ai/glm-5.3-flash`, confirmed
#               present in the live catalogue before the line was written.
# =============================================================================

# Hermes profile model.default. The orchestrator decomposes, so it gets the
# router pin; the lane, prejudge and digest profiles only drive a shell.
FORGE_PIN_ROUTER="z-ai/glm-5.3-flash"
FORGE_PIN_DRIVER="z-ai/glm-5.3-flash"

# `~/.codex/config.toml`: the implementer that actually reasons. Overridable
# per card with `FORGE_CODEX_MODEL`; whichever ran is recorded in the chunk's
# completion metadata (F22).
FORGE_PIN_CODEX_MODEL="gpt-5.6-luna"
FORGE_PIN_CODEX_EFFORT="xhigh"
