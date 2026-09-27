#!/usr/bin/env bash
# =============================================================================
# forge roadmap-check — the sizing rules, executed at PLAN time (audit F53).
#
# `scripts/prejudge.sh` already measures a chunk against the roadmap skill's own
# sizing contract. It measures it on a PULL REQUEST, and the backtest is what
# produced this script: `size-budget` fires on 11 of 11 PRs of the only real
# run, mean 4.0x over, worst 9.3x. Every one of those findings is correct and
# every one of them arrives after a model has been spawned, a branch cut, a diff
# written and a review paid for. F53's ruling, verbatim: those are **planning
# defects being surfaced at review time**, and review time is the most expensive
# place to learn that a planner wrote a 3,700-line chunk.
#
# So this reads the plan, before `hermes/board-bootstrap.sh` creates a card and
# before any model is spawned. It is the same rules against the same numbers at
# the one moment the contract is still free to edit.
#
# WHAT IT DOES NOT DO, deliberately:
#   - It does not predict a chunk's final line count. Nothing can. It counts the
#     things the contract states about itself, which is what the roadmap skill's
#     sizing rule is actually written in terms of.
#   - It does not duplicate `hermes/board-bootstrap.sh`. That script proves
#     acyclicity by construction (no-progress in its create loop), id-to-file
#     correspondence, and parent readback — all of it AFTER opening a board and
#     creating real cards. This runs earlier, offline, with no board.
#
# SEVERITY: every check WARNS. This is F53's other half and it is not timidity —
# turned on as blocking on day one, `size-budget` would have stopped the audited
# project at PR #2 and never let it resume, because nothing in that run's
# methodology produced a 400-line chunk. A gate that blocks everything is not a
# filter either. The procedure ADR-0012 records: ship warning, run it against a
# real roadmap, fix the PLAN until it passes, then flip to blocking as a recorded
# decision. The map below is the one line each flip edits.
#
#   bijection     warn   graph ids and docs/chunks/*.md are 1:1
#   acyclic       warn   depends_on has no cycle
#   single-root   warn   exactly one chunk with no parents (Track E --root-only)
#   reachable     warn   diagnostic evidence naming what that root can reach
#   fields        warn   the roadmap template's fields are all present, by name
#   serves        warn   <= 4 requirements per chunk (F11)
#   touches       warn   <= 6 DECLARABLE paths per chunk (F55 exemption applies)
#   scenarios     warn   <= 5 scenarios, one Given/When/Then each (F11)
#   lane          warn   claude-interactive, or a real Hermes assignee
#   gates         warn   one GATE-<milestone> node per milestone, closing exactly
#                        its chunks, gating the next milestone (epic MS1)
#   tier          warn   every chunk has a tier an implementer exists for (PL3)
#   budget        warn   the plan fits the scope's complexity budget (PL1)
#   estimate      warn   the gates carry the feasibility ledger's estimate (PL2/PL3)
#   spec-budget   warn   each contract and the ROADMAP.md index within budget (PL3)
#
# THE THRESHOLDS ARE THE ROADMAP SKILL'S OWN NUMBERS and are not tunable here.
# `skills/roadmap/SKILL.md` says "<= ~400 lines changed, <= ~6 files, <= 5 BDD
# scenarios"; F11's fix says "make /roadmap split any chunk whose Serves: list
# exceeds ~4 requirements". Moving one after seeing data is the single response
# F53 forbids, because it converts a failed plan into a passing one without
# changing the plan.
#
# Usage:
#   ./scripts/roadmap-check.sh <project-dir>       # or: make roadmap-check PROJECT=<abs-path>
#   ./scripts/roadmap-check.sh <project-dir> -v    # also print every passing check's evidence
#
# Environment:
#   FORGE_ASSIGNEES   space/newline separated assignee names, used INSTEAD of
#                     `hermes kanban assignees`. Set it to run offline; without
#                     hermes and without it, `lane` SKIPS rather than passes.
#
# Exit: 0 the plan was read (warnings do not gate — see SEVERITY above),
#       2 the check could not run at all: no project, no docs/chunks/graph.json,
#       no jq. 0 and 2 are deliberately different, exactly as in prejudge.sh: a
#       finding is a statement about the plan, a 2 is a fact about the substrate.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# ONE definition of the F55 exemption, shared with review time. See the header
# of the sourced file for why a second copy is a defect and not a convenience.
#
# GUARDED, for the reason this whole script exists. Unguarded, a missing file
# left `TOUCHES_EXEMPT` unbound; `set -u` then killed the `$( )` SUBSHELL that
# counts paths — only the subshell — so `touches()` fell through to
# `emit touches pass` and the run printed `CLEAR — 9 pass, 0 warn` at exit 0.
# That is this file's headline defect happening inside this file: a PASS for a
# check that could not run. `prejudge.sh` guards the same source, and it must.
# shellcheck source=./touches-exempt.sh
TOUCHES_EXEMPT_FILE="$HERE/touches-exempt.sh"
[ -f "$TOUCHES_EXEMPT_FILE" ] || {
  echo "roadmap-check: missing $TOUCHES_EXEMPT_FILE — the Touches exemption has one definition and this is it" >&2
  exit 2; }
. "$TOUCHES_EXEMPT_FILE"
[ -n "${TOUCHES_EXEMPT:-}" ] || {
  echo "roadmap-check: $TOUCHES_EXEMPT_FILE did not define TOUCHES_EXEMPT" >&2
  exit 2; }

PROJECT=""; VERBOSE=0
helptext() { awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; }
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift;;
    -h|--help) helptext; exit 0;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) [ -z "$PROJECT" ] || { echo "only one project: got '$PROJECT' and '$1'" >&2; exit 2; }
       PROJECT="$1"; shift;;
  esac
done
[ -n "$PROJECT" ] || { usagetext; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is not on PATH" >&2; exit 2; }
[ -d "$PROJECT" ] || { echo "no such project directory: $PROJECT" >&2; exit 2; }

GRAPH="$PROJECT/docs/chunks/graph.json"
CHUNKDIR="$PROJECT/docs/chunks"
[ -f "$GRAPH" ] || {
  echo "no $GRAPH — run /roadmap first (it emits the chunk specs AND the graph)" >&2
  exit 2
}
jq -e 'type == "array" and length > 0' "$GRAPH" >/dev/null 2>&1 || {
  echo "FATAL: $GRAPH is not a non-empty JSON array" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 0. THE SHAPE OF EACH ENTRY, before any graph algorithm reads one.
#
# `type == "array" and length > 0` was the whole of the validation, and every
# check below assumed far more than that. Two measured consequences, both of
# them a PASS printed over a broken plan:
#
#   A numeric `id` makes the Kahn/reachability jq program die with `Cannot use
#   number (7) as object key`. The error goes to stderr, `GRAPHFACTS` is left
#   EMPTY and unchecked, and `acyclic` and `reachable` then read an empty fact
#   string as "no cycle" and "nothing unreachable". A graph with a genuine
#   three-node cycle reported `PASS acyclic` / `PASS reachable` and exit 0. A
#   cycle is a plan that can never start; reporting it clear is strictly worse
#   than crashing.
#
#   An id containing a space is word-split by every `for id in $IDS` loop, so
#   `CHUNK 1` becomes `CHUNK` and `1`, neither of which has a file. All five
#   content checks `continue` past it and each reports PASS. A chunk serving 40
#   requirements with 30 scenarios is never sized, and nothing says so.
#
# So an id must be a non-empty, unique, filename-safe string — it becomes
# `docs/chunks/<id>.md` and a shell word — and this exits 2, the substrate code,
# because a plan that cannot be parsed has not been checked. That is the same
# distinction prejudge.sh draws: a warning is a statement about the plan, a 2 is
# a fact about whether the check could run at all.
# ---------------------------------------------------------------------------
SCHEMA_ERRORS="$(jq -r '
  def entryerr($i; $e):
    if ($e | type) != "object" then
      "entry \($i) is a \($e | type), not an object"
    elif ($e | has("id") | not) then
      "entry \($i) has no \"id\""
    elif ($e.id | type) != "string" then
      "entry \($i): id \($e.id | tojson) is a \($e.id | type), not a string"
    elif ($e.id | length) == 0 then
      "entry \($i): id is empty"
    elif ($e.id | test("[[:space:]/]")) then
      "entry \($i): id \($e.id | tojson) contains a space or a slash — it becomes docs/chunks/<id>.md and a shell word"
    elif ($e.id == "." or $e.id == "..") then
      "entry \($i): id \($e.id | tojson) is not a chunk name"
    # `null` and an ABSENT key are the same thing to every consumer below —
    # `(.lane // "")` and `(.depends_on // [])` — so rejecting one while warning
    # about the other is the validator disagreeing with the script it guards.
    # `json.dump` of a dict holding None is the obvious way to produce it.
    elif ($e.lane != null) and ($e.lane | type) != "string" then
      "\($e.id): lane \($e.lane | tojson) is a \($e.lane | type), not a string"
    elif ($e.tier != null) and ($e.tier | type) != "string" then
      "\($e.id): tier \($e.tier | tojson) is a \($e.tier | type), not a string"
    elif ($e.depends_on != null) and ($e.depends_on | type) != "array" then
      "\($e.id): depends_on \($e.depends_on | tojson) is a \($e.depends_on | type), not an array"
    elif ($e.depends_on != null) and ([$e.depends_on[] | select(type != "string")] | length) > 0 then
      "\($e.id): depends_on contains a non-string: \([$e.depends_on[] | select(type != "string")] | tojson)"
    else empty end;
  [ (to_entries[] | entryerr(.key; .value)),
    ( [.[] | select(type == "object" and (.id | type) == "string") | .id]
      | group_by(.) | map(select(length > 1) | .[0])
      | .[] | "duplicate id \(. | tojson): the lane lookup returns two records and the display loop reads the second as a status" )
  ] | .[]' "$GRAPH" 2>&1)"

[ -z "$SCHEMA_ERRORS" ] || {
  echo "FATAL: $GRAPH does not describe a checkable plan:" >&2
  printf '%s\n' "$SCHEMA_ERRORS" | sed 's/^/  - /' >&2
  echo "Nothing below this point can be trusted about that graph, so no check has run." >&2
  exit 2
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forge-roadmap.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.tsv"; : > "$RESULTS"

# Same contract as prejudge's `emit`, for the same reason: the fourth field is
# an ACTION, and a finding a planner cannot execute is not a finding. `skip` is
# a real outcome and stays distinguishable from `pass` — a check that could not
# run has not passed (F5).
emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$RESULTS"; }

# A GATE-<milestone> node is a milestone gate (epic MS1), not a chunk: it has no
# feature, no Touches and no scenarios, and the implementer lane never runs it.
# Every chunk-content check below reads IDS, which is chunks only; the checks
# about the graph as a whole — bijection, the lane — read ALL_IDS.
ALL_IDS="$(jq -r '.[].id' "$GRAPH")"
IDS="$(printf '%s\n' "$ALL_IDS" | grep -v '^GATE-' || true)"
GATE_IDS="$(printf '%s\n' "$ALL_IDS" | grep '^GATE-' || true)"
LANE_IMPLEMENTER="${FORGE_LANE_ASSIGNEE:-forge-codex-lane}"

# ---------------------------------------------------------------------------
# 1. graph ids <-> docs/chunks/*.md, bijective. board-bootstrap.sh checks the
# forward half (`$GRAPH names $id but $f does not exist`) at card-create time.
# The reverse half it cannot check at all: a chunk file the graph forgot is
# simply never created, and the plan silently ships one chunk short.
# ---------------------------------------------------------------------------
bijection() {
  local files missing orphan dangling
  files="$(ls -1 "$CHUNKDIR" 2>/dev/null | sed -n 's/\.md$//p' | sort)"
  missing="$(comm -23 <(printf '%s\n' "$ALL_IDS" | sort) <(printf '%s\n' "$files"))"
  orphan="$(comm -13 <(printf '%s\n' "$ALL_IDS" | sort) <(printf '%s\n' "$files"))"
  dangling="$(jq -r --argjson ids "$(printf '%s\n' "$ALL_IDS" | jq -R . | jq -s .)" \
      '.[] | .id as $c | (.depends_on // [])[] | select(. as $d | $ids | index($d) | not)
       | "\($c) -> \(.)"' "$GRAPH" | sort -u)"
  local n=0 detail=""
  [ -n "$missing" ] && { detail="$detail; ids with no file: $(printf '%s' "$missing" | tr '\n' ' ')"; n=$((n+1)); }
  [ -n "$orphan" ] && { detail="$detail; files with no id: $(printf '%s' "$orphan" | tr '\n' ' ')"; n=$((n+1)); }
  [ -n "$dangling" ] && { detail="$detail; depends_on names an unknown id: $(printf '%s' "$dangling" | tr '\n' ' ')"; n=$((n+1)); }
  if [ "$n" = 0 ]; then
    emit bijection pass "$(printf '%s\n' "$ALL_IDS" | grep -c .) id(s), each with exactly one docs/chunks/<id>.md"
  else
    emit bijection warn "graph.json and docs/chunks/ disagree${detail}" \
      "make the two sets equal: add the missing docs/chunks/<id>.md files, add the orphan files to graph.json, and correct any depends_on entry naming an id the graph does not define — board-bootstrap.sh exits 1 on the first of these it reaches, after it has already created cards"
  fi
}

# ---------------------------------------------------------------------------
# 2/3/4. Acyclic, exactly one root, everything reachable from it.
#
# board-bootstrap.sh finds a cycle by making no progress through its create
# loop — correct, and it happens with cards already on a board. Kahn's algorithm
# here costs nothing and names the chunks involved.
#
# The single-root property is not decoration. Track E's staged
# `board-bootstrap.sh --root-only` creates the root card and nothing else; with
# two roots it creates one of them and the operator cannot tell which.
# ---------------------------------------------------------------------------
GRAPHJQ='
  def kahn:
    . as $dep
    | {dep: $dep, order: []}
    | until( (.dep | length) == 0
             or ([.dep | to_entries[] | select(.value | length == 0) | .key] | length) == 0;
             ([.dep | to_entries[] | select(.value | length == 0) | .key] | sort) as $ready
             | .order += $ready
             | .dep |= (delpaths([$ready[] | [.]]) | map_values(. - $ready)) );
  ([.[] | {key: .id, value: ((.depends_on // []) | unique)}] | from_entries) as $dep
  | ($dep | kahn) as $k
  | [$dep | to_entries[] | select(.value | length == 0) | .key] as $roots
  | ( if ($roots | length) == 1
      then ( {seen: $roots, frontier: $roots}
             | until(.frontier | length == 0;
                     ( [ .frontier[] as $f
                         | $dep | to_entries[] | select(.value | index($f)) | .key ] | unique) as $next
                     | ($next - .seen) as $new
                     | {seen: ((.seen + $new) | unique), frontier: $new})
             | .seen )
      else null end ) as $reach
  | { cyclic: ($k.dep | keys | sort),
      roots: ($roots | sort),
      total: ($dep | length),
      unreachable: (if $reach == null then null else (($dep | keys) - $reach | sort) end) }'

# Guarded, and checked for emptiness. This assignment was bare, `set -e` is not
# in force, and every consumer below treated an empty result as good news.
# Schema validation above should make failure unreachable — which is exactly why
# a failure here means something is wrong that nobody has understood yet, and
# the one response that must not happen is nine PASS lines.
GRAPHFACTS="$(jq -c "$GRAPHJQ" "$GRAPH" 2>"$TMP/graph.err")" || {
  echo "FATAL: could not compute the dependency graph from $GRAPH:" >&2
  sed 's/^/  /' "$TMP/graph.err" >&2
  exit 2
}
[ -n "$GRAPHFACTS" ] || {
  echo "FATAL: the dependency graph computed from $GRAPH is empty; refusing to report an unchecked plan as clear" >&2
  exit 2
}
gfact() { printf '%s' "$GRAPHFACTS" | jq -r "$1"; }

acyclic() {
  local cyc; cyc="$(gfact '.cyclic | join(" ")')"
  if [ -z "$cyc" ]; then
    emit acyclic pass "$(gfact .total) chunk(s) topologically ordered; no cycle"
  else
    emit acyclic warn "depends_on has a cycle through: $cyc" \
      "break the cycle by deciding which of these chunks genuinely needs the other's merged output and deleting the other edge — ADR-0008 says a dependent lane waits for its parent PR to merge, so a cycle is a plan that can never start"
  fi
}

single_root() {
  local roots n; roots="$(gfact '.roots | join(" ")')"; n="$(gfact '.roots | length')"
  if [ "$n" = 1 ]; then
    emit single-root pass "one root: $roots"
  elif [ "$n" = 0 ]; then
    emit single-root warn "no chunk has an empty depends_on — every chunk waits on another" \
      "give exactly one chunk 'depends_on': [] so there is somewhere to start; with no root the dispatcher promotes nothing and the board sits in todo forever"
  else
    emit single-root warn "$n roots: $roots — the plan has $n independent starting points" \
      "pick the one chunk that must land first and make every other root depend on it. board-bootstrap.sh --root-only (Track E) creates THE root card; with $n it creates one of them and does not say which"
  fi
}

reachable() {
  local un
  un="$(gfact 'if .unreachable == null then "SKIP" else (.unreachable | join(" ")) end')"
  if [ "$un" = "SKIP" ]; then
    # Not a pass. In a finite DAG every node has a path back to some source, so
    # with exactly one root and no cycle this check cannot fail — it earns its
    # place by NAMING the stranded chunks when one of the other two has already
    # fired, not by detecting anything they do not.
    emit reachable skip "root count is not 1, so there is no single root to reach from — see single-root"
  elif [ -z "$un" ]; then
    emit reachable pass \
      "diagnostic evidence only — all $(gfact .total) chunk(s) reachable from $(gfact '.roots|join(" ")'); acyclic and single-root are the detectors"
  else
    emit reachable warn "unreachable from the root: $un" \
      "these chunks can never be promoted: nothing that reaches them is ever done. Give each one a depends_on path back to the root, or delete it from the plan"
  fi
}

# ---------------------------------------------------------------------------
# 5. Every field of the roadmap skill's contract template is present, BY NAME.
#
# A missing field is not a style nit: `hermes/board-bootstrap.sh` pastes the
# whole file into the card body and a fresh-context worker reads only that. The
# roadmap skill's own rule is "everything the implementer needs is IN the chunk
# spec"; a contract with no `Out of scope:` is a contract that cannot be held to
# one, and it is the F6 bounce loop's raw material.
# ---------------------------------------------------------------------------
REQUIRED_FIELDS='Goal
Milestone
Depends on
Serves
Relevant ADRs
Touches
Scenarios
Out of scope
Done when
Lane
Risk
Multi-record fixtures'

# A contract's value for one **Field:**, up to the next ` · ` separator or EOL.
field_value() {  # $1=file $2=field
  awk -v f="$2" '
    { s = $0
      k = "**" f ":**"
      i = index(s, k)
      if (i == 0) next
      s = substr(s, i + length(k))
      # the template puts two fields on one line, separated by a middle dot
      j = index(s, "·"); if (j > 0) s = substr(s, 1, j - 1)
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      print s; exit }' "$1"
}

fields() {
  local id f missing all_missing="" n=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    f="$CHUNKDIR/$id.md"
    [ -f "$f" ] || continue
    missing=""
    while IFS= read -r name; do
      grep -qF -- "**$name:**" "$f" || missing="$missing $name,"
    done <<< "$REQUIRED_FIELDS"
    if [ -n "$missing" ]; then
      all_missing="$all_missing $id misses:${missing%,};"
      n=$((n+1))
    fi
  done <<EOF
$IDS
EOF
  if [ "$n" = 0 ]; then
    emit fields pass "every chunk carries all $(printf '%s\n' "$REQUIRED_FIELDS" | grep -c .) contract fields"
  else
    emit fields warn "$n chunk(s) with a missing contract field:${all_missing%;}" \
      "add the named field(s) to each contract in docs/chunks/. The card body a fresh-context worker reads is this file and nothing else, so a field absent here is information that reaches nobody"
  fi
}

# ---------------------------------------------------------------------------
# 6. Serves: <= 4 requirements (F11's fix, verbatim: "make /roadmap split any
# chunk whose Serves: list exceeds ~4 requirements").
#
# The run's CHUNK-6 served FR-1..FR-9 and NFR-1..NFR-5 — every requirement in
# the project, in one chunk. CHUNK-5 served 12. A contract that serves
# everything cannot be out of scope for anything, which is how a contract
# enumerating ~40 checkable properties guarantees the judge finds an unmet one.
# ---------------------------------------------------------------------------
SERVES_MAX=4
count_list() {  # comma-separated, backticks stripped, `none` is zero
  printf '%s' "$1" | tr -d '`' | tr ',' '\n' \
    | sed 's/^[ \t]*//; s/[ \t]*$//' \
    | grep -v -i -x -e '' -e 'none' -e 'n/a' | grep -c . || true
}

serves() {
  local id v c over="" worst=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -f "$CHUNKDIR/$id.md" ] || continue
    v="$(field_value "$CHUNKDIR/$id.md" "Serves")"
    c="$(count_list "$v")"
    [ "$c" -gt "$SERVES_MAX" ] && { over="$over $id($c),"; [ "$c" -gt "$worst" ] && worst="$c"; }
  done <<EOF
$IDS
EOF
  if [ -z "$over" ]; then
    emit serves pass "no chunk serves more than $SERVES_MAX requirement(s)"
  else
    emit serves warn "over the $SERVES_MAX-requirement cap:${over%,} — worst $worst" \
      "split each of these into chunks of at most $SERVES_MAX requirements each. This threshold is F11's own and is not to be raised: a chunk serving every requirement is a chunk nothing can be out of scope for"
  fi
}

# ---------------------------------------------------------------------------
# 7. Touches: <= 6 DECLARABLE paths. The skill's file budget, minus the paths
# the methodology obliges every chunk to change and the template has no slot to
# declare — the exemption is sourced from touches-exempt.sh, the same string
# prejudge.sh uses at review time. Counting them here would penalise a planner
# for writing down a file they were always going to edit.
# ---------------------------------------------------------------------------
TOUCHES_MAX=6
path_list() { printf '%s' "$1" | tr -d '`' | tr ',' '\n' \
                | sed 's/^[ \t]*//; s/[ \t]*$//' | grep . || true; }
touches() {
  local id v paths listed c over="" nolist=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -f "$CHUNKDIR/$id.md" ] || continue
    v="$(field_value "$CHUNKDIR/$id.md" "Touches")"
    paths="$(path_list "$v")"
    listed="$(printf '%s\n' "$paths" | grep -c . || true)"
    if [ "$listed" = 0 ]; then nolist="$nolist $id,"; continue; fi
    c="$(printf '%s\n' "$paths" | grep -vcE "$TOUCHES_EXEMPT" || true)"
    [ "$c" -gt "$TOUCHES_MAX" ] && over="$over $id($c of $listed listed),"
  done <<EOF
$IDS
EOF
  # Both findings, never one instead of the other. This was an if/elif chain, so
  # a single chunk missing its Touches list suppressed the over-budget finding
  # for every OTHER chunk in the plan — reproduced with one chunk stripped of
  # `**Touches:**` and another given ten paths against a cap of six: only the
  # missing-list warning printed. They are independent defects in independent
  # contracts and there is no reason one should hide the other.
  if [ -z "$nolist" ] && [ -z "$over" ]; then
    emit touches pass "no chunk declares more than $TOUCHES_MAX non-process path(s)"
    return
  fi
  local ev="" act=""
  [ -n "$nolist" ] && { ev="$ev no parseable Touches list in:${nolist%,};"; \
    act="$act Add a comma-separated Touches list to each of those contracts; without one nothing at plan time or review time can tell scope from drift."; }
  [ -n "$over" ] && { ev="$ev over the $TOUCHES_MAX-file budget:${over%,};"; \
    act="$act Split each of those so no chunk declares more than $TOUCHES_MAX paths. Process docs (docs/decision-log.md, ROADMAP.md at docs/ or repo root, docs/chunks/*) are already excluded, so every path counted is real implementation surface."; }
  ev="${ev# }"; emit touches warn "${ev%;}" "${act# }"
}

# ---------------------------------------------------------------------------
# 8. Scenarios: <= 5, AND one Given/When/Then each.
#
# COUNTING BULLETS IS NOT COUNTING SCENARIOS, and this is the check the whole
# slice turns on. The run's CHUNK-6 scenario 2 reads, verbatim:
#
#   "Given invalid input, an unknown/changing board, cyclic graph,
#    unavailable/old GitHub CLI, malformed canonical evidence, or publication
#    failure ..."
#
# Six scenarios in one bullet. Five such bullets pass a naive count of five and
# specify thirty. So each bullet is scored by the ARITY of its Given and When
# clauses: a clause enumerating alternatives and closing with ", or " is worth
# as many scenarios as it has alternatives.
#
# Disjunction only, never conjunction, and the distinction is the whole of the
# heuristic's precision. "Given A, B, and C" is one scenario with a compound
# setup — one report containing several kinds of field is still one report.
# "Given A, B, or C" is three scenarios wearing one bullet, because no single
# run of the system can be in three of those states at once.
# ---------------------------------------------------------------------------
SCENARIO_MAX=5
SCENARIO_AWK='
  # Count CLAUSE MARKERS, not word occurrences. Counting occurrences reported
  # ordinary English as malformed — "then the record GIVEN to the caller"
  # scored given=2, and "then the operator is told WHEN it started" scored
  # when=2. Both are well-formed single scenarios, and a bullet rejected on
  # vocabulary is never sized either, because the shape branch returns early.
  # A marker is the word at the start of the bullet or after , ; or .
  function nkw(s, w,   n, i, rest, before, after, off) {
    n = 0; rest = s; off = 0
    while ((i = index(rest, w)) > 0) {
      before = (off + i == 1) ? "^" : substr(s, off + i - 1, 1)
      after  = substr(rest, i + length(w), 1)
      if (before == " " && (off + i) >= 3) {
        before = substr(s, off + i - 2, 1)
        if (before != "," && before != ";" && before != ".") before = "x" }
      if ((before == "^" || before == "," || before == ";" || before == ".") \
          && (after == " " || after == "")) n++
      off = off + i + length(w) - 1
      rest = substr(rest, i + length(w))
    }
    return n }

  # A comparative after "or" is a RANGE, not an alternative. "a record of 5 or
  # more fields" is one scenario; scoring it as two reported a defect in a
  # correct plan, and a checker that tells a planner to edit a correct plan is
  # worse than no checker.
  function is_range(w) {
    return (w == "more" || w == "less" || w == "fewer" || w == "greater" ||
            w == "later" || w == "earlier" || w == "equal" || w == "newer" ||
            w == "older" || w == "higher" || w == "lower" || w == "longer" ||
            w == "shorter" || w == "so") }

  # A disjunctive clause is worth as many scenarios as it lists (ADR-0012
  # D12.3). The old rule returned a flat 2 for anything containing " or ", so
  # "empty or partial or corrupt or truncated or absent" — five alternatives —
  # scored 2, which is the same undercount the check exists to catch.
  #
  # Two shapes, and the answer is the larger: an Oxford list ("A, B, or C")
  # where the commas carry the alternatives, and a repeated-or list ("A or B or
  # C") where the separators do. A clause mixing both is scored by whichever
  # reads higher — under-, never over-counting, because a false finding costs a
  # planner more than a missed one at this severity.
  # The commas only count when they belong to the SAME list as the "or" — that
  # is, when the separator is the Oxford ", or ". Counting every earlier comma
  # made an ordinary conjunctive list followed by one plain "or" score as a
  # disjunction of the whole list:
  #
  #   "Given a record carrying a start time, an end time, a status, a cost, a
  #    model name, a lane name, a card id, and a digest that is absent or stale"
  #
  # scored 9. The truth is 2 — "absent or stale" — and one correct bullet
  # single-handedly blew the five-scenario cap and produced two findings telling
  # the planner to split a correct chunk, which the header of this file calls
  # an outcome worse than no checker.
  function arity(c,   n, i, w, ors, prefix, commas, best, trimmed) {
    n = split(c, part, / or /)
    if (n == 1) return 1
    ors = 0; commas = 0; prefix = part[1]
    for (i = 2; i <= n; i++) {
      w = part[i]
      sub(/^[^a-z0-9]*/, "", w); sub(/[^a-z0-9].*$/, "", w)
      if (!is_range(w)) {
        ors++
        # Oxford form only: the text immediately before this separator ends in a
        # comma. "a, b, or c" qualifies; "…a digest that is absent or stale"
        # does not, and its earlier commas belong to a different list.
        trimmed = prefix
        sub(/[ \t]+$/, "", trimmed)
        if (trimmed ~ /,$/) commas = gsub(/,/, ",", prefix)
        else commas = 0
      }
      prefix = prefix " or " part[i]
    }
    if (ors == 0) return 1
    best = ors + 1
    if (commas + 1 > best) best = commas + 1
    return best }

  # Scoring happens on a BUFFERED bullet, not on a line.
  #
  # This was strictly line-oriented, so a bullet wrapped over two physical lines
  # — ordinary Markdown, and how docs/roadmap-first-run.md writes its own C1
  # scenarios — was read as a bullet with a Given and no Then and reported
  # malformed. The plan document that specified this checker failed it, on
  # formatting. Every fixture bullet was one long line, so `verify` could not
  # see it.
  function flush(   l, g, w, t, ig, iw, it, gc, wc, a, b) {
    if (buf == "") return
    bullets++
    l = tolower(buf)
    g = nkw(l, "given"); w = nkw(l, "when"); t = nkw(l, "then")
    if (g != 1 || w != 1 || t != 1) {
      shape = shape " #" bullets "(given=" g ",when=" w ",then=" t ")"
      effective++; buf = ""; return }
    ig = index(l, "given"); iw = index(l, "when"); it = index(l, "then")
    gc = substr(l, ig + 5, iw - ig - 5)
    wc = substr(l, iw + 4, it - iw - 4)
    a = arity(gc); b = arity(wc); if (b > a) a = b
    if (a > 1) compound = compound " #" bullets "=" a
    effective += a
    buf = "" }

  /^- \*\*Scenarios:\*\*/ { flush(); f = 1; next }
  /^- \*\*/               { flush(); f = 0 }
  f && /^[ \t]*- /        { flush(); line = $0; sub(/^[ \t]*-[ \t]*/, "", line); buf = line; next }
  f && /^[ \t]*$/         { flush(); next }
  f                       { line = $0; sub(/^[ \t]+/, "", line)
                            if (buf != "") buf = buf " " line
                            next }
  END { flush()
        printf "%d\t%d\t%s\t%s\n", bullets + 0, effective + 0, (compound == "" ? "-" : compound), (shape == "" ? "-" : shape) }'

scenarios() {
  local id out bullets eff compound shape over="" bad_shape="" packed=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -f "$CHUNKDIR/$id.md" ] || continue
    out="$(awk "$SCENARIO_AWK" "$CHUNKDIR/$id.md")"
    IFS=$'\t' read -r bullets eff compound shape <<< "$out"
    [ "$bullets" = 0 ] && continue
    [ "$eff" -gt "$SCENARIO_MAX" ] && over="$over $id($eff from $bullets bullet(s)),"
    [ "$compound" != "-" ] && packed="$packed $id:$compound,"
    [ "$shape" != "-" ] && bad_shape="$bad_shape $id:$shape,"
  done <<EOF
$IDS
EOF
  if [ -z "$over" ] && [ -z "$bad_shape" ] && [ -z "$packed" ]; then
    emit scenarios pass "every chunk specifies at most $SCENARIO_MAX scenarios, one Given/When/Then each"
    return
  fi
  local ev="" act=""
  [ -n "$over" ] && ev="$ev over the $SCENARIO_MAX-scenario cap:${over%,};"
  [ -n "$packed" ] && { ev="$ev compound bullets (each enumerated alternative counts as one):${packed%,};"; \
    act="$act Rewrite each compound bullet as one bullet per alternative — a bullet reading 'Given A, B, or C' is three scenarios and will be implemented as one."; }
  [ -n "$bad_shape" ] && { ev="$ev not one Given/When/Then:${bad_shape%,};"; \
    act="$act Give every bullet exactly one Given, one When and one Then; these bullets become the .feature file verbatim."; }
  [ -n "$over" ] && act="$act Split any chunk over $SCENARIO_MAX effective scenarios; the threshold is the roadmap skill's own and is not to be raised to fit a plan."
  ev="${ev# }"; emit scenarios warn "${ev%;}" "${act# }"
}

# ---------------------------------------------------------------------------
# 9. Lane names something that can actually run the card.
#
# board-bootstrap.sh checks ONE assignee — $FORGE_LANE_ASSIGNEE — before it
# creates anything. It does not check the per-chunk `lane` it reads out of
# graph.json, and `hermes kanban create` accepts an unknown assignee without
# error: the card sits in `ready` forever with a skipped_nonspawnable event,
# visible only via `kanban diagnostics` half an hour later. That is the failure
# this catches, and it catches it before the board exists.
# ---------------------------------------------------------------------------
lane() {
  local known="${FORGE_ASSIGNEES:-}" src="\$FORGE_ASSIGNEES"
  known="$(printf '%s' "$known" | tr ' ' '\n' | grep . || true)"
  if [ -z "$known" ]; then
    if command -v hermes >/dev/null 2>&1; then
      # --json, and ONLY the names with a profile on disk.
      #
      # `hermes kanban assignees` prints a formatted TABLE, and the old check
      # matched any space-delimited token in it. Measured against live output,
      # all of these PASSED: `yes` and `no` (the ON DISK column), `NAME`,
      # `DISK` and `COUNTS` (the header row), `done=1` and `(idle)` (the COUNTS
      # column), and `forge-operator`, which is `on_disk: false`.
      #
      # The second half is worse than the first. That list is derived from
      # CARDS, so a lane name that has already stranded a card appears in it
      # forever: `no-such-profile-xyz` was in the live output *because* it
      # stranded one. The check validated the exact failure mode its own header
      # says it exists to catch, and got more permissive every time the bug
      # fired. `on_disk` is the only field that answers "can this run a card".
      known="$(hermes kanban assignees --json 2>/dev/null \
               | jq -r '.[] | select(.on_disk == true) | .name' 2>/dev/null)"
      src="hermes kanban assignees --json (on_disk only)"
    fi
  fi
  if [ -z "$known" ]; then
    emit lane skip "no hermes on PATH and no \$FORGE_ASSIGNEES — the assignee list could not be read, so no lane has been cleared"
    return
  fi
  local id l unknown="" seen=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    l="$(jq -r --arg id "$id" '.[] | select(.id == $id) | (.lane // "")' "$GRAPH")"
    [ -n "$l" ] || { unknown="$unknown $id(no lane),"; continue; }
    seen=$((seen+1))
    [ "$l" = "claude-interactive" ] && continue
    printf '%s\n' "$known" | grep -qxF "$l" || unknown="$unknown $id($l),"
  done <<EOF
$ALL_IDS
EOF
  if [ -z "$unknown" ]; then
    emit lane pass "$seen lane(s), each claude-interactive or a known assignee (per $src)"
  else
    emit lane warn "not a known assignee (per $src):${unknown%,}" \
      "set each to the literal claude-interactive or to a name from \`hermes kanban assignees\` — run ./hermes/profiles-bootstrap.sh if the profile should exist and does not. An unknown assignee is not an error at bootstrap: the card sits in ready with a skipped_nonspawnable event nothing surfaces for half an hour"
  fi
}

# ---------------------------------------------------------------------------
# 10. Milestones are gate cards (epic MS1).
#
# A milestone used to be a label in prose. Nothing stopped the next milestone
# starting while the last one was wrong — redglass's CHUNK-15.0 probe found the
# core gates fail-open in code that had already been built on. A gate node makes
# the milestone a card: its parents are the milestone's chunks, the next
# milestone's chunks depend on it, and `_parents_satisfied` holds them natively
# until the gate is done. The gate carries the milestone's probe (MS2) and its
# estimate (PL2), which is what the checkpoint compares actual cost with.
#
# Each finding names the gate or milestone, because a gate whose parents are not
# exactly its milestone's chunks either releases the next milestone early or
# never releases it.
# ---------------------------------------------------------------------------
GATE_FIELDS='Milestone
Probe
Estimate
Lane'

# GATE-M1 -> tests/probes/gate_m1.json — the same derivation acceptance-freeze
# uses for a chunk's feature path, so the path is never a free choice.
gate_probe_path() { printf 'tests/probes/%s.json' "$(printf '%s' "$1" | tr 'A-Z-' 'a-z_')"; }

# milestone <TAB> chunk id, one line per chunk contract that names a milestone.
MS_TSV="$TMP/milestones.tsv"; : > "$MS_TSV"
while IFS= read -r id; do
  [ -n "$id" ] && [ -f "$CHUNKDIR/$id.md" ] || continue
  m="$(field_value "$CHUNKDIR/$id.md" Milestone | tr -d '`' | tr -d ' ')"
  [ -n "$m" ] && printf '%s\t%s\n' "$m" "$id" >> "$MS_TSV"
done <<EOF
$IDS
EOF
# Milestones in plan order: M<n> sorts by n. A name not of that form sorts last
# and is reported by `gates`, which needs the order to find "the next one".
MILESTONES="$(cut -f1 "$MS_TSV" | sort -u \
  | awk '{ n = ($0 ~ /^M[0-9]+$/) ? substr($0, 2) + 0 : 999999; print n "\t" $0 }' \
  | sort -n -k1,1 | cut -f2)"

gate_has_ancestor() {  # $1=node $2=ancestor -> exit 0 when $2 is upstream of $1
  jq -e --arg c "$1" --arg g "$2" '
    (map({key: .id, value: (.depends_on // [])}) | from_entries) as $d
    | {seen: [], frontier: ($d[$c] // [])}
    | until(.frontier | length == 0;
            ((.seen + .frontier) | unique) as $s
            | {seen: $s, frontier: ([.frontier[] | ($d[.] // [])[]] | unique - $s)})
    | .seen | index($g) != null' "$GRAPH" >/dev/null 2>&1
}

gates() {
  local g m f name want got lane_ problems="" prev="" id
  if [ -z "$MILESTONES" ] && [ -z "$GATE_IDS" ]; then
    emit gates skip "no chunk names a milestone and the graph has no gate node, so there is nothing to gate"
    return
  fi
  for m in $MILESTONES; do
    case "$m" in M[0-9]*) ;; *) problems="$problems milestone '$m' is not named M<n>;";; esac
    printf '%s\n' "$GATE_IDS" | grep -qxF "GATE-$m" || problems="$problems $m has no GATE-$m node;"
  done
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    m="${g#GATE-}"
    want="$(awk -F'\t' -v m="$m" '$1==m{print $2}' "$MS_TSV" | sort)"
    got="$(jq -r --arg id "$g" '.[] | select(.id == $id) | (.depends_on // [])[]' "$GRAPH" | sort)"
    if [ -z "$want" ]; then
      problems="$problems $g gates milestone $m, which no chunk names;"
    elif [ "$got" != "$want" ]; then
      problems="$problems $g closes [$(printf '%s' "$got" | tr '\n' ' ' | sed 's/ $//')] but milestone $m is [$(printf '%s' "$want" | tr '\n' ' ' | sed 's/ $//')];"
    fi
    lane_="$(jq -r --arg id "$g" '.[] | select(.id == $id) | (.lane // "")' "$GRAPH")"
    # Held for the operator is the only gate route until something runs one:
    # the probe runner (epic S5b), then the overseer (S8). board-bootstrap.sh
    # refuses any other lane before a board exists; this says so at plan time.
    if [ "$lane_" = "$LANE_IMPLEMENTER" ]; then
      problems="$problems $g is assigned to $LANE_IMPLEMENTER, which would run it as a chunk;"
    elif [ -n "$lane_" ] && [ "$lane_" != claude-interactive ]; then
      problems="$problems $g is assigned to $lane_, but no profile runs a gate card yet;"
    fi
    f="$CHUNKDIR/$g.md"
    [ -f "$f" ] || continue   # bijection names it
    while IFS= read -r name; do
      grep -qF -- "**$name:**" "$f" || problems="$problems $g misses **$name:**;"
    done <<< "$GATE_FIELDS"
    got="$(field_value "$f" Milestone | tr -d '` ')"
    [ -z "$got" ] || [ "$got" = "$m" ] || problems="$problems $g says Milestone $got, its id says $m;"
    got="$(field_value "$f" Probe | tr -d '` ')"
    [ -z "$got" ] || [ "$got" = "$(gate_probe_path "$g")" ] || \
      problems="$problems $g declares probe $got, expected $(gate_probe_path "$g");"
    got="$(field_value "$f" Estimate)"
    [ -z "$got" ] || printf '%s' "$got" | grep -Eqx '[0-9]+ chunks?' || \
      problems="$problems $g estimate '$got' is not '<n> chunks';"
  done <<EOF
$GATE_IDS
EOF
  # Each milestone after the first waits for the one before it: every chunk of
  # milestone N has GATE-M(N-1) upstream. One missing edge and a chunk of M2 is
  # dispatched while M1 is still unverified — the whole point of the gate.
  for m in $MILESTONES; do
    if [ -n "$prev" ] && printf '%s\n' "$GATE_IDS" | grep -qxF "GATE-$prev"; then
      for id in $(awk -F'\t' -v m="$m" '$1==m{print $2}' "$MS_TSV"); do
        gate_has_ancestor "$id" "GATE-$prev" || problems="$problems $id ($m) does not wait for GATE-$prev;"
      done
    fi
    prev="$m"
  done
  if [ -z "$problems" ]; then
    emit gates pass "$(printf '%s\n' "$GATE_IDS" | grep -c .) gate(s) for milestone(s) $(printf '%s' "$MILESTONES" | tr '\n' ' ' | sed 's/ $//'), each closing exactly its chunks and each gating the next"
  else
    problems="${problems# }"
    emit gates warn "${problems%;}" \
      "give every milestone M<n> one GATE-M<n> node in graph.json whose depends_on is exactly that milestone's chunks, make each chunk of the next milestone depend on it, assign it claude-interactive (held for the operator — board-bootstrap.sh refuses any other gate lane), and write docs/chunks/GATE-M<n>.md with Milestone, Probe ($(gate_probe_path GATE-M1) for M1), Estimate ('<n> chunks') and Lane"
  fi
}

# ---------------------------------------------------------------------------
# 11. Tier (epic PL3). `lane` is the card's assignee; `tier` is what kind of
# implementer the chunk is sized and budgeted for. Only two exist before EN1:
# `strong` (Codex, through the lane) and `human`. `cheap` and `local` are
# accepted words with nothing behind them yet, so a chunk given one would be
# dispatched to a model nobody has configured — a warning, not a routing.
# ---------------------------------------------------------------------------
tier() {
  local id t l m notier="" unrouted="" invalid="" mismatch="" humans over=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    t="$(jq -r --arg id "$id" '.[] | select(.id == $id) | (.tier // "")' "$GRAPH")"
    l="$(jq -r --arg id "$id" '.[] | select(.id == $id) | (.lane // "")' "$GRAPH")"
    case "$t" in
      "") notier="$notier $id,"; continue;;
      strong|human) ;;
      cheap|local) unrouted="$unrouted $id($t),";;
      *) invalid="$invalid $id($t),"; continue;;
    esac
    if [ "$t" = human ] && [ "$l" != claude-interactive ]; then
      mismatch="$mismatch $id(human on $l),"
    elif [ "$t" != human ] && [ "$l" = claude-interactive ]; then
      mismatch="$mismatch $id($t on claude-interactive),"
    fi
  done <<EOF
$IDS
EOF
  # The north-star target: at most one human-implemented chunk per milestone.
  for m in $MILESTONES; do
    humans="$(awk -F'\t' -v m="$m" '$1==m{print $2}' "$MS_TSV" | while IFS= read -r id; do
      jq -r --arg id "$id" '.[] | select(.id == $id and .tier == "human") | .id' "$GRAPH"; done | grep -c . || true)"
    [ "$humans" -gt 1 ] && over="$over $m($humans),"
  done
  if [ -z "$notier$unrouted$invalid$mismatch$over" ]; then
    emit tier pass "$(printf '%s\n' "$IDS" | grep -c .) chunk(s), each strong or human, human exactly where the lane is claude-interactive, at most one human chunk per milestone"
    return
  fi
  local ev=""
  [ -n "$notier" ] && ev="$ev no tier:${notier%,};"
  [ -n "$invalid" ] && ev="$ev not a tier:${invalid%,};"
  [ -n "$unrouted" ] && ev="$ev no implementer exists for this tier until EN1:${unrouted%,};"
  [ -n "$mismatch" ] && ev="$ev tier and lane disagree:${mismatch%,};"
  [ -n "$over" ] && ev="$ev more than one human chunk in:${over%,};"
  ev="${ev# }"
  emit tier warn "${ev%;}" \
    "give every chunk \"tier\": \"strong\" (lane forge-codex-lane) or \"human\" (lane claude-interactive) in graph.json. Keep human for a chunk whose decision genuinely needs the operator — the target is at most one per milestone"
}

# ---------------------------------------------------------------------------
# 12/13. The scope's budget and the architect's estimate, carried (PL1, PL2).
# The numbers come from `plan-check.sh --facts`, the one parser of
# docs/REQUIREMENTS.md and docs/feasibility.md. Absent is null there and SKIP
# here — a plan with no budget has not been budgeted, which is not the same as
# fitting one.
# ---------------------------------------------------------------------------
FACTS=""
[ -x "$HERE/plan-check.sh" ] && FACTS="$("$HERE/plan-check.sh" "$PROJECT" --facts 2>/dev/null)" || FACTS=""
fact() { printf '%s' "$FACTS" | jq -r "$1" 2>/dev/null; }

budget() {
  local bc bm nc nm ev=""
  if [ -z "$FACTS" ]; then
    emit budget skip "plan-check.sh --facts could not run beside this script, so no budget was read"
    return
  fi
  bc="$(fact '.budget.chunks // empty')"; bm="$(fact '.budget.milestones // empty')"
  if [ -z "$bc" ]; then
    emit budget skip "docs/REQUIREMENTS.md declares no readable **Complexity budget:** — run plan-check.sh --stage scope"
    return
  fi
  nc="$(printf '%s\n' "$IDS" | grep -c . || true)"
  nm="$(printf '%s\n' "$MILESTONES" | grep -c . || true)"
  [ "$nc" -gt "$bc" ] && ev="$ev $nc chunk(s) against a budget of $bc;"
  [ "$nm" -gt "$bm" ] && ev="$ev $nm milestone(s) against a budget of $bm;"
  if [ -z "$ev" ]; then
    emit budget pass "$nc chunk(s) in $nm milestone(s), within the scope budget of $bc in $bm"
  else
    ev="${ev# }"
    emit budget warn "the plan exceeds the scope's complexity budget: ${ev%;}" \
      "cut or defer until the plan fits, or go back to /scope and raise the budget there with the operator — do not plan past a number the operator signed off"
  fi
}

estimate() {
  local kept g e sum=0 per=""
  if [ -z "$FACTS" ] || [ -z "$(fact '.ledger.kept_chunks // empty')" ]; then
    emit estimate skip "no readable docs/feasibility.md ledger — run plan-check.sh --stage architect"
    return
  fi
  if [ -z "$GATE_IDS" ]; then
    emit estimate skip "no gate node, so no milestone carries an estimate — see gates"
    return
  fi
  kept="$(fact '.ledger.kept_chunks')"
  while IFS= read -r g; do
    [ -n "$g" ] && [ -f "$CHUNKDIR/$g.md" ] || continue
    e="$(field_value "$CHUNKDIR/$g.md" Estimate | sed -n 's/^\([0-9][0-9]*\) chunks*$/\1/p')"
    [ -n "$e" ] || continue   # gates reports the malformed estimate
    sum=$((sum + e))
    per="$per ${g#GATE-} planned $(awk -F'\t' -v m="${g#GATE-}" '$1==m' "$MS_TSV" | grep -c . || true)/estimated $e,"
  done <<EOF
$GATE_IDS
EOF
  if [ "$sum" = "$kept" ]; then
    emit estimate pass "the gates carry the ledger's estimate of $kept chunk(s):${per%,}"
  else
    emit estimate warn "estimated by the gates: $sum chunk(s); by the feasibility ledger's kept rows: $kept —${per%,}" \
      "carry the ledger's estimate into the gates' Estimate fields, or re-estimate in docs/feasibility.md and record why. The milestone checkpoint compares actual cost with these numbers, so the two must be one estimate"
  fi
}

# ---------------------------------------------------------------------------
# 14. Spec budget (PL3). Every lane re-reads its contract, and an implementer
# told the plan lives in docs/ROADMAP.md reads that too — JobApp's was 94 KB and
# redglass's 85 KB, because the roadmap skill made it a second copy of every
# contract. It is now an index, and both have a byte budget stated in the skill.
# ---------------------------------------------------------------------------
SPEC_BYTES_MAX=6000
ROADMAP_BYTES_MAX=16000
spec_budget() {
  local id n over="" rmap="" rn
  while IFS= read -r id; do
    [ -n "$id" ] && [ -f "$CHUNKDIR/$id.md" ] || continue
    n="$(wc -c < "$CHUNKDIR/$id.md" | tr -d ' ')"
    [ "$n" -gt "$SPEC_BYTES_MAX" ] && over="$over $id($n),"
  done <<EOF
$ALL_IDS
EOF
  for rn in "$PROJECT/docs/ROADMAP.md" "$PROJECT/ROADMAP.md"; do
    [ -f "$rn" ] || continue
    n="$(wc -c < "$rn" | tr -d ' ')"
    [ "$n" -gt "$ROADMAP_BYTES_MAX" ] && rmap="${rn#"$PROJECT"/} is $n bytes"
    break
  done
  if [ -z "$over" ] && [ -z "$rmap" ]; then
    emit spec-budget pass "every contract within $SPEC_BYTES_MAX bytes; the ROADMAP.md index, if any, within $ROADMAP_BYTES_MAX"
    return
  fi
  local ev=""
  [ -n "$over" ] && ev="$ev contracts over $SPEC_BYTES_MAX bytes:${over%,};"
  [ -n "$rmap" ] && ev="$ev $rmap, over $ROADMAP_BYTES_MAX;"
  ev="${ev# }"
  emit spec-budget warn "${ev%;}" \
    "move rationale out of the contract into an ADR or the decision log and link it, or split the chunk; keep ROADMAP.md an index of one line per chunk and gate — the contract in docs/chunks/ is the only full text"
}

bijection; acyclic; single_root; reachable
fields; serves; touches; scenarios; lane
gates; tier; budget; estimate; spec_budget

# ---------------------------------------------------------------------------
# Output. No metadata envelope: this runs before a board exists, so there is no
# card to attach one to, and inventing a `forge.*` schema for a result nothing
# stores would be a shape with no consumer.
# ---------------------------------------------------------------------------
printf 'forge roadmap-check — %s  (%s chunk(s), %s gate(s))\n\n' "$PROJECT" "$(printf '%s\n' "$IDS" | grep -c . || true)" "$(printf '%s\n' "$GATE_IDS" | grep -c . || true)"
while IFS=$'\t' read -r id status evidence action; do
  [ "$VERBOSE" = 1 ] || [ "$status" != pass ] || { printf '  %-6s %s\n' "PASS" "$id"; continue; }
  printf '  %-6s %s\n         %s\n' "$(printf '%s' "$status" | tr '[:lower:]' '[:upper:]')" "$id" "$evidence"
  [ -n "$action" ] && printf '      -> %s\n' "$action"
done < "$RESULTS"

W="$(awk -F'\t' '$2=="warn"' "$RESULTS" | grep -c . || true)"
P="$(awk -F'\t' '$2=="pass"' "$RESULTS" | grep -c . || true)"
S="$(awk -F'\t' '$2=="skip"' "$RESULTS" | grep -c . || true)"
printf '\n  %s — %s pass, %s warn, %s skip\n' \
  "$([ "$W" = 0 ] && echo CLEAR || echo "WARN")" "$P" "$W" "$S"
if [ "$W" != 0 ]; then
  printf '  Advisory (ADR-0012): these are planning defects, and the plan is still free to edit.\n'
  printf '  Fix the plan, not the thresholds. Re-run before hermes/board-bootstrap.sh.\n'
fi
exit 0
