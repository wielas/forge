#!/usr/bin/env bash
# =============================================================================
# forge board bootstrap
#   board-bootstrap.sh <board>            init board + load docs/chunks/* cards
#   board-bootstrap.sh <board> --root-only validate graph + load its ONE root
#   board-bootstrap.sh <board> --hello    init board + ONE hello-chunk card
#                                         (the day-one risk burn-down test)
#   ... --branch-suffix <s>               in any mode: append -<s> to every lane
#                                         card's branch (see below)
# Run from the project repo root.
#
# Every flag below was verified against `hermes kanban create --help` on 0.19.0
# (preflight §5). The four that are load-bearing, and what breaks without them:
#   --board       belongs to the KANBAN parser, not to `create`:
#                 `hermes kanban --board <slug> create …`. After the subcommand
#                 it is an unrecognized argument. Board resolution otherwise
#                 falls back to HERMES_KANBAN_BOARD, then the PERSISTED CURRENT
#                 board — `digest` today. We pin both, belt and braces.
#   --workspace   `scratch` (the default) is DELETED on completion. A chunk card
#                 must be `worktree`, which is also preserved afterwards.
#   --assignee    must name a real Hermes profile. An unknown assignee is not an
#                 error: the card sits in `ready` forever with a
#                 skipped_nonspawnable event, visible only via `kanban
#                 diagnostics` half an hour later.
#   --idempotency-key   re-running this script must not duplicate cards.
# There is NO --body-file. Pass file contents with --body "$(cat f)".
# =============================================================================
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: board-bootstrap.sh <board> [full|--root-only|--hello] [--branch-suffix <s>]

  --branch-suffix <s>  append -<s> to the branch of every lane card this run
                       creates (chunk/<id>-<slug>-<s>; --hello: chunk/hello-1-greet-<s>).
                       <s> is a lowercase slug, ^[a-z0-9]+(-[a-z0-9]+)*$, at most 32
                       characters. GitHub keeps a PR tied to its head branch name
                       for ever, and the lane BLOCKS on a CLOSED or MERGED PR only
                       after a paid run — so a re-run of a chunk, or a rehearsal on
                       a name an earlier run spent, needs a name nothing has used.
                       Interactive cards (claude-interactive, GATE-*) carry no
                       --branch, so the suffix does not apply to them.
                       Pass the SAME suffix on every later run of the same board:
                       a card already on the board is left untouched, and the
                       suffix is part of how it is recognised.

Before it creates a card that carries a branch this script asks GitHub, for each
such card, whether that branch already has a PR in ANY state or exists on origin.
  exit 3  the branch is spent (a PR or a remote branch exists): pick another suffix
  exit 2  GitHub, origin or the board could not be asked: not the same as "free"
  exit 1  usage, a bad suffix, a bad graph, or any other FATAL
A refusal creates no card.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0;;
esac
BOARD="${1:?usage: board-bootstrap.sh <board> [full|--root-only|--hello] [--branch-suffix <s>]}"
shift
LANE_ASSIGNEE="${FORGE_LANE_ASSIGNEE:-forge-codex-lane}"

MODE=full
MODE_SET=0
BRANCH_SUFFIX=""
BRANCH_SUFFIX_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    full|--root-only|--hello)
      if [ "$MODE_SET" = 1 ]; then
        echo "board-bootstrap: more than one mode given ('$MODE' and '$1')" >&2
        usage
        exit 1
      fi
      MODE="$1"; MODE_SET=1; shift
      ;;
    --branch-suffix)
      if [ $# -lt 2 ]; then
        echo "board-bootstrap: --branch-suffix needs a value" >&2
        exit 1
      fi
      BRANCH_SUFFIX="$2"; BRANCH_SUFFIX_SET=1; shift 2
      ;;
    --branch-suffix=*)
      BRANCH_SUFFIX="${1#--branch-suffix=}"; BRANCH_SUFFIX_SET=1; shift
      ;;
    *)
      echo "board-bootstrap: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# The suffix is validated before anything else, so a bad one can never reach the
# board. The alphabet is the <slug> half of the branch rule (no capitals, no
# slash, no dot, no leading, trailing or doubled hyphen), so `<branch>-<s>` is a
# branch the rule accepts whenever `<branch>` was. The length cap is ours, not a
# downstream one: neither branch-name.sh nor prejudge.sh limits a branch's
# length, and branch_for caps its own slug at 48; 32 more keeps every name far
# under the 255 bytes a git ref component may be.
if [ "$BRANCH_SUFFIX_SET" = 1 ]; then
  if ! printf '%s' "$BRANCH_SUFFIX" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' \
     || [ "${#BRANCH_SUFFIX}" -gt 32 ]; then
    echo "board-bootstrap: --branch-suffix '$BRANCH_SUFFIX' is not a lowercase slug of at most 32 characters" >&2
    echo "                 (^[a-z0-9]+(-[a-z0-9]+)*\$: no capitals, no slash, no leading or doubled hyphen). No card was created." >&2
    exit 1
  fi
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
GRAPH=docs/chunks/graph.json
ROOT_ID=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# GW1: a held gate speaks to the operator, so it speaks through the one formatter.
# shellcheck source=../scripts/decision-message.sh
. "$HERE/../scripts/decision-message.sh"

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

# Graph validation is a board-mutation boundary in both staged and full modes.
# A malformed plan must fail before even initializing a board.
if [ "$MODE" != "--hello" ]; then
  [ -f "$GRAPH" ] || {
    echo "no $GRAPH found — run /roadmap first (it emits the chunk specs AND the graph)" >&2
    exit 1
  }
  validate_graph "$GRAPH" || exit 1
fi

# Pin the board for every hermes call in this script AND for anything it spawns.
# This is the same mechanism `--board` uses internally (it sets this var for the
# duration of the call), so the two can never disagree.
export HERMES_KANBAN_BOARD="$BOARD"

hermes kanban init 2>/dev/null || true      # idempotent
hermes kanban boards create "$BOARD" 2>/dev/null || true   # `boards` ignores --board

# A `--workspace worktree` card with no explicit workspace_path anchors on the
# BOARD's default_workdir. Unset, `_resolve_worktree_workspace` raises; the
# dispatcher catches that into _record_spawn_failure, and with --max-retries 1
# below the first card auto-blocks on tick 1 — no worker output, no obvious
# cause. Set it here and read it back; `boards create` above is a no-op when the
# board already exists, so the flag on `create` cannot be relied on.
hermes kanban boards set-default-workdir "$BOARD" "$REPO_ROOT"
readback=$(hermes kanban boards list --json \
  | jq -r --arg b "$BOARD" '.[]|select(.slug==$b)|.default_workdir // "null"')
if [ "$readback" != "$REPO_ROOT" ]; then
  echo "FATAL: board '$BOARD' default_workdir is '$readback', expected" >&2
  echo "       '$REPO_ROOT'. Worktree cards would auto-block on tick 1." >&2
  exit 1
fi
echo "board '$BOARD' default_workdir = $readback"

# Fail loudly HERE rather than stranding a card an hour from now.
#
# Read the JSON, not the table, and require `.on_disk`. `kanban assignees`
# lists every name that has EVER appeared on a card and marks each one for
# whether a profile exists for it, so the old unanchored `grep -q` over the
# formatted listing passed for names that cannot receive a card at all —
# verified: it matches `forge-operator-handoff`, the tier-2 sentinel, which by
# design has NO profile on disk. It also matched on substrings and on the
# table's own header words. Both failures are silent in exactly the way this
# check exists to prevent: the dispatcher drops a card on an unspawnable
# assignee, it sits in `ready` with a `skipped_nonspawnable` event, and nothing
# surfaces it for half an hour. `scripts/preflight.sh` (audit F43) and
# `scripts/roadmap-check.sh` already answer "which profiles are real" this way.
if ! hermes kanban assignees --json 2>/dev/null \
     | jq -e --arg a "$LANE_ASSIGNEE" 'any(.[]; .name == $a and .on_disk)' \
       >/dev/null 2>&1; then
  echo "FATAL: '$LANE_ASSIGNEE' is not a known assignee. Run" >&2
  echo "       ./hermes/profiles-bootstrap.sh first, then re-run this." >&2
  exit 1
fi

# The branch name a chunk card carries is not a label: it is enforced twice
# downstream, by the stamped template's `scripts/branch-name.sh` pre-push hook
# and by `scripts/prejudge.sh`'s `branch-name` BLOCK check, both spelling the
# rule AGENTS.md states — `chunk/<id>-<slug>`.
#
# This function used to emit `chunk/${id,,}` with no slug at all: CHUNK-C10
# became `chunk/c10`, which every one of those consumers rejects. Measured on
# JobApp 2026-09-02: the C10 worker had to rename `chunk/c10` itself and
# recorded it as a decision, and it only noticed because that product's CI made
# the consequence concrete. `branch-name.sh`'s own header records the older
# price of the same cause — six `chunk/<n>` pushes on forgeboard-report, four
# PRs closed unmerged on the name alone, after the work was paid for.
#
# So the id keeps its case AND its dots (`C10`, `C9.1`, `7` are all real, and
# the regex allows dotted segments), and the slug comes from the card title.
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

# The --branch-suffix goes on LAST, after branch_for has cut its slug to budget,
# so no cap can ever truncate it. Neither consumer limits a branch's length
# (branch-name.sh and prejudge.sh test shape only), so there is no budget to
# squeeze the slug under; the suffix's own length is capped at parse time.
# `<base>-<s>` stays a name the rule accepts and `prejudge.sh` still reads the
# chunk id from: the id is the first token after `chunk/`, and an appended
# lowercase slug cannot move it.
#
# The producer asks its own consumer. A stamped product carries the ONE copy
# of this rule at scripts/branch-name.sh; asking it here is the difference
# between failing now, before any card exists, and failing in that product's
# CI after the chunk has been implemented and paid for. Products stamped from
# another template have nothing to ask, and are not blocked on its absence.
# It is asked about the FINAL name, suffix included.
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

create_card() {  # $1=title $2=bodyfile $3=assignee $4=idempotency-key $5=branch [extra...]
  hermes kanban --board "$BOARD" create "$1" \
    --assignee "$3" \
    --body "$(cat "$2")" \
    --workspace worktree \
    --branch "$5" \
    --max-retries 1 \
    --idempotency-key "$4" \
    --skill forge-lane \
    "${@:6}"
}

# Same card, but --json so we can capture the id and use it as an atomic
# --parent on later cards. `create` is idempotent on --idempotency-key: it
# returns the EXISTING id rather than creating a duplicate, which is what makes
# re-running this script safe.
create_card_id() {  # $1=title $2=bodyfile $3=assignee $4=idempotency-key $5=branch [extra...]
  create_card "$1" "$2" "$3" "$4" "$5" "${@:6}" --json | jq -r '.id'
}

# A chunk a human drives. It gets a REAL card, blocked so the dispatcher cannot
# pick it up, because a skipped chunk is invisible to the graph — and its
# dependents would then have no unmet prerequisite and auto-promote to ready.
#
# THREE kernel rules dictate the order below. They are measured, not inferred:
# docs/hermes-field-notes.md records the probes, and scripts/prejudge-review.sh
# runs the same sequence (route_tier2) for the tier-2 hand-off card.
#
#   1. `create` has no `running` outcome. The kernel COMPUTES the status: with
#      `--initial-status blocked` it is `blocked`, with `--triage` it is
#      `triage`, otherwise `ready`, downgraded to `todo` when ANY parent is not
#      `done`. This function used to pass `--initial-status running` and then
#      `case` on running|blocked|done, so the card came back `ready` or `todo`,
#      fell to the `*)` arm, and `exit 1` killed the whole bootstrap under
#      `set -e` — for EVERY claude-interactive chunk, every run. `todo` was the
#      common case, because a mid-graph chunk's parents are rarely done yet.
#   2. `block` only fires `WHERE status IN ('running','ready')`. From `todo` it
#      is a silent no-op that returns False. So the card has to be created with
#      NO `--parent` — that is the only way it reliably lands in `ready` — and
#      the edges attached AFTERWARDS. `link` demotes `ready`->`todo`, so
#      blocking after linking would silently leave the card dispatchable.
#      (route_tier2 can pass `--parent` only because a judge card's parent is
#      always already `done`.)
#   3. Stickiness is the blocked EVENT, not the status. `--initial-status
#      blocked` writes only a `created` event whose payload says blocked, and
#      `recompute_ready()` re-promotes the card: measured 2026-07-28, such a
#      probe was promoted on the next tick, assigned to
#      `kanban.default_assignee`, and dispatched. Only a real `block` call
#      makes it stick; `link`'s `linked` event does not clear it.
#      Hermes 0.21.5 changed this: create now also appends a `blocked` event
#      (reason `initial_status`), so a create-time park sticks as well
#      (verify substrate/kanban-card-parking-semantics, 2026-09-24). The real
#      `block` call stays — it is correct on both kernels.
#
# `--assignee forge-operator-handoff` is load-bearing and deliberately NOT a
# real profile (scripts/preflight.sh asserts it never becomes one). It holds
# the card through the window between create and block: this host sets
# `kanban.default_assignee = builder`, so an *unassigned* `ready` card would be
# auto-assigned and spawned before the block landed. The read-back then asserts
# `assignee == null`, after `assign none` has taken the sentinel back off.
# NO --branch / --workspace here, deliberately. `kanban create` rejects
# `--branch` unless `--workspace worktree` rides with it ("--branch is only
# valid with --workspace worktree"), and a worktree workspace on a card the
# dispatcher never claims would record a checkout that is never created. The
# human who runs /start-chunk makes the branch themselves, to the same
# AGENTS.md rule branch_for() encodes. Measured 2026-09-03: passing --branch
# alone here failed every interactive card at create.
create_interactive_card() {  # $1=title $2=bodyfile $3=idempotency-key [--parent <id> ...]
  # $HOLD_REASON, when set, replaces the block reason: a milestone gate holds
  # with a decision-first message rather than the interactive-chunk line.
  local cid state status title="$1" reason
  cid=$(hermes kanban --board "$BOARD" create "$1" \
    --body "$(cat "$2")" \
    --assignee forge-operator-handoff \
    --idempotency-key "$3" \
    --json | jq -r '.id')
  state=$(hermes kanban --board "$BOARD" show "$cid" --json)
  printf '%s' "$state" | jq -e --arg id "$cid" --arg title "$title" '
    .task.id == $id and .task.title == $title
  ' >/dev/null || {
    echo "FATAL: interactive idempotency key mapped to the wrong card identity" >&2
    exit 1
  }
  status=$(printf '%s' "$state" | jq -r '.task.status // empty')
  if [ "$status" = done ]; then
    # Full bootstrap follows the documented human checkpoint. Reuse the
    # terminal root as the same dependency card; never re-block completed work
    # — a second `block` of the same kind trips BLOCK_RECURRENCE_LIMIT and
    # routes the card to `triage`, where it can never be completed — and never
    # erase its human assignee. Its parent edges are still attached below.
    :
  else
    # One idiom for both the fresh card and the already-blocked one, and one
    # unconditional read-back that fails closed on all three substrate facts.
    reason="${HOLD_REASON:-$INTERACTIVE_HOLD_REASON}"
    reason="${reason//<id>/$cid}"
    [ "$status" = blocked ] || \
      hermes kanban --board "$BOARD" block --kind needs_input "$cid" \
        "$reason" >/dev/null
    hermes kanban --board "$BOARD" assign "$cid" none >/dev/null
    hermes kanban --board "$BOARD" show "$cid" --json | jq -e '
      .task.status == "blocked"
      and .task.assignee == null
      and any(.events[]; .kind == "blocked")
    ' >/dev/null || {
      echo "FATAL: interactive card $cid is not sticky-blocked and unassigned" >&2
      exit 1
    }
  fi

  # Edges LAST — see rule 2. The caller hands them as `--parent <id>` pairs,
  # which `create` above deliberately did not receive.
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --parent)
        [ -n "${2:-}" ] || {
          echo "FATAL: --parent given to $cid with no card id" >&2
          exit 1
        }
        hermes kanban --board "$BOARD" link "$2" "$cid" >/dev/null
        shift 2
        ;;
      *)
        echo "FATAL: unexpected argument '$1' for interactive card $cid" >&2
        exit 1
        ;;
    esac
  done
  printf '%s\n' "$cid"
}

# -----------------------------------------------------------------------------
# The branch guard. GitHub ties a PR to its head branch NAME for ever, and
# scripts/lane.sh adopts an OPEN PR, creates one if there is none, and BLOCKS on
# a CLOSED or MERGED one — after the paid Codex run, the green `make check` and
# the push. A card handed a spent name therefore costs a whole run and halts.
# Run A attempt 1 left CLOSED PR #2 on `chunk/1-store-owner-history-in-a-migrated-
# sqlite`, and `--hello`'s fixed `chunk/hello-1-greet` already had three MERGED
# ones; the last rehearsal died on exactly that. So before any card is created
# this asks GitHub about every branch it is about to hand out.
#
#   `gh pr list --head <b> --state all`   EVERY PR on the name, in any state.
#                                         `gh pr view <b>` returns ONE, and the
#                                         one it picks is not the one that blocks.
#   `git ls-remote --heads origin`        a pushed branch with no PR yet.
#
# Exit 3 = the name is spent. Exit 2 = it could not be asked (gh failed, origin
# unreadable, the board's card list unreadable, or an answer that is not JSON):
# "could not ask" is not "nothing there", and a guard that waves a name through
# on an error is the one that costs the paid run. Neither is a skip.
#
# ONLY a card this run would CREATE is asked about. Bootstrap is idempotent on
# `--idempotency-key`, and `create` hands back the existing card for a key it
# has seen; the later full run re-visits the root card, whose branch by now has
# an OPEN PR, and that must pass untouched. `kanban list --json` carries no
# idempotency key, so a card "already exists" when the board holds one with the
# SAME title AND the SAME branch — the pair this script derives from the key's
# chunk. A card that fails to match is asked about, which fails closed: the
# worst a mismatch can do is refuse a re-run that would have been fine.
#
# Everything is asked before the first card is created, so a refusal leaves the
# board with no new card. (The board itself, its workdir and the assignee check
# above are idempotent and already done by then: telling a card that exists from
# one to create needs the board's card list, so the guard cannot run before the
# board does.) `kanban list` runs recompute_ready, so it is not a pure read: the
# same promotion the dispatcher performs every tick, and a no-op on the empty
# board of a first run.
# -----------------------------------------------------------------------------
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

run_guard() {  # $1=file of "<branch><TAB><card title>" lines
  local queue="$1" slug cards br title prs heads errf
  local spent=0 unasked=0 here
  [ -s "$queue" ] || return 0
  errf="$(mktemp)"

  if ! slug="$(origin_slug)"; then
    echo "REFUSED (could not ask, exit 2): $REPO_ROOT has no GitHub 'origin' this script can read" >&2
    echo "       ($(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || echo 'no remote.origin.url')). Whether a branch is spent was not checked. No card was created." >&2
    rm -f "$errf"; exit 2
  fi
  if ! cards="$(hermes kanban --board "$BOARD" list --json 2>"$errf")" \
     || ! printf '%s' "$cards" | jq -e '(if type == "object" then .tasks else . end) | type == "array"' >/dev/null 2>&1; then
    echo "REFUSED (could not ask, exit 2): the card list of board '$BOARD' could not be read, so a card that already exists cannot be told from one to create." >&2
    echo "       $(head -1 "$errf" 2>/dev/null) No card was created." >&2
    rm -f "$errf"; exit 2
  fi

  while IFS=$'\t' read -r br title; do
    [ -n "$br" ] || continue
    if printf '%s' "$cards" | jq -e --arg t "$title" --arg b "$br" \
         '(if type == "object" then .tasks else . end)
          | any(.[]; .title == $t and .branch_name == $b)' >/dev/null 2>&1; then
      echo "exists   $br (already a card on board '$BOARD'; not asked)"
      continue
    fi

    here=0
    if ! prs="$(gh pr list --repo "$slug" --head "$br" --state all \
                  --json number,state --limit 100 2>"$errf")" \
       || ! printf '%s' "$prs" | jq -e '
            type == "array"
            and all(.[]; (.number | type) == "number" and (.state | type) == "string")
          ' >/dev/null 2>&1; then
      echo "REFUSED (could not ask, exit 2): 'gh pr list --repo $slug --head $br --state all' failed or did not answer in JSON." >&2
      echo "       $(head -1 "$errf" 2>/dev/null) Whether '$br' is spent was not checked." >&2
      unasked=1; here=1
    elif [ "$(printf '%s' "$prs" | jq 'length')" != 0 ]; then
      echo "REFUSED (branch spent, exit 3): '$br' already has $(printf '%s' "$prs" | jq -r '[.[] | "PR #\(.number) (\(.state))"] | join(", ")') on $slug." >&2
      spent=1; here=1
    fi

    if ! heads="$(GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" ls-remote --heads origin "refs/heads/$br" 2>"$errf")"; then
      echo "REFUSED (could not ask, exit 2): 'git ls-remote --heads origin $br' failed in $REPO_ROOT." >&2
      echo "       $(head -1 "$errf" 2>/dev/null) Whether '$br' is spent was not checked." >&2
      unasked=1; here=1
    elif [ -n "$heads" ]; then
      echo "REFUSED (branch spent, exit 3): '$br' already exists on origin ($slug) with no card on board '$BOARD'." >&2
      spent=1; here=1
    fi
    [ "$here" = 1 ] || echo "free     $br"
  done < "$queue"
  rm -f "$errf"

  if [ "$unasked" = 1 ]; then
    echo "No card was created. Fix what could not be asked and re-run." >&2
    exit 2
  fi
  if [ "$spent" = 1 ]; then
    echo "No card was created. GitHub keeps a PR tied to its head branch name for ever, and the lane blocks on a CLOSED or MERGED PR only after a paid run." >&2
    echo "       Re-run with a --branch-suffix nothing has ever used (a name you have not typed before)." >&2
    exit 3
  fi
}

if [ "$MODE" = "--hello" ]; then
  tmp=$(mktemp)
  cat > "$tmp" << 'EOF'
### CHUNK-HELLO-1: Add greet(name) with a BDD scenario
- **Goal:** Prove the full lane end-to-end with a trivially small chunk.
- **Milestone:** M0 · **Depends on:** none
- **Serves:** none (infrastructure test) · **Relevant ADRs:** none
- **Touches:** src/<package>/greet.py, tests/features/chunk_hello_1.feature, tests/steps/
- **Scenarios:**
  - Given the package is installed, When I greet "Forge", Then I get "Hello, Forge!"
- **Out of scope:** anything else. Literally anything.
- **Done when:** make check green + scenario passes + PR open
- **Lane:** forge-codex-lane · **Risk:** low
EOF
  hello_title="CHUNK-HELLO-1: Add greet(name) with a BDD scenario"
  hello_branch="$(finish_branch CHUNK-HELLO-1 chunk/hello-1-greet)" || { rm -f "$tmp"; exit 1; }
  hello_queue="$(mktemp)"
  printf '%s\t%s\n' "$hello_branch" "$hello_title" > "$hello_queue"
  run_guard "$hello_queue"
  rm -f "$hello_queue"
  create_card "$hello_title" "$tmp" "$LANE_ASSIGNEE" "hello-1" "$hello_branch"
  rm -f "$tmp"
  echo "hello card created on board '$BOARD'. Watch every step:"
  echo "  hermes kanban --board $BOARD watch"
  echo "  hermes kanban --board $BOARD tail <task-id>   # live worker output"
  exit 0
fi

# full/root-only mode: cards AND edges, driven by docs/chunks/graph.json.
#
# The graph is the ONLY source of truth here. Parsing "Depends on" out of prose,
# or printing link commands for a human to paste, loses edges silently — and a
# child whose parent edge is missing is immediately dispatchable with its
# prerequisite unbuilt. /roadmap emits graph.json for exactly this reason.
if [ ! -f "$GRAPH" ]; then
  echo "no $GRAPH found — run /roadmap first (it emits the chunk specs AND the graph)" >&2
  exit 1
fi
jq -e 'type == "array" and length > 0' "$GRAPH" >/dev/null \
  || { echo "FATAL: $GRAPH is not a non-empty JSON array" >&2; exit 1; }

# chunk id -> created card id. Cards are created in topological order so every
# dependency can be passed as --parent in the SAME create transaction. The old
# two-pass "create every card ready, then link" sequence left a dispatcher race:
# a child could be claimed before its edge existed.
# A flat TSV file, not an associative array: /usr/bin/env bash on macOS is 3.2,
# where `declare -A` does not exist.
IDMAP=$(mktemp)
GUARDQ=$(mktemp)
trap 'rm -f "$IDMAP" "$GUARDQ"' EXIT
card_id_of() { awk -F'\t' -v k="$1" '$1==k{print $2; found=1} END{exit !found}' "$IDMAP"; }

# The branch guard, for every card this run will create that carries a branch,
# BEFORE the first one is created. Interactive cards and gates carry none.
while IFS= read -r id; do
  [ "$MODE" != "--root-only" ] || [ "$id" = "$ROOT_ID" ] || continue
  case "$id" in GATE-*) continue;; esac
  lane=$(jq -r --arg id "$id" --arg lane "$LANE_ASSIGNEE" \
    '.[] | select(.id == $id) | (.lane // $lane)' "$GRAPH")
  [ "$lane" != "claude-interactive" ] || continue
  f="docs/chunks/$id.md"
  [ -f "$f" ] || {
    echo "FATAL: $GRAPH names $id but $f does not exist" >&2
    exit 1
  }
  title=$(head -1 "$f" | sed 's/^#* *//')
  branch=$(branch_for "$id" "${title:-$id}")
  printf '%s\t%s\n' "$branch" "${title:-$id}" >> "$GUARDQ"
done < <(jq -r '.[].id' "$GRAPH")
run_guard "$GUARDQ"

declared=$(jq '[.[].depends_on // [] | length] | add // 0' "$GRAPH")
created=0
total=$(jq 'length' "$GRAPH")
target_total="$total"
expected_declared="$declared"
if [ "$MODE" = "--root-only" ]; then
  target_total=1
  expected_declared=0
fi
while [ "$(wc -l < "$IDMAP" | tr -d ' ')" -lt "$target_total" ]; do
  progress=0
  while IFS= read -r id; do
    [ "$MODE" != "--root-only" ] || [ "$id" = "$ROOT_ID" ] || continue
    card_id_of "$id" >/dev/null 2>&1 && continue

    lane=$(jq -r --arg id "$id" --arg lane "$LANE_ASSIGNEE" \
      '.[] | select(.id == $id)
       | (.lane // (if (.id | startswith("GATE-")) then "claude-interactive" else $lane end))' "$GRAPH")
    deps=$(jq -r --arg id "$id" \
      '.[] | select(.id == $id) | (.depends_on // [])[]' "$GRAPH")
    parent_args=()
    parent_count=0
    expected_parents=""
    parents_ready=1
    for parent in $deps; do
      parent_card=$(card_id_of "$parent" 2>/dev/null) || {
        parents_ready=0
        break
      }
      parent_args+=(--parent "$parent_card")
      parent_count=$((parent_count + 1))
      expected_parents="${expected_parents}${parent_card}"$'\n'
    done
    [ "$parents_ready" = 1 ] || continue

    f="docs/chunks/$id.md"
    [ -f "$f" ] || {
      echo "FATAL: $GRAPH names $id but $f does not exist" >&2
      exit 1
    }
    title=$(head -1 "$f" | sed 's/^#* *//')
    HOLD_REASON=""
    case "$id" in
      GATE-*)
        # No branch: a gate is never implemented, so it never pushes one.
        branch=""
        milestone="${id#GATE-}"
        probe="tests/probes/$(printf '%s' "$id" | tr 'A-Z-' 'a-z_').json"
        HOLD_REASON="$(decision_message milestone-gate \
          "$id holds milestone $milestone's successors until you complete it" \
          "every chunk that depends on this gate waits, by the board's own parent rule, until the gate is done" \
          "once every chunk of $milestone is merged, run its probe ($probe) with \`~/.forge/repo/scripts/probe-run.sh '$REPO_ROOT' $id\` and decide whether $milestone is done — exit 0 passes, 1 is a finding, 2 is no verdict; until then there is nothing to decide" \
          "completing it early starts the next milestone on work nobody has probed" \
          "\`hermes kanban --board $BOARD complete <id> --result \"<the runner's last line>\"\`")"
        ;;
      *) branch=$(branch_for "$id" "${title:-$id}");;
    esac
    if [ "$lane" = "claude-interactive" ]; then
      # The empty-array guard stays: `"${parent_args[@]}"` on an empty array is
      # an unbound-variable error under `set -u` in bash 3.2, which is what the
      # Mac mini runs.
      if [ "$parent_count" -eq 0 ]; then
        cid=$(create_interactive_card "${title:-$id}" "$f" "$BOARD-$id")
      else
        cid=$(create_interactive_card "${title:-$id}" "$f" "$BOARD-$id" \
          "${parent_args[@]}")
      fi
      case "$id" in
        GATE-*) echo "held     $id -> $cid (milestone gate — complete it when the milestone's probe passes)";;
        *)      echo "blocked  $id -> $cid (Lane: claude-interactive — run /start-chunk yourself)";;
      esac
    else
      if [ "$parent_count" -eq 0 ]; then
        cid=$(create_card_id "${title:-$id}" "$f" "$lane" "$BOARD-$id" "$branch")
      else
        cid=$(create_card_id "${title:-$id}" "$f" "$lane" "$BOARD-$id" \
          "$branch" "${parent_args[@]}")
      fi
      if [ -n "$deps" ]; then
        echo "todo     $id -> $cid ($lane; waiting on parents)"
      else
        echo "ready    $id -> $cid ($lane)"
      fi
    fi
    [ -n "$cid" ] && [ "$cid" != "null" ] \
      || { echo "FATAL: no card id returned for $id" >&2; exit 1; }

    actual_parents=$(hermes kanban --board "$BOARD" show "$cid" --json \
      | jq -r '.parents[]?' | sort)
    expected_sorted=$(printf '%s' "$expected_parents" | sed '/^$/d' | sort)
    [ "$actual_parents" = "$expected_sorted" ] || {
      echo "FATAL: $id parent readback differs from graph" >&2
      echo "       expected: ${expected_sorted:-none}" >&2
      echo "       actual:   ${actual_parents:-none}" >&2
      exit 1
    }

    printf '%s\t%s\n' "$id" "$cid" >> "$IDMAP"
    created=$((created + parent_count))
    progress=$((progress + 1))
  done < <(jq -r '.[].id' "$GRAPH")

  [ "$progress" -gt 0 ] || {
    echo "FATAL: $GRAPH has a cycle or names a missing dependency" >&2
    exit 1
  }
done

if [ "$created" != "$expected_declared" ]; then
  echo "FATAL: attached $created parents for the created set but expected $expected_declared." >&2
  exit 1
fi

echo "board '$BOARD': $(wc -l < "$IDMAP" | tr -d ' ') cards, $created/$expected_declared parents attached atomically."
