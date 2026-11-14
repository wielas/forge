#!/usr/bin/env bash
# =============================================================================
# forge — the operator's one front door.
#
# Until this script the operator drove Forge through a dozen long script paths. This is the single
# command, installed by `make install` as ~/.local/bin/forge -> ~/.forge/repo/scripts/forge.sh. It
# owns no logic that another script already has: every answer comes from the script that owns it
# (merge-authority.sh, checkpoint-arm.sh, board-snapshot.sh, the watchdog's own log), and this file
# only asks, joins and prints. A subcommand is a function `cmd_<name>`; adding one is adding that
# function and a line in `usage` (`rehearse` and `go` are the next two and are not built yet).
#
#   forge status [<board>]   what is happening, and does anything need you. READ-ONLY: it writes
#                            nothing under the boards or the forge state root. With no board, every
#                            board that is not archived and still has a card that is not done; with
#                            one, that board even when it is quiet. Per board: counts by status,
#                            merge authority, armed gates, what is running and for how long, what
#                            waits on you (first line of its latest block reason), gates held for
#                            their milestone, and the last chunk to land. Then the host: the
#                            liveness watchdog's last reading.
#   forge stop <board>       the kill switch for unattended authority on one board: revoke its merge
#                            authority and disarm every gate armed for it, then READ BACK that
#                            neither is still in force. It never touches the board itself. A merge
#                            already made is not undone and a card already running finishes its run.
#   forge help               this text
#
# Exit:
#   status  0 nothing waits on you and the watchdog's last reading is healthy
#           1 at least one card waits on you, or the watchdog is not healthy: its last run says
#             UNHEALTHY or has no final verdict line, or there is NO reading in the last 30 minutes
#             (no log, or one nobody has written to). A watchdog that is not running is something
#             the operator must act on, so it is not "nothing waits"
#           2 a board or the host could not be read: a named board with no database, a database that
#             will not open, a helper that did not answer, a log that exists and cannot be read.
#             "Could not ask" is never "nothing there", and it outranks 1
#   stop    0 afterwards the board has no merge authority and no armed gate (asked again, not
#             inferred from the exit codes of the revoke and the disarms)
#           1 one of them is still in force      2 usage, or a helper could not be run or asked
#   other   2 usage (usage on stderr); `forge help`, `-h` and no arguments print usage and exit 0
#
# Environment: HERMES_HOME (default ~/.hermes), HERMES_KANBAN_HOME, FORGE_STATE_ROOT and the narrower
# overrides in scripts/forge-state.sh, all honoured the way the scripts beside this one honour them.
# FORGE_STATUS_NOW (epoch seconds) is a test seam, not an operator knob: it pins the clock that the
# watchdog's 30 minute window and "running for N min" are measured against.
# =============================================================================
set -uo pipefail

# Resolve through symlinks FIRST: the operator runs this as ~/.local/bin/forge, and the scripts it
# calls live beside the TARGET. `pwd -P` on the dirname of a symlink resolves the directory, not the
# link, so a loop (readlink -f is not on every bash 3.2 / older macOS userland).
_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in /*) _self="$_link";; *) _self="$(dirname "$_self")/$_link";; esac
done
HERE="$(cd "$(dirname "$_self")" 2>/dev/null && pwd -P)" \
  || { echo "forge: script directory cannot be resolved" >&2; exit 2; }
# shellcheck source=forge-state.sh
. "$HERE/forge-state.sh" || { echo "forge: cannot source forge-state.sh beside itself" >&2; exit 2; }
# shellcheck source=decision-message.sh
. "$HERE/decision-message.sh" || { echo "forge: cannot source decision-message.sh beside itself" >&2; exit 2; }

usage() {
  cat <<'USAGE'
forge — the operator's front door

  forge status [<board>]   what is happening, and whether anything needs you (read-only)
                             exit 0 nothing waits on you; 1 a card waits on you or the watchdog is
                             not healthy; 2 a board or the host could not be read
  forge stop <board>       withdraw merge authority and disarm every armed gate on the board
                             exit 0 neither is still in force; 1 one is; 2 usage or a script failed
  forge help               this text
USAGE
}
die() { echo "forge: $*" >&2; exit 2; }
usage_err() { echo "forge: $*" >&2; usage >&2; exit 2; }

# ---------------------------------------------------------------------------
# the checkpoint arming list, read once per run. checkpoint-arm.sh `list` exits 1 when SOME file is
# MALFORMED and the listing is still good (a malformed file counts as not armed); only 2 and a
# script that cannot run (126/127) mean "could not ask". ARM_OUT holds the lines, ARM_RC the code.
# ---------------------------------------------------------------------------
ARM_OUT=""; ARM_RC=0
arm_read() {
  ARM_OUT="$("$HERE/checkpoint-arm.sh" list 2>&1)"; ARM_RC=$?
  case "$ARM_RC" in 0|1) return 0;; *) return 1;; esac
}
# `<gate> <mode>` for each gate armed on board $1, one per line. Fields 1 and 2 are tested strictly:
# a board slug `no` is legal and must not match the listing's "no gate is armed", and the project
# path (field 4 on) may hold spaces.
arm_gates() {
  printf '%s\n' "$ARM_OUT" | awk -v b="$1" '$1 == b && $2 ~ /^GATE-/ { print $2, $3 }'
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
# THE BOARD QUERY. One JSON object per board, from a snapshot (never the live file: a Hermes board is
# WAL, and board-snapshot.sh is the one safe read). `waiting` and `held_gates` are RE-DERIVED from
# scripts/digest.sh's board_json, because that script runs top-level code and cannot be sourced; they
# are copied, not paraphrased, and verify's front/status-lists-what-waits-on-you compares the cards
# it names with the digest's own for one fixture, so the two cannot drift unnoticed. In words:
#   waiting      blocked or triage, or ready on the human-handoff sentinel (a human chunk sent back),
#                EXCEPT a gate held for open chunks and the bootstrap's interactive hold on a chunk
#                whose parent is still open — neither asks anything yet.
#   held_gates   a blocked GATE-* card with a parent that is not done: it asks nothing until every
#                chunk it closes is done. (digest.sh's `held` also holds interactive chunks; they are
#                counted under `blocked` here and not listed.)
# The running card's start and profile come from task_runs (the open run), not from tasks columns the
# fixtures do not have. An empty `tasks` table is a quiet board with all counts 0.
status_sql() {  # $1 sentinel (SQL-escaped)  $2 interactive hold (SQL-escaped)
  cat <<SQL
SELECT json_object(
  'open',    (SELECT COUNT(*) FROM tasks WHERE status NOT IN ('done','archived')),
  'running', (SELECT COUNT(*) FROM tasks WHERE status = 'running'),
  'ready',   (SELECT COUNT(*) FROM tasks WHERE status = 'ready'),
  'todo',    (SELECT COUNT(*) FROM tasks WHERE status = 'todo'),
  'blocked', (SELECT COUNT(*) FROM tasks WHERE status = 'blocked'),
  'review',  (SELECT COUNT(*) FROM tasks WHERE status = 'review'),
  'done',    (SELECT COUNT(*) FROM tasks WHERE status = 'done'),
  'triage',  (SELECT COUNT(*) FROM tasks WHERE status = 'triage'),
  'running_cards', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'who', who, 'since', since)), json_array())
                      FROM (SELECT t.id, t.title,
                                   COALESCE((SELECT r.profile FROM task_runs r WHERE r.task_id = t.id AND r.ended_at IS NULL
                                              ORDER BY r.started_at DESC, r.id DESC LIMIT 1), t.assignee) AS who,
                                   (SELECT r.started_at FROM task_runs r WHERE r.task_id = t.id AND r.ended_at IS NULL
                                     ORDER BY r.started_at DESC, r.id DESC LIMIT 1) AS since
                              FROM tasks t WHERE t.status = 'running' ORDER BY t.id)),
  'waiting', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'status', status, 'reason', reason)), json_array())
               FROM (SELECT t.id, t.title, t.status,
                            (SELECT json_extract(e.payload,'\$.reason') FROM task_events e
                              WHERE e.task_id = t.id AND e.kind IN ('blocked','block_loop_detected')
                              ORDER BY e.created_at DESC, e.id DESC LIMIT 1) AS reason
                       FROM tasks t
                      WHERE (t.status IN ('blocked','triage')
                             OR (t.status = 'ready' AND t.assignee IS '$1'))
                        AND NOT (t.title GLOB 'GATE-*' AND t.status = 'blocked'
                                 AND EXISTS (SELECT 1 FROM task_links l
                                               JOIN tasks p ON p.id = l.parent_id
                                              WHERE l.child_id = t.id
                                                AND p.status NOT IN ('done','archived')))
                      ORDER BY t.id) w
              WHERE NOT (w.status = 'blocked' AND w.reason IS '$2'
                         AND EXISTS (SELECT 1 FROM task_links l
                                       JOIN tasks p ON p.id = l.parent_id
                                      WHERE l.child_id = w.id
                                        AND p.status NOT IN ('done','archived')))),
  'held_gates', (SELECT COALESCE(json_group_array(json_object('id', id, 'title', title)), json_array())
                   FROM (SELECT h.id, h.title FROM tasks h
                          WHERE h.status = 'blocked' AND h.title GLOB 'GATE-*'
                            AND EXISTS (SELECT 1 FROM task_links l JOIN tasks p ON p.id = l.parent_id
                                         WHERE l.child_id = h.id AND p.status NOT IN ('done','archived'))
                          ORDER BY h.title, h.id)),
  'landed_title', (SELECT title FROM tasks WHERE status = 'done' AND title GLOB 'CHUNK-*'
                    ORDER BY completed_at DESC, id DESC LIMIT 1),
  'landed_at',    (SELECT completed_at FROM tasks WHERE status = 'done' AND title GLOB 'CHUNK-*'
                    ORDER BY completed_at DESC, id DESC LIMIT 1)
);
SQL
}

# The board block, printed from the JSON. $board, $now, $ma and $armed come in as jq arguments, so the
# two lines other scripts answer are laid in the right place without a second pass. A card's title is
# card text: control characters (a newline in a title, an escape sequence) become one space.
read -r -d '' STATUS_JQ <<'JQ'
def clean: gsub("[[:cntrl:]]+"; " ");
def short($n): clean | if length > $n then .[0:$n-1] + "…" else . end;
def mins: (($now - .) / 60 | floor);
def ago: ($now - .) as $d
  | if $d < 60 then "just now"
    elif $d < 3600 then "\($d / 60 | floor)m ago"
    elif $d < 86400 then "\($d / 3600 | floor)h ago"
    else "\($d / 86400 | floor)d ago" end;
def why: if .status == "ready" then "returned for changes (a human chunk sent back)"
         else ((.reason // "") | split("\n") | (.[0] // "") | clean | gsub("^ +| +$"; "")) as $r
              | if $r != "" then $r
                elif .status == "triage" then "in triage"
                else "blocked, no reason recorded" end end;
"\($board): running \(.running) · ready \(.ready) · todo \(.todo) · blocked \(.blocked) · review \(.review) · done \(.done)"
  + (if .triage > 0 then " · triage \(.triage)" else "" end),
"  merge authority: \($ma)",
"  armed gates: \($armed)",
( if (.running_cards | length) == 0 then "  running: nothing"
  else "  running: \(.running_cards | length)",
       (.running_cards[] | "    \(.id)  \(.title | short(70))  \(.who // "unassigned")  "
                           + (if .since == null then "run start unknown" else "\(.since | mins) min" end)) end ),
( if (.waiting | length) == 0 then "  waiting on you: nothing"
  else "  waiting on you: \(.waiting | length)",
       (.waiting[] | "    \(.id)  \(.title | short(70)) — \(why | short(100))") end ),
( if (.held_gates | length) > 0
  then "  held gates: " + ([.held_gates[] | "\(.title | split(":")[0] | short(24)) (\(.id))"] | join(", ")) else empty end ),
( if .landed_title == null then "  last landed: nothing yet"
  else "  last landed: \(.landed_title | short(70)) — \(.landed_at | ago)" end )
JQ

file_mtime() {  # file -> its mtime in epoch seconds (GNU stat, then BSD stat), or fails
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)" || m=""
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null)" || m="";; esac
  case "$m" in ''|*[!0-9]*) return 1;; esac
  printf '%s' "$m"
}

# The liveness watchdog's last reading (scripts/watchdog.sh, run by launchd every ten minutes, its
# stdout and stderr appended to <watchdog root>/watchdog.log). A run starts with `forge watchdog
# <time>`, then `OK|FAIL <name> <text>` lines, then a final `watchdog: healthy|UNHEALTHY (...)`.
# The age is the log's mtime, not the header's time: it needs no date parsing and a run that died
# after its header still counts as the log's last write. Sets WD_LINE and WD_FAILS (the FAIL lines);
# returns 0 healthy, 1 not healthy or no reading, 2 the log exists and cannot be read.
WD_LINE=""; WD_FAILS=""
status_watchdog() {
  local log mt age run fails nok verdict
  WD_LINE=""; WD_FAILS=""
  log="$(forge_watchdog_root)/watchdog.log"
  if [ ! -e "$log" ]; then
    WD_LINE="watchdog: no reading in the last 30 min (there is no log at $log)"; return 1
  fi
  if [ ! -f "$log" ] || [ ! -r "$log" ]; then WD_LINE="watchdog: UNREADABLE ($log is not a readable file)"; return 2; fi
  mt="$(file_mtime "$log")" || { WD_LINE="watchdog: UNREADABLE (cannot stat $log)"; return 2; }
  age=$((NOW - mt)); [ "$age" -ge 0 ] || age=0
  if [ "$age" -gt 1800 ]; then
    WD_LINE="watchdog: no reading in the last 30 min (the log was last written $((age / 60)) min ago)"; return 1
  fi
  # The last run is everything from the last header line to the end; 200 lines is many runs.
  run="$(tail -n 200 "$log" 2>/dev/null | awk '/^forge watchdog /{buf=""} {buf = buf $0 "\n"} END{printf "%s", buf}')"
  fails="$(printf '%s' "$run" | grep '^FAIL ')"
  nok="$(printf '%s' "$run" | grep -c '^OK ')"
  verdict="$(printf '%s' "$run" | grep '^watchdog: ' | tail -n 1)"
  if [ "$verdict" = "watchdog: healthy" ] && [ -z "$fails" ]; then
    WD_LINE="watchdog: healthy ($nok OK, read $((age / 60)) min ago)"; return 0
  fi
  WD_FAILS="$fails"
  case "$verdict" in
    "watchdog: UNHEALTHY"*) WD_LINE="watchdog: ${verdict#watchdog: } (read $((age / 60)) min ago)";;
    *) WD_LINE="watchdog: the last reading has no healthy/UNHEALTHY verdict, so it is not healthy (read $((age / 60)) min ago)";;
  esac
  return 1
}

# One board. $1 slug  $2 explicit (1 when the operator named it). Prints its block, or for a board
# that cannot be read says so. Sets STATUS_WAITING (cards waiting on you, summed over the boards),
# STATUS_UNREAD and STATUS_SHOWN. Quiet boards (no open card) are skipped unless named.
STATUS_WAITING=0; STATUS_UNREAD=0; STATUS_SHOWN=0
status_board() {
  local slug="$1" explicit="$2" db snap json ma ma_rc armed nw
  if [ "$slug" = default ]; then db="$HERMES_ROOT/kanban.db"; else db="$KANBAN_ROOT/boards/$slug/kanban.db"; fi
  if [ ! -f "$db" ]; then
    printf '%s: UNREADABLE — there is no board database at %s, so nothing here says it is quiet\n' "$slug" "$db"
    STATUS_UNREAD=1; return
  fi
  snap="$("$HERE/board-snapshot.sh" "$db" "$WORK/$slug" 2>/dev/null)"
  json=""
  [ -n "$snap" ] && json="$(sqlite3 "$snap" "$(status_sql "$SENTINEL_SQL" "$HOLD_SQL")" 2>/dev/null)"
  if ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s: UNREADABLE — the board could not be read, so nothing here says it is quiet\n' "$slug"
    STATUS_UNREAD=1; return
  fi
  if [ "$explicit" = 0 ] && printf '%s' "$json" | jq -e '.open == 0' >/dev/null 2>&1; then return; fi

  ma="$("$HERE/merge-authority.sh" status "$slug" 2>&1)"; ma_rc=$?
  case "$ma_rc" in
    0|1) ma="${ma%%$'\n'*}";;
    *)   ma="UNREADABLE (merge-authority.sh exited $ma_rc)"; STATUS_UNREAD=1;;
  esac
  if [ "$ARM_OK" = 1 ]; then
    armed="$(arm_gates "$slug" | awk '{ printf "%s%s (%s)", sep, $1, $2; sep = ", " }')"
    [ -n "$armed" ] || armed=none
  else
    armed="UNREADABLE (checkpoint-arm.sh list exited $ARM_RC)"
  fi
  [ "$STATUS_SHOWN" = 0 ] || echo
  printf '%s' "$json" | jq -r --arg board "$slug" --argjson now "$NOW" --arg ma "$ma" --arg armed "$armed" "$STATUS_JQ" \
    || { printf '%s: UNREADABLE — rendering the board failed\n' "$slug"; STATUS_UNREAD=1; }
  STATUS_SHOWN=$((STATUS_SHOWN + 1))
  nw="$(printf '%s' "$json" | jq -r '.waiting | length' 2>/dev/null)"
  case "$nw" in ''|*[!0-9]*) STATUS_UNREAD=1;; *) STATUS_WAITING=$((STATUS_WAITING + nw));; esac
}

cmd_status() {
  local board="" b rc=0 wd_rc
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0;;
      -*) usage_err "status: unknown option '$1'";;
      *)  [ -z "$board" ] || usage_err "status takes one board at a time: '$board' and '$1'"; board="$1"; shift;;
    esac
  done
  for tool in sqlite3 jq; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"; done
  [ -z "$board" ] || forge_board_slug_ok "$board" || die "'$board' is not a board slug (Hermes: lowercase letters, digits, - and _, starting with a letter or digit, at most 64)"
  NOW="${FORGE_STATUS_NOW:-$(date +%s)}"
  case "$NOW" in ''|*[!0-9]*) die "FORGE_STATUS_NOW must be epoch seconds, got '$NOW'";; esac
  NOW=$((10#$NOW))   # a leading zero is not octal, and is not JSON for jq either
  HERMES_ROOT="${HERMES_HOME:-${HOME:-}/.hermes}"
  KANBAN_ROOT="${HERMES_KANBAN_HOME:-$HERMES_ROOT/kanban}"
  SENTINEL_SQL="$(printf '%s' "${FORGE_HANDOFF_SENTINEL:-forge-operator-handoff}" | sed "s/'/''/g")"
  HOLD_SQL="$(printf '%s' "$INTERACTIVE_HOLD_REASON" | sed "s/'/''/g")"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-status.XXXXXX")" || die "cannot make a temporary directory"
  trap 'rm -rf "$WORK"' EXIT
  ARM_OK=0; arm_read && ARM_OK=1

  if [ -n "$board" ]; then
    status_board "$board" 1
  else
    if [ ! -d "$KANBAN_ROOT/boards" ]; then
      printf 'boards: UNREADABLE — there is no boards directory at %s\n' "$KANBAN_ROOT/boards"
      STATUS_UNREAD=1
    else
      for db in "$KANBAN_ROOT"/boards/*/kanban.db; do
        [ -f "$db" ] || continue
        b="${db%/kanban.db}"; b="${b##*/}"
        case "$b" in _*) continue;; esac
        forge_board_slug_ok "$b" || continue
        status_board "$b" 0
      done
      [ "$STATUS_SHOWN" -gt 0 ] || [ "$STATUS_UNREAD" -gt 0 ] || echo "no board has a card that is not done"
    fi
  fi

  echo
  echo "host:"
  status_watchdog; wd_rc=$?
  printf '  %s\n' "$WD_LINE"
  if [ -n "$WD_FAILS" ]; then printf '%s\n' "$WD_FAILS" | sed 's/^/    /'; fi

  if [ "$STATUS_UNREAD" -gt 0 ] || [ "$wd_rc" = 2 ]; then rc=2
  elif [ "$STATUS_WAITING" -gt 0 ] || [ "$wd_rc" = 1 ]; then rc=1; fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------
cmd_stop() {
  local board="" rc out ma_rc gate mode pre_grant=0 pre_gates act_failed=0 grant_left=0 gates_left read_failed=0 noop
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0;;
      -*) usage_err "stop: unknown option '$1'";;
      *)  [ -z "$board" ] || usage_err "stop takes one board: '$board' and '$1'"; board="$1"; shift;;
    esac
  done
  [ -n "$board" ] || usage_err "stop needs a board"
  forge_board_slug_ok "$board" || die "'$board' is not a board slug (Hermes: lowercase letters, digits, - and _, starting with a letter or digit, at most 64)"
  # The board's database is not needed: a grant or an arming can outlive its board, and stop must still work.
  for s in merge-authority.sh checkpoint-arm.sh; do
    [ -x "$HERE/$s" ] || die "$HERE/$s is missing or not executable"
  done

  # What is in force now, so a second run can say it had nothing to do.
  "$HERE/merge-authority.sh" status "$board" >/dev/null 2>&1; ma_rc=$?
  [ "$ma_rc" != 0 ] || pre_grant=1
  arm_read || { echo "forge stop: checkpoint-arm.sh list failed (exit $ARM_RC): $ARM_OUT" >&2; exit 2; }
  pre_gates="$(arm_gates "$board")"

  echo "forge stop $board"
  # 1. merge authority. Always asked to revoke, also when status says not granted: a malformed file
  #    grants nothing and revoke removes it.
  out="$("$HERE/merge-authority.sh" revoke "$board" 2>&1)"; rc=$?
  printf '  merge authority: %s\n' "$out"
  [ "$rc" -lt 2 ] || act_failed=1

  # 2. every gate armed for this board
  if [ -z "$pre_gates" ]; then
    echo "  armed gates: none armed"
  else
    while read -r gate mode; do
      [ -n "$gate" ] || continue
      out="$("$HERE/checkpoint-arm.sh" disarm --board "$board" --gate "$gate" 2>&1)"; rc=$?
      printf '  armed gates: %s (was armed %s) — %s\n' "$gate" "$mode" "$out"
      [ "$rc" = 0 ] || act_failed=1
    done <<GATES
$pre_gates
GATES
  fi

  # 3. read back. Ask both scripts again; the exit codes of the actions are not the answer.
  "$HERE/merge-authority.sh" status "$board" >/dev/null 2>&1; ma_rc=$?
  case "$ma_rc" in 0) grant_left=1;; 1) ;; *) read_failed=1;; esac
  if arm_read; then gates_left="$(arm_gates "$board")"; else gates_left=""; read_failed=1; fi

  noop=0
  if [ "$pre_grant" = 0 ] && [ -z "$pre_gates" ] && [ "$grant_left" = 0 ] && [ -z "$gates_left" ] && [ "$read_failed" = 0 ]; then
    noop=1
    echo "board $board had no merge authority and no armed gate: nothing to stop"
  fi
  if [ "$grant_left" = 1 ]; then echo "STILL IN FORCE: board $board is still granted merge authority (forge status $board shows it)"; fi
  if [ -n "$gates_left" ]; then printf '%s\n' "$gates_left" | while read -r gate mode; do
    echo "STILL IN FORCE: gate $gate is still armed ($mode) on board $board"; done; fi
  if [ "$read_failed" = 1 ]; then echo "COULD NOT CONFIRM: a script did not answer when asked again, so it is not known that $board is stopped"; fi
  if [ "$noop" = 0 ] && [ "$grant_left" = 0 ] && [ -z "$gates_left" ] && [ "$read_failed" = 0 ]; then
    echo "read back: board $board has no merge authority and no armed gate"
  fi
  echo "note: a merge already made is not undone"
  echo "note: a card already running finishes its run; nothing new merges or releases without you"

  if [ "$grant_left" = 1 ] || [ -n "$gates_left" ]; then return 1; fi
  if [ "$read_failed" = 1 ] || [ "$act_failed" = 1 ]; then return 2; fi
  return 0
}

# ---------------------------------------------------------------------------
# dispatch: `forge <name> ...` runs cmd_<name>. The name is checked before it is looked up.
# ---------------------------------------------------------------------------
main() {
  local sub="${1:-}"
  case "$sub" in
    ''|help|-h|--help) usage; return 0;;
  esac
  [ $# -eq 0 ] || shift
  case "$sub" in
    *[!a-z0-9-]*|-*) usage_err "unknown command '$sub'";;
  esac
  declare -F "cmd_$sub" >/dev/null 2>&1 || usage_err "unknown command '$sub'"
  "cmd_$sub" "$@"
}
main "$@"
exit $?
