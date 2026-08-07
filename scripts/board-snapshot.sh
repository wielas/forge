#!/usr/bin/env bash
# =============================================================================
# forge board-snapshot — the one WAL-safe way to read a live Hermes board.
#
# Every Hermes board is `journal_mode=wal`. A `mode=ro` connection to a WAL
# database CANNOT create the `-shm` file WAL requires, and SQLite deletes `-shm`
# and `-wal` when the last connection closes. So a read-only open succeeds only
# while some other process happens to be holding the board open, and fails —
# sqlite error 14, "unable to open database file" — when the board is IDLE.
# That is the reverse of the intuition, and it is the state a board is in when
# someone sits down to run /retro. Measured (audit F67):
#
#   concurrent writer holding an open write transaction   succeeds
#   -shm absent, no writer at all                         fails 10/10
#   -shm absent, retried five times                       fails 5/5
#
# Both obvious remedies make it worse: retrying never recreates `-shm`, and
# waiting for quiescence waits for the very condition that causes the failure.
#
# The fix is to `cp` the database and its durable sidecars — a copy only reads,
# so the live file is never opened, locked or mutated — and open the COPY
# read-write, which is what lets SQLite build the `-shm` the original could not
# be given. That also fixes the torn read `mode=ro` never addressed: a report
# assembled from a board being written underneath it is inconsistent whether or
# not the connection opens.
#
# This script exists because that behaviour was written twice — once in
# scripts/metrics.sh (F47) and once in verify.sh's live-schema check (F67) —
# and the second copy went on opening a live board `mode=ro` for weeks after
# the first was fixed. F67's standing remedy is "when a check is fixed, grep
# for its siblings"; this is that grep, made permanent. There is one
# implementation, and verify.sh's metrics/snapshot/no-second-implementation
# case fails if a second one appears.
#
# Usage:
#   scripts/board-snapshot.sh <board.db> <dest-dir>
#
# On success: prints the path of the readable snapshot to STDOUT, exits 0.
# On failure: STDOUT IS EMPTY. Diagnostics go to stderr. Exit codes:
#   2  usage, environment, or missing/instructionally-unsafe input
#   3  the source changed under all 3 snapshot attempts (a torn read, refused)
#   4  the snapshot is zero bytes, or will not open as a database
#
# On 3 and 4 the partial copies are removed before exit, so no later reader can
# find a half-written board and trust it.
#
# The empty-stdout guarantee is structural, not a promise (audit F47's
# unrecorded second half): `sqlite3` writes `Error: unable to open database
# file` to STDOUT, so a caller guarding on `[ -n "$OUT" ]` was satisfied by the
# error text itself and reported success while printing nothing. Here fd 1 is
# swapped to stderr for the whole body and the real stdout is held on fd 3, so
# no command in this script CAN write to stdout. Only the final path does.
#
# The caller owns <dest-dir> and its cleanup. This script never writes outside
# it and never writes to the source at all — verify.sh's
# metrics/snapshot/source-is-byte-identical case hashes the source and every
# sidecar across a snapshot to keep it so.
# =============================================================================
set -uo pipefail

# Hold the real stdout on fd 3 and point fd 1 at stderr. Nothing below can
# reach the caller's stdout by accident — see the header.
exec 3>&1 1>&2

# Anchored to the `# ====` rules, not to line numbers. `sed -n '2,55p'` was
# correct the day it was written and nothing asserted it, so it would have gone
# blind the first time a paragraph was added above it — which is the very defect
# this same commit removed from metrics.sh.
help_text() {
  awk 'NR==1 { next }
       /^# ={10,}/ { if (seen) exit; seen=1; next }
       seen { sub(/^#[ ]?/, ""); print }' "$0"
}

case "${1:-}" in
  -h|--help) help_text >&3; exit 0;;
esac

DB="${1:-}"; DEST="${2:-}"
[ -n "$DB" ] && [ -n "$DEST" ] || {
  echo "usage: board-snapshot.sh <board.db> <dest-dir>"; exit 2; }
[ $# -le 2 ] || { echo "board-snapshot.sh takes exactly two arguments"; exit 2; }

# A relative path beginning with `-` is an OPTION to every helper below —
# dirname, basename, shasum and cp each rejected it in turn, and because the
# copy loop only records that a copy failed, the run came back as exit 3, "the
# board changed under every one of 3 snapshot attempts". A naming problem
# diagnosed as a torn read is the same species of misdiagnosis this file exists
# to remove. `./` costs nothing and makes every helper read it as a path.
case "$DB"   in -*) DB="./$DB";; esac
case "$DEST" in -*) DEST="./$DEST";; esac

command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is not on PATH"; exit 2; }
[ -f "$DB" ] || { echo "no board database at $DB"; exit 2; }
[ -r "$DB" ] || { echo "board database is not readable: $DB"; exit 2; }

CREATED_DEST=0
[ -d "$DEST" ] || CREATED_DEST=1
mkdir -p "$DEST" 2>/dev/null || { echo "cannot create snapshot directory $DEST"; exit 2; }
# A snapshot is a full copy of a board. Where this script created the directory
# it also owns its mode, and the ambient umask is not a decision anyone made:
# a caller passing /tmp/foo got a world-readable directory holding the copy.
# A directory the caller already had is left exactly as the caller set it.
[ "$CREATED_DEST" = 0 ] || chmod 700 "$DEST" 2>/dev/null || true

# Refusing to snapshot a board onto itself is not defensive padding: the copy
# is opened READ-WRITE below, and a dest that resolves to the board's own
# directory would hand that write back to production.
SRCDIR="$(cd "$(dirname "$DB")" 2>/dev/null && pwd -P)" || { echo "cannot resolve $DB"; exit 2; }
DESTDIR="$(cd "$DEST" 2>/dev/null && pwd -P)" || { echo "cannot resolve $DEST"; exit 2; }
[ "$SRCDIR" != "$DESTDIR" ] || {
  echo "refusing to snapshot $DB into its own directory; the copy is opened read-write"; exit 2; }

BASE="$(basename "$DB")"
SNAP_PRE="$DESTDIR/$BASE"

# THIS SCRIPT MUST NEVER DELETE A FILE IT DID NOT WRITE.
#
# Both the retry loop and the exit trap remove `$SNAP` and its sidecars by
# COMPUTED path, without ever checking who put them there. So a caller whose
# destination already held a file of the same basename lost it — including on a
# run that failed and returned nothing:
#
#   board-snapshot.sh live.db "$HOME"     ->  exit 4, and $HOME/kanban.db gone
#
# Neither in-repo caller can reach this (both pass a fresh `mktemp -d`
# subdirectory), but the header above advertises this as a reusable primitive,
# and "the caller owns <dest-dir>" is a statement about cleanup, not a licence
# to destroy their data. Refusing is the fail-closed answer and it costs a
# legitimate caller nothing: a snapshot directory that already contains a board
# of this name is one whose previous contents nobody has reasoned about.
for pre in "$SNAP_PRE" "$SNAP_PRE-wal" "$SNAP_PRE-journal" "$SNAP_PRE-shm"; do
  [ -e "$pre" ] || continue
  echo "refusing to write into $DESTDIR: it already contains $(basename "$pre"), which this run did not create"
  exit 2
done
SNAP="$DESTDIR/$BASE"

# `-shm` is deliberately NOT copied and NOT fingerprinted, and that is not an
# omission. It is the WAL index: shared-memory scratch, rebuildable from `-wal`,
# and rewritten constantly by every attached reader. Copying it risks handing
# SQLite a torn index, and fingerprinting it would make the consistency check
# below fail against a live board for no reason. SQLite rebuilds it in the
# private copy — precisely the thing `mode=ro` on the live file could not do,
# and the whole of F47. forgeboard-report's hermes.py excludes it for the same
# reason.
#
# An ARRAY, and every expansion below is quoted. As a space-separated string
# this was re-split on whitespace at both use sites, so every board under a path
# containing a space failed — each fragment failed `[ -f ]`, so nothing copied,
# `before` and `after` were both empty, the loop "succeeded" on attempt 1, and
# only the `[ -f "$SNAP" ]` backstop caught it, reporting a filesystem problem.
# `metrics.sh` therefore exited 2 for any $HOME or HERMES_KANBAN_HOME with a
# space in it. Unquoted it was also glob-expanded, which is the worse half: a
# fragment whose basename happened to match $BASE would have been copied over
# the snapshot and returned as the board, at exit 0.
PARTS=("$DB" "$DB-wal" "$DB-journal")

# Membership AND bytes: a sidecar that appears or vanishes mid-copy is as much
# a change as one whose contents move, and only the second kind shows up in a
# hash of the files we happened to find first.
fingerprint() {
  local f
  for f in "${PARTS[@]}"; do
    [ -f "$f" ] && printf '%s %s\n' "${f##*/}" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
  done
  return 0
}

# Exit 3 (torn) and exit 4 (unreadable) both leave copies behind. Contained
# today only because both in-repo callers pass a subdirectory of an `mktemp -d`
# they clean up; a third-party caller had no such luck, and a half-copied board
# left on disk is exactly the thing a later reader must not find and trust.
SNAPSHOT_OK=0
cleanup_partial() {
  [ "$SNAPSHOT_OK" = 1 ] && return 0
  rm -f "$SNAP" "$SNAP-wal" "$SNAP-journal" "$SNAP-shm" 2>/dev/null || true
}
trap cleanup_partial EXIT

# Three attempts, then an error. A board written faster than it can be copied
# is a real condition and must be REPORTED, never silently reported stale.
# There is no partial success here: either every part copied and the source did
# not move while they did, or this exits non-zero having printed nothing.
attempt=1
while : ; do
  before="$(fingerprint)"
  rm -f "$SNAP" "$SNAP-wal" "$SNAP-journal" "$SNAP-shm"
  failed=0
  for f in "${PARTS[@]}"; do
    [ -f "$f" ] || continue
    cp "$f" "$DESTDIR/${f##*/}" || { failed=1; break; }
  done
  [ "$failed" = 0 ] && [ "$before" = "$(fingerprint)" ] && break
  attempt=$((attempt+1))
  [ "$attempt" -le 3 ] || {
    echo "$DB changed under every one of 3 snapshot attempts; refusing to return a torn read"
    exit 3; }
done
[ -f "$SNAP" ] || { echo "could not snapshot $DB"; exit 2; }

# Two separate questions, and neither one answers the other.
#
# FIRST: is there anything here at all? SQLite treats a zero-byte file as a
# valid EMPTY database and answers every query below happily, so a board
# truncated to nothing was reported as a board with no runs rather than as
# unreadable — at exit 0, with a path on stdout. No query closes that hole,
# because the file is not malformed; it is empty, which is a legal database.
[ -s "$SNAP" ] || {
  echo "snapshot of $DB is zero bytes; a truncated board is not an empty board"
  exit 4; }

# SECOND: does it parse as a database? `SELECT 1` resolves no table, so on
# builds that defer schema initialisation to the first name resolution it never
# reads page 1 and never checks the 16-byte `SQLite format 3\0` header — it
# accepted a text file as a board, and did so on ubuntu while rejecting it on
# macOS sqlite 3.51, which made this suite host-dependent and turned the ubuntu
# job red on the one case proving this script's headline guarantee.
#
# `sqlite_master` cannot be answered without parsing the schema, which cannot
# happen without reading and validating that header, on every version. It is
# what separates UNREADABLE BOARD from SCHEMA CHANGED for every caller below
# this line (F67): twelve column probes each swallowing their own error once
# presented one open failure as twelve missing columns, sending the next reader
# off to rewrite a fixture that was correct.
sqlite3 "$SNAP" "SELECT count(*) FROM sqlite_master;" >/dev/null 2>&1 || {
  echo "snapshot of $DB will not open as a database"
  exit 4; }

SNAPSHOT_OK=1
printf '%s\n' "$SNAP" >&3
