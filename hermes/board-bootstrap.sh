#!/usr/bin/env bash
# =============================================================================
# forge board bootstrap
#   board-bootstrap.sh <board>            init board + load docs/chunks/* cards
#   board-bootstrap.sh <board> --root-only validate graph + load its ONE root
#   board-bootstrap.sh <board> --hello    init board + ONE hello-chunk card
#                                         (the day-one risk burn-down test)
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
BOARD="${1:?usage: board-bootstrap.sh <board> [--root-only|--hello]}"
MODE="${2:-full}"
LANE_ASSIGNEE="${FORGE_LANE_ASSIGNEE:-forge-codex-lane}"

case "$MODE" in
  full|--root-only|--hello) ;;
  *)
    echo "usage: board-bootstrap.sh <board> [--root-only|--hello]" >&2
    exit 1
    ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel)"
GRAPH=docs/chunks/graph.json
ROOT_ID=""

validate_graph() { # $1=graph; sets ROOT_ID
  local graph="$1" roots root_count missing ids seen total progress id deps dep ready

  if ! jq -e '
      type == "array" and length > 0
      and all(.[];
        ((.id | type) == "string")
        and (.id | test("^CHUNK-[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and ((.depends_on // []) | type == "array")
        and all((.depends_on // [])[];
          (type == "string")
          and test("^CHUNK-[A-Za-z0-9][A-Za-z0-9._-]*$"))
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
if ! hermes kanban assignees 2>/dev/null | grep -q "$LANE_ASSIGNEE"; then
  echo "FATAL: '$LANE_ASSIGNEE' is not a known assignee. Run" >&2
  echo "       ./hermes/profiles-bootstrap.sh first, then re-run this." >&2
  exit 1
fi

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
create_interactive_card() {  # $1=title $2=bodyfile $3=idempotency-key [parent args...]
  local cid state status
  cid=$(hermes kanban --board "$BOARD" create "$1" \
    --body "$(cat "$2")" \
    --assignee forge-operator-handoff \
    --initial-status running \
    --idempotency-key "$3" \
    "${@:4}" \
    --json | jq -r '.id')
  state=$(hermes kanban --board "$BOARD" show "$cid" --json)
  printf '%s' "$state" | jq -e --arg id "$cid" --arg title "$1" '
    .task.id == $id and .task.title == $title
  ' >/dev/null || {
    echo "FATAL: interactive idempotency key mapped to the wrong card identity" >&2
    exit 1
  }
  status=$(printf '%s' "$state" | jq -r '.task.status // empty')
  case "$status" in
    running)
      hermes kanban --board "$BOARD" block --kind needs_input "$cid" \
        "interactive chunk: human implementation required" >/dev/null
      hermes kanban --board "$BOARD" assign "$cid" none >/dev/null
      state=$(hermes kanban --board "$BOARD" show "$cid" --json)
      printf '%s' "$state" | jq -e '
        .task.status == "blocked"
        and .task.assignee == null
        and any(.events[]; .kind == "blocked")
      ' >/dev/null || {
        echo "FATAL: interactive card $cid is not sticky-blocked and unassigned" >&2
        exit 1
      }
      ;;
    blocked)
      printf '%s' "$state" | jq -e '
        .task.assignee == null and any(.events[]; .kind == "blocked")
      ' >/dev/null || {
        echo "FATAL: existing interactive card $cid lost its sticky block" >&2
        exit 1
      }
      ;;
    done)
      # Full bootstrap follows the documented human checkpoint. Reuse the
      # terminal root as the same dependency card; never re-block completed
      # work or erase its human assignee. Parent identity is read back below.
      ;;
    *)
      echo "FATAL: existing interactive card $cid has unsafe status '${status:-missing}'" >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$cid"
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
  create_card "CHUNK-HELLO-1: Add greet(name) with a BDD scenario" \
              "$tmp" "$LANE_ASSIGNEE" "hello-1" "chunk/hello-1-greet"
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
trap 'rm -f "$IDMAP"' EXIT
card_id_of() { awk -F'\t' -v k="$1" '$1==k{print $2; found=1} END{exit !found}' "$IDMAP"; }

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
      '.[] | select(.id == $id) | (.lane // $lane)' "$GRAPH")
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
    slug=$(printf '%s' "$id" | tr 'A-Z' 'a-z')
    if [ "$lane" = "claude-interactive" ]; then
      if [ "$parent_count" -eq 0 ]; then
        cid=$(create_interactive_card "${title:-$id}" "$f" "$BOARD-$id")
      else
        cid=$(create_interactive_card "${title:-$id}" "$f" "$BOARD-$id" \
          "${parent_args[@]}")
      fi
      echo "blocked  $id -> $cid (Lane: claude-interactive — run /start-chunk yourself)"
    else
      if [ "$parent_count" -eq 0 ]; then
        cid=$(create_card_id "${title:-$id}" "$f" "$lane" "$BOARD-$id" \
          "chunk/${slug#chunk-}")
      else
        cid=$(create_card_id "${title:-$id}" "$f" "$lane" "$BOARD-$id" \
          "chunk/${slug#chunk-}" "${parent_args[@]}")
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
