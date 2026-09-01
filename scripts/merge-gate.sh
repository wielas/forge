#!/usr/bin/env bash
# =============================================================================
# forge merge-gate — ask GitHub whether a branch is actually gated.
#
# F79 recorded that three documents called branch protection "the merge gate"
# while this repository had none. The first executable answer to that (landed in
# PR #25) asked only `repos/{slug}/rulesets`, and got four things wrong at once:
# it crashed under `set -u` before it could report anything, it FAILED a repo
# protected the classic way, it reported "gated" for a ruleset that permits
# direct pushes, and it counted rules belonging to other branches.
#
# GITHUB HAS TWO MECHANISMS AND THEY ARE INDEPENDENT.
#
#   rulesets    repos/{slug}/rulesets            — the modern one
#   classic     repos/{slug}/branches/{b}/protection — what `make protect` creates
#
# `templates/python-service/template/Makefile`'s `protect` target issues
# `PUT /branches/main/protection`, so every project the Forge stamps is gated the
# CLASSIC way and carries ZERO rulesets. A rulesets-only check reports those as
# ungated. `wielas/forgeboard-report` — the repo `docs/state.md` cites as the
# proof that branch protection works — is exactly that shape. The gate is the
# UNION of the two; absence of one says nothing.
#
# A RULE IS ONLY A GATE IF IT APPLIES TO THE BRANCH. Rulesets carry
# `conditions.ref_name.include/exclude`, and a ruleset scoped to `release/*` says
# nothing about `main`. Rules are therefore collected PER RULESET and only from
# rulesets whose conditions actually select the branch, rather than flattened
# into one blob.
#
# REQUIRING A PR AND REQUIRING CHECKS ARE DIFFERENT QUESTIONS, and answering one
# does not answer the other:
#
#   PR required, no checks     a red PR is mergeable
#   checks required, no PR     a direct push to main bypasses them entirely
#
# Both are "the gate exists and does not gate", both exit 3, and neither may be
# reported by testing the other.
#
# Usage:
#   scripts/merge-gate.sh <owner/repo> [--branch <name>] [--require ctx,ctx]
#
# stdout is ONE machine-readable line, and nothing else can reach it (fd 1 is
# pointed at stderr for the body; the real stdout is held on fd 3):
#
#   <verdict> via=<mechanisms> pr=<yes|no> checks=<ctx,ctx|none> missing=<ctx|->
#
# Exit codes — 2 is deliberately NOT a synonym for "ungated":
#   0  GATED        a PR is required AND checks are required AND --require is met
#   3  PARTIAL      a rule exists but does not gate (see the two shapes above)
#   4  NONE         no applicable rule from either mechanism
#   5  UNAVAILABLE  GitHub reports the feature does not exist for this repository
#   2  UNKNOWN      the question could not be asked (no gh, no jq, 403, no repo)
#
# F5/F65: a control that could not run has NOT passed. Every "could not ask"
# path exits 2 so a caller cannot mistake it for either an answer or a failure.
#
# 5 IS AN ANSWER, NOT A FAILURE TO ASK, and that distinction is the whole of
# ADR-0017. Branch protection and rulesets are PAID features. On a private
# repository on a free plan BOTH endpoints return 403 carrying GitHub's own
# sentence (measured against wielas/JobApp, 2026-09-01):
#
#   gh: Upgrade to GitHub Pro or make this repository public to enable this
#       feature. (HTTP 403)
#
# That is not "we lack permission to look". It is "no such feature here", so no
# configuration can produce a gate and there is nothing to miss. Reporting it as
# 2 made `make commission` refuse every private product outright — F120.
#
# THE RULE IS A CONJUNCTION, because the discriminator is a GitHub-owned prose
# string and this repo's recurring defect is a check anchored to content that
# moves (F65/F66):
#
#   repos/{slug} readable  AND  .private == true
#     AND the rulesets 403 carries the sentinel
#     AND the classic-protection 403 carries the sentinel        -> 5
#
# ANYTHING LESS IS 2. A generic 403 ("Must have admin"), the sentinel on a repo
# GitHub says is public, and one mechanism unavailable while the other answers
# are all incoherent, and incoherent is UNKNOWN.
#
# THE DEGRADE DIRECTION IS DELIBERATE. If GitHub rewords that sentence this
# collapses to 2, and 2 still refuses commissioning. Losing the escape hatch is
# safe; granting it wrongly is not.
# =============================================================================
set -uo pipefail

exec 3>&1 1>&2

help_text() {
  awk 'NR==1 { next }
       /^# ={10,}/ { if (seen) exit; seen=1; next }
       seen { sub(/^#[ ]?/, ""); print }' "$0"
}

SLUG=""; BRANCH=""; REQUIRE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) help_text >&3; exit 0;;
    --branch)  [ $# -ge 2 ] || { echo "merge-gate: --branch needs a value"; exit 2; }
               BRANCH="$2"; shift 2;;
    --require) [ $# -ge 2 ] || { echo "merge-gate: --require needs a value"; exit 2; }
               REQUIRE="$2"; shift 2;;
    -*) echo "merge-gate: unknown flag: $1"; exit 2;;
    *)  [ -z "$SLUG" ] || { echo "merge-gate: one repository at a time"; exit 2; }
        SLUG="$1"; shift;;
  esac
done

[ -n "$SLUG" ] || { echo "usage: merge-gate.sh <owner/repo> [--branch <name>] [--require ctx,ctx]"; exit 2; }

# `owner/repo` and nothing else. A remote this script cannot parse used to be
# passed through verbatim, so `ssh://git@github.com/o/r` became a slug, every
# API call 404'd, and the operator was told they had a permissions problem. A
# malformed slug is a malformed slug and says so.
case "$SLUG" in
  */*/*|/*|*/) echo "merge-gate: '$SLUG' is not an owner/repo slug"; exit 2;;
  */*) ;;
  *)   echo "merge-gate: '$SLUG' is not an owner/repo slug"; exit 2;;
esac

command -v gh >/dev/null 2>&1 || { echo "merge-gate: gh is not on PATH"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "merge-gate: jq is not on PATH"; exit 2; }

# The default branch is needed to resolve `~DEFAULT_BRANCH`, which is how GitHub
# writes "main" in a ruleset condition and is what this repo's own ruleset uses.
REPO_JSON="$(gh api "repos/$SLUG" 2>/dev/null)" || REPO_JSON=""
[ -n "$REPO_JSON" ] || { echo "merge-gate: cannot read repos/$SLUG (no such repo, or no access)"; exit 2; }
DEFAULT_BRANCH="$(printf '%s' "$REPO_JSON" | jq -r '.default_branch // empty' 2>/dev/null)"
[ -n "$DEFAULT_BRANCH" ] || { echo "merge-gate: repos/$SLUG returned no default_branch"; exit 2; }
[ -n "$BRANCH" ] || BRANCH="$DEFAULT_BRANCH"

# Read off the response already in hand rather than paying for a second call.
# Empty (absent key) is not "false" and is not "true" — every comparison below
# is against the literal string `true`, so an absent key can never satisfy one.
PRIVATE="$(printf '%s' "$REPO_JSON" | jq -r '.private // empty' 2>/dev/null)"

# Does a ruleset condition select $BRANCH? `include` may name the branch, a
# glob, `~ALL`, or `~DEFAULT_BRANCH`; `exclude` wins over `include`.
ref_matches() {
  local pat="$1" ref="refs/heads/$BRANCH"
  case "$pat" in
    '~ALL') return 0;;
    '~DEFAULT_BRANCH') [ "$BRANCH" = "$DEFAULT_BRANCH" ] && return 0; return 1;;
  esac
  # shellcheck disable=SC2254
  case "$ref" in $pat) return 0;; esac
  return 1
}

applies() { # stdin: the ruleset's conditions.ref_name as compact json
  local cond="$1" pat
  # A ruleset with no ref_name condition applies to the whole target.
  [ -n "$cond" ] && [ "$cond" != "null" ] || return 0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    ref_matches "$pat" && return 1
  done <<EOF
$(printf '%s' "$cond" | jq -r '.exclude[]?' 2>/dev/null)
EOF
  local any_include=0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    any_include=1
    ref_matches "$pat" && return 0
  done <<EOF
$(printf '%s' "$cond" | jq -r '.include[]?' 2>/dev/null)
EOF
  [ "$any_include" = 0 ] && return 0
  return 1
}

HAS_PR=0; HAS_CHECKS=0; CONTEXTS=""; VIA=""

# ---- rulesets ---------------------------------------------------------------
# `--paginate`: a repo with more than one page of rulesets used to have only its
# first page evaluated. `enforcement` is already on the list response, so
# inactive and evaluate-mode rulesets are dropped BEFORE a detail call is made
# rather than after — one round trip each, on a path that runs before every
# unattended night run.
#
# A 403 here is F79's ORIGINAL condition — private repo on a free plan — and the
# answer to it is "not asked", never "not gated". One call, and its result is
# reused; asking twice to get a status and a payload is how the first version
# paid for every page twice.
# `gh` writes BOTH its own one-line summary and the raw JSON body to stderr on a
# 403, so either form carries the sentence; the match is on the message rather
# than on the status, because 403 alone is ambiguous (see the header).
upgrade_403() { # $1=path to captured stderr
  grep -q 'Upgrade to GitHub Pro' "$1" 2>/dev/null
}

UNAVAIL_RULESETS=0
UNAVAIL_CLASSIC=0

RS_ERR="$(mktemp "${TMPDIR:-/tmp}/merge-gate.XXXXXX")"
RS_RAW="$(gh api --paginate "repos/$SLUG/rulesets" 2>"$RS_ERR")"
RS_RC=$?
if [ "$RS_RC" -ne 0 ]; then
  # ORDER MATTERS. The sentinel test runs BEFORE the generic refusal below; the
  # other way round this arm swallows the paid-feature answer and exit 5 is
  # unreachable. This call used to discard stderr entirely, which is why it
  # could not tell the two apart at all.
  if [ "$PRIVATE" = true ] && upgrade_403 "$RS_ERR"; then
    UNAVAIL_RULESETS=1
    rm -f "$RS_ERR"
  else
    rm -f "$RS_ERR"
    echo "merge-gate: cannot read rulesets for $SLUG (403, or no access)."
    echo "  A control that could not run has NOT passed (F79). Confirm by hand."
    exit 2
  fi
else
  rm -f "$RS_ERR"
fi
RS_IDS="$(printf '%s' "$RS_RAW" | jq -r '.[] | select(.enforcement=="active") | .id' 2>/dev/null)"

if [ -n "$RS_IDS" ]; then
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    detail="$(gh api "repos/$SLUG/rulesets/$id" 2>/dev/null)" || continue
    [ -n "$detail" ] || continue
    cond="$(printf '%s' "$detail" | jq -c '.conditions.ref_name // null' 2>/dev/null)"
    applies "$cond" || continue
    types="$(printf '%s' "$detail" | jq -r '.rules[]?.type' 2>/dev/null)"
    printf '%s\n' "$types" | grep -qx 'pull_request' && { HAS_PR=1; VIA="rulesets"; }
    ctx="$(printf '%s' "$detail" \
            | jq -r '.rules[]? | select(.type=="required_status_checks")
                     | .parameters.required_status_checks[]?.context' 2>/dev/null)"
    if [ -n "$ctx" ]; then
      HAS_CHECKS=1; VIA="rulesets"
      CONTEXTS="$CONTEXTS
$ctx"
    fi
  done <<EOF
$RS_IDS
EOF
fi

# ---- classic branch protection ---------------------------------------------
# 404 is a real answer ("this branch is not protected"); 403 is not an answer at
# all and must not be read as one. Reading protection needs admin, so a token
# without it produces 403 on a repo that IS protected.
PROT_ERR="$(mktemp "${TMPDIR:-/tmp}/merge-gate.XXXXXX")"
PROT="$(gh api "repos/$SLUG/branches/$BRANCH/protection" 2>"$PROT_ERR")" || PROT=""
if [ -z "$PROT" ]; then
  # Sentinel first here too: the generic 403 grep below would otherwise report
  # GitHub's paid-feature answer to the operator as "needs admin", which is the
  # F79 shape of a parsing bug wearing a permissions problem's clothes.
  if [ "$PRIVATE" = true ] && upgrade_403 "$PROT_ERR"; then
    UNAVAIL_CLASSIC=1
  elif grep -q 'HTTP 403\|Must have admin' "$PROT_ERR" 2>/dev/null; then
    rm -f "$PROT_ERR"
    echo "merge-gate: cannot read classic protection for $SLUG ($BRANCH): needs admin."
    echo "  A control that could not run has NOT passed (F79). Confirm by hand."
    exit 2
  fi
else
  printf '%s' "$PROT" | jq -e '.required_pull_request_reviews != null' >/dev/null 2>&1 \
    && { HAS_PR=1; VIA="${VIA:+$VIA+}classic"; }
  ctx="$(printf '%s' "$PROT" | jq -r '.required_status_checks.contexts[]?' 2>/dev/null)"
  if [ -n "$ctx" ]; then
    HAS_CHECKS=1
    case "$VIA" in *classic*) ;; *) VIA="${VIA:+$VIA+}classic";; esac
    CONTEXTS="$CONTEXTS
$ctx"
  fi
fi
rm -f "$PROT_ERR"

CONTEXTS="$(printf '%s\n' "$CONTEXTS" | grep -v '^$' | sort -u | paste -sd, - 2>/dev/null)"
[ -n "$CONTEXTS" ] || CONTEXTS="none"
[ -n "$VIA" ] || VIA="none"

# The PASS branch used to print "PR + required status checks" without ever
# looking at WHICH checks, so swapping the required contexts for one that never
# runs still passed. --require names them and they are verified by name.
MISSING=""
if [ -n "$REQUIRE" ]; then
  oldifs="$IFS"; IFS=,
  for want in $REQUIRE; do
    [ -n "$want" ] || continue
    printf '%s\n' "$CONTEXTS" | tr ',' '\n' | grep -qx "$want" || MISSING="$MISSING,$want"
  done
  IFS="$oldifs"
fi
MISSING="${MISSING#,}"
[ -n "$MISSING" ] || MISSING="-"

emit() { printf '%s via=%s pr=%s checks=%s missing=%s\n' \
           "$1" "$VIA" "$2" "$CONTEXTS" "$MISSING" >&3; }

# GitHub answered that the feature does not exist here. BOTH arms must say so:
# one mechanism unavailable while the other answered is incoherent, and this
# script does not guess its way out of an incoherent reading (ADR-0017).
if [ "$UNAVAIL_RULESETS" = 1 ] || [ "$UNAVAIL_CLASSIC" = 1 ]; then
  if [ "$UNAVAIL_RULESETS" = 1 ] && [ "$UNAVAIL_CLASSIC" = 1 ]; then
    echo "$SLUG is private on a plan without branch protection: GitHub reports both"
    echo "  rulesets and classic protection unavailable for this repository."
    echo "  NO server-side merge gate can exist here, so none was missed. Make the"
    echo "  repository public, or upgrade the plan. Until then the pre-push hook is"
    echo "  the whole gate, and it is advisory (ADR-0017, F120)."
    emit UNAVAILABLE no; exit 5
  fi
  echo "merge-gate: $SLUG reports one protection mechanism unavailable on this plan"
  echo "  while the other answered. That is incoherent, so the question was NOT"
  echo "  answered (F79). Confirm by hand."
  exit 2
fi

if [ "$HAS_PR" = 0 ] && [ "$HAS_CHECKS" = 0 ]; then
  emit NONE no; exit 4
fi
if [ "$HAS_PR" = 0 ]; then
  echo "$SLUG $BRANCH requires status checks but NOT a pull request: a direct push bypasses them"
  emit PARTIAL no; exit 3
fi
if [ "$HAS_CHECKS" = 0 ]; then
  echo "$SLUG $BRANCH requires a pull request but NO status checks: a red PR is mergeable"
  emit PARTIAL yes; exit 3
fi
if [ "$MISSING" != "-" ]; then
  echo "$SLUG $BRANCH is gated, but these required contexts are missing: $MISSING"
  emit PARTIAL yes; exit 3
fi
emit GATED yes; exit 0
