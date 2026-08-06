#!/usr/bin/env bash
# Prepare and validate a lane's worktree, before Codex is handed anything.
#
# This is §2 and §3 of `skills/forge-lane/SKILL.md` as a program. Both sections
# were pure mechanism — land, check, fetch, build, baseline — described in prose
# that the driver retyped on every run. ADR-0010 made the same move for
# `forge-prejudge`: what a driver DOES is a script; what it DECIDES stays in the
# prompt. The decisions here (block or proceed, and with what reason) are still
# the model's, and stay in the skill.
#
# WHY THE ENVIRONMENT MUST BE BUILT HERE, BY THE LANE, WITH A NETWORK.
# `codex exec -s workspace-write` has NO network, and a dispatcher worktree is a
# fresh checkout with no `.venv`. If the lane does not build it while it still
# can, Codex lands somewhere `make check` cannot run — and it does not stop. It
# improvises an environment and hands back a green from a command CI never runs
# (`docs/hermes-field-notes.md` § Codex). A lane that ships a broken environment
# gets back a fabricated green, so `make setup` failing is a block, never
# something to hand to Codex.
#
# WHY THE WORKSPACE IS NOT CREATED HERE. The dispatcher creates the worktree
# BEFORE it spawns the lane and checks it out on $HERMES_KANBAN_BRANCH. Creating
# it again cannot work: the branch is already checked out at that exact path, so
# any re-add fails, and the driver then exits without a terminator — which the
# kernel reaps as `crashed`, ticking the failure counter for a fault that was
# never the chunk's.
#
# Usage:  lane-setup.sh <workspace>
#
# Exit:  0  ready — baseline green, environment built
#        2  usage
#        3  substrate: the workspace is not a git checkout
#        4  env: `make setup` failed — the environment cannot be built
#        5  failing-prereq: the baseline was already red before the chunk began
#
# 1 is deliberately unused, so a caller running under `set -e` cannot mistake a
# reported condition for a crash — the same contract ADR-0010 gave the prejudge
# protocol. Every non-zero exit prints a `reason_class=` line on stdout in the
# vocabulary the board already uses, so the driver can quote it into a block
# rather than compose one.
set -uo pipefail

WS="${1:-}"
[ -n "$WS" ] || { echo "usage: lane-setup.sh <workspace>" >&2; exit 2; }

cd "$WS" 2>/dev/null || {
  echo "reason_class=env: workspace $WS does not exist"
  exit 3
}

# A worktree that is not a checkout is a substrate fault, not a chunk failure.
# It must be reported and blocked, never "repaired" by the lane.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "reason_class=env: workspace $WS is not a git checkout"
  exit 3
}

# The sandbox cannot fetch; start-chunk §3 assumes this already happened.
git fetch origin >/dev/null 2>&1 || true

make setup >/dev/null 2>&1 || {
  echo "reason_class=env: 'make setup' failed in $WS — the environment cannot be built"
  exit 4
}

# Baseline. A red `make check` here predates the chunk, so it is a failing
# prerequisite rather than anything Codex did — and running the chunk on top of
# it would make the two indistinguishable afterwards.
make check >/dev/null 2>&1 || {
  echo "reason_class=failing-prereq: baseline 'make check' was already red before the chunk started"
  exit 5
}

echo "lane-setup: ready — environment built, baseline green"
