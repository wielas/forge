#!/usr/bin/env bash
# =============================================================================
# forge amend-contract — a frozen contract changes in three places or in none
# (epic MS5, S8c).
#
# A verifier finding like CHUNK-8's "fix the contract, not the PR", and a probe
# defect the checkpoint drafts as an amendment, need a path that does not leave
# the plan half-changed. A contract is three things that must agree:
#
#   the contract       docs/chunks/<ID>.md, tests/features/*.feature, or a
#                      probe under tests/probes/ (the files named with --set)
#   its freeze         docs/chunks/contract-freeze.json, rewritten by the real
#                      scripts/acceptance-freeze.sh
#   the decision entry one dated line appended to docs/decision-log.md
#
# ATOMIC, and the order is what makes it so:
#   1. STAGE  copy docs/chunks, tests/features, tests/probes and the decision
#             log to a private directory; apply the changes there; run the real
#             acceptance-freeze on the copy; append the decision entry to the
#             copy. A contract that does not freeze (exit 1 or 2) stops here, and
#             nothing in the project has been touched.
#   2. BACKUP every file step 3 will replace (or note that it is new).
#   3. INSTALL each staged file with a same-directory rename: the contract, then
#             contract-freeze.json, then the decision log LAST. If any install
#             fails, every file already installed is put back from step 2 and
#             the new ones are removed, and the exit is 1 with the project as it
#             was. If a put-back itself fails the exit is 3 and the message says
#             which file to restore by hand: the one outcome this cannot rule
#             out, and it is never reported as anything else.
# `make verify` (triage/amendment-is-atomic) fails each step in turn, with real
# failures (an invalid feature, a read-only directory under each install), and
# hashes the contract, the freeze and the decision log before and after.
#
# OUT OF SCOPE, and said here because nothing can assert it from here
# (ADR-0003): the Hermes card body of the chunk still carries the old contract
# text. This changes the product repository's working tree only; committing it
# is the caller's, and a card is updated with `hermes kanban edit` by the
# operator. The amendment is shown at the checkpoint (scripts/checkpoint.sh
# prints this command in its amendment draft).
#
# MODES, one of which is required: --rehearse stages, freezes the copy and
# prints what --apply would install, and writes nothing; --apply installs.
#
# Usage:
#   ./scripts/amend-contract.sh <project-dir> --id <CHUNK-n|GATE-m> --set <path>=<source-file> [--set ...]
#                               --reason <text> [--actor <name>] (--rehearse|--apply)
#   <path> is relative to the project and is one of: docs/chunks/<CHUNK|GATE>-*.md,
#   tests/features/*.feature, tests/probes/** (no '..', no symlink).
# Exit: 0 amended (or, with --rehearse, would amend), 1 refused: nothing changed,
#       2 could not run, 3 an install failed AND the put-back failed.
# =============================================================================
set -uo pipefail

helptext() { awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; }
usagetext() { awk '/^# Usage:/{u=1} u && /^# Exit:/{exit} u' "$0"; }

_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in /*) _self="$_link";; *) _self="$(dirname "$_self")/$_link";; esac
done
HERE="$(cd "$(dirname "$_self")" 2>/dev/null && pwd -P)" \
  || { echo "amend-contract: script directory cannot be resolved" >&2; exit 2; }

PROJECT=""; ID=""; REASON=""; ACTOR="forge-overseer"; MODE=""
SETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --id)     [ $# -ge 2 ] || { echo "amend-contract: --id needs CHUNK-<n> or GATE-<m>" >&2; exit 2; }; ID="$2"; shift 2;;
    --set)    [ $# -ge 2 ] || { echo "amend-contract: --set needs <path>=<source-file>" >&2; exit 2; }; SETS+=("$2"); shift 2;;
    --reason) [ $# -ge 2 ] || { echo "amend-contract: --reason needs text" >&2; exit 2; }; REASON="$2"; shift 2;;
    --actor)  [ $# -ge 2 ] || { echo "amend-contract: --actor needs a name" >&2; exit 2; }; ACTOR="$2"; shift 2;;
    --rehearse)
      [ "$MODE" != apply ] || { echo "amend-contract: --rehearse and --apply are exclusive" >&2; exit 2; }
      MODE=rehearse; shift;;
    --apply)
      [ "$MODE" != rehearse ] || { echo "amend-contract: --rehearse and --apply are exclusive" >&2; exit 2; }
      MODE=apply; shift;;
    -h|--help) helptext; exit 0;;
    -*) echo "amend-contract: unknown argument: $1" >&2; exit 2;;
    *) [ -z "$PROJECT" ] || { echo "amend-contract: unexpected argument: $1" >&2; exit 2; }
       PROJECT="$1"; shift;;
  esac
done

[ -n "$PROJECT" ] && [ -n "$ID" ] && [ "${#SETS[@]}" -gt 0 ] && [ -n "$REASON" ] || { usagetext >&2; exit 2; }
[ -n "$MODE" ] || { echo "amend-contract: say --rehearse (writes nothing) or --apply (installs the amendment)" >&2; exit 2; }
[ -d "$PROJECT" ] || { echo "amend-contract: no such project directory: $PROJECT" >&2; exit 2; }
id_re='^(CHUNK|GATE)-[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ $ID =~ $id_re ]] || { echo "amend-contract: '$ID' is not a CHUNK-<n> or GATE-<m> id" >&2; exit 2; }
name_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ $ACTOR =~ $name_re ]] || { echo "amend-contract: '$ACTOR' is not an actor name" >&2; exit 2; }
REASON="$(printf '%s' "$REASON" | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//')"
[ -n "$REASON" ] || { echo "amend-contract: --reason must not be empty" >&2; exit 2; }
command -v shasum >/dev/null 2>&1 || { echo "amend-contract: shasum is not on PATH" >&2; exit 2; }
PROJECT="$(cd "$PROJECT" && pwd -P)"

FREEZE_REL="docs/chunks/contract-freeze.json"
LOG_REL="docs/decision-log.md"
[ -f "$PROJECT/$FREEZE_REL" ] || { echo "amend-contract: $PROJECT has no $FREEZE_REL, so nothing is frozen to amend; run scripts/acceptance-freeze.sh first" >&2; exit 2; }
[ -f "$PROJECT/$LOG_REL" ] || { echo "amend-contract: $PROJECT has no $LOG_REL to record the decision in" >&2; exit 2; }

# ---- the paths the caller may change ----------------------------------------
path_ok() { # $1=relative path
  case "$1" in /*|*..*|*//*) return 1;; esac
  case "$1" in
    docs/chunks/CHUNK-*.md|docs/chunks/GATE-*.md) [[ $1 =~ ^docs/chunks/(CHUNK|GATE)-[A-Za-z0-9._-]+\.md$ ]];;
    tests/features/*.feature) [[ $1 =~ ^tests/features/[A-Za-z0-9._-]+\.feature$ ]];;
    tests/probes/*) [[ $1 =~ ^tests/probes/[A-Za-z0-9._/-]+$ ]];;
    *) return 1;;
  esac
}
RELS=(); SRCS=()
for s in "${SETS[@]}"; do
  rel="${s%%=*}"; src="${s#*=}"
  [ "$rel" != "$s" ] && [ -n "$rel" ] && [ -n "$src" ] || { echo "amend-contract: --set '$s' is not <path>=<source-file>" >&2; exit 2; }
  path_ok "$rel" || { echo "amend-contract: refused: '$rel' is not a contract path (docs/chunks/<CHUNK|GATE>-*.md, tests/features/*.feature, tests/probes/**)" >&2; exit 1; }
  [ -f "$src" ] && [ ! -L "$src" ] || { echo "amend-contract: source '$src' for $rel is not a regular file" >&2; exit 2; }
  # a symlink anywhere on the target path would let an install write outside the project
  walk="$PROJECT"
  IFS='/' read -r -a parts <<< "$rel"
  for part in "${parts[@]}"; do
    walk="$walk/$part"
    [ ! -L "$walk" ] || { echo "amend-contract: refused: $rel passes through the symlink $walk" >&2; exit 1; }
  done
  RELS+=("$rel"); SRCS+=("$src")
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-amend.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"; BACKUP="$WORK/backup"
mkdir -p "$STAGE" "$BACKUP" || exit 2

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# ---- 1. STAGE ---------------------------------------------------------------
for d in docs/chunks tests/features tests/probes; do
  if [ -d "$PROJECT/$d" ]; then mkdir -p "$STAGE/$d"; cp -R "$PROJECT/$d/." "$STAGE/$d/" || { echo "amend-contract: could not stage $d" >&2; exit 2; }; fi
done
mkdir -p "$STAGE/docs"; cp "$PROJECT/$LOG_REL" "$STAGE/$LOG_REL" || { echo "amend-contract: could not stage the decision log" >&2; exit 2; }
for i in "${!RELS[@]}"; do
  mkdir -p "$(dirname "$STAGE/${RELS[$i]}")" && cp "${SRCS[$i]}" "$STAGE/${RELS[$i]}" \
    || { echo "amend-contract: could not stage ${RELS[$i]}" >&2; exit 2; }
done
"$HERE/acceptance-freeze.sh" "$STAGE" >"$WORK/freeze.out" 2>"$WORK/freeze.err"; frc=$?
if [ "$frc" != 0 ]; then
  echo "amend-contract: refused: the amended contract does not freeze (acceptance-freeze exit $frc): $(tail -n 3 "$WORK/freeze.err" | tr '\n' ' ')" >&2
  echo "amend-contract: nothing in $PROJECT was touched" >&2
  [ "$frc" = 1 ] && exit 1 || exit 2
fi
new_freeze="$(sha "$STAGE/$FREEZE_REL")"
entry="$(date +%Y-%m-%d) $ID: AMENDMENT by $ACTOR — $REASON. Re-frozen: ${RELS[*]}; $FREEZE_REL is now ${new_freeze:0:12}."
[ -z "$(tail -c1 "$STAGE/$LOG_REL")" ] || printf '\n' >> "$STAGE/$LOG_REL"
printf '%s\n' "$entry" >> "$STAGE/$LOG_REL"

# What step 3 installs, in order: the contract, its freeze, the decision log last.
INSTALL=("${RELS[@]}" "$FREEZE_REL" "$LOG_REL")

if [ "$MODE" = rehearse ]; then
  echo "amend-contract $ID — REHEARSAL: the amended contract freezes; nothing was written to $PROJECT"
  printf '  would install: %s\n' "${INSTALL[@]}"
  echo "  decision entry: $entry"
  exit 0
fi

# ---- 2. BACKUP --------------------------------------------------------------
for rel in "${INSTALL[@]}"; do
  mkdir -p "$(dirname "$BACKUP/$rel")"
  if [ -f "$PROJECT/$rel" ]; then cp -p "$PROJECT/$rel" "$BACKUP/$rel" || { echo "amend-contract: could not back up $rel; nothing was changed" >&2; exit 2; }
  else : > "$BACKUP/$rel.absent"; fi
done

# ---- 3. INSTALL, with put-back ----------------------------------------------
INSTALLED=()
putback() {
  local rel bad=0
  for rel in ${INSTALLED[@]+"${INSTALLED[@]}"}; do
    if [ -f "$BACKUP/$rel.absent" ]; then
      rm -f "$PROJECT/$rel" || { echo "amend-contract: PUT-BACK FAILED: could not remove the new file $PROJECT/$rel" >&2; bad=1; }
    else
      { cp -p "$BACKUP/$rel" "$PROJECT/$rel.putback.$$" && mv -f "$PROJECT/$rel.putback.$$" "$PROJECT/$rel"; } \
        || { echo "amend-contract: PUT-BACK FAILED: restore $PROJECT/$rel from $BACKUP/$rel by hand" >&2; bad=1; rm -f "$PROJECT/$rel.putback.$$"; }
    fi
  done
  return $bad
}
for rel in "${INSTALL[@]}"; do
  if { cp "$STAGE/$rel" "$PROJECT/$rel.amend.$$" && mv -f "$PROJECT/$rel.amend.$$" "$PROJECT/$rel"; }; then
    INSTALLED+=("$rel")
  else
    rm -f "$PROJECT/$rel.amend.$$"
    echo "amend-contract: installing $rel failed; putting back the ${#INSTALLED[@]} file(s) already installed" >&2
    if putback; then
      echo "amend-contract: refused: $PROJECT is as it was (the contract, its freeze and the decision log are unchanged)" >&2
      exit 1
    fi
    echo "amend-contract: the project is NOT as it was; the backup is kept at $BACKUP" >&2
    trap - EXIT
    exit 3
  fi
done

echo "amend-contract $ID — amended: ${INSTALL[*]}"
echo "  decision entry: $entry"
exit 0
