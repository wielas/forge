#!/usr/bin/env bash
# =============================================================================
# forge commission — spend once to prove a product is ready, without launching.
#
# Usage: scripts/commission.sh <absolute-product-path> <board-slug>
#
# Every existing launch prerequisite is recorded verbatim in a timestamped,
# ignored report. This wrapper does not create or open a Hermes board and does
# not invent substitutes for the gates it invokes.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FORGE_ROOT="$(cd "$HERE/.." && pwd)"

usage() {
  echo "usage: scripts/commission.sh <absolute-product-path> <board-slug>" >&2
  exit 2
}

[ "$#" = 2 ] || usage
PROJECT_INPUT="$1"
BOARD="$2"

case "$PROJECT_INPUT" in
  /*) ;;
  *) echo "commission: PROJECT must be an absolute path" >&2; exit 2;;
esac
case "$BOARD" in
  ''|*[!A-Za-z0-9._-]*|[._-]*)
    echo "commission: BOARD must be a safe slug beginning with a letter or number" >&2
    exit 2
    ;;
esac
[ -d "$PROJECT_INPUT" ] \
  || { echo "commission: project directory does not exist: $PROJECT_INPUT" >&2; exit 2; }
PROJECT="$(cd "$PROJECT_INPUT" 2>/dev/null && pwd -P)" \
  || { echo "commission: project directory cannot be resolved: $PROJECT_INPUT" >&2; exit 2; }
git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "commission: PROJECT is not a git worktree: $PROJECT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 \
  || { echo "commission: python3 is required to fingerprint board state" >&2; exit 2; }

# Evidence is permitted only where git has already promised to ignore it. This
# check happens before mkdir so a refusal cannot dirty the product it protects.
git -C "$PROJECT" check-ignore -q .forge/commission-probe \
  || { echo "commission: $PROJECT/.forge must be ignored before commissioning" >&2; exit 2; }
mkdir -p "$PROJECT/.forge"

HERMES_ROOT="${HERMES_HOME:-${HOME:?}/.hermes}"
KANBAN_ROOT="${HERMES_KANBAN_HOME:-$HERMES_ROOT/kanban}"
if [ "$BOARD" = default ]; then
  BOARD_DB="$HERMES_ROOT/kanban.db"
else
  BOARD_DB="$KANBAN_ROOT/boards/$BOARD/kanban.db"
fi

board_fingerprint() {
  python3 - "$BOARD_DB" <<'PY'
import hashlib
import os
import sys

base = sys.argv[1]
paths = [base + suffix for suffix in ("", "-wal", "-shm", "-journal")]
present = [path for path in paths if os.path.exists(path)]
if not present:
    print("ABSENT")
else:
    for path in paths:
        label = os.path.basename(path)
        if not os.path.exists(path):
            print(f"{label} absent")
            continue
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        print(f"{label} {digest.hexdigest()}")
PY
}

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
REPORT="$PROJECT/.forge/commission-$STAMP.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-commission.XXXXXX")" \
  || { echo "commission: could not create scratch directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

BOARD_BEFORE="$(board_fingerprint)" \
  || { echo "commission: could not fingerprint $BOARD_DB" >&2; exit 2; }
FAILED=0
REMOTE_SLUG=""
DEFAULT_BRANCH=""

cat > "$REPORT" <<EOF
# Forge commissioning report

timestamp: $STAMP
project: $PROJECT
board: $BOARD
board-db: $BOARD_DB

EOF

record() { # $1=section, remaining args=command or shell function
  local name="$1" log="$WORK/$1.log" rc
  shift
  "$@" >"$log" 2>&1
  rc=$?
  {
    printf '## %s\n\n' "$name"
    printf 'exit: %s\n\n' "$rc"
    printf '%s\n' '```text'
    cat "$log"
    printf '\n%s\n\n' '```'
  } >> "$REPORT"
  [ "$rc" = 0 ] || FAILED=1
}

durable_path() {
  local accepted
  accepted="$($HERE/new-dest.sh "$PROJECT")" || return $?
  printf 'accepted: %s\n' "$accepted"
  [ "$accepted" = "$PROJECT" ] \
    || { printf 'resolved project differs: %s\n' "$PROJECT"; return 1; }
}

clean_tree() {
  local status
  status="$(git -C "$PROJECT" status --porcelain)" || return $?
  if [ -n "$status" ]; then
    printf '%s\n' "$status"
    return 1
  fi
  printf 'clean: %s\n' "$PROJECT"
}

resolve_remote() {
  local json remote
  remote="$(git -C "$PROJECT" remote get-url origin)" || return $?
  json="$(cd "$PROJECT" && gh repo view --json nameWithOwner,defaultBranchRef)" \
    || return $?
  REMOTE_SLUG="$(printf '%s' "$json" | jq -r '.nameWithOwner // empty')"
  DEFAULT_BRANCH="$(printf '%s' "$json" | jq -r '.defaultBranchRef.name // empty')"
  [ -n "$REMOTE_SLUG" ] && [ -n "$DEFAULT_BRANCH" ] || return 1
  printf 'origin: %s\nrepository: %s\ndefault-branch: %s\n' \
    "$remote" "$REMOTE_SLUG" "$DEFAULT_BRANCH"
}

merge_gate() {
  [ -n "$REMOTE_SLUG" ] && [ -n "$DEFAULT_BRANCH" ] \
    || { echo "remote resolution did not produce a repository and branch"; return 2; }
  "$HERE/merge-gate.sh" "$REMOTE_SLUG" --branch "$DEFAULT_BRANCH" --require check
}

forge_make() {
  (cd "$FORGE_ROOT" && make "$@")
}

board_unchanged() {
  local after
  after="$(board_fingerprint)" || return $?
  printf 'before: %s\nafter: %s\n' "$BOARD_BEFORE" "$after"
  [ "$after" = "$BOARD_BEFORE" ]
}

# Run every prerequisite even after one fails: the artifact is a complete
# commissioning observation, not merely the first error encountered.
record durable-path durable_path
record clean-tree-before clean_tree
record remote-resolution resolve_remote
record merge-gate merge_gate
record roadmap-check forge_make roadmap-check "PROJECT=$PROJECT"
record preflight forge_make preflight
record paid-codex-probe forge_make verify WITH_CODEX=1
record clean-tree-after clean_tree
record board-unchanged board_unchanged

{
  printf '## result\n\n'
  if [ "$FAILED" = 0 ]; then
    printf 'overall: PASS\n'
  else
    printf 'overall: FAIL\n'
  fi
} >> "$REPORT"

printf 'commission report: %s\n' "$REPORT"
if [ "$FAILED" != 0 ]; then
  echo "commission: one or more prerequisites failed" >&2
  exit 1
fi
