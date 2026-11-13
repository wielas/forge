#!/usr/bin/env bash
# =============================================================================
# forge merge-authority — who may let the verifier merge, board by board.
#
# The verifier (scripts/prejudge-review.sh) holds every approval for the operator
# to merge by hand (recommend-only, ADR-0019 D19.3). Merge mode is the other
# branch: the verifier squash-merges the PR itself and completes the card. Until
# this script the only switch was one environment variable, which applies to
# every board on the host at once and leaves no record of who turned it on.
#
# A GRANT IS ONE FILE PER BOARD, WRITTEN BY AN EXPLICIT ACT, AND REVOCABLE BY
# DELETING IT. <merge-authority root>/<board>.json (scripts/forge-state.sh owns
# the path and the one reader) says who granted merge authority, when and why.
# The verifier reads it when it reaches the merge decision, not when the review
# starts, so a revoke made during a long review still wins. NO FILE, NO MERGE:
# a missing, unreadable or malformed file, one for another board, or one without
# a named grantor all read as "not granted", and the verifier recommends.
#
# A grant merges only a chunk the lane (forge-codex-lane) built. The verifier holds
# any other chunk, a person's above all, for its builder to merge however the board is
# granted (see prejudge-review.sh).
# It does not reach back into a merge already made: revoking stops the NEXT
# merge decision, it cannot recall one in flight.
#
#   grant   <board> --by <actor> [--reason <text>]   write the grant (replaces an earlier one)
#   revoke  <board>                                  delete it; revoking nothing is not an error
#   status  [<board>]                                with a board: is it granted?  without: every grant
#
# Usage:
#   ~/.forge/repo/scripts/merge-authority.sh grant <board> --by <actor> [--reason <text>]
#   ~/.forge/repo/scripts/merge-authority.sh revoke <board>
#   ~/.forge/repo/scripts/merge-authority.sh status [<board>]
#
# Exit: 0 done. `status <board>` is the ONE yes/no test: 0 = granted, 1 = not granted (the answer the verifier would
#         reach). `status` with no board is a LISTING and not a test: it exits 0 once it has listed what is there (no
#         grants at all is 0 too) and 1 only when a file in the grants directory is not a valid grant (printed
#         MALFORMED; it grants nothing).
#       1 also: a write or delete that failed; grant or revoke refused because this is a fenced worker terminal.
#       2 usage: an unknown command, a missing or empty --by, a board that is not a Hermes slug.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || { echo "merge-authority: script directory cannot be resolved" >&2; exit 2; }
# shellcheck source=forge-state.sh
. "$HERE/forge-state.sh" || { echo "merge-authority: cannot source forge-state.sh beside itself" >&2; exit 2; }

usagetext() { awk '/^# Usage:/{u=1; next} u && /^#[ ]*$/{exit} u {sub(/^# ?/, ""); print}' "$0" >&2; }
die()  { echo "merge-authority: $*" >&2; exit 2; }
fail() { echo "merge-authority: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is not on PATH"

CMD="${1:-}"; [ $# -eq 0 ] || shift
BOARD=""; BY=""; REASON=""; HAVE_BY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --by)     [ $# -ge 2 ] || die "--by needs the name of whoever grants this"; BY="$2"; HAVE_BY=1; shift 2;;
    --reason) [ $# -ge 2 ] || die "--reason needs text"; REASON="$2"; shift 2;;
    -h|--help) awk 'NR>2 && /^# ={10,}/{exit} NR>2 {sub(/^# ?/, ""); print}' "$0"; exit 0;;
    -*) die "unknown argument '$1'";;
    *)  [ -z "$BOARD" ] || die "one board at a time: '$BOARD' and '$1'"; BOARD="$1"; shift;;
  esac
done

# GRANTING AND REVOKING ARE THE OPERATOR'S ACTS. A worker's terminal (the lane's, the verifier's, or any shell they
# start) carries HERMES_DELEGATED_CHILD_CONTEXT, and a worker must not be able to give itself authority to merge:
# the verifier's driver reads a PR's text, and text is not an instruction. Like lane-handoff.sh this is the fence's
# own cooperative marker, not confinement (docs/hermes-field-notes.md): it stops a model that tries the obvious
# thing, it does not claim to stop a program written to defeat it. `status` only reads, so it stays open.
case "$CMD" in
  grant|revoke)
    [ -z "${HERMES_DELEGATED_CHILD_CONTEXT:-}" ] \
      || fail "$CMD is the operator's act and this is a fenced worker terminal (HERMES_DELEGATED_CHILD_CONTEXT is set): a worker never grants or withdraws merge authority";;
esac

ROOT="$(forge_merge_authority_root)"

case "$CMD" in
  grant)
    [ -n "$BOARD" ] || die "grant needs a board"
    forge_board_slug_ok "$BOARD" || die "'$BOARD' is not a board slug (Hermes: lowercase letters, digits, - and _, starting with a letter or digit, at most 64)"
    [ "$HAVE_BY" = 1 ] || die "grant needs --by <actor>: an authority nobody is named for cannot be audited"
    forge_merge_authority_text_ok "$BY" 128 || die "--by must be a non-empty name of at most 128 characters with no control characters"
    case "$REASON" in *[[:cntrl:]]*) die "--reason has control characters";; esac
    [ "${#REASON}" -le 500 ] || die "--reason is longer than 500 characters"
    FILE="$(forge_merge_authority_path "$BOARD")"
    [ ! -e "$FILE" ] || [ -f "$FILE" ] || fail "$FILE exists and is not a file; remove it by hand"
    PRIOR=""
    if [ -f "$FILE" ]; then
      if forge_merge_authority_read "$BOARD"; then PRIOR="replaced the grant by $FORGE_MA_BY of $FORGE_MA_AT"; else PRIOR="replaced a file that granted nothing"; fi
    fi
    mkdir -p "$ROOT" || fail "cannot create $ROOT"
    TMP="$(mktemp "$ROOT/.tmp.XXXXXX")" || fail "cannot write under $ROOT"
    if jq -n --arg board "$BOARD" --arg by "$BY" --arg reason "$REASON" \
          --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
          { schema: "forge.merge-authority.v1", board: $board, granted_by: $by,
            granted_at: $at, reason: $reason }' > "$TMP" \
       && mv -f "$TMP" "$FILE"; then
      :
    else
      rm -f "$TMP"
      fail "cannot write $FILE; any earlier grant is untouched"
    fi
    forge_merge_authority_read "$BOARD" || fail "wrote $FILE but it does not read back as a grant"
    echo "granted: the verifier may merge approved PRs on board $BOARD (granted by $FORGE_MA_BY at $FORGE_MA_AT${PRIOR:+; $PRIOR}). Chunks a person built are still yours to merge. Stop it with: merge-authority.sh revoke $BOARD"
    exit 0;;

  revoke)
    [ -n "$BOARD" ] || die "revoke needs a board"
    [ "$HAVE_BY" = 0 ] && [ -z "$REASON" ] || die "revoke takes only a board"
    forge_board_slug_ok "$BOARD" || die "'$BOARD' is not a board slug"
    FILE="$(forge_merge_authority_path "$BOARD")"
    if [ ! -e "$FILE" ] && [ ! -L "$FILE" ]; then
      echo "no grant for board $BOARD: nothing to revoke (the verifier only recommends there)"
      exit 0
    fi
    [ -d "$FILE" ] && [ ! -L "$FILE" ] && fail "$FILE is a directory; remove it by hand"
    rm -f "$FILE" || fail "cannot remove $FILE"
    [ ! -e "$FILE" ] && [ ! -L "$FILE" ] || fail "$FILE is still there"
    echo "revoked: the verifier only recommends on board $BOARD from its next merge decision on (a merge already made is not recalled)"
    exit 0;;

  status)
    [ "$HAVE_BY" = 0 ] && [ -z "$REASON" ] || die "status takes only a board"
    if [ -n "$BOARD" ]; then
      forge_board_slug_ok "$BOARD" || die "'$BOARD' is not a board slug"
      if forge_merge_authority_read "$BOARD"; then
        echo "granted: board $BOARD, by $FORGE_MA_BY at $FORGE_MA_AT${FORGE_MA_REASON:+ — $FORGE_MA_REASON}"
        exit 0
      fi
      echo "not granted: board $BOARD (the verifier only recommends there)"
      exit 1
    fi
    N=0; BAD=0
    for f in "$ROOT"/*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      name="${f##*/}"
      b="${name%.json}"
      if [ "$b" != "$name" ] && forge_merge_authority_read "$b"; then
        N=$((N+1))
        echo "$b — by $FORGE_MA_BY at $FORGE_MA_AT${FORGE_MA_REASON:+ — $FORGE_MA_REASON}"
      else
        BAD=$((BAD+1))
        echo "MALFORMED $f (grants nothing)"
      fi
    done
    [ "$N" -gt 0 ] || [ "$BAD" -gt 0 ] || echo "no board has merge authority"
    [ "$BAD" = 0 ] || exit 1
    exit 0;;

  *) usagetext; die "usage: merge-authority.sh grant|revoke|status ... (see --help)";;
esac
