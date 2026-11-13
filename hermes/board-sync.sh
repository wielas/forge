#!/usr/bin/env bash
# =============================================================================
# forge board sync — bring an existing Hermes board back in line with the plan.
#
# board-bootstrap.sh is create-only: the card body is a copy of docs/chunks/<ID>.md
# taken once, and the lane implements from the card. When the plan changes after
# the board exists (a body amended, a chunk added, an edge moved) the board does
# not follow. The plan is the source of truth and the board its projection; this
# is the way back.
#
#   board-sync.sh <board>                       dry run: the diff, decision first, and
#                                               the commands --apply would run. Writes nothing.
#   board-sync.sh <board> --apply               make the board match
#   board-sync.sh <board> --apply --allow-release   ... even where that makes a card dispatchable
#   ... --branch-suffix <s>                     the suffix the board was started with (see below)
# Run from the product repo's root, as board-bootstrap.sh is.
#
# THE DIFF, one line per finding. What --apply changes:
#   CREATE        a plan unit with no card
#   EDGE-ADD      an edge the plan has and the board lacks
#   UPDATE-BODY   a card that has not started and whose body is not docs/chunks/<ID>.md
#   EDGE-REMOVE   an edge the board has and the plan does not
# What it reports and never touches:
#   MATCH         the card agrees with the plan
#   STALE-DONE    body or edges differ on a done or archived card: history, not edited
#   IN-FLIGHT     body or edges differ on a card that is running, in review, or blocked after a start
#   MANUAL        something sync does not do in v1: the plan's title, lane/assignee or branch differs
#                 from a card that has not started; a gate or an interactive chunk with no card
#   ORPHAN        a card with this board's key whose unit the plan no longer names
# A card "has not started" when it is todo, ready, or blocked on the bootstrap's own hold
# (unassigned, needs_input). Only edges between two cards of plan units are compared; a judge
# card or a triage follow-up hanging off a chunk is not the plan's business. An archived card
# still counts as the unit's card (create ignores archived keys, so a CREATE would duplicate it).
#
# Exit: 0 the board and plan agree (STALE-DONE, IN-FLIGHT, MANUAL that is not a missing
#         unit, and ORPHAN lines do not count: sync never touches them), or --apply converged;
#       1 they differ (dry run), or --apply was refused, stopped, or did not converge;
#         also a CREATE whose branch is spent (a PR or a remote branch exists)
#       2 sync could not run: usage, a graph that bootstrap would refuse, an unreadable board,
#         or GitHub/origin/Hermes could not be asked. "Could not ask" is not "nothing there".
#
# WHAT --apply DOES, in an order that cannot release a card early, one mutation at a time,
# reading the board back (a fresh snapshot, never mode=ro) after each and stopping at the
# first surprise (a card that moved, an edge that is not the one asked for, a body that did not
# take, a create that returned an existing card):
#   a. create each missing lane card, in dependency order, naming EVERY parent in the create
#      call itself: create is atomic with its edges, so a card never exists without them;
#   b. link each missing edge;
#   c. edit --body on cards that have not started, and confirm status and assignee unchanged;
#   d. unlink each surplus edge, last.
# Its only write verbs are create, link, edit and unlink: it never archives, completes,
# unblocks, promotes, assigns or blocks anything. Every call carries --board.
#
# THE TWO WAYS A CARD COULD BE RELEASED, both refused unless --allow-release, and a refusal
# writes NOTHING (like bootstrap's "a refusal creates no card"), the dry run names it:
#   - `unlink` recomputes readiness at once (kanban_db.py unlink_tasks -> recompute_ready): a
#     todo card left with no open parent is ready before the call returns, and the dispatcher
#     can claim it within 60 s. Links go first, so the new parent is there before the old one
#     goes; if the new parent is already done, or there is none, the unlink is refused.
#   - a CREATE whose parents are all done or archived (or that has none) is dispatchable at
#     once. `archived` counts as done for gating (recompute_ready), though create itself
#     treats it as not-done.
#
# WHAT IT DOES NOT CREATE. A gate or a claude-interactive chunk is HELD: bootstrap creates it on
# the non-spawnable sentinel, `block`s it with the reason the digest reads (the digest keeps an
# interactive chunk quiet while a parent is open by matching that reason byte for byte, and
# shows a gate's decision from it), `assign none`s it, then links. Sync never blocks or assigns,
# and `create --initial-status blocked` would record the kernel's reason `initial_status` and no
# block kind, so the card would speak early. It reports MANUAL, with bootstrap's sequence, and
# exits 1: run the sequence, run sync again, and sync creates what hangs off it.
#
# --branch-suffix. A new lane card's branch is derived exactly as board-bootstrap.sh derives it
# (chunk/<id>-<slug>, then -<suffix>), and the branch guard asks GitHub about it first. Pass the
# suffix the board was started with: the check below compares each unstarted lane card's own
# branch with what ITS title and your suffix name, and refuses the creates when they differ.
#
# The board is read from a snapshot copy made by scripts/board-snapshot.sh (WAL: never opened
# in place, never mode=ro). A dry run calls no Hermes verb at all, not even `kanban list`
# (which runs recompute_ready, so it is a write). The planner is scripts/board-sync-plan.py.
#
# Copied from board-bootstrap.sh, byte for byte, and asserted identical by verify.sh
# (sync/created-card-matches-bootstrap): validate_graph, branch_for, finish_branch, origin_slug.
# =============================================================================
set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: board-sync.sh <board> [--apply] [--allow-release] [--branch-suffix <s>]

  (no --apply)         dry run: print the diff and the commands --apply would run; write nothing
  --apply              make the board match docs/chunks/graph.json and docs/chunks/<ID>.md
  --allow-release      permit a step that leaves a card with no open parent (an unlink, or a
                       create whose parents are all done): the dispatcher can claim it at once
  --branch-suffix <s>  the suffix the board was started with, as for board-bootstrap.sh
USAGE
}
help_text() { awk 'NR==1 { next } /^# ={10,}/ { if (seen) exit; seen=1; next } seen { sub(/^#[ ]?/, ""); print }' "$0"; }

case "${1:-}" in
  -h|--help) help_text; exit 0;;
esac
if [ $# -lt 1 ]; then usage; exit 2; fi
BOARD="$1"; shift
LANE_ASSIGNEE="${FORGE_LANE_ASSIGNEE:-forge-codex-lane}"

APPLY=0
ALLOW_RELEASE=0
BRANCH_SUFFIX=""
BRANCH_SUFFIX_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift;;
    --allow-release) ALLOW_RELEASE=1; shift;;
    --branch-suffix)
      if [ $# -lt 2 ]; then
        echo "board-sync: --branch-suffix needs a value" >&2
        exit 2
      fi
      BRANCH_SUFFIX="$2"; BRANCH_SUFFIX_SET=1; shift 2
      ;;
    --branch-suffix=*)
      BRANCH_SUFFIX="${1#--branch-suffix=}"; BRANCH_SUFFIX_SET=1; shift
      ;;
    -h|--help) help_text; exit 0;;
    *)
      echo "board-sync: unknown argument '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

board_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
if ! [[ $BOARD =~ $board_re ]]; then
  echo "board-sync: '$BOARD' is not a board slug" >&2
  exit 2
fi
if [ "$BRANCH_SUFFIX_SET" = 1 ]; then
  suffix_re='^[a-z0-9]+(-[a-z0-9]+)*$'
  if ! [[ $BRANCH_SUFFIX =~ $suffix_re ]] \
     || [ "${#BRANCH_SUFFIX}" -gt 32 ]; then
    echo "board-sync: --branch-suffix '$BRANCH_SUFFIX' is not a lowercase slug of at most 32 characters" >&2
    echo "            (^[a-z0-9]+(-[a-z0-9]+)*\$: no capitals, no slash, no leading or doubled hyphen). Nothing was read or written." >&2
    exit 2
  fi
fi
for tool in jq python3 sqlite3 git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "board-sync: $tool is not on PATH" >&2; exit 2; }
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "board-sync: run this from the product repo's root (git rev-parse --show-toplevel failed)" >&2; exit 2; }
GRAPH=docs/chunks/graph.json
ROOT_ID=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLANNER="$HERE/../scripts/board-sync-plan.py"
[ -f "$PLANNER" ] || { echo "board-sync: $PLANNER is missing" >&2; exit 2; }

# The overseer is gate-only (MS3): no card this script creates may be routed to it, by the
# environment or by the graph. The same program bootstrap asks.
"$HERE/../scripts/overseer-guard.sh" lane "$LANE_ASSIGNEE" >&2 || exit 2

validate_graph() { # $1=graph; sets ROOT_ID
  local graph="$1" roots root_count missing ids seen total progress id deps dep ready

  if ! jq -e '
      type == "array" and length > 0
      and all(.[];
        ((.id | type) == "string")
        and (.id | test("^(CHUNK|GATE)-[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and ((.depends_on // []) | type == "array")
        and all((.depends_on // [])[];
          (type == "string")
          and test("^(CHUNK|GATE)-[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and (((.depends_on // []) | unique | length)
             == ((.depends_on // []) | length)))
      and ((map(.id) | unique | length) == length)
    ' "$graph" >/dev/null 2>&1; then
    echo "FATAL: $graph has invalid or duplicate ids/dependencies" >&2
    return 1
  fi

  "$HERE/../scripts/overseer-guard.sh" graph "$graph" >&2 || return 1

  missing="$(jq -r '
      [.[].id] as $ids
      | [ .[] | (.depends_on // [])[] as $dep
          | select(($ids | index($dep)) == null) | $dep ]
      | unique[]
    ' "$graph")"
  if [ -n "$missing" ]; then
    echo "FATAL: $graph names missing dependencies: $(printf '%s' "$missing" | paste -sd, -)" >&2
    return 1
  fi

  # A GATE-<milestone> node (epic MS1) closes a milestone: its parents are that
  # milestone's chunks, and the next milestone's chunks depend on it, so the
  # kernel's own parent gating holds the next milestone until the gate is done.
  # No profile runs a gate card yet, so it is held for the operator exactly as an
  # interactive chunk is. Refused here, before any board exists: a gate with no
  # parent (it would close nothing, and could be the root), and a gate routed to
  # anything but claude-interactive — on the implementer lane it would be run as
  # a chunk, and on any other profile it would strand or be misread.
  local bad_gates
  bad_gates="$(jq -r '
      .[] | select(.id | startswith("GATE-"))
      | select(((.depends_on // []) | length) == 0
               or ((.lane // "claude-interactive") != "claude-interactive"))
      | .id' "$graph")"
  if [ -n "$bad_gates" ]; then
    echo "FATAL: $graph has gate(s) that are parentless or not claude-interactive: $(printf '%s' "$bad_gates" | paste -sd, -)" >&2
    echo "       A gate closes its milestone's chunks and is held for the operator." >&2
    return 1
  fi

  roots="$(jq -r '.[] | select(((.depends_on // []) | length) == 0) | .id' "$graph")"
  root_count="$(printf '%s\n' "$roots" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$root_count" != 1 ]; then
    echo "FATAL: --root-only requires exactly one graph root; found $root_count" >&2
    return 1
  fi
  ROOT_ID="$roots"

  ids="$(mktemp)"
  seen="$(mktemp)"
  jq -r '.[].id' "$graph" > "$ids"
  total="$(wc -l < "$ids" | tr -d ' ')"
  while [ "$(wc -l < "$seen" | tr -d ' ')" -lt "$total" ]; do
    progress=0
    while IFS= read -r id; do
      grep -Fxq "$id" "$seen" && continue
      deps="$(jq -r --arg id "$id" \
        '.[] | select(.id == $id) | (.depends_on // [])[]' "$graph")"
      ready=1
      for dep in $deps; do
        grep -Fxq "$dep" "$seen" || { ready=0; break; }
      done
      [ "$ready" = 1 ] || continue
      printf '%s\n' "$id" >> "$seen"
      progress=$((progress + 1))
    done < "$ids"
    if [ "$progress" = 0 ]; then
      rm -f "$ids" "$seen"
      echo "FATAL: $graph contains a cycle or a chunk unreachable from $ROOT_ID" >&2
      return 1
    fi
  done

  while IFS= read -r id; do
    if [ ! -f "docs/chunks/$id.md" ]; then
      rm -f "$ids" "$seen"
      echo "FATAL: $graph names $id but docs/chunks/$id.md does not exist" >&2
      return 1
    fi
  done < "$ids"
  rm -f "$ids" "$seen"
}

[ -f "$GRAPH" ] || {
  echo "board-sync: no $GRAPH here — run this from the product repo's root" >&2
  exit 2
}
validate_graph "$GRAPH" || exit 2

# Pin the board for every hermes call in this script and anything it spawns, as bootstrap does;
# every call below also names --board itself.
export HERMES_KANBAN_BOARD="$BOARD"

HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
KANBAN_ROOT="${HERMES_KANBAN_HOME:-$HERMES_ROOT/kanban}"
if [ "$BOARD" = default ]; then DB="$HERMES_ROOT/kanban.db"; else DB="$KANBAN_ROOT/boards/$BOARD/kanban.db"; fi
[ -f "$DB" ] || { echo "board-sync: no board database at $DB — has board '$BOARD' been bootstrapped?" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-board-sync.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
snapshot() { # -> path of a fresh readable copy on stdout (a new directory each time: this runs in $(...))
  local d
  d="$(mktemp -d "$WORK/snap.XXXXXX")" || return 1
  "$HERE/../scripts/board-snapshot.sh" "$DB" "$d/board" 2>"$WORK/snap.err" && return 0
  echo "board-sync: could not snapshot board $BOARD; a board that was not read is not an empty one ($(tail -n 1 "$WORK/snap.err"))" >&2
  return 1
}

branch_for() {  # $1=chunk id (CHUNK-C9.1) $2=card title -> chunk/<id>-<slug>
  local id="$1" title="$2" bare head slug word

  bare="${id#CHUNK-}"

  # The card's own H3 repeats the id ("### CHUNK-C10: Resolve every …"), which
  # would otherwise slug into `chunk/C10-chunk-c10-resolve-…` and then lose the
  # meaningful half to truncation. Drop it only when it really is the id.
  head="$title"
  case "$head" in
    "$id":*)   head="${head#"$id":}";;
    "$bare":*) head="${head#"$bare":}";;
  esac

  # Reduce to the alphabet the <slug> half of the rule allows, with every other
  # byte becoming a separator. LC_ALL=C so a non-ASCII title degrades bytewise
  # rather than locale-dependently. Separating with spaces (not hyphens) leaves
  # the join below to the shell's own word splitting, which cannot emit an
  # empty word.
  head="$(printf '%s' "$head" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9' ' ')"

  # Join words with SINGLE hyphens and stop on a word boundary. Building the
  # slug up rather than cutting it down is what makes a double hyphen, a
  # leading hyphen and a truncated trailing hyphen unrepresentable — all three
  # are names the regex refuses, and a mid-word cut is merely ugly.
  slug=""
  for word in $head; do
    if [ -z "$slug" ]; then
      slug="$word"
    elif [ "${#slug}" -lt 40 ]; then
      slug="$slug-$word"
    else
      break
    fi
  done

  # One unbroken 200-character "word" never reaches the budget test above, so
  # cap the whole slug too and repair the trailing hyphen a blind cut can leave
  # — `chunk/C13-aaa-` is exactly the shape the regex refuses.
  slug="$(printf '%s' "$slug" | cut -c1-48)"
  slug="${slug%-}"

  # A title that is entirely punctuation or entirely non-ASCII cleans to
  # nothing. Emitting `chunk/C10-` would fail the gate, so the fallback is a
  # literal, valid slug: the branch still identifies its chunk by id, and
  # `untitled` says why it carries no words.
  [ -n "$slug" ] || slug="untitled"

  finish_branch "$id" "chunk/$bare-$slug"
}

finish_branch() {  # $1=chunk id (for the message) $2=unsuffixed branch -> final branch
  local id="$1" name="$2"
  [ -z "$BRANCH_SUFFIX" ] || name="$name-$BRANCH_SUFFIX"
  if [ -x "$REPO_ROOT/scripts/branch-name.sh" ] \
     && ! "$REPO_ROOT/scripts/branch-name.sh" "$name" >/dev/null 2>&1; then
    echo "FATAL: $id would get branch '$name', which" >&2
    echo "       $REPO_ROOT/scripts/branch-name.sh rejects. No card was created." >&2
    return 1
  fi
  printf '%s\n' "$name"
}

origin_slug() {  # -> owner/repo of the project's origin, or return 1
  local url path
  url="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null)" || return 1
  case "$url" in
    https://github.com/*|http://github.com/*|ssh://git@github.com/*|ssh://github.com/*|git@github.com:*) ;;
    *) return 1;;
  esac
  path="${url#*github.com}"
  path="${path#[:/]}"; path="${path%/}"; path="${path%.git}"
  printf '%s' "$path" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || return 1
  printf '%s\n' "$path"
}

# The branch guard, as bootstrap's run_guard asks it (a PR in ANY state, or the branch on origin,
# means the name is spent) for the cards this run would create. It differs in two ways: every card
# asked about is one the snapshot says is absent, so there is no `kanban list` to tell an existing
# card from a new one (and `list` runs recompute_ready); and it RETURNS: 0 free, 1 a name is spent
# (a refusal: nothing is created), 2 it could not ask. "Could not ask" is not "free".
run_guard() {  # $1=file of "<branch><TAB><card title>" lines
  local queue="$1" slug br title prs heads errf spent=0 unasked=0 here
  [ -s "$queue" ] || return 0
  errf="$WORK/guard.err"
  if ! slug="$(origin_slug)"; then
    echo "REFUSED (could not ask): $REPO_ROOT has no GitHub 'origin' this script can read" >&2
    echo "       ($(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || echo 'no remote.origin.url')). Whether a branch is spent was not checked. Nothing was created." >&2
    return 2
  fi
  while IFS=$'\t' read -r br title; do
    [ -n "$br" ] || continue
    here=0
    if ! prs="$(gh pr list --repo "$slug" --head "$br" --state all \
                  --json number,state --limit 100 2>"$errf" </dev/null)" \
       || ! printf '%s' "$prs" | jq -e '
            type == "array"
            and all(.[]; (.number | type) == "number" and (.state | type) == "string")
          ' >/dev/null 2>&1; then
      echo "REFUSED (could not ask): 'gh pr list --repo $slug --head $br --state all' failed or did not answer in JSON." >&2
      echo "       $(head -1 "$errf" 2>/dev/null) Whether '$br' is spent was not checked." >&2
      unasked=1; here=1
    elif [ "$(printf '%s' "$prs" | jq 'length')" != 0 ]; then
      echo "REFUSED (branch spent): '$br' already has $(printf '%s' "$prs" | jq -r '[.[] | "PR #\(.number) (\(.state))"] | join(", ")') on $slug." >&2
      spent=1; here=1
    fi
    if ! heads="$(GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" ls-remote --heads origin "refs/heads/$br" 2>"$errf" </dev/null)"; then
      echo "REFUSED (could not ask): 'git ls-remote --heads origin $br' failed in $REPO_ROOT." >&2
      echo "       $(head -1 "$errf" 2>/dev/null) Whether '$br' is spent was not checked." >&2
      unasked=1; here=1
    elif [ -n "$heads" ]; then
      echo "REFUSED (branch spent): '$br' already exists on origin ($slug) with no card on board '$BOARD'." >&2
      spent=1; here=1
    fi
    [ "$here" = 1 ] || echo "free     $br"
  done < "$queue"
  [ "$unasked" = 0 ] || { echo "Nothing was created. Fix what could not be asked and re-run." >&2; return 2; }
  if [ "$spent" = 1 ]; then
    echo "Nothing was created. GitHub keeps a PR tied to its head branch name for ever, and the lane blocks on a CLOSED or MERGED PR only after a paid run." >&2
    echo "       Re-run with a --branch-suffix nothing has ever used (a name you have not typed before)." >&2
    return 1
  fi
  return 0
}

# ---- read the board and the plan --------------------------------------------------------------
S0="$(snapshot)" || exit 2
: > "$WORK/units.jsonl"
while IFS= read -r id; do
  f="docs/chunks/$id.md"
  lane=$(jq -r --arg id "$id" --arg lane "$LANE_ASSIGNEE" \
    '.[] | select(.id == $id)
     | (.lane // (if (.id | startswith("GATE-")) then "claude-interactive" else $lane end))' "$GRAPH")
  deps=$(jq -c --arg id "$id" '.[] | select(.id == $id) | (.depends_on // [])' "$GRAPH")
  title=$(head -1 "$f" | sed 's/^#* *//')
  title="${title:-$id}"
  case "$id" in GATE-*) kind=gate;; *) if [ "$lane" = claude-interactive ]; then kind=interactive; else kind=lane; fi;; esac
  branch=""; expected=""
  if [ "$kind" = lane ]; then
    card_title="$(sqlite3 "$S0" "SELECT json_object('t', title) FROM tasks WHERE idempotency_key = '$BOARD-$id' AND status <> 'archived' ORDER BY created_at DESC LIMIT 1;" 2>/dev/null | jq -r '.t // empty' 2>/dev/null)"
    if [ -n "$card_title" ]; then
      # A card exists: what ITS OWN title and this suffix would name, to compare with its branch. A retitled
      # plan file is not a suffix error, and a title the product's branch rule now refuses is not asked about.
      expected="$(branch_for "$id" "$card_title" 2>/dev/null </dev/null)" || expected=""
    elif [ "$(sqlite3 "$S0" "SELECT COUNT(*) FROM tasks WHERE idempotency_key = '$BOARD-$id';" 2>/dev/null)" = 0 ]; then
      branch="$(branch_for "$id" "$title" </dev/null)" || {
        echo "board-sync: $id has no card, and the branch it would get is refused. Nothing was created." >&2
        exit 2
      }
    fi
  fi
  jq -n --arg id "$id" --arg lane "$lane" --arg kind "$kind" --arg title "$title" --arg branch "$branch" \
        --arg expected "$expected" --argjson deps "$deps" \
    '{id:$id, lane:$lane, kind:$kind, title:$title, deps:$deps,
      branch:(if $branch == "" then null else $branch end),
      expected_branch:(if $expected == "" then null else $expected end)}' >> "$WORK/units.jsonl"
done < <(jq -r '.[].id' "$GRAPH")
jq -s '.' "$WORK/units.jsonl" > "$WORK/units.json"

PLAN="$WORK/plan.json"
make_plan() { # $1=snapshot $2=plan file
  python3 -I "$PLANNER" plan --units "$WORK/units.json" --snapshot "$1" --board "$BOARD" \
    --allow-release "$ALLOW_RELEASE" --out "$2"
}
make_plan "$S0" "$PLAN" || exit 2
echo "board-sync: board '$BOARD' against $GRAPH ($(jq -r '.units' "$PLAN") units, $(jq -r '.cards' "$PLAN") cards on the board)$([ "$APPLY" = 1 ] || echo ' — dry run, nothing is written')"
python3 -I "$PLANNER" render --plan "$PLAN" || exit 2
ACTIONABLE="$(jq -r '.actionable' "$PLAN")"
NSTEPS="$(jq -r '.steps | length' "$PLAN")"

if [ "$(jq -r '.refusals | length' "$PLAN")" != 0 ]; then
  [ "$APPLY" = 0 ] || echo "board-sync: --apply refused; nothing was written." >&2
  exit 1
fi

# The branch guard and the assignee check, before the first write. A dry run asks the guard too: it is
# the one thing that could refuse a CREATE for a reason the diff cannot show. (It asks GitHub and origin,
# never Hermes.)
jq -r '.steps[] | select(.kind == "create") | [.branch, .title] | @tsv' "$PLAN" > "$WORK/guard.queue"
echo ""
run_guard "$WORK/guard.queue"; grc=$?
if [ "$grc" != 0 ]; then exit "$grc"; fi

if [ "$APPLY" = 0 ]; then
  [ "$ACTIONABLE" = 0 ] && exit 0
  exit 1
fi
if [ "$NSTEPS" = 0 ]; then
  [ "$ACTIONABLE" = 0 ] && exit 0
  echo "board-sync: sync has nothing it can do about what is listed above (MANUAL); nothing was written." >&2
  exit 1
fi

if [ -s "$WORK/guard.queue" ]; then
  # An unknown assignee is not an error to Hermes: the card sits in ready for ever. Say so now, not in an hour.
  # `assignees` reads; it writes nothing. The lanes asked about are the ones this run assigns.
  if ! hermes kanban --board "$BOARD" assignees --json </dev/null > "$WORK/assignees.json" 2>"$WORK/assignees.err" \
     || ! jq -e 'type == "array"' "$WORK/assignees.json" >/dev/null 2>&1; then
    echo "board-sync: could not read the assignees ($(head -1 "$WORK/assignees.err" 2>/dev/null)); nothing was written." >&2
    exit 2
  fi
  for lane in $(jq -r '[.steps[] | select(.kind == "create") | .lane] | unique[]' "$PLAN"); do
    jq -e --arg a "$lane" 'any(.[]; .name == $a and .on_disk)' "$WORK/assignees.json" >/dev/null 2>&1 || {
      echo "board-sync: '$lane' is not a known assignee, so a card created for it would sit in ready for ever. Run" >&2
      echo "            ./hermes/profiles-bootstrap.sh first, then re-run this. Nothing was written." >&2
      exit 2
    }
  done
fi

# ---- apply: one mutation at a time, read back after each -------------------------------------
echo ""
echo "board-sync: applying $NSTEPS step(s), one at a time, each read back from a fresh snapshot"
cur="$S0"
i=0
while [ "$i" -lt "$NSTEPS" ]; do
  n=$((i + 1))
  pre="$(python3 -I "$PLANNER" precheck --plan "$PLAN" --index "$i" --snapshot "$cur" --allow-release "$ALLOW_RELEASE")"; prc=$?
  label="$(printf '%s' "$pre" | jq -r '.label // empty' 2>/dev/null)"
  if [ "$prc" != 0 ]; then
    echo "board-sync: stopped before step $n/$NSTEPS (${label:-?}): $(printf '%s' "$pre" | jq -r '.reason // empty' 2>/dev/null)" >&2
    echo "            $i step(s) were applied. Run the dry run to see where the board stands." >&2
    exit 1
  fi
  if [ "$(printf '%s' "$pre" | jq -r '.skip')" = true ]; then
    echo "  [$n/$NSTEPS] $label: already so on the board; nothing to run"
    i=$n; continue
  fi
  argv=()
  while IFS= read -r el; do
    case "$el" in --body=@FILE:*) el="--body=$(cat "${el#--body=@FILE:}")";; esac
    argv+=("$el")
  done < <(printf '%s' "$pre" | jq -r '.argv[]')
  # The four write verbs sync has, and no other, whatever the planner handed over.
  case "${argv[0]:-}" in create|link|edit|unlink) ;; *)
    echo "board-sync: refusing to run '${argv[0]:-}': sync's only write verbs are create, link, edit and unlink" >&2; exit 2;;
  esac
  # A title or a body that begins with '-' is one argument: the body is --body=<text>, the title follows `--`.
  out="$(hermes kanban --board "$BOARD" ${argv[@]+"${argv[@]}"} 2>"$WORK/hermes.err" </dev/null)"; hrc=$?
  if [ "$hrc" != 0 ]; then
    echo "board-sync: stopped at step $n/$NSTEPS ($label): the Hermes call failed ($(tail -n 1 "$WORK/hermes.err" 2>/dev/null))" >&2
    echo "            $i step(s) were applied before it. Run the dry run to see where the board stands." >&2
    exit 1
  fi
  nxt="$(snapshot)" || { echo "board-sync: stopped after step $n/$NSTEPS ($label): the board could not be read back, so the step is unverified" >&2; exit 1; }
  post="$(python3 -I "$PLANNER" postcheck --plan "$PLAN" --index "$i" --before "$cur" --after "$nxt")"; prc=$?
  if [ "$prc" != 0 ]; then
    echo "board-sync: SURPRISE after step $n/$NSTEPS ($label): $post" >&2
    echo "            Stopped. $n step(s) were run, none after this. Nothing was repaired: run the dry run to see where the board stands." >&2
    exit 1
  fi
  newid=""
  [ "${argv[0]}" != create ] || newid=" -> $(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)"
  echo "  [$n/$NSTEPS] $label$newid: done, read back"
  cur="$nxt"
  i=$n
done

# ---- converged? ----------------------------------------------------------------------------
S1="$(snapshot)" || exit 1
make_plan "$S1" "$WORK/plan.after.json" || exit 1
echo ""
echo "board-sync: after the apply"
python3 -I "$PLANNER" render --plan "$WORK/plan.after.json" | grep -v '^MATCH' || true
if [ "$(jq -r '.actionable' "$WORK/plan.after.json")" = 0 ]; then
  echo "board-sync: board '$BOARD' matches the plan."
  exit 0
fi
echo "board-sync: the board does not yet match the plan." >&2
exit 1
