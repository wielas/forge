#!/usr/bin/env bash
# =============================================================================
# forge overseer-guard — no chunk card is ever the overseer's (epic MS3, S8c).
#
# `forge-overseer` is gate-only (docs/epic-hands-free.md, MS3): it routes
# milestone gates, exceptions and triage, and "never per chunk". A chunk card
# assigned to it would be dispatched to a profile whose SOUL forbids the work,
# on a premium model. And since decision 13 (2026-11-09) it is never a
# dispatched worker at all, so NO live card is its card, a gate included: the
# dispatcher would spawn it on a card whose board writes the worker fence
# refuses (ADR-0010 amendment, P42). The rule is a program with three entry
# points, called from the places a card gets an assignee:
#
#   lane <name>            the assignee a card is about to get. Exit 1 for the
#                          overseer. Called by hermes/board-bootstrap.sh (for
#                          FORGE_LANE_ASSIGNEE) and scripts/triage.sh (promote).
#   graph <graph.json>     a roadmap graph: no node, chunk or gate, may carry
#                          `lane: forge-overseer`. Called by board-bootstrap.sh
#                          before any board exists. A gate stays
#                          claude-interactive.
#   board <board.db>       the audit of a board that already exists: no card
#                          that is not done or archived is assigned to the
#                          overseer, and no chunk-shaped card (title CHUNK-*,
#                          the forge-lane skill, or a chunk/ branch), however
#                          finished, is assigned to it or has a run under its
#                          profile. Read from a snapshot copy (never mode=ro: a
#                          Hermes board is WAL). Called by scripts/preflight.sh.
#
# NAMES ARE COMPARED AS HERMES COMPARES THEM: trimmed and lowercased
# (hermes_cli/profiles.py:246-260, kanban_db.py:1285), so `FORGE-OVERSEER` and
# ` forge-overseer` are the overseer, in all three entry points.
#
# Exit: 0 clean, 1 a violation (named, one per line), 2 the guard could not run.
# A guard that cannot run is not a pass: `board` on an unreadable board is 2.
# =============================================================================
set -uo pipefail

helptext() { awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; }

OVERSEER="forge-overseer"

# One definition of "the same name": what Hermes does to an assignee before it compares.
norm() { local v; v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }
# The same, in SQL (SQLite's trim() takes only the characters it is given).
WSQL="' ' || char(9) || char(10) || char(13)"
ASG="lower(trim(t.assignee, $WSQL)) = '$OVERSEER'"
RUN="lower(trim(r.profile, $WSQL)) = '$OVERSEER'"

_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in /*) _self="$_link";; *) _self="$(dirname "$_self")/$_link";; esac
done
HERE="$(cd "$(dirname "$_self")" 2>/dev/null && pwd -P)" \
  || { echo "overseer-guard: script directory cannot be resolved" >&2; exit 2; }

cmd="${1:-}"
case "$cmd" in
  -h|--help) helptext; exit 0;;
  lane)
    [ $# -eq 2 ] || { echo "overseer-guard: lane needs exactly one assignee name" >&2; exit 2; }
    if [ "$(norm "$2")" = "$OVERSEER" ]; then
      echo "overseer-guard: '$2' takes gates, exceptions and triage, never a chunk — a card may not be assigned to it (MS3, decision 13)"
      exit 1
    fi
    exit 0;;
  graph)
    [ $# -eq 2 ] && [ -f "$2" ] || { echo "overseer-guard: graph needs a readable graph.json" >&2; exit 2; }
    command -v jq >/dev/null 2>&1 || { echo "overseer-guard: jq is not on PATH" >&2; exit 2; }
    bad="$(jq -r --arg o "$OVERSEER" '
        if type != "array" then error("graph is not an array") else . end
        | .[] | select((.lane // "" | tostring | ascii_downcase | gsub("^\\s+|\\s+$"; "")) == $o) | .id' "$2" 2>/dev/null)" \
      || { echo "overseer-guard: $2 is not a readable graph" >&2; exit 2; }
    if [ -n "$bad" ]; then
      printf 'overseer-guard: %s routed to %s — it is gate-only, and no chunk is ever its card (MS3)\n' \
        "$(printf '%s' "$bad" | paste -sd, - | sed 's/,/, /g')" "$OVERSEER"
      exit 1
    fi
    exit 0;;
  board)
    [ $# -eq 2 ] && [ -f "$2" ] || { echo "overseer-guard: board needs a board database path" >&2; exit 2; }
    command -v sqlite3 >/dev/null 2>&1 || { echo "overseer-guard: sqlite3 is not on PATH" >&2; exit 2; }
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-overseer-guard.XXXXXX")" || exit 2
    trap 'rm -rf "$WORK"' EXIT
    SNAP="$("$HERE/board-snapshot.sh" "$2" "$WORK/board" 2>/dev/null)" && [ -n "$SNAP" ] \
      || { echo "overseer-guard: could not snapshot $2; a board that was not read is not a clean board" >&2; exit 2; }
    # Held by the overseer: a live (not done, not archived) card assigned to it, whatever it is;
    # or a chunk-shaped card (the bootstrap's title, the lane skill, or a chunk branch), in any
    # state, assigned to it or with any run recorded under its profile.
    rows="$(sqlite3 "$SNAP" "
      SELECT t.id || '  ' || t.title || '  (' || t.status || ', assignee ' || COALESCE(t.assignee, '-') || ')'
        FROM tasks t
       WHERE ((t.title GLOB 'CHUNK-*' OR COALESCE(t.skills, '') LIKE '%forge-lane%'
               OR COALESCE(t.branch_name, '') GLOB 'chunk/*')
              AND ($ASG
                   OR EXISTS (SELECT 1 FROM task_runs r WHERE r.task_id = t.id AND $RUN)))
          OR ($ASG AND t.status NOT IN ('done', 'archived'))
       ORDER BY t.created_at, t.id;" 2>&1)" \
      || { echo "overseer-guard: could not query $2: $rows" >&2; exit 2; }
    if [ -n "$rows" ]; then
      echo "overseer-guard: card(s) held by $OVERSEER — it is gate-only (MS3) and never a dispatched worker (decision 13):"
      printf '%s\n' "$rows" | sed 's/^/  /'
      exit 1
    fi
    exit 0;;
  *) echo "usage: overseer-guard.sh lane <name> | graph <graph.json> | board <board.db>" >&2; exit 2;;
esac
