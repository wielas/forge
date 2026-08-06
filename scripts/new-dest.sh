#!/usr/bin/env bash
# =============================================================================
# forge new-dest — decide whether a `make new` destination is durable.
#
# F19: the first real product the Forge built was stamped into /private/tmp,
# which macOS periodically purges and Spotlight does not index. It took a
# filesystem sweep to find it, and local `main` was 41 commits behind origin by
# the time it was found. The mechanism was `Makefile`'s old `DEST ?= ..`: a
# RELATIVE default, resolved against whatever directory the operator happened to
# be standing in. Nobody chose /private/tmp. It was inherited.
#
# So this refuses two things, and the second is the one that actually bit:
#   1. a destination under a volatile root (/tmp, /private/tmp, $TMPDIR)
#   2. a destination that is empty or relative — because a relative path has no
#      single answer, and the answer it happens to give is the bug.
#
# Symlinks are resolved BEFORE judging. On macOS /tmp is a symlink to
# /private/tmp; a check that compares strings passes whichever of the two
# spellings it was not written for, and the operator typed neither.
#
# Usage: scripts/new-dest.sh <dest>
#   stdout: the resolved, physical, durable directory (no trailing slash)
#   exit 0: durable      exit 2: refused (reason on stderr)
# =============================================================================
set -uo pipefail

DEST="${1-}"

die() { printf 'make new: %s\n' "$1" >&2; suggest; exit 2; }

suggest() {
  cat >&2 <<EOF

  A project the Forge builds outlives the session that built it: it accumulates
  a board, a git history and 41-commits-behind-origin worth of delivered work.
  Stamp it somewhere durable and name the path explicitly:

      make new NAME=my-project DEST=$HOME/dev

  There is no default. A default for this is what produced F19.
EOF
}

# Physical path of $1, resolving symlinks, WITHOUT requiring it to exist yet:
# walk up to the deepest existing ancestor, resolve that with `pwd -P`, then
# re-append the tail. `realpath`/`readlink -f` are not portable enough to rely
# on here, and both differ on non-existent paths across BSD and GNU.
physical() {
  local p="$1" tail="" base
  while [ ! -d "$p" ] && [ "$p" != "/" ]; do
    base="$(basename "$p")"
    tail="/$base$tail"
    p="$(dirname "$p")"
  done
  printf '%s\n' "$(cd "$p" 2>/dev/null && pwd -P)$tail"
}

# Is $1 equal to, or underneath, $2? Compared on physical paths only.
under() {
  case "$1" in
    "$2") return 0;;
    "$2"/*) return 0;;
    *) return 1;;
  esac
}

[ -n "$DEST" ] || die "DEST is empty."

case "$DEST" in
  /*) ;;
  *)  die "DEST must be an absolute path; got '$DEST'.";;
esac

RESOLVED="$(physical "$DEST")"
[ -n "$RESOLVED" ] || die "DEST '$DEST' does not resolve to a path."
RESOLVED="${RESOLVED%/}"
[ -n "$RESOLVED" ] || RESOLVED=/

# The volatile roots, each reduced to its physical form first. /tmp and
# /private/tmp collapse to the same entry on macOS; that is the point.
VOLATILE=""
for root in /tmp /private/tmp ${TMPDIR:+"$TMPDIR"}; do
  phys="$(physical "$root")"
  phys="${phys%/}"
  [ -n "$phys" ] || continue
  VOLATILE="$VOLATILE
$phys"
done

while IFS= read -r root; do
  [ -n "$root" ] || continue
  if under "$RESOLVED" "$root"; then
    die "DEST '$DEST' resolves to '$RESOLVED', under the volatile root '$root'. macOS purges it and Spotlight does not index it (F19)."
  fi
done <<EOF
$VOLATILE
EOF

printf '%s\n' "$RESOLVED"
