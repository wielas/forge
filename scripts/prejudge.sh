#!/usr/bin/env bash
# =============================================================================
# forge prejudge — the deterministic HALF of tier 1 (audit F35, ADR-0009).
#
# ADR-0003 says deterministic enforcement lives in the repo, never in a harness
# prompt. §H of the audit is that rule's obituary above L2: eight properties
# that are a regex, an exit code, a set difference or a `jq` predicate, each one
# checked by a language model, in prose, after the fact. This is that rule
# applied to review.
#
# TIER 1 IS TWO STAGES AND THIS IS THE FIRST. A clear result here is not an
# approval: the `forge-prejudge` SOUL runs its `claude -p --model opus` scorer
# afterwards, on exactly the diffs this gate lets through. That model stage is
# NOT deleted and nothing in this file replaces it — ADR-0007 D7.1 stands. What
# this gate does is take the mechanical half of its mandate away, so the two
# stop duplicating (F35's actual thesis), and refuse the obviously-bad work
# before any model is spawned. A blocked PR costs zero driver tokens.
#
# Why the gate blocks and the model does not: the model tier has 0 bounces in 17
# runs, but it was TOLD to pass through — "this tier can only bounce work that is
# obviously bad" — so that number measures a prompt, not a capability. Its fate
# is an experiment, not a conclusion, and it is S5's. What is measured, and all
# that is shipped here, is the severity map below: set by the S3 backtest against
# all 11 PRs of the run that produced the audit, not by a table written first.
#
#   ci-state        block   F5  — absent checks are a block, never a pass
#   branch-name     block   F7  — 6 hits, 4 PRs closed for it alone, one at 3/3/3
#   then-asserts    block   F14 — both shapes are defects on their face
#   scenario-count  block   F13 — ONLY when the PR has FEWER than the contract
#   acceptance-freeze block F14 — implementation cannot rewrite its planning receipt
#   touches         warn    F55 — 3 of 5 drifting paths are undeclarable process docs
#   touches-widened warn    F57 — the head cannot silently expand its own contract
#   size-budget     warn    F53 — fires on 11 of 11; a planning defect, seen late
#   real-source     warn    F53 — fires on 8 of 11, same argument
#
# Usage:
#   ./scripts/prejudge.sh <pr-url|number> [--repo owner/name]
#   ./scripts/prejudge.sh <pr> --json           # the same result, machine-readable
#   ./scripts/prejudge.sh <pr> --wait 300       # seconds to wait for absent CI
#   ./scripts/prejudge.sh --fixture <dir>       # recorded gh, no network (see below)
#
# Exit: 0 clear (warnings do not gate), 1 BLOCK, 2 the gate could not run at all
# (no gh, no PR, no network). 1 and 2 are deliberately different: a block is a
# verdict on the work, a 2 is a fact about the substrate, and conflating them
# would let an outage read as a rejection.
# =============================================================================
set -uo pipefail

PR_ARG=""; REPO=""; FORMAT="text"; WAIT_SECS=180; FIXTURE="${PREJUDGE_FIXTURE:-}"
# Line numbers drift every time this header is edited; these print the block by
# its own markers instead, so `--help` cannot silently start printing code.
helptext() { awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; }
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs owner/name}"; shift 2;;
    --wait) WAIT_SECS="${2:?--wait needs seconds}"; shift 2;;
    --fixture) FIXTURE="${2:?--fixture needs a directory}"; shift 2;;
    --json) FORMAT="json"; shift;;
    -h|--help) helptext; exit 0;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) [ -z "$PR_ARG" ] || { echo "only one PR: got '$PR_ARG' and '$1'" >&2; exit 2; }
       PR_ARG="$1"; shift;;
  esac
done
for tool in jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not on PATH" >&2; exit 2; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forge-prejudge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.tsv"; : > "$RESULTS"
PRJSON="$TMP/pr.json"; NUMSTAT="$TMP/numstat.tsv"
TREE="$TMP/tree"; BASE_TREE="$TMP/base"

# `skip` is a real outcome and must stay distinguishable from `pass`: a check
# that could not run has not passed. That distinction is the whole of F5 — tier
# 1 read an empty CI rollup as "no CI configured" and approved on absent CI,
# four times, while CI was green on all ten PRs.
#
# The fourth argument is the ACTION, and it is not decoration. The gate's
# findings are copied verbatim into the repair card, so a finding a fresh worker
# cannot execute becomes an unworkable card — that is the bounce contract in
# `rubrics/judge-rubric.md`, and it now binds a program rather than a model.
# `emits-an-action-per-block` in `make verify` holds every blocking check to it.
emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$RESULTS"; }

# ---------------------------------------------------------------------------
# Inputs. Everything below this block reads $PRJSON, $NUMSTAT and $TREE and
# knows nothing about where they came from — which is the seam S3 left open.
#
# Four checks touch GitHub, and S3 covered them with an 11-PR backtest run by
# hand and nothing else. That was defensible while the gate blocked nothing. It
# blocks now, so `--fixture <dir>` replays a RECORDED PR: `pr.json` as `gh pr
# view --json` returned it, `numstat.tsv` as `git diff --numstat base..head`
# printed it, and `tree/` holding the files the checks read. No gh, no git, no
# network. `tree/` is the recorded head tree and `base-tree/` carries the base
# contract used for comparisons that a head-only recording cannot make. `make
# verify`'s prejudge/ group runs the whole gate that way.
# ---------------------------------------------------------------------------
if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE/pr.json" ] || { echo "no $FIXTURE/pr.json" >&2; exit 2; }
  cp "$FIXTURE/pr.json" "$PRJSON"
  cp "$FIXTURE/numstat.tsv" "$NUMSTAT" 2>/dev/null || : > "$NUMSTAT"
  mkdir -p "$TREE"
  [ -d "$FIXTURE/tree" ] && cp -R "$FIXTURE/tree/." "$TREE/"
  [ -d "$FIXTURE/base" ] && { mkdir -p "$BASE_TREE"; cp -R "$FIXTURE/base/." "$BASE_TREE/"; }
  # From the recording's own `url`, never a field added to it: a fixture that
  # carries data `gh pr view` does not return is no longer a recording.
  REPO="${REPO:-$(jq -r '.url | capture("github.com/(?<r>[^/]+/[^/]+)/pull").r' "$PRJSON")}"
  NUM="$(jq -r .number "$PRJSON")"
  WAIT_SECS=0
else
  case "$PR_ARG" in
    https://github.com/*/pull/*)
      REPO="$(printf '%s' "$PR_ARG" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#')"
      NUM="$(printf '%s' "$PR_ARG" | sed -E 's#.*/pull/([0-9]+).*#\1#')";;
    [0-9]*) NUM="$PR_ARG";;
    "") usagetext; exit 2;;
    *) echo "PR must be a number or a github.com pull URL: got '$PR_ARG'" >&2; exit 2;;
  esac
  for tool in gh git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not on PATH" >&2; exit 2; }
  done
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
    [ -n "$REPO" ] || { echo "no --repo given and cwd is not a GitHub repo" >&2; exit 2; }
  fi
  gh pr view "$NUM" --repo "$REPO" --json \
    number,state,title,body,headRefName,headRefOid,baseRefName,baseRefOid,mergedAt,url,additions,deletions,changedFiles,statusCheckRollup \
    > "$PRJSON" 2>"$TMP/gh.log" \
    || { echo "cannot read $REPO#$NUM: $(tail -1 "$TMP/gh.log")" >&2; exit 2; }
fi
q() { jq -r "$1" "$PRJSON"; }

HEAD_REF="$(q .headRefName)"; HEAD_OID="$(q .headRefOid)"
BASE_OID="$(q .baseRefOid)"; PR_URL="$(q .url)"; PR_BODY="$(q '.body // ""')"

# ---------------------------------------------------------------------------
# Most content checks below read the PR's own tree: the contract as it stood on
# this branch is the one the implementer worked against and the reviewer judges.
# Frozen acceptance is the deliberate exception. It reads both the head and the
# PR base, because reading the head's rewritten contract, feature, and receipt
# together is exactly how an implementation PR could approve its own amendment
# (ADR-0014).
#
# The base commit comes from the PR's recorded `baseRefOid`, not from a local
# merge-base against main. Four of that run's PRs were closed unmerged and their
# commits later reached main under a renamed branch, so a local merge-base
# against main resolves to the head itself and every diff measures zero.
# ---------------------------------------------------------------------------
if [ -z "$FIXTURE" ]; then
  CACHE="${TMPDIR:-/tmp}/forge-prejudge-cache/${REPO//\//-}"
  if [ ! -d "$CACHE/.git" ]; then
    mkdir -p "$(dirname "$CACHE")"
    # `gh repo clone`, not `git clone`: a private repo over plain HTTPS prompts
    # for a username on a machine with no credential helper and hangs an
    # unattended run. gh already holds the token that `gh pr view` just used.
    gh repo clone "$REPO" "$CACHE" -- --quiet >/dev/null 2>"$TMP/clone.log" \
      || { echo "cannot clone $REPO: $(tail -1 "$TMP/clone.log")" >&2; exit 2; }
  fi
  G() { git -C "$CACHE" "$@"; }
  G fetch --quiet origin "pull/$NUM/head:refs/prejudge/$NUM" --force 2>/dev/null
  G cat-file -e "$HEAD_OID" 2>/dev/null || { echo "PR head $HEAD_OID not fetchable" >&2; exit 2; }
  G cat-file -e "$BASE_OID" 2>/dev/null || G fetch --quiet origin "$BASE_OID" 2>/dev/null
  G cat-file -e "$BASE_OID" 2>/dev/null \
    || { echo "PR base $BASE_OID not fetchable" >&2; exit 2; }

  mkdir -p "$TREE" "$BASE_TREE"
  G archive "$HEAD_OID" | tar -x -C "$TREE" 2>/dev/null
  G archive "$BASE_OID" | tar -x -C "$BASE_TREE" 2>/dev/null \
    || { echo "cannot read PR base tree $BASE_OID" >&2; exit 2; }
  G diff --numstat "$BASE_OID" "$HEAD_OID" > "$NUMSTAT"
fi
# One recording, two readings: `git diff --numstat` carries the changed paths
# AND the line counts, so `touches` and `size-budget` cannot disagree about what
# the diff was.
changed_paths() { cut -f3 "$NUMSTAT" | sort -u; }

# The chunk id is read from the branch, which is also what check 2 judges. A
# branch that fails the naming rule can still be parsed for its id, and a PR
# with no chunk at all (the planning PR) skips the contract checks rather than
# inventing one.
CHUNK=""
case "$HEAD_REF" in
  chunk/[0-9]*) CHUNK="CHUNK-$(printf '%s' "$HEAD_REF" | sed -E 's#^chunk/([0-9]+).*#\1#')";;
esac
CONTRACT=""
[ -n "$CHUNK" ] && [ -f "$TREE/docs/chunks/$CHUNK.md" ] && CONTRACT="$TREE/docs/chunks/$CHUNK.md"
BASE_CONTRACT=""
if [ -n "$CHUNK" ]; then
  if [ -n "$FIXTURE" ]; then
    [ -f "$FIXTURE/base-tree/docs/chunks/$CHUNK.md" ] \
      && BASE_CONTRACT="$FIXTURE/base-tree/docs/chunks/$CHUNK.md"
  else
    base_contract_file="$TMP/base-tree/docs/chunks/$CHUNK.md"
    mkdir -p "$(dirname "$base_contract_file")"
    if G show "$BASE_OID:docs/chunks/$CHUNK.md" > "$base_contract_file" 2>/dev/null; then
      BASE_CONTRACT="$base_contract_file"
    else
      rm -f "$base_contract_file"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 1. CI state (F5) — and its FOURTH state.
#
# The SOUL enumerates pass/fail/pending and is correct about all three. A
# just-pushed PR returns none of them: it returns an EMPTY ROLLUP, because no
# check has registered yet. Tier 1 read that as "no CI configured" and approved.
# `t_faf57139` ran 07:28-07:32Z; that head's CI run started 07:29:59Z.
#
# Absent checks are wait-then-block, never a pass. The wait is real (--wait,
# default 180s) and the block is what happens when it expires. An unhandled
# state resolved in the unsafe direction is how this failed the first time; the
# safe direction is to refuse.
# ---------------------------------------------------------------------------
ci_state() {
  local n deadline now
  deadline=$(( $(date +%s) + WAIT_SECS ))
  while : ; do
    n="$(jq -r '.statusCheckRollup | length' "$PRJSON")"
    [ "$n" != "0" ] && break
    now="$(date +%s)"
    [ "$now" -ge "$deadline" ] && break
    sleep 10
    gh pr view "$NUM" --repo "$REPO" --json statusCheckRollup > "$TMP/roll.json" 2>/dev/null \
      && jq -s '.[0] * .[1]' "$PRJSON" "$TMP/roll.json" > "$TMP/pr.merged" \
      && mv "$TMP/pr.merged" "$PRJSON"
  done

  if [ "$n" = "0" ]; then
    emit ci-state block "empty statusCheckRollup after ${WAIT_SECS}s — absent CI is not green CI (F5)" \
      "check that .github/workflows/ has a job triggered by 'pull_request' and that it is enabled for this branch; push a commit to re-trigger, then re-run 'make prejudge PR=$NUM'"
    return
  fi
  local bad pending
  bad="$(jq -r '[.statusCheckRollup[] | select((.conclusion // "") | test("FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE")) | .name] | join(", ")' "$PRJSON")"
  pending="$(jq -r '[.statusCheckRollup[] | select((.status // "") != "COMPLETED" and ((.state // "") | test("PENDING|EXPECTED"))) | .name] | join(", ")' "$PRJSON")"
  if [ -n "$bad" ]; then
    emit ci-state block "$n check(s) reported; failing: $bad" \
      "run 'gh run view --repo $REPO --log-failed' for the failing check ($bad), fix the cause, and push to the same branch — do not open a new PR"
  elif [ -n "$pending" ]; then
    emit ci-state block "$n check(s) reported; still pending after ${WAIT_SECS}s: $pending" \
      "wait for $pending to complete and re-run 'make prejudge PR=$NUM'; a pending check is not a green one and this gate will not guess"
  else
    emit ci-state pass "$n check(s), all green: $(jq -r '[.statusCheckRollup[].name] | join(", ")' "$PRJSON")"
  fi
}

# ---------------------------------------------------------------------------
# 2. Branch name (F7) — the flagship counter-example inside the Forge's own
# doctrine. AGENTS.md requires `chunk/<id>-<slug>`; the lane pushed `chunk/1`
# through `chunk/6` every time. CHUNK-1 and CHUNK-2 merged in violation and the
# judge approved anyway; CHUNK-3 to 6 were bounced for it, PRs #4/#6/#8/#10
# closed unmerged, branches recreated, PRs reopened — after implementation,
# prejudge AND tier-2 review had all been paid for. `t_298e46f4` is the purest
# case: verdict `bounce`, dimensions 1-3 scored 3/3/3. The work was exemplary.
# The defect was the branch name. That is a regex, and this is the regex.
# ---------------------------------------------------------------------------
#
# SCOPED TO CHUNK PRs, and this scoping was added AFTER seeing the backtest.
# The first run fired on 7 of the 11 PRs where the contract predicted 6; the
# seventh was #1, `planning/lifecycle`, which is not a chunk and was never meant
# to be. AGENTS.md's rule is "one chunk = one branch = one PR" — it is a rule
# about chunks, and applying it to a planning PR is a category error.
#
# Chunk-ness is read from the TITLE as well as the branch, which is what closes
# the hole that scoping would otherwise open: a chunk pushed to a branch named
# anything at all is still judged, because its title still says `CHUNK-n:`. A
# PR that is neither skips, with the reason named.
#
# The action is the whole point of blocking on this. "branch-name fails" is not
# something a fresh worker can execute; a `git branch -m` line with the real
# slug in it is. The slug is derived from the PR title, which is where the four
# closed-and-recreated PRs got theirs from by hand.
branch_name() {
  local title is_chunk=0 want
  title="$(q .title)"
  case "$HEAD_REF" in chunk/*) is_chunk=1;; esac
  case "$title"    in CHUNK-[0-9]*) is_chunk=1;; esac
  if [ "$is_chunk" = 0 ]; then
    emit branch-name skip "neither the branch nor the title names a chunk; the chunk/<id>-<slug> rule does not apply to $HEAD_REF"
    return
  fi
  # `CHUNK-5: Render and atomically publish …` -> `chunk/5-render-and-atomically`
  local id; id="$(printf '%s' "${CHUNK:-$title}" | sed -E 's/^[^0-9]*([0-9]+).*/\1/')"
  want="chunk/$id-$(printf '%s' "$title" \
      | sed -E 's/^[Cc][Hh][Uu][Nn][Kk]-[0-9]+:?[[:space:]]*//' \
      | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' \
      | cut -d- -f1-3 | sed -E 's/^-+|-+$//g')"
  local act="rename the branch and force-push, keeping the same PR: 'git branch -m $HEAD_REF $want && git push --force-with-lease origin $want'. The slug is derived from the PR title; any lowercase-hyphen slug is fine."
  case "$HEAD_REF" in
    chunk/[0-9]*-*)
      if printf '%s' "$HEAD_REF" | grep -qE '^chunk/[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$'; then
        emit branch-name pass "$HEAD_REF"
      else
        emit branch-name block "$HEAD_REF does not match chunk/<id>-<slug> (slug must be lowercase alphanumeric words separated by single hyphens)" "$act"
      fi;;
    chunk/*)
      emit branch-name block "$HEAD_REF has no <slug> — AGENTS.md requires chunk/<id>-<slug>" "$act";;
    *)
      emit branch-name block "$HEAD_REF does not match chunk/<id>-<slug>" "$act";;
  esac
}

# ---------------------------------------------------------------------------
# 3. Diff paths within the contract's Touches (F8) — ADVISORY, decided by the
# count rather than in advance (F55).
#
# S3 counted the drift across the six chunks and the number chose the policy.
# `touches` warned on 5 of the 10 chunk PRs, but three of the five distinct
# drifting paths are process documents every chunk is REQUIRED to change and no
# contract in the entire run ever listed — `docs/decision-log.md`,
# `docs/ROADMAP.md` — and a fourth is `docs/chunks/*`, the contract recording
# its own amendment. Exactly one of five was real implementation outside its
# plan. So: warn, and exclude the three undeclarable classes from the comparison
# outright. Including a file every chunk must edit and no chunk may declare
# manufactures a finding on every single PR, which is a gate nobody will read.
# ---------------------------------------------------------------------------
# Not a convenience list: each entry is a path the METHODOLOGY obliges a chunk to
# touch and the contract template has no slot to declare. The list itself lives
# in ONE file, because `scripts/roadmap-check.sh` applies the same exemption at
# plan time (ADR-0012) and two copies disagree the first time one is edited.
# shellcheck source=./touches-exempt.sh
#
# Guarded. Under `set -u` a missing file leaves TOUCHES_EXEMPT unbound and
# `touches()` dies mid-run with an unbound-variable error, part-way through a
# gate that has already emitted findings — instead of exiting 2, which is this
# script's code for "the gate could not run at all".
TOUCHES_EXEMPT_FILE="$(dirname "${BASH_SOURCE[0]:-$0}")/touches-exempt.sh"
[ -f "$TOUCHES_EXEMPT_FILE" ] || {
  echo "prejudge: missing $TOUCHES_EXEMPT_FILE — the Touches exemption has one definition and this is it" >&2
  exit 2; }
. "$TOUCHES_EXEMPT_FILE"
contract_touches() {
  grep -m1 -- '- \*\*Touches:\*\*' "$1" \
    | grep -oE '`[^`]+`' | tr -d '`' | sort -u
}
touches() {
  [ -n "$CONTRACT" ] || { emit touches skip "no contract for ${CHUNK:-this branch} in the PR tree"; return; }
  local listed drift changed
  listed="$(contract_touches "$CONTRACT")"
  [ -n "$listed" ] || { emit touches skip "contract $CHUNK.md has no parseable Touches list"; return; }
  changed="$(changed_paths | grep -vE "$TOUCHES_EXEMPT")"
  drift="$(comm -23 <(printf '%s\n' "$changed") <(printf '%s\n' "$listed"))"
  local n; n="$(printf '%s' "$drift" | grep -c . || true)"
  if [ "$n" = 0 ]; then
    emit touches pass "$(printf '%s\n' "$changed" | grep -c .) declarable path(s), all listed in $CHUNK.md"
  else
    emit touches warn "$n path(s) outside Touches: $(printf '%s' "$drift" | tr '\n' ' ' | sed 's/ $//')" \
      "for each path, either add it to Touches in $CHUNK.md in this PR with one line saying why, or revert it — advisory, so it does not gate the merge"
  fi
}

# A head-only contract can certify its own expansion: add a path to `Touches`,
# implement that path, and the ordinary set difference truthfully reports that
# the implementation is inside the (new) declaration. Keep that head reading —
# it is the contract the implementer used — and report the contract change as a
# separate advisory signal by comparing base and head declarations.
touches_widened() {
  [ -n "$CONTRACT" ] \
    || { emit touches-widened skip "no head contract for ${CHUNK:-this branch}; no Touches comparison is possible"; return; }
  [ -n "$BASE_CONTRACT" ] \
    || { emit touches-widened skip "no base contract for $CHUNK at $BASE_OID; no Touches comparison is possible"; return; }

  local head_listed base_listed widened n
  head_listed="$(contract_touches "$CONTRACT")"
  base_listed="$(contract_touches "$BASE_CONTRACT")"
  [ -n "$head_listed" ] \
    || { emit touches-widened skip "head contract $CHUNK.md has no parseable Touches list"; return; }
  [ -n "$base_listed" ] \
    || { emit touches-widened skip "base contract $CHUNK.md has no parseable Touches list"; return; }

  # The same exemption policy as `touches`: process documents mandated by the
  # methodology are not implementation surface, whether they appear in a diff
  # or are newly declared in a contract. Filtering both lists also makes a path
  # removal naturally non-widening: only head-minus-base can warn.
  head_listed="$(printf '%s\n' "$head_listed" | grep -vE "$TOUCHES_EXEMPT")"
  base_listed="$(printf '%s\n' "$base_listed" | grep -vE "$TOUCHES_EXEMPT")"
  widened="$(comm -23 <(printf '%s\n' "$head_listed") <(printf '%s\n' "$base_listed"))"
  n="$(printf '%s' "$widened" | grep -c . || true)"
  if [ "$n" = 0 ]; then
    emit touches-widened pass "head Touches adds no declarable path absent from the base contract"
  else
    emit touches-widened warn "$n path(s) added to Touches on this branch: $(printf '%s' "$widened" | tr '\n' ' ' | sed 's/ $//')" \
      "review each head-only path as a contract amendment; either revert it or record why the implementation branch had to widen its advisory scope"
  fi
}

# ---------------------------------------------------------------------------
# 4. Size budget (F28) — ADVISORY, and demoted after the backtest (F53).
#
# It fires on 11 of 11 PRs of the only real run, the planning PR included at
# 3.6x. Every one of those is correct: six chunks, six violations, mean 4.0x,
# worst 9.3x. The consequence was not predicted — a gate that blocks every PR is
# not a filter either. Blocking on day one, this would have stopped the project
# at PR #2 and never let it resume, because nothing in the run's methodology
# produces a 400-line chunk.
#
# The threshold is not the problem and is deliberately not moved: it is the
# roadmap's own number, and moving it after seeing the data is the error this
# slice exists to avoid. F28 is a PLANNING defect surfaced at review time, and
# review time is the most expensive place to learn that a planner wrote a
# 3,700-line chunk. It belongs at /roadmap, where the contract is still editable
# and no model has been spawned. Moving it there is a planning-layer change and
# is not this slice; it stays here, emitting, at warn. Same for real-source.
#
# EVERY changed line counts, tests and docs included, because that is what the
# roadmap rule says: "<= ~400 lines changed INCLUDING tests and doc updates".
# A per-category exemption is a silent route around the gate, pre-installed.
# `size-exception: <reason>` in the PR body is the only override, which turns an
# overrun into a recorded decision — which is what F28 actually asks for.
# ---------------------------------------------------------------------------
size_budget() {
  local budget=400 add del files total exc
  if [ -n "$CONTRACT" ] && grep -qE '^size-budget: [0-9]+' "$CONTRACT"; then
    budget="$(grep -oE '^size-budget: [0-9]+' "$CONTRACT" | head -1 | awk '{print $2}')"
  fi
  read -r add del files <<< "$(awk '{a+=$1; d+=$2; f++} END {printf "%d %d %d", a, d, f}' "$NUMSTAT")"
  total=$(( add + del ))
  exc="$(printf '%s' "$PR_BODY" | grep -m1 -iE '^size-exception: *[^ ]' || true)"
  if [ "$total" -le "$budget" ]; then
    emit size-budget pass "$total lines changed (+$add/-$del) across $files file(s), budget $budget"
  elif [ -n "$exc" ]; then
    emit size-budget pass "$total lines changed, ${budget} budget — recorded exception in the PR body: $(printf '%s' "$exc" | cut -c1-90)"
  else
    emit size-budget warn "$total lines changed (+$add/-$del) across $files file(s) — $(awk -v t="$total" -v b="$budget" 'BEGIN{printf "%.1f", t/b}')x the $budget budget, and no 'size-exception:' line in the PR body" \
      "either split the remaining work into a follow-up chunk, or add one line 'size-exception: <reason>' to the PR body so the overrun is a recorded decision rather than a drift"
  fi
}

# ---------------------------------------------------------------------------
# `parents-merged` WAS check 5 and is DELETED here, not demoted (F52).
#
# It returned pass on all 11 PRs, and the reason is structural rather than
# lucky: by the time a PR exists, the parent has merged — the lane cannot open a
# PR before it has done the work, and it cannot do the work until it is
# unblocked. F10's waste is five spawned workers that discover they cannot work,
# and every one of them dies BEFORE any PR exists. A prejudge gate runs on a PR.
# It is structurally incapable of preventing F10.
#
# F35's fix table files it under tier-1 review; F10's own fix text calls it a
# dispatcher fix — "make the card-level dependency edge resolve on
# parent-PR-merged rather than parent-card-done" — and F10 is the one that is
# right. Keeping a check here that cannot ever fire would let this gate claim
# recall it does not have. The dispatcher edge is F10's, and it is not this
# slice's.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 5. Every Then step asserts on a value (F14) — the most-cited defect in every
# chunk, and cited by the HUMAN tier every time. The implementer writes the
# scenarios, marks them green and self-reports coverage; tier 1 approves 3/3;
# only tier 2 reads the steps. See scripts/prejudge-steps.py for what this can
# and cannot decide — it is a floor, not a ceiling.
# ---------------------------------------------------------------------------
then_asserts() {
  [ -d "$TREE/tests" ] || { emit then-asserts skip "no tests/ directory in the PR tree"; return; }
  local out; out="$(python3 "$(dirname "${BASH_SOURCE[0]:-$0}")/prejudge-steps.py" "$TREE/tests" 2>/dev/null)"
  [ -n "$out" ] || { emit then-asserts skip "the AST walker produced no output"; return; }
  local steps n files
  steps="$(printf '%s' "$out" | jq -r .then_steps)"
  n="$(printf '%s' "$out" | jq -r '.offenders | length')"
  files="$(printf '%s' "$out" | jq -r .files)"
  # A walk that examined no Then step has not cleared one, and saying `pass`
  # here would be F5's mistake in a new place: an absent signal read as a good
  # one. Found by running this gate against a recorded tree that carries feature
  # files and no Python — it reported `pass`, having looked at nothing.
  if [ "$n" = 0 ] && [ "$steps" = 0 ]; then
    emit then-asserts skip "$files python file(s) in tests/, no @then step among them — nothing to clear"
  elif [ "$n" = 0 ]; then
    emit then-asserts pass "$steps Then step(s), every one asserts; no tautological comparison in tests/"
  else
    # The action is per-offender and names the file and line, because that is
    # what F54 proves is missing: tier 2 cited `tests/test_render.py:198-200` by
    # line, bounced, accepted a fix delivered elsewhere, and the cited line is
    # still on main today at :259. A finding that names a file:line is checkable
    # at the next push for nothing, and nothing checked it.
    emit then-asserts block "$steps Then step(s), $n defect(s): $(printf '%s' "$out" \
      | jq -r '[.offenders[] | "\(.file|sub("^.*/tree/";""))':'\(.line) \(.kind)"] | join("; ")' | cut -c1-220)" \
      "$(printf '%s' "$out" | jq -r '[.offenders[] | (.file|sub("^.*/tree/";"")) + ":" + (.line|tostring) + " — " + (if .kind == "tautology" then "both sides of this comparison are the same expression, so it holds however the code behaves: replace one side with an independently computed or literal expected value" elif .kind == "no-assertion" then "this Then step makes no claim at all: add an assert on the value the step names, so the scenario fails when the behaviour breaks" else "unparseable, fix the syntax error" end)] | join(" | ")' | cut -c1-600)"
  fi
}

# ---------------------------------------------------------------------------
# 6. Scenario count matches the contract (F13). Feature files are 10% of their
# step files — a 26-line spec whose meaning is 371 lines of Python the same
# agent wrote. "Scenarios are the living spec" does not hold there, and that is
# the structural reason scenario theater keeps recurring. The contract states
# how many scenarios the chunk has; the feature files either have them or not.
#
# ASYMMETRIC, and the two directions are different findings:
#
#   FEWER than the contract  -> block. That is spec infidelity: scenarios the
#     contract promised and the PR does not have. PR #8 shipped 1 of 5.
#   MORE than the contract   -> warn. That is a planner underestimating, which
#     is the same class as `touches` and `size-budget` — a defect in the plan,
#     surfaced at the most expensive moment. PR #9 shipped 6 of 5, and blocking
#     it would have bounced a PR for doing more testing than it was asked for.
# ---------------------------------------------------------------------------
scenario_count() {
  [ -n "$CONTRACT" ] || { emit scenario-count skip "no contract for ${CHUNK:-this branch} in the PR tree"; return; }
  local want feats got f
  # The bullets under `- **Scenarios:**`, up to the next top-level bullet.
  want="$(awk '/^- \*\*Scenarios:\*\*/{f=1;next} /^- \*\*/{f=0} f && /^  - /{n++} END{print n+0}' "$CONTRACT")"
  feats="$(grep -m1 -- '- \*\*Touches:\*\*' "$CONTRACT" | grep -oE '`[^`]+\.feature`' | tr -d '`')"
  [ "$want" != "0" ] || { emit scenario-count skip "contract $CHUNK.md lists no scenarios"; return; }
  [ -n "$feats" ] || { emit scenario-count skip "contract $CHUNK.md names no .feature file in Touches"; return; }
  got=0
  for f in $feats; do
    [ -f "$TREE/$f" ] || continue
    got=$(( got + $(grep -cE '^[[:space:]]*Scenario( Outline)?:' "$TREE/$f") ))
  done
  local where; where="$(printf '%s' "$feats" | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$want" ]; then
    emit scenario-count pass "$got scenario(s) in $where == $want specified in $CHUNK.md"
  elif [ "$got" -lt "$want" ]; then
    emit scenario-count block "$got scenario(s) in $where but $CHUNK.md specifies $want" \
      "add the $(( want - got )) missing Scenario block(s) to $where so every scenario the contract promises exists and asserts; if the contract is wrong, amend its Scenarios list in this PR and say which scenario was dropped and why"
  else
    emit scenario-count warn "$got scenario(s) in $where, more than the $want specified in $CHUNK.md" \
      "advisory: the plan underestimated. Add the $(( got - want )) extra scenario(s) to the Scenarios list in $CHUNK.md so the contract matches what shipped"
  fi
}

# ---------------------------------------------------------------------------
# 7. A contract naming an external source has a real-source scenario (F25).
# ADVISORY, for F53's reason and not because the finding is weak: it fires on 8
# of 11 and every hit is correct. See the size-budget note above — this is the
# same planning defect surfaced at the same wrong moment, and it belongs at
# /roadmap for the same reason. Demoted, not deleted; the ledger keeps the move.
#
# THIS IS A CONVENTION BEING INTRODUCED, NOT A DEFECT BEING DETECTED. The tag
# does not exist in the repository, so every chunk that names an external source
# fails, and that result is correct: it is F25 restated mechanically, not a
# check that needs tuning until it looks better.
#
# F25 is the audit's highest-value single change. CHUNK-2 built the entire
# Hermes adapter against synthetic fixtures; the real-source check was deferred
# to CHUNK-6's final gate; CHUNK-6 never finished. The one acceptance criterion
# that would have caught F1 — the product cannot read the board that produced it
# — was scheduled last and cut. Nothing ever ran the product against reality.
#
# New plans declare free-text sources and exact scenario indexes. Older recorded
# PRs have no such declaration and are unjudgeable here rather than being
# guessed from a finite vocabulary.
# ---------------------------------------------------------------------------
real_source() {
  [ -n "$CONTRACT" ] || { emit real-source skip "no contract for ${CHUNK:-this branch} in the PR tree"; return; }
  local declaration feature tagged=0
  declaration="$(sed -n 's/^- \*\*Real sources:\*\* //p' "$CONTRACT" | head -1)"
  [ -n "$declaration" ] || {
    emit real-source skip "$CHUNK.md predates the explicit Real sources mapping; do not infer source coverage from prose"
    return
  }
  [ "$declaration" != none ] || {
    emit real-source pass "$CHUNK.md explicitly declares no real sources"
    return
  }
  feature="$(sed -n 's#^- \*\*Acceptance:\*\* `\{0,1\}\([^` ]*\.feature\)`\{0,1\}$#\1#p' \
              "$CONTRACT" | head -1)"
  [ -n "$feature" ] && [ -f "$TREE/$feature" ] \
    && grep -qE '^[[:space:]]*@([^[:space:]]+[[:space:]]+)*@?real-source([[:space:]]|$)' \
         "$TREE/$feature" && tagged=1
  if [ "$tagged" = 1 ]; then
    emit real-source pass "declares $declaration and $feature carries the mapped @real-source scenario(s)"
  else
    emit real-source warn "$CHUNK.md declares $declaration but $feature carries no @real-source scenario" \
      "restore the mapped @real-source tag in $feature; if the mapping is wrong, amend contract, feature, and manifest together in a separate planning PR"
  fi
}

# ---------------------------------------------------------------------------
# 8. Frozen acceptance is compared to the approved PR BASE (F14, F25, F53).
#
# The head manifest is not an authority. Comparing a head feature only to the
# head's digest lets an implementation rewrite its contract, feature, and
# receipt together and approve itself. The separate planning PR is the
# amendment mechanism: it changes all three on the base first, and a later
# chunk branch consumes those already-approved semantics and bytes. Old
# projects with no base manifest have not adopted ADR-0014, so this check is
# absent rather than claiming a skip or pass over an artifact they do not have.
# ---------------------------------------------------------------------------
frozen_acceptance() {
  local base_manifest="$BASE_TREE/docs/chunks/contract-freeze.json"
  [ -f "$base_manifest" ] || return
  if [ -z "$CHUNK" ]; then
    emit acceptance-freeze skip \
      "planning PR: no chunk branch, so contract, feature, and manifest may be amended together for later implementations"
    return
  fi

  local checker="$(dirname "${BASH_SOURCE[0]:-$0}")/acceptance-freeze.sh"
  [ -x "$checker" ] || {
    echo "prejudge: missing executable $checker — frozen acceptance could not be checked" >&2
    exit 2
  }

  local out rc evidence
  out="$("$checker" --check-base "$BASE_TREE" "$TREE" 2>&1)"; rc=$?
  evidence="$(printf '%s' "$out" | tr '\n\t' '  ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-700)"
  case "$rc" in
    0)
      emit acceptance-freeze pass "$evidence";;
    1)
      emit acceptance-freeze block "$evidence" \
        "restore the contract acceptance fields, feature, and docs/chunks/contract-freeze.json to the PR base; if acceptance genuinely changed, open a separate human planning PR that updates the contract, feature, and regenerated manifest together, merge it, then start the implementation branch from that approved hash";;
    *)
      echo "prejudge: frozen acceptance check could not run: ${evidence:-no diagnostic}" >&2
      exit 2;;
  esac
}

ci_state; branch_name; touches; touches_widened; size_budget
then_asserts; scenario_count; real_source; frozen_acceptance

# ---------------------------------------------------------------------------
# `forge.gate.v1` — a real metadata schema, flat, with the schema key inside it
# (rubrics/kanban-metadata-schema.md). It is deliberately NOT `forge.judge.v1`.
#
# The SOUL used to manufacture a `ci-red` bounce as a six-dimension verdict with
# every score zeroed. Extending that here would invent five numbers to say "the
# branch name is wrong", which is the argument the SOUL already accepts for cost
# — "a zeroed cost object is an invented number wearing a measurement's
# clothes" — applied to scores instead. And a gate block at zero tokens is not
# the same event as a tier-2 bounce after a full review: averaging them into one
# bounce rate destroys the signal this whole audit is built on. So the gate
# reports checks, `/retro` counts them separately (scripts/metrics.sh), and the
# `ci-red` zeroed-verdict sentinel is retired — CI is a gate check now.
# ---------------------------------------------------------------------------
JSON="$(jq -Rs --arg pr "$PR_URL" --arg repo "$REPO" --arg num "$NUM" \
   --arg chunk "$CHUNK" --arg branch "$HEAD_REF" --arg head "$HEAD_OID" --arg base "$BASE_OID" '
  split("\n") | map(select(length>0) | split("\t")
                    | {id:.[0], status:.[1], evidence:.[2],
                       action:(if (.[3] // "") == "" then null else .[3] end)})
  | { schema: "forge.gate.v1", gate: "forge-prejudge-gate",
      pr: $pr, repo: $repo, number: ($num|tonumber), chunk: (if $chunk=="" then null else $chunk end),
      branch: $branch, head: $head, base: $base,
      checks: .,
      counts: (reduce .[] as $c ({pass:0,block:0,warn:0,skip:0}; .[$c.status] += 1)),
      blocks: [.[] | select(.status=="block") | .id],
      result: (if any(.[]; .status=="block") then "block" else "clear" end) }' "$RESULTS")"

case "$FORMAT" in
json) printf '%s\n' "$JSON";;
text)
  printf '%s' "$JSON" | jq -r '
    "forge prejudge — \(.repo)#\(.number)  \(.chunk // "(no chunk)")  \(.branch)",
    "",
    (.checks[] | "  \(.status | ascii_upcase | (. + "     ")[0:6]) \(.id)\n         \(.evidence)"
                 + (if .action == null then "" else "\n      -> \(.action)" end)),
    "",
    "  \(.result | ascii_upcase)  — \(.counts.pass) pass, \(.counts.block) block, \(.counts.warn) warn, \(.counts.skip) skip"';;
esac

# The gate blocks. Warnings are advisory by construction and do not reach here.
[ "$(printf '%s' "$JSON" | jq -r .result)" = "block" ] && exit 1
exit 0
