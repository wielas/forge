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
#   4  the snapshot exists but will not open as a database
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

case "${1:-}" in
  -h|--help) sed -n '2,55p' "$0" >&3; exit 0;;
esac

DB="${1:-}"; DEST="${2:-}"
[ -n "$DB" ] && [ -n "$DEST" ] || {
  echo "usage: board-snapshot.sh <board.db> <dest-dir>"; exit 2; }
[ $# -le 2 ] || { echo "board-snapshot.sh takes exactly two arguments"; exit 2; }

command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is not on PATH"; exit 2; }
[ -f "$DB" ] || { echo "no board database at $DB"; exit 2; }
[ -r "$DB" ] || { echo "board database is not readable: $DB"; exit 2; }

mkdir -p "$DEST" 2>/dev/null || { echo "cannot create snapshot directory $DEST"; exit 2; }

# Refusing to snapshot a board onto itself is not defensive padding: the copy
# is opened READ-WRITE below, and a dest that resolves to the board's own
# directory would hand that write back to production.
SRCDIR="$(cd "$(dirname "$DB")" 2>/dev/null && pwd -P)" || { echo "cannot resolve $DB"; exit 2; }
DESTDIR="$(cd "$DEST" 2>/dev/null && pwd -P)" || { echo "cannot resolve $DEST"; exit 2; }
[ "$SRCDIR" != "$DESTDIR" ] || {
  echo "refusing to snapshot $DB into its own directory; the copy is opened read-write"; exit 2; }

BASE="$(basename "$DB")"
SNAP="$DESTDIR/$BASE"

# `-shm` is deliberately NOT copied and NOT fingerprinted, and that is not an
# omission. It is the WAL index: shared-memory scratch, rebuildable from `-wal`,
# and rewritten constantly by every attached reader. Copying it risks handing
# SQLite a torn index, and fingerprinting it would make the consistency check
# below fail against a live board for no reason. SQLite rebuilds it in the
# private copy — precisely the thing `mode=ro` on the live file could not do,
# and the whole of F47. forgeboard-report's hermes.py excludes it for the same
# reason.
PARTS="$DB $DB-wal $DB-journal"

# Membership AND bytes: a sidecar that appears or vanishes mid-copy is as much
# a change as one whose contents move, and only the second kind shows up in a
# hash of the files we happened to find first.
fingerprint() {
  local f
  for f in $PARTS; do
    [ -f "$f" ] && printf '%s %s\n' "${f##*/}" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
  done
  return 0
}

# Three attempts, then an error. A board written faster than it can be copied
# is a real condition and must be REPORTED, never silently reported stale.
# There is no partial success here: either every part copied and the source did
# not move while they did, or this exits non-zero having printed nothing.
attempt=1
while : ; do
  before="$(fingerprint)"
  rm -f "$SNAP" "$SNAP-wal" "$SNAP-journal" "$SNAP-shm"
  failed=0
  for f in $PARTS; do
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

# `SELECT 1` needs no table and no column, so it succeeds on any database that
# opened at all. That is what separates UNREADABLE BOARD from SCHEMA CHANGED
# for every caller below this line (F67): twelve column probes each swallowing
# their own error once presented one open failure as twelve missing columns,
# sending the next reader off to rewrite a fixture that was correct.
sqlite3 "$SNAP" "SELECT 1;" >/dev/null 2>&1 || {
  echo "snapshot of $DB will not open as a database"
  exit 4; }

printf '%s\n' "$SNAP" >&3
