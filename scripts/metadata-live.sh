#!/usr/bin/env bash
# =============================================================================
# forge metadata-live — validate scoped producer output on a live Hermes board.
#
# Usage:
#   scripts/metadata-live.sh <board-slug> --since <RFC3339 timestamp>
#
# The cutoff is mandatory. Historical boards contain envelopes written before
# the current contract, so an unscoped sweep would manufacture a present-day
# failure from rows the producer could not have emitted canonically.
#
# Exit: 0 when the scoped contract is satisfied, 1 on a contract violation,
# 2 when the source or scope cannot be read. The live board is never opened;
# its WAL-safe snapshot is the only query source.
# =============================================================================
set -uo pipefail

help_text() {
  awk 'NR==1 { next }
       /^# ={10,}/ { if (seen) exit; seen=1; next }
       seen { sub(/^#[ ]?/, ""); print }' "$0"
}

case "${1:-}" in
  -h|--help) help_text; exit 0;;
esac

BOARD="${1:-}"
[ "${2:-}" = "--since" ] && [ "$#" -eq 3 ] || {
  echo "usage: metadata-live.sh <board-slug> --since <RFC3339 timestamp>" >&2
  echo "SINCE must be RFC3339, e.g. 2026-08-09T00:00:00Z" >&2
  exit 2
}
SINCE="$3"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || {
  echo "metadata-live script directory cannot be resolved" >&2
  exit 2
}
VALIDATOR="$HERE/validate-metadata.py"

# Scope is resolved before the board path. A missing cutoff must not touch a
# board and then blame historical rows for predating the contract.
SINCE_E="$("$VALIDATOR" --rfc3339-epoch "$SINCE")" || exit 2
[ -n "$SINCE_E" ] || { echo "SINCE could not be scoped" >&2; exit 2; }
[ -n "$BOARD" ] || { echo "board slug is required" >&2; exit 2; }
case "$BOARD" in
  .|..|*/*|*[!a-zA-Z0-9_-]*)
    echo "board slug contains unsafe characters: $BOARD" >&2
    exit 2;;
esac
command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is not on PATH" >&2; exit 2; }

HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
KANBAN_ROOT="${HERMES_KANBAN_HOME:-$HERMES_ROOT/kanban}"
if [ "$BOARD" = "default" ]; then
  DB="$HERMES_ROOT/kanban.db"
else
  DB="$KANBAN_ROOT/boards/$BOARD/kanban.db"
fi
[ -f "$DB" ] || { echo "no board database at $DB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-metadata-live.XXXXXX")" || {
  echo "cannot create metadata-live workspace" >&2
  exit 2
}
trap 'rm -rf "$WORK"' EXIT

SNAP="$("$HERE/board-snapshot.sh" "$DB" "$WORK/board")" || {
  echo "could not snapshot board $BOARD; no rows were judged" >&2
  exit 2
}
[ -n "$SNAP" ] || { echo "snapshot of board $BOARD returned no path" >&2; exit 2; }

# Probe every column before the query. One missing column is substrate drift,
# not a board full of invalid producer output, and therefore exits 2.
missing=""
for spec in \
  "task_runs:id,task_id,profile,outcome,started_at,metadata" \
  "task_events:task_id,run_id,kind,payload,created_at"; do
  table="${spec%%:*}"
  old_ifs="$IFS"; IFS=,
  for column in ${spec#*:}; do
    sqlite3 "$SNAP" "SELECT $column FROM $table LIMIT 0;" >/dev/null 2>&1 \
      || missing="$missing $table.$column"
  done
  IFS="$old_ifs"
done
[ -z "$missing" ] || {
  echo "board $BOARD lacks required metadata-live columns:$missing" >&2
  exit 2
}

ROWS="$WORK/rows.jsonl"
SQLERR="$WORK/query.err"
sqlite3 "$SNAP" >"$ROWS" 2>"$SQLERR" <<'SQL'
WITH projected AS (
  SELECT r.started_at AS at, 0 AS kind_order, r.task_id AS task, r.id AS run,
         json_object(
           'kind', 'run',
           'task', r.task_id,
           'run', r.id,
           'profile', r.profile,
           'at', r.started_at,
           'metadata', r.metadata
         ) AS row
    FROM task_runs r
   WHERE r.outcome = 'completed'
  UNION ALL
  SELECT e.created_at AS at, 1 AS kind_order, e.task_id AS task, e.run_id AS run,
         json_object(
           'kind', 'block',
           'task', e.task_id,
           'run', e.run_id,
           'profile', r.profile,
           'at', e.created_at,
           'payload', e.payload
         ) AS row
    FROM task_events e
    LEFT JOIN task_runs r ON r.id = e.run_id
   WHERE e.kind = 'blocked' AND e.run_id IS NOT NULL
)
SELECT row FROM projected ORDER BY at, kind_order, task, run;
SQL
query_rc=$?
[ "$query_rc" = 0 ] || {
  echo "could not project metadata rows from board $BOARD: $(tr '\n' ' ' < "$SQLERR")" >&2
  exit 2
}

"$VALIDATOR" --batch "$ROWS" --since "$SINCE"
exit $?
