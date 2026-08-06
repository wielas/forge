#!/usr/bin/env bash
# Bound what `codex exec` was allowed to touch, and prove it afterwards.
#
# This is §5's audit of `skills/forge-lane/SKILL.md` as a program.
#
# WHY THIS EXISTS AT ALL. §4 hands Codex `--add-dir "$(git rev-parse
# --git-common-dir)"`, because in a worktree the real `.git` lives in the main
# repo and `workspace-write` alone cannot commit. The sandbox banner then reads
# `workspace-write [workdir, /tmp, $TMPDIR, <repo>/.git]` — so Codex can write
# ALL of the shared `.git`: `hooks/` (the whole L2 local tier), `refs/heads/main`,
# `config`, and every other worktree's admin dir. Narrower grants were not
# attempted, because git needs objects, refs and the worktree admin dir together
# and a wrong guess breaks committing, which cost a rung to get working. The
# grant is therefore treated as BOUNDED RATHER THAN NARROW: it is wide, and this
# script is what checks the blast radius afterwards.
#
# "It only touched the worktree" is an assumption until it is measured. That is
# why `capture` must run BEFORE §4 and `check` after — a hash taken afterwards
# proves nothing.
#
# WHY HASHES AND NOT `git status`. The original probe was
# `git -C "$(git rev-parse --git-common-dir)" status --short hooks`, which did
# not inspect hooks at all: a common `.git` directory is not a worktree, so the
# command exits 128 every time. Measured on the first Codex-driven bounce
# repair, where the driver dismissed that error and later completed with `.orig`
# and `.rej` files still untracked. A check that cannot fail is not a check —
# so this one hashes the files and compares, and its own failure modes exit
# non-zero rather than being swallowed.
#
# Usage:  lane-blast-radius.sh capture <workspace>
#         lane-blast-radius.sh check   <workspace>
#
# Exit:  0  clean — main unmoved, hooks unchanged, worktree clean
#        2  usage, or `check` with no capture to compare against
#        3  breach — a moved `main`, an edited hook, or a dirty worktree
#
# 1 is deliberately unused (ADR-0010's contract), so a caller under `set -e`
# cannot read a breach as a crash. A breach is ALWAYS a `kanban_block`, never a
# push and never a retry: the run went outside its contract, and there is no way
# to tell from here what else it did.
set -uo pipefail

MODE="${1:-}" WS="${2:-}"
[ -n "$MODE" ] && [ -n "$WS" ] \
  || { echo "usage: lane-blast-radius.sh capture|check <workspace>" >&2; exit 2; }

cd "$WS" 2>/dev/null || { echo "blast-radius: workspace $WS does not exist" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "blast-radius: $WS is not a git checkout" >&2; exit 2; }

mkdir -p .forge
HOOKS="$(git rev-parse --git-path hooks)"

# `find` on a missing hooks dir is an error, not an empty set. An absent
# hooks directory is a legitimate state, so normalise it to an empty listing
# rather than letting the difference read as a breach.
hash_hooks() {
  [ -d "$HOOKS" ] || { : > "$1"; return 0; }
  find "$HOOKS" -maxdepth 1 -type f -exec shasum -a 256 {} + 2>/dev/null \
    | awk '{print $1}' | sort > "$1"
}

case "$MODE" in
  capture)
    git rev-parse main > .forge/main.before 2>/dev/null || : > .forge/main.before
    hash_hooks .forge/hooks.before
    echo "blast-radius: captured"
    ;;

  check)
    # A missing baseline means capture never ran. That is not a pass: it is the
    # check being unable to run, which must be louder than a clean result and
    # never quieter (audit F65 — a control that cannot find its baseline must
    # fail, not skip).
    [ -f .forge/main.before ] && [ -f .forge/hooks.before ] || {
      echo "blast-radius: no capture to compare against — capture must run BEFORE codex exec" >&2
      exit 2
    }

    breach=""
    main_now="$(git rev-parse main 2>/dev/null || true)"
    [ "$main_now" = "$(cat .forge/main.before)" ] || breach="$breach main-moved"

    hash_hooks .forge/hooks.after
    cmp -s .forge/hooks.before .forge/hooks.after || breach="$breach hooks-edited"

    # Untracked files included: the measured failure completed with `.orig` and
    # `.rej` files left behind, which a tracked-only check reports as clean.
    #
    # `.forge/` is excluded because it is the LANE'S OWN scratch area — the
    # contract, the codex transcript, and this script's own baselines all live
    # there. Counting the lane's bookkeeping as a Codex breach would block a
    # clean chunk. §5's original inline check did not exclude it and therefore
    # only worked on projects stamped from `templates/python-service`, whose
    # `.gitignore` happens to carry `.forge/` (line 11). On any other repo — and
    # `docs/open-questions.md` records that the operator's projects are not all
    # Python — the lane's own evidence files made its clean-worktree check fail.
    # Excluding by pathspec makes the check correct regardless of the target
    # project's `.gitignore` rather than by luck.
    [ -z "$(git status --porcelain --untracked-files=all -- ':(exclude).forge')" ] \
      || breach="$breach worktree-dirty"

    if [ -n "$breach" ]; then
      echo "reason_class=other: codex exceeded its contract —$breach"
      exit 3
    fi
    echo "blast-radius: clean — main unmoved, hooks unchanged, worktree clean"
    ;;

  *)
    echo "usage: lane-blast-radius.sh capture|check <workspace>" >&2; exit 2 ;;
esac
