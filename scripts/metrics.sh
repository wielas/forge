#!/usr/bin/env bash
# =============================================================================
# forge metrics — the flywheel's numbers, computed instead of asserted.
#
# `docs/retro-metrics.md` defines the numbers that decide whether the Forge is
# improving. Until this script existed, /retro asked a language model to derive
# them by reading printed board output — which is ADR-0003's exact prohibition
# applied to the one component whose whole purpose is to be trustworthy. It had
# already failed in every way it could (audit F27): a bounce rate of 0.00 on a
# run with 12 bounces, a row reading "n/a — noncanonical metadata", no row at
# all for the largest run to date, and 22 malformed chunk envelopes nobody saw
# for three days because nothing ever queried the board's own exhaust.
#
# READ-ONLY BY DESIGN, via a snapshot copy. The live board is only ever read —
# copied byte for byte into a private temp dir, fingerprinted before and after
# to prove the copy is not torn, and queried there. `make verify`'s
# metrics/is-read-only case hashes the original across invocations to keep it so.
#
# It used to open the live file `file:...?mode=ro` instead, which was wrong
# twice (audit F47). A read-only connection cannot create the `-shm` file that
# WAL requires, and every Hermes board is `journal_mode=wal` — so it worked only
# while some other process happened to hold the board open, and failed on a
# board at rest, which is exactly the state a board is in when someone sits down
# to run /retro. And `mode=ro` never addressed the torn read at all: a report
# assembled from a board being written underneath it is inconsistent whether or
# not the connection opens. The snapshot is the pattern `forgeboard-report`'s
# own `hermes.py` uses, and it fixes both.
#
# THE SNAPSHOT NO LONGER LIVES HERE. It is scripts/board-snapshot.sh, shared
# with verify.sh's live-board check, because the fix above landed on this file
# and stopped — while a check forty lines inside verify.sh went on opening a
# live board `mode=ro` for weeks afterwards, and cost a second finding (F67).
# One implementation, one behaviour, one place to fix it next time.
#
# Usage:
#   ./scripts/metrics.sh <board-slug>                    # human-readable report
#   ./scripts/metrics.sh <board-slug> --json             # the same numbers, JSON
#   ./scripts/metrics.sh <board-slug> --markdown-row     # a docs/retro-metrics.md row
#   ./scripts/metrics.sh <board-slug> --since 2026-07-29 --until 2026-07-30
#
# --since/--until are LOCAL calendar dates and both ends are inclusive.
#
# Exit: 0 on success, 2 on a usage or environment error.
# =============================================================================
set -uo pipefail

# Anchored to CONTENT, never to line numbers. `sed -n '2,27p'` printed the
# rationale and stopped one line before `# Usage:`, and the no-board branch's
# `sed -n '17,25p'` printed nine lines of F47 prose containing no usage line at
# all — both ranges were pinned to a header that had since moved beneath them,
# and metrics/help-exits-zero asserted only the exit code, so nothing reddened.
help_text()  { awk '/^# ={10}/ { n++; if (n == 2) exit; next } n == 1' "$0"; }
usage_text() { sed -n '/^# Usage:/,/^# Exit:/p' "$0"; }

BOARD=""; SINCE=""; UNTIL=""; FORMAT="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:?--since needs YYYY-MM-DD}"; shift 2;;
    --until) UNTIL="${2:?--until needs YYYY-MM-DD}"; shift 2;;
    --json) FORMAT="json"; shift;;
    --markdown-row) FORMAT="markdown-row"; shift;;
    -h|--help) help_text; exit 0;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) [ -z "$BOARD" ] || { echo "only one board slug: got '$BOARD' and '$1'" >&2; exit 2; }
       BOARD="$1"; shift;;
  esac
done
[ -n "$BOARD" ] || { usage_text >&2; exit 2; }
for tool in sqlite3 jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not on PATH" >&2; exit 2; }
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || {
  echo "metrics script directory cannot be resolved" >&2
  exit 2
}
CONTRACT="$HERE/../rubrics/run-metadata-contract.json"
BLOCKED_REASON_PATTERN="$(jq -er '.blocked_reason_pattern | select(type == "string")' \
  "$CONTRACT" 2>/dev/null)" || {
  echo "blocked reason contract is unreadable at $CONTRACT" >&2
  exit 2
}
for d in $SINCE $UNTIL; do
  case "$d" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) echo "dates must be YYYY-MM-DD: got '$d'" >&2; exit 2;; esac
done

# [MEASURED, audit] Per-board databases live under <kanban home>/boards/<slug>/.
# The slug `default` is the exception: it is the top-level kanban.db. That same
# top-level file EXISTS for every other board too — as a stale, empty legacy
# artifact — so there is deliberately no fallback to it. A board we cannot find
# is an error, never a silent zero.
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
KANBAN_ROOT="${HERMES_KANBAN_HOME:-$HERMES_ROOT/kanban}"
if [ "$BOARD" = "default" ]; then DB="$HERMES_ROOT/kanban.db"
else DB="$KANBAN_ROOT/boards/$BOARD/kanban.db"; fi
[ -f "$DB" ] || { echo "no board database at $DB" >&2; exit 2; }

# ---------------------------------------------------------------------------
# The snapshot (audit F47, F67), delegated to the one primitive that does it.
# scripts/board-snapshot.sh copies the board and its durable sidecars into a
# private directory, fingerprints the source across the copy so a torn read is
# refused rather than reported, opens the copy read-write — which is what lets
# SQLite build the `-shm` that `mode=ro` on the live file could not be given —
# and prints a path it has already proved will open.
#
# The `[ -n "$SNAP" ]` guard is not belt-and-braces. It is F47's unrecorded
# second half asserted at the call site: a failed read that prints nothing and
# claims success is worse than a failed read, so an empty stdout from the
# snapshot is an error here even if its exit code were ever to lie.
# ---------------------------------------------------------------------------
SNAPDIR="$(mktemp -d "${TMPDIR:-/tmp}/forge-metrics-snap.XXXXXX")"
SQLF="$SNAPDIR/query.sql"
trap 'rm -rf "$SNAPDIR"' EXIT
SNAP="$("$HERE/board-snapshot.sh" "$DB" "$SNAPDIR/board")" || {
  echo "could not snapshot board $BOARD; refusing to report numbers from a board that was not read" >&2
  exit 2; }
[ -n "$SNAP" ] || { echo "snapshot of board $BOARD returned no path" >&2; exit 2; }

# Timestamps in this schema are true Unix epoch seconds (`int(time.time())` in
# hermes_cli/kanban_db.py; confirmed by the db file's mtime matching MAX(
# created_at) exactly on three boards). The trap is on the OTHER side: --since
# is a local calendar date, and bare strftime('%s','2026-07-29') resolves to
# UTC midnight, which is the wrong instant by the UTC offset. The 'utc'
# modifier reads the literal as local time and returns the real epoch for it,
# so a day boundary means the operator's midnight, not Greenwich's.
epoch_of() { sqlite3 :memory: "SELECT strftime('%s','$1'${2:+,'$2'},'utc');"; }
SINCE_E=0; UNTIL_E=99999999999
[ -n "$SINCE" ] && SINCE_E="$(epoch_of "$SINCE")"
[ -n "$UNTIL" ] && UNTIL_E="$(epoch_of "$UNTIL" '+1 day')"   # --until is inclusive

# Join the board's trusted worker_session_id to the state database belonging to
# that exact run profile. Profile state is a second live SQLite substrate, so it
# gets the same WAL-safe snapshot treatment as the board. A missing/unreadable
# state database degrades only this section: the board metrics remain useful and
# the affected run is explicitly unjudged instead of acquiring zero usage.
driver_usage_json() { # $1=base JSON carrying private _driver_runs
  local base_json="$1"
  local sessions_file="$SNAPDIR/driver-sessions.ndjson"
  local joins_file="$SNAPDIR/driver-joins.ndjson"
  local unjudged_file="$SNAPDIR/driver-unjudged.ndjson"
  local limitations_file="$SNAPDIR/driver-limitations.ndjson"
  local runs_file="$SNAPDIR/driver-runs.b64"
  local profile_root="$HERMES_ROOT/profiles"
  local encoded run_json profile session_id
  local state_dir state_source state_snap session_json state_error
  local joined unjudged eligible rate

  : > "$sessions_file"
  : > "$joins_file"
  : > "$unjudged_file"
  : > "$limitations_file"
  printf '%s' "$base_json" | jq -rc '._driver_runs[] | @base64' > "$runs_file"

  while IFS= read -r encoded; do
    [ -n "$encoded" ] || continue
    run_json="$(jq -cn --arg encoded "$encoded" '$encoded | @base64d | fromjson')"
    profile="$(printf '%s' "$run_json" | jq -r '.profile')"
    session_id="$(printf '%s' "$run_json" | jq -r '.worker_session_id // empty')"

    if [ -z "$session_id" ]; then
      printf '%s' "$run_json" | jq -c \
        '. + {reason:"missing-worker-session-id"}' >> "$unjudged_file"
      continue
    fi
    case "$session_id" in
      *[!A-Za-z0-9._:~-]*)
        printf '%s' "$run_json" | jq -c \
          '. + {reason:"invalid-worker-session-id"}' >> "$unjudged_file"
        continue;;
    esac
    case "$profile" in
      ""|.|..|*[!A-Za-z0-9._-]*)
        printf '%s' "$run_json" | jq -c \
          '. + {reason:"invalid-profile"}' >> "$unjudged_file"
        continue;;
    esac

    state_dir="$SNAPDIR/profile-states/$profile"
    state_source="$profile_root/$profile/state.db"
    mkdir -p "$state_dir"

    if [ -f "$state_dir/unavailable" ]; then
      printf '%s' "$run_json" | jq -c \
        '. + {reason:"profile-state-unavailable"}' >> "$unjudged_file"
      continue
    fi
    if [ -f "$state_dir/snapshot-path" ]; then
      state_snap="$(sed -n '1p' "$state_dir/snapshot-path")"
    else
      state_snap=""
      if [ -f "$state_source" ]; then
        state_snap="$("$HERE/board-snapshot.sh" "$state_source" "$state_dir/snapshot" \
                        2>"$state_dir/snapshot.err")" || state_snap=""
      fi
      if [ -z "$state_snap" ]; then
        printf '%s\n' "profile state unavailable: $profile" > "$state_dir/unavailable"
        jq -cn --arg message "profile state unavailable: $profile" '$message' \
          >> "$limitations_file"
        printf '%s' "$run_json" | jq -c \
          '. + {reason:"profile-state-unavailable"}' >> "$unjudged_file"
        continue
      fi
      printf '%s\n' "$state_snap" > "$state_dir/snapshot-path"
    fi

    # Coverage is a property of runs, while usage is a property of sessions.
    # Hermes may legitimately attach more than one completed run to the same
    # profile/session tuple (the live forge-ladder replay does). Once that
    # unique tuple has joined, preserve the additional run mapping without
    # querying or charging its session telemetry again.
    if jq -se --arg profile "$profile" --arg session "$session_id" \
         'any(.[]; .profile == $profile and .worker_session_id == $session)' \
         "$sessions_file" >/dev/null 2>&1; then
      printf '%s' "$run_json" | jq -c \
        '{run_id, task_id, profile, worker_session_id}' >> "$joins_file"
      continue
    fi

    # session_id is restricted above to a non-SQL metacharacter alphabet. The
    # run/task/profile context is added with jq rather than interpolated here.
    # Per-model actual cost has a NOT NULL DEFAULT 0 in Hermes 0.19, so it is
    # only exposed when cost_status says it is actual. Otherwise null preserves
    # the distinction between "not supplied" and a measured zero-dollar call.
    state_error="$state_dir/query.err"
    if ! session_json="$(sqlite3 "$state_snap" 2>"$state_error" "
      SELECT json_object(
        'source', s.source,
        'model', s.model,
        'provider', s.billing_provider,
        'api_calls', s.api_call_count,
        'input_tokens', s.input_tokens,
        'output_tokens', s.output_tokens,
        'cache_read_tokens', s.cache_read_tokens,
        'cache_write_tokens', s.cache_write_tokens,
        'reasoning_tokens', s.reasoning_tokens,
        'estimated_cost_usd', s.estimated_cost_usd,
        'actual_cost_usd', CASE
          WHEN lower(COALESCE(s.cost_status,'')) LIKE 'actual%'
            THEN s.actual_cost_usd ELSE NULL END,
        'cost_status', s.cost_status,
        'cost_source', s.cost_source,
        'models', json(COALESCE((
          SELECT json_group_array(json(model_json)) FROM (
            SELECT json_object(
              'model', u.model,
              'provider', u.billing_provider,
              'billing_base_url', u.billing_base_url,
              'billing_mode', u.billing_mode,
              'task', u.task,
              'api_calls', u.api_call_count,
              'input_tokens', u.input_tokens,
              'output_tokens', u.output_tokens,
              'cache_read_tokens', u.cache_read_tokens,
              'cache_write_tokens', u.cache_write_tokens,
              'reasoning_tokens', u.reasoning_tokens,
              'estimated_cost_usd', u.estimated_cost_usd,
              'actual_cost_usd', CASE
                WHEN lower(COALESCE(u.cost_status,'')) LIKE 'actual%'
                  THEN u.actual_cost_usd ELSE NULL END,
              'cost_status', u.cost_status,
              'cost_source', u.cost_source,
              'first_seen', u.first_seen,
              'last_seen', u.last_seen
            ) AS model_json
              FROM session_model_usage u
             WHERE u.session_id = s.id
             ORDER BY u.model, u.billing_provider, u.billing_base_url,
                      u.billing_mode, u.task
          )
        ), json_array()))
      )
        FROM sessions s
       WHERE s.id = '$session_id'
       LIMIT 1;")"; then
      printf '%s\n' "profile state unreadable: $profile" > "$state_dir/unavailable"
      jq -cn --arg message "profile state unreadable: $profile" '$message' \
        >> "$limitations_file"
      printf '%s' "$run_json" | jq -c \
        '. + {reason:"profile-state-unavailable"}' >> "$unjudged_file"
      continue
    fi

    if [ -z "$session_json" ]; then
      printf '%s' "$run_json" | jq -c '. + {reason:"session-not-found"}' \
        >> "$unjudged_file"
      continue
    fi
    printf '%s' "$run_json" | jq -c \
      '{run_id, task_id, profile, worker_session_id}' >> "$joins_file"
    printf '%s' "$session_json" | jq -c --argjson run "$run_json" \
      '{profile:$run.profile, worker_session_id:$run.worker_session_id} + .' \
      >> "$sessions_file"
  done < "$runs_file"

  joined="$(jq -s 'length' "$joins_file")"
  unjudged="$(jq -s 'length' "$unjudged_file")"
  eligible=$((joined + unjudged))
  if [ "$eligible" -eq 0 ]; then rate=""
  else rate="$(awk -v joined="$joined" -v eligible="$eligible" \
                    'BEGIN { printf "%.2f", joined / eligible }')"; fi

  jq -n \
    --slurpfile sessions "$sessions_file" \
    --slurpfile joins "$joins_file" \
    --slurpfile unjudged "$unjudged_file" \
    --slurpfile limitations "$limitations_file" \
    --arg rate "$rate" '
      ($joins | length) as $joined
      | ($unjudged | length) as $unjudged_count
      | ($joined + $unjudged_count) as $eligible
      | ($sessions | map(
          . as $session
          | . + {runs: ($joins | map(
              select(.profile == $session.profile
                     and .worker_session_id == $session.worker_session_id)
              | {run_id, task_id}) | sort_by(.run_id))}
        )) as $unique_sessions
      | {
          coverage: {
            eligible: $eligible,
            joined: $joined,
            unjudged: $unjudged_count,
            rate: (if $eligible == 0 then null else $rate end)
          },
          totals: {
            api_calls: ([$unique_sessions[].api_calls] | add // 0),
            input_tokens: ([$unique_sessions[].input_tokens] | add // 0),
            output_tokens: ([$unique_sessions[].output_tokens] | add // 0),
            cache_read_tokens: ([$unique_sessions[].cache_read_tokens] | add // 0),
            cache_write_tokens: ([$unique_sessions[].cache_write_tokens] | add // 0),
            reasoning_tokens: ([$unique_sessions[].reasoning_tokens] | add // 0)
          },
          cost: {
            estimated_usd: ([$unique_sessions[].estimated_cost_usd | select(. != null)]
                            | if length == 0 then null else add end),
            estimated_sessions: ([$unique_sessions[].estimated_cost_usd | select(. != null)] | length),
            actual_usd: ([$unique_sessions[].actual_cost_usd | select(. != null)]
                         | if length == 0 then null else add end),
            actual_sessions: ([$unique_sessions[].actual_cost_usd | select(. != null)] | length)
          },
          limitations: ($limitations | unique),
          unjudged: ($unjudged | sort_by(.run_id)),
          shared_attribution: ([$unique_sessions[]
            | select(.runs | length > 1)
            | {profile, worker_session_id,
               run_ids: [.runs[].run_id], task_ids: [.runs[].task_id]}]),
          sessions: ($unique_sessions | sort_by(.profile, .worker_session_id))
        }'
}

# The query is assembled into a file rather than a variable: macOS ships bash
# 3.2, whose parser mishandles a here-document nested inside `$(...)` and dies
# with "unexpected EOF" on a script that is in fact balanced.
printf '.param set :since %s\n.param set :until %s\n' "$SINCE_E" "$UNTIL_E" > "$SQLF"
cat >> "$SQLF" <<'SQL_BODY'
WITH
-- [MEASURED] Chunk cards are identified by CARD SHAPE, never by "carries a
-- chunk envelope". Identifying them by envelope would be circular: a card with
-- malformed metadata would drop out of the denominator, and the conformance
-- count below would silently miss exactly the nonconformance this script
-- exists to detect. So: a completed card that parents a forge-prejudge card,
-- or (fallback, for cards never reviewed) one with a forge-codex-lane run.
cc(id) AS (
  SELECT DISTINCT t.id FROM tasks t
    JOIN task_links l ON l.parent_id = t.id
    JOIN task_runs  r ON r.task_id   = l.child_id AND r.profile = 'forge-prejudge'
   WHERE t.status = 'done'
  UNION
  SELECT DISTINCT t.id FROM tasks t
    JOIN task_runs r ON r.task_id = t.id
   WHERE t.status = 'done' AND r.profile = 'forge-codex-lane'
),
-- [MEASURED] Tier comes from the PROFILE of the run carrying the verdict, not
-- from the card title. forge-prejudge is the unattended tier-1 filter; every
-- other profile, including the unassigned cards an operator drives by hand, is
-- tier 2. Only canonical forge.judge.v1 counts — that is the point of F3.
v AS (
  SELECT r.task_id,
         CASE WHEN r.profile = 'forge-prejudge' THEN 1 ELSE 2 END AS tier,
         json_extract(r.metadata,'$.verdict') AS verdict,
         (json_extract(r.metadata,'$.scores.spec_fidelity')
        + json_extract(r.metadata,'$.scores.scenario_integrity')
        + json_extract(r.metadata,'$.scores.architectural_conformance')) / 3.0 AS d13
    FROM task_runs r
   WHERE json_extract(r.metadata,'$.schema') = 'forge.judge.v1'
     AND r.started_at >= :since AND r.started_at < :until
),
-- A verdict lives on the review card; the bounce belongs to the chunk it
-- reviewed. That is usually the review card's parent, but at least one tier-2
-- card on forge-ladder hangs off the tier-1 card instead, so look two hops up.
va AS (
  SELECT v.*, COALESCE(
      (SELECT l.parent_id FROM task_links l
        WHERE l.child_id = v.task_id AND l.parent_id IN (SELECT id FROM cc)),
      (SELECT l2.parent_id FROM task_links l1
         JOIN task_links l2 ON l2.child_id = l1.parent_id
        WHERE l1.child_id = v.task_id AND l2.parent_id IN (SELECT id FROM cc))
    ) AS chunk_card
    FROM v
),
-- Rates and means are emitted as fixed 2-decimal STRINGS. docs/retro-metrics.md
-- requires "0.00 (0/1)", and a JSON number cannot carry a trailing zero, so a
-- bare 0.0 would reach the log as "0" — the one presentation the honesty rules
-- name. The counts beside them stay numeric, so the rate is recomputable.
-- printf('%.2f', NULL) returns '0.00', which would invent a value out of no
-- data; every use is guarded to keep an absent number absent.
tiers AS (
  SELECT tier,
         COUNT(*) AS verdicts,
         SUM(verdict = 'bounce') AS bounce_verdicts,
         CASE WHEN AVG(d13) IS NULL THEN NULL ELSE printf('%.2f', AVG(d13)) END AS mean_d13,
         COUNT(DISTINCT chunk_card) AS chunks_judged,
         COUNT(DISTINCT CASE WHEN verdict = 'bounce' THEN chunk_card END) AS chunks_bounced
    FROM va GROUP BY tier
),
-- Gate blocks are counted SEPARATELY from bounces, which is ADR-0009 D9.4.
-- Tier 1 has two stages and they leave two different envelopes. The gate emits
-- `forge.gate.v1` — a `result` and the ids of the checks that blocked, and no
-- scores, because a program forms no opinion to score. Its model stage still
-- emits `forge.judge.v1` and is still counted as tier 1 above.
--
-- A gate block costs zero model tokens and lands before any scorer is spawned;
-- a bounce costs a full review. Averaging them into one rate would hide the gap
-- between a filter and a judge — the same defect, from the other side, as the
-- single blended rate this file already refuses (F3). It would also make the
-- experiment ADR-0009 D9.5 sets up unreadable: if a gate block and a model
-- bounce are one number, no later period can show which stage did the filtering.
g AS (
  SELECT json_extract(r.metadata,'$.result') AS result, r.metadata AS md
    FROM task_runs r
   WHERE json_extract(r.metadata,'$.schema') = 'forge.gate.v1'
     AND r.started_at >= :since AND r.started_at < :until
),
-- Which check did the blocking. A gate whose blocks are all one check is a gate
-- with one useful check in it, and that is worth seeing before anyone concludes
-- the other six are earning their place.
gk AS (SELECT je.value AS id FROM g, json_each(g.md, '$.blocks') je),
-- [MEASURED] Read both envelope shapes, report the divergence, normalize
-- neither: detecting it is the deliverable (audit F1/F2). "neither" is a real,
-- reachable bucket, not a defensive else-branch.
env AS (
  SELECT CASE
           WHEN json_extract(r.metadata,'$.schema') = 'forge.chunk.v1'      THEN 'flat'
           WHEN json_extract(r.metadata,'$."forge.chunk.v1"') IS NOT NULL   THEN 'nested'
           ELSE 'neither' END AS shape
    FROM task_runs r JOIN cc ON cc.id = r.task_id
   WHERE r.outcome = 'completed'
     AND r.started_at >= :since AND r.started_at < :until
),
-- forge.block.v1 does not exist and never has: kanban_block takes no metadata
-- parameter, so nothing can carry it (audit F26). The class is whatever leading
-- `token:` the free-text reason happens to start with. Anything that is not a
-- bare lowercase slug — a sentence, a timestamp like "8:07" — is honestly
-- (unclassified) rather than quietly coerced into a bucket.
--
-- The whole reason is carried alongside the class, because `documented` is a
-- claim about the REASON and not about its first token: the class extraction
-- below only requires a slug before the first colon, so `env:no-space` classes
-- as `env` while the contract's pattern — and validate-metadata.py --reason,
-- which enforces it on the producer side — reject the string outright. Testing
-- a synthesised `class + ": reason"` would agree with the SQL by construction
-- and disagree with the validator in exactly that case. The reasons are used
-- for the test and then dropped: they are free text on a durable board and
-- have no business in a metrics document.
rc AS (
  SELECT CASE WHEN p > 1 AND substr(reason,1,p-1) NOT GLOB '*[^a-z0-9-]*'
              THEN substr(reason,1,p-1) ELSE '(unclassified)' END AS class,
         reason
    FROM (SELECT reason, instr(reason,':') AS p FROM
           (SELECT json_extract(payload,'$.reason') AS reason FROM task_events
             WHERE kind = 'blocked' AND created_at >= :since AND created_at < :until)
          WHERE reason IS NOT NULL)
),
-- Best effort, and the method is reported with the number because the board
-- cannot do better (audit F31): an author that never ran as a profile here is
-- taken to be a human, and `unblocked` events record no actor at all (payload
-- is NULL on every one), so they are counted as manual by construction.
ops AS (
  SELECT (SELECT COUNT(*) FROM task_comments
           WHERE author NOT IN (SELECT DISTINCT profile FROM task_runs WHERE profile IS NOT NULL)
             AND created_at >= :since AND created_at < :until) AS comments,
         (SELECT COUNT(*) FROM task_events WHERE kind = 'unblocked'
             AND created_at >= :since AND created_at < :until) AS unblocks
),
-- Candidate chunk runs for the second-substrate join. Keep this private list in
-- the base JSON until shell code snapshots the exact profile state databases.
-- Only completed, profiled runs are eligible: operator rows have no driver, and
-- unfinished workers have no completed telemetry to judge.
du AS (
  SELECT r.id AS run_id, r.task_id, r.profile,
         CASE WHEN json_type(r.metadata,'$.worker_session_id') = 'text'
                    AND trim(json_extract(r.metadata,'$.worker_session_id')) <> ''
              THEN json_extract(r.metadata,'$.worker_session_id') ELSE NULL END
           AS worker_session_id
    FROM task_runs r JOIN cc ON cc.id = r.task_id
   WHERE r.outcome = 'completed' AND r.profile IS NOT NULL
     AND r.started_at >= :since AND r.started_at < :until
)
SELECT json_object(
  'board', NULL, 'since', NULL, 'until', NULL,
  'chunk_cards', (SELECT COUNT(*) FROM cc),
  'verdicts', json_object(
     'total', (SELECT COUNT(*) FROM va),
     'unattributed', (SELECT COUNT(*) FROM va WHERE chunk_card IS NULL),
     'by_verdict', (SELECT json_group_object(COALESCE(verdict,'(null)'), n) FROM
                     (SELECT verdict, COUNT(*) n FROM va GROUP BY verdict ORDER BY verdict))),
  'tiers', (SELECT json_group_array(json_object(
              'tier', tier, 'verdicts', verdicts, 'bounce_verdicts', bounce_verdicts,
              'mean_d13', mean_d13, 'chunks_judged', chunks_judged,
              'chunks_bounced', chunks_bounced,
              'bounce_rate', CASE WHEN chunks_judged = 0 THEN NULL
                             ELSE printf('%.2f', 1.0 * chunks_bounced / chunks_judged) END))
            FROM (SELECT * FROM tiers ORDER BY tier)),
  'mean_d13_all', (SELECT CASE WHEN AVG(d13) IS NULL THEN NULL
                          ELSE printf('%.2f', AVG(d13)) END FROM va),
  'gate', (SELECT json_object(
             'runs',    (SELECT COUNT(*) FROM g),
             'blocked', (SELECT COUNT(*) FROM g WHERE result = 'block'),
             'clear',   (SELECT COUNT(*) FROM g WHERE result = 'clear'),
             'block_rate', (SELECT CASE WHEN COUNT(*) = 0 THEN NULL
                            ELSE printf('%.2f', 1.0 * SUM(result = 'block') / COUNT(*)) END FROM g),
             'by_check', (SELECT COALESCE(json_group_object(id, n), json_object())
                          FROM (SELECT id, COUNT(*) n FROM gk GROUP BY id ORDER BY n DESC, id)))),
  'reason_class', (SELECT json_group_array(json_object('class', class, 'count', n,
                                                       'reasons', json(rs)))
                   FROM (SELECT class, COUNT(*) n, json_group_array(reason) rs
                           FROM rc GROUP BY class ORDER BY n DESC, class)),
  -- Counted, not asserted. F26 claims this envelope has never been emitted;
  -- the claim now has a number attached to it on every run.
  'forge_block_v1', (SELECT COUNT(*) FROM task_runs
                      WHERE json_extract(metadata,'$.schema') = 'forge.block.v1'
                        AND started_at >= :since AND started_at < :until),
  'envelope', (SELECT json_object('flat', SUM(shape='flat'), 'nested', SUM(shape='nested'),
                 'neither', SUM(shape='neither'), 'total', COUNT(*)) FROM env),
  '_driver_runs', (SELECT COALESCE(json_group_array(json_object(
                    'run_id', run_id, 'task_id', task_id, 'profile', profile,
                    'worker_session_id', worker_session_id)), json_array())
                   FROM (SELECT * FROM du ORDER BY run_id)),
  'operator', (SELECT json_object('comments', comments, 'unblocks', unblocks,
                 'touches', comments + unblocks,
                 'method', 'comments by an author that never ran as a profile on this board, '
                        || 'plus every unblocked event (the event records no actor)') FROM ops)
);
SQL_BODY

# The exit code, not the emptiness of the output. sqlite3 prints `Error: ...`
# on STDOUT, so the old `[ -n "$JSON" ]` guard was satisfied by the error text
# itself: on the F47 failure this script printed a blank line and exited 0. A
# broken read reported as success is worse than the read being broken.
JSON="$(sqlite3 "$SNAP" < "$SQLF")"; rc=$?
[ "$rc" = 0 ] || { printf 'querying %s failed (sqlite3 exit %s): %s\n' "$BOARD" "$rc" "$JSON" >&2; exit 2; }
[ -n "$JSON" ] || { echo "query produced no output for $DB" >&2; exit 2; }
printf '%s' "$JSON" | jq -e . >/dev/null 2>&1 \
  || { printf 'querying %s produced non-JSON: %s\n' "$BOARD" "$JSON" >&2; exit 2; }
JSON="$(printf '%s' "$JSON" | jq \
  --arg b "$BOARD" --arg s "${SINCE:-}" --arg u "${UNTIL:-}" \
  --arg reason_pattern "$BLOCKED_REASON_PATTERN" '
    .board=$b
    | .since=(if $s=="" then null else $s end)
    | .until=(if $u=="" then null else $u end)
    | .reason_class |= map({
        class, count,
        documented: ([.reasons[] | test($reason_pattern)] | all)
      })')"
DRIVER_JSON="$(driver_usage_json "$JSON")" || {
  echo "driver usage assembly failed for board $BOARD" >&2
  exit 2
}
JSON="$(printf '%s' "$JSON" | jq --argjson driver "$DRIVER_JSON" '
  . as $base
  | del(._driver_runs, .operator)
  + {driver_usage: $driver, operator: $base.operator}')"

render() { printf '%s' "$1" | jq -r "$2"; }

case "$FORMAT" in
json) printf '%s\n' "$JSON";;

markdown-row)
  # Generated, never hand-written: the honesty rules in docs/retro-metrics.md
  # require denominators rather than percentages, and n/a with a reason rather
  # than a backfill. Both are properties of this formatter, not of a good mood.
  render "$JSON" '
    def tierof(n): ([.tiers[] | select(.tier == n)] | first);
    def br(n): (tierof(n)
                | if . == null then "t\(n) n/a — 0 verdicts in period"
                  elif .bounce_rate == null then "t\(n) n/a — no verdict reached a chunk card"
                  else "t\(n) \(.bounce_rate) (\(.chunks_bounced)/\(.chunks_judged))" end);
    def period: (if .since == null and .until == null then "board lifetime"
                 else "\(.since // "board start")..\(.until // "now")" end);
    # The gate number is FIRST and separately labelled. It is not a bounce rate
    # and must never be averaged into one: it is free, it lands before a
    # reviewer exists, and a period where it rises while t2 falls is the whole
    # point of the change that produced it (ADR-0009).
    def gate: (if .gate.runs == 0 then "gate n/a — 0 gate runs in period"
               else "gate \(.gate.block_rate) (\(.gate.blocked)/\(.gate.runs))" end);
    def driver:
      if .driver_usage.coverage.eligible == 0 then "driver n/a — 0 eligible runs"
      else "driver \(.driver_usage.coverage.rate) (\(.driver_usage.coverage.joined)/\(.driver_usage.coverage.eligible))"
        + " · estimated "
        + (if .driver_usage.cost.estimated_usd == null then "n/a"
           else "$\(.driver_usage.cost.estimated_usd)" end)
        + " · actual "
        + (if .driver_usage.cost.actual_usd == null then "n/a"
           else "$\(.driver_usage.cost.actual_usd)" end)
      end;
    "| " + ([ (now | strflocaltime("%Y-%m-%d")),
              "\(.board), \(period)",
              "\(gate) · \(br(1)) · \(br(2))",
              (if .mean_d13_all == null then "n/a — 0 canonical verdicts in period"
               else "\(.mean_d13_all) (\(.verdicts.total) verdicts)" end),
              (if (.reason_class | length) == 0 then "empty (0 blocked cards)"
               else ([.reason_class[] | "`\(.class)` ×\(.count)"] | join(", ")) end),
              (.operator.touches | tostring),
              driver,
              "—", "—" ] | join(" | ")) + " |"';;

text)
  render "$JSON" '
    "forge metrics — board \(.board)   period \(.since // "(board start)") .. \(.until // "(now)")",
    "",
    "tier-1 gate — stage 1, a program (ADR-0009); blocks cost zero model tokens and are NOT bounces",
    (if .gate.runs == 0 then "  no forge.gate.v1 results in period"
     else "  block rate  \(.gate.block_rate) (\(.gate.blocked)/\(.gate.runs) gate runs)"
          + "\n  by check    " + ([.gate.by_check | to_entries[] | "\(.key) ×\(.value)"]
                                  | if length == 0 then "nothing blocked" else join(" · ") end) end),
    "",
    "bounce rate — a chunk counts as bounced if ANY verdict against it bounced",
    (if (.tiers | length) == 0 then "  no canonical forge.judge.v1 verdicts in period"
     else ([.tiers[] | "  tier \(.tier)  \(.bounce_rate // "n/a") (\(.chunks_bounced)/\(.chunks_judged) chunk cards)"
                       + "   from \(.bounce_verdicts)/\(.verdicts) verdicts"
                       + (if .tier == 1 then "   [model stage only; gate blocks are the number above]" else "" end)]
           | join("\n")) end),
    "",
    "mean judge score, dimensions 1–3 (range 0–3)",
    (if (.tiers | length) == 0 then empty
     else ([.tiers[] | "  tier \(.tier)  \(.mean_d13) over \(.verdicts) verdicts"] | join("\n")) end),
    "  all     \(.mean_d13_all // "n/a") over \(.verdicts.total) verdicts"
      + (if .verdicts.unattributed > 0
         then "   (\(.verdicts.unattributed) not attributable to a chunk card)" else "" end),
    "  verdicts: " + ([.verdicts.by_verdict | to_entries[] | "\(.key) \(.value)"]
                      | if length == 0 then "none" else join(" · ") end),
    "",
    "reason class distribution — leading token of the blocked reason; legacy forge.block.v1 envelopes observed: \(.forge_block_v1)",
    (if (.reason_class | length) == 0 then "  empty (0 blocked cards)"
     else ([.reason_class[]
            | "  \(.class) ×\(.count)"
              + (if .documented then "" else "   (not in the documented vocabulary)" end)]
           | join("\n")) end),
    "",
    "chunk envelope conformance — \(.envelope.total) completed chunk runs in period, \(.chunk_cards) chunk cards on the board",
    "  flat, $.schema == \"forge.chunk.v1\"      \(.envelope.flat // 0)   <- the documented shape",
    "  nested under $.\"forge.chunk.v1\"         \(.envelope.nested // 0)",
    "  neither                                  \(.envelope.neither // 0)",
    "",
    "driver usage — completed chunk runs joined \(.driver_usage.coverage.joined)/\(.driver_usage.coverage.eligible) (\(.driver_usage.coverage.rate // "n/a")); \(.driver_usage.coverage.unjudged) unjudged; \(.driver_usage.sessions | length) unique session(s)",
    "  calls \(.driver_usage.totals.api_calls) · input \(.driver_usage.totals.input_tokens) · output \(.driver_usage.totals.output_tokens) · cache read \(.driver_usage.totals.cache_read_tokens) · cache write \(.driver_usage.totals.cache_write_tokens) · reasoning \(.driver_usage.totals.reasoning_tokens)",
    "  estimated cost " + (if .driver_usage.cost.estimated_usd == null then "n/a"
                            else "$\(.driver_usage.cost.estimated_usd) across \(.driver_usage.cost.estimated_sessions) joined session(s)" end),
    "  actual cost    " + (if .driver_usage.cost.actual_usd == null then "n/a — not reported"
                            else "$\(.driver_usage.cost.actual_usd) across \(.driver_usage.cost.actual_sessions) joined session(s)" end),
    (if (.driver_usage.limitations | length) == 0 then empty
     else ([.driver_usage.limitations[] | "  limitation: \(.)"] | join("\n")) end),
    (if (.driver_usage.sessions | length) == 0 then empty
     else ([.driver_usage.sessions[]
            | "  session \(.profile)/\(.worker_session_id), runs "
              + ([.runs[].run_id | tostring] | join(","))
              + ": \(.model) via \(.provider // "unknown") · \(.cost_status // "cost status missing") · \(.models | length) model row(s)"]
           | join("\n")) end),
    "",
    "operator touches — \(.operator.touches) = \(.operator.comments) comments + \(.operator.unblocks) unblocks",
    "  method: \(.operator.method)"';;
esac
