# shellcheck shell=bash
# =============================================================================
# The paths a chunk's `Touches:` list may not be held to (F55). Sourced, never
# copied: `scripts/prejudge.sh` reads it at review time and
# `scripts/roadmap-check.sh` reads it at plan time, and the whole point of the
# rule is that both agree.
#
# Not a convenience list. Each entry is a path the METHODOLOGY obliges every
# chunk to change and the contract template has no slot to declare, measured
# rather than assumed: of the five distinct drifting paths across the six chunks
# of the only real run, THREE are these — `docs/decision-log.md`,
# `docs/ROADMAP.md`, and `docs/chunks/*` (the contract recording its own
# amendment). Counting a file every chunk must edit and no chunk may declare
# manufactures a finding on every single PR, which is a gate nobody reads.
#
# A second copy that disagrees the first time one is edited is F30's defect
# class. `make verify`'s roadmap/touches-exemption-has-one-definition fails if a
# second `TOUCHES_EXEMPT=` assignment appears anywhere in the repo.
# =============================================================================
TOUCHES_EXEMPT='^docs/decision-log\.md$|^docs/ROADMAP\.md$|^docs/chunks/'
