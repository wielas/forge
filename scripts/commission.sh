#!/usr/bin/env bash
# =============================================================================
# forge commission — spend once to prove a product is ready, without launching.
#
# Usage: scripts/commission.sh <absolute-product-path> <board-slug>
#   REQUIRE_GATE=1   refuse a product GitHub cannot gate (opt-in strict mode)
#
# Every existing launch prerequisite is recorded verbatim in a timestamped,
# ignored report. This wrapper does not create or open a Hermes board and does
# not invent substitutes for the gates it invokes.
#
# ONE PREREQUISITE IS ALLOWED TO BE NONZERO, and only one: merge-gate exit 5,
# UNAVAILABLE. Branch protection is a paid GitHub feature, so on a private
# repository on a free plan GitHub answers that no server-side gate can exist
# there. That is an answer, not a control that failed to run, and treating it as
# the latter refused every private product outright (ADR-0017, F120). Exit 2 —
# "could not ask" — still fails, because F65 governs it and always did.
#
# The report therefore carries a MANDATORY `posture:` line beside `overall:`,
# emitted on every path and derived only from the merge gate's own exit. A
# report that says PASS for a product nothing gates has to say that too.
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
# Only `1` acts, and any other non-empty value is REFUSED rather than
# reinterpreted. The permissive misreading is the dangerous one here: an
# operator who types REQUIRE_GATE=true and silently gets the lenient path has
# been told the opposite of what they asked. Same reasoning as APPLY in the
# root Makefile, which shipped the bug this guard is copied from.
case "${REQUIRE_GATE:-}" in
  ''|1) ;;
  *) echo "commission: REQUIRE_GATE='$REQUIRE_GATE' is not understood. The only value that acts is REQUIRE_GATE=1; omit it entirely to accept a product GitHub cannot gate." >&2
     exit 2;;
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
EVIDENCE_DIR="$PROJECT/.forge"
mkdir -p "$EVIDENCE_DIR" \
  || { echo "commission: could not create evidence directory: $EVIDENCE_DIR" >&2; exit 2; }

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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-commission.XXXXXX")" \
  || { echo "commission: could not create scratch directory" >&2; exit 2; }
REPORT_TMP="$(mktemp "$EVIDENCE_DIR/commission-$STAMP.XXXXXX")" \
  || { echo "commission: could not create evidence report" >&2; rm -rf "$WORK"; exit 2; }
REPORT="$REPORT_TMP.md"
cleanup() {
  rm -rf "$WORK"
  [ ! -e "$REPORT_TMP" ] || rm -f "$REPORT_TMP"
}
trap cleanup EXIT

BOARD_BEFORE="$(board_fingerprint)" \
  || { echo "commission: could not fingerprint $BOARD_DB" >&2; exit 2; }
FAILED=0
REMOTE_SLUG=""
DEFAULT_BRANCH=""
GATE_RC=""

cat > "$REPORT_TMP" <<EOF
# Forge commissioning report

timestamp: $STAMP
project: $PROJECT
board: $BOARD
board-db: $BOARD_DB

EOF
[ "$?" = 0 ] \
  || { echo "commission: could not initialize evidence report" >&2; exit 2; }

report_printf() {
  printf "$@" >> "$REPORT_TMP" \
    || { echo "commission: could not write evidence report" >&2; exit 2; }
}

report_cat() {
  cat "$1" >> "$REPORT_TMP" \
    || { echo "commission: could not write evidence report" >&2; exit 2; }
}

record() { # $1=section, $2=extra acceptable exits (comma list, or `-` for none),
           # remaining args=command or shell function
  local name="$1" accept="$2" log="$WORK/$1.log" rc code tolerated=0 oldifs
  shift 2
  "$@" >"$log" 2>&1
  rc=$?
  # The recorded exit is the REAL one. A tolerated prerequisite is not laundered
  # into `exit: 0`; the report says 5 and the posture line says what that meant.
  report_printf '## %s\n\n' "$name"
  report_printf 'exit: %s\n\n' "$rc"
  report_printf '%s\n' '```text'
  report_cat "$log"
  report_printf '\n%s\n\n' '```'
  [ "$rc" = 0 ] && return 0
  # EXACT MATCH, member by member. A substring test, a non-empty test, or a
  # default-to-permissive branch here would be the root Makefile's APPLY defect
  # on a knob whose lenient reading is the unsafe one: an empty, malformed or
  # unrecognised list tolerates NOTHING.
  oldifs="$IFS"; IFS=,
  for code in $accept; do
    [ "$code" = "$rc" ] && tolerated=1
  done
  IFS="$oldifs"
  [ "$tolerated" = 1 ] || FAILED=1
  return 0
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

github_slug_from_remote() { # $1=origin URL; print owner/repo or refuse
  local remote="$1" path owner repo
  case "$remote" in
    https://github.com/*) path="${remote#https://github.com/}" ;;
    git@github.com:*) path="${remote#git@github.com:}" ;;
    ssh://git@github.com/*) path="${remote#ssh://git@github.com/}" ;;
    *) printf 'unsupported origin URL: %s\n' "$remote" >&2; return 1 ;;
  esac
  path="${path%.git}"
  case "$path" in
    */*) owner="${path%%/*}"; repo="${path#*/}" ;;
    *) printf 'origin does not name owner/repository: %s\n' "$remote" >&2; return 1 ;;
  esac
  case "$owner" in
    ''|[._-]*|*[!A-Za-z0-9._-]*) printf 'unsafe GitHub owner in origin: %s\n' "$owner" >&2; return 1 ;;
  esac
  case "$repo" in
    ''|[._-]*|*[!A-Za-z0-9._-]*|*/*) printf 'unsafe GitHub repository in origin: %s\n' "$repo" >&2; return 1 ;;
  esac
  printf '%s/%s\n' "$owner" "$repo"
}

resolve_remote() {
  local json remote expected_slug viewed_slug
  remote="$(git -C "$PROJECT" remote get-url origin)" || return $?
  expected_slug="$(github_slug_from_remote "$remote")" || return $?
  json="$(gh repo view "$expected_slug" --json nameWithOwner,defaultBranchRef)" \
    || return $?
  viewed_slug="$(printf '%s' "$json" | jq -r '.nameWithOwner // empty')"
  DEFAULT_BRANCH="$(printf '%s' "$json" | jq -r '.defaultBranchRef.name // empty')"
  [ "$viewed_slug" = "$expected_slug" ] \
    || { printf 'origin repository mismatch: expected %s, GitHub returned %s\n' \
           "$expected_slug" "${viewed_slug:-<empty>}"; return 1; }
  [ -n "$DEFAULT_BRANCH" ] || return 1
  REMOTE_SLUG="$expected_slug"
  printf 'origin: %s\nrepository: %s\ndefault-branch: %s\n' \
    "$remote" "$REMOTE_SLUG" "$DEFAULT_BRANCH"
}

merge_gate() {
  [ -n "$REMOTE_SLUG" ] && [ -n "$DEFAULT_BRANCH" ] \
    || { echo "remote resolution did not produce a repository and branch"; return 2; }
  "$HERE/merge-gate.sh" "$REMOTE_SLUG" --branch "$DEFAULT_BRANCH" --require check
  # `record` runs this in the CURRENT shell, so the assignment survives — the
  # same mechanism resolve_remote() already relies on for REMOTE_SLUG.
  GATE_RC=$?
  return "$GATE_RC"
}

# ALWAYS emitted, on every path, and derived from nothing but the merge gate's
# own exit code. There is one producer of this line so it cannot disagree with
# itself, and no branch that can omit it.
gate_posture() {
  case "$GATE_RC" in
    0)  printf 'GATED (%s %s)' "$REMOTE_SLUG" "$DEFAULT_BRANCH";;
    5)  printf 'UNGATED (merge gate unavailable on this plan: %s)' "$REMOTE_SLUG";;
    '') printf 'UNGATED (the merge gate never ran)';;
    *)  printf 'UNGATED (merge gate not established: merge-gate exit %s)' "$GATE_RC";;
  esac
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
#
# The second column is the ONLY exit besides 0 that section may report without
# failing commissioning. Every section but one is `-`: nothing is tolerated.
GATE_ACCEPT=5
if [ "${REQUIRE_GATE:-}" = 1 ]; then
  GATE_ACCEPT=-
fi

record durable-path      - durable_path
record clean-tree-before - clean_tree
record remote-resolution - resolve_remote
record merge-gate  "$GATE_ACCEPT" merge_gate
record roadmap-check     - forge_make roadmap-check "PROJECT=$PROJECT"
record preflight         - forge_make preflight
record paid-codex-probe  - forge_make verify WITH_CODEX=1
record clean-tree-after  - clean_tree
record board-unchanged   - board_unchanged

report_printf '## result\n\n'
if [ "$FAILED" = 0 ]; then
  report_printf 'overall: PASS\n'
else
  report_printf 'overall: FAIL\n'
fi
report_printf 'posture: %s\n' "$(gate_posture)"

mv "$REPORT_TMP" "$REPORT" \
  || { echo "commission: could not publish evidence report" >&2; exit 2; }

printf 'commission report: %s\n' "$REPORT"
if [ "$FAILED" != 0 ]; then
  echo "commission: one or more prerequisites failed" >&2
  exit 1
fi
