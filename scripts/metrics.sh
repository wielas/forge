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

BOARD=""; SINCE=""; UNTIL=""; FORMAT="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:?--since needs YYYY-MM-DD}"; shift 2;;
    --until) UNTIL="${2:?--until needs YYYY-MM-DD}"; shift 2;;
    --json) FORMAT="json"; shift;;
    --markdown-row) FORMAT="markdown-row"; shift;;
    -h|--help) sed -n '2,27p' "$0"; exit 0;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) [ -z "$BOARD" ] || { echo "only one board slug: got '$BOARD' and '$1'" >&2; exit 2; }
       BOARD="$1"; shift;;
  esac
done
[ -n "$BOARD" ] || { sed -n '17,25p' "$0"; exit 2; }
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
# The snapshot (audit F47). Copy the board and its durable sidecars to a
# private directory, then query the copy.
#
# `-shm` is deliberately NOT among them, and that is not an omission. `-shm` is
# the WAL index: shared memory scratch, rebuildable from `-wal`, and rewritten
# constantly by every attached reader. Copying it risks handing SQLite a torn
# index, and fingerprinting it would make the consistency check fail against a
# live board for no reason. SQLite rebuilds it in the private copy — which is
# precisely the thing `mode=ro` on the live file could not do, and the whole
# bug. `forgeboard-report`'s hermes.py excludes it for the same reason.
#
# The copy is opened READ-WRITE, on purpose: WAL recovery must be able to
# create `-shm` and checkpoint. Nothing that happens to a copy in $TMPDIR can
# reach the board, and metrics/is-read-only proves the original's bytes.
# ---------------------------------------------------------------------------
SNAPDIR="$(mktemp -d "${TMPDIR:-/tmp}/forge-metrics-snap.XXXXXX")"
SQLF="$SNAPDIR/query.sql"
trap 'rm -rf "$SNAPDIR"' EXIT
SNAP="$SNAPDIR/$(basename "$DB")"

# Membership AND bytes: a sidecar that appears or vanishes mid-copy is as much
# a change as one whose contents move, and only the second kind shows up in a
# hash of the files we happened to find first.
fingerprint() {
  local f
  for f in "$DB" "$DB-wal" "$DB-journal"; do
    [ -f "$f" ] && printf '%s %s\n' "${f##*/}" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
  done
  return 0
}

# Three attempts, then an error. A board written faster than it can be copied is
# a real condition and must be reported, never silently reported stale.
attempt=1
while : ; do
  before="$(fingerprint)"
  rm -f "$SNAPDIR"/kanban.db*
  copied=0
  for f in "$DB" "$DB-wal" "$DB-journal"; do
    [ -f "$f" ] || continue
    cp "$f" "$SNAPDIR/${f##*/}" 2>/dev/null || { copied=1; break; }
  done
  [ "$copied" = 0 ] && [ "$before" = "$(fingerprint)" ] && break
  attempt=$((attempt+1))
  [ "$attempt" -le 3 ] || {
    echo "board $BOARD changed under every one of 3 snapshot attempts; refusing to report a torn read" >&2
    exit 2; }
done
[ -f "$SNAP" ] || { echo "could not snapshot $DB" >&2; exit 2; }

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
    "| " + ([ (now | strflocaltime("%Y-%m-%d")),
              "\(.board), \(period)",
              "\(gate) · \(br(1)) · \(br(2))",
              (if .mean_d13_all == null then "n/a — 0 canonical verdicts in period"
               else "\(.mean_d13_all) (\(.verdicts.total) verdicts)" end),
              (if (.reason_class | length) == 0 then "empty (0 blocked cards)"
               else ([.reason_class[] | "`\(.class)` ×\(.count)"] | join(", ")) end),
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
    "operator touches — \(.operator.touches) = \(.operator.comments) comments + \(.operator.unblocks) unblocks",
    "  method: \(.operator.method)"';;
esac
