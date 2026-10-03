# shellcheck shell=bash
# =============================================================================
# Where Forge keeps its own state on the host — ONE definition, sourced.
#
# A worker's terminal cannot write the board (the kernel fences it: `hermes
# kanban comment`, `heartbeat`, `block`, `request-review` ... are all refused;
# epic S6d, P24), so anything a worker's PROGRAM must leave behind for a later
# reader — the lane's session record and its validated hand-off envelope, the
# verifier's verdict — goes on the host instead. Three programs agree on where:
#
#   scripts/lane.sh            writes lane-sessions/<board>-<task>[.metadata.json]
#   scripts/prejudge-review.sh reads that envelope; writes verdicts/<board>-<task>.json
#   scripts/merge-watcher.sh   reads verdicts/<board>-<task>.json
#
# The root is `$HOME/.forge`, which is what `lane.sh` has always resolved for
# `lane-sessions` (and what `~/.forge/repo/scripts/...`, the only path that
# resolves from a project worktree, already depends on). It is the same for
# every profile on this host: Hermes keeps the REAL home in a host's subprocess
# env (`hermes_constants.get_subprocess_home`, mode `auto`), measured in run A,
# where a fenced lane wrote `/Users/goonlab/.forge/lane-sessions/...` and no
# profile-local `home/.forge` exists. A host that gave a profile its own HOME
# would break `~/.forge/repo/...` first.
#
# Sourced, never executed. Every consumer is bash; do not add a second parser
# or a second formula for these paths. `FORGE_STATE_ROOT` and the two narrower
# overrides exist so a case can aim a program at a throwaway directory.
# =============================================================================
forge_state_root()        { printf '%s' "${FORGE_STATE_ROOT:-$HOME/.forge}"; }
forge_lane_session_root() { printf '%s' "${FORGE_LANE_SESSION_ROOT:-$(forge_state_root)/lane-sessions}"; }
forge_verdict_root()      { printf '%s' "${FORGE_VERDICT_ROOT:-$(forge_state_root)/verdicts}"; }
