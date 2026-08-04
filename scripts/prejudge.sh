#!/usr/bin/env bash
# =============================================================================
# forge prejudge — tier 1 as a program (audit F35).
#
# ADR-0003 says deterministic enforcement lives in the repo, never in a harness
# prompt. §H of the audit is that rule's obituary above L2: eight properties
# that are a regex, an exit code, a set difference or a `jq` predicate, each one
# checked by a language model, in prose, after the fact. This is that rule
# applied to review.
#
# Tier 1 costs a full Opus pass and has never bounced anything: 17 runs, 0
# bounces, mean d1-3 ~3.00, against tier 2's 12 bounces and 1.88 on the same
# diffs. It reads the same PR against the same rubric as tier 2, with a narrower
# mandate, so it can only ever duplicate — a second opinion purchased before the
# first one. Everything it is actually mandated to catch is decidable here.
#
# SHADOW MODE. This gates nothing. No lefthook, no CI job, no lane change, no
# SOUL change. It prints a result and exits 0 unless it could not run at all.
# Wiring it into a hook is the gating step, and gating is the next slice.
#
# Usage:
#   ./scripts/prejudge.sh <pr-url|number> [--repo owner/name]
#   ./scripts/prejudge.sh <pr> --json          # the same result, machine-readable
#   ./scripts/prejudge.sh <pr> --wait 300      # seconds to wait for absent CI
#
# Exit: 0 always when the checks ran (shadow mode — read `result`), 2 when the
# gate itself could not run (no gh, no PR, no network).
# =============================================================================
set -uo pipefail

PR_ARG=""; REPO=""; FORMAT="text"; WAIT_SECS=180
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs owner/name}"; shift 2;;
    --wait) WAIT_SECS="${2:?--wait needs seconds}"; shift 2;;
    --json) FORMAT="json"; shift;;
    -h|--help) sed -n '2,28p' "$0"; exit 0;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) [ -z "$PR_ARG" ] || { echo "only one PR: got '$PR_ARG' and '$1'" >&2; exit 2; }
       PR_ARG="$1"; shift;;
  esac
done
[ -n "$PR_ARG" ] || { sed -n '22,27p' "$0"; exit 2; }
for tool in gh jq git python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not on PATH" >&2; exit 2; }
done

case "$PR_ARG" in
  https://github.com/*/pull/*)
    REPO="$(printf '%s' "$PR_ARG" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#')"
    NUM="$(printf '%s' "$PR_ARG" | sed -E 's#.*/pull/([0-9]+).*#\1#')";;
  [0-9]*) NUM="$PR_ARG";;
  *) echo "PR must be a number or a github.com pull URL: got '$PR_ARG'" >&2; exit 2;;
esac
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  [ -n "$REPO" ] || { echo "no --repo given and cwd is not a GitHub repo" >&2; exit 2; }
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forge-prejudge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.tsv"; : > "$RESULTS"

# `skip` is a real outcome and must stay distinguishable from `pass`: a check
# that could not run has not passed. That distinction is the whole of F5 — tier
# 1 read an empty CI rollup as "no CI configured" and approved on absent CI,
# four times, while CI was green on all ten PRs.
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; }

PRJSON="$TMP/pr.json"
gh pr view "$NUM" --repo "$REPO" --json \
  number,state,title,body,headRefName,headRefOid,baseRefName,baseRefOid,mergedAt,url,additions,deletions,changedFiles,statusCheckRollup \
  > "$PRJSON" 2>"$TMP/gh.log" \
  || { echo "cannot read $REPO#$NUM: $(tail -1 "$TMP/gh.log")" >&2; exit 2; }
q() { jq -r "$1" "$PRJSON"; }

HEAD_REF="$(q .headRefName)"; HEAD_OID="$(q .headRefOid)"
BASE_OID="$(q .baseRefOid)"; PR_URL="$(q .url)"; PR_BODY="$(q '.body // ""')"

# ---------------------------------------------------------------------------
# The tree. Every content check below reads the PR's OWN tree, not the default
# branch — including the contract. That is deliberate and it is the honest
# reading: the contract as it stood on this branch is the one the implementer
# worked against and the one a reviewer would be judging against. On the
# forgeboard-report run it is also the difference between PR #4 and PR #5,
# whose contract was amended between them.
#
# The base commit comes from the PR's recorded `baseRefOid`, not from a local
# merge-base against main. Four of that run's PRs were closed unmerged and their
# commits later reached main under a renamed branch, so a local merge-base
# against main resolves to the head itself and every diff measures zero.
# ---------------------------------------------------------------------------
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

TREE="$TMP/tree"; mkdir -p "$TREE"
G archive "$HEAD_OID" | tar -x -C "$TREE" 2>/dev/null

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
    emit ci-state fail "empty statusCheckRollup after ${WAIT_SECS}s — absent CI is not green CI (F5)"
    return
  fi
  local bad pending
  bad="$(jq -r '[.statusCheckRollup[] | select((.conclusion // "") | test("FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE")) | .name] | join(", ")' "$PRJSON")"
  pending="$(jq -r '[.statusCheckRollup[] | select((.status // "") != "COMPLETED" and ((.state // "") | test("PENDING|EXPECTED"))) | .name] | join(", ")' "$PRJSON")"
  if [ -n "$bad" ]; then
    emit ci-state fail "$n check(s) reported; failing: $bad"
  elif [ -n "$pending" ]; then
    emit ci-state fail "$n check(s) reported; still pending after ${WAIT_SECS}s: $pending"
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
branch_name() {
  local title is_chunk=0
  title="$(q .title)"
  case "$HEAD_REF" in chunk/*) is_chunk=1;; esac
  case "$title"    in CHUNK-[0-9]*) is_chunk=1;; esac
  if [ "$is_chunk" = 0 ]; then
    emit branch-name skip "neither the branch nor the title names a chunk; the chunk/<id>-<slug> rule does not apply to $HEAD_REF"
    return
  fi
  case "$HEAD_REF" in
    chunk/[0-9]*-*)
      if printf '%s' "$HEAD_REF" | grep -qE '^chunk/[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$'; then
        emit branch-name pass "$HEAD_REF"
      else
        emit branch-name fail "$HEAD_REF does not match chunk/<id>-<slug> (slug must be lowercase alphanumeric words separated by single hyphens)"
      fi;;
    chunk/*)
      emit branch-name fail "$HEAD_REF has no <slug> — AGENTS.md requires chunk/<id>-<slug>";;
    *)
      emit branch-name fail "$HEAD_REF does not match chunk/<id>-<slug>";;
  esac
}

# ---------------------------------------------------------------------------
# 3. Diff paths within the contract's Touches (F8) — reported as WARN, on
# purpose, and the count is the deliverable.
#
# The audit offers two policies and picks neither: `Touches` is advisory and
# scope is judged against the Goal, or the lane may amend `Touches` in-branch
# with a justification. Both are defensible; choosing one here would be
# guessing, and the guess would be enforced on six chunks by a program. So this
# reports drift, counts it, and lets the number decide the policy next slice.
#
# What is NOT in doubt is that bouncing on it was wrong. `Touches` lists were
# written by /roadmap before any code existed. CHUNK-3's omitted a fixture the
# work necessarily needed, and the bounce was a defect in the PLAN discovered in
# the most expensive place available.
# ---------------------------------------------------------------------------
touches() {
  [ -n "$CONTRACT" ] || { emit touches skip "no contract for ${CHUNK:-this branch} in the PR tree"; return; }
  local listed drift changed
  listed="$(grep -m1 -- '- \*\*Touches:\*\*' "$CONTRACT" \
            | grep -oE '`[^`]+`' | tr -d '`' | sort -u)"
  [ -n "$listed" ] || { emit touches skip "contract $CHUNK.md has no parseable Touches list"; return; }
  changed="$(G diff --name-only "$BASE_OID" "$HEAD_OID" | sort -u)"
  drift="$(comm -23 <(printf '%s\n' "$changed") <(printf '%s\n' "$listed"))"
  local n; n="$(printf '%s' "$drift" | grep -c . || true)"
  if [ "$n" = 0 ]; then
    emit touches pass "$(printf '%s\n' "$changed" | grep -c .) changed path(s), all listed in $CHUNK.md"
  else
    emit touches warn "$n path(s) outside Touches: $(printf '%s' "$drift" | tr '\n' ' ' | sed 's/ $//')"
  fi
}

# ---------------------------------------------------------------------------
# 4. Size budget (F28) — the most-violated rule in the Forge and the only major
# rule with no gate. Six chunks, six violations, mean 4.0x over, worst 9.3x.
# The same repo enforces ruff formatting with a git hook.
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
  read -r add del files <<< "$(G diff --numstat "$BASE_OID" "$HEAD_OID" \
    | awk '{a+=$1; d+=$2; f++} END {printf "%d %d %d", a, d, f}')"
  total=$(( add + del ))
  exc="$(printf '%s' "$PR_BODY" | grep -m1 -iE '^size-exception: *[^ ]' || true)"
  if [ "$total" -le "$budget" ]; then
    emit size-budget pass "$total lines changed (+$add/-$del) across $files file(s), budget $budget"
  elif [ -n "$exc" ]; then
    emit size-budget warn "$total lines changed, ${budget} budget — overridden by PR body: $(printf '%s' "$exc" | cut -c1-90)"
  else
    emit size-budget fail "$total lines changed (+$add/-$del) across $files file(s) — $(awk -v t="$total" -v b="$budget" 'BEGIN{printf "%.1f", t/b}')x the $budget budget, and no 'size-exception:' line in the PR body"
  fi
}

# ---------------------------------------------------------------------------
# 5. Parent PRs merged (F10). ADR-0008 gates on parent `mergedAt`, but the
# dispatcher promotes on parent card `done`, and a card goes done when the PR
# OPENS. So the board reliably spawned a worker that reliably discovered it
# could not work: run 1 of every chunk from 2 to 6 was blocked after 25s-1m,
# five wasted spawns each paying full prompt cost. The edge lives in
# docs/chunks/graph.json, and `mergedAt` is one field.
# ---------------------------------------------------------------------------
parents_merged() {
  local graph="$TREE/docs/chunks/graph.json"
  [ -n "$CHUNK" ] || { emit parents-merged skip "branch names no chunk, so it has no graph edges"; return; }
  [ -f "$graph" ] || { emit parents-merged skip "no docs/chunks/graph.json in the PR tree"; return; }
  local parents; parents="$(jq -r --arg c "$CHUNK" '.[] | select(.id==$c) | .depends_on[]?' "$graph" 2>/dev/null)"
  if [ -z "$parents" ]; then
    emit parents-merged pass "$CHUNK has no parents in graph.json"; return
  fi
  local p pnum unmerged="" checked=""
  for p in $parents; do
    # The parent's PR is the MERGED one whose branch names that chunk. A closed
    # unmerged PR for the same chunk (there are four on this run) must not be
    # mistaken for the parent's integration.
    pnum="$(gh pr list --repo "$REPO" --state merged --limit 100 \
             --json number,headRefName,mergedAt \
             -q "[.[] | select(.headRefName | test(\"^chunk/${p#CHUNK-}(-|$)\"))] | sort_by(.number) | last | .number" 2>/dev/null)"
    if [ -z "$pnum" ] || [ "$pnum" = "null" ]; then
      unmerged="$unmerged $p(no merged PR)"
    else
      checked="$checked $p=#$pnum"
    fi
  done
  if [ -n "$unmerged" ]; then
    emit parents-merged fail "parent(s) not merged:$unmerged"
  else
    emit parents-merged pass "parent(s) merged:$checked"
  fi
}

# ---------------------------------------------------------------------------
# 6. Every Then step asserts on a value (F14) — the most-cited defect in every
# chunk, and cited by the HUMAN tier every time. The implementer writes the
# scenarios, marks them green and self-reports coverage; tier 1 approves 3/3;
# only tier 2 reads the steps. See scripts/prejudge-steps.py for what this can
# and cannot decide — it is a floor, not a ceiling.
# ---------------------------------------------------------------------------
then_asserts() {
  [ -d "$TREE/tests" ] || { emit then-asserts skip "no tests/ directory in the PR tree"; return; }
  local out; out="$(python3 "$(dirname "${BASH_SOURCE[0]:-$0}")/prejudge-steps.py" "$TREE/tests" 2>/dev/null)"
  [ -n "$out" ] || { emit then-asserts skip "the AST walker produced no output"; return; }
  local steps n
  steps="$(printf '%s' "$out" | jq -r .then_steps)"
  n="$(printf '%s' "$out" | jq -r '.offenders | length')"
  if [ "$n" = 0 ]; then
    emit then-asserts pass "$steps Then step(s), every one asserts; no tautological comparison in tests/"
  else
    emit then-asserts fail "$steps Then step(s), $n defect(s): $(printf '%s' "$out" \
      | jq -r '[.offenders[] | "\(.file|sub("^.*/tree/";""))':'\(.line) \(.kind)"] | join("; ")' | cut -c1-220)"
  fi
}

# ---------------------------------------------------------------------------
# 7. Scenario count matches the contract (F13). Feature files are 10% of their
# step files — a 26-line spec whose meaning is 371 lines of Python the same
# agent wrote. "Scenarios are the living spec" does not hold there, and that is
# the structural reason scenario theater keeps recurring. The contract states
# how many scenarios the chunk has; the feature files either have them or not.
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
  if [ "$got" = "$want" ]; then
    emit scenario-count pass "$got scenario(s) in $(printf '%s' "$feats" | tr '\n' ' ')== $want specified in $CHUNK.md"
  else
    emit scenario-count fail "$got scenario(s) in $(printf '%s' "$feats" | tr '\n' ' ')but $CHUNK.md specifies $want"
  fi
}

# ---------------------------------------------------------------------------
# 8. A contract naming an external source has a real-source scenario (F25).
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
# The convention: a scenario tagged `@real-source` in one of the chunk's feature
# files, which pytest-bdd carries through as a marker, so it can be selected and
# skipped-if-absent without a second mechanism.
# ---------------------------------------------------------------------------
EXTERNAL_SOURCES='Hermes|GitHub|gh CLI|GitHub CLI|kanban|sqlite|SQLite|subprocess|network|HTTP'
real_source() {
  [ -n "$CONTRACT" ] || { emit real-source skip "no contract for ${CHUNK:-this branch} in the PR tree"; return; }
  local named feats f tagged=0
  named="$(grep -oE "$EXTERNAL_SOURCES" "$CONTRACT" | sort -u | tr '\n' ',' | sed 's/,$//')"
  [ -n "$named" ] || { emit real-source pass "$CHUNK.md names no external source"; return; }
  feats="$(grep -m1 -- '- \*\*Touches:\*\*' "$CONTRACT" | grep -oE '`[^`]+\.feature`' | tr -d '`')"
  for f in $feats; do
    [ -f "$TREE/$f" ] && grep -qE '^[[:space:]]*@[a-z-]*real-source' "$TREE/$f" && tagged=1
  done
  if [ "$tagged" = 1 ]; then
    emit real-source pass "names $named and has a @real-source scenario"
  else
    emit real-source fail "$CHUNK.md names $named but no feature file carries a @real-source scenario — every external source was tested against synthetic fixtures only (F25)"
  fi
}

ci_state; branch_name; touches; size_budget
parents_merged; then_asserts; scenario_count; real_source

# ---------------------------------------------------------------------------
# The result shape is this gate's OWN, not `forge.judge.v1`. Speaking the
# verdict schema would smuggle in F29's derive-don't-assert decision, which
# belongs to the slice that owns the schema, and would couple this to a schema
# that is about to change. A gate reports checks; it does not score dimensions.
# ---------------------------------------------------------------------------
JSON="$(jq -Rs --arg pr "$PR_URL" --arg repo "$REPO" --arg num "$NUM" \
   --arg chunk "$CHUNK" --arg branch "$HEAD_REF" --arg head "$HEAD_OID" --arg base "$BASE_OID" '
  split("\n") | map(select(length>0) | split("\t") | {id:.[0], status:.[1], evidence:.[2]})
  | { gate: "forge-prejudge-gate", gate_version: 1, mode: "shadow",
      pr: $pr, repo: $repo, number: ($num|tonumber), chunk: (if $chunk=="" then null else $chunk end),
      branch: $branch, head: $head, base: $base,
      checks: .,
      counts: (reduce .[] as $c ({pass:0,fail:0,warn:0,skip:0}; .[$c.status] += 1)),
      result: (if any(.[]; .status=="fail") then "block" else "clear" end) }' "$RESULTS")"

case "$FORMAT" in
json) printf '%s\n' "$JSON";;
text)
  printf '%s' "$JSON" | jq -r '
    "forge prejudge — \(.repo)#\(.number)  \(.chunk // "(no chunk)")  \(.branch)",
    "  shadow mode: this gates nothing",
    "",
    (.checks[] | "  \(.status | ascii_upcase | (. + "    ")[0:5])  \(.id)\n         \(.evidence)"),
    "",
    "  \(.result | ascii_upcase)  — \(.counts.pass) pass, \(.counts.fail) fail, \(.counts.warn) warn, \(.counts.skip) skip"';;
esac
