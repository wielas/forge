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
# Symlinks AND `..` are resolved BEFORE judging. On macOS /tmp is a symlink to
# /private/tmp; a check that compares strings passes whichever of the two
# spellings it was not written for, and the operator typed neither. And a `..`
# left unresolved is the same hole wearing a different hat: the first version of
# this script walked up to the deepest EXISTING ancestor and then concatenated
# the remaining tail verbatim, so `<durable>/__missing__/../../../private/tmp/x`
# was accepted — as a string it never starts with a volatile root, but
# `mkdir -p` (what copier does) traverses it and lands there anyway.
#
# The judgement is on the FINAL TARGET, not on DEST alone. DEST was validated
# and NAME was appended to it unchecked, so `NAME=../../../private/tmp/x`
# defeated the whole guard by typing the other variable.
#
# Usage: scripts/new-dest.sh <dest> [--name <project-name>]
#   stdout: without --name, the resolved durable directory
#           with --name, the resolved durable FINAL TARGET (<dest>/<name>)
#           either way: physical, absolute, no `..`, no trailing slash
#   exit 0: durable      exit 2: refused (reason on stderr)
# =============================================================================
set -uo pipefail

DEST=""; NAME=""; HAVE_NAME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || { echo "new-dest: --name needs a value" >&2; exit 2; }
            NAME="$2"; HAVE_NAME=1; shift 2;;
    -*) echo "new-dest: unknown flag: $1" >&2; exit 2;;
    *) [ -z "$DEST" ] || { echo "new-dest: one destination at a time" >&2; exit 2; }
       DEST="$1"; shift;;
  esac
done

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
#
# Returns non-zero when the deepest existing ancestor cannot be entered (an
# unreadable directory, a symlink loop). It used to emit `$tail` alone in that
# case — a bare "/sub/proj", which reads as a perfectly good absolute path and
# would have had `make new` stamp a project at the filesystem root.
physical() {
  local p="$1" tail="" base resolved
  while [ ! -d "$p" ] && [ "$p" != "/" ]; do
    base="$(basename "$p")"
    tail="/$base$tail"
    p="$(dirname "$p")"
  done
  resolved="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  [ -n "$resolved" ] || return 1
  # `pwd -P` at the root prints "/", and "/" + "/sub" is "//sub" — which some
  # systems treat as its own namespace and which canonical() would never see
  # converge. Strip first, restore the root only if nothing else is left.
  resolved="${resolved%/}$tail"
  printf '%s\n' "${resolved:-/}"
}

# Resolve `.` and `..` textually, and squash repeated slashes.
#
# Textual resolution of `..` is wrong in general — `link/..` is the parent of
# the link's TARGET, not of the link — which is why this is only ever applied
# to output of `physical()`: there, every component that exists has already been
# resolved by `pwd -P`, and a component that does not exist cannot be a symlink.
lexnorm() {
  local out="" comp oldifs="$IFS"
  IFS=/; set -- $1; IFS="$oldifs"
  for comp in "$@"; do
    case "$comp" in
      ''|.) ;;
      ..)   out="${out%/*}";;
      *)    out="$out/$comp";;
    esac
  done
  printf '%s\n' "${out:-/}"
}

# physical() then lexnorm(), to a fixed point: popping a `..` can expose a
# symlink that was not on the path before (`<dir>/__missing__/../link`), and
# resolving that symlink can expose more `..`. Two rounds settle every real
# case; the bound is there so a pathological input terminates rather than spins.
canonical() {
  local p="$1" n i=0
  while [ "$i" -lt 32 ]; do
    p="$(physical "$p")" || return 1
    n="$(lexnorm "$p")"
    if [ "$n" = "$p" ]; then printf '%s\n' "$p"; return 0; fi
    p="$n"; i=$((i+1))
  done
  return 1
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

RESOLVED="$(canonical "$DEST")" \
  || die "DEST '$DEST' does not resolve to a usable path (an ancestor could not be entered)."
RESOLVED="${RESOLVED%/}"
[ -n "$RESOLVED" ] || RESOLVED=/

# The contract says "a durable DIRECTORY". Both of these used to be accepted at
# exit 0: a regular file (DEST=$HOME/.zshrc) and the filesystem root (DEST=/,
# which made `make new` target `//x`).
[ "$RESOLVED" != "/" ] \
  || die "DEST must not be the filesystem root."
if [ -e "$RESOLVED" ] && [ ! -d "$RESOLVED" ]; then
  die "DEST '$DEST' resolves to '$RESOLVED', which exists and is not a directory."
fi

# NAME is judged here rather than in the Makefile because this is the file that
# owns the invariant. One path component, nothing that traverses, nothing that
# reads as a flag to copier.
if [ "$HAVE_NAME" = 1 ]; then
  case "$NAME" in
    "")      die "NAME is empty.";;
    .|..)    die "NAME '$NAME' is not a project name.";;
    */*)     die "NAME '$NAME' contains '/'. NAME is one directory component, not a path — put the location in DEST.";;
    -*)      die "NAME '$NAME' starts with '-', which reads as a flag to the tools that receive it.";;
  esac
fi

TARGET="$RESOLVED"
[ "$HAVE_NAME" = 1 ] && TARGET="$(canonical "$RESOLVED/$NAME")"
[ -n "$TARGET" ] || die "the target under '$RESOLVED' does not resolve to a usable path."

# The volatile roots, each reduced to its canonical form first. /tmp and
# /private/tmp collapse to the same entry on macOS; that is the point.
VOLATILE=""
for root in /tmp /private/tmp ${TMPDIR:+"$TMPDIR"}; do
  phys="$(canonical "$root")" || continue
  phys="${phys%/}"
  [ -n "$phys" ] || continue
  VOLATILE="$VOLATILE
$phys"
done

# Judge the FINAL TARGET. With NAME constrained above it cannot escape DEST,
# and this is still evaluated on the target rather than on DEST: the two are
# only equal because of a rule enforced ten lines up, and a guard that depends
# on another guard staying correct is one edit from being no guard at all.
while IFS= read -r root; do
  [ -n "$root" ] || continue
  if under "$TARGET" "$root"; then
    die "'$DEST' resolves to '$TARGET', under the volatile root '$root'. macOS purges it and Spotlight does not index it (F19)."
  fi
done <<EOF
$VOLATILE
EOF

printf '%s\n' "$TARGET"
