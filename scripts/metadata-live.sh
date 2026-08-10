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

echo "metadata-live sweep implementation is incomplete" >&2
exit 2
