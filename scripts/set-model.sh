#!/usr/bin/env bash
# =============================================================================
# forge set-model — swap a pin in one command, and REFUSE to write an id that
# could not be confirmed against a catalogue.
#
# WHY THIS EXISTS.
#
# ADR-0018 reduced three model pins to ONE machine-readable source,
# `scripts/model-pins.sh`. It did not reduce the number of places a swap must
# touch: the prose copies remain, because a skill body and a state document
# must still SAY what is pinned. So a swap is still three checked-in edits in
# three different shapes, each read by a different `sed`:
#
#   scripts/model-pins.sh        four assignments      SOURCED (ADR-0018 D18.2)
#   docs/state.md   env block    prose, vendor-STRIPPED    cli/model-pin-documented
#                                prose, `codex pinned M E` cli/codex-pin-documented
#   skills/forge-lane/SKILL.md   prose, (`M`, reasoning `E`) a sed RANGE anchored
#                                                            on two English sentences
#
# Every one of those readers is anchored to text a human is expected to keep
# intact, which is F65: reword the anchor and the extraction yields the empty
# string — the guard goes BLIND, not red. Doing the three edits by hand is how
# a pin ships half-applied, and F22 measured what that costs (a pin that moved
# mid-run confounded the one chunk that failed, because nothing recorded it had
# moved). This command makes the checked-in half one action, and then READS
# BACK through the very extractions the suite uses.
#
# AND WHY IT VALIDATES, which is the larger half of its value. Nothing in this
# repository checks that a model id RESOLVES; every check compares strings to
# other strings. That is how, on 2026-08-07, MODEL_DRIVER spent a day reading
# `deepseek-v4-flash-latest-latest` — an id that resolves nowhere — with the
# entire suite green. Three agreeing copies of a wrong id are three wrong
# copies. A `set-model` that wrote an unvalidated id would be WORSE than the
# hand edit it replaces, because it launders an unchecked value through a tool
# that looks authoritative. So: no confirmation, no write.
#
# WHAT IT NEVER TOUCHES: `~/.codex/config.toml`. Since #65 the runner PASSES
# `-m` and `-c model_reasoning_effort` out of the pin file on both argv
# branches, so that file does not govern an unattended run and the Codex
# desktop app may rewrite it freely (it did, unbidden, on 2026-09-08 at
# 10:08:47). Writing it here would rebuild exactly the coupling #65 removed.
#
# WHERE THE ANSWERS COME FROM.
#
#   router/driver  the live OpenRouter catalogue,
#                  https://openrouter.ai/api/v1/models, on a hard timeout
#                  (431 ids on 2026-09-09). Fallback: the Hermes catalogue
#                  cache, $HOME/.hermes/cache/model_catalog.json — but that is
#                  a CURATED subset (57 ids) and can be days stale, so absence
#                  there is NOT proof the id is bad. It confirms; it never
#                  condemns.
#   codex          $HOME/.codex/models_cache.json, fully offline, and it
#                  validates MODEL AND EFFORT TOGETHER: each slug carries its
#                  own `supported_reasoning_levels`. Measured 2026-09-09:
#                  7 slugs, and `gpt-5.6-luna` supports `xhigh` but NOT
#                  `ultra` — so the effort arm has real teeth. The cache also
#                  carries `client_version`; a mismatch against `codex
#                  --version` means the cache describes a different binary,
#                  which is "could not ask", not "the pin is wrong".
#
# Usage:
#   [APPLY=1] scripts/set-model.sh [--router <id>] [--driver <id>]
#                                  [--codex-model <slug>] [--codex-effort <e>]
#
# DRY RUN BY DEFAULT. It validates and prints the plan; it writes nothing.
# APPLY=1 is the ONLY value that acts. Any other non-empty value is REFUSED,
# never reinterpreted: `APPLY=0`, `APPLY=false` and `APPLY=no` all read as
# "don't" to the operator who typed them, and the Makefile's worktree-sweep
# comment records what happened the last time a non-empty test treated them as
# "do". Silently doing the opposite of what was typed is worse than an error.
#
# Exit codes:
#   0  ran and made no unfinished change: the plan was printed (dry run), or
#      APPLY=1 wrote all three sites and every readback agreed.
#   1  a write was made and then FAILED its readback. The three files were
#      RESTORED from backup, so the tree is as it was, and the diagnostic names
#      which extraction disagreed. This is the only exit that means a `sed`
#      matched nothing — which is precisely how a swap ships half-applied.
#   2  REFUSED — nothing was written, and no claim is made about the id.
#
# EXIT 2 ALWAYS MEANS "COULD NOT ASK", and it deliberately covers both "no
# catalogue answered" and "the catalogue answered and does not carry this id".
# That is not sloppiness: in both cases this command holds NO evidence that the
# id is good, nothing has been written, and the operator's next action is the
# same. The DIAGNOSTICS distinguish them; the exit code does not need to,
# because there is no caller for whom "unconfirmable" and "unconfirmed" differ.
# It also covers an unknown flag, an APPLY value that is not 1, and an anchor
# that has moved. 2 is never a verdict about the tree.
#
# THE ESCAPE HATCH, and its cost: FORGE_SET_MODEL_UNVERIFIED=1 downgrades every
# validation refusal to a warning and proceeds. It is not free — the override
# is printed INTO the suggested commit message, so an unverified write leaves a
# durable trace in the history instead of a clean-looking commit. (That value,
# too, is 1 or nothing.)
#
# THE HALF IT CANNOT DO. This command changes CHECKED-IN files only. Nothing
# live moves until the PR merges and the runtime is pulled and republished; the
# closing lines print those two commands. A live `hermes config set` on a
# `forge-*` profile is NOT durable — profiles-bootstrap.sh republishes the four
# profiles and reverts it.
# =============================================================================
set -uo pipefail

# Anchored to the `# ====` rules, never a line range: `sed -n '2,40p'` goes
# blind the first time a paragraph moves, and this header is the exit-code
# contract (worktree-sweep.sh's help lost its `Exit:` line exactly that way).
help_text() {
  awk 'NR==1 { next }
       /^# ={10,}/ { if (seen) exit; seen=1; next }
       seen { sub(/^#[ ]?/, ""); print }' "$0"
}

say() { printf '%s\n' "$*"; }
refuse() { printf 'set-model: %s\n' "$*" >&2; exit 2; }

# --- where the three sites are -----------------------------------------------
# dirname "$0" and NOT `readlink -f` / `pwd -P` / `git rev-parse --show-toplevel`.
# The conformance suite runs this script through a SYMLINK inside a fixture
# repo; every one of those resolves the symlink back to the real checkout, and
# the mutation cases would then edit the live docs/state.md and
# skills/forge-lane/SKILL.md. A mutation harness that mutates the worktree in
# place leaves a defect the pushed head and CI cannot see.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || refuse "cannot resolve my own directory"
ROOT="${SCRIPT_DIR%/*}"
PIN_FILE="$ROOT/scripts/model-pins.sh"
STATE_FILE="$ROOT/docs/state.md"
LANE_FILE="$ROOT/skills/forge-lane/SKILL.md"

OPENROUTER_URL="${FORGE_SET_MODEL_CATALOG_URL:-https://openrouter.ai/api/v1/models}"
CURL_TIMEOUT="${FORGE_SET_MODEL_TIMEOUT:-12}"
HERMES_CACHE="$HOME/.hermes/cache/model_catalog.json"
CODEX_CACHE="$HOME/.codex/models_cache.json"

# --- arguments ---------------------------------------------------------------
WANT_ROUTER=""; WANT_DRIVER=""; WANT_CODEX_MODEL=""; WANT_CODEX_EFFORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) help_text; exit 0;;
    --router)       [ $# -ge 2 ] || refuse "--router needs a value";       WANT_ROUTER="$2"; shift 2;;
    --driver)       [ $# -ge 2 ] || refuse "--driver needs a value";       WANT_DRIVER="$2"; shift 2;;
    --codex-model)  [ $# -ge 2 ] || refuse "--codex-model needs a value";  WANT_CODEX_MODEL="$2"; shift 2;;
    --codex-effort) [ $# -ge 2 ] || refuse "--codex-effort needs a value"; WANT_CODEX_EFFORT="$2"; shift 2;;
    *) refuse "unknown argument: $1 (see --help)";;
  esac
done

case "${APPLY:-}" in
  ""|1) ;;
  *) refuse "APPLY='${APPLY}' is not understood. The only value that acts is APPLY=1; omit it entirely for a dry run. Reinterpreting it would mean writing files for an operator who typed 'no'.";;
esac
APPLYING=0; [ "${APPLY:-}" = 1 ] && APPLYING=1

case "${FORGE_SET_MODEL_UNVERIFIED:-}" in
  ""|1) ;;
  *) refuse "FORGE_SET_MODEL_UNVERIFIED='${FORGE_SET_MODEL_UNVERIFIED}' is not understood. The only value that overrides validation is 1.";;
esac
UNVERIFIED=0; [ "${FORGE_SET_MODEL_UNVERIFIED:-}" = 1 ] && UNVERIFIED=1
UNVERIFIED_NOTES=""

[ -n "$WANT_ROUTER$WANT_DRIVER$WANT_CODEX_MODEL$WANT_CODEX_EFFORT" ] \
  || refuse "nothing to set. usage: [APPLY=1] set-model.sh [--router <id>] [--driver <id>] [--codex-model <slug>] [--codex-effort <e>]"

# Every requested value is spliced into a `sed` replacement below. Bound the
# alphabet here rather than trusting the caller: an id carrying a `|`, a `&` or
# a newline would rewrite the replacement itself, and the readback would then be
# asserting something nobody asked for.
for v in "$WANT_ROUTER" "$WANT_DRIVER" "$WANT_CODEX_MODEL"; do
  [ -z "$v" ] && continue
  case "$v" in
    *[!A-Za-z0-9./:_-]*) refuse "'$v' is not a model id: only A-Za-z0-9 . / : _ - are accepted";;
  esac
done
if [ -n "$WANT_CODEX_EFFORT" ]; then
  case "$WANT_CODEX_EFFORT" in
    *[!a-z]*) refuse "'$WANT_CODEX_EFFORT' is not a reasoning effort: lowercase letters only";;
  esac
fi

# --- the current pins, SOURCED (ADR-0018 D18.2 — `source` is the only parser) -
[ -r "$PIN_FILE" ] || refuse "$PIN_FILE is missing or unreadable"
[ -r "$STATE_FILE" ] || refuse "$STATE_FILE is missing or unreadable"
[ -r "$LANE_FILE" ] || refuse "$LANE_FILE is missing or unreadable"

read_pins() { # sets PIN_ROUTER/PIN_DRIVER/PIN_CODEX_MODEL/PIN_CODEX_EFFORT
  local out
  out="$(
    unset FORGE_PIN_ROUTER FORGE_PIN_DRIVER FORGE_PIN_CODEX_MODEL FORGE_PIN_CODEX_EFFORT
    # shellcheck disable=SC1090
    . "$PIN_FILE" >/dev/null 2>&1 || exit 1
    printf '%s\n%s\n%s\n%s\n' "${FORGE_PIN_ROUTER:-}" "${FORGE_PIN_DRIVER:-}" \
                              "${FORGE_PIN_CODEX_MODEL:-}" "${FORGE_PIN_CODEX_EFFORT:-}"
  )" || return 1
  { read -r PIN_ROUTER; read -r PIN_DRIVER
    read -r PIN_CODEX_MODEL; read -r PIN_CODEX_EFFORT; } <<< "$out"
  [ -n "$PIN_ROUTER" ] && [ -n "$PIN_DRIVER" ] \
    && [ -n "$PIN_CODEX_MODEL" ] && [ -n "$PIN_CODEX_EFFORT" ]
}
PIN_ROUTER=""; PIN_DRIVER=""; PIN_CODEX_MODEL=""; PIN_CODEX_EFFORT=""
read_pins || refuse "could not source all four FORGE_PIN_* names out of $PIN_FILE"

NEW_ROUTER="${WANT_ROUTER:-$PIN_ROUTER}"
NEW_DRIVER="${WANT_DRIVER:-$PIN_DRIVER}"
NEW_CODEX_MODEL="${WANT_CODEX_MODEL:-$PIN_CODEX_MODEL}"
NEW_CODEX_EFFORT="${WANT_CODEX_EFFORT:-$PIN_CODEX_EFFORT}"

if [ "$NEW_ROUTER" = "$PIN_ROUTER" ] && [ "$NEW_DRIVER" = "$PIN_DRIVER" ] \
   && [ "$NEW_CODEX_MODEL" = "$PIN_CODEX_MODEL" ] \
   && [ "$NEW_CODEX_EFFORT" = "$PIN_CODEX_EFFORT" ]; then
  say "set-model: the pins already read router=$PIN_ROUTER driver=$PIN_DRIVER codex=$PIN_CODEX_MODEL/$PIN_CODEX_EFFORT — nothing to change."
  exit 0
fi

# --- validation ---------------------------------------------------------------
# A validation refusal is fatal UNLESS the override is set, in which case it is
# recorded and carried into the commit message.
cannot_confirm() { # $1=diagnostic
  if [ "$UNVERIFIED" = 1 ]; then
    say "  WARNING (FORGE_SET_MODEL_UNVERIFIED=1): $1"
    UNVERIFIED_NOTES="$UNVERIFIED_NOTES
      - $1"
    return 0
  fi
  printf 'set-model: %s\n' "$1" >&2
  printf 'set-model: nothing was written. Re-run with FORGE_SET_MODEL_UNVERIFIED=1 to override — it is printed into the commit message.\n' >&2
  exit 2
}

# One flattened catalogue, whatever answered. Both shapes carry `"id": "..."`,
# so removing whitespace makes one `grep -F` serve the live JSON and the
# pretty-printed cache alike. No `jq`: the pin checks are the offline group
# that runs in CI precisely so a pull request cannot merge with a drifted pin,
# and a tool that might be absent would let that guard go quiet (ADR-0018 D18.3).
CATALOGUE=""; CATALOGUE_SOURCE=""; CATALOGUE_IDS=0
load_catalogue() {
  [ -n "$CATALOGUE_SOURCE" ] && return 0
  local body=""
  if command -v curl >/dev/null 2>&1; then
    body="$(curl -fsS --max-time "$CURL_TIMEOUT" "$OPENROUTER_URL" 2>/dev/null)" || body=""
  fi
  if [ -n "$body" ]; then
    CATALOGUE="$(printf '%s' "$body" | tr -d ' \t\n')"
    CATALOGUE_SOURCE="live"
  elif [ -r "$HERMES_CACHE" ]; then
    CATALOGUE="$(tr -d ' \t\n' < "$HERMES_CACHE")"
    CATALOGUE_SOURCE="cache"
  else
    CATALOGUE_SOURCE="none"
    return 1
  fi
  CATALOGUE_IDS="$(printf '%s' "$CATALOGUE" | grep -o '"id":"[^"]*"' | grep -c . || true)"
  [ "$CATALOGUE_IDS" -gt 0 ] || { CATALOGUE_SOURCE="none"; return 1; }
  return 0
}

check_openrouter_id() { # $1=role $2=id
  local role="$1" id="$2"
  if ! load_catalogue; then
    cannot_confirm "cannot validate the $role id '$id': the live OpenRouter catalogue did not answer within ${CURL_TIMEOUT}s and $HERMES_CACHE is not readable, so no catalogue could be asked"
    return 0
  fi
  case "$CATALOGUE" in
    *"\"id\":\"$id\""*)
      if [ "$CATALOGUE_SOURCE" = live ]; then
        say "  ok    $role '$id' is in the live OpenRouter catalogue ($CATALOGUE_IDS ids)"
      else
        say "  ok    $role '$id' is in the Hermes catalogue cache ($CATALOGUE_IDS curated ids; the live catalogue did not answer)"
      fi
      return 0;;
  esac
  if [ "$CATALOGUE_SOURCE" = live ]; then
    cannot_confirm "the live OpenRouter catalogue ($CATALOGUE_IDS ids) does not carry the $role id '$id' — this is the check that 2026-08-07 did not have, when MODEL_DRIVER read 'deepseek-v4-flash-latest-latest' for a day with every check green"
  else
    cannot_confirm "cannot confirm the $role id '$id': the live OpenRouter catalogue did not answer and $HERMES_CACHE is a CURATED subset ($CATALOGUE_IDS ids), so its silence is not proof the id is bad — it is proof nothing could answer"
  fi
}

# The Codex cache is one JSON document per binary version. Flatten it and cut
# the block belonging to one slug: `#*` takes the FIRST match, `%%` ends it at
# the next slug, so an effort belonging to a different model can never satisfy
# this. Model and effort are one question here, never two.
codex_block() { # $1=flattened cache $2=slug ; prints the slug's block
  local flat="$1" slug="$2" block
  case "$flat" in *"\"slug\":\"$slug\""*) ;; *) return 1;; esac
  block="${flat#*\"slug\":\"$slug\"}"
  block="${block%%\"slug\":\"*}"
  printf '%s' "$block"
}

check_codex_pair() { # $1=slug $2=effort
  local slug="$1" effort="$2" flat cache_ver cli_ver block efforts slugs
  if [ ! -r "$CODEX_CACHE" ]; then
    cannot_confirm "cannot validate the Codex pair '$slug/$effort': $CODEX_CACHE is not readable, and it is the only offline source that knows which efforts a slug supports"
    return 0
  fi
  flat="$(tr -d ' \t\n' < "$CODEX_CACHE")" || flat=""
  [ -n "$flat" ] || { cannot_confirm "cannot validate the Codex pair '$slug/$effort': $CODEX_CACHE is empty or unreadable"; return 0; }
  cache_ver="$(printf '%s' "$flat" | sed -n 's/.*"client_version":"\([^"]*\)".*/\1/p' | head -1)"
  if ! command -v codex >/dev/null 2>&1; then
    cannot_confirm "cannot validate the Codex pair '$slug/$effort': codex is not on PATH, so nothing can say whether $CODEX_CACHE (client_version ${cache_ver:-unknown}) describes the binary that will run"
    return 0
  fi
  cli_ver="$(codex --version 2>/dev/null | head -1 | awk '{print $NF}')"
  if [ -z "$cache_ver" ] || [ -z "$cli_ver" ] || [ "$cache_ver" != "$cli_ver" ]; then
    cannot_confirm "cannot validate the Codex pair '$slug/$effort': $CODEX_CACHE says client_version '${cache_ver:-unknown}' but codex --version says '${cli_ver:-unknown}' — the cache describes a different binary, which is 'could not ask', not 'the pin is wrong'"
    return 0
  fi
  if ! block="$(codex_block "$flat" "$slug")"; then
    slugs="$(printf '%s' "$flat" | grep -o '"slug":"[^"]*"' | sed 's/"slug":"//;s/"$//' | tr '\n' ' ')"
    cannot_confirm "the Codex catalogue for client_version $cache_ver does not carry the slug '$slug'; it carries: ${slugs% }"
    return 0
  fi
  efforts="$(printf '%s' "$block" | grep -o '"effort":"[^"]*"' | sed 's/"effort":"//;s/"$//' | tr '\n' ' ')"
  case "$block" in
    *"\"effort\":\"$effort\""*)
      say "  ok    codex '$slug' supports reasoning '$effort' (client_version $cache_ver; supported: ${efforts% })";;
    *)
      cannot_confirm "the Codex model '$slug' does not support reasoning effort '$effort'; it supports: ${efforts% } (client_version $cache_ver)";;
  esac
}

say "set-model: validating the values that CHANGE (an unchanged role is not re-asked)"
[ "$NEW_ROUTER" != "$PIN_ROUTER" ] && check_openrouter_id router "$NEW_ROUTER"
[ "$NEW_DRIVER" != "$PIN_DRIVER" ] && [ "$NEW_DRIVER" != "$NEW_ROUTER" ] \
  && check_openrouter_id driver "$NEW_DRIVER"
[ "$NEW_DRIVER" != "$PIN_DRIVER" ] && [ "$NEW_DRIVER" = "$NEW_ROUTER" ] \
  && say "  ok    driver '$NEW_DRIVER' is the router id, already asked"
if [ "$NEW_CODEX_MODEL" != "$PIN_CODEX_MODEL" ] || [ "$NEW_CODEX_EFFORT" != "$PIN_CODEX_EFFORT" ]; then
  check_codex_pair "$NEW_CODEX_MODEL" "$NEW_CODEX_EFFORT"
fi

# --- the three rewrites ---------------------------------------------------
# state.md names the models WITHOUT their vendor prefix, because
# cli/model-pin-documented compares on `${pin#*/}`. Router and driver are
# identical today and one string satisfies both greps — but they need not be,
# and a rewrite that assumed they were would name only one of a split pair and
# leave the other unstated while the check still passed on the substring it
# found. When they differ the block names BOTH, labelled.
STRIPPED_ROUTER="${NEW_ROUTER#*/}"
STRIPPED_DRIVER="${NEW_DRIVER#*/}"
if [ "$NEW_ROUTER" = "$NEW_DRIVER" ]; then
  STATE_MODELS="$STRIPPED_DRIVER"
else
  STATE_MODELS="router $STRIPPED_ROUTER, driver $STRIPPED_DRIVER"
fi

# Every anchor is asserted to match EXACTLY ONCE before anything is written. A
# `sed` that matched nothing is silent, and silence here is a half-applied
# swap; a `sed` that matched twice would rewrite prose nobody was pointing at.
STATE_ANCHOR='forge-digest (.*) · codex pinned '
LANE_ANCHOR='^- Model: the pin lives in `scripts/model-pins.sh` (`.*`, reasoning `.*`)'
# `grep -c`, BRE, and deliberately NOT `-E`: both anchors carry literal
# parentheses, and in an ERE `(` opens a group — the lane anchor would then
# demand a backtick where the file has `(`, match nothing, and refuse every run
# while looking like a careful guard.
anchor_count() { grep -c "$1" "$2" 2>/dev/null || true; }

n="$(anchor_count '^profiles: forge-orchestrator' "$STATE_FILE")"
[ "$n" = 1 ] || refuse "$STATE_FILE has $n lines starting 'profiles: forge-orchestrator', expected 1 — the environment block cli/model-pin-documented reads has moved (F65)"
n="$(anchor_count "$STATE_ANCHOR" "$STATE_FILE")"
[ "$n" = 1 ] || refuse "$STATE_FILE has $n lines matching 'forge-digest (…) · codex pinned …', expected 1 — the line this command rewrites has moved (F65)"
n="$(anchor_count "$LANE_ANCHOR" "$LANE_FILE")"
[ "$n" = 1 ] || refuse "$LANE_FILE has $n lines matching the forge-lane §4 Model bullet, expected 1 — the sed RANGE in verify.sh's load_checked_in_codex_pins is anchored to it (F65)"

OLD_STATE_LINE="$(grep "$STATE_ANCHOR" "$STATE_FILE")"
OLD_LANE_LINE="$(grep "$LANE_ANCHOR" "$LANE_FILE")"

say ""
say "plan:"
say "  $PIN_FILE"
say "    FORGE_PIN_ROUTER       $PIN_ROUTER -> $NEW_ROUTER"
say "    FORGE_PIN_DRIVER       $PIN_DRIVER -> $NEW_DRIVER"
say "    FORGE_PIN_CODEX_MODEL  $PIN_CODEX_MODEL -> $NEW_CODEX_MODEL"
say "    FORGE_PIN_CODEX_EFFORT $PIN_CODEX_EFFORT -> $NEW_CODEX_EFFORT"
say "  $STATE_FILE"
say "    - $OLD_STATE_LINE"
say "  $LANE_FILE"
say "    - $OLD_LANE_LINE"

if [ "$APPLYING" != 1 ]; then
  say ""
  say "set-model: DRY RUN — nothing was written. Re-run with APPLY=1 to act."
  exit 0
fi

BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/set-model.XXXXXX")" || refuse "cannot create a backup directory"
cleanup() { [ -n "${BACKUP:-}" ] && rm -rf "$BACKUP"; }
trap cleanup EXIT
cp "$PIN_FILE" "$BACKUP/pins" && cp "$STATE_FILE" "$BACKUP/state" && cp "$LANE_FILE" "$BACKUP/lane" \
  || refuse "cannot back up the three files; refusing to write without a way back"

restore_and_die() { # $1=diagnostic
  cp "$BACKUP/pins" "$PIN_FILE"; cp "$BACKUP/state" "$STATE_FILE"; cp "$BACKUP/lane" "$LANE_FILE"
  printf 'set-model: %s\n' "$1" >&2
  printf 'set-model: the three files were RESTORED from backup; the tree is as it was.\n' >&2
  exit 1
}

rewrite() { # $1=file $2=sed program
  local tmp="$BACKUP/out.$$"
  sed "$2" "$1" > "$tmp" 2>/dev/null && mv "$tmp" "$1"
}

rewrite "$PIN_FILE" "
  s|^FORGE_PIN_ROUTER=\".*\"\$|FORGE_PIN_ROUTER=\"$NEW_ROUTER\"|
  s|^FORGE_PIN_DRIVER=\".*\"\$|FORGE_PIN_DRIVER=\"$NEW_DRIVER\"|
  s|^FORGE_PIN_CODEX_MODEL=\".*\"\$|FORGE_PIN_CODEX_MODEL=\"$NEW_CODEX_MODEL\"|
  s|^FORGE_PIN_CODEX_EFFORT=\".*\"\$|FORGE_PIN_CODEX_EFFORT=\"$NEW_CODEX_EFFORT\"|
" || restore_and_die "could not rewrite $PIN_FILE"

# The prefix and the ` · codex pinned ` join are CAPTURED, not retyped, so the
# indentation and the separator survive verbatim.
rewrite "$STATE_FILE" \
  "s|^\\(.*forge-digest (\\)[^)]*\\() · codex pinned \\).*\$|\\1$STATE_MODELS\\2$NEW_CODEX_MODEL $NEW_CODEX_EFFORT|" \
  || restore_and_die "could not rewrite $STATE_FILE"

# One line in, one line out. skills/forge-lane/SKILL.md is at its
# cli/skill-body-budget ceiling of 308 lines; adding one would redden the suite.
rewrite "$LANE_FILE" \
  "s|^\\(- Model: the pin lives in \`scripts/model-pins.sh\` (\\)\`[^\`]*\`, reasoning \`[^\`]*\`\\()\\)|\\1\`$NEW_CODEX_MODEL\`, reasoning \`$NEW_CODEX_EFFORT\`\\2|" \
  || restore_and_die "could not rewrite $LANE_FILE"

# --- READ BACK through the SAME extractions the suite performs ---------------
# profiles-bootstrap.sh's doctrine: a write is not done until the reader agrees.
# These `sed` programs are deliberate duplicates of scripts/verify.sh's
# load_model_pins, load_checked_in_codex_pins and its env_block extraction — if
# one of those anchors is ever rewritten, this must be rewritten with it, and
# cli/set-model-readback-mirrors-the-suite asserts they still name each other.
read_pins || restore_and_die "the rewritten $PIN_FILE no longer sources four FORGE_PIN_* values"
[ "$PIN_ROUTER" = "$NEW_ROUTER" ] || restore_and_die "readback: $PIN_FILE sources FORGE_PIN_ROUTER='$PIN_ROUTER', expected '$NEW_ROUTER'"
[ "$PIN_DRIVER" = "$NEW_DRIVER" ] || restore_and_die "readback: $PIN_FILE sources FORGE_PIN_DRIVER='$PIN_DRIVER', expected '$NEW_DRIVER'"
[ "$PIN_CODEX_MODEL" = "$NEW_CODEX_MODEL" ] || restore_and_die "readback: $PIN_FILE sources FORGE_PIN_CODEX_MODEL='$PIN_CODEX_MODEL', expected '$NEW_CODEX_MODEL'"
[ "$PIN_CODEX_EFFORT" = "$NEW_CODEX_EFFORT" ] || restore_and_die "readback: $PIN_FILE sources FORGE_PIN_CODEX_EFFORT='$PIN_CODEX_EFFORT', expected '$NEW_CODEX_EFFORT'"

env_block="$(sed -n '/^profiles: forge-orchestrator/,/codex pinned/p' "$STATE_FILE")"
[ -n "$env_block" ] || restore_and_die "readback: $STATE_FILE has no 'profiles: forge-orchestrator … codex pinned' environment block, which is what cli/model-pin-documented reads"
printf '%s' "$env_block" | grep -Fq "$STRIPPED_ROUTER" \
  || restore_and_die "readback: the environment block in $STATE_FILE does not name the router as '$STRIPPED_ROUTER'"
printf '%s' "$env_block" | grep -Fq "$STRIPPED_DRIVER" \
  || restore_and_die "readback: the environment block in $STATE_FILE does not name the driver as '$STRIPPED_DRIVER'"

state_pair="$(sed -n 's/.*codex pinned \([^[:space:]]*\)[[:space:]]\([^[:space:]]*\).*/\1 \2/p' "$STATE_FILE" | head -1)"
[ "$state_pair" = "$NEW_CODEX_MODEL $NEW_CODEX_EFFORT" ] \
  || restore_and_die "readback: cli/codex-pin-documented's extraction reads '$state_pair' out of $STATE_FILE, expected '$NEW_CODEX_MODEL $NEW_CODEX_EFFORT'"

lane_pair="$(sed -n '/^- Model: the pin lives in `scripts\/model-pins.sh`/,/completion metadata\./p' "$LANE_FILE" \
  | tr '\n' ' ' \
  | sed -n 's/.*(`\([^`]*\)`, reasoning[[:space:]]*`\([^`]*\)`).*/\1 \2/p')"
[ "$lane_pair" = "$NEW_CODEX_MODEL $NEW_CODEX_EFFORT" ] \
  || restore_and_die "readback: verify.sh's forge-lane §4 sed RANGE reads '$lane_pair', expected '$NEW_CODEX_MODEL $NEW_CODEX_EFFORT'"

lane_lines="$(grep -c '' "$LANE_FILE")"
[ "$lane_lines" -le 308 ] \
  || restore_and_die "readback: $LANE_FILE is now $lane_lines lines, over cli/skill-body-budget's lane ceiling of 308"

say ""
say "set-model: applied and read back through the suite's own extractions."
say "  router  $NEW_ROUTER"
say "  driver  $NEW_DRIVER"
say "  codex   $NEW_CODEX_MODEL / $NEW_CODEX_EFFORT"
say ""
say "suggested commit message:"
say ""
say "    pins: router $NEW_ROUTER, driver $NEW_DRIVER, codex $NEW_CODEX_MODEL/$NEW_CODEX_EFFORT"
say ""
say "    Written by scripts/set-model.sh across the three checked-in sites"
say "    (scripts/model-pins.sh, docs/state.md, skills/forge-lane/SKILL.md) and"
say "    read back through the extractions cli/model-pin-documented and"
say "    cli/codex-pin-documented perform."
if [ -n "$UNVERIFIED_NOTES" ]; then
  say ""
  say "    FORGE_SET_MODEL_UNVERIFIED=1 — these values were NOT confirmed against"
  say "    any catalogue, and this line is the durable trace of that:$UNVERIFIED_NOTES"
fi
say ""
say "then, AFTER the pull request merges — this command changed checked-in files only:"
say "    git -C ~/dev/forge-runtime pull && ~/.forge/repo/hermes/profiles-bootstrap.sh"
say "  (a live \`hermes config set\` on a forge-* profile is NOT durable: the"
say "   bootstrap republishes the four profiles and reverts it.)"
exit 0
