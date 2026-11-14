#!/usr/bin/env bash
# =============================================================================
# forge — the operator's one front door.
#
# Until this script the operator drove Forge through a dozen long script paths. This is the single
# command, installed by `make install` as ~/.local/bin/forge -> ~/.forge/repo/scripts/forge.sh. It
# owns no logic that another script already has: every answer comes from the script that owns it
# (merge-authority.sh, checkpoint-arm.sh, board-snapshot.sh, the watchdog's own log), and this file
# only asks, joins and prints. A subcommand is a function `cmd_<name>`; adding one is adding that
# function and a line in `usage`.
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
#   forge rehearse [--mode merge|recommend] [--dir <hello checkout>] [--timeout <min>] [--keep]
#                            the end-to-end smoke test, as a program: one card on a throwaway board in the
#                            hello repo goes lane -> PR -> CI -> verifier -> merge -> done with no operator
#                            action. It SPENDS one Codex run and one judge call and pushes to the hello repo,
#                            so it is an explicit operator command and no test ever runs it. Preconditions
#                            (all reads), names, bootstrap, a grant on its own board only (revoked on EVERY
#                            exit), a bounded wait, the verdict read back from the card and GitHub, evidence
#                            under ${FORGE_EVIDENCE_DIR:-~/forge-evidence}/rehearsals/<board>/, and on a pass
#                            the cleanup: the board archived and the hello repo reset through a revert PR.
#   forge rehearse --cleanup <hello-rehearsal-board>
#                            the cleanup of a failed or --keep run; works out the branch and PR from the board
#   forge rehearse --reset   greet.py is on main: revert the commit that added it, through a PR
#   forge go <board> --project <abs dir> [--gate GATE-Mn]... [--ahead] [--no-arm] [--rearm] [--by <name>] [--yes]
#                            [--branch-suffix <s>]
#                            the launch: read the situation (status, board-sync dry run, the product checkout,
#                            the ready gate), say in plain words what it is about to put in force, ask, then
#                            grant merge authority, arm the gate apply and resume the checkpoint cron job,
#                            reading each back. Nothing is changed before the confirmation. --gate may be given
#                            more than once; a gate whose milestone is not finished is refused unless --ahead:
#                            armed apply early, the checkpoint cron does nothing for it until every chunk of its
#                            milestone is done, and then completes it by itself when its probe passes.
#   forge new <name> [--dest <dir>] [--github <owner>/<repo> [--public]]
#                            a project from nothing: stamp templates/python-service at <dir>/<name> (default dir
#                            ~/dev; scripts/new-dest.sh judges the path), git init -b main, make setup, the first
#                            commit. With --github also create the repository, push, run the template's make
#                            protect and say whether GitHub gates it. It never overwrites an existing target.
#   forge start <project dir> [--board <slug>] [--branch-suffix <s>] [--root-only] [--commission] [--yes]
#                            where the project stands, and what to do next. A ladder of twelve rungs (git, origin,
#                            .forge/ ignored, scope, architect, roadmap, acceptance frozen, the plan pushed, the
#                            merge gate, the host, the lanes, the board), each answered by the script that owns it. It
#                            stops at the first rung that is not met and prints one NEXT line. READ-ONLY until
#                            the last rung: when every rung is met and the board does not exist it says in plain words
#                            what the bootstrap will do, asks, and runs hermes/board-bootstrap.sh, reading the board back.
#                            Run it again after every step. --commission also runs the paid commission.sh. A project
#                            whose board already holds cards is RUNNING: asked right after rung 2, it turns every
#                            other rung that is not met into a `warn` line, goes on through all of them, and lets the
#                            board's own rung decide: in sync is "already on board", exit 0 (with a count of warnings);
#                            drift is a NEXT, exit 1. Commissioning is never run against an existing board.
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
#   rehearse 0 passed and cleaned up (or passed and kept, with --keep); 1 the rehearsal ran and FAILED, which is
#             a finding: the board, PR and branch are left for diagnosis and `forge rehearse --cleanup <board>`
#             is printed; 2 it could not run (a precondition, nothing changed) or could not finish its cleanup
#             (what is left behind is said). Merge authority is never left in force by any exit.
#   go      0 in force and read back; 1 refused (not in sync, the checkout not clean on main at origin/main, a gate
#             that is not ready and no --ahead, a gate that already has checkpoint state and no --rearm, the cron job
#             missing -- then the grant and the arming STAY and it says so); 2 usage or could not ask, or no
#             confirmation (no --yes and no terminal): nothing was changed
#   start   0 the board exists and matches the plan (just bootstrapped, or already there; warnings do not change it);
#             1 a rung is not met (the NEXT line says what; on a project already on its board only the board's
#             own rung can be) or the bootstrap refused (exit 3 of the bootstrap: another --branch-suffix);
#             2 usage, a rung that could not be asked (never a NEXT), or no confirmation (no --yes and no terminal):
#             nothing was changed
#   new     0 stamped, committed (and, with --github, pushed and protected); 1 a step failed (it says which, and what
#             is left on disk); 2 usage, a target that already exists, a tool that is missing, or a path new-dest.sh refuses
#   other   2 usage (usage on stderr); `forge help`, `-h` and no arguments print usage and exit 0
#
# Environment: HERMES_HOME (default ~/.hermes), HERMES_KANBAN_HOME, FORGE_STATE_ROOT and the narrower
# overrides in scripts/forge-state.sh, all honoured the way the scripts beside this one honour them.
# FORGE_STATUS_NOW (epoch seconds) is a test seam, not an operator knob: it pins the clock that the
# watchdog's 30 minute window and "running for N min" are measured against. So are FORGE_REHEARSE_NOW (the clock
# the rehearsal's name is taken from), FORGE_REHEARSE_POLL_S, FORGE_REHEARSE_TIMEOUT_S and
# FORGE_REHEARSE_CHECKS_TIMEOUT_S (seconds; they replace the 20 s poll and the minutes of --timeout). The operator's
# own knobs are FORGE_HELLO_DIR (the hello checkout, default ~/dev/hello-forge) and FORGE_EVIDENCE_DIR.
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
  forge rehearse [--mode merge|recommend] [--dir <hello checkout>] [--timeout <min>] [--keep]
                           the end-to-end smoke test on the throwaway repo (spends one Codex run and one judge call)
                             exit 0 passed and cleaned up; 1 it ran and FAILED; 2 it could not run or finish cleaning
  forge rehearse --cleanup <hello-rehearsal-board>   clean up after a failed or --keep run
  forge rehearse --reset   revert greet.py off main through a PR
  forge go <board> --project <abs dir> [--gate GATE-Mn]... [--ahead] [--no-arm] [--rearm] [--by <name>] [--yes] [--branch-suffix <s>]
                           the launch: grant merge authority, arm the ready gate apply, resume the checkpoint cron
                           (--ahead: arm a gate whose milestone is not finished; the cron waits for its chunks)
                             exit 0 in force and read back; 1 refused; 2 usage, could not ask, or not confirmed
  forge new <name> [--dest <dir>] [--github <owner>/<repo> [--public]]
                           stamp a new project from the template, set it up, commit it; with --github, create the repo
                             exit 0 done; 1 a step failed; 2 usage, the target exists, or could not ask
  forge start <project dir> [--board <slug>] [--branch-suffix <s>] [--root-only] [--commission] [--yes]
                           where the project stands and what to do next; once every rung is met, puts the plan on a board
                           (a project already on its board: a rung not met is a warning, and only the board's rung decides)
                             exit 0 the board matches the plan; 1 a rung is not met (NEXT) or the bootstrap refused;
                             2 usage, could not ask, or not confirmed
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
  ARM_OK=0
  if arm_read; then ARM_OK=1; else STATUS_UNREAD=1; fi   # not asked is not "nothing armed"

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
  if [ "$ARM_OK" = 0 ]; then printf '  checkpoint arming: UNREADABLE (checkpoint-arm.sh list exited %s: %s)\n' "$ARM_RC" "$(printf '%s' "$ARM_OUT" | head -n 1)"; fi

  if [ "$STATUS_UNREAD" -gt 0 ] || [ "$wd_rc" = 2 ]; then rc=2
  elif [ "$STATUS_WAITING" -gt 0 ] || [ "$wd_rc" = 1 ]; then rc=1; fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------
cmd_stop() {
  local board="" rc out ma_rc gate mode pre_grant=0 pre_gates act_failed=0 grant_left=0 gates_left read_failed=0 noop list_failed
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
  # NOTHING BELOW MAY END THE RUN BEFORE THE REVOKE HAS BEEN TRIED. A helper that cannot run is recorded and
  # the read-back decides the exit; a broken arming list must not leave merge authority in force.

  # What is in force now, so a second run can say it had nothing to do.
  "$HERE/merge-authority.sh" status "$board" >/dev/null 2>&1; ma_rc=$?
  [ "$ma_rc" != 0 ] || pre_grant=1
  list_failed=0
  if arm_read; then pre_gates="$(arm_gates "$board")"; else pre_gates=""; list_failed=1; fi

  echo "forge stop $board"
  # 1. merge authority. Always asked to revoke, also when status says not granted: a malformed file
  #    grants nothing and revoke removes it.
  out="$("$HERE/merge-authority.sh" revoke "$board" 2>&1)"; rc=$?
  printf '  merge authority: %s\n' "$out"
  [ "$rc" -lt 2 ] || act_failed=1

  # 2. every gate armed for this board
  if [ "$list_failed" = 1 ]; then
    echo "  armed gates: could not be listed (checkpoint-arm.sh list exited $ARM_RC), so none was disarmed"
    act_failed=1
  elif [ -z "$pre_gates" ]; then
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
# shared by rehearse and go: where the boards are, and the one WAL-safe way to read one
# ---------------------------------------------------------------------------
fx_roots() {
  HERMES_ROOT="${HERMES_HOME:-${HOME:-}/.hermes}"
  KANBAN_ROOT="${HERMES_KANBAN_HOME:-$HERMES_ROOT/kanban}"
}
fx_db() { if [ "$1" = default ]; then printf '%s/kanban.db' "$HERMES_ROOT"; else printf '%s/boards/%s/kanban.db' "$KANBAN_ROOT" "$1"; fi; }
# epoch -> yyyymmddHHMM in UTC (GNU date -d first, then BSD date -r: the mini is BSD, CI is GNU)
fx_stamp() { date -u -d "@$1" +%Y%m%d%H%M 2>/dev/null || date -u -r "$1" +%Y%m%d%H%M 2>/dev/null; }
# `hermes kanban boards list [--all] --json` asked about one slug: 0 listed, 1 not listed, 2 could not ask
fx_board_listed() {
  local out
  out="$(hermes kanban boards list ${2:+--all} --json 2>/dev/null)" || return 2
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
  if printf '%s' "$out" | jq -e --arg b "$1" 'any(.[]; .slug == $b)' >/dev/null 2>&1; then return 0; fi
  return 1
}
# Is the Hermes gateway running? The watchdog's own reading (scripts/watchdog.sh, chk_gateway): launchd, not
# `hermes gateway status`, whose text is for people. FORGE_WATCHDOG_LAUNCHCTL is the watchdog's seam for the binary.
# Prints why not on stdout and returns 1.
fx_gateway_running() {
  local lc="${FORGE_WATCHDOG_LAUNCHCTL:-launchctl}" label=ai.hermes.gateway uid out rc state
  command -v "$lc" >/dev/null 2>&1 || { echo "$lc is not on PATH, so whether the gateway runs cannot be asked"; return 1; }
  uid="$(id -u)"
  out="$("$lc" print "gui/$uid/$label" 2>&1)"; rc=$?
  [ "$rc" = 0 ] || { echo "$label is not loaded in gui/$uid (launchctl print exited $rc)"; return 1; }
  state="$(printf '%s\n' "$out" | awk '$1 == "state" && $2 == "=" { $1 = ""; $2 = ""; sub(/^ +/, ""); print; exit }')"
  [ "$state" = running ] || { echo "$label is loaded but not running (state = ${state:-unknown})"; return 1; }
  return 0
}
# sleep that a trapped signal interrupts at once (a foreground sleep would delay the handler up to its length)
FX_SLEEP_PID=""
fx_sleep() {
  case "${1:-}" in ''|0|0.0) return 0;; esac
  sleep "$1" & FX_SLEEP_PID=$!
  wait "$FX_SLEEP_PID" 2>/dev/null
  FX_SLEEP_PID=""
  return 0
}

# ---------------------------------------------------------------------------
# rehearse
# ---------------------------------------------------------------------------
# The end-to-end smoke test as a program. Everything below is the hand-run ritual of 2026-11-14 in order: precondition
# checks that write nothing, a one-card board on the throwaway repo, an explicit and revocable grant, a bounded wait, a
# verdict read back from the card and from GitHub, evidence, and a cleanup that leaves the hello repo exactly as found.
RH_PREFIX="hello-rehearsal-"
RH_DIR=""; RH_SLUG=""; RH_BOARD=""; RH_CREATED=""; RH_CARD=""; RH_BRANCH=""; RH_SUFFIX=""
RH_GRANTED=0; RH_WORK=""; RH_EVIDENCE_DONE=0; RH_MODE=merge; RH_POLL=20
RH_T0=0; RH_CARD_JSON=""; RH_RESULT="ABORTED (the run ended before it had a verdict)"
RH_PRE_FAILS=""; RH_PR_NUM=""; RH_PR_URL=""; RH_WHY=""; RH_PASS=0; RH_LINE=""
RH_PR_STATE=""; RH_PR_OID=""

rh_say() { printf 'rehearse: %s\n' "$*"; }
rh_err() { printf 'rehearse: %s\n' "$*" >&2; }
rh_fatal() { rh_err "$*"; exit 2; }
# LEFTHOOK=0: the rehearsal's own commits and pushes (the revert branch) skip the repo's local hooks. CI checks the
# revert PR, and a hook whose recorded lefthook path is dead falls through lefthook's launcher chain to
# `swift package`, which leaves an untracked .build/ and fails the "clean main" read at the end (seen 2026-11-14).
rh_git() { LEFTHOOK=0 git -C "$RH_DIR" "$@"; }
rh_elapsed() { local s=$(( $(date +%s) - RH_T0 )); printf '%d min %02d s' $((s / 60)) $((s % 60)); }
rh_pre_fail() { RH_PRE_FAILS="$RH_PRE_FAILS  - $1: $2"$'\n'; }
rh_cmd_cleanup_hint() { printf 'forge rehearse --cleanup %s' "$1"; }

# ONE FUNCTION GRANTS, AND IT GRANTS ONE BOARD: a name with the rehearsal prefix that this very run is bootstrapping.
# `--cleanup` and `--reset` never reach it, and nothing else in this file runs merge-authority.sh grant.
rh_grant() {
  local board="$1" out rc
  case "$board" in
    "$RH_PREFIX"*) ;;
    *) rh_err "REFUSED: merge authority is granted only on boards named $RH_PREFIX*, not '$board'"; return 2;;
  esac
  if [ -z "$RH_CREATED" ] || [ "$board" != "$RH_CREATED" ]; then
    rh_err "REFUSED: '$board' is not the board this run created, and a rehearsal grants no other"; return 2
  fi
  RH_GRANTED=1   # set BEFORE the call: a grant that half landed is revoked on any exit
  out="$("$HERE/merge-authority.sh" grant "$board" --by forge-rehearse --reason "forge rehearse" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then rh_err "the grant failed ($rc): $out"; return 2; fi
  "$HERE/merge-authority.sh" status "$board" >/dev/null 2>&1; rc=$?
  if [ "$rc" != 0 ]; then rh_err "the grant was made but does not read back (status exited $rc)"; return 2; fi
  return 0
}
# Revoke RH_BOARD's grant and ask again: 0 only once status says not granted (1), whatever revoke's own exit said.
rh_revoke() {
  local out rc src
  out="$("$HERE/merge-authority.sh" revoke "$RH_BOARD" 2>&1)"; rc=$?
  "$HERE/merge-authority.sh" status "$RH_BOARD" >/dev/null 2>&1; src=$?
  if [ "$src" = 1 ]; then
    RH_GRANTED=0
    rh_say "merge authority on $RH_BOARD is revoked (read back: not granted)"
    return 0
  fi
  rh_err "STILL GRANTED or NOT CONFIRMED: merge authority on $RH_BOARD (revoke exited $rc, status exited $src: $out). Run: forge stop $RH_BOARD"
  return 1
}

# Every exit of a run, the abnormal ones included: authority is never left behind.
rh_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  [ -z "$FX_SLEEP_PID" ] || kill "$FX_SLEEP_PID" 2>/dev/null
  if [ "$RH_GRANTED" = 1 ]; then rh_revoke || rc=2; fi
  if [ -n "$RH_CARD" ] && [ "$RH_EVIDENCE_DONE" = 0 ]; then rh_evidence "$RH_RESULT" >/dev/null 2>&1; fi
  [ -z "$RH_WORK" ] || rm -rf "$RH_WORK"
  exit "$rc"
}
rh_signal() { rh_err "interrupted ($1): merge authority is withdrawn and the board, PR and branch are left as they are"; RH_RESULT="ABORTED ($1)"; exit 2; }
rh_traps() { trap rh_exit EXIT; trap 'rh_signal INT' INT; trap 'rh_signal TERM' TERM; trap 'rh_signal HUP' HUP; }

# --- preconditions: every one is a read ---------------------------------------------------------------------------
# $1 run|repo. Collects every failure it can find (a missing tool stops the rest: nothing else can be asked without it).
# Sets RH_DIR (absolute) and RH_SLUG. Returns 1 with RH_PRE_FAILS filled.
rh_preconditions() {
  local t out top br porc head origin
  RH_PRE_FAILS=""
  for t in hermes gh git jq sqlite3; do command -v "$t" >/dev/null 2>&1 || rh_pre_fail tools "$t is not on PATH"; done
  [ -z "$RH_PRE_FAILS" ] || return 1
  if [ "$1" = run ]; then
    if ! out="$(fx_gateway_running)"; then rh_pre_fail gateway "$out"; fi
    if ! out="$(hermes kanban assignees --json 2>/dev/null)"; then
      rh_pre_fail profiles "hermes kanban assignees --json failed, so the profiles could not be asked"
    elif ! printf '%s' "$out" | jq -e 'map(select(.name | IN("forge-codex-lane","forge-verifier")) | select(.on_disk)) | length == 2' >/dev/null 2>&1; then
      rh_pre_fail profiles "forge-codex-lane and forge-verifier are not both on disk (hermes kanban assignees --json)"
    fi
  fi
  if [ ! -d "$RH_DIR" ]; then
    rh_pre_fail checkout "$RH_DIR is not a directory"
  else
    top="$(git -C "$RH_DIR" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [ -z "$top" ]; then
      rh_pre_fail checkout "$RH_DIR is not a git repository"
    elif [ "$(cd "$RH_DIR" && pwd -P)" != "$(cd "$top" && pwd -P)" ]; then
      rh_pre_fail checkout "$RH_DIR is inside the repository $top: give its root"
    else
      RH_DIR="$(cd "$RH_DIR" && pwd -P)"
      br="$(git -C "$RH_DIR" symbolic-ref --short -q HEAD 2>/dev/null)" || br=""
      [ "$br" = main ] || rh_pre_fail checkout "$RH_DIR is on '${br:-a detached HEAD}', not main"
      if ! porc="$(git -C "$RH_DIR" status --porcelain 2>/dev/null)"; then
        rh_pre_fail checkout "git status failed in $RH_DIR"
      elif [ -n "$porc" ]; then
        rh_pre_fail checkout "$RH_DIR has uncommitted changes (git status --porcelain is not empty)"
      fi
      if ! git -C "$RH_DIR" fetch --quiet origin 2>/dev/null; then
        rh_pre_fail checkout "git fetch origin failed in $RH_DIR, so whether it is current could not be asked"
      elif [ "$1" = run ]; then
        head="$(git -C "$RH_DIR" rev-parse HEAD 2>/dev/null)"; origin="$(git -C "$RH_DIR" rev-parse origin/main 2>/dev/null)"
        { [ -n "$head" ] && [ "$head" = "$origin" ]; } || rh_pre_fail checkout "HEAD is not origin/main in $RH_DIR (HEAD ${head:0:8}, origin/main ${origin:0:8}): pull first"
      fi
      if [ ! -d "$RH_DIR/src/hello_forge" ]; then
        rh_pre_fail checkout "$RH_DIR is not the hello repo (it has no src/hello_forge); a rehearsal pushes to, and in merge mode merges into, whatever repo it is aimed at"
      elif [ "$1" = run ] && [ -e "$RH_DIR/src/hello_forge/greet.py" ]; then
        rh_pre_fail greet.py "src/hello_forge/greet.py is present on main: a previous rehearsal's merge was never reset. Run: forge rehearse --reset"
      fi
      if out="$(cd "$RH_DIR" && gh repo view --json nameWithOwner 2>/dev/null)" && RH_SLUG="$(printf '%s' "$out" | jq -r '.nameWithOwner // empty' 2>/dev/null)" \
         && [[ $RH_SLUG =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then :
      else
        RH_SLUG=""; rh_pre_fail repo "gh repo view could not name the repository of $RH_DIR (origin)"
      fi
    fi
  fi
  [ -z "$RH_PRE_FAILS" ]
}

# --- the wait -------------------------------------------------------------------------------------------------------
# Polls the card. Prints a line only when its status or its number of runs changes. Returns 0 with RH_END set to
# terminal|timeout, 2 when the card could not be read three times running.
RH_END=""
rh_wait() {
  local end now out st nruns last="" sig fails=0 kind runs
  end=$(( $(date +%s) + $1 ))
  while :; do
    out="$(hermes kanban --board "$RH_BOARD" show "$RH_CARD" --json 2>/dev/null)"
    if printf '%s' "$out" | jq -e '.task.status' >/dev/null 2>&1; then
      fails=0
      RH_CARD_JSON="$out"
      st="$(printf '%s' "$out" | jq -r '.task.status')"
      nruns="$(printf '%s' "$out" | jq -r '(.runs // []) | length')"
      sig="$st/$nruns"
      if [ "$sig" != "$last" ]; then
        last="$sig"
        kind="$(printf '%s' "$out" | jq -r '(.events // []) | (last // {}) | .kind // "none"')"
        runs="$(printf '%s' "$out" | jq -r '(.runs // []) | map("\(.profile // "?"): \(.outcome // .status // "running")") | join(", ")')"
        rh_say "[e] $(rh_elapsed): card $RH_CARD is $st; last event $kind; runs $nruns${runs:+ ($runs)}"
      fi
      case "$st" in done|archived|blocked) RH_END=terminal; return 0;; esac
    else
      fails=$((fails + 1))
      if [ "$fails" -ge 3 ]; then rh_err "the card could not be read three times running (hermes kanban show failed)"; return 2; fi
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$end" ]; then RH_END=timeout; return 0; fi
    fx_sleep "$RH_POLL"
  done
}

# "<total> <failing> <pending>" of a statusCheckRollup, from `gh pr view --json statusCheckRollup`'s output
rh_rollup_counts() {
  printf '%s' "$1" | jq -r '
    (.statusCheckRollup // []) as $c
    | [ ($c | length),
        ([$c[] | select(((.conclusion // "") as $k | $k == "FAILURE" or $k == "TIMED_OUT" or $k == "CANCELLED" or $k == "STARTUP_FAILURE" or $k == "ACTION_REQUIRED" or $k == "STALE")
                       or ((.state // "") as $s | $s == "FAILURE" or $s == "ERROR"))] | length),
        ([$c[] | select(((.status // "COMPLETED") != "COMPLETED") or ((.state // "") as $s | $s == "PENDING" or $s == "EXPECTED"))] | length) ]
    | map(tostring) | join(" ")' 2>/dev/null
}

# --- the verdict ------------------------------------------------------------------------------------------------------
# Sets RH_PASS and RH_WHY (one line per condition that did not hold), RH_PR_*. Returns 2 when GitHub could not be asked.
rh_why() { RH_PASS=0; RH_WHY="$RH_WHY  - $*"$'\n'; }
rh_verdict() {
  local prs n st reason res view counts total=0 failing=0 pending=0
  RH_PASS=1; RH_WHY=""; RH_PR_NUM=""; RH_PR_URL=""; RH_PR_STATE=""; RH_PR_OID=""; RH_LINE=""
  st="$(printf '%s' "$RH_CARD_JSON" | jq -r '.task.status // "unknown"' 2>/dev/null)"
  res="$(printf '%s' "$RH_CARD_JSON" | jq -r '.task.result // ""' 2>/dev/null)"
  reason="$(printf '%s' "$RH_CARD_JSON" | jq -r '[(.events // [])[] | select(.kind == "blocked" or .kind == "block_loop_detected")] | sort_by(.created_at // 0) | (last // {}) | .payload.reason // ""' 2>/dev/null)"
  if ! prs="$(gh pr list --repo "$RH_SLUG" --head "$RH_BRANCH" --state all --json number,state,mergedAt,headRefOid,url,mergeCommit 2>/dev/null)" \
     || ! printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    rh_err "gh pr list for $RH_BRANCH failed, so the pull request could not be asked"; return 2
  fi
  n="$(printf '%s' "$prs" | jq 'length')"
  if [ "$n" = 1 ]; then
    RH_PR_NUM="$(printf '%s' "$prs" | jq -r '.[0].number')"; RH_PR_URL="$(printf '%s' "$prs" | jq -r '.[0].url // empty')"
    RH_PR_STATE="$(printf '%s' "$prs" | jq -r '.[0].state')"; RH_PR_OID="$(printf '%s' "$prs" | jq -r '.[0].mergeCommit.oid // empty')"
    if ! view="$(gh pr view "$RH_PR_NUM" --repo "$RH_SLUG" --json statusCheckRollup 2>/dev/null)" || [ -z "$(rh_rollup_counts "$view")" ]; then
      rh_err "gh pr view $RH_PR_NUM failed, so its checks could not be asked"; return 2
    fi
    counts="$(rh_rollup_counts "$view")"; read -r total failing pending <<RC_EOF
$counts
RC_EOF
  fi
  if [ "$RH_MODE" = merge ]; then
    [ "$st" = done ] || rh_why "the card is '$st', not done"
    if [ "$n" = 0 ]; then rh_why "no pull request was ever opened for $RH_BRANCH"
    elif [ "$n" != 1 ]; then rh_why "$n pull requests exist for $RH_BRANCH, expected one"
    else
      [ "$RH_PR_STATE" = MERGED ] || rh_why "PR #$RH_PR_NUM is $RH_PR_STATE, not MERGED"
      [ "$failing" = 0 ] || rh_why "PR #$RH_PR_NUM has $failing failing check(s) of $total"
    fi
    case "$res" in "merged by forge-verifier"*) RH_LINE="${res%%$'\n'*}";; *) rh_why "the card's result does not start with 'merged by forge-verifier' (it is: ${res:-empty})";; esac
  else
    [ "$st" = blocked ] || rh_why "the card is '$st', not blocked"
    case "$reason" in "merge-pending:"*) RH_LINE="${reason%%$'\n'*}";; *) rh_why "the card's latest block reason does not start with 'merge-pending:' (it is: ${reason:-none})";; esac
    if [ "$n" = 0 ]; then rh_why "no pull request was ever opened for $RH_BRANCH"
    elif [ "$n" != 1 ]; then rh_why "$n pull requests exist for $RH_BRANCH, expected one"
    else
      [ "$RH_PR_STATE" = OPEN ] || rh_why "PR #$RH_PR_NUM is $RH_PR_STATE, not OPEN"
      if [ "$total" = 0 ]; then rh_why "PR #$RH_PR_NUM has no checks, so 'green' is unproven"
      elif [ "$failing" != 0 ] || [ "$pending" != 0 ]; then rh_why "PR #$RH_PR_NUM checks are not green ($failing failing, $pending pending of $total)"; fi
    fi
  fi
  return 0
}

# --- evidence: always, pass or fail --------------------------------------------------------------------------------
# $1 the result word. 0 written, 1 it could not be (the caller then does not clean up what it would destroy).
rh_evidence() {
  local d card verdictf db snap rc=0 fin
  [ -n "$RH_BOARD" ] || return 1
  RH_EVIDENCE_DONE=1
  d="${FORGE_EVIDENCE_DIR:-${HOME:-}/forge-evidence}/rehearsals/$RH_BOARD"
  mkdir -p "$d" 2>/dev/null || { rh_err "evidence: cannot create $d"; return 1; }
  if [ -n "$RH_CARD" ]; then
    card="$(hermes kanban --board "$RH_BOARD" show "$RH_CARD" --json 2>/dev/null)"
    if printf '%s' "$card" | jq -e . >/dev/null 2>&1; then printf '%s\n' "$card" > "$d/card.json" || rc=1
    elif [ -n "$RH_CARD_JSON" ]; then printf '%s\n' "$RH_CARD_JSON" > "$d/card.json" || rc=1
    else rc=1; rh_err "evidence: the card could not be read"; fi
    verdictf="$(forge_verdict_root)/$RH_BOARD-$RH_CARD.json"
    if [ -f "$verdictf" ]; then cp "$verdictf" "$d/verdict.json" || rc=1
    else printf 'no verdict file at %s\n' "$verdictf" > "$d/verdict.MISSING.txt" || rc=1; fi
  fi
  db="$(fx_db "$RH_BOARD")"
  if [ -f "$db" ] && [ -n "$RH_WORK" ] && mkdir -p "$RH_WORK/ev" && snap="$("$HERE/board-snapshot.sh" "$db" "$RH_WORK/ev" 2>/dev/null)" && [ -n "$snap" ]; then
    rm -f "$d/board.db"; sqlite3 "$snap" ".backup '$d/board.db'" >/dev/null 2>&1 && [ -s "$d/board.db" ] || { rc=1; rh_err "evidence: the board could not be snapshotted"; }
  else
    rc=1; rh_err "evidence: the board database could not be snapshotted ($db)"
  fi
  fin="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  { printf 'board: %s\nmode: %s\nresult: %s\ncard: %s\nbranch: %s\npr: %s\npr state: %s\nverifier line: %s\nstarted: %s\nfinished: %s\nelapsed: %s\n' \
      "$RH_BOARD" "$RH_MODE" "$1" "${RH_CARD:-none}" "${RH_BRANCH:-none}" "${RH_PR_URL:-none}" "${RH_PR_STATE:-none}" "${RH_LINE:-none}" \
      "$(fx_iso "$RH_T0")" "$fin" "$(rh_elapsed)"
    [ -z "$RH_WHY" ] || printf 'what did not hold:\n%s' "$RH_WHY"
  } > "$d/result.txt" || rc=1
  RH_EVIDENCE_DIR_USED="$d"
  [ "$rc" = 0 ]
}
RH_EVIDENCE_DIR_USED=""
fx_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

# --- cleanup ------------------------------------------------------------------------------------------------------------
# Wait for a PR's checks by reading its rollup (the exit codes of `gh pr checks --watch` are not an answer, and right after
# `pr create` no check has registered yet): 0 green (at least one, none failing or pending), 1 one failed,
# 2 still pending or none registered at the bound, 3 could not ask.
rh_checks_wait() {
  local end out counts total failing pending
  end=$(( $(date +%s) + ${FORGE_REHEARSE_CHECKS_TIMEOUT_S:-900} ))
  while :; do
    out="$(gh pr view "$1" --repo "$RH_SLUG" --json statusCheckRollup 2>/dev/null)" || return 3
    counts="$(rh_rollup_counts "$out")"; [ -n "$counts" ] || return 3
    read -r total failing pending <<RC_EOF
$counts
RC_EOF
    if [ "$failing" != 0 ]; then return 1; fi
    if [ "$total" != 0 ] && [ "$pending" = 0 ]; then return 0; fi
    if [ "$(date +%s)" -ge "$end" ]; then return 2; fi
    fx_sleep "$RH_POLL"
  done
}
rh_pr_state() {  # number -> OPEN|MERGED|CLOSED on stdout; fails when it could not be asked
  gh pr view "$1" --repo "$RH_SLUG" --json state 2>/dev/null | jq -er '.state' 2>/dev/null
}
# Revert commit $1 through a pull request, wait for its checks, squash-merge it, and confirm greet.py is gone.
# $2 names the branch revert/<label>. A re-run adopts an open revert PR left by an earlier attempt. 0 done, 2 not.
rh_revert_flow() {
  local sha="$1" rb="revert/$2" num url rc existing st
  existing="$(gh pr list --repo "$RH_SLUG" --head "$rb" --state open --json number 2>/dev/null)" || { rh_err "gh pr list for $rb failed, so it could not be asked"; return 2; }
  if [ "$(printf '%s' "$existing" | jq 'length' 2>/dev/null)" = 1 ]; then
    num="$(printf '%s' "$existing" | jq -r '.[0].number')"
    rh_say "[h] adopting the open revert PR #$num from an earlier attempt"
  else
    if [ -n "$(git -C "$RH_DIR" ls-remote --heads origin "refs/heads/$rb" 2>/dev/null)" ]; then
      rh_err "origin already has $rb and no open PR is on it: delete it by hand (git push origin --delete $rb) and run again"; return 2
    fi
    if rh_git show-ref --verify --quiet "refs/heads/$rb"; then rh_git branch -D "$rb" >/dev/null 2>&1 || { rh_err "a stale local $rb cannot be deleted"; return 2; }; fi
    rh_git switch --quiet -c "$rb" || { rh_err "cannot create $rb in $RH_DIR"; return 2; }
    if ! rh_git revert --no-edit "$sha" >/dev/null 2>&1; then
      rh_git revert --abort >/dev/null 2>&1; rh_git switch --quiet main >/dev/null 2>&1; rh_git branch -D "$rb" >/dev/null 2>&1
      rh_err "git revert $sha failed (a conflict, most likely): the hello repo is back on main as it was"; return 2
    fi
    rh_say "[h] reverted ${sha:0:8} on $rb"
    if ! rh_git push --quiet -u origin "$rb" 2>/dev/null; then rh_git switch --quiet main >/dev/null 2>&1; rh_err "git push of $rb failed; $RH_DIR is on main, $rb is local only"; return 2; fi
    if ! url="$(gh pr create --repo "$RH_SLUG" --base main --head "$rb" --title "revert: forge rehearsal $2" --body "Resets the hello repo after the forge rehearsal $2: reverts ${sha:0:12}." 2>/dev/null)"; then
      rh_git switch --quiet main >/dev/null 2>&1; rh_err "gh pr create for $rb failed; the branch is pushed, open its PR by hand"; return 2
    fi
    num="${url##*/}"
    case "$num" in ''|*[!0-9]*) rh_git switch --quiet main >/dev/null 2>&1; rh_err "gh pr create did not name a pull request (it said: $url)"; return 2;; esac
    rh_say "[h] opened revert PR #$num ($url)"
  fi
  rh_git switch --quiet main >/dev/null 2>&1
  rh_checks_wait "$num"; rc=$?
  case "$rc" in
    0) rh_say "[h] revert PR #$num: checks are green";;
    1) rh_err "revert PR #$num has a failing check: it is left open for you to look at"; return 2;;
    2) rh_err "revert PR #$num: no green checks within the bound (still pending, or none registered): it is left open"; return 2;;
    *) rh_err "revert PR #$num: the checks could not be asked"; return 2;;
  esac
  gh pr merge "$num" --repo "$RH_SLUG" --squash --delete-branch >/dev/null 2>&1 || true
  st="$(rh_pr_state "$num")" || st=""
  if [ "$st" != MERGED ]; then rh_err "revert PR #$num is '${st:-unreadable}' after gh pr merge, not MERGED: it is left as it is"; return 2; fi
  rh_say "[h] revert PR #$num merged"
  rh_git branch -D "$rb" >/dev/null 2>&1
  rh_git switch --quiet main >/dev/null 2>&1
  rh_git pull --quiet --ff-only origin main >/dev/null 2>&1 || { rh_err "git pull --ff-only failed in $RH_DIR after the revert merged"; return 2; }
  if [ -e "$RH_DIR/src/hello_forge/greet.py" ]; then rh_err "src/hello_forge/greet.py is still on main after the revert merged"; return 2; fi
  rh_say "[h] main pulled: src/hello_forge/greet.py is absent again"
  return 0
}
# The local clean-up of one card's leftovers: its worktree, then the local branches, and the remote chunk branch if the merge left it.
rh_leftovers() {  # $1 chunk branch  $2 card workspace path or empty  $3 revert suffix
  local wt wts br
  wts="$(rh_git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$1" -v p="${2:-}" '
    /^worktree / { if (path != "" && (br == b || (p != "" && path == p))) print path; path = substr($0, 10); br = ""; next }
    /^branch /   { br = substr($0, 8) }
    END          { if (path != "" && (br == b || (p != "" && path == p))) print path }')"
  while IFS= read -r wt; do
    [ -n "$wt" ] && [ "$wt" != "$RH_DIR" ] || continue
    if rh_git worktree remove --force "$wt" >/dev/null 2>&1; then rh_say "[h] removed the worktree $wt"; else rh_err "could not remove the worktree $wt"; fi
  done <<WT_EOF
$wts
WT_EOF
  rh_git worktree prune >/dev/null 2>&1
  for br in "$1" "revert/$3"; do
    if rh_git show-ref --verify --quiet "refs/heads/$br"; then rh_git branch -D "$br" >/dev/null 2>&1 && rh_say "[h] deleted the local branch $br"; fi
  done
  case "$1" in
    chunk/HELLO-1-greet-*)
      if [ -n "$(git -C "$RH_DIR" ls-remote --heads origin "refs/heads/$1" 2>/dev/null)" ]; then
        rh_git push --quiet origin --delete "$1" >/dev/null 2>&1 && rh_say "[h] deleted $1 on origin"
      fi;;
  esac
  return 0
}
# The end state: main, clean, equal to origin/main. 0 and a line saying so, or 2.
rh_final_state() {
  local br porc head origin
  git -C "$RH_DIR" fetch --quiet origin 2>/dev/null || { rh_err "git fetch origin failed, so the final state could not be confirmed"; return 2; }
  br="$(rh_git symbolic-ref --short -q HEAD 2>/dev/null)"; porc="$(rh_git status --porcelain 2>/dev/null)"
  head="$(rh_git rev-parse HEAD 2>/dev/null)"; origin="$(rh_git rev-parse origin/main 2>/dev/null)"
  if [ "$br" = main ] && [ -z "$porc" ] && [ -n "$head" ] && [ "$head" = "$origin" ] && [ ! -e "$RH_DIR/src/hello_forge/greet.py" ]; then
    rh_say "[h] $RH_DIR is on main, equal to origin/main (${head:0:8}), git status --porcelain is empty, greet.py is absent"
    return 0
  fi
  rh_err "the hello repo is NOT back to a clean main (branch '${br:-detached}', HEAD ${head:0:8}, origin/main ${origin:0:8}, status: $(printf '%s' "$porc" | head -n 3 | tr '\n' '|'))"
  return 2
}
# Step h for RH_BOARD, for a passed run and for --cleanup. Revoke, reset the hello repo by the state of the PR, remove the
# card's leftovers, archive the board, say the end state. The board is archived LAST so that a cleanup that stops half way can be
# run again and still find the card. 0 cleaned, 2 something is left behind (and said).
rh_cleanup_board() {
  local rc snap card cid branch b2 wp prs n pstate oid suffix="${RH_BOARD#"$RH_PREFIX"}" listed
  rh_say "[h] cleanup of $RH_BOARD"
  rh_revoke || return 2
  branch="chunk/HELLO-1-greet-$suffix"; wp=""
  fx_board_listed "$RH_BOARD" all; listed=$?
  if [ "$listed" = 2 ]; then rh_err "hermes kanban boards list failed, so the board could not be asked"; return 2; fi
  if [ -f "$(fx_db "$RH_BOARD")" ]; then
    mkdir -p "$RH_WORK/cl"
    if snap="$("$HERE/board-snapshot.sh" "$(fx_db "$RH_BOARD")" "$RH_WORK/cl" 2>/dev/null)" && [ -n "$snap" ]; then
      cid="$(sqlite3 "$snap" "select id from tasks where idempotency_key='hello-1' order by created_at limit 1" 2>/dev/null)"
      if [ -n "$cid" ] && card="$(hermes kanban --board "$RH_BOARD" show "$cid" --json 2>/dev/null)" && printf '%s' "$card" | jq -e . >/dev/null 2>&1; then
        b2="$(printf '%s' "$card" | jq -r '.task.branch_name // empty')"
        [ -z "$b2" ] || branch="$b2"
        wp="$(printf '%s' "$card" | jq -r '.task.workspace_path // empty')"
      fi
    else
      rh_err "the board $RH_BOARD could not be read: nothing was reset"; return 2
    fi
  else
    rh_say "[h] $RH_BOARD has no database here (already archived?): the branch is taken from its name"
  fi
  case "$branch" in chunk/HELLO-1-greet-[a-z0-9]*) ;; *) rh_err "the card's branch '$branch' is not a rehearsal branch: nothing was reset"; return 2;; esac
  if ! prs="$(gh pr list --repo "$RH_SLUG" --head "$branch" --state all --json number,state,mergeCommit,url 2>/dev/null)" \
     || ! printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    rh_err "gh pr list for $branch failed, so the pull request could not be asked"; return 2
  fi
  n="$(printf '%s' "$prs" | jq 'length')"
  if [ "$n" -gt 1 ]; then rh_err "$n pull requests exist for $branch: look at them by hand"; return 2; fi
  pstate="none"
  [ "$n" = 0 ] || { pstate="$(printf '%s' "$prs" | jq -r '.[0].state')"; RH_PR_NUM="$(printf '%s' "$prs" | jq -r '.[0].number')"; oid="$(printf '%s' "$prs" | jq -r '.[0].mergeCommit.oid // empty')"; }
  rh_git switch --quiet main >/dev/null 2>&1
  case "$pstate" in
    MERGED)
      rh_git pull --quiet --ff-only origin main >/dev/null 2>&1 || { rh_err "git pull --ff-only failed in $RH_DIR"; return 2; }
      if [ ! -e "$RH_DIR/src/hello_forge/greet.py" ]; then
        rh_say "[h] PR #$RH_PR_NUM is merged and greet.py is already absent on main: nothing to revert"
      elif [ -n "$oid" ] && [ "$(rh_git rev-parse HEAD 2>/dev/null)" = "$oid" ]; then
        rh_revert_flow "$oid" "$suffix" || return 2
      else
        rh_err "main is not at PR #$RH_PR_NUM's merge commit (HEAD $(rh_git rev-parse --short HEAD 2>/dev/null), merge commit ${oid:0:8}): something landed after it, so it is not reverted blindly. Revert it by hand, then run this again"
        return 2
      fi;;
    OPEN)
      gh pr close "$RH_PR_NUM" --repo "$RH_SLUG" --delete-branch >/dev/null 2>&1 || true
      pstate="$(rh_pr_state "$RH_PR_NUM")" || pstate=""
      if [ "$pstate" != CLOSED ]; then rh_err "PR #$RH_PR_NUM is '${pstate:-unreadable}' after gh pr close, not CLOSED"; return 2; fi
      rh_say "[h] closed PR #$RH_PR_NUM and deleted its branch";;
    CLOSED) rh_say "[h] PR #$RH_PR_NUM is already closed";;
    *) rh_say "[h] no pull request was opened for $branch";;
  esac
  rh_leftovers "$branch" "$wp" "$suffix"
  if [ "$listed" = 0 ] && [ -f "$(fx_db "$RH_BOARD")" ]; then
    hermes kanban boards rm "$RH_BOARD" >/dev/null 2>&1
    fx_board_listed "$RH_BOARD"; rc=$?
    if [ "$rc" = 0 ]; then rh_err "board $RH_BOARD is still listed after boards rm (it is not archived): hermes kanban boards rm $RH_BOARD"; return 2; fi
    if [ "$rc" = 2 ]; then rh_err "hermes kanban boards list failed after boards rm: it is not confirmed that $RH_BOARD is archived"; return 2; fi
    rh_say "[h] board $RH_BOARD is archived (read back: it is no longer in the board list)"
  else
    rh_say "[h] board $RH_BOARD is already archived"
  fi
  rh_final_state
}

# --- the run ---------------------------------------------------------------------------------------------------------------
rh_run() {
  local minutes="$1" timeout_s board suffix branch out rc card_rc snap vrc ev_ok=1 tail15 reason
  RH_T0="$(date +%s)"
  timeout_s="${FORGE_REHEARSE_TIMEOUT_S:-$((minutes * 60))}"
  RH_WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-rehearse.XXXXXX")" || rh_fatal "cannot make a temporary directory"
  rh_traps
  rh_say "[a] preconditions (mode $RH_MODE, hello checkout $RH_DIR)"
  if ! rh_preconditions run; then
    rh_err "a precondition does not hold; nothing was changed:"; printf '%s' "$RH_PRE_FAILS" >&2; exit 2
  fi
  rh_say "[a] ok: tools, gateway running, forge-codex-lane and forge-verifier on disk, $RH_SLUG at $RH_DIR is clean on main == origin/main, greet.py absent"

  suffix="r$(fx_stamp "${FORGE_REHEARSE_NOW:-$RH_T0}")"
  board="$RH_PREFIX$suffix"; branch="chunk/HELLO-1-greet-$suffix"
  fx_board_listed "$board" all; rc=$?
  [ "$rc" != 2 ] || rh_fatal "hermes kanban boards list failed, so it could not be asked whether $board exists; nothing was changed"
  [ "$rc" = 1 ] || rh_fatal "a board named $board already exists (two rehearsals in one minute?); nothing was changed"
  if ! out="$(gh pr list --repo "$RH_SLUG" --head "$branch" --state all --json number 2>/dev/null)" || ! printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    rh_fatal "gh pr list for $branch failed, so it could not be asked whether the branch was ever used; nothing was changed"
  fi
  [ "$(printf '%s' "$out" | jq 'length')" = 0 ] || rh_fatal "a pull request has already used $branch; nothing was changed"
  RH_BOARD="$board"; RH_SUFFIX="$suffix"; RH_BRANCH="$branch"
  rh_say "[b] names: board $board, branch $branch"

  RH_CREATED="$board"   # from here the board may exist; it is the only one this run may grant
  out="$(cd "$RH_DIR" && "$HERE/../hermes/board-bootstrap.sh" "$board" --hello --branch-suffix "$suffix" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    rh_err "board-bootstrap.sh exited $rc:"; printf '%s\n' "$out" | tail -n 12 | sed 's/^/    /' >&2
    rh_err "the board may exist: $(rh_cmd_cleanup_hint "$board")"; exit 2
  fi
  mkdir -p "$RH_WORK/snap"
  if ! snap="$("$HERE/board-snapshot.sh" "$(fx_db "$board")" "$RH_WORK/snap" 2>/dev/null)" || [ -z "$snap" ]; then
    rh_err "the new board could not be read to find its card: $(rh_cmd_cleanup_hint "$board")"; exit 2
  fi
  RH_CARD="$(sqlite3 "$snap" "select id from tasks where idempotency_key='hello-1'" 2>/dev/null)"
  case "$RH_CARD" in ''|*[!A-Za-z0-9_-]*) rh_err "the hello card id could not be read back (got '${RH_CARD:-nothing}'): $(rh_cmd_cleanup_hint "$board")"; RH_CARD=""; exit 2;; esac
  rh_say "[c] board $board bootstrapped: card $RH_CARD"

  if [ "$RH_MODE" = merge ]; then
    rh_grant "$board" || { rh_err "$(rh_cmd_cleanup_hint "$board")"; exit 2; }
    rh_say "[d] merge authority granted on $board (by forge-rehearse); it is revoked on every exit"
  else
    rh_say "[d] recommend mode: no merge authority is granted"
  fi

  rh_say "[e] waiting up to $minutes min for the card (a line per change)"
  rh_wait "$timeout_s"; card_rc=$?
  if [ "$RH_GRANTED" = 1 ]; then rh_revoke || { RH_RESULT="FAILED (authority not revoked)"; exit 2; }; fi
  if [ "$card_rc" != 0 ]; then RH_RESULT="ABORTED (the card could not be read)"; rh_err "left as it is: $(rh_cmd_cleanup_hint "$board")"; exit 2; fi
  [ "$RH_END" != timeout ] || rh_say "[e] the timeout ($minutes min) ran out with the card not finished"

  rh_verdict; vrc=$?
  if [ "$vrc" = 2 ]; then RH_RESULT="ABORTED (GitHub could not be asked)"; rh_err "left as it is: $(rh_cmd_cleanup_hint "$board")"; exit 2; fi
  [ "$RH_END" != timeout ] || { RH_PASS=0; RH_WHY="  - the timeout ($minutes min) ran out with the card still $(printf '%s' "$RH_CARD_JSON" | jq -r '.task.status')"$'\n'"$RH_WHY"; }
  if [ "$RH_PASS" = 1 ]; then RH_RESULT="PASSED"; else RH_RESULT="FAILED"; fi
  rh_evidence "$RH_RESULT" || ev_ok=0
  [ -z "$RH_EVIDENCE_DIR_USED" ] || rh_say "[g] evidence: $RH_EVIDENCE_DIR_USED"

  if [ "$RH_PASS" != 1 ]; then
    reason="$(printf '%s' "$RH_CARD_JSON" | jq -r '[(.events // [])[] | select(.kind == "blocked" or .kind == "block_loop_detected")] | sort_by(.created_at // 0) | (last // {}) | .payload.reason // ""' 2>/dev/null)"
    tail15="$(hermes kanban --board "$board" log "$RH_CARD" 2>&1 | tail -n 15)"
    echo "REHEARSAL FAILED:"
    printf '%s' "$RH_WHY"
    echo "  last block reason: ${reason:-none}"
    echo "  last 15 lines of the card's log:"
    printf '%s\n' "${tail15:-(the log is empty)}" | sed 's/^/    /'
    echo "the board, the PR and the branch are left as they are. Clean up later with: $(rh_cmd_cleanup_hint "$board")"
    exit 1
  fi
  if [ "$ev_ok" = 0 ]; then
    rh_err "the rehearsal passed but its evidence could not be written, so nothing was cleaned up (it would destroy the evidence): $(rh_cmd_cleanup_hint "$board")"
    exit 2
  fi
  echo "REHEARSAL PASSED in $(rh_elapsed) — $RH_PR_URL — $RH_LINE"
  if [ "$RH_KEEP" = 1 ]; then
    echo "kept (--keep): the board, and in merge mode the merge, are as they were. Clean up with: $(rh_cmd_cleanup_hint "$board")"
    exit 0
  fi
  rh_cleanup_board || { rh_err "the rehearsal PASSED but its cleanup did not finish; what is left is named above. Run again: $(rh_cmd_cleanup_hint "$board")"; exit 2; }
  exit 0
}

# --- --cleanup and --reset -------------------------------------------------------------------------------------------------
rh_cleanup_cmd() {
  local board="$1"
  RH_T0="$(date +%s)"; RH_BOARD="$board"
  RH_WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-rehearse.XXXXXX")" || rh_fatal "cannot make a temporary directory"
  rh_traps
  if ! rh_preconditions repo; then rh_err "a precondition does not hold; nothing was changed:"; printf '%s' "$RH_PRE_FAILS" >&2; exit 2; fi
  rh_cleanup_board || { rh_err "the cleanup did not finish; what is left is named above. Run it again: $(rh_cmd_cleanup_hint "$board")"; exit 2; }
  echo "cleaned up $board"
  exit 0
}
rh_reset_cmd() {
  local sha stamp
  RH_T0="$(date +%s)"
  RH_WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-rehearse.XXXXXX")" || rh_fatal "cannot make a temporary directory"
  rh_traps
  if ! rh_preconditions repo; then rh_err "a precondition does not hold; nothing was changed:"; printf '%s' "$RH_PRE_FAILS" >&2; exit 2; fi
  rh_git pull --quiet --ff-only origin main >/dev/null 2>&1 || rh_fatal "git pull --ff-only failed in $RH_DIR"
  if [ ! -e "$RH_DIR/src/hello_forge/greet.py" ]; then
    rh_say "src/hello_forge/greet.py is absent on main: nothing to reset"
    rh_final_state || exit 2
    exit 0
  fi
  sha="$(rh_git log --diff-filter=A --format=%H -n 1 -- src/hello_forge/greet.py 2>/dev/null)"
  [ -n "$sha" ] || rh_fatal "no commit that added src/hello_forge/greet.py was found in $RH_DIR's history"
  stamp="reset-r$(fx_stamp "${FORGE_REHEARSE_NOW:-$(date +%s)}")"
  rh_say "reset: reverting ${sha:0:8}, the commit that added greet.py, through a pull request"
  rh_revert_flow "$sha" "$stamp" || exit 2
  rh_final_state || exit 2
  echo "reset: the hello repo is as before the rehearsal"
  exit 0
}

cmd_rehearse() {
  local mode=merge dir="${FORGE_HELLO_DIR:-${HOME:-}/dev/hello-forge}" minutes=30 keep=0 cleanup="" reset=0 mode_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0;;
      --mode)    [ $# -ge 2 ] || usage_err "rehearse: --mode needs merge or recommend"; mode="$2"; mode_set=1; shift 2;;
      --dir)     [ $# -ge 2 ] || usage_err "rehearse: --dir needs a directory"; dir="$2"; shift 2;;
      --timeout) [ $# -ge 2 ] || usage_err "rehearse: --timeout needs minutes"; minutes="$2"; shift 2;;
      --keep)    keep=1; shift;;
      --reset)   reset=1; shift;;
      --cleanup) [ $# -ge 2 ] || usage_err "rehearse: --cleanup needs a board"; cleanup="$2"; shift 2;;
      *) usage_err "rehearse: unknown argument '$1'";;
    esac
  done
  case "$mode" in merge|recommend) ;; *) usage_err "rehearse: --mode is merge or recommend, not '$mode'";; esac
  case "$minutes" in ''|*[!0-9]*|0) usage_err "rehearse: --timeout is a whole number of minutes, at least 1";; esac
  minutes=$((10#$minutes))
  if [ -n "$cleanup" ] && [ "$reset" = 1 ]; then usage_err "rehearse: --cleanup and --reset are two different repairs: one at a time"; fi
  if { [ -n "$cleanup" ] || [ "$reset" = 1 ]; } && { [ "$mode_set" = 1 ] || [ "$keep" = 1 ]; }; then usage_err "rehearse: --mode and --keep belong to a run, not to --cleanup or --reset"; fi
  if [ -n "$cleanup" ]; then
    case "$cleanup" in
      "$RH_PREFIX"?*) forge_board_slug_ok "$cleanup" || usage_err "rehearse: '$cleanup' is not a board slug";;
      *) usage_err "rehearse: --cleanup works only on boards named $RH_PREFIX*, not '$cleanup'";;
    esac
  fi
  [ -n "$dir" ] || usage_err "rehearse: --dir is empty (and FORGE_HELLO_DIR and HOME give no default)"
  case "$dir" in /*) ;; *) dir="$(cd "$dir" 2>/dev/null && pwd -P)" || usage_err "rehearse: --dir is not a directory";; esac
  case "${FORGE_REHEARSE_POLL_S:-20}" in ''|*[!0-9.]*) die "FORGE_REHEARSE_POLL_S must be seconds";; esac
  case "${FORGE_REHEARSE_TIMEOUT_S:-1}" in ''|*[!0-9]*) die "FORGE_REHEARSE_TIMEOUT_S must be whole seconds";; esac
  RH_POLL="${FORGE_REHEARSE_POLL_S:-20}"; RH_DIR="$dir"; RH_MODE="$mode"; RH_KEEP="$keep"
  fx_roots
  if [ -n "$cleanup" ]; then rh_cleanup_cmd "$cleanup"
  elif [ "$reset" = 1 ]; then rh_reset_cmd
  else rh_run "$minutes"; fi
}
RH_KEEP=0

# ---------------------------------------------------------------------------
# go
# ---------------------------------------------------------------------------
# The launch, one command. Read-only until the operator has said yes; then three acts, each read back: merge authority, the
# arming of the one gate that is ready, and the checkpoint cron job. It never works around the fence: merge-authority.sh
# refuses inside a Hermes worker and `go` fails with its message.
GO_WORK=""; GO_ACTING=0; GO_DONE=0; GO_BOARD=""
go_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  [ -z "$GO_WORK" ] || rm -rf "$GO_WORK"
  if [ "$GO_ACTING" = 1 ] && [ "$GO_DONE" = 0 ]; then
    echo "forge go: stopped part way: forge status $GO_BOARD shows what is in force; forge stop $GO_BOARD withdraws it" >&2
  fi
  exit "$rc"
}
go_signal() { echo "forge go: interrupted ($1)" >&2; exit 2; }
go_say() { printf '%s\n' "$*"; }

# The checkpoint cron job, read from Hermes' own job file (the watchdog reads the same file: `hermes cron list` has no
# JSON form). Sets GO_JOB_ID and GO_JOB_STATE (active|paused|missing). Returns 0, or 2 when it could not be read.
GO_JOB_ID=""; GO_JOB_STATE=""
GO_JOB_NAME=forge-checkpoint
go_cron_read() {
  local f="$HERMES_ROOT/cron/jobs.json" r
  GO_JOB_ID=""; GO_JOB_STATE=""
  [ -r "$f" ] || return 2
  r="$(jq -r --arg n "$GO_JOB_NAME" '
        if (.jobs | type) != "array" then "unreadable"
        else [.jobs[] | select(.name == $n)] as $j
          | if ($j | length) == 0 then "missing"
            elif ($j | length) > 1 then "ambiguous"
            else ($j[0] | "\(.id) \(if (.enabled == false or .state == "paused") then "paused" else "active" end)") end
        end' "$f" 2>/dev/null)" || return 2
  case "$r" in
    missing) GO_JOB_STATE=missing;;
    ambiguous|unreadable|"") return 2;;
    *" paused") GO_JOB_ID="${r% *}"; GO_JOB_STATE=paused;;
    *" active") GO_JOB_ID="${r% *}"; GO_JOB_STATE=active;;
    *) return 2;;
  esac
  return 0
}

# The gates of a board, from a snapshot: one JSON array of every blocked GATE-* card with `ready` (every parent done or
# archived: the chunks it closes are done, which is what `status` calls waiting on you, as against held) and `releases`
# (its children that become ready when it completes: todo, and no other parent still open).
go_gates_sql() {
  cat <<'SQL'
SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'ready', ready, 'releases', json(releases))), json_array())
FROM (
  SELECT g.id AS id, g.title AS title,
         NOT EXISTS (SELECT 1 FROM task_links l JOIN tasks p ON p.id = l.parent_id
                      WHERE l.child_id = g.id AND p.status NOT IN ('done','archived')) AS ready,
         (SELECT COALESCE(json_group_array(json_object('id', rid, 'title', rtitle)), json_array())
            FROM (SELECT c.id AS rid, c.title AS rtitle FROM tasks c JOIN task_links cl ON cl.child_id = c.id
                   WHERE cl.parent_id = g.id AND c.status = 'todo'
                     AND NOT EXISTS (SELECT 1 FROM task_links l2 JOIN tasks p2 ON p2.id = l2.parent_id
                                      WHERE l2.child_id = c.id AND p2.id <> g.id AND p2.status NOT IN ('done','archived'))
                   ORDER BY c.title, c.id)) AS releases
    FROM tasks g WHERE g.title GLOB 'GATE-*' AND g.status = 'blocked'
   ORDER BY g.title, g.id);
SQL
}

cmd_go() {
  local board="" project="" gate="" gates_req="" ahead=0 no_arm=0 by="" yes=0 rearm=0 suffix="" suffix_set=0
  local out rc sync_rc snap gates ready_n gid grow refuse=0 unasked=0 syncv db apply_cmd dry_cmd
  local mode_word releases_txt cp_dir key armed_now has_decision has_pending ans repo
  local sel="" conflict=0 armed_list="" is_ready NL=$'\n'
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0;;
      --project) [ $# -ge 2 ] || usage_err "go: --project needs the product checkout's absolute path"; project="$2"; shift 2;;
      --gate)    [ $# -ge 2 ] || usage_err "go: --gate needs a gate id"
                 case "$2" in ''|*[!A-Za-z0-9._-]*) usage_err "go: '$2' is not a gate id (GATE-<milestone>)";; esac
                 printf '%s\n' "$gates_req" | grep -Fxq -- "$2" || gates_req="${gates_req:+$gates_req$NL}$2"
                 shift 2;;
      --ahead)   ahead=1; shift;;
      --by)      [ $# -ge 2 ] || usage_err "go: --by needs a name"; by="$2"; shift 2;;
      --branch-suffix) [ $# -ge 2 ] || usage_err "go: --branch-suffix needs the suffix the board was bootstrapped with"; suffix="$2"; suffix_set=1; shift 2;;
      --no-arm)  no_arm=1; shift;;
      --rearm)   rearm=1; shift;;
      --yes|-y)  yes=1; shift;;
      -*) usage_err "go: unknown option '$1'";;
      *)  [ -z "$board" ] || usage_err "go takes one board: '$board' and '$1'"; board="$1"; shift;;
    esac
  done
  [ -n "$board" ] || usage_err "go needs a board"
  forge_board_slug_ok "$board" || die "'$board' is not a board slug (Hermes: lowercase letters, digits, - and _, starting with a letter or digit, at most 64)"
  [ -n "$project" ] || usage_err "go needs --project <absolute dir>: the product checkout the checkpoint probes"
  case "$project" in /*) ;; *) usage_err "go: --project must be an absolute path";; esac
  [ -d "$project" ] || die "no such project directory: $project"
  [ -z "$gates_req" ] || [ "$no_arm" = 0 ] || usage_err "go: --gate and --no-arm contradict each other"
  [ "$ahead" = 0 ] || [ -n "$gates_req" ] || usage_err "go: --ahead arms a gate before its milestone is done, so it needs --gate GATE-<milestone> (the one it applies to)"
  [ "$ahead" = 0 ] || [ "$no_arm" = 0 ] || usage_err "go: --ahead and --no-arm contradict each other"
  [ "$rearm" = 0 ] || [ "$no_arm" = 0 ] || usage_err "go: --rearm and --no-arm contradict each other"
  [ "$suffix_set" = 0 ] || { [[ $suffix =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#suffix}" -le 32 ]; } || usage_err "go: --branch-suffix is a lowercase slug of at most 32 characters"
  by="${by:-${USER:-$(id -un 2>/dev/null)}}"
  [ -n "$by" ] || usage_err "go: who is granting? give --by <name> (USER is not set)"
  for tool in sqlite3 jq git; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"; done
  fx_roots
  GO_BOARD="$board"
  GO_WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-go.XXXXXX")" || die "cannot make a temporary directory"
  trap go_exit EXIT; trap 'go_signal INT' INT; trap 'go_signal TERM' TERM; trap 'go_signal HUP' HUP
  repo="$(cd "$HERE/.." && pwd -P)"
  dry_cmd="(cd $project && $repo/hermes/board-sync.sh $board${suffix:+ --branch-suffix $suffix})"
  apply_cmd="(cd $project && $repo/hermes/board-sync.sh $board${suffix:+ --branch-suffix $suffix} --apply)"

  # ---- 1. the situation, all of it a read -----------------------------------------------------------------------------
  go_say "forge go $board (project $project)"
  go_say "== the board =="
  out="$("$HERE/forge.sh" status "$board" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  if [ "$rc" = 2 ]; then echo "forge go: REFUSED (could not read): forge status $board exited 2 (a board or the host could not be read). Nothing was changed." >&2; exit 2; fi
  if [ "$rc" = 1 ]; then echo "note: forge status exited 1: a card waits on you or the watchdog is not healthy. Read the block above before an unattended run."; fi
  go_say "== board and plan =="
  out="$(cd "$project" && "$HERE/../hermes/board-sync.sh" "$board" ${suffix:+--branch-suffix} ${suffix:+"$suffix"} 2>&1)"; sync_rc=$?
  printf '%s\n' "$out" | head -n 30 | sed 's/^/  /'
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -le 30 ] || echo "  ... ($(printf '%s\n' "$out" | wc -l | tr -d ' ') lines in all; run the command below for the rest)"
  case "$sync_rc" in
    0) go_say "  the board is in sync with the plan";;
    1) refuse=1; go_say "  NOT IN SYNC: the board and the plan differ. See it with: $dry_cmd"
       go_say "  and make it match with:    $apply_cmd";;
    *) unasked=1; go_say "  COULD NOT RUN board-sync.sh (exit $sync_rc). Run it by hand: $dry_cmd";;
  esac
  go_say "== product checkout =="
  if ! git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    unasked=1; go_say "  $project is not a git checkout (git rev-parse failed)"
  else
    out="$(git -C "$project" symbolic-ref --short -q HEAD 2>/dev/null)" || out=""
    if [ "$out" != main ]; then refuse=1; go_say "  NOT ON MAIN: the checkout is on '${out:-a detached HEAD}'"; fi
    if out="$(git -C "$project" status --porcelain 2>/dev/null)"; then
      if [ -n "$out" ]; then refuse=1; go_say "  NOT CLEAN: git status --porcelain lists $(printf '%s\n' "$out" | wc -l | tr -d ' ') path(s); the checkpoint probes this checkout"; fi
    else unasked=1; go_say "  git status failed in $project"; fi
    if ! git -C "$project" remote get-url origin >/dev/null 2>&1; then
      refuse=1; go_say "  NO ORIGIN: the verifier merges on GitHub and the checkpoint fast-forwards from origin/main"
    elif ! git -C "$project" fetch --quiet origin 2>/dev/null; then
      unasked=1; go_say "  git fetch origin failed in $project, so whether it is current could not be asked"
    else
      out="$(git -C "$project" rev-parse HEAD 2>/dev/null)"; rc="$(git -C "$project" rev-parse origin/main 2>/dev/null)"
      if [ -n "$out" ] && [ "$out" = "$rc" ]; then go_say "  on main, clean, equal to origin/main (${out:0:8})"
      else refuse=1; go_say "  NOT AT origin/main: HEAD ${out:0:8}, origin/main ${rc:0:8}"; fi
    fi
  fi
  go_say "== gates =="
  db="$(fx_db "$board")"
  gates=""
  if [ -f "$db" ] && mkdir -p "$GO_WORK/snap" && snap="$("$HERE/board-snapshot.sh" "$db" "$GO_WORK/snap" 2>/dev/null)" && [ -n "$snap" ]; then
    gates="$(sqlite3 "$snap" "$(go_gates_sql)" 2>/dev/null)"
  fi
  if ! printf '%s' "$gates" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "forge go: REFUSED (could not read): the gates of $board could not be read from its database. Nothing was changed." >&2; exit 2
  fi
  if ! arm_read; then echo "forge go: REFUSED (could not read): checkpoint-arm.sh list exited $ARM_RC. Nothing was changed." >&2; exit 2; fi
  if [ "$refuse" = 1 ] || [ "$unasked" = 1 ]; then
    if [ "$unasked" = 1 ]; then echo "forge go: REFUSED (could not ask): see above. Nothing was changed." >&2; exit 2; fi
    echo "forge go: REFUSED: the launch needs the board in sync and the product checkout on a clean main at origin/main. Nothing was changed." >&2; exit 1
  fi

  # ---- 2. which gates ------------------------------------------------------------------------------------------------
  # `sel` is one JSON row (a gate from the board) per line: the gates this run will arm. With --gate, every named gate: a
  # ready one needs nothing more, a not-ready one needs --ahead (the checkpoint cron does nothing for an armed gate whose
  # chunks are not all done, scripts/checkpoint-cron.sh, so arming it early is safe). Without --gate, the one ready gate.
  # Every refusal is decided here, for every gate, before the first act.
  sel=""; releases_txt=""; conflict=0
  if [ "$no_arm" = 1 ]; then
    go_say "  --no-arm: no gate is armed by this run"
  else
    if [ -n "$gates_req" ]; then
      while IFS= read -r gate; do
        [ -n "$gate" ] || continue
        grow="$(printf '%s' "$gates" | jq -c --arg g "$gate" '[.[] | select((.title | split(":")[0] | gsub("^ +| +$"; "")) == $g)] | .[0] // empty')"
        if [ -z "$grow" ]; then
          echo "forge go: REFUSED: $board has no blocked $gate card, so there is nothing to arm. Nothing was changed." >&2; exit 1
        fi
        if [ "$(printf '%s' "$grow" | jq -r '.ready')" != 1 ] && [ "$ahead" = 0 ]; then
          echo "forge go: REFUSED: $gate is not ready: a chunk it closes is not done yet, so its probe could not pass. Add --ahead to arm it now anyway (the checkpoint cron does nothing for it until every chunk is done). Nothing was changed." >&2; exit 1
        fi
        sel="$sel$grow"$'\n'
      done <<GATES_REQ
$gates_req
GATES_REQ
    else
      ready_n="$(printf '%s' "$gates" | jq '[.[] | select(.ready == 1)] | length')"
      if [ "$ready_n" = 1 ]; then sel="$(printf '%s' "$gates" | jq -c '[.[] | select(.ready == 1)] | .[0]')"$'\n'
      elif [ "$ready_n" = 0 ]; then sel=""
      else
        echo "forge go: $ready_n gates are ready ($(printf '%s' "$gates" | jq -r '[.[] | select(.ready == 1) | .title | split(":")[0]] | join(", ")')): name the one to arm with --gate, or --no-arm. Nothing was changed." >&2; exit 2
      fi
    fi
    while IFS= read -r grow; do
      [ -n "$grow" ] || continue
      gid="$(printf '%s' "$grow" | jq -r '.title | split(":")[0] | gsub("^ +| +$"; "")')"
      cp_dir="$( . "$HERE/gate-reply.sh" >/dev/null 2>&1 && gr_state_dir )"
      key="$( . "$HERE/gate-reply.sh" >/dev/null 2>&1 && gr_key "$board" "$gid" )"
      if [ -z "$cp_dir" ] || [ -z "$key" ]; then echo "forge go: REFUSED (could not read): the checkpoint state directory could not be resolved. Nothing was changed." >&2; exit 2; fi
      armed_now="$(arm_gates "$board" | awk -v g="$gid" '$1 == g { print $2 }')"
      has_decision=0; [ -e "$cp_dir/decided/$key.json" ] && has_decision=1
      has_pending=0;  [ -e "$cp_dir/pending/$key.json" ] && has_pending=1
      if [ "$rearm" = 0 ] && { [ -n "$armed_now" ] || [ "$has_decision" = 1 ] || [ "$has_pending" = 1 ]; }; then
        conflict=1
        {
          echo "forge go: REFUSED: $gid on $board already has checkpoint state, and arming a gate again ERASES it:"
          [ -z "$armed_now" ] || echo "  - it is armed ($armed_now)"
          [ "$has_decision" = 0 ] || echo "  - a decision is recorded for it (a /park or /redirect: $cp_dir/decided/$key.json)"
          [ "$has_pending" = 0 ] || echo "  - a checkpoint report awaits an answer ($cp_dir/pending/$key.json)"
          echo "  Add --rearm to arm it afresh anyway, or --no-arm to grant authority without arming. Nothing was changed."
        } >&2
      fi
    done <<SEL_STATE
$sel
SEL_STATE
    [ "$conflict" = 0 ] || exit 1
  fi
  if [ -z "$sel" ] && [ "$no_arm" = 0 ]; then
    go_say "  no blocked gate has all of its chunks done: nothing is armed, and the run will stop at the next gate"
  else
    while IFS= read -r grow; do
      [ -n "$grow" ] || continue
      gid="$(printf '%s' "$grow" | jq -r '.title | split(":")[0] | gsub("^ +| +$"; "")')"
      if [ "$(printf '%s' "$grow" | jq -r '.ready')" = 1 ]; then go_say "  $gid is ready (every chunk it closes is done)"
      else go_say "  $gid is NOT ready (a chunk it closes is not done yet): armed AHEAD, because --ahead was given"; fi
    done <<SEL_SAY
$sel
SEL_SAY
  fi
  if [ -n "$sel" ]; then
    if ! go_cron_read; then
      echo "forge go: REFUSED (could not read): $HERMES_ROOT/cron/jobs.json could not be read, or names $GO_JOB_NAME more than once, so the checkpoint job could not be asked. Nothing was changed." >&2; exit 2
    fi
  fi

  # ---- 3. exactly what is about to be in force -------------------------------------------------------------------
  echo
  echo "this will put in force on $board:"
  echo "  - the verifier will MERGE approved lane-built PRs on $board (merge authority granted by $by; chunks a person built are still yours to merge)"
  if [ -n "$sel" ]; then
    while IFS= read -r grow; do
      [ -n "$grow" ] || continue
      gid="$(printf '%s' "$grow" | jq -r '.title | split(":")[0] | gsub("^ +| +$"; "")')"
      releases_txt="$(printf '%s' "$grow" | jq -r '[.releases[] | .title | gsub("[[:cntrl:]]+"; " ")] | join("; ")')"
      if [ "$(printf '%s' "$grow" | jq -r '.ready')" = 1 ]; then
        echo "  - $gid is armed apply on the project $project: when its probe passes, the checkpoint cron completes it, which releases: ${releases_txt:-no card (nothing waits on it)}"
      else
        echo "  - $gid is armed apply AHEAD: nothing happens until every chunk of its milestone is done; then, when its probe passes, the checkpoint cron completes it by itself, which releases: ${releases_txt:-no card (nothing waits on it)}"
      fi
    done <<SEL_TEXT
$sel
SEL_TEXT
    case "$GO_JOB_STATE" in
      paused)  echo "  - the checkpoint cron job $GO_JOB_NAME ($GO_JOB_ID) is paused and will be resumed";;
      active)  echo "  - the checkpoint cron job $GO_JOB_NAME ($GO_JOB_ID) is already running";;
      missing) echo "  - WARNING: there is no cron job named $GO_JOB_NAME: no gate completes until it exists (go will say how to create it)";;
    esac
  else
    echo "  - no gate is armed and the checkpoint cron job is not touched: the run will stop at the next gate"
  fi
  echo "  to stop: forge stop $board"

  # ---- the confirmation ---------------------------------------------------------------------------------------------
  if [ "$yes" = 1 ]; then
    echo "  (confirmed by --yes)"
  elif [ -t 0 ]; then
    printf 'proceed? type y to put this in force: '
    ans=""; read -r ans || ans=""
    case "$ans" in y|Y|yes) ;; *) echo "not confirmed: nothing was changed"; exit 2;; esac
  else
    echo "forge go: not confirmed: this is not a terminal and --yes was not given. Nothing was changed." >&2; exit 2
  fi

  # ---- 4. the acts, each read back --------------------------------------------------------------------------------
  GO_ACTING=1
  out="$("$HERE/merge-authority.sh" grant "$board" --by "$by" --reason "forge go" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$out" >&2
    echo "forge go: the grant was refused, so nothing was put in force." >&2
    GO_DONE=1; if [ "$rc" = 1 ]; then exit 1; else exit 2; fi
  fi
  "$HERE/merge-authority.sh" status "$board" >/dev/null 2>&1; rc=$?
  if [ "$rc" != 0 ]; then echo "forge go: the grant does not read back (status exited $rc). Withdraw anything half done with: forge stop $board" >&2; GO_DONE=1; exit 2; fi
  go_say "granted: $board may be merged by the verifier (read back: granted by $by)"
  mode_word=""; armed_list=""
  if [ -n "$sel" ]; then
    while IFS= read -r grow; do
      [ -n "$grow" ] || continue
      gid="$(printf '%s' "$grow" | jq -r '.title | split(":")[0] | gsub("^ +| +$"; "")')"
      is_ready="$(printf '%s' "$grow" | jq -r '.ready')"
      out="$("$HERE/checkpoint-arm.sh" arm --board "$board" --gate "$gid" --project "$project" --mode apply --confirm-release 2>&1)"; rc=$?
      if [ "$rc" != 0 ]; then
        printf '%s\n' "$out" >&2
        echo "forge go: arming $gid failed. IN FORCE: merge authority on $board${armed_list:+, and $armed_list armed apply}. NOT in force: $gid. To withdraw: forge stop $board" >&2
        GO_DONE=1; exit 2
      fi
      if ! arm_read; then echo "forge go: the arming list could not be read back (exit $ARM_RC). Check: forge status $board" >&2; GO_DONE=1; exit 2; fi
      mode_word="$(arm_gates "$board" | awk -v g="$gid" '$1 == g { print $2 }')"
      if [ "$mode_word" != apply ]; then echo "forge go: $gid does not read back as armed apply (it reads '${mode_word:-not armed}'). IN FORCE: merge authority${armed_list:+, and $armed_list armed apply}. To withdraw: forge stop $board" >&2; GO_DONE=1; exit 1; fi
      if [ "$is_ready" = 1 ]; then go_say "armed: $gid on $board, apply, project $project (read back)"
      else go_say "armed: $gid on $board, apply, project $project, AHEAD of its milestone (read back)"; fi
      armed_list="${armed_list:+$armed_list, }$gid"
    done <<SEL_ACT
$sel
SEL_ACT
    go_cron_read; rc=$?
    if [ "$rc" != 0 ]; then
      echo "forge go: the cron job file could not be read. IN FORCE: merge authority and $armed_list armed apply. NOT confirmed: that the checkpoint job runs. Check: hermes cron list" >&2
      GO_DONE=1; exit 2
    fi
    case "$GO_JOB_STATE" in
      missing)
        {
          echo "forge go: there is no cron job named $GO_JOB_NAME, so nothing will complete $armed_list until one exists."
          echo "  IN FORCE (nothing was undone): merge authority on $board, and $armed_list armed apply."
          echo "  Create it (paused), then run this again with --rearm or resume it by hand:"
          echo "    hermes cron create 'every 15m' --name forge-checkpoint --no-agent --script forge-checkpoint.sh --deliver telegram --paused"
          echo "    hermes cron resume <id from: hermes cron list>"
          echo "  To withdraw all of it: forge stop $board"
        } >&2
        GO_DONE=1; exit 1;;
      paused)
        hermes cron resume "$GO_JOB_ID" >/dev/null 2>&1; rc=$?
        go_cron_read; rc=$?
        if [ "$rc" != 0 ] || [ "$GO_JOB_STATE" != active ]; then
          echo "forge go: $GO_JOB_NAME ($GO_JOB_ID) does not read back as running after hermes cron resume (it reads '${GO_JOB_STATE:-unreadable}'). IN FORCE: merge authority and $armed_list armed apply. Resume it by hand: hermes cron resume $GO_JOB_ID" >&2
          GO_DONE=1; if [ "$rc" != 0 ]; then exit 2; else exit 1; fi
        fi
        go_say "resumed: the checkpoint cron job $GO_JOB_NAME ($GO_JOB_ID) (read back: running)";;
      active) go_say "the checkpoint cron job $GO_JOB_NAME ($GO_JOB_ID) was already running (read back)";;
    esac
  fi
  GO_DONE=1
  echo
  echo "== in force =="
  "$HERE/forge.sh" status "$board" 2>&1
  echo
  echo "go: $board is launched. To stop: forge stop $board"
  return 0
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
# A ladder, not a script. The old launch was a page of prose and ten commands in an order the operator had to remember
# (docs/staged-run-guide.md). Here every rung asks the program that owns the answer (plan-check, roadmap-check,
# acceptance-freeze, merge-gate, preflight, overseer-guard, board-sync) and takes ITS verdict; nothing is re-derived. The
# ladder stops at the first rung that is not met, says in one NEXT line what to do, and shows the rest as not reached.
# It is READ-ONLY until the last rung: the only write is the bootstrap, behind the confirmation `go` also asks for. So it
# can be run again after every step, and a run that has nothing left to do says so and changes nothing.
#
# Three outcomes per rung: met (ok), not met (NEXT, exit 1), or COULD NOT ASK (??, exit 2). "Could not ask" is never
# "not there": a checker that cannot run is not a verdict. One trap the checkers set, and the reason a rung is more than
# `$? = 0`: plan-check and roadmap-check exit 2 when the document they read does not exist yet, which on a young project
# is not a broken host but a rung that is not met; so the file is asked about first, and only a checker that fails on a
# file that IS there is a rung that could not be asked.
ST_WORK=""; ST_ACTING=0; ST_DONE=0
ST_DIR=""; ST_BOARD=""; ST_BOARD_SET=0; ST_SUFFIX=""; ST_ROOT_ONLY=0; ST_COMMISSION=0; ST_YES=0
ST_SLUG=""; ST_BSTATE=""; ST_BCOUNT=""
# A project whose board already holds cards is RUNNING: start then answers "is it still in line with its plan", not "may it
# start", so a rung that is not met warns instead of stopping the ladder, and the board's own rung decides the exit.
ST_RUNNING=0; ST_WARNS=0; ST_WARN_AT=""
ST_LANE="${FORGE_LANE_ASSIGNEE:-forge-codex-lane}"
st_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  [ -z "$ST_WORK" ] || rm -rf "$ST_WORK"
  if [ "$ST_ACTING" = 1 ] && [ "$ST_DONE" = 0 ]; then
    echo "forge start: stopped during the bootstrap: board $ST_BOARD may hold part of the plan. forge start $ST_DIR shows where it stands" >&2
  fi
  exit "$rc"
}
st_signal() { echo "forge start: interrupted ($1)" >&2; exit 2; }

st_name() {
  case "$1" in
    1) echo "git";; 2) echo "origin";; 3) echo "ignore";; 4) echo "scope";; 5) echo "architect";; 6) echo "roadmap";;
    7) echo "acceptance";; 8) echo "plan";; 9) echo "merge gate";; 10) echo "host";; 11) echo "lanes";; 11+) echo "commission";; 12) echo "board";;
  esac
}
st_ok()   { printf '  ok    %-3s %s: %s\n' "$1" "$(st_name "$1")" "$2"; }
st_next() {
  if [ "$ST_RUNNING" = 1 ] && [ "$1" != 12 ]; then
    printf '  warn  %-3s %s: %s\n' "$1" "$(st_name "$1")" "$2"
    ST_WARNS=$((ST_WARNS + 1)); ST_WARN_AT="${ST_WARN_AT:+$ST_WARN_AT, }$1"
  else
    printf '  NEXT  %-3s %s: %s\n' "$1" "$(st_name "$1")" "$2"
  fi
}
st_ask()  { printf '  ??    %-3s %s: %s\n' "$1" "$(st_name "$1")" "$2"; }
st_skip() { printf '  -     %-3s %s\n' "$1" "$(st_name "$1")"; }
st_more() { printf '              %s\n' "$*"; }
st_lines() {  # stdin -> indented detail lines, at most $1 of them
  local n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    [ "$n" -le "${1:-12}" ] || { printf '              ... (%s more line(s))\n' "$(( $(cat | wc -l | tr -d ' ') + 1 ))"; break; }
    printf '              %s\n' "$line"
  done
}
# The checkers print a block per finding: `  FAIL|WARN|SKIP  name`, then its evidence and its remedy. The failing blocks only.
st_findings() {  # $1 status word, stdin the checker's output
  awk -v w="$1" '/^  (CLEAR|FAIL|WARN) — / { show = 0; next } /^  (PASS|FAIL|WARN|SKIP)[ ]/ { show = ($1 == w) } show && NF { sub(/^ +/, ""); print }'
}

st_r1() {
  local top rc br
  if [ ! -d "$ST_DIR" ]; then
    st_next 1 "$ST_DIR does not exist"
    st_more "stamp a new project there: forge new $(basename "$ST_DIR") --dest $(dirname "$ST_DIR")"
    return 1
  fi
  top="$(git -C "$ST_DIR" rev-parse --show-toplevel 2>"$ST_WORK/err")"; rc=$?
  if [ "$rc" != 0 ]; then
    if grep -q 'not a git repository' "$ST_WORK/err" 2>/dev/null; then
      st_next 1 "$ST_DIR is not a git repository"
      st_more "git -C $ST_DIR init -b main      (a new project: forge new <name> --dest <dir>)"
      return 1
    fi
    st_ask 1 "git could not read $ST_DIR: $(head -n 1 "$ST_WORK/err")"; return 2
  fi
  if [ "$(cd "$top" && pwd -P)" != "$ST_DIR" ]; then
    st_next 1 "$ST_DIR is inside the repository $top, not its root: give the root"; return 1
  fi
  br="$(git -C "$ST_DIR" symbolic-ref --short -q HEAD 2>/dev/null)" || br=""
  if [ "$br" != main ]; then
    st_next 1 "$ST_DIR is on '${br:-a detached HEAD}', not main"
    st_more "git -C $ST_DIR switch main      (a repository with no commit yet: git -C $ST_DIR branch -m main)"
    return 1
  fi
  st_ok 1 "a git repository on main"
}

st_r2() {
  local out rc name
  if ! git -C "$ST_DIR" remote get-url origin >/dev/null 2>&1; then
    st_next 2 "$ST_DIR has no origin"
    st_more "gh repo create $(basename "$ST_DIR") --private --source . --push      (run in $ST_DIR)"
    return 1
  fi
  command -v gh >/dev/null 2>&1 || { st_ask 2 "gh is not on PATH, so origin could not be resolved"; return 2; }
  out="$(cd "$ST_DIR" && gh repo view --json nameWithOwner 2>"$ST_WORK/err")"; rc=$?
  ST_SLUG=""
  [ "$rc" != 0 ] || ST_SLUG="$(printf '%s' "$out" | jq -r '.nameWithOwner // empty' 2>/dev/null)"
  if ! [[ $ST_SLUG =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    ST_SLUG=""; st_ask 2 "gh repo view could not name the repository behind origin ($(git -C "$ST_DIR" remote get-url origin 2>/dev/null)): $(head -n 1 "$ST_WORK/err" 2>/dev/null)"; return 2
  fi
  # The default board is <repository>-run-1, made a Hermes slug: GitHub allows capitals and dots, a slug allows neither.
  if [ "$ST_BOARD_SET" = 0 ]; then
    name="${ST_SLUG#*/}"; ST_BOARD="$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr . -)-run-1"
    if ! forge_board_slug_ok "$ST_BOARD"; then
      st_ask 2 "the default board name '$ST_BOARD' (from $ST_SLUG) is not a Hermes board slug: run again with --board <slug>"; return 2
    fi
  fi
  # Is the board already there with cards? It decides what the rungs after this one mean, so it is asked now, and read-only.
  if ! st_board_state; then
    st_ask 2 "GitHub $ST_SLUG, but hermes kanban boards list failed, so whether board $ST_BOARD exists could not be asked (it decides whether a rung not met stops the ladder or only warns)"; return 2
  fi
  [ "$ST_BSTATE" != exists ] || ST_RUNNING=1
  st_ok 2 "GitHub $ST_SLUG"
  if [ "$ST_RUNNING" = 1 ]; then
    st_more "board $ST_BOARD is on the board already ($ST_BCOUNT cards): a rung not met warns and the ladder goes on; only the board's own rung decides the exit"
  fi
}

st_r3() {
  local rc
  git -C "$ST_DIR" check-ignore -q .forge/x 2>/dev/null; rc=$?
  case "$rc" in
    0) st_ok 3 ".forge/ is ignored";;
    1) st_next 3 ".forge/ is not ignored, so run evidence would dirty the project"
       st_more "echo '.forge/' >> $ST_DIR/.gitignore      and commit it"
       return 1;;
    *) st_ask 3 "git check-ignore failed in $ST_DIR (exit $rc)"; return 2;;
  esac
}

st_plan() {  # $1 rung  $2 stage  $3 the document it reads  $4 the skill that writes it
  local out rc
  if [ ! -e "$ST_DIR/$3" ]; then
    st_next "$1" "$3 does not exist yet: open Claude Code in $ST_DIR and run /$4"; return 1
  fi
  out="$("$HERE/plan-check.sh" "$ST_DIR" --stage "$2" 2>"$ST_WORK/err")"; rc=$?
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^[[:space:]]*CLEAR — '; then
    st_ok "$1" "plan-check --stage $2 is CLEAR"; return 0
  fi
  if [ "$rc" = 1 ]; then
    st_next "$1" "plan-check --stage $2 found problems: open Claude Code in $ST_DIR and run /$4 (it resumes from what is there)"
    printf '%s\n' "$out" | st_findings FAIL | st_lines 12
    return 1
  fi
  st_ask "$1" "plan-check --stage $2 exited $rc without a verdict: $(head -n 1 "$ST_WORK/err" 2>/dev/null)"; return 2
}

st_r6() {
  local out rc summary
  if [ ! -e "$ST_DIR/docs/chunks/graph.json" ]; then
    st_next 6 "docs/chunks/graph.json does not exist yet: open Claude Code in $ST_DIR and run /roadmap"; return 1
  fi
  out="$("$HERE/roadmap-check.sh" "$ST_DIR" 2>"$ST_WORK/err")"; rc=$?
  summary="$(printf '%s\n' "$out" | grep -E '^[[:space:]]*(CLEAR|WARN) — ' | tail -n 1 | sed 's/^ *//')"
  if [ "$rc" = 0 ]; then
    case "$summary" in
      "CLEAR — "*) st_ok 6 "roadmap-check is $summary"; return 0;;
      "WARN — "*)
        st_next 6 "roadmap-check: $summary (exit 0 with warnings is not clear): fix the plan, or run /roadmap again"
        printf '%s\n' "$out" | st_findings WARN | st_lines 14
        return 1;;
    esac
  fi
  st_ask 6 "roadmap-check exited $rc and printed no CLEAR or WARN summary, so the plan was not checked"
  head -n 6 "$ST_WORK/err" 2>/dev/null | st_lines 6
  return 2
}

# Is acceptance frozen, and is the committed manifest the one the freeze would write today? acceptance-freeze.sh has one
# non-writing mode, --check-base, and it is the wrong question: it compares an implementation against an approved base, it
# never sees a feature that is missing from the manifest, and a stale digest is a FATAL there. So: run the real script on a
# scratch COPY of what git can see, and compare the manifest it writes there with the committed one. The project is not
# written.
st_same_json() {  # two files that both parse as JSON and are the same document (whitespace and key order aside)
  local a b
  a="$(jq -S . "$1" 2>/dev/null)" || return 1
  b="$(jq -S . "$2" 2>/dev/null)" || return 1
  [ -n "$a" ] && [ "$a" = "$b" ]
}
st_r7() {
  local scratch="$ST_WORK/freeze" f out rc m="docs/chunks/contract-freeze.json"
  if [ ! -e "$ST_DIR/docs/chunks/graph.json" ]; then
    st_next 7 "docs/chunks/graph.json does not exist yet: open Claude Code in $ST_DIR and run /roadmap"; return 1
  fi
  rm -rf "$scratch"; mkdir -p "$scratch" || { st_ask 7 "cannot make a scratch directory"; return 2; }
  if ! { git -C "$ST_DIR" ls-files -z -co --exclude-standard 2>/dev/null | while IFS= read -r -d '' f; do if [ -e "$ST_DIR/$f" ]; then printf '%s\0' "$f"; fi; done \
         | tar -C "$ST_DIR" --null -T - -cf - 2>/dev/null | tar -C "$scratch" -xf - 2>/dev/null; } \
     || [ ! -d "$scratch/docs/chunks" ]; then
    st_ask 7 "a scratch copy of $ST_DIR could not be made, so the freeze could not be tried"; return 2
  fi
  out="$("$HERE/acceptance-freeze.sh" "$scratch" 2>"$ST_WORK/err")"; rc=$?
  case "$rc" in
    0) if [ -f "$ST_DIR/$m" ] && [ -f "$scratch/$m" ] && { cmp -s "$scratch/$m" "$ST_DIR/$m" || st_same_json "$scratch/$m" "$ST_DIR/$m"; }; then
         st_ok 7 "acceptance is frozen and $m is current"; return 0
       fi
       st_next 7 "$m is $([ -f "$ST_DIR/$m" ] && echo "out of date" || echo "missing"): the plan's acceptance is not frozen as committed"
       st_more "~/.forge/repo/scripts/acceptance-freeze.sh $ST_DIR      then commit $m"
       return 1;;
    1) st_next 7 "acceptance-freeze rejects the plan's contracts or features"
       head -n 12 "$ST_WORK/err" | st_lines 12
       st_more "fix them (open Claude Code in $ST_DIR and run /roadmap), then ~/.forge/repo/scripts/acceptance-freeze.sh $ST_DIR and commit"
       return 1;;
    *) st_ask 7 "acceptance-freeze exited $rc: $(head -n 1 "$ST_WORK/err" 2>/dev/null)"; return 2;;
  esac
}

st_r8() {
  local porc n head origin counts ahead behind
  if ! porc="$(git -C "$ST_DIR" status --porcelain 2>/dev/null)"; then st_ask 8 "git status failed in $ST_DIR"; return 2; fi
  if [ -n "$porc" ]; then
    n="$(printf '%s\n' "$porc" | wc -l | tr -d ' ')"
    st_next 8 "the working tree is not clean ($n path(s)): the plan is not committed"
    printf '%s\n' "$porc" | st_lines 6
    st_more "git -C $ST_DIR add -A && git -C $ST_DIR commit -m 'plan: ...'      then push it, or open the plan PR"
    return 1
  fi
  if ! git -C "$ST_DIR" fetch --quiet origin 2>/dev/null; then st_ask 8 "git fetch origin failed in $ST_DIR, so whether the plan is on GitHub could not be asked"; return 2; fi
  head="$(git -C "$ST_DIR" rev-parse HEAD 2>/dev/null)"
  if ! origin="$(git -C "$ST_DIR" rev-parse --verify -q origin/main 2>/dev/null)"; then
    st_next 8 "origin has no main yet: the plan is not on GitHub"
    st_more "git -C $ST_DIR push -u origin main"
    return 1
  fi
  if [ -z "$head" ]; then st_ask 8 "git rev-parse HEAD failed in $ST_DIR (no commit?)"; return 2; fi
  if [ "$head" = "$origin" ]; then st_ok 8 "clean, and HEAD is origin/main (${head:0:8})"; return 0; fi
  counts="$(git -C "$ST_DIR" rev-list --left-right --count "HEAD...origin/main" 2>/dev/null)" || { st_ask 8 "git rev-list failed in $ST_DIR"; return 2; }
  read -r ahead behind <<ST_COUNTS
$counts
ST_COUNTS
  if [ "${ahead:-0}" != 0 ] && [ "${behind:-0}" = 0 ]; then
    st_next 8 "HEAD is $ahead commit(s) ahead of origin/main: the plan is not on GitHub"
    st_more "git -C $ST_DIR push      (main is protected: push a branch, open the plan PR, merge it, then git -C $ST_DIR pull --ff-only)"
  elif [ "${ahead:-0}" = 0 ]; then
    st_next 8 "HEAD is $behind commit(s) behind origin/main"
    st_more "git -C $ST_DIR pull --ff-only"
  else
    st_next 8 "HEAD and origin/main have diverged ($ahead ahead, $behind behind)"
    st_more "bring them together first: git -C $ST_DIR log --oneline --left-right HEAD...origin/main"
  fi
  return 1
}

# The posture is merge-gate's own, asked as commission.sh asks it (the default branch, the `check` context): a repository
# one of them calls gated and the other does not would be a launch that commissions and then does not hold.
st_r9() {
  local out rc
  out="$("$HERE/merge-gate.sh" "$ST_SLUG" --branch main --require check 2>"$ST_WORK/err")"; rc=$?
  case "$rc" in
    0) st_ok 9 "$out";;
    5) st_ok 9 "UNGATED (GitHub cannot gate a private repo on this plan; CI green is checked by the verifier)";;
    3|4) st_next 9 "$ST_SLUG is not gated ($out): branch protection requiring the check is not in force"
         st_more "make -C $ST_DIR protect"
         return 1;;
    *) st_ask 9 "merge-gate exited $rc, so whether $ST_SLUG is gated could not be asked: $(head -n 1 "$ST_WORK/err" 2>/dev/null)"; return 2;;
  esac
}

st_r10() {
  local out rc summary
  if ! out="$(fx_gateway_running)"; then
    st_next 10 "the Hermes gateway is not running ($out): start it, then run this again"; return 1
  fi
  "$HERE/preflight.sh" >"$ST_WORK/pf.out" 2>"$ST_WORK/err"; rc=$?
  summary="$(grep -E '^PASS [0-9]+ +WARN [0-9]+ +FAIL [0-9]+' "$ST_WORK/pf.out" | tail -n 1)"
  if [ "$rc" = 0 ] && [ -n "$summary" ] && printf '%s' "$summary" | grep -Eq 'FAIL 0$'; then
    st_ok 10 "the gateway is running; preflight: $summary"; return 0
  fi
  if [ "$rc" = 1 ] && [ -n "$summary" ]; then
    st_next 10 "preflight has failures ($summary): fix each FAIL, then run this again (make preflight shows all of it)"
    grep '^FAIL ' "$ST_WORK/pf.out" | st_lines 12
    return 1
  fi
  st_ask 10 "preflight exited $rc without a readable summary, so the host was not checked"; return 2
}

st_r11() {
  local graph="$ST_DIR/docs/chunks/graph.json" out rc lanes assignees missing l
  if [ ! -e "$graph" ]; then
    st_next 11 "docs/chunks/graph.json does not exist, so the lanes of the plan cannot be read"; return 1
  fi
  out="$("$HERE/overseer-guard.sh" lane "$ST_LANE" 2>&1)"; rc=$?
  case "$rc" in
    0) ;;
    1) st_next 11 "FORGE_LANE_ASSIGNEE names the overseer: unset it (the default lane is forge-codex-lane)"; printf '%s\n' "$out" | st_lines 4; return 1;;
    *) st_ask 11 "overseer-guard.sh lane exited $rc"; return 2;;
  esac
  out="$("$HERE/overseer-guard.sh" graph "$graph" 2>&1)"; rc=$?
  case "$rc" in
    0) ;;
    1) st_next 11 "the plan routes a card to the overseer, which is gate-only: edit the lane in docs/chunks/graph.json"; printf '%s\n' "$out" | st_lines 4; return 1;;
    *) st_ask 11 "overseer-guard.sh graph exited $rc: $(printf '%s' "$out" | head -n 1)"; return 2;;
  esac
  lanes="$(jq -r --arg lane "$ST_LANE" '[.[] | (.lane // (if (.id | startswith("GATE-")) then "claude-interactive" else $lane end))] | unique | .[] | select(. != "claude-interactive")' "$graph" 2>/dev/null)" \
    || { st_ask 11 "the lanes of $graph could not be read"; return 2; }
  if ! assignees="$(hermes kanban assignees --json 2>/dev/null)" || ! printf '%s' "$assignees" | jq -e 'type == "array"' >/dev/null 2>&1; then
    st_ask 11 "hermes kanban assignees --json failed, so the lanes could not be asked about"; return 2
  fi
  missing=""
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    printf '%s' "$assignees" | jq -e --arg a "$l" 'any(.[]; .name == $a and .on_disk)' >/dev/null 2>&1 || missing="${missing:+$missing, }$l"
  done <<ST_LANES
$lanes
ST_LANES
  if [ -n "$missing" ]; then
    st_next 11 "the plan names lane(s) that are not Hermes profiles on disk: $missing"
    st_more "~/.forge/repo/hermes/profiles-bootstrap.sh      or correct the lane in docs/chunks/graph.json"
    return 1
  fi
  st_ok 11 "every lane ($(printf '%s' "$lanes" | paste -sd, - | sed 's/,/, /g')) is a Hermes profile on disk, and no card goes to the overseer"
}

# board-sync's dry run, from the project, with the suffix: its output goes to $ST_WORK/sync.out and its exit is the verdict.
st_sync() {
  (cd "$ST_DIR" && "$HERE/../hermes/board-sync.sh" "$ST_BOARD" ${ST_SUFFIX:+--branch-suffix} ${ST_SUFFIX:+"$ST_SUFFIX"}) >"$ST_WORK/sync.out" 2>&1
}

# The board, asked of Hermes once: absent | empty (listed, no card: what an earlier refused bootstrap leaves behind, and
# which bootstrap reuses) | archived | exists. 0 answered, 2 could not ask.
st_board_state() {
  local out row
  [ -z "$ST_BSTATE" ] || return 0
  out="$(hermes kanban boards list --all --json 2>/dev/null)" || return 2
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
  row="$(printf '%s' "$out" | jq -c --arg b "$ST_BOARD" '[.[] | select(.slug == $b)] | .[0] // empty' 2>/dev/null)"
  if [ -z "$row" ]; then ST_BSTATE=absent; ST_BCOUNT=0
  elif [ "$(printf '%s' "$row" | jq -r '.archived // false')" = true ]; then ST_BSTATE=archived; ST_BCOUNT=""
  else
    ST_BCOUNT="$(printf '%s' "$row" | jq -r '.total // "?"')"
    if [ "$ST_BCOUNT" = 0 ]; then ST_BSTATE=empty; else ST_BSTATE=exists; fi
  fi
  return 0
}

st_r11c() {
  local out rc report overall posture
  if ! st_board_state; then st_ask 11+ "hermes kanban boards list failed, so whether board $ST_BOARD exists could not be asked"; return 2; fi
  case "$ST_BSTATE" in
    exists|archived) printf '  -     %-3s %s: not run: board %s already exists, and commissioning is the evidence taken BEFORE a first bootstrap\n' 11+ commission "$ST_BOARD"; return 0;;
  esac
  out="$("$HERE/commission.sh" "$ST_DIR" "$ST_BOARD" 2>"$ST_WORK/err")"; rc=$?
  report="$(printf '%s\n' "$out" | sed -n 's/^commission report: //p' | tail -n 1)"
  overall=""; posture=""
  if [ -n "$report" ] && [ -f "$report" ]; then
    overall="$(sed -n 's/^overall: //p' "$report" | tail -n 1)"; posture="$(sed -n 's/^posture: //p' "$report" | tail -n 1)"
  fi
  if [ "$rc" = 0 ] && [ "$overall" = PASS ]; then
    st_ok 11+ "commissioned (this spent one paid Codex sandbox probe)"
    st_more "overall: $overall"; st_more "posture: $posture"; st_more "report: $report"
    return 0
  fi
  if [ "$rc" = 1 ] || [ "$overall" = FAIL ]; then
    st_next 11+ "commissioning FAILED: read the report, fix what it names, and run this again (that spends again)"
    st_more "overall: ${overall:-FAIL}"; [ -z "$posture" ] || st_more "posture: $posture"; [ -z "$report" ] || st_more "report: $report"
    return 1
  fi
  st_ask 11+ "commission.sh exited $rc and left no readable report, so whether the product is commissioned is not known: $(head -n 1 "$ST_WORK/err" 2>/dev/null)"; return 2
}

# What the bootstrap is about to do, in plain words, read from the same graph the bootstrap reads. Several roots cannot
# happen (board-bootstrap.sh refuses a graph without exactly one), but the text does not rely on that.
st_plan_words() {
  local graph="$ST_DIR/docs/chunks/graph.json" chunks gates started waiting hand first n
  chunks="$(jq '[.[] | select(.id | startswith("CHUNK-"))] | length' "$graph")"
  gates="$(jq '[.[] | select(.id | startswith("GATE-"))] | length' "$graph")"
  started="$(jq -r --arg lane "$ST_LANE" '[.[] | select(((.depends_on // []) | length) == 0) | (.lane // (if (.id | startswith("GATE-")) then "claude-interactive" else $lane end)) as $l | select($l != "claude-interactive") | "\(.id) (\($l))"] | join(", ")' "$graph")"
  waiting="$(jq -r '[.[] | select(((.depends_on // []) | length) == 0) | select((.lane // "") == "claude-interactive") | .id] | join(", ")' "$graph")"
  hand="$(jq -r '[.[] | select(.id | startswith("CHUNK-")) | select((.lane // "") == "claude-interactive") | .id] | join(", ")' "$graph")"
  first="$(jq -r '. as $g | [.[] | select(.id | startswith("GATE-")) | .id] as $gs
      | def behind($set): [$g[] | select(any((.depends_on // [])[]; . as $d | ($gs | index($d)) != null or ($set | index($d)) != null)) | .id];
        (reduce range(0; ($g | length)) as $i ([]; behind(.) | sort)) as $past
      | [$gs[] | select(. as $x | ($past | index($x)) == null)] | join(", ")' "$graph" 2>/dev/null)"
  echo "forge start will now bootstrap board $ST_BOARD from $ST_DIR${ST_SUFFIX:+ (branch suffix $ST_SUFFIX)}:"
  if [ "$ST_ROOT_ONLY" = 1 ]; then
    echo "  - ONE card is created now (--root-only): the root. The other $(( chunks + gates - 1 )) card(s) of the plan ($chunks chunk card(s) and $gates gate card(s), over $gates milestone(s)) come from the full bootstrap, after the root's PR has merged"
  else
    echo "  - $(( chunks + gates )) cards: $chunks chunk card(s) and $gates gate card(s), over $gates milestone(s) (docs/chunks/graph.json)"
  fi
  if [ -n "$started" ]; then
    echo "  - it STARTS IMMEDIATELY: $started is ready the moment it is created, so the gateway's dispatcher gives it to its lane within about a minute, and the lane spends a Codex run on it"
  else
    echo "  - nothing starts by itself: the root is hand-built, so no lane is given a card yet"
  fi
  if [ -n "$waiting" ]; then echo "  - the root $waiting is hand-built (claude-interactive): nothing runs it, it waits for you"; fi
  if [ -n "$hand" ]; then echo "  - hand-built (claude-interactive) chunks wait for you, whenever their turn comes: $hand"; fi
  echo "  - the verifier only RECOMMENDS merges (a card blocks as merge-pending) until forge go grants it merge authority; this step grants nothing"
  if [ -n "$first" ]; then
    echo "  - everything behind $first waits for that gate: it is held until its milestone's chunks are done and its probe is passed (forge go arms it)"
  else
    echo "  - the plan has no milestone gate, so nothing is held back by one"
  fi
  echo "  to archive the board again: hermes kanban boards rm $ST_BOARD (a card that has already started finishes its run)"
}

st_r12() {
  local out rc args root title cards sync_rc brc bs ans
  if ! st_board_state; then st_ask 12 "hermes kanban boards list failed, so whether board $ST_BOARD exists could not be asked"; return 2; fi
  bs="$ST_BOARD"
  case "$ST_BSTATE" in
    archived)
      st_next 12 "board $bs exists but is archived: a board with old rows is not a clean run boundary"
      st_more "choose another: forge start $ST_DIR --board <new slug>${ST_SUFFIX:+ --branch-suffix $ST_SUFFIX}"
      return 1;;
    exists)
      st_sync; sync_rc=$?
      case "$sync_rc" in
        0) st_ok 12 "board $bs exists ($ST_BCOUNT cards) and matches the plan"
           echo
           echo "already on board $bs: nothing to start. Next: forge go $bs --project $ST_DIR${ST_SUFFIX:+ --branch-suffix $ST_SUFFIX}"
           return 0;;
        1) st_next 12 "board $bs exists but differs from the plan"
           head -n 12 "$ST_WORK/sync.out" | st_lines 12
           st_more "see it:        (cd $ST_DIR && ~/.forge/repo/hermes/board-sync.sh $bs${ST_SUFFIX:+ --branch-suffix $ST_SUFFIX})"
           st_more "make it match: (cd $ST_DIR && ~/.forge/repo/hermes/board-sync.sh $bs${ST_SUFFIX:+ --branch-suffix $ST_SUFFIX} --apply)"
           st_more "a board started with --root-only gets the rest from the full bootstrap, which is idempotent and reuses the root:"
           st_more "                (cd $ST_DIR && ~/.forge/repo/hermes/board-bootstrap.sh $bs${ST_SUFFIX:+ --branch-suffix $ST_SUFFIX})"
           return 1;;
        *) st_ask 12 "board-sync exited $sync_rc, so whether board $bs matches the plan could not be asked"
           head -n 4 "$ST_WORK/sync.out" | st_lines 4
           return 2;;
      esac;;
  esac

  # ---- the act: the board is absent (or listed with no card) ------------------------------------------------------------
  printf '  ACT   %-3s %s: board %s %s: this is the one rung that writes\n' 12 board "$bs" "$([ "$ST_BSTATE" = empty ] && echo "exists with no card (an earlier refused bootstrap)" || echo "does not exist yet")"
  echo
  st_plan_words
  if [ "$ST_YES" = 1 ]; then
    echo "  (confirmed by --yes)"
  elif [ -t 0 ]; then
    printf 'proceed? type y to create the board and start the plan: '
    ans=""; read -r ans || ans=""
    case "$ans" in y|Y|yes) ;; *) echo "not confirmed: nothing was changed"; exit 2;; esac
  else
    echo "forge start: not confirmed: this is not a terminal and --yes was not given. Nothing was changed." >&2; exit 2
  fi

  ST_ACTING=1
  args=("$bs")
  [ "$ST_ROOT_ONLY" = 0 ] || args+=(--root-only)
  [ -z "$ST_SUFFIX" ] || args+=(--branch-suffix "$ST_SUFFIX")
  out="$(cd "$ST_DIR" && "$HERE/../hermes/board-bootstrap.sh" "${args[@]}" 2>&1)"; brc=$?
  printf '%s\n' "$out" | tail -n 40 | sed 's/^/    /'
  case "$brc" in
    0) ;;
    3) ST_DONE=1; echo "forge start: REFUSED (exit 3): a branch of the plan is spent (a PR or a remote branch already uses it). No card was created. Pick another --branch-suffix: forge start $ST_DIR --branch-suffix <new>" >&2; return 1;;
    2) ST_DONE=1; echo "forge start: could not ask (exit 2): GitHub, origin or the board could not be asked, which is not the same as free. No card was created. Fix what it names and run this again" >&2; exit 2;;
    4) ST_DONE=1; echo "forge start: REFUSED (exit 4): the board already holds a card under a different branch suffix. Use the suffix the board was started with, or another board" >&2; return 1;;
    1) ST_DONE=1; echo "forge start: REFUSED (exit 1): the bootstrap refused the plan or its arguments (above). A refusal before the cards creates none; run forge start again to see where the board stands" >&2; return 1;;
    *) ST_DONE=1; echo "forge start: the bootstrap could not run (exit $brc). Run forge start again to see where board $bs stands" >&2; exit 2;;
  esac

  # ---- read it back: the exit code of the bootstrap is not the answer -------------------------------------------------
  if [ "$ST_ROOT_ONLY" = 1 ]; then
    root="$(jq -r '[.[] | select(((.depends_on // []) | length) == 0) | .id] | .[0] // empty' "$ST_DIR/docs/chunks/graph.json" 2>/dev/null)"
    title="$(head -n 1 "$ST_DIR/docs/chunks/$root.md" 2>/dev/null | sed 's/^#* *//')"
    cards="$(hermes kanban --board "$bs" list --json 2>/dev/null)"; rc=$?
    if [ "$rc" != 0 ] || [ -z "$root" ] || ! printf '%s' "$cards" | jq -e '(if type == "object" then .tasks else . end) | type == "array"' >/dev/null 2>&1; then
      ST_DONE=1; echo "forge start: the bootstrap exited 0 but the board's cards could not be read back, so the root card is not confirmed. Check: forge status $bs" >&2; exit 2
    fi
    if ! printf '%s' "$cards" | jq -e --arg t "$title" '(if type == "object" then .tasks else . end) | any(.[]; .title == $t)' >/dev/null 2>&1; then
      ST_DONE=1; echo "forge start: the bootstrap exited 0 but board $bs has no card titled '$title': the root card is not there. Check: forge status $bs" >&2; return 1
    fi
    echo "read back: the root card ($root) is on board $bs"
  else
    st_sync; sync_rc=$?
    case "$sync_rc" in
      0) echo "read back: board $bs is in sync with the plan (board-sync dry run)";;
      1) ST_DONE=1; echo "forge start: the bootstrap exited 0 but the board does not match the plan:" >&2; head -n 12 "$ST_WORK/sync.out" | sed 's/^/    /' >&2; return 1;;
      *) ST_DONE=1; echo "forge start: the bootstrap exited 0 but board-sync could not read the board back (exit $sync_rc), so it is not confirmed. Check: forge status $bs" >&2; exit 2;;
    esac
  fi
  ST_DONE=1
  echo
  echo "== forge status $bs =="
  "$HERE/forge.sh" status "$bs" 2>&1 || true
  echo
  echo "started: board $bs is on the plan. Nothing is granted yet: the verifier only recommends merges."
  echo "next: forge go $bs --project $ST_DIR${ST_SUFFIX:+ --branch-suffix $ST_SUFFIX}      (grants merge authority, arms the first gate)"
  echo "stop: forge stop $bs"
  return 0
}

st_run_rung() {
  local rc
  case "$1" in
    1) st_r1;; 2) st_r2;; 3) st_r3;;
    4) st_plan 4 scope docs/REQUIREMENTS.md scope;;
    5) st_plan 5 architect docs/feasibility.md architect;;
    6) st_r6;; 7) st_r7;; 8) st_r8;; 9) st_r9;; 10) st_r10;;
    11) st_r11; rc=$?
        if [ "$rc" = 0 ] && [ "$ST_COMMISSION" = 0 ] && [ "$ST_RUNNING" = 0 ]; then
          echo "        commissioning skipped: --commission would run scripts/commission.sh, which runs make verify WITH_CODEX=1 (one paid Codex sandbox probe, about 18 minutes) and writes a report under $ST_DIR/.forge/"
        fi
        return "$rc";;
    11+) st_r11c;;
    12) st_r12;;
  esac
}

cmd_start() {
  local dir="" n rc stopped=0 stopped_at="" rungs tool
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0;;
      --board)   [ $# -ge 2 ] || usage_err "start: --board needs a board slug"; ST_BOARD="$2"; ST_BOARD_SET=1; shift 2;;
      --branch-suffix) [ $# -ge 2 ] || usage_err "start: --branch-suffix needs a suffix"; ST_SUFFIX="$2"; shift 2;;
      --root-only)  ST_ROOT_ONLY=1; shift;;
      --commission) ST_COMMISSION=1; shift;;
      --yes|-y)     ST_YES=1; shift;;
      -*) usage_err "start: unknown option '$1'";;
      *)  [ -z "$dir" ] || usage_err "start takes one project directory: '$dir' and '$1'"; dir="$1"; shift;;
    esac
  done
  [ -n "$dir" ] || usage_err "start needs the project directory"
  [ "$ST_BOARD_SET" = 0 ] || forge_board_slug_ok "$ST_BOARD" || die "'$ST_BOARD' is not a board slug (Hermes: lowercase letters, digits, - and _, starting with a letter or digit, at most 64)"
  [ -z "$ST_SUFFIX" ] || { [[ $ST_SUFFIX =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#ST_SUFFIX}" -le 32 ]; } || usage_err "start: --branch-suffix is a lowercase slug of at most 32 characters"
  for tool in jq git hermes; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"; done
  case "$dir" in /*) ;; *) dir="$PWD/$dir";; esac
  if [ -d "$dir" ]; then ST_DIR="$(cd "$dir" && pwd -P)"; else ST_DIR="${dir%/}"; fi
  ST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-start.XXXXXX")" || die "cannot make a temporary directory"
  trap st_exit EXIT; trap 'st_signal INT' INT; trap 'st_signal TERM' TERM; trap 'st_signal HUP' HUP

  rungs="1 2 3 4 5 6 7 8 9 10 11"
  [ "$ST_COMMISSION" = 0 ] || rungs="$rungs 11+"
  rungs="$rungs 12"
  echo "forge start $ST_DIR$([ "$ST_BOARD_SET" = 1 ] && echo " (board $ST_BOARD)")"
  for n in $rungs; do
    if [ "$stopped" != 0 ]; then st_skip "$n"; continue; fi
    st_run_rung "$n"; rc=$?
    case "$rc" in
      0) ;;
      1) if [ "$ST_RUNNING" = 1 ] && [ "$n" != 12 ]; then :; else stopped=1; stopped_at="$n"; fi;;
      *) stopped=2; stopped_at="$n";;
    esac
  done
  case "$stopped" in
    0) if [ "$ST_WARNS" -gt 0 ]; then
         echo
         echo "forge start: $ST_WARNS warning(s), at rung $ST_WARN_AT: the board matches the plan, but the project no longer meets every rung the plan was started on"
       fi
       return 0;;
    1) echo
       if [ "$ST_ACTING" = 1 ]; then echo "forge start: the bootstrap was refused at rung $stopped_at (above)"
       else echo "forge start: stopped at rung $stopped_at ($(st_name "$stopped_at")): do the step marked above and run this again. Nothing was changed."; fi
       [ "$ST_WARNS" = 0 ] || echo "forge start: $ST_WARNS warning(s) before it, at rung $ST_WARN_AT"
       return 1;;
    *) echo
       echo "forge start: could not ask at rung $stopped_at ($(st_name "$stopped_at")): that is not the same as met. Nothing was changed." >&2
       return 2;;
  esac
}

# ---------------------------------------------------------------------------
# new
# ---------------------------------------------------------------------------
# What `make new` prints as manual steps, as a program: resolve the target through the one durable-path guard
# (scripts/new-dest.sh), stamp templates/python-service, `git init -b main`, `make setup`, the first commit; with --github
# also create the repository, push, run the template's `make protect` and ask merge-gate what came of it. It never
# overwrites: new-dest.sh refuses a volatile or relative destination, not one that exists, so the existing target is
# refused here, before anything is written.
new_step() { printf 'new: %s\n' "$*"; }
new_fail() {  # <step> <what is left on disk>
  echo "forge new: FAILED at: $1. $2" >&2; exit 1
}
cmd_new() {
  local name="" dest="" github="" public=0 target out rc tmpl gate_rc gate_out
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0;;
      --dest)   [ $# -ge 2 ] || usage_err "new: --dest needs a directory"; dest="$2"; shift 2;;
      --github) [ $# -ge 2 ] || usage_err "new: --github needs <owner>/<repo>"; github="$2"; shift 2;;
      --public) public=1; shift;;
      -*) usage_err "new: unknown option '$1'";;
      *)  [ -z "$name" ] || usage_err "new takes one project name: '$name' and '$1'"; name="$1"; shift;;
    esac
  done
  [ -n "$name" ] || usage_err "new needs a project name"
  [ "$public" = 0 ] || [ -n "$github" ] || usage_err "new: --public belongs to --github (a repository is only created with it)"
  [ -z "$github" ] || [[ $github =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage_err "new: --github is <owner>/<repo>, not '$github'"
  dest="${dest:-${HOME:-}/dev}"
  [ -n "$dest" ] && [ "$dest" != /dev ] || usage_err "new: --dest is empty (and HOME gives no default)"
  tmpl="$HERE/../templates/python-service"
  for tool in git make uvx; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH. Nothing was written."; done
  [ -z "$github" ] || command -v gh >/dev/null 2>&1 || die "gh is not on PATH. Nothing was written."
  [ -d "$tmpl" ] || die "the template $tmpl is not there. Nothing was written."
  # the one guard for where a project may live; its refusal is a refusal, and it says why
  target="$("$HERE/new-dest.sh" "$dest" --name "$name")" || exit 2
  [ -n "$target" ] || die "new-dest.sh named no target. Nothing was written."
  if [ -e "$target" ] || [ -L "$target" ]; then
    echo "forge new: $target already exists, and forge new never overwrites. Nothing was written." >&2; exit 2
  fi
  echo "forge new $name -> $target"

  new_step "stamping templates/python-service"
  uvx copier copy "$tmpl" "$target" --defaults --data project_name="$name"; rc=$?
  [ "$rc" = 0 ] && [ -d "$target" ] || new_fail "stamping the template (uvx copier exited $rc)" "$target may be partly written: look at it, remove it, run again."
  new_step "git init -b main"
  git -C "$target" init -q -b main || new_fail "git init -b main" "$target is stamped but is not a repository."
  new_step "make setup"
  (cd "$target" && make setup) || new_fail "make setup" "$target is stamped and is a repository with no commit. Run make setup there when its cause is fixed, then commit."
  new_step "the initial commit"
  git -C "$target" add -A || new_fail "git add" "$target is stamped and set up, with nothing committed."
  git -C "$target" commit -q -m "initial commit: stamped from forge templates/python-service" || new_fail "the initial commit" "$target is stamped and set up, with nothing committed (a hook may have refused it: read its message above)."

  if [ -n "$github" ]; then
    new_step "gh repo create $github $([ "$public" = 1 ] && echo --public || echo --private) --source . --push"
    (cd "$target" && gh repo create "$github" "$([ "$public" = 1 ] && echo --public || echo --private)" --source . --push) \
      || new_fail "gh repo create $github" "$target is committed locally; the GitHub repository may or may not exist: gh repo view $github. Push with: cd $target && gh repo create $github --private --source . --push"
    new_step "make protect"
    (cd "$target" && make protect); rc=$?
    # make protect's own exit is not the answer: on a private repository on a free plan it fails with a 403 for a
    # reason no configuration can fix, and that is an answer, not a failure. Ask what GitHub says, as commission does.
    gate_out="$("$HERE/merge-gate.sh" "$github" --branch main --require check 2>/dev/null)"; gate_rc=$?
    case "$gate_rc" in
      0) echo "posture: GATED (branch protection requires a PR and the check: $gate_out)";;
      5) echo "posture: UNGATED (GitHub cannot gate a private repository on this plan; CI green is checked by the verifier)";;
      3|4) new_fail "make protect (exit $rc): $github is not gated ($gate_out)" "$target is pushed to $github. Fix the protection (cd $target && make protect) before forge start.";;
      *) echo "forge new: the project is stamped and pushed, but whether $github is gated could not be asked (merge-gate exited $gate_rc). Ask it: $HERE/merge-gate.sh $github --branch main --require check" >&2; exit 2;;
    esac
  else
    echo "next: gh repo create $name --private --source . --push      (run in $target; then make protect)"
  fi
  echo "next: open Claude Code in $target and run /scope — then: forge start $target"
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
