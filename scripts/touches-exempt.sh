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
#
# ROADMAP.md matches at either `docs/ROADMAP.md` (the location `skills/roadmap`
# and `skills/architect` both write) or a bare repo-root `ROADMAP.md`. The
# METHODOLOGY obligation this list exists for — every chunk ticks its roadmap
# checkbox — does not depend on which of the two a given project chose, and a
# project that keeps it at root is not exempt from being exempt. Measured on
# JobApp (`jobapp-second-instance`, 2026-09-04, CHUNK-C14 and CHUNK-C18 the
# same day): the anchored `^docs/ROADMAP\.md$` never matched that project's
# root-level file, so `touches` warned on every single PR regardless of what
# any card declared, and the two chunks recorded opposite workarounds — one
# widened `Touches` past `roadmap-check.sh`'s own `TOUCHES_MAX` to silence it,
# the other declined and left the warn structurally unfixable. `docs/chunks/`
# is left `docs/`-anchored: `skills/roadmap` always writes chunk contracts
# there and no project run has ever moved it.
TOUCHES_EXEMPT='^docs/decision-log\.md$|^(docs/)?ROADMAP\.md$|^docs/chunks/'
