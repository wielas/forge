#!/usr/bin/env bash
# =============================================================================
# forge verify — the conformance suite. Forge's test for Forge.
#
# `make validate` checks YAML frontmatter and `bash -n`. This checks CLAIMS:
# every flag this repo tells a machine to run, every config invariant it says
# holds, every substrate behaviour it depends on, and that the template it
# stamps actually comes up green.
#
# The rule this exists to enforce (ADR-0003, applied to ourselves for once):
#   A claim that cannot be asserted may not appear in a skill body,
#   because skill bodies are executed by machines that cannot tell
#   aspiration from observation.
#
# Usage:
#   ./scripts/verify.sh                 # every group, with free substrate probes
#   ./scripts/verify.sh cli config      # only these groups
#   ./scripts/verify.sh --with-codex    # also run the sandbox probes (spend tokens)
#   ./scripts/verify.sh bootstrap --with-hermes  # run isolated real-Hermes bootstrap proof
#   ./scripts/verify.sh --list          # list cases without running them
#
# Groups:
#   cli/        every long flag named beside a command in skills/, hermes/, docs/
#               must exist in that command's live --help                    (F5, F10)
#   config/     documented invariants, read PER PROFILE              (F3, F11, F13, F14)
#   substrate/  throwaway-lab probes of behaviour we depend on        (F2, F9, F15)
#   template/   stamp -> make setup -> hooks installed -> make check   (F8)
#   lane/       preconditions the unattended lane needs and cannot create for
#               itself. Every case was a real failure seen on 2026-07-28 while
#               driving `codex exec` by hand against a live chunk (rung 2).
#   bootstrap/  staged board creation against a stateful Hermes stub: validate
#               the graph first, create one root, then extend idempotently.
#   commission/ paid launch evidence against command stubs; never spends in CI.
#   metrics/    the flywheel's review and observability signals, computed from
#               checked-in board/profile fixtures and diffed against one exact
#               expectation. Schema drift must fail a check, not a quarter (F27)
#   metadata/   completed-run envelopes against their versioned JSON Schemas,
#               from fixtures only; no live board is opened              (F1, F2, F44)
#   sweep/      durability of what `make new` stamps, and reclamation of the
#               checkouts finished chunks leave behind             (F18, F19)
#   prejudge/   tier 1 as a program: the AST walker against a checked-in fixture
#               of real and near-miss step shapes, and the gate's own safety
#               properties — absent CI is not a pass, skip is not pass, it does
#               not speak the verdict schema, and it gates nothing       (F35)
#   roadmap/    the sizing rules at PLAN time: one checked-in passing roadmap,
#               one mutation per rule family, and the audited run's own CHUNK-5
#               driven through the real check              (F11, F53, ADR-0012)
#   gate/       repository merge protection and required-check diagnostics,
#               driven through recorded API response shapes                    (F79)
#   docs/       the reconciled launch ledger and operator contract: dispositions,
#               bounded cleanup, preserved history, and one next command
#   quota/      the usage-limit park: which window a run waits on, and that the
#               lane resumes the same Codex session rather than restarting it.
#               Fixtures and a stubbed codex only — spends nothing   (ADR-0016)
#   manifest/   `--list` names every case the suite actually runs. Compares the
#               catalogue against what THIS run emitted, so a check added
#               without a catalogue entry is caught. Full runs only    (F65/F66)
#
# Exit 0 iff every case passes. Run it in CI, and as a hard gate after every
# `hermes update` and every codex/claude upgrade.
# =============================================================================
set -uo pipefail   # NOT -e: a failing case is a result, not a crash

cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 2
REPO_ROOT="$(pwd)"
# In a linked worktree these differ: --git-common-dir resolves to the main
# checkout's .git, which is the checkout the live Hermes profiles point at (F49).
MAIN_ROOT="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)/.." 2>/dev/null && pwd)"
MAIN_ROOT="${MAIN_ROOT:-$REPO_ROOT}"

helptext() {
  awk '
    /^# forge verify / { printing = 1 }
    printing && /^# =+$/ { exit }
    printing { sub(/^# ?/, ""); print }
  ' "$0"
}

WITH_CODEX=0; WITH_HERMES=0; LIST_ONLY=0; SUITES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-codex) WITH_CODEX=1; shift;;
    --with-hermes) WITH_HERMES=1; shift;;
    --list) LIST_ONLY=1; shift;;
    -h|--help) helptext; exit 0;;
    cli|config|substrate|template|lane|bootstrap|commission|metrics|metadata|prejudge|sweep|roadmap|gate|docs|quota|manifest) SUITES="$SUITES $1"; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
DEFAULT_SUITES="cli config substrate template lane bootstrap commission metrics metadata prejudge sweep roadmap gate docs quota manifest"
[ -n "$SUITES" ] || SUITES="$DEFAULT_SUITES"

PASS=0; FAIL=0; SKIP=0
CURRENT_GROUP=""
# Every case records the name it reported under, so the manifest/ group can
# compare what this run actually executed against what --list claims it does.
# The dynamic tail (" (14 flag claims …)") is stripped: it is diagnostic detail,
# not part of the case's identity.
_emit()  { [ -n "${TMPROOT:-}" ] && printf '%s/%s\n' "$CURRENT_GROUP" "${1%% (*}" >> "$TMPROOT/emitted.txt"; return 0; }
ok()    { PASS=$((PASS+1)); _emit "$1"; printf '  ok    %s/%s\n' "$CURRENT_GROUP" "$1"; }
bad()   { FAIL=$((FAIL+1)); _emit "$1"; printf '  FAIL  %s/%s\n        %s\n' "$CURRENT_GROUP" "$1" "$2"; }
skip()  { SKIP=$((SKIP+1)); _emit "$1"; printf '  skip  %s/%s (%s)\n' "$CURRENT_GROUP" "$1" "$2"; }
group() { CURRENT_GROUP="$1"; printf '\n== %s ==\n' "$1"; }
wants() { case " $SUITES " in *" $1 "*) return 0;; *) return 1;; esac; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/forge-verify.XXXXXX")"
# The sandbox lab must NOT live under /tmp or $TMPDIR: codex `workspace-write`
# grants those unconditionally, so a probe there passes for the wrong reason.
LABROOT="$HOME/.forge-verify-lab"
cleanup() { rm -rf "$TMPROOT" "$LABROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# cli/ — flags named next to a command must exist in that command's --help.
#
# This is the group that would have caught `--body-file` on `hermes kanban
# create` before it shipped to a machine. It does not read prose: it extracts
# the LOGICAL command line (joining backslash continuations) and only inspects
# lines that actually invoke a tracked command.
# ---------------------------------------------------------------------------
# regex matching an invocation | command to ask for --help
# Most specific first: `boards create` must win over `create`.
CLI_SPECS='
hermes kanban( .*)? boards create|hermes kanban boards create
hermes kanban( .*)? boards set-default-workdir|hermes kanban boards set-default-workdir
hermes kanban( .*)? boards list|hermes kanban boards list
hermes kanban( .*)? create|hermes kanban create
hermes kanban( .*)? link|hermes kanban link
codex exec resume|codex exec resume
codex exec|codex exec
gh pr create|gh pr create
gh pr checks|gh pr checks
gh pr diff|gh pr diff
'

help_flags() { # $1=command -> newline-separated long flags it accepts
  # shellcheck disable=SC2086
  $1 --help 2>&1 | grep -oE -- '--[a-zA-Z][a-zA-Z0-9-]+' | sort -u
  # `hermes kanban --board <slug> create …` is real and documented: --board
  # belongs to the KANBAN parser, not to the subcommand. So a subcommand's
  # claimed flags may legitimately come from the parent parser too.
  case "$1" in
    "hermes kanban "*) hermes kanban --help 2>&1 | grep -oE -- '--[a-zA-Z][a-zA-Z0-9-]+' | sort -u;;
  esac
}

# Join backslash-continued lines so a multi-line invocation is one record, then
# split into per-command segments. Without the split, `hermes … --json | jq
# --arg …` would charge jq's flags to hermes. Command substitutions are removed
# first, so `--add-dir "$(git rev-parse --git-common-dir)"` does not charge
# git's flags to codex.
logical_lines() { # $1=file
  awk '{
    line = $0
    sub(/^[[:space:]]*/, "", line)
    if (buf != "") { buf = buf " " line } else { buf = line }
    if (buf ~ /\\$/) { sub(/\\$/, "", buf); next }
    print buf; buf = ""
  } END { if (buf != "") print buf }' "$1" \
  | sed -e 's/\$([^)]*)//g' -e 's/`[^`]*`//g' \
  | tr '|' '\n'
}

check_skill_section_references() { # $1=repo root; diagnostics on stdout
  local root="$1" refs source line reference target section target_file shown bad_refs=0
  refs="$(grep -rnEo '`[a-z][a-z0-9-]*`[[:space:]]+§[0-9]+' \
             "$root/skills" --include='SKILL.md' 2>/dev/null || true)"
  if [ -z "$refs" ]; then
    echo "found no '<skill> §<n>' references under skills/ — the check went blind"
    return 1
  fi

  while IFS=: read -r source line reference; do
    [ -n "$source" ] || continue
    target="$(printf '%s' "$reference" \
      | sed -E 's/^`([a-z][a-z0-9-]*)`[[:space:]]+§[0-9]+$/\1/')"
    section="$(printf '%s' "$reference" | sed -E 's/.*§([0-9]+)$/\1/')"
    target_file="$root/skills/$target/SKILL.md"
    shown="${source#"$root"/}:$line reference '$target §$section'"
    if [ ! -f "$target_file" ]; then
      echo "$shown names missing skill skills/$target/SKILL.md"
      bad_refs=1
    elif ! grep -Eq "^#{1,6}[[:space:]]+$section([.[:space:]]|$)" "$target_file"; then
      echo "$shown has missing heading '§$section' in skills/$target/SKILL.md"
      bad_refs=1
    fi
  done <<< "$refs"

  return "$bad_refs"
}

CHECKED_LANE_MODEL=""; CHECKED_LANE_EFFORT=""
CHECKED_STATE_MODEL=""; CHECKED_STATE_EFFORT=""
load_checked_in_codex_pins() {
  local lane_pair state_pair
  lane_pair="$(sed -n '/^- Model: the pin lives in `~\/.codex\/config.toml`/,/completion metadata\./p' \
                    skills/forge-lane/SKILL.md \
    | tr '\n' ' ' \
    | sed -n 's/.*(`\([^`]*\)`, reasoning[[:space:]]*`\([^`]*\)`).*/\1 \2/p')"
  state_pair="$(sed -n \
    's/.*codex pinned \([^[:space:]]*\)[[:space:]]\([^[:space:]]*\).*/\1 \2/p' \
    docs/state.md | head -1)"
  read -r CHECKED_LANE_MODEL CHECKED_LANE_EFFORT <<< "$lane_pair"
  read -r CHECKED_STATE_MODEL CHECKED_STATE_EFFORT <<< "$state_pair"
  [ -n "$CHECKED_LANE_MODEL" ] && [ -n "$CHECKED_LANE_EFFORT" ] \
    && [ -n "$CHECKED_STATE_MODEL" ] && [ -n "$CHECKED_STATE_EFFORT" ]
}

codex_live_pin_diagnostic() { # $1=config.toml; checked-in pins already loaded
  local config="$1" live_model live_effort
  if [ ! -r "$config" ]; then
    echo "live Codex pin is '<unreadable at $config>'; checked-in pin is '$CHECKED_LANE_MODEL/$CHECKED_LANE_EFFORT'"
    return 1
  fi
  live_model="$(sed -n 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
                       "$config" | head -1)"
  live_effort="$(sed -n 's/^[[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
                        "$config" | head -1)"
  if [ "$live_model" = "$CHECKED_LANE_MODEL" ] \
     && [ "$live_effort" = "$CHECKED_LANE_EFFORT" ]; then
    return 0
  fi
  echo "live Codex pin is '${live_model:-<unset>}/${live_effort:-<unset>}'; checked-in pin is '$CHECKED_LANE_MODEL/$CHECKED_LANE_EFFORT'"
  return 1
}

run_cli_group() {
  group cli
  # Help is a contract header, not a line interval. Grow each header before
  # asking for help so this case fails against a range that merely happens to
  # fit today's prose.
  local verify_help_fixture="$TMPROOT/verify-help.sh" verify_help
  awk '
    /^# Exit 0 iff/ { print "#   appended/  a newly appended suite remains visible in --help" }
    { print }
  ' scripts/verify.sh > "$verify_help_fixture"
  chmod +x "$verify_help_fixture"
  verify_help="$("$verify_help_fixture" --help 2>/dev/null)"
  local help_groups_complete=1 help_suite
  while IFS= read -r help_suite; do
    [ -n "$help_suite" ] || continue
    printf '%s' "$verify_help" | grep -Fq "  $help_suite/" || help_groups_complete=0
  done < <(sed -n 's/^[[:space:]]*\([^)]*\)) SUITES=.*/\1/p' scripts/verify.sh | tr '|' '\n')
  if printf '%s' "$verify_help" | grep -Fq 'appended/' \
     && [ "$help_groups_complete" = 1 ] \
     && ! grep -Eq -- "-h\\|--help\\).*sed -n '[0-9]+,[0-9]+p'" scripts/verify.sh; then
    ok "verify-help-grows-with-the-group-header"
  else
    bad "verify-help-grows-with-the-group-header" \
        "verify.sh --help lost an accepted/appended group or is pinned to a numeric sed range"
  fi

  local preflight_help_fixture="$TMPROOT/preflight-help.sh" preflight_help
  awk '
    /^# Usage \(on the Mac mini\):/ {
      for (i = 1; i <= 10; i++) print "# Help growth probe " i "."
    }
    { print }
  ' scripts/preflight.sh > "$preflight_help_fixture"
  chmod +x "$preflight_help_fixture"
  preflight_help="$("$preflight_help_fixture" --help 2>/dev/null)"
  if printf '%s' "$preflight_help" | grep -Fq 'Usage (on the Mac mini):' \
     && printf '%s' "$preflight_help" | grep -Fq 'Exit code:' \
     && ! grep -Eq -- "-h\\|--help\\).*sed -n '[0-9]+,[0-9]+p'" scripts/preflight.sh; then
    ok "preflight-help-grows-with-the-header"
  else
    bad "preflight-help-grows-with-the-header" \
        "preflight.sh --help lost its Usage or Exit section after header growth, or is line-pinned"
  fi

  # No early return when hermes is missing: each command is judged (or skipped)
  # on its own, so CI still checks every tool it does have.
  local claims="$TMPROOT/claims.tsv"; : > "$claims"

  # This extractor reads INVOCATIONS: lines that look like `codex exec ...`
  # with the flags beside them. §4's invocation has moved into
  # scripts/codex-run.sh (ADR-0016), where the flags live in a bash array and
  # no executable line reads as a command name. Adding that file here therefore
  # contributes nothing -- measured, not assumed -- and pretending otherwise is
  # how the coverage went missing in the first place. The replacement is
  # `codex-run-flags-exist` below, which reads the array directly.
  local files; files=$(find skills hermes docs -type f \( -name '*.md' -o -name '*.sh' -o -name '*.yaml' \) 2>/dev/null)
  local f line spec rx cmd
  for f in $files; do
    # The audit report itself quotes broken commands as evidence; verifying it
    # would re-report every bug it documents as a live defect.
    case "$f" in docs/audit-*.md) continue;; esac
    while IFS= read -r line; do
      case "$line" in \#*) continue;; esac          # shell comments
      while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        rx="${spec%%|*}"; cmd="${spec##*|}"
        if printf '%s' "$line" | grep -qE -- "$rx"; then
          printf '%s' "$line" | grep -oE -- '--[a-zA-Z][a-zA-Z0-9-]+' \
            | while read -r fl; do printf '%s\t%s\t%s\n' "$cmd" "$fl" "$f" >> "$claims"; done
          break                                      # most specific wins
        fi
      done <<< "$CLI_SPECS"
    done < <(logical_lines "$f")
  done

  if [ ! -s "$claims" ]; then
    bad "flags-exist" "extracted zero flag claims — the extractor is broken, not the repo"
    return
  fi

  local prev_cmd="" allowed="" nclaims=0 nbad=0 nskip=0 usable=1
  while IFS=$'\t' read -r cmd fl file; do
    if [ "$cmd" != "$prev_cmd" ]; then
      prev_cmd="$cmd"
      # An absent binary means we cannot judge its flags. That is a SKIP;
      # treating it as a failure would make CI red for every tool it lacks,
      # and a suite that cries wolf gets switched off.
      if command -v "${cmd%% *}" >/dev/null 2>&1; then
        usable=1; allowed="$(help_flags "$cmd")"
        [ -n "$allowed" ] || { usable=0; skip "flags-exist/$cmd" "--help produced no flags"; }
      else
        usable=0; skip "flags-exist/${cmd%% *}" "not on PATH"
      fi
    fi
    [ "$usable" = 1 ] || { nskip=$((nskip+1)); continue; }
    nclaims=$((nclaims+1))
    if ! printf '%s\n' "$allowed" | grep -qx -- "$fl"; then
      bad "flags-exist" "$file claims '$fl' for '$cmd', which its --help does not list"
      nbad=$((nbad+1))
    fi
  done < <(sort -u "$claims")

  [ "$nbad" = 0 ] && ok "flags-exist ($nclaims flag claims checked against live --help, $nskip unjudgeable)"

  # The coverage flags-exist can no longer reach, restored explicitly.
  #
  # When §4's invocation moved into codex-run.sh, `--add-dir` and
  # `--output-last-message` left the scanned set and the claim count went 16 →
  # 14 with nothing turning red. That is F65/F66's exact shape -- a check
  # anchored to content that moved, degrading silently -- landing on the most
  # load-bearing integration point the lane has.
  #
  # Two-sided on purpose, because either half alone rots: the flag must still
  # be IN the argv the runner builds (what the scraper used to prove), and must
  # still be ACCEPTED by the subcommand it is passed to (what --help proves).
  # `codex exec resume` is checked as its own command: it takes neither -s, -C
  # nor --add-dir, which is the whole reason the resume path restates the
  # sandbox grant as -c overrides.
  local argv_body
  argv_body="$(sed -n '/^build_argv()/,/^}/p' scripts/codex-run.sh | grep -v '^[[:space:]]*#')"
  _codex_accepts() { # <command> <flag>
    # shellcheck disable=SC2086
    $1 --help 2>&1 | grep -qE -- "(^|[[:space:]])$2([[:space:],=]|$)"
  }
  local cr_pair cr_cmd cr_fl cr_missing="" cr_rejected="" cr_n=0
  for cr_pair in 'codex exec|-C'            'codex exec|-s' \
                 'codex exec|--add-dir'     'codex exec|--json' \
                 'codex exec|-m'            'codex exec|--output-last-message' \
                 'codex exec resume|-c'     'codex exec resume|--json' \
                 'codex exec resume|--output-last-message'; do
    cr_cmd="${cr_pair%%|*}"; cr_fl="${cr_pair##*|}"
    # The terminator is "not more flag", not "whitespace": the array literal
    # ends lines as `--json)`, and requiring a space there silently found
    # nothing. Anchoring the START on whitespace is what keeps -m from matching
    # inside --model.
    printf '%s' "$argv_body" \
      | grep -qE -- "(^|[[:space:]])$cr_fl([^A-Za-z0-9_-]|$)" \
      || cr_missing="$cr_missing $cr_cmd/$cr_fl"
    if command -v codex >/dev/null 2>&1; then
      cr_n=$((cr_n + 1))
      _codex_accepts "$cr_cmd" "$cr_fl" || cr_rejected="$cr_rejected $cr_cmd/$cr_fl"
    fi
  done
  if [ -n "$cr_missing" ]; then
    bad "codex-run-flags-exist" "codex-run.sh no longer passes:$cr_missing"
  elif [ -n "$cr_rejected" ]; then
    bad "codex-run-flags-exist" "the live codex --help does not accept:$cr_rejected"
  elif [ "$cr_n" = 0 ]; then
    skip "codex-run-flags-exist" "codex not on PATH; argv shape checked, --help not"
  else
    ok "codex-run-flags-exist ($cr_n flags in the runner's argv, each accepted by its subcommand)"
  fi

  # Skill bodies are executed. A status marker for an unverified claim has no
  # business in one (F5): the reader is a machine that cannot tell aspiration
  # from observation.
  local leaks; leaks=$(grep -rniE '\b(assumed|aspirational|not yet verified|unverified)\b' skills/ 2>/dev/null)
  if [ -n "$leaks" ]; then
    bad "no-unverified-claims-in-skills" "$(printf '%s' "$leaks" | head -3 | tr '\n' ' ')"
  else
    ok "no-unverified-claims-in-skills"
  fi

  # The description budget README states. It was ≤60 while all eight skills were
  # 135–165 chars — a rule nothing met, which is the same failure as a wrong
  # flag: prose the machine is supposed to obey and provably does not.
  local limit=170 over=0 f d n
  for f in skills/*/SKILL.md; do
    d=$(grep -m1 '^description:' "$f" | sed 's/^description: *//')
    n=${#d}
    if [ "$n" -gt "$limit" ]; then
      bad "skill-description-budget" "$f description is $n chars (limit $limit)"; over=1
    fi
    [ -n "$d" ] || { bad "skill-description-budget" "$f has no description"; over=1; }
  done
  [ "$over" = 0 ] && ok "skill-description-budget (all <= $limit chars)"

  # The BODY budget, split in two because one number never fitted both kinds of
  # skill. README asked for "well under ~150" across the board. The seven
  # ceremonies sit at 43–89 and always have; `forge-lane` reached 283 and every
  # attempt to call that a defect stalled, because it is not one — the ceremonies
  # are read by an interactive operator alongside a whole project's context,
  # while `forge-lane` IS the entire job of one dedicated unattended profile,
  # and its length is accumulated measured failures, not prose. Cutting it means
  # deleting the evidence for a defect somebody paid a run to find.
  # So: two budgets, both met, both enforced. The lane's headroom is deliberately
  # thin so the next addition forces a decision instead of drifting again.
  # (README "A limit nothing meets is not a rule" — this is its mirror image.)
  local cer_limit=150 lane_limit=300 body_over=0 lines base
  for f in skills/*/SKILL.md; do
    lines=$(wc -l < "$f" | tr -d ' ')
    base=$(basename "$(dirname "$f")")
    if [ "$base" = "forge-lane" ]; then
      [ "$lines" -le "$lane_limit" ] || {
        bad "skill-body-budget" "$f is $lines lines (lane protocol limit $lane_limit) — split to references/ or re-argue the budget"
        body_over=1; }
    else
      [ "$lines" -le "$cer_limit" ] || {
        bad "skill-body-budget" "$f is $lines lines (ceremony limit $cer_limit) — long material goes to rubrics/ or references/"
        body_over=1; }
    fi
  done
  [ "$body_over" = 0 ] && ok "skill-body-budget (ceremonies <= $cer_limit, lane <= $lane_limit)"

  # A cross-reference is an executable dependency between two prompts. Resolve
  # each named numeric section against the target skill, then mutate the PR
  # section once so the failure path proves it reports the source and target.
  local section_out section_fixture section_mutation
  if section_out="$(check_skill_section_references "$REPO_ROOT")"; then
    ok "skill-section-references-resolve"
  else
    bad "skill-section-references-resolve" "$(printf '%s' "$section_out" | tr '\n' ' ')"
  fi
  section_fixture="$TMPROOT/skill-section-rename"
  mkdir -p "$section_fixture"
  cp -R skills "$section_fixture/skills"
  sed 's/^## 6\. PR$/## 8. PR/' "$section_fixture/skills/forge-lane/SKILL.md" \
    > "$section_fixture/forge-lane.mutated"
  mv "$section_fixture/forge-lane.mutated" "$section_fixture/skills/forge-lane/SKILL.md"
  section_mutation="$(check_skill_section_references "$section_fixture" 2>&1)"; local section_rc=$?
  if [ "$section_rc" -ne 0 ] \
     && printf '%s' "$section_mutation" | grep -Fq "skills/end-chunk/SKILL.md" \
     && printf '%s' "$section_mutation" | grep -Fq "missing heading '§6'"; then
    ok "skill-section-reference-rename-is-named"
  else
    bad "skill-section-reference-rename-is-named" \
        "renaming forge-lane §6 was not reported with its end-chunk source and missing heading (got: ${section_mutation:-no diagnostic})"
  fi

  # The same discipline for the other kind of prompt, which never had a number.
  # A SOUL is a profile's system prompt: read in full on every single run, by
  # the only metered agent in that run. `forge-prejudge` reached 404 lines
  # against 27, 29 and 32 for the other three, and 144 of those were executable
  # bash — a protocol re-enacted by a model rather than executed by bash (F61).
  # The slice that eventually shrank it grew it by 65 lines first, and nothing
  # here could see that happen because no budget covered a SOUL (F62).
  local soul_limit=60 soul_over=0
  for f in hermes/profiles/*.SOUL.md; do
    [ -f "$f" ] || continue
    lines=$(wc -l < "$f" | tr -d ' ')
    [ "$lines" -le "$soul_limit" ] || {
      bad "soul-body-budget" "$f is $lines lines (limit $soul_limit) — a SOUL is identity; protocol belongs in a script under scripts/ (ADR-0010)"
      soul_over=1; }
  done
  [ "$soul_over" = 0 ] && ok "soul-body-budget (all SOULs <= $soul_limit lines)"

  # A fenced executable block in a prompt is a script nobody has written yet.
  # Showing the ONE command a profile runs is legitimate, which is why this
  # bounds block length instead of banning blocks: a usage example is an
  # example, and eleven blocks totalling 144 lines is a program. ADR-0003 put
  # deterministic enforcement in the repo rather than the harness; ADR-0010
  # says the same about what a driver DOES, not only about what it decides.
  local blk_limit=6 blk_over=0 longest
  for f in hermes/profiles/*.SOUL.md; do
    [ -f "$f" ] || continue
    longest=$(awk '/^ *```/{i=!i; if(i){n=0} else if(n>m){m=n}; next} i{n++} END{print m+0}' "$f")
    [ "$longest" -le "$blk_limit" ] || {
      bad "no-programs-in-souls" "$f has a $longest-line fenced block (limit $blk_limit) — that is a program; move it to scripts/ and have the SOUL invoke it (ADR-0010)"
      blk_over=1; }
  done
  [ "$blk_over" = 0 ] && ok "no-programs-in-souls (longest fenced block <= $blk_limit lines)"

  # S2: the flywheel must have somewhere to record whether it worked, and
  # /retro must still be pointed at it. Prose that stops referencing its own
  # metric file is how a measured loop reverts to an accumulating one.
  if [ ! -f docs/retro-metrics.md ]; then
    bad "retro-metrics" "docs/retro-metrics.md is missing — /retro cannot report movement"
  elif ! grep -q '| Retro date |' docs/retro-metrics.md; then
    bad "retro-metrics" "docs/retro-metrics.md has no log table header"
  elif ! grep -q 'retro-metrics' skills/retro/SKILL.md; then
    bad "retro-metrics" "skills/retro/SKILL.md no longer references docs/retro-metrics.md"
  else
    ok "retro-metrics (log table present and referenced by /retro)"
  fi

  # The allowlist is a permission boundary, and a trailing `*` in a Bash pattern
  # spans spaces — so it authorises every additional argument, not just the ones
  # the author had in mind. Two shapes make that expensive here, both measured:
  #
  #   `Bash(make <target> *)`  — make takes MULTIPLE targets. `make metrics
  #     BOARD=x install` really does run ./scripts/metrics.sh AND ./install.sh,
  #     which symlinks skills into every harness on the machine.
  #   `Bash(./scripts/verify.sh <group> *)` — admits `--with-codex`, which
  #     CLAUDE.md calls "spends tokens. Not casual."
  #
  # So a `*` is allowed only behind a command that cannot do anything paid or
  # mutating however it is invoked. Everything else is spelled out exactly. The
  # list below is the whitelist of prefixes permitted to carry a wildcard; adding
  # to it is a deliberate act that should be argued for in the PR that does it.
  local settings='.claude/settings.json'
  if [ ! -f "$settings" ]; then
    bad "permissions-are-read-only" "$settings is missing — the boundary is unasserted"
  elif ! command -v jq >/dev/null 2>&1; then
    skip "permissions-are-read-only" "jq not on PATH"
  else
    local entries wild_ok offenders
    entries="$(jq -r '.permissions.allow[]? // empty' "$settings" 2>/dev/null)"
    if [ -z "$entries" ]; then
      bad "permissions-are-read-only" "no allow entries parsed out of $settings — the check went blind, which is not a pass (F65)"
    else
      # read-only however invoked: a metrics read, three kanban reads, an MCP list
      wild_ok='^Bash\((\./scripts/metrics\.sh|hermes kanban (show|list|assignees)|hermes kanban boards list|codex mcp list) \*\)$'
      offenders="$(printf '%s\n' "$entries" | grep -F '*' | grep -Ev "$wild_ok" || true)"
      if [ -n "$offenders" ]; then
        bad "permissions-are-read-only" \
            "wildcard entries admit paid or mutating commands: $(printf '%s' "$offenders" | tr '\n' ' ')"
      else
        ok "permissions-are-read-only ($(printf '%s\n' "$entries" | grep -c . ) entries, $(printf '%s\n' "$entries" | grep -cF '*') wildcards)"
      fi
    fi
  fi

  # The Codex pin has two checked-in statements: the lane contract and the
  # environment record. This half deliberately never reads $HOME, so CI can
  # catch drift without an operator config. config/codex-pin-live is the live
  # half and prints both pairs when they differ.
  if ! load_checked_in_codex_pins; then
    bad "codex-pin-documented" \
        "could not parse the model-and-effort pair from forge-lane and docs/state.md"
  elif [ "$CHECKED_LANE_MODEL/$CHECKED_LANE_EFFORT" \
       = "$CHECKED_STATE_MODEL/$CHECKED_STATE_EFFORT" ]; then
    ok "codex-pin-documented ($CHECKED_LANE_MODEL/$CHECKED_LANE_EFFORT; offline)"
  else
    bad "codex-pin-documented" \
        "forge-lane pins '$CHECKED_LANE_MODEL/$CHECKED_LANE_EFFORT'; docs/state.md pins '$CHECKED_STATE_MODEL/$CHECKED_STATE_EFFORT'"
  fi

  # ADR-0013 keeps the built-in skills toolset because the lane needs it to
  # load forge-lane. Hermes 0.19 cannot disable only skill_manage, so the
  # generated config's write-approval readback is the enforceable boundary and
  # the ADR must name what staged access remains.
  local skill_policy=1 policy_adr=docs/adr/0013-lane-skill-management.md
  grep -Eq '^  "forge-codex-lane\|.*\|[^" ]*(,[^" ]*)*skills(,[^" ]*)*"$' \
    hermes/profiles-bootstrap.sh || skill_policy=0
  grep -Fq 'echo "  write_approval: true"' hermes/profiles-bootstrap.sh \
    || skill_policy=0
  grep -Fq 'config get skills.write_approval' hermes/profiles-bootstrap.sh \
    || skill_policy=0
  grep -Fq '[ "$got" = "true" ]' hermes/profiles-bootstrap.sh \
    || skill_policy=0
  grep -Fq '# ADR-0013:' hermes/profiles-bootstrap.sh || skill_policy=0
  [ -f "$policy_adr" ] || skill_policy=0
  if [ -f "$policy_adr" ]; then
    grep -Fq '`skills` toolset' "$policy_adr" || skill_policy=0
    grep -Fq '`skills.write_approval=true`' "$policy_adr" || skill_policy=0
    grep -Fq '`skill_manage`' "$policy_adr" || skill_policy=0
    grep -Fq 'stage a proposed skill rewrite' "$policy_adr" || skill_policy=0
    grep -Fq 'cannot apply that rewrite' "$policy_adr" || skill_policy=0
  fi
  if grep -Fq '**Should the lane keep `skill_manage`?**' docs/open-questions.md; then
    skill_policy=0
  fi
  [ "$skill_policy" = 1 ] \
    && ok "lane-skill-management-policy (skills retained; writes approval-gated)" \
    || bad "lane-skill-management-policy" \
        "ADR-0013, generated write_approval readback, retained skills toolset, residual staged write, and open-question retirement must agree"

  # The driver pin is the F22/F36 shape on the metered side. F22 measured what a
  # model pin changing mid-run costs: it confounded the one chunk that failed,
  # because nothing recorded that the pin had moved. F36 found the same staleness
  # in a load-bearing skill body. Both were about Codex; nothing ever watched the
  # *driver*, and on 2026-08-07 MODEL_DRIVER spent a day reading
  # `deepseek-v4-flash-latest-latest` — an id that resolves nowhere — with every
  # check in this repo green. profiles-bootstrap.sh is what republishes the three
  # driver profiles, so that value is one `./hermes/profiles-bootstrap.sh` away
  # from every unattended run.
  #
  # This half is offline, so it belongs HERE rather than in config/: that group
  # returns early without hermes and is not in CI, so the one assertion that
  # could have caught the bad pin on a pull request would never have run. The
  # live comparison stays in config/ as model-pin-live/<profile>.
  #
  # state.md names the bare model without its vendor prefix, so compare on that.
  local pin_drv pin_rtr env_block
  pin_drv="$(sed -n 's/^MODEL_DRIVER="\${FORGE_MODEL_DRIVER:-\([^}"]*\)}".*/\1/p' \
               hermes/profiles-bootstrap.sh | head -1)"
  pin_rtr="$(sed -n 's/^MODEL_ROUTER="\${FORGE_MODEL_ROUTER:-\([^}"]*\)}".*/\1/p' \
               hermes/profiles-bootstrap.sh | head -1)"
  env_block="$(sed -n '/^profiles: forge-orchestrator/,/codex pinned/p' docs/state.md)"
  if [ -z "$pin_drv" ] || [ -z "$pin_rtr" ]; then
    bad "model-pin-documented" \
        "could not read MODEL_DRIVER/MODEL_ROUTER out of hermes/profiles-bootstrap.sh — the check went blind, which is not a pass (F65)"
  elif [ -z "$env_block" ]; then
    bad "model-pin-documented" \
        "docs/state.md has no 'profiles: forge-orchestrator … codex pinned' environment block to compare against"
  elif printf '%s' "$env_block" | grep -Fq "${pin_drv#*/}" \
    && printf '%s' "$env_block" | grep -Fq "${pin_rtr#*/}"; then
    ok "model-pin-documented ($pin_drv)"
  else
    bad "model-pin-documented" \
        "profiles-bootstrap.sh pins '$pin_drv' / '$pin_rtr'; docs/state.md's environment block does not name both"
  fi
}

# ---------------------------------------------------------------------------
# config/ — the invariants, read PER PROFILE. Section 4 of preflight reads the
# default profile; workers do not run there (F11).
# ---------------------------------------------------------------------------
run_config_group() {
  group config
  # Compare the operator's live Codex config with the checked-in pair. First
  # drive a known mismatch through the same helper so a green run proves the
  # required two-value diagnostic rather than only today's agreement.
  local codex_config codex_diag mismatch_config
  if ! load_checked_in_codex_pins; then
    bad "codex-pin-live" "checked-in Codex pin is unreadable; cli/codex-pin-documented also fails"
  elif [ "$CHECKED_LANE_MODEL/$CHECKED_LANE_EFFORT" \
       != "$CHECKED_STATE_MODEL/$CHECKED_STATE_EFFORT" ]; then
    bad "codex-pin-live" \
        "checked-in pins disagree: forge-lane '$CHECKED_LANE_MODEL/$CHECKED_LANE_EFFORT', state '$CHECKED_STATE_MODEL/$CHECKED_STATE_EFFORT'"
  else
    mismatch_config="$TMPROOT/codex-config-mismatch.toml"
    printf 'model = "fixture-wrong"\nmodel_reasoning_effort = "low"\n' > "$mismatch_config"
    codex_diag="$(codex_live_pin_diagnostic "$mismatch_config" 2>&1)"; local codex_diag_rc=$?
    if [ "$codex_diag_rc" -ne 0 ] \
       && printf '%s' "$codex_diag" | grep -Fq "fixture-wrong/low" \
       && printf '%s' "$codex_diag" | grep -Fq "$CHECKED_LANE_MODEL/$CHECKED_LANE_EFFORT"; then
      ok "codex-pin-live-diagnostic-names-both-values"
    else
      bad "codex-pin-live-diagnostic-names-both-values" \
          "known mismatch did not print live and checked-in pairs (got: ${codex_diag:-no diagnostic})"
    fi
    codex_config="${CODEX_HOME:-$HOME/.codex}/config.toml"
    if [ ! -f "$codex_config" ]; then
      skip "codex-pin-live" "$codex_config is absent; no live operator pin to judge"
    elif codex_diag="$(codex_live_pin_diagnostic "$codex_config" 2>&1)"; then
      ok "codex-pin-live ($CHECKED_LANE_MODEL/$CHECKED_LANE_EFFORT)"
    else
      bad "codex-pin-live" "$codex_diag"
    fi
  fi

  if ! command -v hermes >/dev/null 2>&1; then
    skip "per-profile" "hermes not on PATH"; return
  fi
  # An assignee is not a profile (audit F43). `forge-operator-handoff` is the
  # deliberately non-spawnable sentinel the tier-2 hand-off parks on
  # (lane/prejudge-tier2-card-is-sticky), and `forge-operator` is a ghost
  # assignee from the rung-4 row in docs/retro-metrics.md. Both are supposed to
  # have no profile. This group interrogated them anyway and reported six hard
  # failures, so `make verify` exited 1 on the operator's own machine
  # continuously — and a suite that is already red cannot report a new failure.
  # `assignees --json` says which names resolve to a profile; the ones that do
  # not are SKIPPED and named, because a check that could not run has not passed.
  local profs; profs=$(hermes kanban assignees --json 2>/dev/null \
    | jq -r '.[]|select(.name|test("^forge-[a-z-]+$"))|select(.on_disk)|.name' | sort -u)
  local ghosts; ghosts=$(hermes kanban assignees --json 2>/dev/null \
    | jq -r '.[]|select(.name|test("^forge-[a-z-]+$"))|select(.on_disk|not)|.name' | sort -u)
  if [ -z "$profs" ]; then
    bad "per-profile" "no forge-* profiles are known assignees"; return
  fi
  local g
  for g in $ghosts; do
    skip "per-profile/$g" "assignee with no profile on disk — sentinel or ghost, not spawnable"
  done

  # preflight.sh must answer "which profiles are real" the same way this group
  # does. It did not: it took every forge-* assignee regardless of on_disk, so
  # `forge-operator` (a ghost) and `forge-operator-handoff` (the tier-2
  # sentinel, which MUST be absent) were interrogated for config they cannot
  # have — six FAILs and "not ready for unattended work" on a system that was
  # correct. This group had already been fixed for exactly that as audit F43;
  # the fix was never carried across. A readiness gate that reddens when the
  # system is right teaches its operator to ignore it.
  #
  # And the sentinel must be read from where the hand-off lives now. preflight
  # sed'd it out of forge-prejudge.SOUL.md, which was right until ADR-0010
  # moved the protocol into scripts/prejudge-review.sh — after which it matched
  # nothing and the check reported its own blindness as a WARN. F65's shape.
  if grep -q 'on_disk' scripts/preflight.sh \
     && grep -q 'route_tier2' scripts/preflight.sh \
     && ! grep -q 'forge-prejudge.SOUL.md" 2>/dev/null | head -1' scripts/preflight.sh; then
    ok "preflight-agrees-about-real-profiles"
  else
    bad "preflight-agrees-about-real-profiles" \
        "preflight must filter assignees by on_disk (F43) and read the tier-2 sentinel out of route_tier2() in prejudge-review.sh, not out of the SOUL (F65)"
  fi
  # The live half of the driver pin; the offline half is cli/model-pin-documented,
  # which lives in the cli group deliberately — this group skips wholesale
  # without hermes, so an offline assertion placed here would never run in CI.
  local pin_drv pin_rtr
  pin_drv="$(sed -n 's/^MODEL_DRIVER="\${FORGE_MODEL_DRIVER:-\([^}"]*\)}".*/\1/p' \
               hermes/profiles-bootstrap.sh | head -1)"
  pin_rtr="$(sed -n 's/^MODEL_ROUTER="\${FORGE_MODEL_ROUTER:-\([^}"]*\)}".*/\1/p' \
               hermes/profiles-bootstrap.sh | head -1)"

  local p v
  for p in $profs; do
    v="$(hermes -p "$p" config get terminal.timeout 2>/dev/null | tail -1)"
    if printf '%s' "$v" | grep -qE '^[0-9]+$' && [ "$v" -ge 1800 ]; then
      ok "terminal-timeout/$p ($v)"
    else
      bad "terminal-timeout/$p" "got '${v:-unset}', need >=1800 or 'make check' is killed mid-run"
    fi

    v="$(hermes -p "$p" config get skills.write_approval 2>/dev/null | tail -1)"
    [ "$v" = "true" ] && ok "write-approval/$p" \
      || bad "write-approval/$p" "got '${v:-unset}', ADR-0005's consent gate needs true"

    # F49. The profiles are bootstrapped once, against the MAIN checkout. F40
    # requires every slice to run in a linked worktree — where this check can
    # only ever be false, because a worktree's skills/ is not the directory the
    # live profiles load. Judged against $REPO_ROOT it made `make verify` red by
    # construction in the one place the audit mandates working, which is the
    # same disarming F43 describes. So: a match on this checkout passes; a match
    # on the main checkout, from a linked worktree, SKIPS with the consequence
    # stated — the skills you are editing are not the ones a run would read.
    v="$(hermes -p "$p" config get skills.external_dirs 2>/dev/null)"
    case "$v" in
      *"$REPO_ROOT/skills"*) ok "external-dirs/$p";;
      *"$MAIN_ROOT/skills"*)
        skip "external-dirs/$p" "points at the main checkout $MAIN_ROOT/skills; edits in this worktree are not live for any run";;
      *) bad "external-dirs/$p" "does not point at $REPO_ROOT/skills (got '${v:-unset}')";;
    esac

    # A SOUL edited in git does NOT reach the worker: profiles-bootstrap.sh
    # copies it into ~/.hermes/profiles/<p>/SOUL.md. Nothing else notices the
    # drift, so a fix can look committed and merged while every run still uses
    # the old identity. Measured 2026-07-28: the prejudge tier-2 fix was dead
    # in the repo until the bootstrap was re-run.
    if [ -f "hermes/profiles/$p.SOUL.md" ]; then
      if diff -q "$HOME/.hermes/profiles/$p/SOUL.md" "hermes/profiles/$p.SOUL.md" \
           >/dev/null 2>&1; then
        ok "soul-in-sync/$p"
      else
        bad "soul-in-sync/$p" "live SOUL differs from git — run ./hermes/profiles-bootstrap.sh"
      fi
    fi

    # The live half of the driver pin. Same failure shape as soul-in-sync: the
    # value can be correct in git and stale on the worker, and only a republish
    # closes the gap. Reported as a WARN-equivalent skip rather than a failure
    # when the pin is merely un-republished would be wrong — an unattended run
    # uses the LIVE value, so a divergence is a real defect, not a caveat.
    if [ -n "$pin_drv" ] && [ -n "$pin_rtr" ]; then
      local want live
      case "$p" in forge-orchestrator) want="$pin_rtr";; *) want="$pin_drv";; esac
      live="$(hermes -p "$p" config get model.default 2>/dev/null | tail -1)"
      if [ -z "$live" ]; then
        skip "model-pin-live/$p" "could not read model.default from the live profile"
      elif [ "$live" = "$want" ]; then
        ok "model-pin-live/$p"
      else
        bad "model-pin-live/$p" \
            "live model.default is '$live', profiles-bootstrap.sh pins '$want' — run ./hermes/profiles-bootstrap.sh"
      fi
    fi
  done

  # F13: the unattended lane must not have the interactive ceremonies loaded.
  local enabled
  enabled="$(hermes -p forge-codex-lane skills list --source local --enabled-only 2>/dev/null)"
  if printf '%s' "$enabled" | grep -qE '(start-chunk|end-chunk)'; then
    bad "lane-skill-scope" "start-chunk/end-chunk are enabled for forge-codex-lane"
  else
    ok "lane-skill-scope"
  fi

  # F1: a worktree card with no workspace_path anchors on the board's
  # default_workdir. Unset, the first card auto-blocks on tick 1.
  local boards unanchored
  boards="$(hermes kanban boards list --json 2>/dev/null)"
  if [ -n "$boards" ]; then
    unanchored="$(printf '%s' "$boards" \
      | jq -r '.[]|select(.archived==false and (.slug|startswith("forge")) and (.default_workdir==null))|.slug')"
    [ -z "$unanchored" ] && ok "board-default-workdir" \
      || bad "board-default-workdir" "forge board(s) with no default_workdir: $(printf '%s' "$unanchored" | tr '\n' ' ')"
  else
    skip "board-default-workdir" "no board list"
  fi
}

# ---------------------------------------------------------------------------
# substrate/ — behaviours we depend on and do not control. These are upgrade
# canaries: they must fail a check, not a night run.
# ---------------------------------------------------------------------------
run_substrate_group() {
  group substrate

  # F2: the dispatcher materialises the worktree BEFORE spawning the worker.
  # forge-lane tells the worker never to create it, which is only safe while
  # this holds. Read the installed source; a hermes upgrade could change it.
  local kdb="$HOME/.hermes/hermes-agent/hermes_cli/kanban_db.py"
  if [ -f "$kdb" ]; then
    local res_line spawn_line
    res_line=$(grep -n '_resolve_worktree_workspace(claimed' "$kdb" | head -1 | cut -d: -f1)
    spawn_line=$(awk -v s="${res_line:-0}" 'NR>s && /_spawn = spawn_fn/ {print NR; exit}' "$kdb")
    if [ -n "$res_line" ] && [ -n "$spawn_line" ] && [ "$res_line" -lt "$spawn_line" ]; then
      ok "worktree-ownership (resolve@$res_line before spawn@$spawn_line)"
    else
      bad "worktree-ownership" "dispatch order changed: forge-lane assumes the worktree already exists"
    fi
  else
    skip "worktree-ownership" "hermes source not found"
  fi

  # F9: in a linked worktree .git is a FILE. Anything writing .git/<path>
  # cannot work, which is why PR bodies live in .forge/.
  local lab="$LABROOT/wt"; rm -rf "$LABROOT"; mkdir -p "$lab"
  (
    cd "$lab" || exit 1
    git init -q -b main . >/dev/null 2>&1
    printf 'setup:\n\t@true\ncheck:\n\t@true\n' > Makefile
    git add Makefile >/dev/null 2>&1
    git -c user.email=v@v -c user.name=v commit -qm init >/dev/null 2>&1
    git remote add origin "$lab"
    git worktree add -q ../linked -b probe >/dev/null 2>&1
  )
  if [ -e "$LABROOT/linked/.git" ] && [ ! -d "$LABROOT/linked/.git" ]; then
    if (echo x > "$LABROOT/linked/.git/PROBE") 2>/dev/null; then
      bad "worktree-gitfile" ".git accepted a write — the .forge/ rationale no longer holds"
    else
      ok "worktree-gitfile (.git is a file; writes under it fail)"
    fi
  else
    bad "worktree-gitfile" ".git in a linked worktree is not a file — assumption changed"
  fi

  # The `--json` shapes are NOT uniform across subcommands, and jq answers a
  # wrong path with `null` rather than an error — so a script reading the wrong
  # one does not fail, it quietly reports nothing. Measured 2026-07-28 while
  # watching CHUNK-C3: `.status` on `show --json` returned null for four
  # minutes while the card was in fact running, and `.metadata` returned null
  # while complete metadata sat under `.runs[]`. board-bootstrap.sh depends on
  # two of these three shapes, so a Hermes change here breaks dispatch silently.
  if ! command -v hermes >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    skip "kanban-json-shapes" "hermes or jq not on PATH"
  else
    local shape_err="" a_board a_task
    a_board="$(hermes kanban boards list --json 2>/dev/null \
               | jq -r 'if type=="array" and (.[0]|has("slug")) then "ok" else "bad" end' 2>/dev/null)"
    [ "$a_board" = "ok" ] || shape_err="boards list --json is not an array of objects with .slug"
    a_task="$(hermes kanban boards list --json 2>/dev/null \
              | jq -r '.[0].slug // empty' 2>/dev/null)"
    if [ -n "$a_task" ]; then
      local one
      one="$(HERMES_KANBAN_BOARD="$a_task" hermes kanban list --json 2>/dev/null \
             | jq -r '(.tasks // .)[0].id // empty' 2>/dev/null)"
      if [ -n "$one" ]; then
        HERMES_KANBAN_BOARD="$a_task" hermes kanban show "$one" --json 2>/dev/null \
          | jq -e '.task.status' >/dev/null 2>&1 \
          || shape_err="${shape_err:+$shape_err; }show --json no longer nests the card under .task"
      fi
    fi
    # board-bootstrap.sh now reads `.on_disk` per assignee to decide whether a
    # lane assignee really exists. The predecessor check was an unanchored
    # `grep` over the human-readable listing, which matched a profile shown
    # as `ON DISK: no` just as happily as one shown `ON DISK: yes` — it
    # passed for exactly the nonexistent profile it existed to catch. This
    # is a SHAPE claim only (the field is present and boolean); whether the
    # value is trustworthy for any one profile is a semantics question for
    # config/, not here.
    if ! hermes kanban assignees --json 2>/dev/null \
        | jq -e 'type=="array" and length>0 and all(.[]; has("on_disk") and (.on_disk|type)=="boolean")' \
        >/dev/null 2>&1; then
      shape_err="${shape_err:+$shape_err; }assignees --json no longer carries a boolean .on_disk per entry"
    fi
    if [ -z "$shape_err" ]; then
      ok "kanban-json-shapes (boards list = array; show = nested under .task; assignees carries .on_disk)"
    else
      bad "kanban-json-shapes" "$shape_err"
    fi
  fi

  # kanban-card-parking-semantics: the outage kanban-json-shapes cannot see.
  # 855e03d's fake `hermes` echoed back whatever --initial-status it was
  # passed, so `--initial-status running` produced a card reporting running
  # and the bootstrap suite went green while the real kernel can never
  # return that status — it fired on every interactive chunk, on every
  # board, every time (PR #56). kanban-json-shapes pins the SHAPE of these
  # JSON replies; nothing pinned their SEMANTICS. This does, against the
  # real installed `hermes` (never a stub), in an isolated HERMES_HOME so
  # nothing here can touch the operator's real boards — including the one a
  # live gateway is dispatching against right now. Every card carries an
  # explicit --assignee so kanban.default_assignee (which resolves globally
  # and IS `builder` on this host) can never auto-adopt one of ours; the
  # sentinel `forge-operator-handoff` is the one `scripts/preflight.sh`
  # asserts never resolves to a real profile, so even a card that reaches
  # ready is inert.
  #
  # Three assertions, each with a positive control an assertion with only a
  # negative case is worthless — a nonzero exit from a typo'd id looks
  # identical to a guard working, so every refusal below is paired with a
  # call of the same shape that must succeed.
  if [ "$WITH_HERMES" != 1 ]; then
    skip "kanban-card-parking-semantics/create-never-yields-running" \
         "needs --with-hermes (creates/blocks/dispatches a real, disposable board)"
    skip "kanban-card-parking-semantics/block-refuses-from-todo" \
         "needs --with-hermes (creates/blocks/dispatches a real, disposable board)"
    skip "kanban-card-parking-semantics/stickiness-is-the-event-not-the-status" \
         "needs --with-hermes (creates/blocks/dispatches a real, disposable board)"
  elif ! command -v hermes >/dev/null 2>&1; then
    skip "kanban-card-parking-semantics/create-never-yields-running" "hermes not on PATH"
    skip "kanban-card-parking-semantics/block-refuses-from-todo" "hermes not on PATH"
    skip "kanban-card-parking-semantics/stickiness-is-the-event-not-the-status" "hermes not on PATH"
  elif ! command -v jq >/dev/null 2>&1; then
    skip "kanban-card-parking-semantics/create-never-yields-running" "jq not on PATH"
    skip "kanban-card-parking-semantics/block-refuses-from-todo" "jq not on PATH"
    skip "kanban-card-parking-semantics/stickiness-is-the-event-not-the-status" "jq not on PATH"
  else
    # An isolated root, not the operator's ~/.hermes: get_default_hermes_root()
    # (hermes_constants.py) only redirects when HERMES_HOME resolves OUTSIDE
    # the platform native home and is not a `.../profiles/<name>` leaf — both
    # true for a path under $TMPROOT — so every kanban_db.py path (including
    # dispatch's) reads and writes only this throwaway root. Confirmed by
    # reading that function and by running create/dispatch against a scratch
    # HERMES_HOME while authoring this case; a stray board here cannot reach
    # a real gateway. The slug still carries a timestamp+pid and is still
    # hard-deleted below: this case pins `boards create`/`boards rm --delete`
    # too, and the same silent-leak failure would matter for real on a
    # long-lived install.
    local park_home="$TMPROOT/parking-home"
    local park_board="verify-park-$(date +%s)-$$"
    mkdir -p "$park_home"
    local create_board_out create_board_rc board_setup_err=""
    create_board_out="$(HERMES_HOME="$park_home" hermes kanban boards create "$park_board" 2>&1)"
    create_board_rc=$?
    [ "$create_board_rc" = 0 ] || board_setup_err=" (board create rc=$create_board_rc: $(printf '%s' "$create_board_out" | tail -2 | tr '\n' ' '))"
    _pk() { HERMES_HOME="$park_home" hermes kanban --board "$park_board" "$@"; }

    # --- 1: create never yields running ---------------------------------
    # create_task only special-cases initial_status=='blocked' (kanban_db.py
    # ~3444); every other value, INCLUDING 'running', falls straight through
    # to the ordinary ready/todo derivation (~3450-3465) — there is no code
    # path in create_task that ever writes status='running'. Prove the field
    # is real, not hardcoded, on two parent shapes at once: a genuine
    # derivation differs between them (ready vs todo); a stub that merely
    # refuses 'running' by returning one fixed status would not.
    local a1_ok=1 a1_msg=""
    local park_parent park_noparent park_withparent
    park_parent="$(_pk create "parking-semantics: parent for #1" \
                     --assignee forge-operator-handoff --json 2>/dev/null | jq -r '.id // empty')"
    park_noparent="$(_pk create "parking-semantics: initial-status running, no parent" \
                       --initial-status running --assignee forge-operator-handoff --json 2>/dev/null \
                       | jq -r '.status // empty')"
    park_withparent="$(_pk create "parking-semantics: initial-status running, live parent" \
                         --initial-status running --parent "$park_parent" \
                         --assignee forge-operator-handoff --json 2>/dev/null | jq -r '.status // empty')"
    if [ -z "$park_parent" ]; then
      a1_ok=0; a1_msg="setup failed: could not create the parent card${board_setup_err}"
    elif [ "$park_noparent" = running ] || [ "$park_withparent" = running ]; then
      a1_ok=0
      a1_msg="--initial-status running produced status=running (noparent=$park_noparent withparent=$park_withparent) — the exact outage 855e03d fixed the STUB for; create_task has no 'running' outcome (kanban_db.py ~3440-3465)"
    elif [ "$park_noparent" = ready ] && [ "$park_withparent" = todo ]; then
      a1_msg="no parent -> ready, live (non-done) parent -> todo, neither ever running"
    else
      a1_ok=0
      a1_msg="expected ready (no parent) / todo (live parent), got noparent=$park_noparent withparent=$park_withparent — the positive control failed, so the refusal of 'running' above proves nothing"
    fi

    # --- 2: block refuses from todo --------------------------------------
    # block_task guards every UPDATE that reaches 'blocked' with
    # `AND status IN ('running','ready')` (kanban_db.py ~6320, ~6378,
    # ~6417/6432). A todo card matches neither and block_task returns False
    # without writing anything. Positive control: the identical call against
    # a ready card must succeed AND leave a 'blocked' EVENT behind —
    # assertion #3 below depends on that event existing, not just on the
    # status column moving.
    local a2_ok=1 a2_msg=""
    local blk_parent blk_todo blk_ready
    blk_parent="$(_pk create "parking-semantics: parent for #2" \
                    --assignee forge-operator-handoff --json 2>/dev/null | jq -r '.id // empty')"
    blk_todo="$(_pk create "parking-semantics: todo card, block must refuse" \
                  --parent "$blk_parent" --assignee forge-operator-handoff --json 2>/dev/null \
                  | jq -r '.id // empty')"
    blk_ready="$(_pk create "parking-semantics: ready card, block must succeed" \
                   --assignee forge-operator-handoff --json 2>/dev/null | jq -r '.id // empty')"
    local blk_todo_out blk_todo_rc blk_todo_status
    blk_todo_out="$(_pk block "$blk_todo" "must be refused: card is todo" 2>&1)"
    blk_todo_rc=$?
    blk_todo_status="$(_pk show "$blk_todo" --json 2>/dev/null | jq -r '.task.status // empty')"
    local blk_ready_out blk_ready_rc blk_ready_status blk_ready_events
    blk_ready_out="$(_pk block "$blk_ready" "must succeed: card is ready" --kind needs_input 2>&1)"
    blk_ready_rc=$?
    blk_ready_status="$(_pk show "$blk_ready" --json 2>/dev/null | jq -r '.task.status // empty')"
    blk_ready_events="$(_pk show "$blk_ready" --json 2>/dev/null | jq -r '[.events[]?.kind] | join(",")')"
    if [ -z "$blk_parent" ] || [ -z "$blk_todo" ] || [ -z "$blk_ready" ]; then
      a2_ok=0; a2_msg="setup failed: could not create the parent/todo/ready cards${board_setup_err}"
    elif [ "$blk_todo_rc" = 0 ]; then
      a2_ok=0
      a2_msg="block against a todo card exited 0 — the status IN ('running','ready') guard is gone: $blk_todo_out"
    elif [ "$blk_todo_status" != todo ]; then
      a2_ok=0
      a2_msg="block on a todo card was refused (rc=$blk_todo_rc) but still left status=$blk_todo_status — a refusal must be side-effect free"
    elif [ "$blk_ready_rc" != 0 ]; then
      a2_ok=0
      a2_msg="block on a ready card was refused too (rc=$blk_ready_rc) — the positive control failed, so the todo refusal above proves nothing: $blk_ready_out"
    elif [ "$blk_ready_status" != blocked ] || ! printf '%s' "$blk_ready_events" | grep -q 'blocked'; then
      a2_ok=0
      a2_msg="block on a ready card did not land on status=blocked with a blocked event: status=$blk_ready_status events=$blk_ready_events"
    else
      a2_msg="todo refused with status unchanged (rc=$blk_todo_rc); ready blocked to status=blocked with a blocked event"
    fi

    # --- 3: stickiness is the EVENT, not the status column ---------------
    # THE CROWN JEWEL. _has_sticky_block (kanban_db.py ~4443-4478) reads the
    # most recent blocked/unblocked EVENT row, not the status column, and
    # recompute_ready (~4510-4599) skips exactly the cards where that read
    # says 'blocked'. Card A is blocked through kanban_block, so it carries
    # that event. Card B is parked with --initial-status blocked at CREATE
    # time: create_task (~3444, INSERT + _append_event around ~3491-3552)
    # writes status='blocked' and appends only a 'created' event — reading
    # both call sites end to end, nothing there ever appends a
    # 'blocked'/'unblocked' event for a create-time park. So recompute_ready
    # must promote B once its parent is done, and must leave A alone.
    #
    # complete_task calls recompute_ready synchronously in the SAME call
    # (kanban_db.py:5579, "Recompute ready status for dependents"), so B is
    # normally already promoted by the time `complete` returns, before any
    # dispatch. That is still real coverage, not a shortcut: this tier
    # exists to catch Hermes drift, and either recompute_ready call site
    # regressing — complete's inline one or the dispatcher's — must turn
    # this assertion red. The case also forces one explicit dispatch tick,
    # both because that is the mechanism asked for and because it proves the
    # dispatcher's own path is idempotent (does not un-stick A):
    # `dispatch --dry-run --max 0` still runs the sweep —
    # `_dispatch_once_locked` calls `recompute_ready(conn, ...)`
    # unconditionally at kanban_db.py:10004, before the first `if not
    # dry_run:` gate (line 10165) and before the `max_spawn` early-return
    # (~10021-10024) that `--max 0` triggers on the very next tick. Those
    # later gates withhold only the default-assignee persist and the spawn
    # itself, never the promotion — confirmed by reading
    # `_dispatch_once_locked` end to end, not by running dispatch against a
    # live board. `--max 0` is kept anyway: at ~10021-10024,
    # `max_spawn is not None and running_count >= max_spawn` is true for
    # any running_count once max_spawn=0, so the tick returns right after
    # computing it — before the ready-row loop even starts. result.spawned
    # and result.skipped_nonspawnable are therefore always empty here and
    # are deliberately not asserted on — a check that can never fire is
    # exactly this bug's class.
    local a3_ok=1 a3_msg=""
    local sk_parent sk_a sk_b sk_b_events
    sk_parent="$(_pk create "parking-semantics: parent for #3" \
                   --assignee forge-operator-handoff --json 2>/dev/null | jq -r '.id // empty')"
    sk_a="$(_pk create "parking-semantics: card A, event-blocked" \
              --assignee forge-operator-handoff --json 2>/dev/null | jq -r '.id // empty')"
    _pk block "$sk_a" "sticky: worker/operator block" --kind needs_input >/dev/null 2>&1
    sk_b="$(_pk create "parking-semantics: card B, status-only blocked" \
              --initial-status blocked --assignee forge-operator-handoff --json 2>/dev/null \
              | jq -r '.id // empty')"
    sk_b_events="$(_pk show "$sk_b" --json 2>/dev/null | jq -r '[.events[]?.kind] | join(",")')"
    _pk link "$sk_parent" "$sk_a" >/dev/null 2>&1
    _pk link "$sk_parent" "$sk_b" >/dev/null 2>&1
    _pk complete "$sk_parent" --result "parking-semantics probe" >/dev/null 2>&1
    _pk dispatch --dry-run --max 0 --json >"$TMPROOT/parking-dispatch.json" 2>&1
    local sk_a_status sk_b_status
    sk_a_status="$(_pk show "$sk_a" --json 2>/dev/null | jq -r '.task.status // empty')"
    sk_b_status="$(_pk show "$sk_b" --json 2>/dev/null | jq -r '.task.status // empty')"
    if [ -z "$sk_parent" ] || [ -z "$sk_a" ] || [ -z "$sk_b" ]; then
      a3_ok=0; a3_msg="setup failed: could not create the parent/A/B cards${board_setup_err}"
    elif printf '%s' "$sk_b_events" | grep -q 'blocked'; then
      a3_ok=0
      a3_msg="setup is void: card B (--initial-status blocked) carries a blocked/unblocked EVENT (events=$sk_b_events) — create_task now emits one, so this run cannot distinguish event-blocked from status-only-blocked"
    elif [ "$sk_a_status" = "$sk_b_status" ] && [ "$sk_a_status" = blocked ]; then
      a3_ok=0
      a3_msg="both A and B are STILL blocked after complete+dispatch — the promotion sweep did not run (recompute_ready was not reached by complete_task:5579 or dispatch:10004); without this exact message this case would pass forever while detecting nothing, which is the vacuity it exists to prevent (dispatch said: $(tr '\n' ' ' < "$TMPROOT/parking-dispatch.json" | cut -c1-300))"
    elif [ "$sk_a_status" != blocked ]; then
      a3_ok=0
      a3_msg="card A (blocked via a real kanban_block EVENT) was promoted anyway to $sk_a_status — the #28712 sticky-block guard (_has_sticky_block, kanban_db.py ~4443-4478) no longer distinguishes an event-blocked card from a status-only one"
    elif [ "$sk_b_status" != ready ]; then
      a3_ok=0
      a3_msg="card B (status-only blocked, no event) was not promoted (status=$sk_b_status) even though A correctly stayed blocked — the positive control failed, so A staying blocked proves nothing"
    else
      a3_msg="A (real blocked event) stayed blocked; B (status column only, no event) was promoted to ready"
    fi

    # --- cleanup: the throwaway board must not survive this run ----------
    # The isolated HERMES_HOME above is removed by the top-level
    # `trap cleanup EXIT` regardless of what happens below, so nothing here
    # can leak into a real installation — but the delete is still asserted
    # explicitly, on every path including failure, because a silent failure
    # here would be exactly as silent against a real long-lived Hermes
    # install, where a leftover board is one a live gateway dispatcher ticks
    # forever.
    local cleanup_ok=1 cleanup_msg="" del_out del_rc still_there
    del_out="$(HERMES_HOME="$park_home" hermes kanban boards rm --delete "$park_board" 2>&1)"
    del_rc=$?
    still_there="$(HERMES_HOME="$park_home" hermes kanban boards list --all --json 2>/dev/null \
                    | jq -e --arg s "$park_board" 'any(.[]?; .slug == $s)' 2>/dev/null)"
    if [ "$del_rc" != 0 ] || [ "$still_there" = "true" ]; then
      cleanup_ok=0
      cleanup_msg="board $park_board was not fully deleted (rc=$del_rc, still listed=${still_there:-unknown}): $(printf '%s' "$del_out" | tail -2 | tr '\n' ' ')"
    fi
    unset -f _pk

    # A failed message must never read as if a passing assertion's own text
    # were the reason for failure — an operator reading this at 2am should
    # see immediately that the KERNEL held and the FIXTURE leaked, not have
    # to parse a success sentence sitting in front of "ALSO:".
    _park_report() {
      local name="$1" this_ok="$2" this_msg="$3"
      if [ "$this_ok" = 1 ] && [ "$cleanup_ok" = 1 ]; then
        ok "kanban-card-parking-semantics/$name ($this_msg)"
      elif [ "$this_ok" = 1 ]; then
        bad "kanban-card-parking-semantics/$name" \
            "kernel semantics held (${this_msg}) but cleanup failed: $cleanup_msg"
      elif [ "$cleanup_ok" = 1 ]; then
        bad "kanban-card-parking-semantics/$name" "$this_msg"
      else
        bad "kanban-card-parking-semantics/$name" "${this_msg}; ALSO cleanup failed: $cleanup_msg"
      fi
    }
    _park_report create-never-yields-running "$a1_ok" "$a1_msg"
    _park_report block-refuses-from-todo "$a2_ok" "$a2_msg"
    _park_report stickiness-is-the-event-not-the-status "$a3_ok" "$a3_msg"
    unset -f _park_report
  fi

  # F15: codex `workspace-write` cannot commit inside a worktree without
  # --add-dir on the git common dir. Costs tokens, so it is opt-in.
  if [ "$WITH_CODEX" != 1 ]; then
    skip "codex-worktree-commit" "needs --with-codex (spends tokens)"
  elif ! command -v codex >/dev/null 2>&1; then
    skip "codex-worktree-commit" "codex not on PATH"
  else
    local out common live_run setup_out audit_out check_ok=0
    # The audit root is redirected like every other lane case. Without this the
    # live probe writes run state into the operator's real ~/.forge/lane-audits
    # and never reaps it — a test that litters the directory it is testing.
    local live_audit="$TMPROOT/live-lane-audits"
    common=$(git -C "$LABROOT/linked" rev-parse --git-common-dir)
    live_run="verify-codex-$(date +%s)-$$"
    setup_out="$(env FORGE_LANE_AUDIT_ROOT="$live_audit" \
                 $REPO_ROOT/scripts/lane-setup.sh "$LABROOT/linked" "$live_run" 2>&1)"
    if [ "$?" != 0 ]; then
      bad "codex-worktree-commit" \
          "live lane setup/capture failed: $(printf '%s' "$setup_out" | tail -2 | tr '\n' ' ')"
      return
    fi
    # The audit is filed under the key setup EMITS, never the bare run id. Since
    # ba933ff that key carries the board (`<board>-<run-id>`, and `_noboard-…`
    # here because HERMES_KANBAN_BOARD is unset in the suite). Consume it exactly
    # as skills/forge-lane/SKILL.md §5 does.
    #
    # This probe recomputed it and drifted the moment the key changed: it is
    # SKIPPED without --with-codex, so neither CI nor a plain `verify.sh` run
    # could see it, and the break surfaced only in the paid commissioning gate
    # (2026-09-02, JobApp) — after the slice that caused it had already merged.
    # `prejudge/lane-audit-key-is-emitted` below now guards the same rule for
    # free, so the token-spending case is no longer the only witness.
    local live_key
    live_key="$(printf '%s' "$setup_out" | sed -n 's/^FORGE_LANE_RUN_KEY=//p' | tail -1)"
    if [ -z "$live_key" ]; then
      bad "codex-worktree-commit" \
          "lane-setup emitted no FORGE_LANE_RUN_KEY — the audit key contract is broken"
      return
    fi
    out=$(cd "$LABROOT/linked" && codex exec -s workspace-write \
            --ephemeral --ignore-user-config \
            --add-dir "$common" \
            "create a file probe.txt containing hi, then git add and git commit it" \
            </dev/null 2>&1)
    make -C "$LABROOT/linked" check >/dev/null 2>&1 && check_ok=1
    audit_out="$(env FORGE_LANE_AUDIT_ROOT="$live_audit" \
                 $REPO_ROOT/scripts/lane-blast-radius.sh \
                   check "$LABROOT/linked" "$live_key" 2>&1)"
    # Assert the FILE is in HEAD, not merely that some commit exists — the lab
    # repo already has an `init` commit, so "log is non-empty" proves nothing.
    # (Do not pipe `git log` into `grep -q`: grep exits early, git takes SIGPIPE,
    # and pipefail then reports a failure that did not happen.)
    if git -C "$LABROOT/linked" cat-file -e HEAD:probe.txt 2>/dev/null \
       && [ "$check_ok" = 1 ] \
       && [ -f "$live_audit/$live_key/check.complete" ] \
       && [ "$audit_out" = \
            "blast-radius: clean — protected Git state unchanged, task commit surfaces only" ]; then
      # The run id is the citation. `state.md` and the audit ledger record which
      # run proved the lane, and a claim naming a run nobody can identify is the
      # kind ADR-0003 exists to stop — so print it rather than making the
      # operator reconstruct it from a cleaned-up temp directory.
      ok "codex-worktree-commit (live setup → immutable capture → Codex commit → final audit; key $live_key)"
    else
      bad "codex-worktree-commit" \
          "live lane proof failed: codex=$(printf '%s' "$out" | tail -2 | tr '\n' ' ') audit=$(printf '%s' "$audit_out" | tail -2 | tr '\n' ' ')"
    fi
  fi
}

# ---------------------------------------------------------------------------
# template/ — a fresh stamp must install hooks and come up green (F8).
# ---------------------------------------------------------------------------
run_template_group() {
  group template
  if ! command -v uvx >/dev/null 2>&1; then
    skip "stamp-setup-check" "uvx not on PATH"; return
  fi
  local dest="$TMPROOT/probe"
  # --defaults, and only project_name: every other question must have a usable
  # default, or `make new` cannot run unattended (copier demands a TTY).
  if ! uvx copier copy --defaults --data project_name="verify-probe" \
        templates/python-service "$dest" >"$TMPROOT/copier.log" 2>&1; then
    bad "stamp" "copier failed: $(tail -2 "$TMPROOT/copier.log" | tr '\n' ' ')"; return
  fi
  ok "stamp"

  # Dispatcher worktrees live at <repo>/.worktrees/<task-id>. Git does not
  # ignore them on its own, so without this they are untracked content that a
  # `git add -A` inside a lane will stage.
  if grep -q '^\.worktrees/' "$dest/.gitignore"; then
    ok "gitignores-worktrees"
  else
    bad "gitignores-worktrees" ".worktrees/ not ignored — dispatcher worktrees are untracked content"
  fi

  git -C "$dest" init -q -b main >/dev/null 2>&1
  if ! make -C "$dest" setup >"$TMPROOT/setup.log" 2>&1; then
    bad "setup" "make setup failed: $(tail -3 "$TMPROOT/setup.log" | tr '\n' ' ')"; return
  fi
  ok "setup"

  if [ -f "$dest/.git/hooks/pre-push" ] && grep -q lefthook "$dest/.git/hooks/pre-push"; then
    ok "hooks-installed"
  else
    bad "hooks-installed" "no lefthook pre-push hook after make setup — ADR-0003's local tier is prose"
  fi

  if make -C "$dest" check >"$TMPROOT/check.log" 2>&1 && grep -q 'FORGE CHECK: GREEN' "$TMPROOT/check.log"; then
    ok "check-green"
  else
    bad "check-green" "make check not green: $(tail -3 "$TMPROOT/check.log" | tr '\n' ' ')"
  fi

  # The pre-push gate, exercised against a real bare remote rather than read.
  # Two states, opposite verdicts: the FIRST push to main is what creates the
  # branch (no PR path exists yet) and must be allowed; once main exists on the
  # remote every direct push must be refused. Measured 2026-07-28: without the
  # bootstrap exception a freshly stamped project cannot be published at all.
  local bare="$TMPROOT/origin.git"
  git init -q --bare "$bare" >/dev/null 2>&1
  git -C "$dest" remote add origin "$bare"
  git -C "$dest" add -A >/dev/null 2>&1
  if ! git -C "$dest" -c user.email=v@v -c user.name=v commit -qm stamp \
        >"$TMPROOT/commit.log" 2>&1; then
    skip "push-gate" "probe commit failed: $(tail -2 "$TMPROOT/commit.log" | tr '\n' ' ')"
    return
  fi

  if git -C "$dest" push -q -u origin main >"$TMPROOT/push1.log" 2>&1; then
    ok "bootstrap-push-allowed"
  else
    bad "bootstrap-push-allowed" \
        "the push that creates main was blocked — a new project cannot be published: $(tail -2 "$TMPROOT/push1.log" | tr '\n' ' ')"
  fi

  # A real file change, NOT --allow-empty: push what people push. (An empty
  # commit works too — pre-push commands with no file template run regardless,
  # re-measured 2026-07-28. An earlier comment here claimed they were skipped;
  # that was the pre-COMMIT skip being misread. See the template lefthook.yml.)
  echo "# second" >> "$dest/README.md"
  git -C "$dest" add -A >/dev/null 2>&1
  git -C "$dest" -c user.email=v@v -c user.name=v commit -qm second >/dev/null 2>&1
  if git -C "$dest" push origin main >"$TMPROOT/push2.log" 2>&1; then
    bad "main-push-blocked" "direct push to an existing main succeeded — the pre-push guard is inert"
  else
    ok "main-push-blocked"
  fi

  # Same push, but with the branch's TRACKED remote pointing somewhere that
  # cannot be reached. The guard must judge the remote it is pushing to (`{1}`),
  # and must never read "I could not find out" as "must be a bootstrap".
  # Measured 2026-07-28: the old guard asked branch.main.remote, got an error,
  # and allowed a direct push to a main that already existed.
  git -C "$dest" remote add unreachable /nonexistent/nope.git 2>/dev/null
  git -C "$dest" config branch.main.remote unreachable
  echo "# third" >> "$dest/README.md"
  git -C "$dest" add -A >/dev/null 2>&1
  git -C "$dest" -c user.email=v@v -c user.name=v commit -qm third >/dev/null 2>&1
  if git -C "$dest" push origin main >"$TMPROOT/push3.log" 2>&1; then
    bad "main-push-guard-fails-closed" \
        "an unreachable tracked remote turned the bootstrap exception into a licence to push to main"
  else
    ok "main-push-guard-fails-closed"
  fi
  git -C "$dest" config --unset branch.main.remote

  # F7, exercised the same way and for the same reason: two states, opposite
  # verdicts, against a real remote rather than grepped out of the YAML.
  # Measured on forgeboard-report 2026-07-30 — the lane pushed `chunk/1`…
  # `chunk/6` against a documented `chunk/<id>-<slug>`, and tier 2 bounced four
  # PRs on the name alone, after the review that found nothing else wrong had
  # already been paid for. The valid case matters as much as the blocked one:
  # a guard that refuses correct branches costs more than the rule it enforces.
  git -C "$dest" checkout -q -b chunk/7-render-report
  echo "# chunk" >> "$dest/README.md"
  git -C "$dest" add -A >/dev/null 2>&1
  git -C "$dest" -c user.email=v@v -c user.name=v commit -qm chunk >/dev/null 2>&1
  if git -C "$dest" push -u origin chunk/7-render-report >"$TMPROOT/push4.log" 2>&1; then
    ok "chunk-branch-push-allowed"
  else
    bad "chunk-branch-push-allowed" \
        "a correctly named chunk branch was refused: $(tail -2 "$TMPROOT/push4.log" | tr '\n' ' ')"
  fi

  # `chunk/8` is the literal shape that closed PRs #4, #6, #8 and #10 unmerged.
  git -C "$dest" checkout -q -b chunk/8
  echo "# misnamed" >> "$dest/README.md"
  git -C "$dest" add -A >/dev/null 2>&1
  git -C "$dest" -c user.email=v@v -c user.name=v commit -qm misnamed >/dev/null 2>&1
  if git -C "$dest" push -u origin chunk/8 >"$TMPROOT/push5.log" 2>&1; then
    bad "misnamed-branch-blocked" \
        "'chunk/8' pushed — the exact name that cost four PRs and four review rounds (F7)"
  else
    ok "misnamed-branch-blocked"
  fi
  git -C "$dest" checkout -q main

  # ONE source for the rule. AGENTS.md states it in prose; lefthook and CI must
  # both defer to the same script rather than restate the regex. Two config
  # files each carrying a copy is F30's defect — they disagree the first time
  # one is edited, and the disagreement surfaces as a branch that passes locally
  # and fails in CI, which is the F7 cost over again in a new costume.
  local lh="$dest/lefthook.yml" ciy="$dest/.github/workflows/ci.yml"
  if grep -q 'scripts/branch-name.sh' "$lh" \
     && grep -q 'scripts/branch-name.sh' "$ciy" \
     && ! grep -qE '\^?chunk/\[' "$lh" "$ciy"; then
    ok "branch-rule-has-one-source"
  else
    bad "branch-rule-has-one-source" \
        "lefthook and CI must both call scripts/branch-name.sh, and neither may inline the pattern"
  fi

  # The CI path takes the branch as an ARGUMENT, because on a pull_request the
  # runner's checkout is a detached merge ref whose HEAD is not the branch. That
  # path is never exercised by the pushes above, so drive the script directly.
  # `main` and a detached HEAD must PASS: no-main-push owns main-branch policy
  # including its bootstrap exception, and a hook that cannot see which refs are
  # being pushed has no question to answer and must not invent one.
  # `<id>` IS NOT A DECIMAL INTEGER, and the middle three probes are the shapes
  # that proved it: JobApp's board runs `C6`, `C9.1` and `C10`, and the tutorial
  # project runs `hello-1`. A rule that reads the id as a number refuses every
  # one of them at push time, on every push of the run — F7's cost with the sign
  # flipped, charged to correct work. Widening the ID does not loosen the SLUG:
  # `chunk/7-Render` is still refused, and `chunk/7--foo` is here because it is
  # the one shape where this rule and the gate's disagreed — the template's
  # `[a-z0-9-]+` swallowed a doubled hyphen the gate rejected. Two rules that
  # disagree is F30's defect, and it surfaces as a branch that passes locally
  # and fails in CI.
  local bn="$dest/scripts/branch-name.sh" bn_ok=1 got
  for probe in "main:0" "chunk/7-render-report:0" "chunk/12-a-b-c:0" "HEAD:0" \
               "chunk/C6-breadth-sources:0" "chunk/hello-1-greet:0" \
               "chunk/C7.1-mirror-and-migration-hardening:0" \
               "chunk/8:1" "chunk/6:1" "slice/foo:1" "chunk/7-Render:1" \
               "chunk/7--foo:1"; do
    got=0; "$bn" "${probe%:*}" >/dev/null 2>&1 || got=1
    if [ "$got" != "${probe##*:}" ]; then
      bad "branch-name-judges-by-argument" \
          "'${probe%:*}' returned $got, expected ${probe##*:}"
      bn_ok=0; break
    fi
  done
  [ "$bn_ok" = 1 ] && ok "branch-name-judges-by-argument (12 names, the CI path)"

  # `make check` is the verdict forge-lane §5 trusts in place of Codex's word,
  # so it must not be able to answer from a cache. Measured 2026-07-28: a lane
  # worktree's warm .ruff_cache returned "All checks passed!" for bytes that a
  # cold clone and CI both rejected. This is a config assertion, deliberately:
  # the staleness could not be reproduced synthetically (forcing size+mtime did
  # not fool ruff), so there is no honest behavioural test to write — but the
  # flag going missing is exactly how the false green comes back.
  local lint_body
  lint_body="$(awk '/^lint:/{f=1;next} /^[a-z]/{f=0} f' "$dest/Makefile")"
  if [ "$(printf '%s' "$lint_body" | grep -c -- '--no-cache')" -ge 2 ]; then
    ok "check-reads-no-cache"
  else
    bad "check-reads-no-cache" \
        "make lint can answer from a cache — a cached verdict is not a verdict (forge-lane §5)"
  fi

  # ADR-0003 says CI runs exactly what local runs. That holds for the command;
  # it holds for the runtime underneath it only if the interpreter is pinned.
  # Measured 2026-07-28: with only `requires-python = ">=3.12"` the local venv
  # resolved to 3.14.6 while AGENTS.md said 3.12 — the project's own SSOT
  # describing a runtime the project was not using.
  local want have
  want="$(tr -d '[:space:]' < "$dest/.python-version" 2>/dev/null)"
  have="$("$dest/.venv/bin/python" -V 2>&1 | awk '{print $2}')"
  if [ -z "$want" ]; then
    bad "python-pinned" "no .python-version stamped — local and CI resolve interpreters independently"
  elif [ "${have#"$want"}" != "$have" ]; then
    ok "python-pinned ($have)"
  else
    bad "python-pinned" ".python-version says $want but the venv is $have"
  fi
}

# ---------------------------------------------------------------------------
if [ "$LIST_ONLY" = 1 ]; then
  cat <<'EOF'
cli/flags-exist                   every long flag named beside a tracked command exists in its --help
cli/flags-exist/<command>         one tracked command could not be judged: absent, or its --help lists no flags
cli/verify-help-grows-with-the-group-header  appended groups remain visible without numeric line pins
cli/preflight-help-grows-with-the-header  Usage and Exit remain visible after the header grows
cli/no-unverified-claims-in-skills  skill bodies carry no unverified-claim markers
cli/skill-body-budget             ceremonies <= 150 lines, the lane protocol <= 300
cli/skill-section-references-resolve every named numeric skill section exists
cli/skill-section-reference-rename-is-named a renamed target reports source and missing heading
cli/soul-body-budget              every profile SOUL <= 60 lines (identity, not protocol)
cli/no-programs-in-souls          no fenced block in a SOUL exceeds 6 lines
cli/permissions-are-read-only     no allowlist wildcard admits a paid or mutating command
cli/model-pin-documented          profiles-bootstrap.sh's model pins are named in state.md (F22/F36)
cli/codex-pin-documented          forge-lane and state.md agree without reading live config (F36)
cli/lane-skill-management-policy  retained skills toolset is write-approval-gated (ADR-0013)
cli/skill-description-budget              frontmatter descriptions fit the budget every session pays to list
cli/retro-metrics                         docs/retro-metrics.md exists and carries the table /retro appends to
cli/codex-run-flags-exist                 each flag codex-run.sh builds is in its argv AND accepted by that subcommand
config/codex-pin-live-diagnostic-names-both-values mismatch output names live and checked-in pins
config/codex-pin-live             ~/.codex/config.toml agrees with the checked-in model-and-effort pair
config/terminal-timeout/<profile> >= 1800s per profile
config/write-approval/<profile>   ADR-0005 consent gate on per profile
config/external-dirs/<profile>    points at this checkout's skills/
config/soul-in-sync/<profile>     live ~/.hermes SOUL matches the one in git
config/model-pin-live/<profile>   live model.default matches the pin that would republish it
config/lane-skill-scope           start-chunk/end-chunk not loadable by the lane
config/board-default-workdir      every forge board has a worktree anchor
config/per-profile/<assignee>             a declared assignee with no profile on disk is named, not trusted (F43)
config/per-profile                        the per-profile sweep could not run at all (no hermes, or no forge-* profiles)
config/preflight-agrees-about-real-profiles  preflight's profile source carries no second implementation of the resolution
substrate/worktree-ownership      dispatcher resolves the worktree before spawning
substrate/worktree-gitfile        .git is a file in a linked worktree; writes fail
substrate/kanban-json-shapes      the --json shapes board-bootstrap and monitoring read are unchanged
substrate/kanban-card-parking-semantics/<assertion>  create never yields running, block refuses from todo, and stickiness is the blocked EVENT, not the status column (--with-hermes)
substrate/codex-worktree-commit   codex can commit in a worktree with --add-dir (--with-codex)
template/stamp                            copier stamps a project from the template into a durable path
template/stamp-setup-check                the stamp/setup/check probe could not run (uvx absent)
template/setup                            make setup builds the venv and installs the toolchain
template/hooks-installed                  lefthook really installs its hooks into the stamped repo's .git
template/check-green                      make check passes on the freshly stamped project
template/push-gate                        the real-bare-remote push probe could not reach a probe commit
template/gitignores-worktrees     .worktrees/ is ignored (dispatcher worktrees live in-repo)
template/bootstrap-push-allowed   the push that CREATES main is allowed (real bare remote)
template/main-push-blocked        every later direct push to main is refused
template/main-push-guard-fails-closed  an unreachable tracked remote does not unlock the bootstrap exception
template/chunk-branch-push-allowed  a correctly named chunk/<id>-<slug> branch pushes
template/misnamed-branch-blocked  chunk/8 is refused at push time, not at review time (F7)
template/branch-rule-has-one-source  lefthook and CI defer to one script; neither inlines the pattern
template/branch-name-judges-by-argument  the CI path (branch passed in, detached HEAD) is correct
template/check-reads-no-cache     make lint cannot answer from a warm ruff cache
template/python-pinned            .python-version is stamped and the venv actually uses it
lane/env-prepared-before-codex    linked task checkout, fetch, setup, baseline and immutable capture; exits 0/2/3/4/5/6
lane/scratch-is-board-scoped      run ids are board-local; scratch and audit carry the board, same-board reuse still refuses
lane/codex-probe-audits-the-emitted-key  the --with-codex probe consumes FORGE_LANE_RUN_KEY instead of recomputing it
lane/role-boundary-prepended      every contract states codex must not push/PR/touch the board
lane/driver-never-authors-diff    the cheap driver cannot substitute a direct patch for codex exec
lane/terminator-set-is-closed     kanban_request_review/_changes are named forbidden, not merely unlisted
lane/terminators-match-the-substrate    every terminator the installed Hermes exposes is accounted for in §7 (--with-hermes)
lane/blast/missing-run-capture    a check with no current-run immutable baseline cannot pass
lane/blast/capture-is-single-use  Codex cannot replace the pre-Codex baseline
lane/blast/check-is-single-use    a completed final audit cannot be overwritten or replayed
lane/blast/failed-check-cannot-be-retried  a detected breach cannot be restored and re-audited under the same run id
lane/blast/clean-linked-worktree  the nominal linked-worktree path passes
lane/blast/baseline-is-outside-codex-roots  protected state never lives in the worktree
lane/blast/task-commit-is-the-allowed-path  normal objects/ref/reflog/index changes pass
lane/blast/hook-rename-is-a-breach        hook name is identity, not just content
lane/blast/hook-mode-is-a-breach          executable mode is protected
lane/blast/hook-symlink-retarget-is-a-breach  symlink target is protected
lane/blast/hook-symlink-target-content-is-protected  writable target bytes are protected
lane/blast/unreadable-hook-fails-closed   hashing failure cannot become an empty clean set
lane/blast/shared-config-is-protected     local config is outside the task contract
lane/blast/worktree-config-is-protected   core.hooksPath lives here and --local never shows it
lane/blast/shared-hooks-are-protected     the OPERATOR's hooks, which lanes no longer write
lane/blast/forge-dirt-is-not-hidden       no whole-directory .forge exclusion remains
lane/blast/unreadable-status-fails-closed git status exit 128 cannot read as empty output
lane/blast/main-is-protected              the protected branch cannot move
lane/blast/object-alternates-are-protected  object lookup cannot be redirected elsewhere
lane/blast/pre-existing-objects-are-protected  reachable history cannot lose an object
lane/blast/sibling-lane-is-not-a-breach   a concurrent lane and a fetch are not escapes (F75)
lane/blast/pre-existing-fsck-damage-is-not-a-breach  malformed history predating the run is not Codex's (F76)
lane/blast/breach-names-what-moved        a block names the offending path, not just a category
lane/dependent-pr-must-be-merged  parent card completion cannot substitute for code integration
lane/graph-parents-are-atomic     dependent cards carry --parent before the dispatcher can claim them
lane/uv-cache-dir-is-deterministic-and-outside-worktree  one run-specific TMPDIR, no status blind spot
lane/verification-is-plain-make-check   no UV_OFFLINE/UV_CACHE_DIR green counts
lane/template-agents-scopes-ceremonies  AGENTS.md scopes ceremonies to the operator
lane/prejudge-delegates-its-protocol    the SOUL names the script and the script exists (ADR-0010)
lane/prejudge-terminator-mapping        rc 0 -> kanban_complete, rc 3 -> kanban_block; an outage is not a rejection
lane/driver-never-reads-the-diff        the metered driver redirects the diff; it never renders one
lane/prejudge-stores-what-happened      gate result or verdict, never a manufactured one; ci-red sentinel retired
bootstrap/root-only-creates-one-card    a valid graph creates only its unique root
bootstrap/multiple-roots-mutate-nothing invalid staged graphs refuse before the first Hermes command
bootstrap/malformed-ids-mutate-nothing  space, slash, traversal and malformed dependency ids invoke no Hermes command
bootstrap/full-extends-root-idempotently full bootstrap reuses the root key and atomically attaches every remaining parent
bootstrap/completed-interactive-root-is-reused full bootstrap extends the human-completed root without re-blocking it
bootstrap/parented-interactive-chunk-is-blocked-then-linked an interactive chunk whose parent is not done is created parentless, sticky-blocked, unassigned, then linked
bootstrap/reconciliation-is-mode-scoped root-only checks its created set while full mode still rejects missing declared edges
bootstrap/generated-branch-names-pass-the-branch-name-rule  the branch board-bootstrap.sh generates is accepted by branch-name.sh itself
commission/records-all-prerequisites    the paid probe and every existing gate land in one evidence report
commission/propagates-prerequisite-failure a named nonzero prerequisite makes commissioning fail
commission/preserves-roadmap-warn       advisory WARN remains WARN in the report
commission/requires-enforceable-gate    repository visibility never substitutes for merge protection
commission/binds-github-to-origin       GitHub identity must exactly match the parsed origin URL
commission/report-publication-failure-is-fatal an unpublished evidence artifact can never report success
commission/leaves-project-and-board-unchanged only ignored evidence is written and no Hermes mutation runs
commission/an-ungatable-product-commissions  a repo GitHub cannot gate is an answer, not a refusal (ADR-0017)
commission/every-report-states-its-posture  every report names its posture, derived from the gate's exit alone
commission/require-gate-restores-the-refusal  REQUIRE_GATE=1 restores the strict posture for a repo you expect gated
commission/an-unrecognised-require-gate-is-refused  any other REQUIRE_GATE value is refused, never reinterpreted
bootstrap/real-hermes-root-and-extension opt-in isolated host proof uses Hermes rather than the command stub
metrics/help-exits-zero           scripts/metrics.sh --help works with no board and no ~/.hermes
metrics/fixture-numbers-exact     a checked-in SQL board reproduces a checked-in JSON expectation, field for field
metrics/driver-usage-joins-exact-session  session totals and every per-model row come from worker_session_id
metrics/driver-usage-shared-session-counts-once multiple runs retain mappings without charging one session twice
metrics/driver-usage-missing-id-is-unjudged  a completed chunk run without worker_session_id is not zero usage
metrics/driver-usage-missing-profile-is-explicit  unreadable profile state preserves base metrics and names the gap
metrics/driver-usage-estimate-keeps-actual-absent  estimated Hermes cost never manufactures zero actual cost
metrics/markdown-row-has-operator-and-driver-cells  generated rows match the retro log's expanded header
metrics/detects-noncanonical-envelope  a nested chunk envelope is reported as nonconforming, not normalized or dropped
metrics/gate-blocks-are-not-bounces    forge.gate.v1 blocks are counted apart from bounces (ADR-0009 D9.4)
metrics/reads-a-quiescent-board   a board at rest, with no WAL sidecars, is still readable (F47)
metrics/is-read-only              reading changes neither database nor sidecar membership/bytes
metrics/read-only-fingerprint-includes-sidecars  membership and bytes cover db, wal, shm and journal
metrics/live-schema-has-fixture-columns  the columns the fixture declares still exist on a real board
metrics/live-schema-selection-is-complete-and-deterministic  every board is named in stable order
metrics/live-schema-read-survives-an-idle-board  a WAL board with no -shm is still readable, so the check above cannot flake (F67)
metrics/retro-skill-runs-the-command    /retro runs `make metrics`, and does not compute the numbers itself
metrics/help-names-its-usage      --help and the no-board error both reach the Usage block, not line-pinned prose
metrics/snapshot/fixture-reproduces-the-idle-failure  the fixture is WAL and shm-less, so mode=ro provably refuses it (F51)
metrics/snapshot/idle-wal-board-is-readable  a board at rest snapshots and reads (F47, F67)
metrics/snapshot/source-is-byte-identical    reading a board changes neither it nor its sidecars
metrics/snapshot/unreadable-input-is-silent-on-stdout  a failed read exits non-zero AND prints nothing (F47's second half)
metrics/snapshot/empty-input-is-not-an-empty-board  a zero-byte file is a VALID empty database; no query closes that
metrics/snapshot/path-with-a-space-is-a-path  a board under a directory with a space still snapshots
metrics/snapshot/help-names-its-exit-contract  --help is anchored to the header rules, not to line numbers
metrics/snapshot/torn-source-is-refused      a board moving under every attempt fails; no partial success
metrics/snapshot/no-second-implementation    the WAL snapshot exists once, and both live-board readers call it
metadata/schemas-are-valid              every run-metadata schema is valid JSON Schema Draft 2020-12
metadata/profile-contract-is-explicit   each producing profile names the only schemas it may complete with
metadata/lane-validates-before-complete the nondeterministic lane gates the exact object before its terminator
metadata/valid-by-profile               canonical chunk/judge fixtures and the recorded gate producer validate by profile
metadata/published-examples-validate    the two JSON examples in the canonical document satisfy their own schemas
metadata/rejects-nested-chunk            the historical $."forge.chunk.v1" envelope is not canonical
metadata/chunk-id-is-not-digits          letter-prefixed and dotted ids validate, and mismatched ids are still caught
metadata/rejects-reserved-nested-copy    a flat envelope cannot hide a second copy under a forge.* key
metadata/rejects-incomplete-chunk        a chunk missing a required exhaust field cannot complete
metadata/rejects-coverage-key-drift      check.coverage cannot silently replace check.coverage_pct
metadata/rejects-semantic-contradictions scenarios, identities, URLs, checks, counts and result cannot disagree
metadata/allows-additive-hermes-keys     dashboard-native sibling keys remain compatible
metadata/judge-envelope-as-produced      the key set a real prejudge run stored, once the harness fills nits_as_cards
metadata/rejects-profile-schema-mismatch a valid envelope from the wrong producer is still invalid
metadata/rejects-missing-metadata        a completed producer run cannot carry null metadata
metadata/validator-runtime-is-locked     the shebang the lane runs pins transitive validation code, not just jsonschema
metadata/unreadable-path-is-not-invalid-metadata  an unreadable path exits 2; only a real envelope earns exit 1
metadata/blocked-reason-contract         literal producers and the metrics consumer use the registry vocabulary
metadata/live-requires-rfc3339-since     an absent or malformed cutoff refuses before any board read
metadata/live-operator-interface          automation is directed to the script that preserves exit 0/1/2
metadata/live-valid-counts               valid envelopes are counted by profile and schema
metadata/live-classifies-every-bad-row   nested, null, cross-profile and unreadable rows are named
metadata/live-rejects-bad-block-reason   a model-authored reason outside the registry names task, run and reason
metadata/live-ignores-pre-cutoff         historical rows are counted as ignored, never judged
metadata/live-uses-snapshot              the opt-in reader depends on board-snapshot.sh at runtime
prejudge/help-exits-zero          scripts/prejudge.sh --help works with no PR
prejudge/steps-walker-exact       a checked-in fixture of step shapes reproduces a checked-in expectation
prejudge/steps-walker-catches-both-cited-shapes  F14's no-assertion and render(x)==render(x) are both reported
prejudge/steps-walker-has-no-false-positives     six legitimate Then-step shapes are not reported
prejudge/recorded-prs-exact       two recorded PRs reproduce a checked-in severity map, offline
prejudge/branch-name-reads-real-chunk-ids  letter-prefixed and dotted ids pass, and the repair action keeps the id
prejudge/touches-widening-is-visible head-only Touches additions warn even when the implementation is in scope
prejudge/touches-removal-is-not-widening paths removed from Touches do not warn as widening
prejudge/touches-unchanged-passes unchanged contracts with in-scope implementation pass both Touches checks
prejudge/touches-widening-shares-exemptions process docs are exempt through the single shared policy definition
prejudge/blocks-with-exit-1       a blocking check exits 1; a clear-with-warnings PR exits 0
prejudge/absent-ci-is-not-a-pass  an empty statusCheckRollup blocks after a wait, never passes (F5)
prejudge/scenario-count-is-asymmetric  fewer scenarios than the contract blocks, more only warns
prejudge/frozen-feature-blocks-change  a feature whose bytes differ from the approved base is named and blocked
prejudge/frozen-contract-blocks-change  implementation cannot weaken the approved Scenarios prose
prejudge/frozen-contract-blocks-acceptance-redirect  implementation cannot redirect the approved feature path
prejudge/frozen-feature-allows-step-definitions  ordinary implementation steps do not change frozen acceptance
prejudge/frozen-feature-blocks-self-amendment  changing the feature and its manifest together cannot approve itself
prejudge/frozen-feature-accepts-planning-amendment  a later branch consumes the hash already approved on its base
prejudge/judge-scores-frozen-real-source  @real-source remains in the judge's scored acceptance surface
prejudge/skip-is-distinguishable-from-pass  a check that could not run has not passed
prejudge/emits-an-action-per-block  every blocking finding carries an action a fresh worker can execute
prejudge/emits-its-own-shape-not-the-verdict-schema  the gate emits forge.gate.v1, never a scored verdict
prejudge/gate-is-a-stage-not-a-replacement  no model in the gate, and the protocol's scorer still there
prejudge/scorer-is-the-control-arm  the claude -p call is byte-identical to the recorded baseline (S5's control; never skips)
prejudge/review-routes-by-gate-result  a gate block bounces with no model spawned, carrying forge.gate.v1
prejudge/review-emits-a-terminator-envelope  one forge.review.v1 object tells the model which terminator to call
prejudge/review-never-prints-the-diff  a recorded 63 KB patch reaches the prompt file and not stdout
prejudge/schema-hides-stamped-fields  the model is not asked for the fields the operator stamps
prejudge/cost-is-storable         the verdict schema takes cost, session_id, worker_session_id and tokens_estimate — storable, never demanded, cache field intact
prejudge/deriver-sources-without-side-effects  sourcing verdict.sh does not change the caller's shell options
prejudge/verdict-derives-from-scores     judge-rubric.md's verdict logic, as a table of cases (F29)
prejudge/unevidenced-score-is-not-a-verdict  a score below 3 naming no finding fails instead of deriving
prejudge/derived-verdict-routes             the derived verdict routes; the model's own word is recorded, not obeyed (F29)
prejudge/undecidable-derivation-falls-back-to-the-scorer  a null derived_verdict routes on .verdict instead of reaching substrate()
prejudge/shadow-fields-are-stamped-never-trusted  a model-invented derived_verdict cannot survive
prejudge/shadow-never-destroys-the-verdict  an unstampable verdict file is left exactly as found
prejudge/shadow-needs-no-writable-tmpdir  the stage does not depend on TMPDIR being writable
prejudge/stamp-reports-its-own-failure    emitting nothing returns non-zero, not 0
prejudge/shadow-preserves-the-routing-field  stamping never alters .verdict
prejudge/stamped-envelope-declares-every-key  no key the schema does not declare (additionalProperties:false)
prejudge/envelope-is-repaired-before-it-is-stored  an absent nits_as_cards is filled and an invented worker_session_id cannot survive
prejudge/bounce-card-lands-in-the-rejected-worktree  route_bounce's own flags make a card Hermes accepts, in the rejected worktree
prejudge/review-uses-the-guarded-stamp    the caller cannot truncate the verdict with a raw mv
sweep/dest-refuses-tmp-both-spellings       /tmp and /private/tmp are one directory; both lose
sweep/dest-refuses-tmp-via-traversal        symlinks and `..` resolved BEFORE judging
sweep/dest-refuses-traversal-past-a-missing-component  `..` through a dir that does not exist yet still lands in /tmp
sweep/dest-refuses-active-tmpdir            $TMPDIR is volatile and is not under /tmp on macOS
sweep/dest-refuses-relative-and-empty       a relative DEST is the F19 mechanism itself
sweep/dest-refuses-a-non-directory          a regular file and / are not durable directories
sweep/dest-refuses-an-unreadable-ancestor   an un-enterable ancestor must refuse, never emit a bare tail
sweep/dest-refuses-a-traversing-name        NAME is one component; it cannot walk out of DEST
sweep/dest-refusal-names-a-durable-location the refusal shows a usable DEST=, not only "no"
sweep/dest-accepts-durable                  a durable path still works, resolved physically
sweep/dest-accepts-durable-with-a-name      --name returns the final target, the string make new uses
sweep/make-new-routes-through-the-guard     `make new` calls it and no longer defaults DEST to ..
sweep/make-new-sends-name-through-the-guard NAME is validated, not appended to a validated DEST
sweep/make-new-fails-when-copier-fails      a failed stamp exits non-zero and prints no next steps
sweep/sweep-apply-acts-only-on-1            APPLY=0/false/no do not delete; they are refused
sweep/sweep-refuses-relative-project        a command that deletes must not inherit its target
sweep/sweep-dry-run-changes-nothing         no APPLY: names the removal, performs none of it
sweep/sweep-refuses-outside-the-bound       worktrees outside <project>/.worktrees/ are REFUSEd
sweep/sweep-removes-clean-merged            clean + merged PR on the remote is reclaimed
sweep/sweep-keeps-dirty                     uncommitted work is never swept
sweep/sweep-keeps-unmerged                  no merged PR on the remote means no removal
sweep/sweep-keeps-a-rebuilt-branch          a merged PR at a DIFFERENT head is not this branch's merge
sweep/sweep-keeps-what-it-cannot-read       a git that fails is not a clean worktree
sweep/sweep-fails-when-it-cannot-enumerate  "nothing to sweep" and "I could not look" are different exits
sweep/sweep-never-touches-outside-the-bound APPLY still cannot reach outside the bound
sweep/sweep-refuses-an-unreadable-bound     a bound that cannot be entered must not become every path
sweep/sweep-fixture                         the sweep fixture could not be built (git absent)
sweep/sweep-never-force-deletes-a-branch    unreachable commit survives; reported, never -D'd
sweep/sweep-carries-no-forced-delete        the script contains no `git branch -D`
sweep/sweep-tolerates-missing-remote-branch the merge deletes origin/<branch>; that is normal
sweep/sweep-help-names-its-exit-contract    --help is anchored to the header, not to line numbers
roadmap/real-run-contract-fails-on-serves  the audited run's own CHUNK-5 serves 12 requirements, cap 4 (F11)
roadmap/counting-bullets-is-not-counting-scenarios  5 bullets specifying 8 scenarios are 8, not 5
roadmap/compound-bullet-is-not-one-scenario  the run's verbatim six-in-one Given is worth six
roadmap/conjunctive-list-is-still-one-scenario  'Given A, B, and C' is one scenario, not three
roadmap/bijection-id-with-no-file       a graph id with no docs/chunks/<id>.md is reported
roadmap/bijection-file-with-no-id       a chunk file the graph forgot is reported (bootstrap cannot see this)
roadmap/bijection-dangling-depends-on   depends_on naming an id the graph does not define
roadmap/acyclic-catches-a-cycle         a cycle is named before a board exists
roadmap/single-root-catches-two-roots   Track E's --root-only needs exactly one root
roadmap/reachable-is-diagnostic-evidence  pass is named as evidence, never an independent detector
roadmap/fields-names-the-missing-one    a missing contract field fails and is named
roadmap/serves-over-four                more than 4 requirements per chunk (F11's own number)
roadmap/touches-over-six                more than 6 declarable paths per chunk
roadmap/scenario-count-over-five        more than 5 scenarios per chunk
roadmap/scenario-shape-needs-one-given-when-then  a bullet that is not one Given/When/Then
roadmap/lane-catches-an-unknown-assignee  an unknown assignee strands the card silently, so catch it here
roadmap/graph-schema-rejects-a-numeric-id  a non-string id killed the jq graph program and PASSed a cycle
roadmap/graph-schema-rejects-an-id-with-a-space  a word-split id skipped all five content checks, reporting pass
roadmap/graph-schema-rejects-duplicate-ids  two records for one id corrupt the tab-separated result
roadmap/graph-schema-rejects-a-scalar-depends-on  depends_on must be an array of strings
roadmap/range-is-not-a-disjunction      "5 or more fields" is one scenario, not a compound bullet
roadmap/disjunction-counts-every-alternative  a clause is worth as many scenarios as it lists (D12.3)
roadmap/wrapped-bullet-is-still-one-scenario  a bullet wrapped over two lines is not malformed
roadmap/touches-findings-are-independent  a missing Touches list must not hide another chunk's overage
roadmap/lane-accepts-only-on-disk-profiles  the hermes branch: on_disk names only, never the table's tokens
roadmap/missing-touches-exemption-is-exit-2-not-a-pass  an unguarded source printed PASS touches at exit 0
roadmap/conjunctive-commas-are-not-alternatives  a comma list plus one plain "or" is not a disjunction of the list
roadmap/keyword-inside-a-clause-is-not-a-marker  "the record given to the caller" is not a second Given
roadmap/null-is-the-same-as-an-absent-key  a null lane/depends_on is what every consumer already tolerates
roadmap/process-docs-do-not-count-against-touches  the F55 exemption applies at plan time too
roadmap/touches-exemption-has-one-definition  plan time and review time share one list, not two
roadmap/warns-without-blocking          findings do not gate — F53's ruling, shipped
roadmap/unrunnable-is-exit-2-not-a-pass  an absent plan is not a clean plan
roadmap/unreadable-assignee-list-skips-never-passes  a check that could not run has not passed
roadmap/every-warning-carries-an-action  no finding a planner cannot execute
roadmap/skill-delegates-to-the-checker  /roadmap names the script, via ~/.forge/repo (ADR-0003)
roadmap/thresholds-are-the-skills-own-numbers  the caps have not drifted from skills/roadmap/SKILL.md
roadmap/skill-emits-frozen-acceptance    one planning pass writes feature paths, executable scenarios, and the manifest
roadmap/acceptance-matches-contract      every generated Given/When/Then step matches its chunk contract
roadmap/real-source-is-planned           arbitrary declared sources map exactly to their @real-source scenarios
roadmap/freeze-is-deterministic           sorted repo-relative paths map to the feature bytes' SHA-256 digests
roadmap/missing-feature-is-named          freeze refuses atomically and names the chunk plus expected path
gate/rulesets-are-a-gate                  a ruleset with a PR rule and required checks is GATED (exit 0)
gate/classic-protection-is-a-gate         classic protection carrying both halves is GATED (exit 0)
gate/required-contexts-are-checked-by-name  a gate missing a named context reports missing=, not gated
gate/checks-without-a-pr-rule-is-not-a-gate  required checks with no PR rule is PARTIAL (exit 3)
gate/a-pr-requiring-no-checks-is-not-a-gate  a PR rule requiring nothing is PARTIAL (exit 3)
gate/no-rule-from-either-mechanism-is-exit-4  neither mechanism present is NONE via=none (exit 4)
gate/an-inactive-ruleset-is-not-a-gate    a ruleset that is not enforced does not gate
gate/a-ruleset-for-another-branch-does-not-gate-main  a rule scoped to another ref leaves main ungated
gate/an-excluded-branch-is-not-gated      main on a ruleset's exclusion list is not gated by it
gate/an-unreadable-repo-is-exit-2           a repository that cannot be read is exit 2 — not a pass (F65/F66)
gate/unreadable-rulesets-is-exit-2-not-exit-4  a failed rulesets read is 'could not ask', never 'no rule exists'
gate/unreadable-classic-protection-is-exit-2  the same distinction for classic protection
gate/one-mechanism-unavailable-is-exit-2  one mechanism unreadable is exit 2 even when the other answers
gate/a-missing-gh-warns-rather-than-vanishing  preflight WARNs about an absent gh rather than saying nothing
gate/a-malformed-slug-is-named-not-misreported  a bad owner/name is reported as malformed, not as ungated
gate/an-unavailable-plan-is-exit-5-not-exit-2  a plan without protection is UNAVAILABLE (exit 5), a distinct answer (ADR-0017)
gate/an-unavailable-repo-is-never-reported-gated  an unavailable posture can never read as gated
gate/a-public-repo-upgrade-403-is-exit-2  a 403 on a public repo is 'could not ask', not 'plan unavailable'
gate/a-public-repo-classic-upgrade-403-is-needs-admin  the classic-protection form of that 403 reads as needs-admin
gate/a-needs-admin-403-is-still-exit-2    needs-admin remains exit 2 — insufficient rights is not a verdict
gate/help-is-anchored-to-the-header-rules merge-gate.sh --help stays visible without numeric line pins
gate/preflight-has-no-second-implementation  preflight calls merge-gate.sh instead of re-deriving the verdict
docs/launch-ledger-reconciles-touched-findings every readiness finding names its closing chunk or remaining live proof
docs/launch-roadmap-separates-state-and-sequence landed tracks, remaining proof and the run sequence cannot be confused
docs/launch-slices-own-worktrees-and-manager-owned-ledger human slices never share main or become the sole audit-ledger writer
docs/launch-slice-contract-mutation-is-caught weakening slice isolation or ownership turns the docs gate red
docs/launch-cleanup-stays-bounded              automated cleanup stays under .worktrees and outside paths require explicit review
docs/launch-prior-dispositions-are-superseded  F81 and F103 keep their original record and link a superseding decision
docs/launch-f102-cites-real-product-roadmap    F102 closes on measured product-plan evidence, not the Forge fixture
docs/launch-f102-evidence-mutation-is-caught   changing the product identity makes the evidence contract red
quota/latest-reset-wins                 two exhausted windows wait for the LATER reset, never the nearer
quota/nearest-reset-mutation-is-caught  substituting min for max turns this group red
quota/window-shape-is-not-hardcoded     the old weekly-only and the new short-window shapes both read
quota/hard-limit-outranks-percentage    a reached marker blocks even below the threshold
quota/missing-fields-are-unknown-not-clear  a null used_percent must not license a start
quota/blocked-without-reset-is-not-clear  exhausted with no resets_at is still blocked
quota/parks-then-resumes-the-same-session  a limited run waits and resumes its session, not a new one
quota/resume-carries-the-sandbox-grant  `codex exec resume` takes no --add-dir, so -c restates it
quota/non-quota-failure-is-not-parked   an unrelated nonzero exit blocks and clears any stale park record
quota/wait-cap-blocks-with-a-board-class  giving up prints an `env:` reason and keeps the park record
quota/park-record-is-adopted-by-a-successor  a new run id resumes the parked session, not a fresh one
quota/lane-invokes-the-runner           forge-lane §4 calls it through ~/.forge/repo (ADR-0003)
quota/the-wait-is-bounded-by-the-blocked-windows  max runs over blocked windows only, never healthy ones
quota/a-reset-in-the-past-is-stale-not-blocking  an elapsed resets_at must not block a start
quota/an-incredible-reset-is-not-slept-on a resets_at beyond the horizon reads as wake_at=unknown, not a wait
quota/the-horizon-is-one-number           quota-window.py and codex-run.sh agree on the horizon constant
quota/a-stream-without-windows-is-unknown-not-clear  no rate-limit data is exit 3 unknown, never a licence to start
quota/a-named-refusal-blocks-only-the-window-it-names  rate_limit_reached_type must not widen to healthy windows
quota/a-fresh-snapshot-supersedes-an-earlier-refusal  a reached marker must not outlive the snapshot that described it
quota/a-record-that-is-foreign-or-undatable-is-not-adopted  adoption refuses another workspace's record and one past its TTL
quota/the-reactive-check-reads-the-current-attempt  a later failure is judged on that attempt's stream, not the run log
quota/the-park-record-is-json-and-the-comment-is-prefixed  the record survives a hostile --version and §1's PARK-COMMENT marker holds
quota/the-model-override-reaches-argv-and-a-missing-runtime-is-substrate  FORGE_CODEX_MODEL appears as -m; no runtime is exit 3
quota/a-knob-that-reads-as-garbage-is-a-usage-error  an unparseable knob exits 2 naming itself, never silently unbounded
docs/launch-docs-share-next-command            all four operator documents name roadmap-check as the next command
manifest/list-matches-the-suite           every case that ran is named in this catalogue (the reverse is not asserted)
EOF
  exit 0
fi

echo "forge verify — $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "groups:$SUITES$([ "$WITH_CODEX" = 1 ] && echo ' (+codex probes)')$([ "$WITH_HERMES" = 1 ] && echo ' (+real Hermes)')"

wants cli       && run_cli_group
wants config    && run_config_group
wants substrate && run_substrate_group
wants template  && run_template_group

# ---------------------------------------------------------------------------
# lane/ — what the unattended lane must do FOR Codex, because Codex cannot do
# it for itself. All four cases below are regressions of failures measured on
# 2026-07-28 driving `codex exec` by hand on hello-forge.
# ---------------------------------------------------------------------------
run_lane_group() {
  group lane
  local lane=skills/forge-lane/SKILL.md
  local agents=templates/python-service/template/AGENTS.md.jinja

  # §2/§3 and §5's audit are PROGRAMS now — scripts/lane-setup.sh and
  # scripts/lane-blast-radius.sh (audit F64). So the two cases below EXECUTE
  # them rather than grepping the skill for a substring. That is F63's argument
  # applied one layer up: a protocol living in prose can be approximated but not
  # tested, and this group already spent eleven cases proving it.
  #
  # The substring form was not merely weaker, it was actively misleading. When
  # §3 became a script call, `sed -n '/^## 3\./,/^## 4\./p' | grep -q 'make
  # setup'` went on passing — by matching the SENTENCE that describes what the
  # script does. Deleting the call and keeping the prose would have stayed
  # green. Same shape as F65: a check that survives the removal of the thing it
  # guards was never guarding it.
  #
  # So each case asserts BOTH halves: the script behaves, and the skill still
  # invokes it. A behavioural test of a script nothing calls is green and
  # worthless.
  local lmain="$TMPROOT/lane-main" lrepo="$TMPROOT/lane-repo" \
        lorigin="$TMPROOT/lane-origin.git" \
        laudit="$TMPROOT/lane-audits"
  _lane_fixture() {   # $1=make setup command, $2=make check command
    rm -rf "$lmain" "$lrepo" "$lorigin"
    git init -q --bare "$lorigin" >/dev/null 2>&1 || return 1
    mkdir -p "$lmain"
    ( cd "$lmain" \
      && git init -q -b main . \
      && printf 'setup:\n\t@%s\ncheck:\n\t@%s\n' "$1" "$2" > Makefile \
      && git add -A \
      && git -c user.email=v@v -c user.name=v commit -qm init \
      && git remote add origin "$lorigin" \
      && git push -qu origin main \
      && git branch task \
      && git worktree add -q "$lrepo" task ) >/dev/null 2>&1
  }
  _rc() { "$@" >/dev/null 2>&1; echo $?; }   # exit code, without tripping the shell

  # `-s workspace-write` grants NO network. A dispatcher worktree is a fresh
  # checkout with no .venv, so unless the lane builds it while it still has a
  # network, `make check` cannot run inside the sandbox at all.
  local setup=scripts/lane-setup.sh e_ok=1 detail="" setup_line codex_line \
        setup_output setup_rc
  if [ ! -x "$setup" ]; then
    bad "env-prepared-before-codex" "$setup is missing or not executable"
  elif ! grep -Fq '~/.forge/repo/scripts/lane-setup.sh' "$lane"; then
    bad "env-prepared-before-codex" \
        "forge-lane §3 no longer invokes $setup — a bare relative path cannot resolve from a project worktree, so it must be the ~/.forge/repo form"
  else
    _lane_fixture true true
    # HERMES_KANBAN_BOARD is PINNED, not inherited: lane-setup scopes its
    # per-run paths with it, so an ambient board in the shell running verify
    # would move the paths these cases assert.
    setup_output="$(env TMPDIR="$TMPROOT" FORGE_LANE_AUDIT_ROOT="$laudit" \
                    HERMES_KANBAN_BOARD=vboard \
                    "$setup" "$lrepo" setup-healthy 2>&1)"
    setup_rc=$?
    [ "$setup_rc" = 0 ] \
      || { e_ok=0; detail="$detail healthy-not-0($setup_output)"; }
    [ -f "$laudit/vboard-setup-healthy/capture.complete" ] \
      || { e_ok=0; detail="$detail healthy-did-not-capture"; }
    [ -d "$TMPROOT/forge-lane-vboard-setup-healthy" ] \
      || { e_ok=0; detail="$detail healthy-did-not-create-runtime"; }
    printf '%s' "$setup_output" \
      | grep -Fq "FORGE_LANE_RUNTIME=$TMPROOT/forge-lane-vboard-setup-healthy" \
      || { e_ok=0; detail="$detail healthy-did-not-emit-runtime-path"; }
    # F77: the worktree must own its hooks, or two lanes' `make setup` race on
    # one shared file and the audit blames Codex for the loser.
    [ "$(git -C "$lrepo" rev-parse --git-path hooks)" \
        = "$(git -C "$lrepo" rev-parse --git-dir)/hooks" ] \
      || { e_ok=0; detail="$detail healthy-hooks-not-per-worktree"; }
    [ "$(_rc "$setup")" = 2 ] || { e_ok=0; detail="$detail no-arg-not-2"; }
    [ "$(_rc "$setup" "$lrepo" ../unsafe)" = 2 ] \
      || { e_ok=0; detail="$detail unsafe-run-id-not-2"; }
    [ "$(_rc "$setup" "$TMPROOT/absent" setup-missing)" = 3 ] \
      || { e_ok=0; detail="$detail missing-ws-not-3"; }
    mkdir -p "$TMPROOT/notgit"
    [ "$(_rc "$setup" "$TMPROOT/notgit" setup-notgit)" = 3 ] \
      || { e_ok=0; detail="$detail notgit-not-3"; }
    git init -q --bare "$TMPROOT/lane-bare.git"
    printf 'setup:\n\t@true\ncheck:\n\t@true\n' > "$TMPROOT/lane-bare.git/Makefile"
    [ "$(_rc "$setup" "$TMPROOT/lane-bare.git" setup-bare)" = 3 ] \
      || { e_ok=0; detail="$detail bare-not-3"; }
    _lane_fixture true true
    [ "$(_rc "$setup" "$lmain" setup-main)" = 3 ] \
      || { e_ok=0; detail="$detail main-not-3"; }
    [ "$(_rc env HERMES_KANBAN_BRANCH=other "$setup" "$lrepo" setup-wrong-branch)" = 3 ] \
      || { e_ok=0; detail="$detail wrong-branch-not-3"; }
    _lane_fixture false true
    [ "$(_rc env FORGE_LANE_AUDIT_ROOT="$laudit" "$setup" "$lrepo" setup-fails)" = 4 ] \
      || { e_ok=0; detail="$detail setup-failure-not-4"; }
    _lane_fixture true true
    git -C "$lrepo" remote set-url origin "$TMPROOT/missing-origin"
    [ "$(_rc env FORGE_LANE_AUDIT_ROOT="$laudit" "$setup" "$lrepo" fetch-fails)" = 4 ] \
      || { e_ok=0; detail="$detail fetch-failure-not-4"; }
    _lane_fixture true false
    [ "$(_rc env FORGE_LANE_AUDIT_ROOT="$laudit" "$setup" "$lrepo" baseline-red)" = 5 ] \
      || { e_ok=0; detail="$detail red-baseline-not-5"; }
    _lane_fixture 'touch generated.lock' true
    [ "$(_rc env FORGE_LANE_AUDIT_ROOT="$laudit" "$setup" "$lrepo" baseline-dirty)" = 5 ] \
      || { e_ok=0; detail="$detail dirty-baseline-not-5"; }
    _lane_fixture true true
    mkdir -p "$TMPROOT/forge-lane-vboard-runtime-exists"
    [ "$(_rc env TMPDIR="$TMPROOT" FORGE_LANE_AUDIT_ROOT="$laudit" \
              HERMES_KANBAN_BOARD=vboard \
              "$setup" "$lrepo" runtime-exists)" = 4 ] \
      || { e_ok=0; detail="$detail runtime-reuse-not-4"; }
    _lane_fixture true true
    mkdir -p "$laudit/vboard-capture-exists"
    [ "$(_rc env TMPDIR="$TMPROOT" FORGE_LANE_AUDIT_ROOT="$laudit" \
              HERMES_KANBAN_BOARD=vboard \
              "$setup" "$lrepo" capture-exists)" = 6 ] \
      || { e_ok=0; detail="$detail audit-failure-not-6"; }
    setup_line="$(grep -n '~/.forge/repo/scripts/lane-setup.sh' "$lane" | head -1 | cut -d: -f1)"
    codex_line="$(grep -n '~/.forge/repo/scripts/codex-run.sh' "$lane" | head -1 | cut -d: -f1)"
    [ -n "$setup_line" ] && [ -n "$codex_line" ] && [ "$setup_line" -lt "$codex_line" ] \
      || { e_ok=0; detail="$detail setup-not-before-codex"; }
    if [ "$e_ok" = 1 ]; then
      ok "env-prepared-before-codex (fetch, setup, baseline and immutable capture; 0/2/3/4/5/6 exact)"
    else
      bad "env-prepared-before-codex" \
          "lane-setup.sh must build the environment and report a blockable reason —$detail"
    fi
  fi

  # RUN IDS ARE BOARD-LOCAL. Every Hermes board keeps its own database at
  # ~/.hermes/kanban/boards/<slug>/kanban.db, so ids restart at 1 per board —
  # measured 2026-09-02, `forge-hello-20260902` and `forge-hello-20260902b`
  # each issued 1, 2, 3. The per-run scratch dir and the audit baseline were
  # both keyed on the run id ALONE, nothing ever cleans either up, and
  # lane-setup treats a collision as a hard exit 4. So every FRESH board
  # inherited the leftovers of an earlier one. That fired live on 2026-09-02:
  # run 1 met a completed prior session's scratch and audit, and the run only
  # survived because the worker improvised a quarantine that appears nowhere
  # in this repo — no trap, no sweep, no documented recovery.
  #
  # BOTH DIRECTIONS ARE ASSERTED. A gate that refuses everything is as broken
  # as one that refuses nothing, so this case pins the refusal as hard as it
  # pins the fix:
  #   two DIFFERENT boards, both run id 1  -> both proceed
  #   the SAME board, same run id, twice   -> STILL exit 4
  # The boards deliberately share ONE $TMPDIR and ONE audit root. That sharing
  # is the real-life condition; isolating either would fake the proof.
  #
  # Refusing reuse is what stops two LIVE runs from sharing scratch and
  # corrupting each other's baseline and blast-radius audit, which is why the
  # repair is to scope the key and NOT to auto-remove or quarantine a
  # colliding directory.
  local b_ok=1 bdetail="" bkey
  local btmp="$TMPROOT/board-scope" baudit="$TMPROOT/board-scope-audit"
  if [ ! -x "$setup" ]; then
    bad "scratch-is-board-scoped" "$setup is missing or not executable"
  else
    rm -rf "$btmp" "$baudit"; mkdir -p "$btmp" "$baudit"

    _lane_fixture true true
    [ "$(_rc env TMPDIR="$btmp" FORGE_LANE_AUDIT_ROOT="$baudit" \
              HERMES_KANBAN_BOARD=alpha "$setup" "$lrepo" 1)" = 0 ] \
      || { b_ok=0; bdetail="$bdetail board-alpha-run1-not-0"; }
    # The defect, in one line: a different board reusing run id 1.
    _lane_fixture true true
    [ "$(_rc env TMPDIR="$btmp" FORGE_LANE_AUDIT_ROOT="$baudit" \
              HERMES_KANBAN_BOARD=beta "$setup" "$lrepo" 1)" = 0 ] \
      || { b_ok=0; bdetail="$bdetail cross-board-run1-collided"; }
    # The safety property that must SURVIVE the fix.
    _lane_fixture true true
    [ "$(_rc env TMPDIR="$btmp" FORGE_LANE_AUDIT_ROOT="$baudit" \
              HERMES_KANBAN_BOARD=alpha "$setup" "$lrepo" 1)" = 4 ] \
      || { b_ok=0; bdetail="$bdetail same-board-reuse-not-4"; }
    # Scoped in BOTH places, or board beta dies at the audit instead: the
    # scratch guard fires first and would otherwise mask a board-blind audit.
    { [ -d "$btmp/forge-lane-alpha-1" ] && [ -d "$btmp/forge-lane-beta-1" ]; } \
      || { b_ok=0; bdetail="$bdetail board-missing-from-scratch-path"; }
    { [ -d "$baudit/alpha-1" ] && [ -d "$baudit/beta-1" ]; } \
      || { b_ok=0; bdetail="$bdetail board-missing-from-audit-path"; }

    # A user-chosen slug must not climb out of $TMPDIR. Malformed is refused,
    # not degraded — degrading it would hide an upstream problem.
    _lane_fixture true true
    [ "$(_rc env TMPDIR="$btmp" FORGE_LANE_AUDIT_ROOT="$baudit" \
              HERMES_KANBAN_BOARD=../escape "$setup" "$lrepo" 1)" = 2 ] \
      || { b_ok=0; bdetail="$bdetail unsafe-board-not-2"; }
    [ "$(_rc env TMPDIR="$btmp" FORGE_LANE_AUDIT_ROOT="$baudit" \
              HERMES_KANBAN_BOARD=.. "$setup" "$lrepo" 1)" = 2 ] \
      || { b_ok=0; bdetail="$bdetail dotdot-board-not-2"; }
    # An UNSET board degrades to a sentinel, never to `forge-lane--7`. A
    # leading underscore is illegal in a real Hermes slug, so no board can
    # shadow it.
    _lane_fixture true true
    [ "$(_rc env TMPDIR="$btmp" FORGE_LANE_AUDIT_ROOT="$baudit" \
              HERMES_KANBAN_BOARD= "$setup" "$lrepo" 7)" = 0 ] \
      || { b_ok=0; bdetail="$bdetail unset-board-not-0"; }
    { [ -d "$btmp/forge-lane-_noboard-7" ] && [ ! -e "$btmp/forge-lane--7" ]; } \
      || { b_ok=0; bdetail="$bdetail unset-board-not-sentinel"; }

    # The skill cannot find the capture unless setup EMITS the key, and the
    # documented last-line contract must survive the extra line.
    _lane_fixture true true
    bkey="$(env TMPDIR="$btmp" FORGE_LANE_AUDIT_ROOT="$baudit" \
            HERMES_KANBAN_BOARD=gamma "$setup" "$lrepo" 2 2>&1)"
    printf '%s' "$bkey" | grep -Fq "FORGE_LANE_RUN_KEY=gamma-2" \
      || { b_ok=0; bdetail="$bdetail did-not-emit-run-key"; }
    # The scoping depends on a dispatcher variable, so the skill's runtime
    # table must name it and lane-setup must actually read it. Documented-but-
    # unread, or read-but-undocumented, are the two ways these drift apart.
    grep -Fq 'HERMES_KANBAN_BOARD' "$setup" \
      || { b_ok=0; bdetail="$bdetail setup-does-not-read-the-board"; }
    grep -Fq 'HERMES_KANBAN_BOARD' "$lane" \
      || { b_ok=0; bdetail="$bdetail skill-runtime-table-omits-the-board"; }
    [ "$(printf '%s\n' "$bkey" | tail -1)" \
        = "FORGE_LANE_RUNTIME=$btmp/forge-lane-gamma-2" ] \
      || { b_ok=0; bdetail="$bdetail runtime-path-is-no-longer-the-last-line"; }

    if [ "$b_ok" = 1 ]; then
      ok "scratch-is-board-scoped (two boards share run id 1; same-board reuse still 4)"
    else
      bad "scratch-is-board-scoped" \
          "run ids are board-local, so scratch AND audit must carry the board — while a genuine same-board collision must still refuse —$bdetail"
    fi
  fi

  # Measured: codex followed AGENTS.md to skills/forge-lane and start-chunk,
  # read both in full, and announced it was "using the Forge lane protocol" —
  # i.e. the caller's playbook, including push / PR / board operations.
  if grep -qi 'do NOT push' "$lane" && grep -qi 'do NOT read or follow' "$lane"; then
    ok "role-boundary-prepended"
  else
    bad "role-boundary-prepended" \
        "forge-lane must append an explicit role boundary to every contract (reads are not sandboxed)"
  fi

  # The first worktree-routed bounce force-loaded forge-lane, but the cheap
  # driver still patched the one-line fix itself because the prohibition was
  # only implied by "operator". Diff size must not change component ownership.
  local lane_soul=hermes/profiles/forge-codex-lane.SOUL.md
  if grep -Fq 'Never author the retained implementation yourself' "$lane_soul" \
     && grep -Fq 'Even a one-line repair' "$lane_soul" \
     && grep -Fq 'goes through `codex exec`' "$lane_soul" \
     && grep -Fq 'never use a write,' "$lane" \
     && grep -Fq 'patch, or shell-edit operation' "$lane"; then
    ok "driver-never-authors-diff"
  else
    bad "driver-never-authors-diff" \
        "forge-codex-lane must prohibit direct implementation even for one-line fixes"
  fi

  # Hermes 0.20.4 added a first-class `review` state and TWO new terminating
  # kanban tools. The injected KANBAN_GUIDANCE routes a worker whose
  # kanban_show() lists no children straight at kanban_request_review — and §7
  # creates the prejudge child AT completion time, so the driver is on that
  # branch at every decision point it has. §7 said "exiting without one of
  # these is a protocol violation", which forbids exiting WITHOUT a terminator,
  # not calling a THIRD one; a cheap driver satisfies both texts by requesting
  # review. The card then sits in `review`, not `done`, so ADR-0008 never
  # promotes its dependents, validate-metadata.py (which sits only on the
  # kanban_complete path) is bypassed, and review dispatch respawns the lane as
  # its own reviewer.
  #
  # So the verdict is ONE bounded-window match, not three independent greps.
  # Three greps would still pass with the policy INVERTED — "call
  # `kanban_request_review` when …" while the word "forbidden" survived
  # elsewhere in §7 — which is F65's shape again: a check that survives the
  # removal of the thing it guards was never guarding it. The three greps below
  # only build the failure message. This case never skips; CI is where it earns
  # its keep, so a missing §7 is a FAIL, not an absence of evidence.
  local sec7 sec7_flat term_ok=1 term_detail=""
  sec7="$(sed -n '/^## 7\./,/^## Hard rules/p' "$lane")"
  # Normalised to one line: the prohibition is prose and wraps unpredictably.
  sec7_flat="$(printf '%s' "$sec7" | tr '\n' ' ' | tr -s ' ')"
  [ -n "$sec7_flat" ] || { term_ok=0; term_detail="$term_detail no-section-7"; }
  printf '%s' "$sec7_flat" | grep -Fq 'kanban_request_review' \
    || { term_ok=0; term_detail="$term_detail request_review-unnamed"; }
  printf '%s' "$sec7_flat" | grep -Fq 'kanban_request_changes' \
    || { term_ok=0; term_detail="$term_detail request_changes-unnamed"; }
  printf '%s' "$sec7_flat" | grep -Fq 'forbidden' \
    || { term_ok=0; term_detail="$term_detail no-prohibition-word"; }
  printf '%s' "$sec7_flat" \
    | grep -Eq 'kanban_request_review.{0,80}kanban_request_changes.{0,80}forbidden' \
    || { term_ok=0; term_detail="$term_detail prohibition-not-one-clause"; }
  if [ "$term_ok" = 1 ]; then
    ok "terminator-set-is-closed"
  else
    bad "terminator-set-is-closed" \
        "forge-lane §7 must name kanban_request_review and kanban_request_changes as forbidden in one clause — a card left in review is not done, so ADR-0008 never promotes its dependents —$term_detail"
  fi

  # And the set has to stay closed as the substrate moves. Enumerate the
  # kanban_* tools the INSTALLED Hermes exposes, subtract the coordination
  # verbs that hand control straight back, and require §7 to account for every
  # name that remains — allowed or forbidden, this case does not care which,
  # only that a human decided. The subtraction is deliberately the wrong way
  # round: a new NON-terminating tool trips this too. That false positive is
  # the safe direction — it costs one name in the list below — and it is the
  # only shape that notices 0.21's next terminator instead of re-learning this
  # lesson in production.
  # TWO sources, unioned, because they merely overlap. `EXPOSED_TOOLS` in the
  # MCP transport is the codex_app_server subset (11 kanban tools); toolsets.py's
  # `kanban` toolset carries 14, and IT is what a lane actually resolves from —
  # ~/.hermes/profiles/forge-codex-lane/config.yaml declares
  # `toolsets: [terminal, file, kanban, memory, skills]`. Reading only the MCP
  # list would miss a terminator added to the toolset and not to the transport,
  # which is F65's shape reproduced inside the check written to prevent it.
  # Unioned, neither source moving can silently shrink coverage.
  local hermes_root="$HOME/.hermes/hermes-agent"
  local mcp_src="$hermes_root/agent/transports/hermes_tools_mcp_server.py"
  local ts_src="$hermes_root/toolsets.py"
  local kanban_nonterminating=" kanban_show kanban_list kanban_comment kanban_heartbeat kanban_create kanban_link kanban_unblock kanban_attach kanban_attach_url kanban_attachments "
  # Only a missing CHECKOUT skips. A source that is present but yields nothing
  # is a FAIL: a control that could not run has not passed (F65/F66), and
  # "the other source still had the names" is precisely how coverage shrinks
  # unnoticed. A file missing from a present checkout means upstream moved it.
  if [ "$WITH_HERMES" != 1 ]; then
    skip "terminators-match-the-substrate" "--with-hermes not given"
  elif [ ! -d "$hermes_root" ]; then
    skip "terminators-match-the-substrate" "hermes source not found"
  else
    # Quoted entries only, and windowed to the declaring list in each file:
    # both name kanban tools in nearby prose comments, and matching those
    # would enumerate the wrong set.
    local mcp_tools="" ts_tools="" exposed unaccounted="" ktool src_detail=""
    if [ ! -f "$mcp_src" ]; then
      src_detail="$src_detail mcp-source-missing($mcp_src)"
    else
      mcp_tools="$(awk '/^EXPOSED_TOOLS/{p=1} p{print} p&&/^\)/{exit}' "$mcp_src" \
                   | grep -oE '"kanban_[a-z_]+"' | tr -d '"')"
      [ -n "$mcp_tools" ] || src_detail="$src_detail mcp-source-yielded-no-kanban-tools"
    fi
    if [ ! -f "$ts_src" ]; then
      src_detail="$src_detail toolsets-source-missing($ts_src)"
    else
      ts_tools="$(awk '/^[[:space:]]*"kanban":[[:space:]]*\{/{k=1} k&&/"tools":[[:space:]]*\[/{t=1} t{print} t&&/\]/{exit}' \
                    "$ts_src" | grep -oE '"kanban_[a-z_]+"' | tr -d '"')"
      [ -n "$ts_tools" ] || src_detail="$src_detail toolsets-source-yielded-no-kanban-tools"
    fi
    exposed="$(printf '%s\n%s\n' "$mcp_tools" "$ts_tools" | grep -E '^kanban_' | sort -u)"
    if [ -n "$src_detail" ]; then
      bad "terminators-match-the-substrate" \
          "the kanban tool enumeration broke, which is not evidence about the skill — fix the reader, do not let the other source stand in for it:$src_detail"
    elif [ -z "$sec7_flat" ]; then
      bad "terminators-match-the-substrate" \
          "forge-lane §7 did not delimit — cannot tell which terminators it accounts for"
    else
      # Subtract the coordination verbs that hand control straight back; every
      # name left ENDS the run and §7 must account for it — allowed or
      # forbidden, this case does not care which, only that a human decided.
      # The subtraction is deliberately the wrong way round: a new
      # NON-terminating tool trips this too. That false positive is the safe
      # direction — it costs one name in the list above — and it is the only
      # shape that notices 0.21's next terminator instead of re-learning this
      # lesson in production.
      for ktool in $exposed; do
        case "$kanban_nonterminating" in *" $ktool "*) continue;; esac
        printf '%s' "$sec7_flat" | grep -Fq "$ktool" \
          || unaccounted="$unaccounted $ktool"
      done
      if [ -z "$unaccounted" ]; then
        ok "terminators-match-the-substrate ($(printf '%s\n' "$exposed" | grep -c .) kanban tools unioned from EXPOSED_TOOLS + the kanban toolset; every terminator among them is named in §7)"
      else
        bad "terminators-match-the-substrate" \
            "the installed Hermes exposes kanban tools §7 never mentions:$unaccounted — name each in §7 as allowed or forbidden, or (if it does not end the run) add it to kanban_nonterminating in this case"
      fi
    fi
  fi

  # The grant is bounded by a NAMED set, not by freezing the shared .git. An
  # earlier revision asserted whole-.git immutability and blocked clean chunks
  # on a sibling lane's commit, on any fetch, and on pre-existing malformed
  # history (audit F75/F76) — so the positive cases below are load-bearing:
  # they pin the false positives shut. Every case gets a fresh linked worktree
  # and its own capture, so a previous breach cannot make a later one pass.
  local blast=scripts/lane-blast-radius.sh
  local bmain="$TMPROOT/blast-main" brepo="$TMPROOT/blast-task" \
        bsibling="$TMPROOT/blast-sibling" borigin="$TMPROOT/blast-origin.git" \
        bhooks="" bshared="" brun=""
  _blast_fixture() { # $1=run id
    brun="$1"
    rm -rf "$bmain" "$brepo" "$bsibling" "$borigin"
    # Bare-repository HEAD follows the host's init.defaultBranch. Pin it: a
    # dangling `master` HEAD on Linux makes connectivity checks reject an
    # otherwise healthy fixture whose only pushed branch is main.
    git init -q --bare -b main "$borigin" >/dev/null 2>&1 || return 1
    git init -q -b main "$bmain" >/dev/null 2>&1 || return 1
    mkdir -p "$bmain/.forge"
    printf 'policy=v1\n' > "$bmain/.forge/policy"
    git -C "$bmain" add -A >/dev/null 2>&1 \
      && git -C "$bmain" -c user.email=v@v -c user.name=v commit -qm init \
      && git -C "$bmain" remote add origin "$borigin" \
      && git -C "$bmain" push -q origin main \
      && git -C "$bmain" branch task \
      && git -C "$bmain" branch sibling \
      && git -C "$bmain" worktree add -q "$brepo" task \
      && git -C "$bmain" worktree add -q "$bsibling" sibling || return 1
    # Mirror what lane-setup.sh does: this worktree gets its own hooks dir, so
    # the shared one below is the OPERATOR's and must stay untouched.
    bshared="$bmain/.git/hooks"
    git -C "$brepo" config extensions.worktreeConfig true >/dev/null 2>&1 || return 1
    bhooks="$(git -C "$brepo" rev-parse --git-dir)/hooks" || return 1
    mkdir -p "$bhooks" || return 1
    git -C "$brepo" config --worktree core.hooksPath "$bhooks" >/dev/null 2>&1 || return 1
    [ "$(git -C "$brepo" rev-parse --git-path hooks)" = "$bhooks" ] || return 1
    printf '#!/bin/sh\nexit 0\n' > "$bhooks/pre-commit"
    chmod 755 "$bhooks/pre-commit"
    printf '#!/bin/sh\nexit 0\n' > "$bshared/pre-push"
    chmod 755 "$bshared/pre-push"
    printf '#!/bin/sh\nexit 0\n' > "$TMPROOT/$brun-hook-ok"
    printf '#!/bin/sh\nexit 1\n' > "$TMPROOT/$brun-hook-bad"
    chmod 755 "$TMPROOT/$brun-hook-ok" "$TMPROOT/$brun-hook-bad"
    ln -s "$TMPROOT/$brun-hook-ok" "$bhooks/pre-push"
    env FORGE_LANE_AUDIT_ROOT="$laudit" "$blast" capture "$brepo" "$brun" \
      >/dev/null 2>&1
  }
  _blast_rc() {
    local rc
    env FORGE_LANE_AUDIT_ROOT="$laudit" "$blast" check "$brepo" "$brun" \
      > "$TMPROOT/$brun-check.out" 2>&1
    rc=$?
    printf '%s\n' "$rc"
  }
  _expect_blast() { # name expected actual
    local detail evidence
    if [ "$3" = "$2" ]; then
      ok "$1"
    else
      detail="$(tr '\n' ' ' < "$TMPROOT/$brun-check.out" 2>/dev/null | sed 's/[[:space:]]*$//')"
      evidence="$(tail -8 "$laudit/$brun/breach.txt" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
      bad "$1" "lane-blast-radius expected exit $2, observed $3; output: ${detail:-<none>}; evidence: ${evidence:-<none>}"
    fi
  }

  if [ ! -x "$blast" ]; then
    bad "lane-final-worktree-is-clean" "$blast is missing or not executable"
  elif ! grep -Fq '~/.forge/repo/scripts/lane-blast-radius.sh' "$lane"; then
    bad "lane-final-worktree-is-clean" \
        "forge-lane §5 no longer invokes $blast — a bare relative path cannot resolve from a project worktree, so it must be the ~/.forge/repo form"
  elif ! grep -Fq '"$BLAST" capture "$WS_PHYS" "$SCOPE"' "$setup"; then
    # $SCOPE, not $RUN_ID: run ids are board-local, so the audit baseline is
    # filed under lane-setup's board-scoped key. This guard is an `elif` over
    # the whole blast subgroup — when it stops matching, twenty cases silently
    # do not run rather than turning red, so it must track the real call.
    bad "lane-capture-is-pre-codex" \
        "lane-setup must take the immutable capture, under the board-scoped key, before it can return ready"
  else
    _blast_fixture blast-base || bad "blast-fixture" "could not create linked-worktree fixture"
    _expect_blast "blast/missing-run-capture" 2 \
      "$(_rc env FORGE_LANE_AUDIT_ROOT="$laudit" "$blast" check "$brepo" absent-run)"
    _expect_blast "blast/capture-is-single-use" 2 \
      "$(_rc env FORGE_LANE_AUDIT_ROOT="$laudit" "$blast" capture "$brepo" "$brun")"
    _expect_blast "blast/clean-linked-worktree" 0 "$(_blast_rc)"
    _expect_blast "blast/check-is-single-use" 2 "$(_blast_rc)"
    [ -f "$laudit/$brun/capture.complete" ] && [ ! -e "$brepo/.forge/main.before" ] \
      && ok "blast/baseline-is-outside-codex-roots" \
      || bad "blast/baseline-is-outside-codex-roots" \
          "capture must live in the protected audit root, never the worktree"

    _blast_fixture blast-failed-check-retry
    chmod 644 "$bhooks/pre-commit"
    first_check="$(_blast_rc)"
    chmod 755 "$bhooks/pre-commit"
    second_check="$(_blast_rc)"
    if [ "$first_check" = 3 ] && [ "$second_check" = 2 ]; then
      ok "blast/failed-check-cannot-be-retried"
    else
      bad "blast/failed-check-cannot-be-retried" \
          "first breach check returned $first_check; replay returned $second_check"
    fi

    _blast_fixture blast-task-commit
    printf 'task\n' > "$brepo/task.txt"
    git -C "$brepo" add task.txt \
      && git -C "$brepo" -c user.email=v@v -c user.name=v commit -qm task
    _expect_blast "blast/task-commit-is-the-allowed-path" 0 "$(_blast_rc)"

    _blast_fixture blast-hook-rename
    mv "$bhooks/pre-commit" "$bhooks/commit-msg"
    _expect_blast "blast/hook-rename-is-a-breach" 3 "$(_blast_rc)"

    _blast_fixture blast-hook-mode
    chmod 644 "$bhooks/pre-commit"
    _expect_blast "blast/hook-mode-is-a-breach" 3 "$(_blast_rc)"

    _blast_fixture blast-hook-link
    rm "$bhooks/pre-push"
    ln -s "$TMPROOT/$brun-hook-bad" "$bhooks/pre-push"
    _expect_blast "blast/hook-symlink-retarget-is-a-breach" 3 "$(_blast_rc)"

    _blast_fixture blast-hook-link-content
    printf '#!/bin/sh\nexit 1\n' > "$TMPROOT/$brun-hook-ok"
    _expect_blast "blast/hook-symlink-target-content-is-protected" 3 "$(_blast_rc)"

    _blast_fixture blast-hook-unreadable
    chmod 000 "$bhooks/pre-commit"
    _expect_blast "blast/unreadable-hook-fails-closed" 3 "$(_blast_rc)"

    _blast_fixture blast-config
    git -C "$brepo" config forge.probe changed
    _expect_blast "blast/shared-config-is-protected" 3 "$(_blast_rc)"

    _blast_fixture blast-forge-dirt
    printf 'policy=v2\n' > "$brepo/.forge/policy"
    printf 'leftover\n' > "$brepo/.forge/patch.orig"
    _expect_blast "blast/forge-dirt-is-not-hidden" 3 "$(_blast_rc)"

    _blast_fixture blast-index
    printf 'not-an-index\n' > "$(git -C "$brepo" rev-parse --git-path index)"
    _expect_blast "blast/unreadable-status-fails-closed" 3 "$(_blast_rc)"

    _blast_fixture blast-main-moved
    git -C "$brepo" -c user.email=v@v -c user.name=v commit -q --allow-empty -m moved \
      && git -C "$brepo" update-ref refs/heads/main HEAD
    _expect_blast "blast/main-is-protected" 3 "$(_blast_rc)"

    _blast_fixture blast-worktree-config
    git -C "$brepo" config --worktree core.hooksPath "$TMPROOT/$brun-elsewhere"
    _expect_blast "blast/worktree-config-is-protected" 3 "$(_blast_rc)"

    _blast_fixture blast-shared-hooks
    printf '#!/bin/sh\nexit 1\n' > "$bshared/pre-push"
    _expect_blast "blast/shared-hooks-are-protected" 3 "$(_blast_rc)"

    _blast_fixture blast-alternates
    printf '%s\n' "$TMPROOT/$brun-elsewhere" \
      > "$(git -C "$brepo" rev-parse --git-common-dir)/objects/info/alternates"
    _expect_blast "blast/object-alternates-are-protected" 3 "$(_blast_rc)"

    _blast_fixture blast-object
    object_id="$(git -C "$brepo" rev-parse HEAD^{tree})"
    object_dir="$(git -C "$brepo" rev-parse --git-common-dir)/objects/${object_id%${object_id#??}}"
    object_file="$object_dir/${object_id#??}"
    mv "$object_file" "$TMPROOT/$brun-object.saved"
    _expect_blast "blast/pre-existing-objects-are-protected" 3 "$(_blast_rc)"

    # --- the false positives this audit must NOT raise ------------------------
    # Each of these was a reproduced block against a clean chunk. They are
    # positive assertions on purpose: a wide audit passes every negative case
    # above and is still unusable.

    # A dispatcher runs lanes off ONE shared .git. From in here, a sibling's
    # branch moving is indistinguishable from Codex moving it, so it cannot be
    # protected — and must not be reported.
    _blast_fixture blast-sibling-lane
    printf 'sib\n' > "$bsibling/sib.txt"
    git -C "$bsibling" add sib.txt \
      && git -C "$bsibling" -c user.email=v@v -c user.name=v commit -qm sibling
    git -C "$brepo" fetch origin >/dev/null 2>&1
    _expect_blast "blast/sibling-lane-is-not-a-breach" 0 "$(_blast_rc)"

    # `git fsck --full` validates object CONTENT, so a repo carrying malformed
    # history blocked every chunk on it forever, blaming Codex for a commit
    # that predated the run. Connectivity is the property that matters.
    _blast_fixture blast-legacy-object
    legacy_raw="$TMPROOT/$brun-legacy.raw"
    printf 'tree %s\nparent %s\nauthor A <a@b> 1000000000 +0000\ncommitter A<a@b> 1000000000 +0000\n\nlegacy import\n' \
      "$(git -C "$brepo" rev-parse HEAD^{tree})" "$(git -C "$brepo" rev-parse HEAD)" > "$legacy_raw"
    legacy_oid="$(git -C "$brepo" hash-object -w -t commit --stdin --literally < "$legacy_raw" 2>/dev/null)"
    if [ -n "$legacy_oid" ] \
       && ! git -C "$brepo" fsck --full --no-reflogs --no-dangling --no-progress >/dev/null 2>&1; then
      _expect_blast "blast/pre-existing-fsck-damage-is-not-a-breach" 0 "$(_blast_rc)"
    else
      skip "blast/pre-existing-fsck-damage-is-not-a-breach" \
           "this git does not accept a malformed object even with --literally"
    fi

    # A breach the operator cannot diagnose is barely better than none: the
    # manifest hashes the path, so without the display column and the evidence
    # file a misfire says only that "something" moved.
    _blast_fixture blast-evidence
    printf 'leftover\n' > "$brepo/patch.orig"
    evidence_out="$(env FORGE_LANE_AUDIT_ROOT="$laudit" "$blast" check "$brepo" "$brun" 2>/dev/null)"
    if printf '%s' "$evidence_out" | grep -Fq 'patch.orig' \
       && grep -Fq 'patch.orig' "$laudit/$brun/breach.txt" 2>/dev/null; then
      ok "blast/breach-names-what-moved"
    else
      bad "blast/breach-names-what-moved" \
          "the reason line and $laudit/<run>/breach.txt must both name the offending path, not just a category"
    fi
  fi

  # A parent chunk is marked done when its PR opens. Measured on D1 -> D2:
  # D2 promoted immediately, blocked because key.py was absent, auto-promoted
  # again when it used kind=dependency, then invented a stacked-branch rebase.
  # Code dependencies need the parent PR integrated, and the wait must be
  # sticky because the board-level parent is already done.
  if grep -Fq 'mergedAt' "$lane" \
     && grep -Fq 'the `failing-prereq:` classification' "$lane" \
     && grep -Fq 'kanban_block(kind="needs_input"' "$lane" \
     && grep -Fq 'Do **not** use block kind `dependency`' "$lane" \
     && grep -Fq 'unmerged parent branch or silently create a stacked PR' "$lane" \
     && grep -Fq 'git rebase "origin/$parent_base"' "$lane"; then
    ok "dependent-pr-must-be-merged"
  else
    bad "dependent-pr-must-be-merged" \
        "a done parent card must not release implementation until its PR is merged; wait sticky and never invent a stacked branch"
  fi

  # The first real graph was created in two passes: both cards were briefly
  # ready, then `kanban link` demoted the child. A dispatcher tick between
  # those writes can claim the child without its prerequisite. The corrected
  # bootstrap creates in topological order and passes every --parent in the
  # card's create transaction, then reads the parents back.
  local bootstrap=hermes/board-bootstrap.sh
  if grep -Fq 'parent_args+=(--parent "$parent_card")' "$bootstrap" \
     && grep -Fq 'if [ "$parent_count" -eq 0 ]' "$bootstrap" \
     && grep -Fq 'created=$((created + parent_count))' "$bootstrap" \
     && grep -Fq '"${@:6}" --json' "$bootstrap" \
     && grep -Fq '.parents[]?' "$bootstrap" \
     && ! sed -n '/# full mode:/,$p' "$bootstrap" \
          | grep -Eq 'hermes kanban( --board "[^"]+")? link '; then
    ok "graph-parents-are-atomic"
  else
    bad "graph-parents-are-atomic" \
        "board-bootstrap must attach graph parents during create and read them back, never create ready children before a later link pass"
  fi

  # `uv run` writes a cache and ~/.cache/uv is outside the sandbox. Keep every
  # lane-owned scratch file in one run-specific $TMPDIR, which the sandbox can
  # write without forcing the final worktree check to ignore a whole directory.
  #
  # The path has exactly ONE definition. The skill used to recompute the
  # `${TMPDIR:-/tmp}/forge-lane-...` string that lane-setup.sh builds, so a
  # $TMPDIR differing between the driver's shell and the script would put the
  # contract somewhere setup never created. Setup emits it; the skill consumes
  # it. The same now holds for the audit key: setup emits FORGE_LANE_RUN_KEY
  # and §5 passes it back, because a run id alone is board-local and collides.
  # The negative pin below names the RETIRED string. Once the path became
  # board-scoped that grep would still pass against a form nothing produces,
  # so it is kept AND joined by pins on the current one — a stale assertion
  # that can no longer fail is this repo's signature bug, and leaving only the
  # old one would have committed it in the very fix for it.
  local lane_audit_call
  lane_audit_call="$(grep -A2 -F 'lane-blast-radius.sh check' "$lane")"
  if grep -Fq 'FORGE_LANE_RUNTIME=$RUNTIME_DIR' "$setup" \
     && grep -Fq 'FORGE_LANE_RUN_KEY=$SCOPE' "$setup" \
     && grep -Fq 'UV_CACHE_DIR="$FORGE_LANE_RUNTIME/uv-cache"' "$lane" \
     && grep -Fq 'UV_CACHE_DIR="$FORGE_LANE_RUNTIME/uv-cache"' scripts/codex-run.sh \
     && grep -Fq 'FORGE_LANE_RUNTIME' "$lane" \
     && ! grep -Fq 'forge-lane-$HERMES_KANBAN_RUN_ID' "$lane" \
     && ! grep -Fq 'forge-lane-$HERMES_KANBAN_BOARD' "$lane" \
     && printf '%s' "$lane_audit_call" | grep -Fq '"$FORGE_LANE_RUN_KEY"' \
     && ! printf '%s' "$lane_audit_call" | grep -Fq '"$HERMES_KANBAN_RUN_ID"' \
     && ! grep -Fq '.forge/uv-cache' "$lane"; then
    ok "uv-cache-dir-is-deterministic-and-outside-worktree"
  else
    bad "uv-cache-dir-is-deterministic-and-outside-worktree" \
        "lane-setup must emit FORGE_LANE_RUNTIME and FORGE_LANE_RUN_KEY and the skill must consume both — never recompute the \$TMPDIR path, and never audit under the bare run id"
  fi

  # The rule above binds the SKILL. It did not bind this suite's own live probe,
  # and on 2026-09-02 that gap cost a paid commissioning run: `lane-setup.sh`
  # began filing the capture under the board-scoped key while
  # substrate/codex-worktree-commit still called `check` with the bare run id.
  # That case is SKIPPED without --with-codex, so a full green `verify.sh` and a
  # green CI both reported healthy while the audit pairing was broken.
  #
  # So the probe is pinned the same way the skill is, and for free. A rule with
  # two callers needs two pins: pinning only the one that is cheap to test is
  # how the first copy drifted.
  local codex_probe
  # awk that EXITS at the probe's closing line, not a sed range. A guard that
  # greps its own source file is self-referential: this block quotes the very
  # literals it pins, so any range that can re-open later swallows the guard and
  # trips its own negative pin. Exiting at the first close keeps the window on
  # the probe (~line 890) and can never reach this block. Both failure modes
  # were measured while writing it, which is the argument for red-before-green.
  codex_probe="$(awk '/live_run="verify-codex-/{f=1} f{print} f && /ok "codex-worktree-commit/{exit}' scripts/verify.sh)"
  if printf '%s' "$codex_probe" | grep -Fq 's/^FORGE_LANE_RUN_KEY=//p' \
     && printf '%s' "$codex_probe" | grep -Fq 'check "$LABROOT/linked" "$live_key"' \
     && printf '%s' "$codex_probe" | grep -Fq '"$live_audit/$live_key/check.complete"' \
     && ! printf '%s' "$codex_probe" | grep -Fq 'check "$LABROOT/linked" "$live_run"'; then
    ok "codex-probe-audits-the-emitted-key"
  else
    bad "codex-probe-audits-the-emitted-key" \
        "substrate/codex-worktree-commit must read FORGE_LANE_RUN_KEY out of lane-setup's output and audit under it — auditing under \$live_run breaks the moment the key gains a component, and only --with-codex would notice"
  fi

  # Codex's workaround for the missing venv was UV_CACHE_DIR + UV_OFFLINE.
  # That green is not the command CI runs, so the lane must re-verify plainly.
  if sed -n '/^## 5\./,/^## 6\./p' "$lane" | grep -q 'UV_OFFLINE'; then
    ok "verification-is-plain-make-check"
  else
    bad "verification-is-plain-make-check" \
        "forge-lane §5 must require a plain 'make check' (no UV_OFFLINE/UV_CACHE_DIR green)"
  fi

  # The template's own AGENTS.md is what sent Codex to the ceremony skills.
  if grep -q 'interactive operator' "$agents" && grep -q 'implement exactly it and stop' "$agents"; then
    ok "template-agents-scopes-ceremonies"
  else
    bad "template-agents-scopes-ceremonies" \
        "AGENTS.md.jinja must scope ceremony skills to the interactive operator"
  fi

  # ---------------------------------------------------------------------
  # The prejudge SOUL is IDENTITY, not protocol (ADR-0010, audit F61). Only
  # what a model must read and obey is asserted here. Everything the protocol
  # *does* is a program now and is EXECUTED in the prejudge/ group instead.
  #
  # Until 2026-08-05 eleven cases in this group asserted runtime behaviour by
  # substring match, and one by comparing the line numbers of two `grep -n`
  # results. The comment that used to sit at `prejudge-cost-is-observed`
  # recorded them silently diverging from the SOUL for a whole commit — which
  # is the strongest argument available that a protocol living in prose can be
  # approximated but not tested (F63).
  # ---------------------------------------------------------------------
  local soul=hermes/profiles/forge-prejudge.SOUL.md
  local review=scripts/prejudge-review.sh

  if grep -Fq 'scripts/prejudge-review.sh' "$soul" && [ -x "$review" ]; then
    ok "prejudge-delegates-its-protocol"
  else
    bad "prejudge-delegates-its-protocol" \
        "the SOUL must name $review, and that script must exist and be executable"
  fi

  # The rc -> terminator mapping is the one part that CANNOT move into the
  # script: only the model holds kanban_complete/kanban_block, which the
  # completion kernel ties to the identity of the running task. A substrate
  # fault and a bounce take different terminators on purpose, so that an
  # outage can never read as a rejection.
  if grep -Eq '^ *\| 0 \|.*kanban_complete' "$soul" \
     && grep -Eq '^ *\| 3 \|.*kanban_block' "$soul" \
     && grep -Fq 'never report an outage as a rejection' "$soul" \
     && grep -Fq 'Exiting while still' "$soul"; then
    ok "prejudge-terminator-mapping"
  else
    bad "prejudge-terminator-mapping" \
        "the SOUL must map rc 0 to kanban_complete and rc 3 to kanban_block, and forbid exiting while running"
  fi

  # The prohibition stays prose because it constrains the model. The
  # MEASUREMENT that the protocol never prints a diff is now behavioural:
  # prejudge/review-never-prints-the-diff runs it against a recorded 63 KB
  # patch and greps the output for hunk headers.
  if grep -Fq 'Never render a diff' "$soul" && grep -Fq '127,738' "$soul"; then
    ok "driver-never-reads-the-diff"
  else
    bad "driver-never-reads-the-diff" \
        "the SOUL must forbid rendering a diff into the metered driver's context"
  fi

  # ADR-0009 retired the CI-red sentinel: CI is a gate check now, so the zeroed
  # six-dimension verdict that existed to make `/retro` count the bounce has no
  # subject left. Five invented dimension scores are the same defect as the
  # zeroed cost object this protocol already refuses to write.
  if grep -Fq 'forge.gate.v1' "$soul" && grep -Fq 'forge.judge.v1' "$soul" \
     && grep -Fq 'never manufacture the one that did not' "$soul" \
     && ! grep -Fq 'all six scores set to zero' "$soul" \
     && ! grep -Fq 'deterministic sentinel' rubrics/judge-rubric.md; then
    ok "prejudge-stores-what-happened"
  else
    bad "prejudge-stores-what-happened" \
        "tier 1 must store forge.gate.v1 on a gate block and forge.judge.v1 on a scored review, and the ci-red zeroed-score sentinel must be gone (ADR-0009 D9.4)"
  fi
}
wants lane      && run_lane_group

# ---------------------------------------------------------------------------
# bootstrap/ — CHUNK-8 staged launch, executed through the real source.
# ---------------------------------------------------------------------------
run_bootstrap_group() {
  group bootstrap
  local bootstrap="$REPO_ROOT/hermes/board-bootstrap.sh"

  _bootstrap_fixture() { # $1=root $2=graph shape
    local root="$1" shape="$2" id
    rm -rf "$root"
    mkdir -p "$root/bin" "$root/docs/chunks" "$root/state"
    git -C "$root" init -q

    case "$shape" in
      normal)
        cat > "$root/docs/chunks/graph.json" <<'BOOTSTRAP_GRAPH'
[
  {"id":"CHUNK-1","lane":"forge-codex-lane","depends_on":[]},
  {"id":"CHUNK-2","lane":"forge-codex-lane","depends_on":["CHUNK-1"]},
  {"id":"CHUNK-3","lane":"forge-codex-lane","depends_on":["CHUNK-2"]}
]
BOOTSTRAP_GRAPH
        ;;
      multi-root)
        cat > "$root/docs/chunks/graph.json" <<'BOOTSTRAP_GRAPH'
[
  {"id":"CHUNK-1","lane":"forge-codex-lane","depends_on":[]},
  {"id":"CHUNK-2","lane":"forge-codex-lane","depends_on":[]},
  {"id":"CHUNK-3","lane":"forge-codex-lane","depends_on":["CHUNK-1"]}
]
BOOTSTRAP_GRAPH
        ;;
      interactive)
        cat > "$root/docs/chunks/graph.json" <<'BOOTSTRAP_GRAPH'
[
  {"id":"CHUNK-1","lane":"claude-interactive","depends_on":[]},
  {"id":"CHUNK-2","lane":"forge-codex-lane","depends_on":["CHUNK-1"]},
  {"id":"CHUNK-3","lane":"forge-codex-lane","depends_on":["CHUNK-2"]}
]
BOOTSTRAP_GRAPH
        ;;
      interactive-child)
        # The shape the parentless `interactive` fixture above cannot reach: an
        # interactive chunk with a parent that is NOT done, which is what every
        # mid-graph human chunk looks like on a first `full` run.
        cat > "$root/docs/chunks/graph.json" <<'BOOTSTRAP_GRAPH'
[
  {"id":"CHUNK-1","lane":"forge-codex-lane","depends_on":[]},
  {"id":"CHUNK-2","lane":"claude-interactive","depends_on":["CHUNK-1"]}
]
BOOTSTRAP_GRAPH
        ;;
      bad-space)
        printf '%s\n' '[{"id":"CHUNK 1","lane":"forge-codex-lane","depends_on":[]}]' \
          > "$root/docs/chunks/graph.json"
        ;;
      bad-slash)
        printf '%s\n' '[{"id":"CHUNK/1","lane":"forge-codex-lane","depends_on":[]}]' \
          > "$root/docs/chunks/graph.json"
        ;;
      bad-traversal)
        printf '%s\n' '[{"id":"CHUNK-../1","lane":"forge-codex-lane","depends_on":[]}]' \
          > "$root/docs/chunks/graph.json"
        ;;
      bad-dependency)
        printf '%s\n' '[{"id":"CHUNK-1","lane":"forge-codex-lane","depends_on":["CHUNK 0"]}]' \
          > "$root/docs/chunks/graph.json"
        ;;
      branch-names)
        cat > "$root/docs/chunks/graph.json" <<'BOOTSTRAP_GRAPH'
[
  {"id":"CHUNK-C10","lane":"forge-codex-lane","depends_on":[]},
  {"id":"CHUNK-C9.1","lane":"forge-codex-lane","depends_on":["CHUNK-C10"]},
  {"id":"CHUNK-7","lane":"forge-codex-lane","depends_on":["CHUNK-C9.1"]},
  {"id":"CHUNK-C11","lane":"forge-codex-lane","depends_on":["CHUNK-7"]}
]
BOOTSTRAP_GRAPH
        # Real heading shapes, id included, because the H3 repeats it. The three
        # id forms are the ones seen in the wild — letter-prefixed, dotted, and
        # bare. CHUNK-C11 is the pathological title: punctuation and non-ASCII
        # only, which cleans to an empty slug and must still name a valid branch.
        printf '### CHUNK-C10: Resolve every instance path from its own config file\n' \
          > "$root/docs/chunks/CHUNK-C10.md"
        printf '### CHUNK-C9.1: Pipeline observability \xe2\x80\x94 the run, its cost and its shape\n' \
          > "$root/docs/chunks/CHUNK-C9.1.md"
        printf '### CHUNK-7: Render report\n' > "$root/docs/chunks/CHUNK-7.md"
        printf '### CHUNK-C11: \xc2\xa1\xc2\xbf \xe2\x80\x94 \xe2\x98\x85 ***\n' \
          > "$root/docs/chunks/CHUNK-C11.md"
        # The stamped product's own copy of the rule, so the generator asks its
        # consumer during the run and not only in the assertion below.
        mkdir -p "$root/scripts"
        cp "$REPO_ROOT/templates/python-service/template/scripts/branch-name.sh" \
           "$root/scripts/branch-name.sh"
        chmod +x "$root/scripts/branch-name.sh"
        ;;
      *) return 1;;
    esac

    for id in CHUNK-1 CHUNK-2 CHUNK-3; do
      printf '### %s: bootstrap fixture\n' "$id" > "$root/docs/chunks/$id.md"
    done

    cat > "$root/bin/hermes" <<'HERMES_STUB'
#!/usr/bin/env bash
set -eu
state="${STUB_STATE:?}"
[ "${1:-}" = kanban ] || exit 64
shift
printf '%s\n' "$*" >> "$state/commands.log"

case "${1:-}" in
  init) exit 0;;
  assignees)
    # Two shapes, and board-bootstrap.sh reads the JSON one. The TABLE lists
    # every name a card has ever carried and marks each yes/no for whether a
    # profile exists on disk, so an unanchored grep over it clears names that
    # cannot receive a card. forge-operator-handoff is in both listings, with
    # no profile, precisely so a substring match here would be a false pass.
    for arg in "$@"; do
      [ "$arg" = --json ] || continue
      printf '[{"name":"forge-codex-lane","on_disk":true,"counts":{}},\n'
      printf ' {"name":"forge-operator-handoff","on_disk":false,"counts":{}}]\n'
      exit 0
    done
    # ONE write: `grep -q` closes the pipe on its first match, and a second
    # printf into a closed pipe would make this stub exit non-zero under the
    # caller's `pipefail` — a race, not a finding.
    printf 'NAME                    ON DISK   COUNTS\nforge-codex-lane        yes\nforge-operator-handoff  no\n'
    exit 0
    ;;
  boards)
    shift
    case "${1:-}" in
      create) exit 0;;
      set-default-workdir)
        printf '%s' "$2" > "$state/board"
        printf '%s' "$3" > "$state/workdir"
        exit 0
        ;;
      list)
        jq -n --arg board "$(cat "$state/board")" \
              --arg workdir "$(cat "$state/workdir")" \
              '[{slug:$board,default_workdir:$workdir}]'
        exit 0
        ;;
    esac
    ;;
  --board)
    board="$2"
    shift 2
    command="${1:-}"
    shift
    case "$command" in
      create)
        title="${1:-}"
        shift
        key=""; parents=""; assignee=""; initial=""; branch=""; triage=0
        workspace=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --idempotency-key) key="$2"; shift 2;;
            --parent) parents="${parents}${2}"$'\n'; shift 2;;
            --assignee) assignee="$2"; shift 2;;
            --initial-status) initial="$2"; shift 2;;
            --branch) branch="$2"; shift 2;;
            --workspace) workspace="$2"; shift 2;;
            --triage) triage=1; shift;;
            --body|--max-retries|--skill) shift 2;;
            --json) shift;;
            *) shift;;
          esac
        done
        [ -n "$key" ] || exit 65
        # The CLI couples these two flags and refuses the pair outright:
        #   kanban: --branch is only valid with --workspace worktree
        # Measured 2026-09-03: this stub used to swallow --workspace and accept
        # a lone --branch, so a change that added --branch to the interactive
        # card passed 8/8 here and then failed on its FIRST real invocation —
        # the same class of lie as the --initial-status echo above, one fix
        # later. A double that accepts arguments the real CLI rejects can only
        # ever confirm the caller.
        if [ -n "$branch" ] && [ "$workspace" != worktree ]; then
          printf 'kanban: --branch is only valid with --workspace worktree\n' >&2
          exit 2
        fi
        touch "$state/keys.tsv" "$state/creates.tsv"
        cid="$(awk -F '\t' -v key="$key" '$1==key{print $2; exit}' "$state/keys.tsv")"
        if [ -z "$cid" ]; then
          cid="card-$(( $(wc -l < "$state/keys.tsv" | tr -d ' ') + 1 ))"
          printf '%s\t%s\n' "$key" "$cid" >> "$state/keys.tsv"
          printf '%s' "$parents" > "$state/$cid.parents"
          # The kernel COMPUTES the initial status; it never echoes back the
          # one it was handed, and it has no `running` outcome at all
          # (kanban_db.py 3441-3462): --initial-status blocked -> blocked,
          # --triage -> triage, otherwise ready, downgraded to todo when ANY
          # parent is not done. This stub used to store the passed value, so it
          # modelled a kernel that does not exist and every caller that read
          # `running` back from create was green here and fatal in production.
          if [ "$initial" = blocked ]; then
            status=blocked
          elif [ "$triage" = 1 ]; then
            status=triage
          else
            status=ready
            for parent in $parents; do
              [ "$(cat "$state/$parent.status" 2>/dev/null || true)" = done ] \
                || { status=todo; break; }
            done
          fi
          printf '%s' "$status" > "$state/$cid.status"
          printf '%s' "$assignee" > "$state/$cid.assignee"
          printf '%s' "$title" > "$state/$cid.title"
          printf '%s\n' "$branch" >> "$state/branches.txt"
          printf '%s\t%s\t%s\t%s\n' "$key" "$cid" \
            "$(printf '%s' "$parents" | paste -sd, -)" "$title" >> "$state/creates.tsv"
        fi
        jq -n --arg id "$cid" --arg board "$board" '{id:$id,board:$board}'
        exit 0
        ;;
      show)
        cid="${1:?}"
        if [ "${STUB_DROP_PARENTS:-0}" = 1 ]; then
          parents='[]'
        else
          parents="$(jq -R -s 'split("\n") | map(select(length > 0))' \
            "$state/$cid.parents")"
        fi
        status="$(cat "$state/$cid.status")"
        assignee="$(cat "$state/$cid.assignee")"
        if [ -f "$state/$cid.blocked" ]; then
          events='[{"kind":"blocked"}]'
        else
          events='[]'
        fi
        jq -n --argjson parents "$parents" --argjson events "$events" \
          --arg status "$status" --arg assignee "$assignee" \
          --arg id "$cid" --arg title "$(cat "$state/$cid.title")" \
          '{task:{id:$id,title:$title,status:$status,
                  assignee:(if $assignee == "" then null else $assignee end)},
            events:$events,parents:$parents}'
        exit 0
        ;;
      block)
        cid=""
        for arg in "$@"; do case "$arg" in card-*) cid="$arg";; esac; done
        [ -n "$cid" ] || exit 65
        # block_task updates `WHERE status IN ('running','ready')`. From any
        # other status it changes nothing and returns False, so a caller that
        # blocks a `todo` card gets a card that is still dispatchable.
        current="$(cat "$state/$cid.status" 2>/dev/null || true)"
        case "$current" in
          running|ready) ;;
          *)
            printf 'block refused: %s is %s, not running/ready\n' \
              "$cid" "${current:-missing}" >&2
            exit 66
            ;;
        esac
        printf blocked > "$state/$cid.status"
        # Stickiness is the EVENT, not the status: only a real block call
        # writes it, and recompute_ready re-promotes a card that lacks it.
        : > "$state/$cid.blocked"
        exit 0
        ;;
      assign)
        cid="${1:?}"
        [ "${2:-}" = none ] || exit 65
        : > "$state/$cid.assignee"
        exit 0
        ;;
      link)
        parent="${1:?}"; cid="${2:?}"
        touch "$state/$cid.parents"
        grep -qx "$parent" "$state/$cid.parents" \
          || printf '%s\n' "$parent" >> "$state/$cid.parents"
        # link_tasks demotes `WHERE status = 'ready'` only. A blocked child
        # survives being linked, which is what makes block-before-link the
        # only safe order; the `linked` event does not clear stickiness.
        if [ "$(cat "$state/$cid.status" 2>/dev/null || true)" = ready ]; then
          printf todo > "$state/$cid.status"
        fi
        exit 0
        ;;
    esac
    ;;
esac

printf 'unexpected hermes invocation: %s\n' "$*" >&2
exit 64
HERMES_STUB
    chmod +x "$root/bin/hermes"
  }

  _bootstrap_run() { # $1=fixture $2=mode [drop-parent-readback]
    local root="$1" mode="$2" drop="${3:-0}"
    (cd "$root" && STUB_STATE="$root/state" STUB_DROP_PARENTS="$drop" \
      PATH="$root/bin:$PATH" "$bootstrap" stage "$mode")
  }

  local root="$TMPROOT/bootstrap-root" out rc count
  _bootstrap_fixture "$root" normal
  out="$(_bootstrap_run "$root" --root-only 2>&1)"; rc=$?
  count="$(wc -l < "$root/state/keys.tsv" 2>/dev/null | tr -d ' ')"
  if [ "$rc" = 0 ] && [ "$count" = 1 ] \
     && grep -q $'^stage-CHUNK-1\t' "$root/state/keys.tsv" \
     && ! grep -q $'^stage-CHUNK-[23]\t' "$root/state/keys.tsv"; then
    ok "root-only-creates-one-card"
  else
    bad "root-only-creates-one-card" \
        "--root-only must create only CHUNK-1; exit $rc, cards ${count:-0}: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi

  local multi="$TMPROOT/bootstrap-multi"
  _bootstrap_fixture "$multi" multi-root
  out="$(_bootstrap_run "$multi" --root-only 2>&1)"; rc=$?
  if [ "$rc" = 1 ] && [ ! -e "$multi/state/commands.log" ] \
     && [ ! -s "$multi/state/keys.tsv" ]; then
    ok "multiple-roots-mutate-nothing"
  else
    bad "multiple-roots-mutate-nothing" \
        "a multi-root graph must exit 1 before invoking Hermes; exit $rc: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi

  local malformed="$TMPROOT/bootstrap-malformed" shape malformed_ok=1
  for shape in bad-space bad-slash bad-traversal bad-dependency; do
    _bootstrap_fixture "$malformed" "$shape"
    out="$(_bootstrap_run "$malformed" --root-only 2>&1)"; rc=$?
    if [ "$rc" != 1 ] || [ -e "$malformed/state/commands.log" ]; then
      malformed_ok=0
      break
    fi
  done
  if [ "$malformed_ok" = 1 ]; then
    ok "malformed-ids-mutate-nothing (space, slash, traversal, dependency)"
  else
    bad "malformed-ids-mutate-nothing" \
        "$shape reached Hermes or returned $rc instead of structural exit 1: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi

  local extend="$TMPROOT/bootstrap-extend" root_id child2_id child3_id staged_count final_count
  _bootstrap_fixture "$extend" normal
  out="$(_bootstrap_run "$extend" --root-only 2>&1)"; rc=$?
  staged_count="$(wc -l < "$extend/state/keys.tsv" 2>/dev/null | tr -d ' ')"
  root_id="$(awk -F '\t' '$1=="stage-CHUNK-1"{print $2}' "$extend/state/keys.tsv" 2>/dev/null)"
  out="$(_bootstrap_run "$extend" full 2>&1)"; local full_rc=$?
  final_count="$(wc -l < "$extend/state/keys.tsv" 2>/dev/null | tr -d ' ')"
  child2_id="$(awk -F '\t' '$1=="stage-CHUNK-2"{print $2}' "$extend/state/keys.tsv" 2>/dev/null)"
  child3_id="$(awk -F '\t' '$1=="stage-CHUNK-3"{print $2}' "$extend/state/keys.tsv" 2>/dev/null)"
  if [ "$rc" = 0 ] && [ "$full_rc" = 0 ] \
     && [ "$staged_count" = 1 ] && [ "$final_count" = 3 ] \
     && [ -n "$root_id" ] && [ -n "$child2_id" ] && [ -n "$child3_id" ] \
     && [ "$(cat "$extend/state/$child2_id.parents")" = "$root_id" ] \
     && [ "$(cat "$extend/state/$child3_id.parents")" = "$child2_id" ]; then
    ok "full-extends-root-idempotently"
  else
    bad "full-extends-root-idempotently" \
        "root-only then full must retain one root mapping and create both parented children; exits $rc/$full_rc, counts ${staged_count:-0}/${final_count:-0}: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi

  local interactive="$TMPROOT/bootstrap-interactive" interactive_blocks
  _bootstrap_fixture "$interactive" interactive
  out="$(_bootstrap_run "$interactive" --root-only 2>&1)"; rc=$?
  root_id="$(awk -F '\t' '$1=="stage-CHUNK-1"{print $2}' \
              "$interactive/state/keys.tsv" 2>/dev/null)"
  if [ -n "$root_id" ]; then
    printf done > "$interactive/state/$root_id.status"
    printf human-operator > "$interactive/state/$root_id.assignee"
  fi
  interactive_blocks="$(grep -c ' block ' "$interactive/state/commands.log" 2>/dev/null || true)"
  out="$(_bootstrap_run "$interactive" full 2>&1)"; full_rc=$?
  final_count="$(wc -l < "$interactive/state/keys.tsv" 2>/dev/null | tr -d ' ')"
  if [ "$rc" = 0 ] && [ "$full_rc" = 0 ] && [ "$final_count" = 3 ] \
     && [ "$(cat "$interactive/state/$root_id.status" 2>/dev/null)" = done ] \
     && [ "$(cat "$interactive/state/$root_id.assignee" 2>/dev/null)" = human-operator ] \
     && [ "$(grep -c ' block ' "$interactive/state/commands.log" 2>/dev/null || true)" = "$interactive_blocks" ]; then
    ok "completed-interactive-root-is-reused (done state and human assignee preserved)"
  else
    bad "completed-interactive-root-is-reused" \
        "full bootstrap must reuse a completed interactive root without re-blocking it; exits $rc/$full_rc, cards ${final_count:-0}: $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
  fi

  # The parentless root above is the ONE shape this bug does not take. A human
  # chunk in the middle of a graph is created while its parents are still open,
  # so the kernel hands back `todo` — never `running`, which the old code
  # `case`d on, and never `ready` either. `block` then refuses from `todo`, and
  # the fix has to create parentless, block, and attach the edges afterwards.
  local ichild="$TMPROOT/bootstrap-interactive-child" ic_rc ic_root ic_card
  _bootstrap_fixture "$ichild" interactive-child
  out="$(_bootstrap_run "$ichild" full 2>&1)"; ic_rc=$?
  ic_root="$(awk -F '\t' '$1=="stage-CHUNK-1"{print $2}' \
              "$ichild/state/keys.tsv" 2>/dev/null)"
  ic_card="$(awk -F '\t' '$1=="stage-CHUNK-2"{print $2}' \
              "$ichild/state/keys.tsv" 2>/dev/null)"
  if [ "$ic_rc" = 0 ] && [ -n "$ic_root" ] && [ -n "$ic_card" ] \
     && [ "$(cat "$ichild/state/$ic_card.status" 2>/dev/null)" = blocked ] \
     && [ -z "$(cat "$ichild/state/$ic_card.assignee" 2>/dev/null)" ] \
     && [ -f "$ichild/state/$ic_card.blocked" ] \
     && [ "$(cat "$ichild/state/$ic_card.parents" 2>/dev/null)" = "$ic_root" ]; then
    ok "parented-interactive-chunk-is-blocked-then-linked"
  else
    bad "parented-interactive-chunk-is-blocked-then-linked" \
        "an interactive chunk whose parent is not done must end blocked, unassigned, with a sticky blocked event and its parent edge; exit $ic_rc, status '$(cat "$ichild/state/$ic_card.status" 2>/dev/null)', assignee '$(cat "$ichild/state/$ic_card.assignee" 2>/dev/null)', parents '$(cat "$ichild/state/$ic_card.parents" 2>/dev/null | tr '\n' ' ')': $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi

  local scoped="$TMPROOT/bootstrap-scoped" root_rc full_bad_rc
  _bootstrap_fixture "$scoped" normal
  _bootstrap_run "$scoped" --root-only 1 >/dev/null 2>&1; root_rc=$?
  _bootstrap_run "$scoped" full 1 >/dev/null 2>&1; full_bad_rc=$?
  if [ "$root_rc" = 0 ] && [ "$full_bad_rc" = 1 ]; then
    ok "reconciliation-is-mode-scoped"
  else
    bad "reconciliation-is-mode-scoped" \
        "empty root readback must pass root-only, while missing full-mode parent readback must fail; exits $root_rc/$full_bad_rc"
  fi

  # F7's root cause, closed at the producer. The name board-bootstrap.sh
  # GENERATES is handed to the very validator that rejects it downstream, rather
  # than to a second copy of the regex written here — a third copy of one rule is
  # what this repo keeps paying for. Measured 2026-09-02: the generator emitted
  # `chunk/c10` (lowercased id, no slug at all), JobApp's C10 worker renamed the
  # branch by hand mid-chunk, and `branch-name.sh`'s own header records the
  # earlier bill for the same cause on forgeboard-report.
  local names="$TMPROOT/bootstrap-names" validator branches names_rc rejected=""
  validator="$REPO_ROOT/templates/python-service/template/scripts/branch-name.sh"
  _bootstrap_fixture "$names" branch-names
  out="$(_bootstrap_run "$names" full 2>&1)"; names_rc=$?
  branches="$(sed '/^$/d' "$names/state/branches.txt" 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    bash "$validator" "$line" >/dev/null 2>&1 || rejected="${rejected}${line} "
  done <<EOF
$branches
EOF
  local expected_branches
  expected_branches="$(printf '%s\n' \
    'chunk/7-render-report' \
    'chunk/C10-resolve-every-instance-path-from-its-own' \
    'chunk/C11-untitled' \
    'chunk/C9.1-pipeline-observability-the-run-its-cost-and')"
  if [ "$names_rc" = 0 ] && [ -z "$rejected" ] \
     && [ "$(printf '%s\n' "$branches" | sort)" = "$expected_branches" ]; then
    ok "generated-branch-names-pass-the-branch-name-rule (C10, C9.1, 7, empty slug)"
  else
    bad "generated-branch-names-pass-the-branch-name-rule" \
        "board-bootstrap.sh must emit chunk/<id>-<slug> that branch-name.sh accepts; exit $names_rc, rejected: ${rejected:-none}, got: $(printf '%s' "$branches" | tr '\n' ' ')"
  fi

  if [ "$WITH_HERMES" != 1 ]; then
    skip "real-hermes-root-and-extension" "needs --with-hermes (isolated host integration)"
  elif ! command -v hermes >/dev/null 2>&1; then
    skip "real-hermes-root-and-extension" "hermes not on PATH"
  else
    local real="$TMPROOT/bootstrap-real" real_project="$TMPROOT/bootstrap-real/project"
    local real_home="$TMPROOT/bootstrap-real/hermes-home" real_db real_root_id
    mkdir -p "$real_project/docs/chunks" "$real_home"
    git -C "$real_project" init -q
    cat > "$real_project/docs/chunks/graph.json" <<'REAL_BOOTSTRAP_GRAPH'
[
  {"id":"CHUNK-1","lane":"default","depends_on":[]},
  {"id":"CHUNK-2","lane":"default","depends_on":["CHUNK-1"]}
]
REAL_BOOTSTRAP_GRAPH
    printf '### CHUNK-1: real root\n' > "$real_project/docs/chunks/CHUNK-1.md"
    printf '### CHUNK-2: real child\n' > "$real_project/docs/chunks/CHUNK-2.md"
    out="$(cd "$real_project" && HERMES_HOME="$real_home" \
      FORGE_LANE_ASSIGNEE=default "$bootstrap" stage-real --root-only 2>&1)"; rc=$?
    real_db="$real_home/kanban/boards/stage-real/kanban.db"
    staged_count="$(sqlite3 "$real_db" 'SELECT COUNT(*) FROM tasks;' 2>/dev/null || true)"
    real_root_id="$(sqlite3 "$real_db" \
      "SELECT id FROM tasks WHERE idempotency_key='stage-real-CHUNK-1';" 2>/dev/null)"
    out="$(cd "$real_project" && HERMES_HOME="$real_home" \
      FORGE_LANE_ASSIGNEE=default "$bootstrap" stage-real 2>&1)"; full_rc=$?
    final_count="$(sqlite3 "$real_db" 'SELECT COUNT(*) FROM tasks;' 2>/dev/null || true)"
    root_id="$(sqlite3 "$real_db" \
      "SELECT id FROM tasks WHERE idempotency_key='stage-real-CHUNK-1';" 2>/dev/null)"
    child2_id="$(sqlite3 "$real_db" \
      "SELECT id FROM tasks WHERE idempotency_key='stage-real-CHUNK-2';" 2>/dev/null)"
    if [ "$rc" = 0 ] && [ "$full_rc" = 0 ] \
       && [ "$staged_count" = 1 ] && [ "$final_count" = 2 ] \
       && [ -n "$real_root_id" ] && [ "$root_id" = "$real_root_id" ] \
       && [ "$(sqlite3 "$real_db" \
              "SELECT COUNT(*) FROM task_links WHERE parent_id='$root_id' AND child_id='$child2_id';" 2>/dev/null)" = 1 ]; then
      ok "real-hermes-root-and-extension (isolated board: 1 root -> 2 cards, 1 edge)"
    else
      bad "real-hermes-root-and-extension" \
          "actual Hermes did not preserve the staged root and atomic edge; exits $rc/$full_rc, cards ${staged_count:-?}/${final_count:-?}: $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
    fi
  fi
}
wants bootstrap && run_bootstrap_group

# ---------------------------------------------------------------------------
# commission/ — CHUNK-9's paid launch wrapper, driven entirely through stubs.
# The one real paid probe is an operator action recorded in docs/state.md; the
# default suite proves the wrapper's sequencing, evidence and refusal paths.
# ---------------------------------------------------------------------------
run_commission_group() {
  group commission
  local commission="$REPO_ROOT/scripts/commission.sh"
  local cases='records-all-prerequisites propagates-prerequisite-failure preserves-roadmap-warn requires-enforceable-gate binds-github-to-origin report-publication-failure-is-fatal leaves-project-and-board-unchanged'
  local case_name

  if [ ! -x "$commission" ] || ! grep -q '^commission:' "$REPO_ROOT/Makefile"; then
    for case_name in $cases; do
      bad "$case_name" "scripts/commission.sh and the make commission target do not exist yet"
    done
    return
  fi

  local root="$LABROOT/commission" product="$LABROOT/commission/product"
  local state="$LABROOT/commission/state" real_make real_mv report rc before after out
  real_make="$(command -v make)"
  real_mv="$(command -v mv)"
  rm -rf "$root"
  mkdir -p "$product" "$root/bin" "$state" "$root/hermes"
  git -C "$product" init -q -b main
  printf '.forge/\n' > "$product/.gitignore"
  printf 'fixture\n' > "$product/README.md"
  git -C "$product" add .gitignore README.md
  git -C "$product" -c user.name=Forge -c user.email=forge@example.invalid \
    commit -q -m fixture
  git -C "$product" remote add origin git@github.com:acme/product.git

  cat > "$root/bin/make" <<'COMMISSION_MAKE_STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${CALLS:?}"
case "$*" in
  'verify WITH_CODEX=1')
    printf 'paid probe: recorded\n'
    ;;
  preflight)
    printf 'preflight: checked\n'
    [ "${MAKE_FAIL:-}" != preflight ] || exit 7
    ;;
  roadmap-check*)
    if [ "${ROADMAP_WARN:-0}" = 1 ]; then
      printf 'WARN CHUNK-99 is advisory-sized\n'
    else
      printf 'roadmap-check: no warnings\n'
    fi
    ;;
  *) printf 'unexpected make invocation: %s\n' "$*" >&2; exit 64;;
esac
COMMISSION_MAKE_STUB

  cat > "$root/bin/gh" <<'COMMISSION_GH_STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${GH_CALLS:?}"
case "$*" in
  repo\ view\ *\ --json\ nameWithOwner,defaultBranchRef)
    printf '{"nameWithOwner":"%s","defaultBranchRef":{"name":"main"}}\n' "${GH_VIEW_SLUG:-acme/product}"
    ;;
  'api repos/acme/product')
    # `unavailable` is the private free-plan shape: GitHub answers the repo
    # query, says it is private, and then refuses BOTH protection mechanisms
    # with its paid-feature sentence (ADR-0017).
    if [ "${GH_GATE:-classic}" = unavailable ]; then
      printf '%s\n' '{"default_branch":"main","private":true}'
    else
      printf '%s\n' '{"default_branch":"main"}'
    fi
    ;;
  'api --paginate repos/acme/product/rulesets')
    [ "${GH_GATE:-classic}" != unavailable ] || {
      echo 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)' >&2
      exit 1
    }
    printf '%s\n' '[]'
    ;;
  'api repos/acme/product/branches/main/protection')
    [ "${GH_GATE:-classic}" != unavailable ] || {
      echo 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)' >&2
      exit 1
    }
    [ "${GH_GATE:-classic}" != none ] || exit 1
    printf '%s\n' '{"required_pull_request_reviews":{},"required_status_checks":{"contexts":["check"]}}'
    ;;
  *) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 64;;
esac
COMMISSION_GH_STUB

  cat > "$root/bin/mv" <<'COMMISSION_MV_STUB'
#!/usr/bin/env bash
set -u
if [ "${MV_FAIL:-0}" = 1 ]; then
  echo 'injected report publication failure' >&2
  exit 73
fi
exec "${REAL_MV:?}" "$@"
COMMISSION_MV_STUB

  cat > "$root/bin/hermes" <<'COMMISSION_HERMES_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERMES_CALLS:?}"
exit 65
COMMISSION_HERMES_STUB
  chmod +x "$root/bin/make" "$root/bin/gh" "$root/bin/hermes" "$root/bin/mv"

  _commission_run() { # $1=make failure $2=roadmap warn $3=gate shape $4=mv failure
                     # $5=view slug $6=REQUIRE_GATE (empty = the default posture)
    rm -rf "$product/.forge"
    : > "$state/make-calls"
    : > "$state/gh-calls"
    : > "$state/hermes-calls"
    MAKE_FAIL="$1" ROADMAP_WARN="$2" GH_GATE="$3" MV_FAIL="$4" \
      REQUIRE_GATE="${6:-}" \
      GH_VIEW_SLUG="$5" REAL_MV="$real_mv" CALLS="$state/make-calls" \
      GH_CALLS="$state/gh-calls" HERMES_CALLS="$state/hermes-calls" \
      HERMES_HOME="$root/hermes" PATH="$root/bin:$PATH" \
      "$real_make" --no-print-directory commission PROJECT="$product" BOARD=commission-fixture \
      > "$state/run.out" 2>&1
    rc=$?
    report="$(find "$product/.forge" -maxdepth 1 -type f -name 'commission-*.md' -print 2>/dev/null | head -1)"
    out="$(cat "$state/run.out")"
  }

  _commission_run '' 0 classic 0 acme/product
  if [ "$rc" = 0 ] && [ -n "$report" ] \
     && grep -Fq '## paid-codex-probe' "$report" \
     && grep -Fq '## preflight' "$report" \
     && grep -Fq '## roadmap-check' "$report" \
     && grep -Fq '## durable-path' "$report" \
     && grep -Fq '## clean-tree-before' "$report" \
     && grep -Fq '## remote-resolution' "$report" \
     && grep -Fq '## merge-gate' "$report" \
     && grep -Fxq 'verify WITH_CODEX=1' "$state/make-calls" \
     && grep -Fxq 'preflight' "$state/make-calls" \
     && grep -Fq "roadmap-check PROJECT=$product" "$state/make-calls"; then
    ok "records-all-prerequisites"
  else
    bad "records-all-prerequisites" "commissioning must record every named gate; exit $rc: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi

  _commission_run preflight 0 classic 0 acme/product
  if [ "$rc" != 0 ] && [ -n "$report" ] \
     && grep -A2 '^## preflight$' "$report" | grep -Fq 'exit: 7' \
     && grep -Fq 'overall: FAIL' "$report"; then
    ok "propagates-prerequisite-failure"
  else
    bad "propagates-prerequisite-failure" "preflight exit 7 must name the failing section and fail commissioning; exit $rc"
  fi

  _commission_run '' 1 classic 0 acme/product
  if [ "$rc" = 0 ] && [ -n "$report" ] \
     && grep -Fq 'WARN CHUNK-99 is advisory-sized' "$report"; then
    ok "preserves-roadmap-warn"
  else
    bad "preserves-roadmap-warn" "roadmap advisory output must survive verbatim; exit $rc"
  fi

  _commission_run '' 0 none 0 acme/product
  if [ "$rc" != 0 ] && [ -n "$report" ] \
     && grep -A8 '^## merge-gate$' "$report" | grep -Fq 'NONE via=none'; then
    ok "requires-enforceable-gate"
  else
    bad "requires-enforceable-gate" "a repository with no enforceable gate must be refused regardless of visibility; exit $rc"
  fi

  # --- ADR-0017: a product GitHub cannot gate ------------------------------
  # Branch protection is a paid feature, so on a private free-plan repository
  # GitHub answers that no server-side gate can exist. Treating that answer as a
  # control that failed to run refused every private product outright (F120).
  # It commissions — and the report has to SAY the product is ungated, because a
  # bare `overall: PASS` beside an unreadable gate is the claim ADR-0003 forbids.
  # The section is extracted by its own boundaries rather than by a fixed -AN
  # window: the diagnostic under this heading is longer than any other, and a
  # line-count anchor is the shape that goes blind the first time text grows.
  _commission_gate_section() {
    awk '/^## merge-gate$/ { p = 1; next } p && /^## / { exit } p' "$1"
  }
  _commission_run '' 0 unavailable 0 acme/product
  if [ "$rc" = 0 ] && [ -n "$report" ] \
     && _commission_gate_section "$report" | grep -Fq 'exit: 5' \
     && _commission_gate_section "$report" | grep -Fq 'UNAVAILABLE via=none' \
     && grep -Fq 'overall: PASS' "$report" \
     && grep -Fq 'posture: UNGATED (merge gate unavailable on this plan: acme/product)' "$report"; then
    ok "an-ungatable-product-commissions"
  else
    bad "an-ungatable-product-commissions" \
        "a product GitHub cannot gate must commission and be recorded UNGATED with its real exit 5; exit $rc: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi

  # The posture line is not decoration on the unavailable path — it is emitted
  # on EVERY path, from the gate's own exit and nothing else. A gated product
  # states its posture too, so the line cannot quietly vanish and leave the
  # ungated case looking like every other report.
  _commission_run '' 0 classic 0 acme/product
  if [ "$rc" = 0 ] && [ -n "$report" ] \
     && grep -Fq 'posture: GATED (acme/product main)' "$report"; then
    ok "every-report-states-its-posture"
  else
    bad "every-report-states-its-posture" \
        "every commissioning report must state the posture the merge gate established; exit $rc, posture='$(grep -F 'posture:' "$report" 2>/dev/null)'"
  fi

  # The strict posture is still available for a repository you DO expect to be
  # gated. Only `1` acts; the guard refusing any other value is asserted below.
  _commission_run '' 0 unavailable 0 acme/product 1
  if [ "$rc" != 0 ] && [ -n "$report" ] \
     && grep -Fq 'overall: FAIL' "$report" \
     && grep -Fq 'posture: UNGATED' "$report"; then
    ok "require-gate-restores-the-refusal"
  else
    bad "require-gate-restores-the-refusal" \
        "REQUIRE_GATE=1 must refuse a product GitHub cannot gate; exit $rc"
  fi

  # REQUIRE_GATE=true reads as "yes, require it" and would silently do the
  # opposite. Refused rather than reinterpreted — the root Makefile's APPLY bug.
  _commission_run '' 0 unavailable 0 acme/product true
  if [ "$rc" != 0 ] && [ -z "$report" ] \
     && grep -Fq "REQUIRE_GATE='true' is not understood" "$state/run.out"; then
    ok "an-unrecognised-require-gate-is-refused"
  else
    bad "an-unrecognised-require-gate-is-refused" \
        "an unrecognised REQUIRE_GATE must be refused, never read as the lenient default; exit $rc"
  fi

  git -C "$product" remote set-url origin git@github.com:other/product.git
  _commission_run '' 0 classic 0 acme/product
  if [ "$rc" != 0 ] && [ -n "$report" ] \
     && grep -A8 '^## remote-resolution$' "$report" | grep -Fq 'origin repository mismatch: expected other/product, GitHub returned acme/product' \
     && grep -Fxq 'repo view other/product --json nameWithOwner,defaultBranchRef' "$state/gh-calls" \
     && grep -Fq 'overall: FAIL' "$report"; then
    ok "binds-github-to-origin"
  else
    bad "binds-github-to-origin" "a mismatched ambient GitHub repository must not satisfy the origin-bound check; exit $rc"
  fi
  git -C "$product" remote set-url origin git@github.com:acme/product.git

  _commission_run '' 0 classic 1 acme/product
  if [ "$rc" != 0 ] && [ -z "$report" ] \
     && grep -Fq 'commission: could not publish evidence report' "$state/run.out"; then
    ok "report-publication-failure-is-fatal"
  else
    bad "report-publication-failure-is-fatal" "an unpublished report must fail commissioning and leave no final PASS artifact; exit $rc, report='${report:-}'"
  fi

  before="$(git -C "$product" status --porcelain)"
  _commission_run '' 0 classic 0 acme/product
  after="$(git -C "$product" status --porcelain)"
  if [ "$rc" = 0 ] && [ "$before" = "$after" ] && [ -z "$after" ] \
     && [ ! -s "$state/hermes-calls" ] \
     && [ ! -e "$root/hermes/kanban.db" ] \
     && git -C "$product" check-ignore -q .forge/commission-probe \
     && grep -Fq 'before: ABSENT' "$report" \
     && grep -Fq 'after: ABSENT' "$report"; then
    ok "leaves-project-and-board-unchanged"
  else
    bad "leaves-project-and-board-unchanged" "only ignored evidence may change; project status='$after', Hermes calls=$(wc -l < "$state/hermes-calls" | tr -d ' ')"
  fi
}
wants commission && run_commission_group

# ---------------------------------------------------------------------------
# metrics/ — the flywheel's own numbers (F27). Before scripts/metrics.sh, /retro
# asked a language model to derive them from printed board output, and the
# published bounce rate read 0.00 on a run with 12 bounces. A number that is
# computed can be tested; that is the entire argument, so it is tested here.
#
# The fixture is SQL, not a .db: a binary blob in git is a number nobody can
# review. It is rebuilt into a temp board on every run and reached through
# HERMES_KANBAN_HOME, which exercises the real path-resolution code rather than
# a test-only escape hatch.
# ---------------------------------------------------------------------------
db_source_fingerprint() { # $1=kanban.db; membership + bytes of SQLite's source set
  local source="$1" file suffix
  for suffix in "" -wal -shm -journal; do
    file="$source$suffix"
    if [ -e "$file" ]; then
      printf '%s %s\n' "${file##*/}" "$(shasum -a 256 "$file" | cut -d' ' -f1)"
    else
      printf '%s absent\n' "${file##*/}"
    fi
  done
}

live_schema_report() { # $1=boards root $2=snapshot root; TSV board/status/detail
  local boards_root="$1" snapshot_root="$2"
  local live board snapdir snapdb err missing spec t c ordinal=0
  mkdir -p "$snapshot_root" 2>/dev/null || return 2

  while IFS= read -r live; do
    [ -n "$live" ] || continue
    ordinal=$((ordinal+1))
    board="$(basename "$(dirname "$live")")"
    snapdir="$snapshot_root/$ordinal"
    err="$snapshot_root/$ordinal.err"
    rm -rf "$snapdir" "$err"
    if ! snapdb="$(scripts/board-snapshot.sh "$live" "$snapdir" 2>"$err")" \
       || [ -z "$snapdb" ]; then
      printf '%s\tunreadable\t%s\n' "$board" \
        "$(tr '\t\n' '  ' < "$err" | sed 's/[[:space:]]*$//')"
      continue
    fi

    missing=""
    for spec in "tasks:id,status" "task_runs:task_id,profile,outcome,started_at,metadata" \
                "task_events:kind,payload,created_at" "task_comments:author,created_at" \
                "task_links:parent_id,child_id"; do
      t="${spec%%:*}"
      for c in $(printf '%s' "${spec#*:}" | tr ',' ' '); do
        sqlite3 "$snapdb" "SELECT $c FROM $t LIMIT 0;" >/dev/null 2>&1 \
          || missing="$missing $t.$c"
      done
    done
    if [ -z "$missing" ]; then
      printf '%s\tpass\t\n' "$board"
    else
      printf '%s\tmissing\t%s\n' "$board" "$missing"
    fi
  done < <(find "$boards_root" -mindepth 2 -maxdepth 2 -type f -name kanban.db \
             -print 2>/dev/null | LC_ALL=C sort)
}

run_metrics_group() {
  group metrics
  local ms=scripts/metrics.sh fx=scripts/fixtures/metrics-board.sql
  local exp=scripts/fixtures/metrics-expected.json

  for tool in sqlite3 jq; do
    command -v "$tool" >/dev/null 2>&1 || { skip "fixture-numbers-exact" "$tool not on PATH"; return; }
  done

  # --help must work with no board, no database and no arguments: it is the
  # first thing anyone runs, including CI on a host with no ~/.hermes at all.
  if HOME="$TMPROOT/nohome" "$ms" --help >/dev/null 2>&1; then
    ok "help-exits-zero"
  else
    bad "help-exits-zero" "$ms --help did not exit 0 without a board"
  fi

  local hermes_root="$TMPROOT/hermes" home="$TMPROOT/hermes/kanban"
  local db="$home/boards/metrics-fixture/kanban.db"
  local profile_db="$hermes_root/profiles/forge-codex-lane/state.db"
  mkdir -p "$(dirname "$db")"
  # stdout is discarded: the fixture's `PRAGMA journal_mode=wal` echoes its
  # result, and that is fixture noise, not a case result.
  if ! sqlite3 "$db" < "$fx" >/dev/null 2>"$TMPROOT/fixture.log"; then
    bad "fixture-numbers-exact" "fixture would not load: $(tail -2 "$TMPROOT/fixture.log" | tr '\n' ' ')"
    return
  fi

  # A separate profile state fixture is essential: worker_session_id joins two
  # independent SQLite substrates in production. Session totals deliberately
  # differ from either model row, and actual_cost_usd is the schema's misleading
  # zero in the per-model table while cost_status remains estimated. The output
  # must use the sessions row for totals, preserve both breakdown rows, and turn
  # that storage default back into an honest missing actual cost.
  mkdir -p "$(dirname "$profile_db")"
  sqlite3 "$profile_db" <<'METRICS_STATE_SQL'
CREATE TABLE sessions (
  id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT,
  billing_provider TEXT, api_call_count INTEGER DEFAULT 0,
  input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
  cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
  reasoning_tokens INTEGER DEFAULT 0, estimated_cost_usd REAL,
  actual_cost_usd REAL, cost_status TEXT, cost_source TEXT
);
CREATE TABLE session_model_usage (
  session_id TEXT NOT NULL, model TEXT NOT NULL,
  billing_provider TEXT NOT NULL DEFAULT '', billing_base_url TEXT NOT NULL DEFAULT '',
  billing_mode TEXT NOT NULL DEFAULT '', task TEXT NOT NULL DEFAULT '',
  api_call_count INTEGER NOT NULL DEFAULT 0, input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
  cache_write_tokens INTEGER NOT NULL DEFAULT 0, reasoning_tokens INTEGER NOT NULL DEFAULT 0,
  estimated_cost_usd REAL NOT NULL DEFAULT 0, actual_cost_usd REAL NOT NULL DEFAULT 0,
  cost_status TEXT, cost_source TEXT, first_seen REAL, last_seen REAL
);
INSERT INTO sessions VALUES
  ('session-exact','kanban','deepseek-v4-flash','openrouter',7,
   1000,200,800,50,70,1.25,NULL,'estimated','openrouter-model-pricing');
INSERT INTO session_model_usage VALUES
  ('session-exact','deepseek-v4-flash','openrouter','https://openrouter.example/api/v1',
   'api','driver',5,900,150,700,40,60,0.75,0,'estimated',
   'openrouter-model-pricing',1785200011.0,1785200090.0),
  ('session-exact','routing-helper','openrouter','https://openrouter.example/api/v1',
   'api','routing',2,100,50,100,10,10,0.50,0,'estimated',
   'openrouter-model-pricing',1785200010.0,1785200011.0);
METRICS_STATE_SQL

  # Changing only sidecar membership must change the same fingerprint used by
  # the end-to-end read-only assertion below. The main database remains byte
  # identical throughout this mutation.
  local fp_lab="$TMPROOT/source-fingerprint" fp_db fp_before fp_after
  mkdir -p "$fp_lab"
  fp_db="$fp_lab/kanban.db"
  printf 'unchanged database bytes\n' > "$fp_db"
  fp_before="$(db_source_fingerprint "$fp_db" 2>/dev/null)"
  : > "$fp_db-wal"
  fp_after="$(db_source_fingerprint "$fp_db" 2>/dev/null)"
  if [ -n "$fp_before" ] && [ -n "$fp_after" ] && [ "$fp_before" != "$fp_after" ]; then
    ok "read-only-fingerprint-includes-sidecars"
  else
    bad "read-only-fingerprint-includes-sidecars" \
        "adding kanban.db-wal did not change the source-set fingerprint while kanban.db stayed unchanged"
  fi

  # The live-board policy is every kanban.db below the board root, in bytewise
  # path order. Both deliberately unreadable probes must still be named: a
  # failed check is evidence about that board, not permission to omit it.
  local selection_root="$TMPROOT/live-selection/boards" selection_report selection_names
  local selection_blocker="$TMPROOT/live-selection/not-a-directory" selection_workspace_rc
  mkdir -p "$selection_root/z-board" "$selection_root/a-board"
  printf 'not sqlite\n' > "$selection_root/z-board/kanban.db"
  printf 'not sqlite\n' > "$selection_root/a-board/kanban.db"
  selection_report="$(live_schema_report "$selection_root" "$TMPROOT/live-selection/snapshots" 2>/dev/null)"
  selection_names="$(printf '%s\n' "$selection_report" | awk -F '\t' 'NF { print $1 }')"
  printf 'block snapshot creation\n' > "$selection_blocker"
  live_schema_report "$selection_root" "$selection_blocker/child" >/dev/null 2>&1
  selection_workspace_rc=$?
  if [ "$selection_names" = "$(printf 'a-board\nz-board')" ] \
     && [ "$(printf '%s\n' "$selection_report" | awk -F '\t' '$2=="unreadable"{n++} END{print n+0}')" = 2 ] \
     && [ "$selection_workspace_rc" != 0 ]; then
    ok "live-schema-selection-is-complete-and-deterministic"
  else
    bad "live-schema-selection-is-complete-and-deterministic" \
        "expected both boards in deterministic order; got: ${selection_names:-no named boards}"
  fi

  # Exact, whole-document diff. Asserting a handful of fields would let a new
  # bucket appear, or an old one silently vanish, without failing anything.
  HERMES_HOME="$hermes_root" HERMES_KANBAN_HOME="$home" \
    "$ms" metrics-fixture --json > "$TMPROOT/metrics.json" 2>&1
  if diff -u "$exp" "$TMPROOT/metrics.json" > "$TMPROOT/metrics.diff" 2>&1; then
    ok "fixture-numbers-exact ($(jq -r '.verdicts.total' "$exp") verdicts, every field)"
  else
    bad "fixture-numbers-exact" "$(head -12 "$TMPROOT/metrics.diff" | tr '\n' ' ')"
  fi

  local driver_exact driver_shared driver_missing driver_profile driver_cost
  driver_exact="$(jq -c '[.driver_usage.sessions[0]
                          | .model, .provider, .api_calls, .input_tokens,
                            .output_tokens, .cache_read_tokens,
                            .cache_write_tokens, .reasoning_tokens,
                            .cost_status, (.models | length)]' \
                    "$TMPROOT/metrics.json" 2>/dev/null)"
  if [ "$driver_exact" = '["deepseek-v4-flash","openrouter",7,1000,200,800,50,70,"estimated",2]' ]; then
    ok "driver-usage-joins-exact-session"
  else
    bad "driver-usage-joins-exact-session" \
        "expected exact session totals and both model rows, got ${driver_exact:-nothing}"
  fi

  driver_shared="$(jq -c '[.driver_usage.coverage.eligible,
                            .driver_usage.coverage.joined,
                            (.driver_usage.sessions | length),
                            .driver_usage.sessions[0].runs,
                            .driver_usage.totals.api_calls,
                            .driver_usage.cost.estimated_usd,
                            .driver_usage.shared_attribution[0].run_ids]' \
                      "$TMPROOT/metrics.json" 2>/dev/null)"
  if [ "$driver_shared" = '[4,2,1,[{"run_id":1,"task_id":"t_c1"},{"run_id":2,"task_id":"t_c1"}],7,1.25,[1,2]]' ]; then
    ok "driver-usage-shared-session-counts-once (2 runs, 1 session, 1 charge)"
  else
    bad "driver-usage-shared-session-counts-once" \
        "shared profile/session mappings must preserve both runs and charge telemetry once; got ${driver_shared:-nothing}"
  fi

  driver_missing="$(jq -c '[.driver_usage.coverage.unjudged,
                            ([.driver_usage.unjudged[]
                              | select(.reason == "missing-worker-session-id")
                              | .task_id] | first)]' \
                      "$TMPROOT/metrics.json" 2>/dev/null)"
  if [ "$driver_missing" = '[2,"t_c3"]' ]; then
    ok "driver-usage-missing-id-is-unjudged"
  else
    bad "driver-usage-missing-id-is-unjudged" \
        "a missing worker_session_id must be unjudged, not zero usage; got ${driver_missing:-nothing}"
  fi

  driver_profile="$(jq -c '[.verdicts.total,
                            (.driver_usage.limitations
                              | index("profile state unavailable: forge-missing-driver")),
                            ([.driver_usage.unjudged[]
                              | select(.reason == "profile-state-unavailable")
                              | .task_id] | first)]' \
                      "$TMPROOT/metrics.json" 2>/dev/null)"
  if [ "$driver_profile" = '[6,0,"t_c2"]' ]; then
    ok "driver-usage-missing-profile-is-explicit"
  else
    bad "driver-usage-missing-profile-is-explicit" \
        "base metrics must survive and name the unavailable profile state; got ${driver_profile:-nothing}"
  fi

  driver_cost="$(jq -c '[.driver_usage.cost.estimated_usd,
                         .driver_usage.cost.actual_usd,
                         .driver_usage.sessions[0].actual_cost_usd,
                         [.driver_usage.sessions[0].models[].actual_cost_usd]]' \
                   "$TMPROOT/metrics.json" 2>/dev/null)"
  if [ "$driver_cost" = '[1.25,null,null,[null,null]]' ]; then
    ok "driver-usage-estimate-keeps-actual-absent"
  else
    bad "driver-usage-estimate-keeps-actual-absent" \
        "estimated cost must stay labelled and actual cost absent, including per-model storage defaults; got ${driver_cost:-nothing}"
  fi

  local markdown_header markdown_row header_cells row_cells row_operator row_driver
  markdown_header="$(awk '/^\| Retro date \| Period \|/{print; exit}' docs/retro-metrics.md)"
  markdown_row="$(HERMES_HOME="$hermes_root" HERMES_KANBAN_HOME="$home" \
                    "$ms" metrics-fixture --markdown-row 2>/dev/null)"
  header_cells="$(printf '%s\n' "$markdown_header" | awk -F '|' '{print NF-2}')"
  row_cells="$(printf '%s\n' "$markdown_row" | awk -F '|' '{print NF-2}')"
  row_operator="$(printf '%s\n' "$markdown_row" | awk -F '|' '{gsub(/^ +| +$/, "", $7); print $7}')"
  row_driver="$(printf '%s\n' "$markdown_row" | awk -F '|' '{gsub(/^ +| +$/, "", $8); print $8}')"
  if [ "$header_cells" = 9 ] && [ "$row_cells" = 9 ] \
     && [ "$row_operator" = 4 ] \
     && [ "$row_driver" = 'driver 0.50 (2/4) · estimated $1.25 · actual n/a' ]; then
    ok "markdown-row-has-operator-and-driver-cells"
  else
    bad "markdown-row-has-operator-and-driver-cells" \
        "expected matching 9-cell header/row with operator and driver cells; got header=$header_cells row=$row_cells operator='${row_operator:-}' driver='${row_driver:-}'"
  fi

  # The lane writes chunk metadata NESTED under a key named for the schema,
  # while the documented shape is flat with an inner "schema" field (F1). This
  # slice must REPORT that divergence, never repair it — and the card carrying
  # the malformed envelope must stay in the denominator, or the conformance
  # count would be blind to exactly the fault it exists to find.
  local e
  e="$(jq -c '[.envelope.flat,.envelope.nested,.envelope.neither,.envelope.total,.chunk_cards]' \
        "$TMPROOT/metrics.json" 2>/dev/null)"
  if [ "$e" = "[2,1,1,4,3]" ]; then
    ok "detects-noncanonical-envelope (2 flat runs, 1 nested, 1 neither, none normalized away)"
  else
    bad "detects-noncanonical-envelope" \
        "expected [flat,nested,neither,total,chunk_cards]=[2,1,1,4,3], got ${e:-nothing} — a nonconforming envelope was normalized or dropped from the denominator"
  fi

  # ADR-0009 D9.4. A gate block and a bounce are different events and must stay
  # different numbers. The fixture holds one blocking and one clearing gate run
  # alongside tier-1 and tier-2 verdicts, so this fails if the gate results are
  # ever folded into the bounce rate — or if they stop being counted at all,
  # which is the quieter way to lose them. The tier-2 bounce count is asserted in
  # the same expression precisely so that folding one into the other cannot pass.
  local gate_row
  gate_row="$(jq -c '[.gate.runs, .gate.blocked, .gate.block_rate,
                      (.gate.by_check | keys | length),
                      ([.tiers[] | select(.tier == 2) | .bounce_verdicts] | first)]' \
                "$TMPROOT/metrics.json" 2>/dev/null)"
  if [ "$gate_row" = '[2,1,"0.50",2,3]' ]; then
    ok "gate-blocks-are-not-bounces (1 of 2 gate runs blocked, 3 tier-2 bounces, counted apart)"
  else
    bad "gate-blocks-are-not-bounces" \
        "expected [runs,blocked,rate,checks,t2_bounces]=[2,1,\"0.50\",2,3], got ${gate_row:-nothing} — forge.gate.v1 results must be counted separately from forge.judge.v1 bounces"
  fi

  # F47. A board AT REST — WAL checkpointed away, no `-shm`, no `-wal`, nobody
  # holding it open — is the state a board is in when someone sits down to run
  # /retro, and it is the one state `mode=ro` could not read: a read-only
  # connection cannot create the `-shm` that WAL requires. The fixture above
  # does not reach it, because loading the fixture leaves the sidecars warm.
  # This case builds the quiescent condition explicitly: it copies the database
  # alone, without sidecars, to a directory nothing has ever opened.
  #
  # Both halves are asserted. The old failure printed sqlite3's error on STDOUT,
  # satisfied a `[ -n "$JSON" ]` guard with the error text, and EXITED 0 — so a
  # case that checked only the exit code would have passed on the bug.
  local qhome="$TMPROOT/quiescent" qdb
  qdb="$qhome/boards/metrics-fixture/kanban.db"
  mkdir -p "$(dirname "$qdb")"
  cp "$db" "$qdb"
  # Checkpoint first, then delete the sidecars: a WAL board that is closed
  # cleanly folds its WAL into the main file and leaves nothing beside it.
  # Deleting an un-checkpointed `-wal` would discard committed rows and test a
  # corrupt board instead of a resting one.
  sqlite3 "$qdb" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
  rm -f "$qdb-wal" "$qdb-shm" "$qdb-journal"
  if HERMES_HOME="$hermes_root" HERMES_KANBAN_HOME="$qhome" \
     "$ms" metrics-fixture --json > "$TMPROOT/quiescent.json" 2>&1 \
     && jq -e '.verdicts.total' "$TMPROOT/quiescent.json" >/dev/null 2>&1; then
    ok "reads-a-quiescent-board (no -wal, no -shm, nothing holding it open)"
  else
    bad "reads-a-quiescent-board" \
        "a board at rest could not be read — the state every /retro finds it in: $(head -2 "$TMPROOT/quiescent.json" | tr '\n' ' ')"
  fi

  # A live board and profile state are production data for the whole flywheel.
  # The script snapshots both and reads the copies; this proves the originals'
  # bytes, because "read-only" is a claim in a comment and claims in comments
  # are what this suite is for.
  local before after
  before="$(db_source_fingerprint "$db"; db_source_fingerprint "$profile_db")"
  HERMES_HOME="$hermes_root" HERMES_KANBAN_HOME="$home" \
    "$ms" metrics-fixture >/dev/null 2>&1
  HERMES_HOME="$hermes_root" HERMES_KANBAN_HOME="$home" \
    "$ms" metrics-fixture --since 2026-07-28 --markdown-row >/dev/null 2>&1
  after="$(db_source_fingerprint "$db"; db_source_fingerprint "$profile_db")"
  if [ "$before" = "$after" ]; then
    ok "is-read-only (board/profile dbs and all sidecars unchanged across two invocations)"
  else
    bad "is-read-only" \
        "the database source set changed while being read. before: $(printf '%s' "$before" | tr '\n' ' ') after: $(printf '%s' "$after" | tr '\n' ' ')"
  fi

  # The fixture declares a schema by hand, so it can drift away from the real
  # one and keep passing. Read the columns metrics.sh depends on off a live
  # board instead of asserting in a comment that they are the same.
  #
  # SNAPSHOT FIRST; NEVER OPEN THE LIVE FILE. Every hermes board is WAL, and a
  # `mode=ro` connection to a WAL database cannot create the `-shm` file it
  # needs. SQLite deletes `-shm` and `-wal` when the last connection closes, so
  # the read-only open this check used to do fails — sqlite error 14, "unable
  # to open database file" — in exactly the windows when the dispatch gateway
  # is IDLE. That is the reverse of what the audit first recorded (F67): a
  # concurrent writer provably does not disturb the read at all, and the two
  # obvious fixes both make it worse. Retrying fails 5 times out of 5 because
  # nothing about the retry recreates `-shm`, and waiting for quiescence waits
  # for the very condition that causes it.
  #
  # THE COPY IS NO LONGER MADE HERE. scripts/board-snapshot.sh is the one
  # implementation, shared with metrics.sh: `cp` only reads, so the live board
  # is never opened, locked or mutated by the suite, and the copy is opened
  # read-write, which is what lets SQLite build the `-shm` the original could
  # not be given. This check carrying its own copy of that logic while
  # metrics.sh carried another is what F67 cost a finding to discover.
  #
  # A read failure and a schema change are different findings and must not
  # share a message. The primitive proves the snapshot opens (`SELECT 1` needs
  # no table and no column) before it returns a path, so every column failure
  # below is unambiguously about the column.
  local boards_root live_report live_report_rc board status detail
  boards_root="${HERMES_KANBAN_HOME:-${HERMES_HOME:-$HOME/.hermes}/kanban}/boards"
  rm -rf "$TMPROOT/live-schema"
  live_report="$(live_schema_report "$boards_root" "$TMPROOT/live-schema")"
  live_report_rc=$?
  if [ "$live_report_rc" != 0 ]; then
    bad "live-schema-has-fixture-columns" \
        "could not create the private snapshot workspace; no live board was checked (exit $live_report_rc)"
  elif [ -z "$live_report" ]; then
    skip "live-schema-has-fixture-columns" "no live board to compare against"
  else
    while IFS=$'\t' read -r board status detail; do
      case "$status" in
        pass)
          ok "live-schema-has-fixture-columns ($board)";;
        unreadable)
          bad "live-schema-has-fixture-columns ($board)" \
              "could not read a snapshot of board '$board' — the board was unreadable, which is not a schema change; the fixture is unverified this run, not disproven: $detail";;
        missing)
          bad "live-schema-has-fixture-columns ($board)" \
              "live board '$board' no longer has:$detail — the fixture is testing a schema that no longer exists";;
        *)
          bad "live-schema-has-fixture-columns ($board)" \
              "live schema inspection returned unknown status '${status:-empty}'";;
      esac
    done <<< "$live_report"
  fi

  # F67 as a regression, offline and on a board this suite builds itself. The
  # flake was invisible to every previous run of the case above, because it
  # only appears when `-shm` is absent and a live board usually has one; the
  # bug reproduces on demand only if the test removes it deliberately.
  #
  # F47 IS THE SAME DEFECT, FOUND EARLIER AND NEVER CARRIED ACROSS — see
  # `metrics/reads-a-quiescent-board` above, which has asserted since F47 that
  # a board with no WAL sidecars stays readable. That fix landed on metrics.sh
  # and stopped there, while the check 40 lines below it went on opening a live
  # board `mode=ro`. Third time this pattern has cost a finding (F43 -> F66,
  # F65, now F47 -> F67): when a check is fixed, grep for its siblings.
  local wal="$TMPROOT/walcheck"
  rm -rf "$wal" && mkdir -p "$wal"
  sqlite3 "$wal/kanban.db" \
    "PRAGMA journal_mode=WAL; CREATE TABLE tasks(id TEXT, status TEXT);" >/dev/null 2>&1
  rm -f "$wal/kanban.db-shm" "$wal/kanban.db-wal"   # what SQLite does on last close
  #
  # This is the THIRD copy of the pattern, and it survived the slice that exists
  # to unify it: `live-schema-has-fixture-columns` above was converted to call
  # the primitive and this one was not, so it went on proving that a hand-rolled
  # `cp` survives an idle board — which is not the claim. It is routed through
  # scripts/board-snapshot.sh here, which is also what gives
  # `snapshot/no-second-implementation` a real second caller to hold.
  if sqlite3 "file:$wal/kanban.db?mode=ro" "SELECT id FROM tasks LIMIT 0;" >/dev/null 2>&1; then
    skip "live-schema-read-survives-an-idle-board" \
         "this sqlite3 opens a shm-less WAL database read-only; the F67 flake cannot occur here"
  else
    local wsnap
    wsnap="$(scripts/board-snapshot.sh "$wal/kanban.db" "$wal/snap" 2>/dev/null)"
    if [ -n "$wsnap" ] && sqlite3 "$wsnap" "SELECT id FROM tasks LIMIT 0;" >/dev/null 2>&1; then
      ok "live-schema-read-survives-an-idle-board (shm-less WAL board reads via the snapshot primitive, not mode=ro)"
    else
      bad "live-schema-read-survives-an-idle-board" \
          "a WAL board with no -shm could not be read even through scripts/board-snapshot.sh — the check above will flake again (F67)"
    fi
  fi

  # /retro must not go back to asking a model for arithmetic. The skill has to
  # name the command, and must not still be telling anyone to compute anything.
  if grep -Fq 'make metrics BOARD=' skills/retro/SKILL.md; then
    ok "retro-skill-runs-the-command"
  else
    bad "retro-skill-runs-the-command" \
        "skills/retro/SKILL.md must run 'make metrics BOARD=<board>' — step 1 may not derive the numbers in prose (ADR-0003)"
  fi
}

# ---------------------------------------------------------------------------
# metrics/snapshot/ — the ONE WAL-safe way to read a live board (F47, F67).
#
# The behaviour these cases pin existed twice: once in scripts/metrics.sh, put
# there by F47, and once in the live-schema check above, which went on opening
# a live board `mode=ro` for weeks after F47 was fixed and cost a second
# finding. F67's standing remedy — "when a check is fixed, grep for its
# siblings" — is performed here once and then held by
# metrics/snapshot/no-second-implementation.
#
# THE FIXTURE IS THE WHOLE CASE (F51). F47 is reachable ONLY on a
# journal_mode=wal database with no `-shm` beside it; on SQLite's default
# `delete` mode a read-only open succeeds every time. The regression case
# written for F47 passed against the reintroduced bug for exactly that reason.
# So the fixture below is built WAL, checkpointed, stripped of its sidecars,
# and then asserted to still refuse a `mode=ro` open BEFORE anything else is
# claimed about it — a fixture that cannot reproduce the bug is reported, not
# assumed away.
#
# These cases build their own board under $TMPROOT. No live board is opened;
# F67 is precisely why any live sweep stays explicit and opt-in.
# ---------------------------------------------------------------------------
run_snapshot_cases() {
  # Not `group metrics` — that would print a second `== metrics ==` header for
  # what is one group. These cases are appended rather than interleaved so the
  # slices sharing this file rebase cleanly.
  CURRENT_GROUP=metrics
  local bs=scripts/board-snapshot.sh lab="$TMPROOT/snapshot"

  # Six cases are declared in the --list manifest. Both early exits below used
  # to name ONE of them and return, so five declared claims vanished with no
  # skip line and nothing reconciling what was emitted against what was
  # promised — a check that could not run has not passed (F5), and one that does
  # not even say it did not run cannot be noticed.
  local SNAPSHOT_CASES="fixture-reproduces-the-idle-failure
idle-wal-board-is-readable
source-is-byte-identical
unreadable-input-is-silent-on-stdout
empty-input-is-not-an-empty-board
path-with-a-space-is-a-path
help-names-its-exit-contract
torn-source-is-refused
no-second-implementation"
  _snapshot_all() { # $1=skip|bad  $2=reason
    local c
    while IFS= read -r c; do [ -n "$c" ] && "$1" "snapshot/$c" "$2"; done <<EOF
$SNAPSHOT_CASES
EOF
  }

  if ! command -v sqlite3 >/dev/null 2>&1; then
    _snapshot_all skip "sqlite3 not on PATH"; return
  fi
  if [ ! -x "$bs" ]; then
    _snapshot_all bad "$bs is missing or not executable"
    return
  fi
  rm -rf "$lab" && mkdir -p "$lab/src"

  # Build the resting state explicitly. Checkpoint FIRST, then delete the
  # sidecars: deleting an un-checkpointed `-wal` discards committed rows and
  # would test a corrupt board rather than a quiescent one.
  local src="$lab/src/kanban.db" mode
  sqlite3 "$src" "PRAGMA journal_mode=WAL;
                  CREATE TABLE tasks(id TEXT, status TEXT);
                  INSERT INTO tasks VALUES('t1','done');" >/dev/null 2>&1
  mode="$(sqlite3 "$src" "PRAGMA journal_mode;" 2>/dev/null)"
  sqlite3 "$src" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
  rm -f "$src-wal" "$src-shm" "$src-journal"

  if [ "$mode" != "wal" ]; then
    bad "snapshot/fixture-reproduces-the-idle-failure" \
        "the fixture board is journal_mode=${mode:-unknown}, not wal — F47 is unreachable on it, so every case below would pass against the reintroduced bug (F51)"
  elif sqlite3 "file:$src?mode=ro" "SELECT id FROM tasks LIMIT 0;" >/dev/null 2>&1; then
    # THIS IS THE STATE OF `ubuntu-latest`, so it is the state of every pull
    # request. When this skips, `snapshot/idle-wal-board-is-readable` below goes
    # on to report `ok` on a host where the bug is unreachable — true, and
    # evidence of nothing. F47/F67 is therefore gated by `make preflight` on the
    # mini, which builds this same fixture and FAILS if the read breaks; see
    # scripts/preflight.sh §10. A green CI is not a run of this regression.
    skip "snapshot/fixture-reproduces-the-idle-failure" \
         "this sqlite3 opens a shm-less WAL database read-only; F47/F67 is unreachable here and is gated by 'make preflight' on the mini instead"
  else
    ok "snapshot/fixture-reproduces-the-idle-failure (wal, no -shm, and mode=ro provably refuses it)"
  fi

  # Membership AND bytes, over the sidecars too: a `-shm` or `-wal` that the
  # snapshot CREATED beside the live board would be a write to production even
  # though the database itself hashed the same.
  local before after out rc
  before="$(db_source_fingerprint "$src")"

  out="$("$bs" "$src" "$lab/snap" 2>"$lab/snap.err")"; rc=$?
  if [ "$rc" = 0 ] && [ -n "$out" ] \
     && [ "$(sqlite3 "$out" "SELECT id FROM tasks;" 2>/dev/null)" = "t1" ]; then
    ok "snapshot/idle-wal-board-is-readable (no -wal, no -shm, nothing holding it open)"
  else
    bad "snapshot/idle-wal-board-is-readable" \
        "a WAL board at rest could not be snapshot-read (exit $rc, path '${out}') — that is the state every /retro finds a board in: $(tr '\n' ' ' < "$lab/snap.err")"
  fi

  after="$(db_source_fingerprint "$src")"
  if [ "$before" = "$after" ]; then
    ok "snapshot/source-is-byte-identical (db and all three sidecars, present or absent)"
  else
    bad "snapshot/source-is-byte-identical" \
        "reading a board changed it. before: $(printf '%s' "$before" | tr '\n' ' ') after: $(printf '%s' "$after" | tr '\n' ' ')"
  fi

  # F47's UNRECORDED SECOND HALF. `sqlite3` writes `Error: unable to open
  # database file` to STDOUT, so a caller guarding on `[ -n "$OUT" ]` was
  # satisfied by the error text itself: metrics.sh printed one blank line and
  # exited 0 on a resting board, and a /retro consuming --json got nothing from
  # a command that said it worked. Both halves are asserted here, because a
  # case that checked only the exit code would have passed on the bug.
  local out2 rc2
  out="$("$bs" "$lab/absent.db" "$lab/absentsnap" 2>/dev/null)"; rc=$?
  printf 'this is not a database\n' > "$lab/junk.db"
  out2="$("$bs" "$lab/junk.db" "$lab/junksnap" 2>/dev/null)"; rc2=$?
  if [ "$rc" != 0 ] && [ -z "$out" ] && [ "$rc2" != 0 ] && [ -z "$out2" ]; then
    ok "snapshot/unreadable-input-is-silent-on-stdout (missing exit $rc, not-a-database exit $rc2, no path either time)"
  else
    bad "snapshot/unreadable-input-is-silent-on-stdout" \
        "an unreadable board must exit non-zero AND print nothing to stdout: missing file exit $rc printed '$out'; not-a-database exit $rc2 printed '$out2'"
  fi

  # A ZERO-BYTE board is the one unreadable shape no query closes, because it is
  # not malformed — SQLite treats an empty file as a valid EMPTY database and
  # answers happily. A board truncated to nothing was therefore reported as a
  # board with no runs, at exit 0 with a path on stdout, which is the difference
  # between "your run produced nothing" and "I could not read your board".
  local out3 rc3
  : > "$lab/empty.db"
  out3="$("$bs" "$lab/empty.db" "$lab/emptysnap" 2>/dev/null)"; rc3=$?
  if [ "$rc3" != 0 ] && [ -z "$out3" ]; then
    ok "snapshot/empty-input-is-not-an-empty-board (exit $rc3, no path)"
  else
    bad "snapshot/empty-input-is-not-an-empty-board" \
        "a zero-byte board must not read as a board with no rows: exit $rc3 printed '$out3'"
  fi

  # Every path here was carried in a space-separated string and re-split on
  # whitespace, so any board under a directory with a space in its name failed —
  # and failed with a message about the filesystem rather than about quoting.
  # `metrics.sh` exited 2 for any $HOME or $HERMES_KANBAN_HOME containing one.
  local sp="$lab/sp/my board/src" out4 rc4
  mkdir -p "$sp" "$lab/sp/dest"
  sqlite3 "$sp/kanban.db" "CREATE TABLE tasks(id TEXT);" >/dev/null 2>&1
  out4="$("$bs" "$sp/kanban.db" "$lab/sp/dest" 2>/dev/null)"; rc4=$?
  if [ "$rc4" = 0 ] && [ -n "$out4" ] && [ -f "$out4" ]; then
    ok "snapshot/path-with-a-space-is-a-path"
  else
    bad "snapshot/path-with-a-space-is-a-path" \
        "a board under a directory with a space failed to snapshot: exit $rc4 printed '$out4'"
  fi

  # --help was `sed -n '2,55p' "$0"` — correct the day it was written, asserted
  # by nothing, and blind the first time a paragraph was added above it. The
  # same commit removed exactly this pattern from metrics.sh.
  local bshelp; bshelp="$("$bs" --help 2>/dev/null)"
  if printf '%s' "$bshelp" | grep -q 'Usage:' \
     && printf '%s' "$bshelp" | grep -q 'Exit codes:' \
     && ! grep -qE "sed -n '[0-9]+,[0-9]+p' \"\\\$0\"" "$bs"; then
    ok "snapshot/help-names-its-exit-contract"
  else
    bad "snapshot/help-names-its-exit-contract" \
        "--help must carry the whole header block (Usage: and Exit codes:) and must not be pinned to line numbers"
  fi

  # A source that moves under every attempt. The writer is injected through a
  # `cp` shim rather than a background loop on purpose: a real concurrent
  # writer makes this case a coin toss, and a flaky case in the suite that
  # arbitrates disagreements is worse than no case.
  mkdir -p "$lab/shim"
  cat > "$lab/shim/cp" <<'SHIM'
#!/bin/sh
# fault injection: a writer commits to the SOURCE while the copy is in flight
/bin/cp "$@"; rc=$?
printf '%s' "$(date +%s)-$$" >> "$1"
exit $rc
SHIM
  chmod +x "$lab/shim/cp"
  cp "$src" "$lab/torn.db"
  out="$(PATH="$lab/shim:$PATH" "$bs" "$lab/torn.db" "$lab/tornsnap" 2>"$lab/torn.err")"; rc=$?
  # …and it must leave NOTHING BEHIND. Refusing on stdout while leaving a
  # half-copied board on disk only moves the problem to whoever finds the file.
  # Both in-repo callers happen to pass a subdirectory of an `mktemp -d` they
  # clean up, which is luck rather than a property of this script.
  local torn_left; torn_left="$(ls -A "$lab/tornsnap" 2>/dev/null | tr '\n' ' ')"
  if [ "$rc" != 0 ] && [ -z "$out" ] && [ -z "$torn_left" ]; then
    ok "snapshot/torn-source-is-refused (exit $rc after 3 attempts, no path, no partial copy left)"
  else
    bad "snapshot/torn-source-is-refused" \
        "a board changing under every copy attempt must fail, return no path AND leave no partial copy: exit $rc printed '$out', left [${torn_left:-nothing}]"
  fi

  # The point of the slice, and the one case that holds its entire thesis — so
  # it is asserted by EXECUTION, not by grep.
  #
  # It used to be three greps for the string `board-snapshot.sh`, which matched
  # metrics.sh's header COMMENT and six comments in this file. Mutation-proven:
  # replacing the real call `SNAP="$("$HERE/board-snapshot.sh" …)"` with
  # `SNAP="$(false)"` still printed `ok no-second-implementation`. A check that
  # a comment can satisfy is not checking the code.
  #
  # So: stand up a copy of the two scripts, make the primitive unusable, and
  # require metrics.sh to FAIL. Nothing but a real dependency can produce that.
  # Two runs, not one. "It failed with the primitive removed" proves nothing on
  # its own — metrics.sh could be failing for any reason at all — so the SAME
  # sandbox is run first with the primitive intact and must SUCCEED. The pair is
  # the check; either half alone is a coin toss.
  local ns="$TMPROOT/nosecond" dep_rc=-1 ctrl_rc=-1 dep_ready=0
  rm -rf "$ns"; mkdir -p "$ns/scripts" "$ns/rubrics" "$ns/kanban/boards/metrics-fixture"
  if command -v jq >/dev/null 2>&1 \
     && cp scripts/metrics.sh scripts/board-snapshot.sh "$ns/scripts/" 2>/dev/null \
     && cp rubrics/run-metadata-contract.json "$ns/rubrics/" 2>/dev/null \
     && sqlite3 "$ns/kanban/boards/metrics-fixture/kanban.db" \
          < scripts/fixtures/metrics-board.sql >/dev/null 2>&1; then
    dep_ready=1
    HERMES_KANBAN_HOME="$ns/kanban" "$ns/scripts/metrics.sh" metrics-fixture --json \
      >/dev/null 2>&1; ctrl_rc=$?
    chmod -x "$ns/scripts/board-snapshot.sh" 2>/dev/null
    HERMES_KANBAN_HOME="$ns/kanban" "$ns/scripts/metrics.sh" metrics-fixture --json \
      >/dev/null 2>&1; dep_rc=$?
  fi

  # And both live-board readers must CALL it, counted on non-comment lines only.
  # The original check was three `grep -Fq 'board-snapshot.sh'`, which matched
  # metrics.sh's header comment and six comments in this file — so it reported
  # a call that had been deleted. Comments are stripped first, for the same
  # reason `sweep-carries-no-forced-delete` strips them: prose about a rule is
  # not the rule (F65, running the other way).
  #
  # Two in this file, because there are two live-board readers here: the
  # live-schema column check and the idle-board read beside it. That count is
  # what stopped the third hand-rolled `cp` from surviving the unification.
  # The pattern is an INVOCATION inside a command substitution — `$(… board-
  # snapshot.sh …)`. Counting bare mentions on non-comment lines is not enough:
  # two of them in this file are the text of failure messages, and a `cp` of the
  # script into a sandbox is not a call to it either.
  local calls='\$\([^)]*board-snapshot\.sh'
  local m_calls v_calls
  m_calls=$(grep -v '^[[:space:]]*#' scripts/metrics.sh | grep -cE "$calls")
  v_calls=$(grep -v '^[[:space:]]*#' scripts/verify.sh  | grep -cE "$calls")
  local impls=""
  [ "$m_calls" -ge 1 ] || impls="scripts/metrics.sh does not call it ($m_calls)"
  [ "$v_calls" -ge 2 ] || impls="${impls:+$impls; }this suite's live-board readers call it $v_calls time(s), expected 2"

  if [ "$dep_ready" = 0 ]; then
    skip "snapshot/no-second-implementation" \
         "could not stand up the metrics sandbox (jq missing, or the fixture would not load)"
  elif [ "$ctrl_rc" != 0 ]; then
    bad "snapshot/no-second-implementation" \
        "the control arm failed: metrics.sh exited $ctrl_rc against the fixture with the primitive INTACT, so the dependency probe below could not have meant anything"
  elif [ "$dep_rc" = 0 ]; then
    bad "snapshot/no-second-implementation" \
        "metrics.sh still succeeded with board-snapshot.sh made non-executable — it is not really calling the primitive. A grep for the filename cannot tell the difference: it matches the header comment"
  elif [ -n "$impls" ]; then
    bad "snapshot/no-second-implementation" \
        "a live-board reader is not routed through the primitive — $impls. One copy going stale while the other was fixed is what F67 cost a finding to find"
  else
    ok "snapshot/no-second-implementation (metrics.sh: exit $ctrl_rc with the primitive, exit $dep_rc without it; $m_calls + $v_calls real call sites)"
  fi
}

# `metrics/help-exits-zero` asserted the exit code and nothing else, so both of
# metrics.sh's `sed -n '<n>,<m>p' "$0"` help extractors printed the wrong text
# for as long as anyone had been moving lines above them: --help stopped one
# line before `# Usage:` and printed none of the flags, and the no-board branch
# printed nine lines of F47 prose containing no usage line at all. Exactly the
# failure mode CLAUDE.md names — a check anchored to content that moved goes
# blind without turning anything red — so the extractors are now anchored to
# content and the claim is executed rather than asserted.
run_metrics_help_cases() {
  CURRENT_GROUP=metrics
  local h u
  h="$(scripts/metrics.sh --help 2>/dev/null)"
  u="$(scripts/metrics.sh 2>&1 >/dev/null)"
  if printf '%s' "$h" | grep -Fq -- '--markdown-row' \
     && printf '%s' "$h" | grep -Fq 'Usage:' \
     && printf '%s' "$u" | grep -Fq 'Usage:'; then
    ok "help-names-its-usage (--help and the no-board error both reach the Usage block)"
  else
    bad "help-names-its-usage" \
        "metrics.sh --help must print the Usage block and its flags, and the no-board error must print Usage on stderr; got $(printf '%s' "$h" | wc -l | tr -d ' ') help lines and $(printf '%s' "$u" | wc -l | tr -d ' ') usage lines with no match"
  fi
}

wants metrics   && run_metrics_group
wants metrics   && run_metrics_help_cases
wants metrics   && run_snapshot_cases

# ---------------------------------------------------------------------------
# metadata/ — the structured exhaust contract (F1, F2, F44).
#
# This suite is deliberately fixture-only. A live Hermes board is production
# data, and F67 measured why even a read-only open can flake on an idle WAL
# database. A later opt-in sweep may snapshot a live board; the default gate
# proves the contract with immutable files and no board dependency.
#
# Validation uses the JSON Schema implementation pinned in
# scripts/validate-metadata.py. Re-implementing JSON Schema in jq would repeat
# F23 inside Forge: a handwritten validator beside the machine-readable source
# of truth, waiting for the two to disagree.
# ---------------------------------------------------------------------------
run_metadata_group() {
  group metadata
  local validator=scripts/validate-metadata.py
  local fixtures=scripts/fixtures/metadata
  local contract=rubrics/run-metadata-contract.json
  local gate=scripts/prejudge.sh prs=scripts/fixtures/prejudge-prs
  local validator_log="$TMPROOT/metadata-validator.log"

  if ! command -v uv >/dev/null 2>&1; then
    # A skip here is honest — this suite cannot run — but it is NOT the whole
    # story, because forge-lane §7 shells out to this same validator on the
    # unattended path. `make preflight` requires uv for that reason; a green
    # verify with this skip does not mean a lane can terminate on this host.
    skip "schemas-are-valid" "uv not on PATH; cannot run the pinned jsonschema validator"
    return
  fi
  if [ ! -f "$validator" ]; then
    bad "schemas-are-valid" "$validator is missing"
    return
  fi
  if [ ! -f "$validator.lock" ]; then
    bad "schemas-are-valid" "$validator.lock is missing; transitive validation code is not pinned"
    return
  fi

  # --locked, not merely `--script`: without it uv silently RE-RESOLVES and
  # rewrites the lock when the inline metadata drifts, so the check above would
  # keep passing on the lock file's existence while the transitive versions it
  # names had already moved. The direct jsonschema pin holds either way; attrs,
  # referencing and rpds-py are what --locked keeps honest (ADR-0003: execute
  # the claim, do not assert it).
  metadata_validate() {
    uv run --quiet --locked --script "$validator" "$@" > /dev/null 2> "$validator_log"
  }
  metadata_rc() {
    metadata_validate "$@"; printf '%s' "$?"
  }

  if metadata_validate --check-schemas; then
    ok "schemas-are-valid (Draft 2020-12, every registered schema)"
  else
    bad "schemas-are-valid" "$(tail -3 "$validator_log" | tr '\n' ' ')"
  fi

  if jq -e '
      .version == 1
      and .schemas["forge.chunk.v1"] == "chunk-handoff.schema.json"
      and .schemas["forge.gate.v1"] == "gate-result.schema.json"
      and .schemas["forge.judge.v1"] == "judge-verdict.schema.json"
      and .profiles["forge-codex-lane"].completed == ["forge.chunk.v1"]
      and (.profiles["forge-prejudge"].completed | sort
           == (["forge.gate.v1","forge.judge.v1"] | sort))
    ' "$contract" >/dev/null 2>&1; then
    ok "profile-contract-is-explicit (lane: chunk; prejudge: gate or judge)"
  else
    bad "profile-contract-is-explicit" \
        "$contract must map each completed producer profile to its allowed schema ids"
  fi

  # The ~/.forge/repo prefix is asserted, not just the script name: §7 is reached
  # from a project worktree where a relative path cannot resolve, exactly as for
  # lane-setup.sh and lane-blast-radius.sh above. Matching the bare name would
  # let `scripts/validate-metadata.py …` keep this case green while every real
  # lane run died at the terminator.
  local lane=skills/forge-lane/SKILL.md validate_line complete_line
  validate_line="$(grep -Fn '~/.forge/repo/scripts/validate-metadata.py --profile forge-codex-lane' \
                    "$lane" | head -1 | cut -d: -f1)"
  complete_line="$(grep -n 'kanban_complete(summary=' "$lane" | head -1 | cut -d: -f1)"
  if [ -n "$validate_line" ] && [ -n "$complete_line" ] \
     && [ "$validate_line" -lt "$complete_line" ] \
     && grep -Fq "metadata=<the validated file's exact object>" "$lane"; then
    ok "lane-validates-before-complete"
  else
    bad "lane-validates-before-complete" \
        "forge-lane must validate the flat file before kanban_complete and pass that exact object"
  fi

  local valid_ok=1 name profile gate_rc
  for spec in \
    "chunk-valid.json:forge-codex-lane" \
    "judge-valid.json:forge-prejudge"; do
    name="${spec%%:*}"; profile="${spec#*:}"
    metadata_validate --profile "$profile" "$fixtures/$name" || valid_ok=0
  done
  "$gate" --fixture "$prs/pr-8" --json \
    > "$TMPROOT/metadata-produced-gate.json" 2> "$TMPROOT/metadata-gate.err"
  gate_rc=$?
  [ "$gate_rc" = 1 ] || valid_ok=0
  metadata_validate --profile forge-prejudge "$TMPROOT/metadata-produced-gate.json" \
    || valid_ok=0
  [ "$valid_ok" = 1 ] \
    && ok "valid-by-profile (chunk, recorded gate producer, judge)" \
    || bad "valid-by-profile" \
        "a canonical envelope failed its producer contract: $(tail -3 "$validator_log" | tr '\n' ' ')"

  metadata_example() { # one-based JSON block index
    awk -v want="$1" '
      /^```json$/ { seen++; inside=(seen==want); next }
      inside && /^```$/ { exit }
      inside { print }
    ' rubrics/kanban-metadata-schema.md
  }
  if metadata_example 1 | metadata_validate --profile forge-codex-lane - \
     && metadata_example 2 | metadata_validate --profile forge-prejudge -; then
    ok "published-examples-validate"
  else
    bad "published-examples-validate" \
        "rubrics/kanban-metadata-schema.md contains an example its schema rejects"
  fi

  if [ "$(metadata_rc --profile forge-codex-lane "$fixtures/chunk-nested.json")" = 1 ]; then
    ok "rejects-nested-chunk (the historical envelope shape stays noncanonical)"
  else
    bad "rejects-nested-chunk" 'metadata nested under $."forge.chunk.v1" must fail, never normalize'
  fi

  if jq '.["forge.chunk.v1"] = {chunk_id: .chunk_id, pr: .pr}' \
       "$fixtures/chunk-valid.json" \
       | metadata_validate --profile forge-codex-lane -; then
    bad "rejects-reserved-nested-copy" \
        "a flat chunk carrying a second forge.chunk.v1 object was accepted"
  else
    ok "rejects-reserved-nested-copy"
  fi

  if [ "$(metadata_rc --profile forge-codex-lane "$fixtures/chunk-missing-required.json")" = 1 ]; then
    ok "rejects-incomplete-chunk"
  else
    bad "rejects-incomplete-chunk" "a chunk missing required exhaust fields was accepted"
  fi

  if [ "$(metadata_rc --profile forge-codex-lane "$fixtures/chunk-coverage-drift.json")" = 1 ]; then
    ok "rejects-coverage-key-drift (coverage_pct is canonical)"
  else
    bad "rejects-coverage-key-drift" "check.coverage silently replaced check.coverage_pct"
  fi

  # Eight of these ten mutations edit the RECORDED gate output, so a producer
  # that emitted nothing would silently turn them into no-ops that still report
  # success: `jq '.result = "clear"' </dev/null` exits 0 with empty output, the
  # validator then rejects empty stdin with rc 1, and `&& semantic_ok=0` reads
  # that as "the contradiction was correctly caught". Prove the mutations had
  # something to mutate before believing any of them. `.checks[1]` and the
  # `.blocks | reverse` mutation are no-ops on shorter arrays, so the shape
  # each mutation needs is what gets asserted, not merely non-emptiness.
  local semantic_ok=1
  if ! jq -e '
      type == "object"
      and (.checks | type) == "array" and (.checks | length) > 1
      and (.blocks | type) == "array" and (.blocks | length) > 1
    ' "$TMPROOT/metadata-produced-gate.json" >/dev/null 2>&1; then
    bad "rejects-semantic-contradictions" \
        "the recorded gate emitted no mutable envelope; the ten mutations proved nothing"
  else
    jq '.scenarios.passing = (.scenarios.added + 1)' "$fixtures/chunk-valid.json" \
      | metadata_validate --profile forge-codex-lane - && semantic_ok=0
    jq '.branch = "chunk/8-wrong-id"' "$fixtures/chunk-valid.json" \
      | metadata_validate --profile forge-codex-lane - && semantic_ok=0
    jq '.result = "clear"' "$TMPROOT/metadata-produced-gate.json" \
      | metadata_validate --profile forge-prejudge - && semantic_ok=0
    jq '.counts.block = 0' "$TMPROOT/metadata-produced-gate.json" \
      | metadata_validate --profile forge-prejudge - && semantic_ok=0
    jq '.counts.pass += 1' "$TMPROOT/metadata-produced-gate.json" \
      | metadata_validate --profile forge-prejudge - && semantic_ok=0
    jq '.repo = "someone/else"' "$TMPROOT/metadata-produced-gate.json" \
      | metadata_validate --profile forge-prejudge - && semantic_ok=0
    jq '.number += 1' "$TMPROOT/metadata-produced-gate.json" \
      | metadata_validate --profile forge-prejudge - && semantic_ok=0
    jq '.checks[1].id = .checks[0].id' "$TMPROOT/metadata-produced-gate.json" \
      | metadata_validate --profile forge-prejudge - && semantic_ok=0
    jq '.blocks |= reverse' "$TMPROOT/metadata-produced-gate.json" \
      | metadata_validate --profile forge-prejudge - && semantic_ok=0
    jq '.branch = "chunk/6-wrong-id"' "$TMPROOT/metadata-produced-gate.json" \
      | metadata_validate --profile forge-prejudge - && semantic_ok=0
    if [ "$semantic_ok" = 1 ]; then
      ok "rejects-semantic-contradictions (scenarios, ids, URLs, checks, counts and result)"
    else
      bad "rejects-semantic-contradictions" \
          "an envelope whose derived fields contradict its evidence was accepted"
    fi
  fi

  # The SAME defect one layer down, and the layer that costs most. The lane's
  # §7 gates `kanban_complete` on this validator exiting 0, so a digits-only
  # `chunk_id`/`branch` pattern kills a JobApp run at the TERMINATOR — after the
  # PR is open and the whole chunk is paid for. Measured on this worktree before
  # the widening, against `chunk-valid.json` retargeted to C10:
  #
  #   branch: 'chunk/C10-instance-paths' does not match '^chunk/[0-9]+-…'
  #   chunk_id: 'CHUNK-C10' does not match '^CHUNK-[0-9]+$'
  #
  # The MISMATCH rows are the ones that earn this case. `semantic_errors()`
  # compares the branch id to the chunk id only when BOTH of its own regexes
  # match, so widening the schemas alone would let `CHUNK-C10` sail past a
  # comparison that silently stopped happening — a check switched off by the
  # repair, which is this repo's signature bug. The digits rows are the control:
  # nothing about the old shape may change.
  local ids_ok=1 rc
  for spec in \
    "chunk:CHUNK-C10:chunk/C10-instance-paths:0" \
    "chunk:CHUNK-C9.1:chunk/C9.1-pipeline-observability:0" \
    "chunk:CHUNK-7:chunk/7-sync-engine:0" \
    "chunk:CHUNK-C10:chunk/C9.1-pipeline-observability:1" \
    "chunk:CHUNK-7:chunk/8-sync-engine:1" \
    "gate:CHUNK-C10:chunk/C10-instance-paths:0" \
    "gate:CHUNK-C10:chunk/C9.1-pipeline-observability:1"; do
    local kind="${spec%%:*}" rest="${spec#*:}"
    local cid="${rest%%:*}"; rest="${rest#*:}"
    local br="${rest%%:*}" want_rc="${rest##*:}"
    if [ "$kind" = chunk ]; then
      rc="$(jq --arg c "$cid" --arg b "$br" '.chunk_id=$c | .branch=$b' \
              "$fixtures/chunk-valid.json" \
            | metadata_rc --profile forge-codex-lane -)"
    else
      rc="$(jq --arg c "$cid" --arg b "$br" '.chunk=$c | .branch=$b' \
              "$TMPROOT/metadata-produced-gate.json" \
            | metadata_rc --profile forge-prejudge -)"
    fi
    if [ "$rc" != "$want_rc" ]; then
      bad "chunk-id-is-not-digits" \
          "$kind envelope $cid on $br returned $rc, expected $want_rc: $(tail -2 "$validator_log" | tr '\n' ' ')"
      ids_ok=0; break
    fi
  done
  [ "$ids_ok" = 1 ] \
    && ok "chunk-id-is-not-digits (7 envelopes: C10, C9.1 and 7 accepted, mismatched ids still refused)"

  if metadata_validate --profile forge-codex-lane "$fixtures/chunk-additive.json"; then
    ok "allows-additive-hermes-keys (changed_files/tests_run stay siblings)"
  else
    bad "allows-additive-hermes-keys" "dashboard-native sibling keys were rejected"
  fi

  # The same tolerance, on the one envelope that did not have it. Recorded from
  # board forge-hello-20260902, task t_0868e3c1 run 2, 2026-09-02: the chunk
  # envelope beside it validated and this one did not, with three errors.
  #
  #   $: Additional properties are not allowed ('worker_session_id' was unexpected)
  #   $: 'nits_as_cards' is a required property
  #   $: 'tokens_estimate' is a required property
  #
  # `metadata-live` exits 1 on that, which docs/staged-run-guide.md defines as
  # "stop and repair the producer" — at the ROOT checkpoint, after the chunk had
  # been implemented, reviewed and merged. The three dispositions, one leg each:
  #
  # A. `nits_as_cards` stays REQUIRED, so the recorded envelope stays refused.
  #    It is a genuine judgement the scorer alone made, and the repair is in the
  #    harness, which now fills the absent case with [] rather than in a schema
  #    that stops asking for it.
  # B. With it filled, the envelope a real run stores must VALIDATE.
  #    `worker_session_id` is Hermes's own stamp on task_runs.metadata
  #    (docs/hermes-field-notes.md) — the exact provenance metrics.sh joins on —
  #    so refusing it makes every real prejudge run invalid forever, and
  #    `tokens_estimate` is not demanded of a verdict whose harness reported no
  #    usage. `chunk_id` is recorded as it came back, `chunk_hello_1`, because
  #    nothing here catches that yet and pretending otherwise would hide it.
  # C. Declaring ONE measured key is not opening the envelope. A second,
  #    unmeasured sibling is still refused: additionalProperties:false is what
  #    prejudge/stamped-envelope-declares-every-key rests on.
  local live="$fixtures/judge-live-20260902.json" live_ok=1
  [ "$(metadata_rc --profile forge-prejudge "$live")" = 1 ] || live_ok=0
  jq '.nits_as_cards = []' "$live"     | metadata_validate --profile forge-prejudge - || live_ok=0
  [ "$(jq '.nits_as_cards = [] | .helpfully_invented = "x"' "$live"        | metadata_rc --profile forge-prejudge -)" = 1 ] || live_ok=0
  [ "$live_ok" = 1 ]     && ok "judge-envelope-as-produced (the recorded key set, once the harness fills nits_as_cards)"     || bad "judge-envelope-as-produced"         "the envelope forge-hello-20260902 actually stored must validate once nits_as_cards is filled, and only the substrate's own sibling key may be declared: $(tail -3 "$validator_log" | tr '\n' ' ')"

  if [ "$(metadata_rc --profile forge-prejudge "$fixtures/chunk-valid.json")" = 1 ]; then
    ok "rejects-profile-schema-mismatch"
  else
    bad "rejects-profile-schema-mismatch" "forge-prejudge accepted a forge.chunk.v1 completion"
  fi

  if [ "$(metadata_rc --profile forge-codex-lane "$fixtures/metadata-null.json")" = 1 ]; then
    ok "rejects-missing-metadata"
  else
    bad "rejects-missing-metadata" "a completed lane run with null metadata was accepted"
  fi

  # The lane runs this validator by shebang, not through this suite, so --locked
  # has to be ON THE SHEBANG or the unattended path is the unpinned one while
  # `make verify` reports a pinned one.
  if head -1 "$validator" | grep -Fq 'uv run --locked --script'; then
    ok "validator-runtime-is-locked (the shebang the lane uses refuses a drifted lock)"
  else
    bad "validator-runtime-is-locked" \
        "$validator's shebang must pass --locked; uv silently re-resolves and rewrites the lock without it"
  fi

  # Exit 1 is a verdict about the envelope, and forge-lane §7 turns it into a
  # block against the chunk. A path that cannot be read yields no verdict at
  # all, so it must not borrow that code and blame the run for it.
  if [ "$(metadata_rc --profile forge-codex-lane "$fixtures")" = 2 ]; then
    ok "unreadable-path-is-not-invalid-metadata (exit 2, and no traceback)"
  else
    bad "unreadable-path-is-not-invalid-metadata" \
        "a path that cannot be read must exit 2; exit 1 makes a lane block its chunk for an operator's fault"
  fi

  # Each producer is swept by a rule matching ITS literal form, and a rule that
  # matches nothing extracts nothing: the loop below never sees the line, the
  # class it carries is never validated, and the case still reports ok. That is
  # the F65/F66 failure mode — a check anchored to content that moved degrades
  # to silence rather than to red — and it is not hypothetical here. The form
  # this slice retired from lane-setup.sh, `echo "reason_class=env: …"`, carries
  # an underscore, which the echo rule's [a-z0-9=-] class does not admit;
  # reverting a producer to it would go unswept, not caught.
  #
  # So the sweep is per producer, not one pooled stream, and a producer that
  # contributes no class at all fails the case. Pooling hid this: lane-setup.sh
  # and lane-blast-radius.sh together yield ~46 of the ~61 classes, so either
  # one could fall silent and any total-count floor would still clear.
  local reason_ok=1 reason silent="" legacy swept="$TMPROOT/metadata-reasons.txt"
  : > "$swept"
  metadata_sweep() { # $1=rule label  $2=sed script  $3=producer file
    local hits; hits="$(sed -n "$2" "$3")"
    if [ -n "$hits" ]; then printf '%s\n' "$hits" >> "$swept"
    else silent="$silent $3($1)"; fi
  }
  metadata_sweep substrate 's/.*substrate "\([a-z0-9=-]*:\).*/\1/p' scripts/prejudge-review.sh
  metadata_sweep json     's/.*"reason":"\([a-z0-9=-]*:\).*/\1/p'   scripts/prejudge-review.sh
  metadata_sweep quoted   's/^[[:space:]]*"\([a-z0-9=-]*:\).*/\1/p' scripts/prejudge-review.sh
  metadata_sweep echo     's/.*echo "\([a-z0-9=-]*:\).*/\1/p'       scripts/lane-setup.sh
  metadata_sweep echo     's/.*echo "\([a-z0-9=-]*:\).*/\1/p'       scripts/lane-blast-radius.sh
  metadata_sweep reason   's/.*reason="\([a-z0-9=-]*:\).*/\1/p'     hermes/profiles/forge-prejudge.SOUL.md
  metadata_sweep reason   's/.*reason="\([a-z0-9=-]*:\).*/\1/p'     skills/forge-lane/SKILL.md

  while IFS= read -r reason; do
    [ -n "$reason" ] || continue
    case "$reason" in usage:|lane-setup:|blast-radius:) continue;; esac
    metadata_validate --reason "$reason reason" || reason_ok=0
  done < "$swept"

  # Asserted directly, because no sweep rule can see it: the retired form is
  # what a revert would reintroduce, and it is invisible to the rules above.
  legacy="$(grep -lF 'reason_class=' \
              scripts/prejudge-review.sh scripts/lane-setup.sh \
              scripts/lane-blast-radius.sh hermes/profiles/forge-prejudge.SOUL.md \
              skills/forge-lane/SKILL.md 2>/dev/null | tr '\n' ' ')"

  for producer in skills/forge-lane/SKILL.md \
                  hermes/profiles/forge-codex-lane.SOUL.md \
                  hermes/profiles/forge-orchestrator.SOUL.md; do
    grep -Fq '~/.forge/rubrics/run-metadata-contract.json' "$producer" || reason_ok=0
  done
  grep -Fq 'run-metadata-contract.json' scripts/metrics.sh || reason_ok=0
  if [ "$reason_ok" = 1 ] && [ -z "$silent" ] && [ -z "$legacy" ]; then
    ok "blocked-reason-contract ($(grep -c . "$swept") classes swept from 7 producer rules)"
  else
    bad "blocked-reason-contract" \
        "${silent:+no class matched in:$silent — the sweep went blind, not green; }${legacy:+the retired reason-class form is back in: $legacy; }a producer or metrics consumer diverges from rubrics/run-metadata-contract.json"
  fi
}

run_metadata_live_cases() {
  CURRENT_GROUP=metadata
  local fixture=scripts/fixtures/metadata/live-board.sql
  local live_root="$TMPROOT/metadata-live-home" board=metadata-live
  local db="$live_root/boards/$board/kanban.db"
  local cutoff=2026-08-09T00:00:00Z out rc

  if grep -Fq './scripts/metadata-live.sh <slug> --since' docs/operator-guide.md \
     && grep -Fq 'exits 0 for a satisfied contract, 1 for a readable contract' \
          docs/operator-guide.md \
     && grep -Fq 'do not use' docs/operator-guide.md; then
    ok "live-operator-interface (direct script preserves 0/1/2; Make is human-facing)"
  else
    bad "live-operator-interface" \
        "operator automation must call metadata-live.sh directly and reserve the Make wrapper for generic human-facing success/failure"
  fi

  mkdir -p "$(dirname "$db")"
  if ! sqlite3 "$db" < "$fixture" >/dev/null 2>&1; then
    bad "live-fixture" "could not create the WAL-mode metadata board"
    return
  fi

  out="$(HERMES_KANBAN_HOME="$live_root" \
      make metadata-live BOARD=missing SINCE= 2>&1)"; rc=$?
  if [ "$rc" = 2 ] \
     && printf '%s' "$out" | grep -Fq 'SINCE must be RFC3339' \
     && ! printf '%s' "$out" | grep -Fq 'no board database'; then
    out="$(HERMES_KANBAN_HOME="$live_root" \
        make metadata-live BOARD=missing SINCE=2026-08-09 2>&1)"; rc=$?
    if [ "$rc" = 2 ] \
       && printf '%s' "$out" | grep -Fq 'SINCE must be RFC3339' \
       && ! printf '%s' "$out" | grep -Fq 'no board database'; then
      ok "live-requires-rfc3339-since (absent and malformed values refused before board resolution)"
    else
      bad "live-requires-rfc3339-since" \
          "malformed SINCE must exit 2 before looking for BOARD=missing; got exit $rc: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
  else
    bad "live-requires-rfc3339-since" \
        "missing SINCE must exit 2 before looking for BOARD=missing; got exit $rc: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi

  out="$(HERMES_KANBAN_HOME="$live_root" \
      scripts/metadata-live.sh "$board" --since "$cutoff" 2>&1)"; rc=$?
  local good_out="$out" good_rc="$rc"
  sqlite3 "$db" "UPDATE task_runs SET profile='default' WHERE id=2;"
  out="$(HERMES_KANBAN_HOME="$live_root" \
      scripts/metadata-live.sh "$board" --since "$cutoff" 2>&1)"; rc=$?
  sqlite3 "$db" "UPDATE task_runs SET profile='forge-prejudge' WHERE id=2;"
  if [ "$good_rc" = 0 ] \
     && printf '%s' "$good_out" | grep -Fq 'valid=3 invalid=0 unjudged=0 ignored=2' \
     && printf '%s' "$good_out" | grep -Fq 'profile=forge-codex-lane schema=forge.chunk.v1 valid=1' \
     && printf '%s' "$good_out" | grep -Fq 'profile=forge-prejudge schema=forge.judge.v1 valid=1' \
     && [ "$rc" = 1 ] \
     && printf '%s' "$out" | grep -Fq 'missing producer=forge-prejudge'; then
    ok "live-valid-counts (profile/schema counts exact; a missing contracted producer exits 1)"
  else
    bad "live-valid-counts" \
        "canonical counts or missing-producer enforcement drifted; got exits $good_rc/$rc: $(printf '%s' "$out" | tail -6 | tr '\n' ' ')"
  fi

  # Mutate only post-cutoff rows. The historical nested envelope and bad reason
  # remain ignored, which proves the scope independently of the good fixture.
  sqlite3 "$db" <<'SQL'
UPDATE task_runs
   SET task_id='t_bad_nested', metadata='{"forge.chunk.v1":{"chunk_id":"CHUNK-4"}}'
 WHERE id=1;
INSERT INTO task_runs VALUES
  (5,'t_bad_null','forge-codex-lane','done',1786234000,1786234010,'completed',NULL),
  (6,'t_bad_cross','forge-codex-lane','done',1786234020,1786234030,'completed','{"schema":"forge.judge.v1"}');
UPDATE task_events
   SET task_id='t_bad_reason', payload='{"reason":"free-form model excuse","kind":"needs_input"}'
 WHERE id=1;
SQL

  out="$(HERMES_KANBAN_HOME="$live_root" \
      scripts/metadata-live.sh "$board" --since "$cutoff" 2>&1)"; rc=$?
  local named=1 id
  for id in t_bad_nested t_bad_null t_bad_cross; do
    printf '%s' "$out" | grep -Fq "task=$id" || named=0
  done
  local invalid_out="$out" invalid_rc="$rc"

  if [ "$invalid_rc" = 1 ] \
     && printf '%s' "$invalid_out" | grep -Fq 'valid=1 invalid=4 unjudged=0 ignored=2' \
     && printf '%s' "$invalid_out" | grep -Fq 'invalid task=t_bad_reason run=1' \
     && printf '%s' "$invalid_out" | grep -Fq 'reason="free-form model excuse"'; then
    ok "live-rejects-bad-block-reason (task, run and reason printed)"
  else
    bad "live-rejects-bad-block-reason" \
        "the invalid model-authored reason must be an exit-1 contract violation with task and run"
  fi

  sqlite3 "$db" \
    "INSERT INTO task_runs VALUES (7,'t_unreadable','forge-codex-lane','done',1786234040,1786234050,'completed','{not json');"
  out="$(HERMES_KANBAN_HOME="$live_root" \
      scripts/metadata-live.sh "$board" --since "$cutoff" 2>&1)"; rc=$?
  if [ "$invalid_rc" = 1 ] && [ "$named" = 1 ] \
     && [ "$rc" = 2 ] \
     && printf '%s' "$out" | grep -Fq 'unjudged task=t_unreadable run=7' \
     && printf '%s' "$out" | grep -Fq 'valid=1 invalid=4 unjudged=1 ignored=2'; then
    ok "live-classifies-every-bad-row (invalid exits 1; unjudged is named and dominates as exit 2)"
  else
    bad "live-classifies-every-bad-row" \
        "bad rows must be named with distinct exit-1/exit-2 outcomes; got exits $invalid_rc/$rc: $(printf '%s' "$out" | tail -9 | tr '\n' ' ')"
  fi

  if printf '%s' "$out" | grep -Fq 'ignored=2' \
     && ! printf '%s' "$out" | grep -Fq 'invalid task=t_old_nested'; then
    ok "live-ignores-pre-cutoff (one producer row plus one block event)"
  else
    bad "live-ignores-pre-cutoff" \
        "pre-cutoff rows must contribute only to ignored"
  fi

  local isolated="$TMPROOT/metadata-live-isolated"
  mkdir -p "$isolated/scripts" "$isolated/rubrics" \
           "$isolated/kanban/boards/$board"
  cp scripts/metadata-live.sh scripts/board-snapshot.sh \
     scripts/validate-metadata.py scripts/validate-metadata.py.lock \
     "$isolated/scripts/" 2>/dev/null || true
  cp rubrics/*.json "$isolated/rubrics/" 2>/dev/null || true
  sqlite3 "$isolated/kanban/boards/$board/kanban.db" \
    < "$fixture" >/dev/null 2>&1
  HERMES_KANBAN_HOME="$isolated/kanban" \
    "$isolated/scripts/metadata-live.sh" "$board" --since "$cutoff" \
    >/dev/null 2>&1; local control_rc=$?
  chmod -x "$isolated/scripts/board-snapshot.sh" 2>/dev/null || true
  HERMES_KANBAN_HOME="$isolated/kanban" \
    "$isolated/scripts/metadata-live.sh" "$board" --since "$cutoff" \
    >/dev/null 2>&1; local dependency_rc=$?
  if [ "$control_rc" = 0 ] && [ "$dependency_rc" = 2 ]; then
    ok "live-uses-snapshot (control exit 0; unavailable primitive exit 2)"
  else
    bad "live-uses-snapshot" \
        "metadata-live must work with the primitive and fail closed without it; exits $control_rc/$dependency_rc"
  fi
}
wants metadata  && run_metadata_group
wants metadata  && run_metadata_live_cases

# ---------------------------------------------------------------------------
# prejudge/ — tier 1's deterministic FIRST STAGE (F35, ADR-0009). Modelled on
# metrics/: a checked-in fixture, an exact whole-document expectation, and a
# mutation the case must actually catch. The model stage that runs after a clear
# result is covered in lane/, which is where the SOUL is read.
#
# S3 left the GitHub-facing half — ci-state, branch-name, size-budget, touches —
# covered by an 11-PR backtest run by hand and nothing else. That gap is closed
# here, because the gate blocks now: `--fixture` replays two RECORDED PRs of the
# run that produced the audit, and the whole gate runs against them with no gh,
# no git and no network. Recorded with, for n in 8 9:
#
#   gh pr view $n --repo wielas/forgeboard-report --json \
#     number,state,title,body,headRefName,headRefOid,baseRefName,baseRefOid,\
#     mergedAt,url,additions,deletions,changedFiles,statusCheckRollup | jq -S .
#   git diff --numstat <baseRefOid> <headRefOid>        > numstat.tsv
#   git archive <headRefOid> docs/chunks tests/features | tar -x -C tree/
#   git show <baseRefOid>:docs/chunks/<CHUNK>.md         > base-tree/docs/chunks/<CHUNK>.md
#
# The recorded `tree/` carries the contract and the feature file and NOT the
# 3,500-line test suite, so `then-asserts` skips on these fixtures. That check
# is covered exactly, and separately, by the walker fixture above — the point of
# these two is the GitHub/tree-facing set that was covered by nothing.
# ---------------------------------------------------------------------------
run_prejudge_group() {
  group prejudge
  local gate=scripts/prejudge.sh walker=scripts/prejudge-steps.py
  local fx=scripts/fixtures/prejudge-steps exp=scripts/fixtures/prejudge-steps-expected.json

  if ! command -v python3 >/dev/null 2>&1; then
    skip "steps-walker-exact" "python3 not on PATH"; return
  fi

  if HOME="$TMPROOT/nohome" "$gate" --help >/dev/null 2>&1; then
    ok "help-exits-zero"
  else
    bad "help-exits-zero" "$gate --help did not exit 0 without a PR"
  fi

  # Exact, whole-document. A new offender kind appearing, or an old one quietly
  # vanishing, must fail a case — the same argument as metrics/fixture-numbers.
  python3 "$walker" "$fx" | jq . > "$TMPROOT/steps.json" 2>&1
  if diff -u "$exp" "$TMPROOT/steps.json" > "$TMPROOT/steps.diff" 2>&1; then
    ok "steps-walker-exact ($(jq -r .then_steps "$exp") Then steps, $(jq -r '.offenders|length' "$exp") offenders, every field)"
  else
    bad "steps-walker-exact" "$(head -12 "$TMPROOT/steps.diff" | tr '\n' ' ')"
  fi

  # The two shapes F14 cites by file and line must be caught BY NAME, not merely
  # counted. A count can stay right while the walker starts finding the wrong
  # three things.
  local kinds
  kinds="$(jq -r '[.offenders[] | "\(.func):\(.kind)"] | sort | join(",")' "$exp")"
  case "$kinds" in
    *"then_no_assertion_at_all:no-assertion"*)
      case "$kinds" in
        *"then_tautology:tautology"*) ok "steps-walker-catches-both-cited-shapes";;
        *) bad "steps-walker-catches-both-cited-shapes" "the render(x)==render(x) tautology (test_render.py:198-200) is not reported";;
      esac;;
    *) bad "steps-walker-catches-both-cited-shapes" "a Then step with no assertion at all is not reported";;
  esac

  # False positives are how a gate gets switched off. The fixture holds six
  # legitimate Then steps — plain assert, recorded-vs-recomputed comparison,
  # pytest.raises, pytest.fail, an assert* helper and a module-PRIVATE
  # _assert* helper — and none may be reported. The last shape is here because
  # the walker got it wrong: four Then steps on PR #11 delegating to
  # `_assert_failures` were reported as making no claim at all.
  local fp
  fp="$(jq -r '[.offenders[].func | select(test("plain_assert|compares_two_different|pytest_raises|pytest_fail|assert_helper"))] | join(",")' "$exp")"
  [ -z "$fp" ] && ok "steps-walker-has-no-false-positives (6 legitimate step shapes)" \
    || bad "steps-walker-has-no-false-positives" "legitimate steps reported as defects: $fp"

  # ---- the recorded PRs. The whole gate, offline, against real inputs. ------
  local prs=scripts/fixtures/prejudge-prs pexp=scripts/fixtures/prejudge-prs/expected.json
  local got want name drift=""
  for name in pr-8 pr-9; do
    "$gate" --fixture "$prs/$name" --json > "$TMPROOT/$name.json" 2>"$TMPROOT/$name.err"
    got="$(jq -S '{result, blocks, checks: (.checks | map({(.id): .status}) | add)}' \
             "$TMPROOT/$name.json" 2>/dev/null)"
    want="$(jq -S --arg n "$name" '.[$n]' "$pexp")"
    [ "$got" = "$want" ] || drift="$drift $name"
  done
  # The expectation is the SEVERITY MAP, not the prose: id -> status, the block
  # list and the result. Asserting the evidence strings too would fail on every
  # reworded sentence and teach the next person to regenerate the file without
  # reading it, which is how a checked-in expectation stops being evidence.
  [ -z "$drift" ] && ok "recorded-prs-exact (2 PRs, 8 checks each, offline)" \
    || bad "recorded-prs-exact" "the severity map moved on:$drift — $(jq -c . "$TMPROOT/${drift## }.json" 2>/dev/null | cut -c1-200)"

  # ---- the same gate, against the id shapes real products use --------------
  # `<id>` was read as a decimal integer in four places, and the reproduction is
  # the whole argument. `chunk/C10-instance-paths` and
  # `chunk/C9.1-pipeline-observability` were BLOCKED with "has no <slug>" — a
  # sentence that is false about the branch it names — because the `chunk/[0-9]*-*`
  # arm cannot match a letter and everything fell through to the no-slug arm.
  # branch-name blocks, so that stopped every chunk of a 15-chunk JobApp run,
  # each one AFTER a full unattended lane run had already been paid for. That is
  # F7's cost with the sign flipped: the rule now refuses correct work.
  #
  # THE ACTION IS ASSERTED, NOT JUST THE STATUS, and this is the column that
  # matters most. The id sed was `s/^[^0-9]*([0-9]+).*/\1/`, which turns
  # `CHUNK-C10` into `10` and `CHUNK-C9.1` into `9`, so the gate blocked and then
  # advised `git branch -m … chunk/10-…`. A worker who obeys ends up with a
  # branch whose id no longer matches its card, and the next run cannot pair
  # them. A status-only matrix goes green with that sed still in place.
  #
  # The `.chunk` column asserts the derivation at the top of the gate, which is
  # the fourth place and the reason the other three cannot be fixed alone: with
  # `chunk` null there is no CONTRACT, so `scenario-count` and `touches` SKIP.
  # Widening only the branch rule would convert a wrong block into a clear with
  # a blocking check silently skipped, which is strictly worse.
  #
  # `slice/foo` carrying a `CHUNK-C10:` title must BLOCK, not skip: chunk-ness is
  # read from the title precisely so a chunk pushed to any name at all is still
  # judged, and `CHUNK-[0-9]*` could not see a letter id. `planning/lifecycle` is
  # the case that scoping exists for (PR #1) and must still skip.
  #
  # An id containing a hyphen is not recoverable from the branch alone — the
  # branch separator IS a hyphen — so `chunk/hello-1-greet` yields `CHUNK-hello`
  # and its contract checks skip naming that id. The branch is still correctly
  # named; the grammar simply reads `hello` as the id and `1-greet` as the slug.
  #
  # Columns: branch | PR title | status | substring the action must carry | .chunk
  local bfx="$TMPROOT/branch-shapes" b t want_status want_act want_chunk
  local shapes_ok=1 gotj got_status got_act got_chunk
  while IFS='|' read -r b t want_status want_act want_chunk; do
    [ -n "$b" ] || continue
    rm -rf "$bfx"; mkdir -p "$bfx"
    jq --arg b "$b" --arg t "$t" '.headRefName=$b | .title=$t' \
       "$prs/pr-9/pr.json" > "$bfx/pr.json"
    gotj="$("$gate" --fixture "$bfx" --json 2>/dev/null)"
    got_status="$(printf '%s' "$gotj" | jq -r '.checks[]|select(.id=="branch-name")|.status')"
    got_act="$(printf '%s' "$gotj" | jq -r '.checks[]|select(.id=="branch-name")|.action // ""')"
    got_chunk="$(printf '%s' "$gotj" | jq -r '.chunk // "null"')"
    if [ "$got_status" != "$want_status" ]; then
      bad "branch-name-reads-real-chunk-ids" \
          "'$b' is $got_status, expected $want_status: $(printf '%s' "$gotj" | jq -r '.checks[]|select(.id=="branch-name")|.evidence')"
      shapes_ok=0; break
    fi
    case "$got_act" in
      *"$want_act"*) ;;
      *) bad "branch-name-reads-real-chunk-ids" \
             "'$b' was told '${got_act:-(no action)}' — a repair a worker can obey must name $want_act, not a renumbered branch"
         shapes_ok=0; break;;
    esac
    if [ "$got_chunk" != "$want_chunk" ]; then
      bad "branch-name-reads-real-chunk-ids" \
          "'$b' derived chunk=$got_chunk, expected $want_chunk — an unparsed id skips scenario-count and touches instead of running them"
      shapes_ok=0; break
    fi
  done <<'SHAPES'
chunk/C10-instance-paths|CHUNK-C10: instance paths and second instance|pass||CHUNK-C10
chunk/C9.1-pipeline-observability|CHUNK-C9.1: pipeline observability|pass||CHUNK-C9.1
chunk/hello-1-greet|CHUNK-hello-1: greet the world|pass||CHUNK-hello
chunk/7-render-report|CHUNK-7: render the report|pass||CHUNK-7
chunk/C10|CHUNK-C10: instance paths and second instance|block|chunk/C10-instance|CHUNK-C10
chunk/C7.1-Mirror|CHUNK-C7.1: mirror and migration hardening|block|chunk/C7.1-mirror|CHUNK-C7.1
chunk/8|CHUNK-8: render the report|block|chunk/8-render|CHUNK-8
slice/foo|CHUNK-C10: instance paths and second instance|block|chunk/C10-instance|null
planning/lifecycle|planning: the chunk lifecycle|skip||null
SHAPES
  [ "$shapes_ok" = 1 ] \
    && ok "branch-name-reads-real-chunk-ids (9 shapes: verdict, repair action and derived id)"

  # The head contract is still the source for the ordinary `touches` check.
  # Comparing it with the recorded base contract adds a second, independent
  # signal: a branch cannot silently widen its own declaration and then have
  # the implementation certified against only that widened declaration.
  local unchanged="$TMPROOT/touches-unchanged"
  local widened="$TMPROOT/touches-widened"
  local removed="$TMPROOT/touches-removed"
  local exempted="$TMPROOT/touches-exempted"
  local contract_rel=tree/docs/chunks/CHUNK-5.md
  local base_contract_rel=base-tree/docs/chunks/CHUNK-5.md
  local errors_path=src/forgeboard_report/errors.py

  rm -rf "$unchanged"; cp -R "$prs/pr-9" "$unchanged"
  # ANSI-C quoting supplies literal tabs on both BSD and GNU grep. A doubled
  # backslash was tolerated as a tab locally but matched nothing on Ubuntu.
  grep -v $'^21\t0\tsrc/forgeboard_report/errors.py$' "$prs/pr-9/numstat.tsv" \
    > "$unchanged/numstat.tsv"
  "$gate" --fixture "$unchanged" --json > "$TMPROOT/touches-unchanged.json" 2>&1
  if [ "$(jq -r '.checks[] | select(.id=="touches") | .status' "$TMPROOT/touches-unchanged.json")" = pass ] \
     && [ "$(jq -r '.checks[] | select(.id=="touches-widened") | .status' "$TMPROOT/touches-unchanged.json")" = pass ]; then
    ok "touches-unchanged-passes"
  else
    bad "touches-unchanged-passes" \
        "an unchanged contract with an in-scope diff must pass touches and touches-widened"
  fi

  rm -rf "$widened"; cp -R "$prs/pr-9" "$widened"
  sed "s#\`src/forgeboard_report/domain.py\`, #\`src/forgeboard_report/domain.py\`, \`$errors_path\`, #" \
    "$widened/$contract_rel" > "$widened/contract.tmp"
  mv "$widened/contract.tmp" "$widened/$contract_rel"
  "$gate" --fixture "$widened" --json > "$TMPROOT/touches-widened.json" 2>&1
  if [ "$(jq -r '.checks[] | select(.id=="touches") | .status' "$TMPROOT/touches-widened.json")" = pass ] \
     && [ "$(jq -r '.checks[] | select(.id=="touches-widened") | .status' "$TMPROOT/touches-widened.json")" = warn ] \
     && jq -e --arg path "$errors_path" \
          '.checks[] | select(.id=="touches-widened") | .evidence | contains($path)' \
          "$TMPROOT/touches-widened.json" >/dev/null; then
    ok "touches-widening-is-visible ($errors_path)"
  else
    bad "touches-widening-is-visible" \
        "a head-only Touches addition must warn with its path while ordinary touches passes"
  fi

  rm -rf "$removed"; cp -R "$unchanged" "$removed"
  sed "s#\`src/forgeboard_report/domain.py\`, #\`src/forgeboard_report/domain.py\`, \`$errors_path\`, #" \
    "$removed/$base_contract_rel" > "$removed/contract.tmp"
  mv "$removed/contract.tmp" "$removed/$base_contract_rel"
  "$gate" --fixture "$removed" --json > "$TMPROOT/touches-removed.json" 2>&1
  if [ "$(jq -r '.checks[] | select(.id=="touches-widened") | .status' "$TMPROOT/touches-removed.json")" = pass ] \
     && ! jq -e --arg path "$errors_path" \
          '.checks[] | select(.id=="touches-widened") | .evidence | contains($path)' \
          "$TMPROOT/touches-removed.json" >/dev/null; then
    ok "touches-removal-is-not-widening"
  else
    bad "touches-removal-is-not-widening" \
        "a path present only in the base Touches list must not be reported as widening"
  fi

  rm -rf "$exempted"; cp -R "$unchanged" "$exempted"
  sed 's#`tests/test_render.py`#`tests/test_render.py`, `docs/decision-log.md`#' \
    "$exempted/$contract_rel" > "$exempted/contract.tmp"
  mv "$exempted/contract.tmp" "$exempted/$contract_rel"
  printf '1\t0\tdocs/decision-log.md\n' >> "$exempted/numstat.tsv"
  "$gate" --fixture "$exempted" --json > "$TMPROOT/touches-exempted.json" 2>&1
  if [ "$(jq -r '.checks[] | select(.id=="touches") | .status' "$TMPROOT/touches-exempted.json")" = pass ] \
     && [ "$(jq -r '.checks[] | select(.id=="touches-widened") | .status' "$TMPROOT/touches-exempted.json")" = pass ] \
     && [ "$(grep -Rhc '^TOUCHES_EXEMPT=' scripts/*.sh | awk '{n+=$1} END {print n+0}')" = 1 ]; then
    ok "touches-widening-shares-exemptions"
  else
    bad "touches-widening-shares-exemptions" \
        "docs/decision-log.md must be exempt from both comparisons through the one TOUCHES_EXEMPT definition"
  fi

  # The gate blocks. This is the property the whole slice turns on, and it is
  # asserted on the exit code rather than on the printed word, because that is
  # what a hook, a CI job and the driver will all read.
  "$gate" --fixture "$prs/pr-8" >/dev/null 2>&1; local rc8=$?
  "$gate" --fixture "$prs/pr-9" >/dev/null 2>&1; local rc9=$?
  if [ "$rc8" = 1 ] && [ "$rc9" = 0 ]; then
    ok "blocks-with-exit-1 (pr-8 blocks, pr-9 clears with warnings)"
  else
    bad "blocks-with-exit-1" \
        "expected pr-8 to exit 1 and pr-9 to exit 0, got $rc8 and $rc9 — a gate that cannot fail a command gates nothing"
  fi

  # F5's fourth state, on a real recording with its rollup emptied. The live
  # window is seconds wide and cannot be recorded after the fact (F52), so this
  # is the one edited input in the fixture set, and it is edited in exactly the
  # way the race produces: checks not registered yet.
  local ci="$TMPROOT/absent-ci"
  rm -rf "$ci"; cp -R "$prs/pr-9" "$ci"
  jq '.statusCheckRollup = []' "$prs/pr-9/pr.json" > "$ci/pr.json"
  "$gate" --fixture "$ci" --json > "$TMPROOT/absent-ci.json" 2>&1; local rcci=$?
  if [ "$rcci" = 1 ] && [ "$(jq -r '.checks[] | select(.id=="ci-state") | .status' "$TMPROOT/absent-ci.json")" = "block" ]; then
    ok "absent-ci-is-not-a-pass (empty rollup blocks, exit 1)"
  else
    bad "absent-ci-is-not-a-pass" \
        "an empty statusCheckRollup must block, never pass (F5) — got exit $rcci, ci-state $(jq -r '.checks[]|select(.id=="ci-state")|.status' "$TMPROOT/absent-ci.json" 2>/dev/null)"
  fi

  # Asymmetry, in one comparison. Fewer scenarios than the contract is spec
  # infidelity and blocks; more is a planner underestimating and only warns.
  # Both sides are read off the same pair of recordings — pr-8 shipped 1 of 5,
  # pr-9 shipped 6 of 5 — so this cannot pass by having no `more` case at all.
  local fewer more
  fewer="$(jq -r '.checks[] | select(.id=="scenario-count") | .status' "$TMPROOT/pr-8.json")"
  more="$(jq -r '.checks[] | select(.id=="scenario-count") | .status' "$TMPROOT/pr-9.json")"
  if [ "$fewer" = block ] && [ "$more" = warn ]; then
    ok "scenario-count-is-asymmetric (1-of-5 blocks, 6-of-5 warns)"
  else
    bad "scenario-count-is-asymmetric" "fewer=$fewer more=$more; expected block and warn"
  fi

  # -- acceptance is immutable on implementation PRs (ADR-0014 D14.3) ------
  #
  # The base/ directory is the separately approved planning tree; tree/ is the
  # implementation head. Each mutation drives the whole prejudge program, so a
  # helper that merely compares two local files cannot make these cases green.
  _frozen_pr_fixture() { # $1=fixture root
    local frozen_root="$1" frozen_base="$1/base"
    rm -rf "$frozen_root"
    mkdir -p "$frozen_base/docs/chunks" "$frozen_base/tests/features"
    cp "$prs/pr-9/pr.json" "$frozen_root/pr.json"
    jq '.number = 7
        | .title = "CHUNK-7: Enforce frozen acceptance"
        | .headRefName = "chunk/7-enforce-frozen-acceptance"
        | .url = "https://github.com/wielas/forgeboard-report/pull/7"' \
      "$frozen_root/pr.json" > "$frozen_root/pr.next.json"
    mv "$frozen_root/pr.next.json" "$frozen_root/pr.json"
    : > "$frozen_root/numstat.tsv"
    cat > "$frozen_base/docs/chunks/graph.json" <<'FROZEN_GRAPH'
[
  {"id":"CHUNK-7","lane":"claude-interactive","depends_on":[]}
]
FROZEN_GRAPH
    cat > "$frozen_base/docs/chunks/CHUNK-7.md" <<'FROZEN_CHUNK'
### CHUNK-7: Frozen acceptance fixture
- **Goal:** Keep approved acceptance immutable during implementation.
- **Milestone:** M1 · **Depends on:** none
- **Serves:** F14, F25 · **Relevant ADRs:** 0014
- **Touches:** `tests/features/chunk_7.feature`, `tests/steps/chunk_7_steps.py`
- **Scenarios:**
  - Given a SQLite source, When the reader runs, Then one real record is returned.
- **Real sources:** `SQLite source` → scenario 1
- **Acceptance:** tests/features/chunk_7.feature
- **Out of scope:** planning amendments.
- **Done when:** the base hash still matches.
- **Lane:** claude-interactive · **Risk:** high
FROZEN_CHUNK
    cat > "$frozen_base/tests/features/chunk_7.feature" <<'FROZEN_FEATURE'
Feature: CHUNK-7 frozen acceptance fixture

  @real-source
  Scenario: Read the approved source
    Given a SQLite source
    When the reader runs
    Then one real record is returned
FROZEN_FEATURE
    "$REPO_ROOT/scripts/acceptance-freeze.sh" "$frozen_base" >/dev/null 2>&1 \
      || return 1
    mkdir -p "$frozen_root/tree"
    cp -R "$frozen_base/." "$frozen_root/tree/"
  }

  local frozen_changed="$TMPROOT/frozen-changed" frozen_json frozen_status frozen_rc
  if _frozen_pr_fixture "$frozen_changed"; then
    printf '\n# implementation rewrote approved bytes\n' \
      >> "$frozen_changed/tree/tests/features/chunk_7.feature"
    printf '1\t0\ttests/features/chunk_7.feature\n' > "$frozen_changed/numstat.tsv"
    "$gate" --fixture "$frozen_changed" --json > "$TMPROOT/frozen-changed.json" 2>&1
    frozen_rc=$?
    frozen_status="$(jq -r '.checks[] | select(.id=="acceptance-freeze") | .status' \
      "$TMPROOT/frozen-changed.json" 2>/dev/null)"
    if [ "$frozen_rc" = 1 ] && [ "$frozen_status" = block ] \
       && jq -e '.checks[] | select(.id=="acceptance-freeze")
            | .evidence | contains("tests/features/chunk_7.feature")' \
          "$TMPROOT/frozen-changed.json" >/dev/null 2>&1; then
      ok "frozen-feature-blocks-change"
    else
      bad "frozen-feature-blocks-change" \
          "prejudge must block and name tests/features/chunk_7.feature when its bytes differ from the approved base (exit $frozen_rc, status ${frozen_status:-missing})"
    fi
  else
    bad "frozen-feature-blocks-change" "could not create the frozen-acceptance fixture"
  fi

  local frozen_contract="$TMPROOT/frozen-contract"
  if _frozen_pr_fixture "$frozen_contract"; then
    sed -i.bak 's/Then one real record is returned\./Then a warning may be returned./' \
      "$frozen_contract/tree/docs/chunks/CHUNK-7.md"
    rm -f "$frozen_contract/tree/docs/chunks/CHUNK-7.md.bak"
    printf '1\t1\tdocs/chunks/CHUNK-7.md\n' > "$frozen_contract/numstat.tsv"
    "$gate" --fixture "$frozen_contract" --json \
      > "$TMPROOT/frozen-contract.json" 2>&1
    frozen_rc=$?
    frozen_status="$(jq -r '.checks[] | select(.id=="acceptance-freeze") | .status' \
      "$TMPROOT/frozen-contract.json" 2>/dev/null)"
    if [ "$frozen_rc" = 1 ] && [ "$frozen_status" = block ] \
       && jq -e '.checks[] | select(.id=="acceptance-freeze")
            | .evidence | contains("docs/chunks/CHUNK-7.md")' \
          "$TMPROOT/frozen-contract.json" >/dev/null 2>&1; then
      ok "frozen-contract-blocks-change"
    else
      bad "frozen-contract-blocks-change" \
          "a contract-only Then weakening must block and name docs/chunks/CHUNK-7.md (exit $frozen_rc, status ${frozen_status:-missing})"
    fi
  else
    bad "frozen-contract-blocks-change" "could not create the frozen-acceptance fixture"
  fi

  local frozen_redirect="$TMPROOT/frozen-contract-redirect"
  if _frozen_pr_fixture "$frozen_redirect"; then
    sed -i.bak 's#tests/features/chunk_7.feature#tests/features/weaker.feature#' \
      "$frozen_redirect/tree/docs/chunks/CHUNK-7.md"
    rm -f "$frozen_redirect/tree/docs/chunks/CHUNK-7.md.bak"
    printf '1\t1\tdocs/chunks/CHUNK-7.md\n' > "$frozen_redirect/numstat.tsv"
    "$gate" --fixture "$frozen_redirect" --json \
      > "$TMPROOT/frozen-contract-redirect.json" 2>&1
    frozen_rc=$?
    frozen_status="$(jq -r '.checks[] | select(.id=="acceptance-freeze") | .status' \
      "$TMPROOT/frozen-contract-redirect.json" 2>/dev/null)"
    if [ "$frozen_rc" = 1 ] && [ "$frozen_status" = block ] \
       && jq -e '.checks[] | select(.id=="acceptance-freeze")
            | .evidence | contains("docs/chunks/CHUNK-7.md")' \
          "$TMPROOT/frozen-contract-redirect.json" >/dev/null 2>&1; then
      ok "frozen-contract-blocks-acceptance-redirect"
    else
      bad "frozen-contract-blocks-acceptance-redirect" \
          "redirecting only the contract Acceptance path must block (exit $frozen_rc, status ${frozen_status:-missing})"
    fi
  else
    bad "frozen-contract-blocks-acceptance-redirect" \
        "could not create the frozen-acceptance fixture"
  fi

  local frozen_steps="$TMPROOT/frozen-steps"
  if _frozen_pr_fixture "$frozen_steps"; then
    mkdir -p "$frozen_steps/tree/tests/steps"
    printf 'def given_the_source():\n    return "ready"\n' \
      > "$frozen_steps/tree/tests/steps/chunk_7_steps.py"
    printf '2\t0\ttests/steps/chunk_7_steps.py\n' > "$frozen_steps/numstat.tsv"
    "$gate" --fixture "$frozen_steps" --json > "$TMPROOT/frozen-steps.json" 2>&1
    frozen_status="$(jq -r '.checks[] | select(.id=="acceptance-freeze") | .status' \
      "$TMPROOT/frozen-steps.json" 2>/dev/null)"
    if [ "$frozen_status" = pass ]; then
      ok "frozen-feature-allows-step-definitions"
    else
      bad "frozen-feature-allows-step-definitions" \
          "adding only tests/steps/chunk_7_steps.py must pass the frozen-feature check (status ${frozen_status:-missing})"
    fi
  else
    bad "frozen-feature-allows-step-definitions" "could not create the frozen-acceptance fixture"
  fi

  local frozen_self="$TMPROOT/frozen-self"
  if _frozen_pr_fixture "$frozen_self"; then
    printf '\n# implementation rewrote and rehashed approved bytes\n' \
      >> "$frozen_self/tree/tests/features/chunk_7.feature"
    "$REPO_ROOT/scripts/acceptance-freeze.sh" "$frozen_self/tree" >/dev/null 2>&1
    printf '1\t0\ttests/features/chunk_7.feature\n1\t1\tdocs/chunks/contract-freeze.json\n' \
      > "$frozen_self/numstat.tsv"
    "$gate" --fixture "$frozen_self" --json > "$TMPROOT/frozen-self.json" 2>&1
    frozen_rc=$?
    frozen_status="$(jq -r '.checks[] | select(.id=="acceptance-freeze") | .status' \
      "$TMPROOT/frozen-self.json" 2>/dev/null)"
    if [ "$frozen_rc" = 1 ] && [ "$frozen_status" = block ]; then
      ok "frozen-feature-blocks-self-amendment"
    else
      bad "frozen-feature-blocks-self-amendment" \
          "regenerating contract-freeze.json on the implementation head must still block against the approved base (exit $frozen_rc, status ${frozen_status:-missing})"
    fi
  else
    bad "frozen-feature-blocks-self-amendment" "could not create the frozen-acceptance fixture"
  fi

  local frozen_amended="$TMPROOT/frozen-amended"
  if _frozen_pr_fixture "$frozen_amended"; then
    printf '\n# separately approved planning amendment\n' \
      >> "$frozen_amended/base/tests/features/chunk_7.feature"
    "$REPO_ROOT/scripts/acceptance-freeze.sh" "$frozen_amended/base" >/dev/null 2>&1
    rm -rf "$frozen_amended/tree"
    mkdir -p "$frozen_amended/tree/tests/steps"
    cp -R "$frozen_amended/base/." "$frozen_amended/tree/"
    printf 'def given_the_amended_source():\n    return "ready"\n' \
      > "$frozen_amended/tree/tests/steps/chunk_7_steps.py"
    printf '2\t0\ttests/steps/chunk_7_steps.py\n' > "$frozen_amended/numstat.tsv"
    "$gate" --fixture "$frozen_amended" --json > "$TMPROOT/frozen-amended.json" 2>&1
    frozen_status="$(jq -r '.checks[] | select(.id=="acceptance-freeze") | .status' \
      "$TMPROOT/frozen-amended.json" 2>/dev/null)"
    if [ "$frozen_status" = pass ]; then
      ok "frozen-feature-accepts-planning-amendment"
    else
      bad "frozen-feature-accepts-planning-amendment" \
          "an implementation branch matching its already-amended base must pass (status ${frozen_status:-missing})"
    fi
  else
    bad "frozen-feature-accepts-planning-amendment" "could not create the frozen-acceptance fixture"
  fi

  if grep -Fq 'contract-freeze.json' skills/judge/SKILL.md \
     && grep -Fq '@real-source' skills/judge/SKILL.md \
     && grep -Fq 'scored acceptance surface' skills/judge/SKILL.md; then
    ok "judge-scores-frozen-real-source"
  else
    bad "judge-scores-frozen-real-source" \
        "/judge must read the frozen manifest and keep every @real-source scenario in the scored acceptance surface"
  fi

  # A check that could not run has not passed. If skip collapsed into pass the
  # gate would repeat F5's exact mistake in a new place — and it did, once:
  # `then-asserts` reported `pass` against a tree with no Python in it, having
  # examined nothing. Asserted on behaviour now, not on the source.
  if [ "$(jq -r '[.checks[] | select(.status=="skip")] | length' "$TMPROOT/pr-8.json")" -ge 1 ] \
     && [ "$(jq -r '.counts.pass' "$TMPROOT/pr-8.json")" -ge 1 ] \
     && [ "$(jq -r '.result' "$TMPROOT/pr-9.json")" = clear ]; then
    ok "skip-is-distinguishable-from-pass"
  else
    bad "skip-is-distinguishable-from-pass" \
        "the result must count skip separately from pass and block only on block"
  fi

  # The bounce contract, applied to a program. The gate's findings are copied
  # verbatim into the repair card, so a blocking finding with no executable
  # action produces an unworkable card. Every block, on every fixture, must
  # carry one — and it must be an instruction, not a restatement.
  local noaction=""
  for name in pr-8 absent-ci; do
    jq -e '[.checks[] | select(.status=="block") | select((.action // "") | length < 40)] | length == 0' \
      "$TMPROOT/$name.json" >/dev/null 2>&1 || noaction="$noaction $name"
  done
  [ -z "$noaction" ] && ok "emits-an-action-per-block" \
    || bad "emits-an-action-per-block" "blocking findings with no executable action:$noaction"

  # `forge.gate.v1`, not a scored `forge.judge.v1` with five invented numbers in
  # it. A gate block at zero model tokens and a bounce after a full review are
  # different events, and the SOUL's own argument against a zeroed cost object
  # is the argument against a zeroed score object.
  if [ "$(jq -r .schema "$TMPROOT/pr-8.json")" = "forge.gate.v1" ] \
     && jq -e '(.scores // null) == null and (.verdict // null) == null' "$TMPROOT/pr-8.json" >/dev/null; then
    ok "emits-its-own-shape-not-the-verdict-schema"
  else
    bad "emits-its-own-shape-not-the-verdict-schema" \
        "$gate must emit forge.gate.v1 and must not score dimensions or assert a verdict"
  fi

  # The gate is a STAGE, not a replacement. S4's predecessor deleted tier 1's
  # model call on the strength of 0-bounces-in-17, a number produced by a prompt
  # that told the model to pass anything subtler than obvious through. That
  # deletion was cancelled: the call is the control arm S5 measures against, and
  # a control somebody quietly removed is worse than one somebody tuned. The
  # gate itself must contain no model call, and the protocol exactly one.
  local gate_exec review=scripts/prejudge-review.sh
  gate_exec="$(grep -vE '^[[:space:]]*#' "$gate")"
  if printf '%s' "$gate_exec" | grep -qE '(^|[^-[:alnum:]])(claude|codex)([[:space:]]+-|[[:space:]]+exec)'; then
    bad "gate-is-a-stage-not-a-replacement" \
        "a model invocation appeared inside the gate itself — the gate is the deterministic stage (ADR-0009 D9.1)"
  elif [ "$(grep -c -- '^   raw="$(claude -p --model opus --output-format json \\$' "$review")" = 1 ]; then
    ok "gate-is-a-stage-not-a-replacement (gate has no model call; the scorer survives in $review)"
  else
    bad "gate-is-a-stage-not-a-replacement" \
        "the tier-1 scorer call is gone from $review — ADR-0007 D7.1 stands and ADR-0009 does not supersede it; deleting it is S5's experiment, not this gate's side effect"
  fi

  # -------------------------------------------------------------------------
  # THE CONTROL ARM, PINNED (ADR-0009 D9.5, ADR-0010).
  #
  # ADR-0010 moved tier 1's protocol out of a 404-line system prompt and into a
  # program. That move carried the `claude -p --model opus` invocation and its
  # stamping `jq` with it, and those bytes are S5's experimental baseline: S5
  # measures candidate tier-1 mandates against what this call does today, so a
  # baseline somebody edited in passing is not a baseline.
  #
  # The baseline is a RECORDED FIXTURE, not a branch (F65). It used to be
  # `git show main:hermes/profiles/forge-prejudge.SOUL.md`, which was correct
  # for exactly as long as the arm lived in that SOUL. ADR-0010 moved it into
  # this script — so the moment ADR-0010 merged, main's SOUL stopped containing
  # the block, `arm_extract` returned empty, and this case began reporting
  # `skip: main has no pinned scorer block to compare`. It went inert at the
  # merge that created it, and a skip is quiet. ADR-0010 D10.5's claim that
  # moving the bytes made the control *stronger* because they are "pinned by a
  # test" was true on the branch and false one commit later.
  #
  # Hence: compare against `scripts/fixtures/control-arm.txt`, recorded from
  # `6b4c419:hermes/profiles/forge-prejudge.SOUL.md` — the last commit whose
  # SOUL still carried the arm — and verified byte-identical to the bytes
  # ADR-0010 moved. A fixture cannot drift out from under the check the way a
  # branch can.
  #
  # NOTHING HERE MAY SKIP. A control that cannot find its baseline is not a
  # passing control, it is a failing one; that is the whole lesson of F65. Both
  # the missing-fixture and the empty-extraction paths call bad(), so deleting
  # either side of the comparison fails the suite instead of silencing it.
  #
  # Whitespace counts: the three-space indent is inherited from the markdown
  # list item the block came out of, and reindenting it would be an undeclared
  # edit to the control arm.
  # -------------------------------------------------------------------------
  local arm_base arm_now baseline=scripts/fixtures/control-arm.txt
  arm_extract() {
    sed -n '/^   STAMPED=/,/judge-verdict\.schema\.json)"$/p' "$1"
    sed -n '/^   raw="\$(claude -p --model opus/,/^   .)"$/p' "$1"
  }
  arm_now="$(arm_extract "$review")"
  if [ ! -f "$baseline" ]; then
    bad "scorer-is-the-control-arm" \
        "$baseline is missing — S5's baseline is unrecorded, so nothing can be measured against it (F65)"
  elif [ -z "$arm_now" ]; then
    bad "scorer-is-the-control-arm" \
        "no scorer block found in $review — the arm was renamed, reindented or deleted, and this check must fail rather than skip (F65)"
  else
    arm_base="$(cat "$baseline")"
    if [ "$arm_base" = "$arm_now" ]; then
      ok "scorer-is-the-control-arm ($(printf '%s\n' "$arm_now" | wc -l | tr -d ' ') lines byte-identical to the recorded baseline)"
    else
      bad "scorer-is-the-control-arm" \
          "the scorer call in $review differs from $baseline — it is S5's baseline and may be moved but not modified (ADR-0009 D9.5)"
    fi
  fi

  # -------------------------------------------------------------------------
  # The protocol, EXECUTED. These cases replace eleven substring matches against
  # a system prompt (F63). `--dry-run` stops after the gate and the prompt
  # assembly, so no model is spawned and no board is touched; with `--fixture`
  # there is no gh, no git and no network either.
  # -------------------------------------------------------------------------
  local prs=scripts/fixtures/prejudge-prs
  local contract='CHUNK-5: render the canonical report

- **Touches:** `src/forgeboard_report/domain.py`
- **Scenarios:** 3'

  # A blocked PR routes to a bounce WITHOUT scoring: the whole saving is that
  # nothing is spawned. The action names the outcome, and the stored metadata is
  # the gate object, never a manufactured verdict.
  local b8
  b8="$(printf '%s' "$contract" | "$review" https://example.invalid/pull/8 \
        --chunk t_fixture --fixture "$prs/pr-8" --dry-run 2>/dev/null)"
  if printf '%s' "$b8" | jq -e '
        .action == "gate-block"
        and .metadata.schema == "forge.gate.v1"
        and ((.metadata.blocks | sort) == ["branch-name","scenario-count"])
        and (.metadata | has("scores") | not)
        and .created_cards == []' >/dev/null 2>&1; then
    ok "review-routes-by-gate-result (a block bounces with no model spawned)"
  else
    bad "review-routes-by-gate-result" \
        "$review must route a gate block to a bounce carrying the forge.gate.v1 object and no verdict"
  fi

  # The envelope is the entire contract between the program and the model, so
  # every field the terminator needs must be present and typed.
  local c9
  c9="$(printf '%s' "$contract" | "$review" https://example.invalid/pull/9 \
        --chunk t_fixture --fixture "$prs/pr-9" --dry-run 2>/dev/null)"
  if printf '%s' "$c9" | jq -e '
        .schema == "forge.review.v1"
        and .action == "would-score"
        and ((.summary | type) == "string")
        and (.reason == null)
        and ((.created_cards | type) == "array")
        and (.metadata.gate.result == "clear")' >/dev/null 2>&1; then
    ok "review-emits-a-terminator-envelope"
  else
    bad "review-emits-a-terminator-envelope" \
        "$review must emit one forge.review.v1 object carrying action, summary, reason, metadata and created_cards"
  fi

  # F32's rule, finally measured instead of asserted. The driver is the only
  # metered agent in a review; the engine it feeds is OAuth. A diff rendered
  # into the driver's context is billed to it and then sent, free, to the model
  # that actually needed it. pr-9 carries a recorded 63 KB patch, so if any of
  # it reaches stdout this fails on hunk headers rather than on a promise.
  local body_bytes prompt_bytes env_bytes
  if [ ! -s "$prs/pr-9/diff.patch" ]; then
    skip "review-never-prints-the-diff" "no recorded diff in the pr-9 fixture"
  elif printf '%s' "$c9" | grep -qE '^\+\+\+ |diff --git|@@ .* @@'; then
    bad "review-never-prints-the-diff" \
        "diff content reached stdout — the metered driver must observe a byte count, never the patch"
  else
    prompt_bytes="$(printf '%s' "$c9" | jq -r '.metadata.prompt_bytes')"
    env_bytes="$(printf '%s' "$c9" | wc -c | tr -d ' ')"
    body_bytes="$(wc -c < "$prs/pr-9/diff.patch" | tr -d ' ')"
    if [ "$prompt_bytes" -gt "$body_bytes" ] && [ "$env_bytes" -lt 8000 ]; then
      ok "review-never-prints-the-diff (${body_bytes}B moved, ${env_bytes}B observed)"
    else
      bad "review-never-prints-the-diff" \
          "the ${body_bytes}B patch must reach the prompt file and not the envelope (prompt=${prompt_bytes}B, envelope=${env_bytes}B)"
    fi
  fi

  # The model was required to produce five fields the operator overwrote a
  # moment later — which is where the invented `claude-opus-4-8` came from. Not
  # asking is a better fix than overwriting. Run the protocol's own reduction
  # rather than a copy of it, so this cannot pass against a transform that has
  # drifted.
  local jq_prog reduced
  jq_prog="$(sed -n '/VERDICT_SCHEMA="\$(jq -c --argjson stamped/,/judge-verdict\.schema\.json)"/p' \
               "$review" | sed '1d;$d')"
  if ! command -v jq >/dev/null 2>&1; then
    skip "schema-hides-stamped-fields" "jq not on PATH"
  elif [ -z "$jq_prog" ]; then
    bad "schema-hides-stamped-fields" \
        "could not find the model-facing schema reduction in $review"
  elif reduced="$(jq -c --argjson stamped \
        '["pr","judge_model","tokens_estimate","cost","session_id"]' \
        "$jq_prog" rubrics/judge-verdict.schema.json 2>/dev/null)" \
    && grep -Fq "STAMPED='[\"pr\",\"judge_model\",\"tokens_estimate\",\"cost\",\"session_id\"]'" "$review" \
    && printf '%s' "$reduced" | jq -e --argjson stamped \
         '["pr","judge_model","tokens_estimate","cost","session_id"]' '
           (has("$schema") | not)
           and (((.properties | keys) - $stamped) == (.properties | keys))
           and ((.required - $stamped) == .required)
           and (.required | index("verdict"))
         ' >/dev/null 2>&1; then
    ok "schema-hides-stamped-fields"
  else
    bad "schema-hides-stamped-fields" \
        "the schema handed to --json-schema must drop pr/judge_model/tokens_estimate/cost/session_id from BOTH properties and required"
  fi

  # The stored verdict must be ABLE to carry what the operator stamps, and must
  # not demand it: cost is absent on a gate block, which has no model call to
  # measure. cache_read_input_tokens is required *within* cost because without
  # it F21's cache-hostility claim, and every saving proposed against it, is
  # unfalsifiable.
  #
  # `tokens_estimate` USED TO BE REQUIRED HERE, and the rubric one directory up
  # said in the same breath that it is stamped by the harness and never produced
  # by the model. Both could not stand: it comes off the same usage envelope
  # `cost` does, so on the paths where cost cannot be stamped — an interactive
  # tier-2 review reports no usage at all — the required field had no permitted
  # author. On 2026-09-02 that refused a completed, paid-for review at the root
  # checkpoint. It is optional in the schema and stamped on every tier-1 review
  # by scripts/prejudge-review.sh, which is where a producer obligation belongs;
  # prejudge/scorer-is-the-control-arm still pins the line that stamps it.
  #
  # `worker_session_id` is the mirror image: declared so the substrate's stamp
  # survives additionalProperties:false, and optional because a tier-2 verdict
  # written by hand has no Hermes run behind it.
  if ! command -v jq >/dev/null 2>&1; then
    skip "cost-is-storable" "jq not on PATH"
  elif jq -e '
      (.properties.cost.required | index("cache_read_input_tokens"))
      and (.properties.cost.required | index("total_cost_usd"))
      and (.properties.session_id.type == "string")
      and (.properties.worker_session_id.type == "string")
      and ((.required | index("cost")) == null)
      and ((.required | index("session_id")) == null)
      and ((.required | index("worker_session_id")) == null)
      and ((.required | index("tokens_estimate")) == null)
      and (.properties.tokens_estimate.type == "integer")
    ' rubrics/judge-verdict.schema.json >/dev/null 2>&1; then
    ok "cost-is-storable"
  else
    bad "cost-is-storable" \
        "judge-verdict.schema.json must accept cost/session_id/worker_session_id/tokens_estimate as OPTIONAL but storable, and require cache_read_input_tokens inside cost"
  fi

  # -------------------------------------------------------------------------
  # THE VERDICT, DERIVED (audit F29, shadow mode).
  #
  # judge-rubric.md has always stated the verdict logic as four rules over the
  # scores. Nothing computed them: the model was asked for `verdict` beside the
  # scores it also produced, so a verdict that did not follow from its own
  # numbers was undetectable. scripts/verdict.sh is those rules as a program,
  # and this is the table it must reproduce — written as cases, because a
  # decision table asserted in prose is what F29 already is.
  # -------------------------------------------------------------------------
  local vs=scripts/verdict.sh

  # SOURCING MUST NOT REWRITE THE CALLER'S SHELL. prejudge-review.sh runs
  # `set -uo pipefail` and deliberately not `-e`: ADR-0010 gives it an exit-code
  # contract (0 routed, 2 usage, 3 substrate, 1 unused precisely so a caller
  # under errexit cannot read a bounce as a crash) and it handles non-zero
  # returns itself. A sourced library that switched errexit on would rewrite the
  # control flow of every line after the source.
  #
  # No --dry-run case can catch this: the shadow stage runs only after a real
  # model call, so the source line is never reached offline. Hence a direct
  # assertion on the shell state, in a subshell so the answer is not the
  # verifier's own options.
  if [ "$(bash -c 'set +e; . '"$vs"'; case "$-" in *e*) echo ERREXIT;; *) echo clean;; esac')" = "clean" ] \
     && [ "$(bash -c 'set +u; . '"$vs"'; case "$-" in *u*) echo NOUNSET;; *) echo clean;; esac')" = "clean" ]; then
    ok "deriver-sources-without-side-effects"
  else
    bad "deriver-sources-without-side-effects" \
        "$vs changes the caller's shell options — prejudge-review.sh runs without errexit on purpose (ADR-0010's exit-code contract)"
  fi

  # shellcheck source=scripts/verdict.sh
  . "$vs"
  _sc() { # build a scores object from six digits
    printf '{"spec_fidelity":%s,"scenario_integrity":%s,"architectural_conformance":%s,"scope_discipline":%s,"debt_honesty":%s,"doc_reconciliation":%s}' \
      "${1:0:1}" "${1:1:1}" "${1:2:1}" "${1:3:1}" "${1:4:1}" "${1:5:1}"
  }
  _env() { printf '{"verdict":"%s","scores":%s,"findings":%s}' "$2" "$(_sc "$1")" "$3"; }

  local dv_ok=1 got want
  # scores | findings | expected derivation
  while IFS='|' read -r sc f want; do
    [ -z "$sc" ] && continue
    got="$(derive_verdict "$(_env "$sc" approve "$f")" 2>/dev/null)" || got="ERR"
    if [ "$got" != "$want" ]; then
      bad "verdict-derives-from-scores" "scores $sc findings $f -> '$got', rubric says '$want'"
      dv_ok=0; break
    fi
  done <<'TABLE'
333333|[]|approve
333332|[{"dimension":"doc_reconciliation","severity":"nit"}]|approve
323333|[{"dimension":"scenario_integrity","severity":"fix"}]|approve
333033|[{"dimension":"scope_discipline","severity":"block"}]|bounce
313333|[{"dimension":"scenario_integrity","severity":"nit"}]|approve-with-nits
313333|[{"dimension":"scenario_integrity","severity":"fix"}]|bounce
313333|[{"dimension":"scenario_integrity","severity":"block"}]|bounce
333331|[{"dimension":"doc_reconciliation","severity":"nit"}]|approve-with-nits
313333|[]|ERR
333332|[]|ERR
TABLE
  [ "$dv_ok" = 1 ] && ok "verdict-derives-from-scores (10 cases incl. the two unevidenced)"

  # A dimension scored below 3 that names no finding is INVALID, not a nit. The
  # schema says so in a `description`, where no validator reads it. Without the
  # check, rule 3 is vacuously true — `all` over an empty list — so the least
  # evidenced verdict possible would derive to approve-with-nits. The two ERR
  # rows above are that case; this asserts the exit code that carries it.
  if derive_verdict "$(_env 313333 approve '[]')" >/dev/null 2>&1; then
    bad "unevidenced-score-is-not-a-verdict" \
        "a dimension scored 1 with no finding derived a verdict instead of failing"
  else
    ok "unevidenced-score-is-not-a-verdict (exit $?)"
  fi

  # PROMOTED. The derived verdict routes; the model's own word is recorded and
  # no longer decides. The model must still be ASKED for `verdict` — that is
  # what keeps divergence measurable post-gate — so this asserts both halves:
  # divergence is still recorded, and routing reads the derived field.
  local stamped
  stamped="$(stamp_shadow "$(_env 333233 approve-with-nits '[{"dimension":"scope_discipline","severity":"nit"}]')")"
  if [ "$(printf '%s' "$stamped" | jq -r '.verdict')" = "approve-with-nits" ] \
     && [ "$(printf '%s' "$stamped" | jq -r '.derived_verdict')" = "approve" ] \
     && [ "$(printf '%s' "$stamped" | jq -r '.verdict_divergence')" = "true" ] \
     && grep -q 'case "\$VERDICT" in' scripts/prejudge-review.sh \
     && grep -q "VERDICT=\"\\\$(jq -r '\.derived_verdict // \.verdict'" scripts/prejudge-review.sh; then
    ok "derived-verdict-routes (divergence recorded, derived value routes)"
  else
    bad "derived-verdict-routes" \
        "routing must read .derived_verdict (falling back to .verdict), and divergence must still be recorded"
  fi

  # THE FALLBACK IS THE WHOLE SAFETY PROPERTY OF THE PROMOTION. `derived_verdict`
  # is null on two paths — the stamp could not be applied, or derivation itself
  # failed — and a bare `jq -r '.derived_verdict'` returns the STRING "null" on
  # both, which Stage 5's case statement sends to `*)` and substrate(). That is
  # the PR #14 bug rebuilt one line lower. Asserted on the real file, driving
  # the same jq the script runs, for both null shapes: key absent, key null.
  local fb_absent fb_null fb_ok=1
  fb_absent="$(printf '%s' '{"verdict":"bounce","findings":[]}' | jq -r '.derived_verdict // .verdict')"
  fb_null="$(printf '%s' '{"verdict":"approve","derived_verdict":null,"verdict_derivation_error":"x"}' \
             | jq -r '.derived_verdict // .verdict')"
  [ "$fb_absent" = "bounce" ] || fb_ok=0
  [ "$fb_null" = "approve" ]  || fb_ok=0
  # ...and the routed value must be one Stage 5 can actually dispatch.
  case "$fb_absent" in approve|approve-with-nits|bounce) ;; *) fb_ok=0;; esac
  case "$fb_null"   in approve|approve-with-nits|bounce) ;; *) fb_ok=0;; esac
  if [ "$fb_ok" = 1 ]; then
    ok "undecidable-derivation-falls-back-to-the-scorer (both null shapes route, neither reaches substrate)"
  else
    bad "undecidable-derivation-falls-back-to-the-scorer" \
        "a null derived_verdict must fall back to .verdict; got '$fb_absent' / '$fb_null' — an unroutable value reaches substrate() and reports a completed review as an outage"
  fi

  # The model IS shown these three fields, because the model-facing schema is
  # judge-verdict.schema.json minus STAMPED, and STAMPED is inside the pinned
  # control arm and may not be edited until D9.5's experiment concludes. So the
  # stamp has to be unconditional: a value the model invented must not survive.
  # Adding the three to STAMPED belongs with the `verdict` exclusion.
  local invented
  invented="$(stamp_shadow '{"verdict":"approve","scores":'"$(_sc 333333)"',"findings":[],"derived_verdict":"bounce","verdict_divergence":true,"verdict_derivation_error":"invented"}')"
  if [ "$(printf '%s' "$invented" | jq -r '.derived_verdict')" = "approve" ] \
     && [ "$(printf '%s' "$invented" | jq -r '.verdict_divergence')" = "false" ] \
     && [ "$(printf '%s' "$invented" | jq -r 'has("verdict_derivation_error")')" = "false" ]; then
    ok "shadow-fields-are-stamped-never-trusted"
  else
    bad "shadow-fields-are-stamped-never-trusted" \
        "a model-supplied derived_verdict survived the stamp — it must be overwritten unconditionally"
  fi

  # SHADOW MUST NOT BE ABLE TO DESTROY A REVIEW. The first version of this
  # stage stamped into a temp file and mv'd it over the verdict unconditionally.
  # When the stamp came back empty the verdict was truncated to zero bytes,
  # `.verdict` read null, and Stage 5's routing case fell through to `*)` and
  # called substrate() — a completed, paid-for review reported as an
  # infrastructure outage because a SHADOW record could not be computed. The
  # empty path also returns 0, so no exit-code check would have caught it.
  #
  # Adversarial input: bytes that are not JSON. derive_verdict cannot parse
  # them, and neither can the error branch that runs over the same bytes, so
  # stamp_shadow emits nothing at all.
  local sdir vf
  sdir="$TMPROOT/shadow"; mkdir -p "$sdir"; vf="$sdir/verdict.json"

  printf 'not json at all' > "$vf"
  stamp_shadow_file "$vf" >/dev/null 2>&1
  if [ "$(cat "$vf")" = "not json at all" ]; then
    ok "shadow-never-destroys-the-verdict (unstampable input leaves the file intact)"
  else
    bad "shadow-never-destroys-the-verdict" \
        "an unstampable verdict was overwritten — a completed review would route to substrate"
  fi

  # stamp_shadow must REPORT the empty case rather than merely not printing.
  # `rm -f` as a function's last statement returns 0 and hides it.
  if stamp_shadow 'not json at all' >/dev/null 2>&1; then
    bad "stamp-reports-its-own-failure" \
        "stamp_shadow returned 0 while emitting nothing — a caller cannot tell that from success"
  else
    ok "stamp-reports-its-own-failure"
  fi

  # The stage must not need a writable TMPDIR. The Hermes worker's environment
  # is not this shell's, and an earlier version opened `err="$(mktemp)"` then
  # redirected to it — with no writable TMPDIR that is an empty filename and an
  # ambiguous redirect, taking down the one stage whose contract is that it
  # cannot cost a review.
  if [ "$(TMPDIR=/nonexistent-dir stamp_shadow \
            "$(_env 313333 approve '[{"dimension":"scenario_integrity","severity":"nit"}]')" \
          2>/dev/null | jq -r '.derived_verdict')" = "approve-with-nits" ]; then
    ok "shadow-needs-no-writable-tmpdir"
  else
    bad "shadow-needs-no-writable-tmpdir" \
        "stamping failed without a writable TMPDIR — the worker's environment is not the verifier's"
  fi

  # The routing field is the one thing shadow may never touch.
  printf '%s' "$(_env 313333 bounce '[{"dimension":"scenario_integrity","severity":"fix"}]')" > "$vf"
  if stamp_shadow_file "$vf" >/dev/null 2>&1 \
     && [ "$(jq -r '.verdict' "$vf")" = "bounce" ] \
     && [ "$(jq -r '.derived_verdict' "$vf")" = "bounce" ] \
     && [ "$(jq -r '.verdict_divergence' "$vf")" = "false" ]; then
    ok "shadow-preserves-the-routing-field"
  else
    bad "shadow-preserves-the-routing-field" \
        "stamping altered or lost .verdict — shadow adds fields, it never changes the one that routes"
  fi

  # `additionalProperties: false` is the binding constraint on the stored
  # envelope, and there is no JSON Schema validator on this host (no ajv, no
  # python jsonschema), so assert the part that actually bites: every key the
  # stamp writes must be declared in the schema. This is what breaks if a
  # shadow field is added to the envelope and not to judge-verdict.schema.json.
  local stampedout
  stampedout="$(stamp_shadow "$(_env 313333 bounce '[{"dimension":"scenario_integrity","severity":"nit"}]')")"
  if printf '%s' "$stampedout" | jq -e --slurpfile s rubrics/judge-verdict.schema.json '
        ($s[0].properties | keys) as $allowed
      | [keys[] | select(([$allowed[]] | index(.)) == null)] | length == 0
     ' >/dev/null 2>&1; then
    ok "stamped-envelope-declares-every-key"
  else
    bad "stamped-envelope-declares-every-key" \
        "the stamped envelope carries a key judge-verdict.schema.json does not declare, and the schema is additionalProperties:false"
  fi

  # The producer half of 2026-09-02's root-checkpoint refusal, EXECUTED rather
  # than asserted (ADR-0003). The filter is lifted out of the script and run, so
  # this cannot pass against a repair that has drifted or been deleted. Two
  # directions, one line:
  #   - the scorer's absent `nits_as_cards` becomes [], the only thing an
  #     omitted array can honestly mean. It stays a model field and stays
  #     required in the stored envelope; filling an absence is not the overwrite
  #     STAMPED performs.
  #   - a `worker_session_id` the scorer produced does NOT survive. The schema
  #     declares that key for Hermes's own stamp, which also offers it to the
  #     model, and an invented join key is worse than a missing one:
  #     scripts/metrics.sh would join real usage onto a session that never ran.
  local repair repaired_env
  repair="$(sed -n "s/^ *| jq -c '\(.*\)')\"$/\1/p" "$review")"
  if ! command -v jq >/dev/null 2>&1; then
    skip "envelope-is-repaired-before-it-is-stored" "jq not on PATH"
  elif [ -z "$repair" ]; then
    bad "envelope-is-repaired-before-it-is-stored" \
        "no envelope repair found in $review — the 2026-09-02 root-checkpoint refusal is unfixed again"
  elif repaired_env="$(printf '%s' \
        '{"verdict":"approve","worker_session_id":"invented-by-the-scorer"}' \
        | jq -c "$repair" 2>/dev/null)" \
    && printf '%s' "$repaired_env" | jq -e '
         .nits_as_cards == []
         and (has("worker_session_id") | not)
         and .verdict == "approve"
       ' >/dev/null 2>&1; then
    ok "envelope-is-repaired-before-it-is-stored"
  else
    bad "envelope-is-repaired-before-it-is-stored" \
        "the repair must fill an absent nits_as_cards, drop a model-authored worker_session_id, and touch nothing else (got '${repaired_env:-nothing}')"
  fi

  # A BOUNCE IS THE COMMON CASE, and it had never been executed. route_bounce is
  # LIFTED OUT of the script and RUN against real Hermes in an isolated home,
  # because the only consumer that can say whether its `--workspace` argument is
  # legal is the CLI that parses it — asserting the argument's shape here would
  # just be a second opinion about a rule Hermes owns.
  #
  # Measured 2026-09-02 on JobApp: route_bounce passed a BARE PATH. `--workspace`
  # names a kind (`scratch`, `worktree`, `worktree:<path>`, `dir:<path>`), so
  # Hermes exited 2 with "unknown --workspace value" before it opened the board,
  # the create emitted no id, route_bounce returned 1, and the caller raised
  # `other: handoff-integrity` — which destroyed a real tier-1 verdict, recovered
  # only by re-running the deterministic gate by hand. Every bounce whose parent
  # chunk ran in a worktree failed exactly this way.
  local bounce_home="$TMPROOT/bounce-home" bounce_ws="$TMPROOT/bounce-ws"
  local bounce_fix bounce_rc
  if ! command -v hermes >/dev/null 2>&1; then
    skip "bounce-card-lands-in-the-rejected-worktree" "hermes not on PATH"
  else
    mkdir -p "$bounce_home" "$bounce_ws"
    git -C "$bounce_ws" init -q 2>/dev/null
    bounce_fix="$(
      export HERMES_HOME="$bounce_home" HERMES_KANBAN_BOARD=bouncelab
      hermes kanban init >/dev/null 2>&1 || true
      hermes kanban boards create bouncelab >/dev/null 2>&1 || true
      BOARD=bouncelab
      PR_URL="https://example.invalid/pull/1"
      HERMES_KANBAN_TASK=bounce-probe
      CREATED=()
      kanban() { hermes kanban --board "$BOARD" "$@"; }
      board_live() { return 0; }
      substrate() { printf 'substrate: %s\n' "$1" >&2; return 1; }
      # The completed chunk, in the worktree its rejected PR branch sits in.
      CHUNK="$(kanban create "chunk under review" --assignee forge-codex-lane \
                 --workspace "dir:$bounce_ws" --idempotency-key chunk-probe \
                 --json 2>/dev/null | jq -r '.id')"
      [ -n "$CHUNK" ] && [ "$CHUNK" != null ] || exit 1
      eval "$(sed -n '/^route_bounce() {/,/^}$/p' "$review")"
      route_bounce "- **branch-name** — evidence" "gate blocked: branch-name" || exit 1
      printf '%s\n' "${CREATED[0]:-}"
    )"; bounce_rc=$?
    if [ "$bounce_rc" = 0 ] && [ -n "$bounce_fix" ] \
       && HERMES_HOME="$bounce_home" hermes kanban --board bouncelab \
            show "$bounce_fix" --json 2>/dev/null \
          | jq -e --arg ws "$bounce_ws" '
              .task.workspace_kind == "dir" and .task.workspace_path == $ws
              and (.task.skills | index("forge-lane")) != null' >/dev/null 2>&1; then
      ok "bounce-card-lands-in-the-rejected-worktree (real Hermes, isolated home)"
    else
      bad "bounce-card-lands-in-the-rejected-worktree" \
          "route_bounce must create a fix card Hermes accepts and reads back as dir@<chunk worktree> with forge-lane; rc $bounce_rc, card '${bounce_fix:-none}'"
    fi
  fi

  # The caller must use the guarded entry point, not the raw two lines.
  if grep -q 'stamp_shadow_file "\$TMP/verdict.json"' scripts/prejudge-review.sh \
     && ! grep -q 'mv "\$TMP/v2.json"' scripts/prejudge-review.sh; then
    ok "review-uses-the-guarded-stamp"
  else
    bad "review-uses-the-guarded-stamp" \
        "prejudge-review.sh must call stamp_shadow_file; an unguarded mv can truncate the verdict"
  fi
}
wants prejudge  && run_prejudge_group

# ---------------------------------------------------------------------------
# sweep/ — durability of what the Forge stamps, and reclamation of what it
# leaves behind. Both halves are regressions of measured failures:
#
#   F19 — the first real product the Forge built was stamped into /private/tmp,
#         which macOS purges and Spotlight does not index. It took a filesystem
#         sweep to find it. Cause: `DEST ?= ..`, a relative default resolved
#         against wherever the operator was standing.
#   F18 — every finished chunk leaves <project>/.worktrees/<task-id>, a full
#         checkout plus a .venv at 50 MB, holding its branch, so
#         `gh pr merge --delete-branch` fails every time.
#
# The fixture builds real git worktrees and stubs `gh` on PATH, because "merged"
# has to be answered from the remote: a squash merge leaves no local ancestry,
# so any local heuristic reports every squash-merged chunk as unmerged.
# ---------------------------------------------------------------------------
run_sweep_group() {
  group sweep
  local nd=scripts/new-dest.sh sw=scripts/worktree-sweep.sh
  # Under TMPROOT, not LABROOT. LABROOT exists because codex `workspace-write`
  # grants /tmp unconditionally, so a SANDBOX probe there passes for the wrong
  # reason — a rationale that does not apply to a git fixture the sweep walks;
  # worktree-sweep.sh has no volatility logic of any kind. Under $HOME the whole
  # fixture collapsed to a single skip whenever $HOME was not writable, which is
  # exactly what a codex sandbox does: ten cases, no red.
  local lab="$TMPROOT/sweep"

  # -- new-dest: refusing a non-durable destination ------------------------
  _dest_rc() { "./$nd" "$1" >/dev/null 2>&1; echo $?; }

  # /tmp and /private/tmp are the same directory behind a symlink. Both
  # spellings must lose, including the one nobody types.
  local tmp_rc priv_rc
  tmp_rc=$(_dest_rc "/tmp/forge-probe"); priv_rc=$(_dest_rc "/private/tmp/forge-probe")
  if [ "$tmp_rc" != 0 ] && [ "$priv_rc" != 0 ]; then
    ok "dest-refuses-tmp-both-spellings"
  else
    bad "dest-refuses-tmp-both-spellings" \
        "/tmp rc=$tmp_rc /private/tmp rc=$priv_rc — a string compare passes the spelling it was not written for"
  fi

  # …and so is a path that only reaches a volatile root through `..`.
  if [ "$(_dest_rc "/Users/../tmp/forge-probe")" != 0 ]; then
    ok "dest-refuses-tmp-via-traversal"
  else
    bad "dest-refuses-tmp-via-traversal" "'/Users/../tmp/x' was accepted; symlinks and .. must be resolved BEFORE judging"
  fi

  # …and the case above passes for the wrong reason on its own: every component
  # of /Users/../tmp exists, so a single `-d` test resolves it. The shape that
  # got through walked `..` past a component that does NOT exist yet, which is
  # the shape `make new` actually produces, because the target is new.
  local esc="$REPO_ROOT/__forge_missing__/../../../../../../../../private/tmp/forge-probe"
  if [ "$(_dest_rc "$esc")" != 0 ]; then
    ok "dest-refuses-traversal-past-a-missing-component"
  else
    bad "dest-refuses-traversal-past-a-missing-component" \
        "'$esc' was accepted; it normalises into /private/tmp and mkdir -p walks it"
  fi

  if [ -n "${TMPDIR:-}" ]; then
    if [ "$(_dest_rc "${TMPDIR%/}/forge-probe")" != 0 ]; then
      ok "dest-refuses-active-tmpdir"
    else
      bad "dest-refuses-active-tmpdir" "\$TMPDIR is volatile too, and on macOS it is not under /tmp at all"
    fi
  else
    skip "dest-refuses-active-tmpdir" "TMPDIR unset"
  fi

  local rel_rc empty_rc
  rel_rc=$(_dest_rc ".."); empty_rc=$(_dest_rc "")
  if [ "$rel_rc" != 0 ] && [ "$empty_rc" != 0 ]; then
    ok "dest-refuses-relative-and-empty"
  else
    bad "dest-refuses-relative-and-empty" \
        "'..' rc=$rel_rc, '' rc=$empty_rc — a relative DEST is the F19 mechanism itself"
  fi

  # The contract word is DIRECTORY. A regular file was accepted at rc 0, and so
  # was `/` — which made `make new NAME=x DEST=/` target `//x`.
  local file_rc root_rc probe_file="$TMPROOT/not-a-dir"
  : > "$probe_file"
  file_rc=$(_dest_rc "$probe_file"); root_rc=$(_dest_rc "/")
  if [ "$file_rc" != 0 ] && [ "$root_rc" != 0 ]; then
    ok "dest-refuses-a-non-directory"
  else
    bad "dest-refuses-a-non-directory" \
        "a regular file rc=$file_rc, '/' rc=$root_rc — the contract promises a durable directory"
  fi

  # An ancestor that cannot be entered used to emit the bare TAIL as if it were
  # an absolute path: `<unreadable>/sub/proj` came back as `/sub/proj`, rc 0,
  # and `make new` would have stamped a project at the filesystem root.
  local noperm="$TMPROOT/noperm" noperm_rc noperm_out
  mkdir -p "$noperm/sub" && chmod 000 "$noperm"
  noperm_out="$("./$nd" "$noperm/sub/proj" 2>/dev/null)"; noperm_rc=$?
  chmod 755 "$noperm" 2>/dev/null
  # A dangling symlink is not `-d` either, so it fell into the tail and was
  # never resolved — lexnorm()'s premise is that a component which does not
  # exist cannot be a symlink, and this was the exception to it.
  local dangle_rc
  ln -sfn /private/tmp/__forge_nonexistent__ "$TMPROOT/dangle" 2>/dev/null
  "./$nd" "$TMPROOT/dangle/proj" >/dev/null 2>&1; dangle_rc=$?
  if [ "$noperm_rc" != 0 ] && [ "$noperm_out" != "/sub/proj" ] && [ "$dangle_rc" != 0 ]; then
    ok "dest-refuses-an-unreadable-ancestor"
  elif [ "$(id -u)" = 0 ]; then
    skip "dest-refuses-an-unreadable-ancestor" "running as root; chmod 000 does not deny"
  else
    bad "dest-refuses-an-unreadable-ancestor" \
        "rc=$noperm_rc out='$noperm_out' — an un-enterable ancestor must refuse, not emit its tail"
  fi

  # DEST was validated and NAME was appended to it unchecked, so the guard was
  # defeated by typing the other variable. NAME is one path component.
  #
  # The third probe is what makes this a check rather than a coincidence. The
  # first two are ALSO refused by the volatile-root test on the final target, so
  # with NAME validation deleted outright this case stayed green — F65's shape,
  # caught by mutation-testing it. `../elsewhere` escapes DEST and lands
  # somewhere perfectly durable: nothing but the NAME rule refuses that.
  local nm_rc dot_rc esc_rc
  "./$nd" "$HOME/dev" --name "../../../private/tmp/x" >/dev/null 2>&1; nm_rc=$?
  "./$nd" "$HOME/dev" --name ".." >/dev/null 2>&1; dot_rc=$?
  "./$nd" "$HOME/dev" --name "../elsewhere" >/dev/null 2>&1; esc_rc=$?
  if [ "$nm_rc" != 0 ] && [ "$dot_rc" != 0 ] && [ "$esc_rc" != 0 ]; then
    ok "dest-refuses-a-traversing-name"
  else
    bad "dest-refuses-a-traversing-name" \
        "NAME='../../../private/tmp/x' rc=$nm_rc, '..' rc=$dot_rc, '../elsewhere' rc=$esc_rc — NAME is one component"
  fi

  # Refusing is half a fix. The operator has to be told where to put it.
  local refusal; refusal="$("./$nd" "/tmp/forge-probe" 2>&1)"
  if printf '%s' "$refusal" | grep -q 'DEST=' && printf '%s' "$refusal" | grep -q "$HOME"; then
    ok "dest-refusal-names-a-durable-location"
  else
    bad "dest-refusal-names-a-durable-location" \
        "the refusal must show a usable DEST= under \$HOME, not only say no"
  fi

  # And a durable path must still work, printed as a physical absolute path.
  local good; good="$("./$nd" "$HOME/dev" 2>/dev/null)"
  if [ "$good" = "$(cd "$HOME" && pwd -P)/dev" ]; then
    ok "dest-accepts-durable"
  else
    bad "dest-accepts-durable" "\$HOME/dev was not accepted/resolved: got '$good'"
  fi

  # With --name it returns the FINAL TARGET. That string is what `make new`
  # stamps, so the guard and the recipe cannot disagree about where it went.
  local named; named="$("./$nd" "$HOME/dev" --name hello-forge 2>/dev/null)"
  if [ "$named" = "$(cd "$HOME" && pwd -P)/dev/hello-forge" ]; then
    ok "dest-accepts-durable-with-a-name"
  else
    bad "dest-accepts-durable-with-a-name" \
        "--name must print the resolved <dest>/<name>; got '$named'"
  fi

  # The guard is worthless if `make new` stops calling it, or if the relative
  # default comes back. F65's lesson: a check that survives the removal of the
  # thing it guards was never guarding it — so this reads the RECIPE, not the
  # file. The comment above the target names the script too, and grepping the
  # whole Makefile would go on passing after the call itself was deleted.
  local new_recipe
  new_recipe="$(awk '/^new:/{f=1;next} /^[a-zA-Z]/{f=0} f' Makefile)"
  if printf '%s' "$new_recipe" | grep -q 'scripts/new-dest.sh' \
     && ! printf '%s' "$new_recipe" | grep -qE '\$\(or \$\(DEST\),\.\.\)'; then
    ok "make-new-routes-through-the-guard"
  else
    bad "make-new-routes-through-the-guard" \
        "the new: recipe must call scripts/new-dest.sh and must not default DEST to '..'"
  fi

  # Reading the recipe is not enough, and this is where that stopped being a
  # theoretical objection: the case above passed while `make new` was accepting
  # NAME=../../../private/tmp/x and while a failed copier exited 0. So RUN it,
  # with copier replaced by a stub that only reports its argv.
  local mk="$TMPROOT/mknew"; mkdir -p "$mk/bin"
  printf '#!/bin/sh\necho "UVX: $*"\nexit ${UVX_RC:-0}\n' > "$mk/bin/uvx"
  chmod +x "$mk/bin/uvx"

  local nout nrc
  nout="$( PATH="$mk/bin:$PATH" make new NAME="../../../private/tmp/x" DEST="$HOME/dev" 2>&1 )"; nrc=$?
  if [ "$nrc" != 0 ] && ! printf '%s' "$nout" | grep -q 'UVX:'; then
    ok "make-new-sends-name-through-the-guard"
  else
    bad "make-new-sends-name-through-the-guard" \
        "NAME='../../../private/tmp/x' exited $nrc and reached copier — DEST is validated and NAME is not"
  fi

  local fout frc
  fout="$( PATH="$mk/bin:$PATH" UVX_RC=1 make new NAME=probe DEST="$HOME/dev" 2>&1 )"; frc=$?
  if [ "$frc" != 0 ] && ! printf '%s' "$fout" | grep -q '→ cd'; then
    ok "make-new-fails-when-copier-fails"
  else
    bad "make-new-fails-when-copier-fails" \
        "a failed copier exited $frc and still printed next steps for a directory that was never created"
  fi

  # APPLY was a non-empty test, so APPLY=0 — how an operator writes "don't" —
  # passed --apply to a command that removes worktrees and deletes branches.
  #
  # The refusal is read by its MESSAGE, not by a non-zero exit. Judged on rc
  # alone this passed with the refusal deleted, because the sweep then ran and
  # exited 2 on the nonexistent PROJECT — a second mutation-testing catch, and
  # the same "passed for the wrong reason" shape as the case above.
  local dr0 dr1 refuse_out refuse_rc
  dr0="$(make -n worktree-sweep PROJECT=/nonexistent APPLY=0 2>&1)"
  dr1="$(make -n worktree-sweep PROJECT=/nonexistent APPLY=1 2>&1)"
  refuse_out="$(make worktree-sweep PROJECT=/nonexistent APPLY=0 2>&1)"; refuse_rc=$?
  if ! printf '%s' "$dr0" | grep -qE 'worktree-sweep\.sh.*--apply' \
     && printf '%s' "$dr1" | grep -qE 'worktree-sweep\.sh.*--apply' \
     && [ "$refuse_rc" != 0 ] \
     && printf '%s' "$refuse_out" | grep -q 'is not understood'; then
    ok "sweep-apply-acts-only-on-1"
  else
    bad "sweep-apply-acts-only-on-1" \
        "APPLY=0 must neither pass --apply nor be silently reinterpreted (rc=$refuse_rc)"
  fi

  # -- worktree-sweep ------------------------------------------------------
  if ! command -v git >/dev/null 2>&1; then
    skip "sweep-fixture" "git not on PATH"; return
  fi

  # Fixture construction FAILS; it does not skip. "The git fixture is broken"
  # and "the lab root was denied" printed the same single skip line, and ten
  # cases disappearing without a red is the shape F5 names.
  rm -rf "$lab"
  if ! mkdir -p "$lab/bin"; then
    bad "sweep-fixture" "could not create the lab root at $lab — the worktree cases cannot run"
    return
  fi
  local realgit; realgit="$(command -v git)"
  cat > "$lab/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Stand-in for the ONE question the sweep asks the remote: is there a merged PR
# on this head branch, and at which commit? Answers from $MERGED_BRANCHES, whose
# entries are `branch` (merged at that branch's current head) or `branch=<oid>`
# (merged at a specific, possibly stale, commit).
head=""
while [ $# -gt 0 ]; do case "$1" in --head) head="$2"; shift 2;; *) shift;; esac; done
for spec in $MERGED_BRANCHES; do
  b="${spec%%=*}"
  [ "$b" = "$head" ] || continue
  oid="${spec#*=}"
  [ "$oid" != "$spec" ] || oid="$(git rev-parse "$b" 2>/dev/null)"
  printf '[{"number":7,"headRefOid":"%s"}]\n' "$oid"
  exit 0
done
echo '[]'
GHSTUB
  chmod +x "$lab/bin/gh"

  # A git that fails for exactly one question, so "could not read" can be told
  # apart from "read, and the answer was empty". $FAIL_GIT_ON names the
  # subcommand to fail; everything else is the real git.
  cat > "$lab/bin/git" <<GITSTUB
#!/usr/bin/env bash
# The calls this stands in for are always: -C <dir> <subcommand> [...]
# The -n test is load-bearing: without it an unset FAIL_GIT_ON matched an unset
# \$3, so every OTHER git invocation in the fixture failed instead of none.
if [ -n "\${FAIL_GIT_ON:-}" ] && [ "\${FAIL_GIT_ON}" = "\${3:-}" ]; then
  case "\${FAIL_GIT_ON:-}" in
    worktree) [ "\${4:-}" = list ] && { echo "fatal: stubbed failure" >&2; exit 128; };;
    *) echo "fatal: stubbed failure" >&2; exit 128;;
  esac
fi
exec "$realgit" "\$@"
GITSTUB
  chmod +x "$lab/bin/git"

  local proj="$lab/proj"
  _sweep_fixture() {
    rm -rf "$proj"; mkdir -p "$proj/.worktrees"
    ( cd "$proj" \
      && git init -q -b main . \
      && printf 'x\n' > f.txt \
      && git add -A \
      && git -c user.email=v@v -c user.name=v commit -qm init \
      && for spec in "merged:.worktrees/wt-merged" "unmerged:.worktrees/wt-unmerged" \
                     "dirty:.worktrees/wt-dirty" "ahead:.worktrees/wt-ahead" \
                     "rebuilt:.worktrees/wt-rebuilt" "elsewhere:outside-wt"; do
           git branch "${spec%%:*}" && git worktree add -q "$proj/${spec#*:}" "${spec%%:*}"
         done ) >/dev/null 2>&1 || return 1
    printf 'junk\n' > "$proj/.worktrees/wt-dirty/junk.txt"
    # `ahead` is the squash-merge shape: PR merged on the remote, but the commit
    # is not reachable from main, so `git branch -d` legitimately refuses.
    # `rebuilt` has the identical local shape and a different REMOTE answer: the
    # merged PR's head is the commit below it, not this one. Same picture on
    # disk, opposite verdict — which is the point.
    local w
    for w in ahead rebuilt; do
      printf '%s\n' "$w" > "$proj/.worktrees/wt-$w/$w.txt"
      ( cd "$proj/.worktrees/wt-$w" && git add -A \
        && git -c user.email=v@v -c user.name=v commit -qm "$w" ) >/dev/null 2>&1
    done
    BASE_OID="$(git -C "$proj" rev-parse main 2>/dev/null)"
    [ -n "$BASE_OID" ]
  }
  # every branch below is "merged" as far as the remote is concerned, so the
  # only thing keeping wt-dirty, wt-rebuilt and outside-wt alive is the sweep's
  # own guards. `rebuilt=$BASE_OID` is a PR merged at a commit this branch has
  # since moved past — the branch NAME matches, the work does not.
  _sweep() { MERGED_BRANCHES="merged dirty ahead elsewhere rebuilt=$BASE_OID" \
             PATH="$lab/bin:$PATH" "./$sw" "$@" 2>&1; }

  if ! _sweep_fixture; then
    bad "sweep-fixture" "could not build the git fixture under $lab — the worktree cases cannot run"
    return
  fi

  # PROJECT must be absolute for the same reason DEST must be: a relative path
  # inherits its meaning from the caller's cwd, and this one deletes things.
  local relrc; ( cd "$lab" && MERGED_BRANCHES="merged" PATH="$lab/bin:$PATH" \
                 "$REPO_ROOT/$sw" ./proj ) >/dev/null 2>&1; relrc=$?
  if [ "$relrc" = 2 ]; then
    ok "sweep-refuses-relative-project"
  else
    bad "sweep-refuses-relative-project" "a relative PROJECT exited $relrc, not 2"
  fi

  # Dry run by default: it must describe the removal and perform none of it.
  local dry; dry="$(_sweep "$proj")"
  if printf '%s' "$dry" | grep -q 'WOULD.*wt-merged' \
     && [ -d "$proj/.worktrees/wt-merged" ] \
     && git -C "$proj" show-ref --verify --quiet refs/heads/merged; then
    ok "sweep-dry-run-changes-nothing"
  else
    bad "sweep-dry-run-changes-nothing" \
        "without APPLY the sweep must name wt-merged and leave both the worktree and its branch in place"
  fi

  if printf '%s' "$dry" | grep -q 'REFUSE.*outside-wt'; then
    ok "sweep-refuses-outside-the-bound"
  else
    bad "sweep-refuses-outside-the-bound" "a worktree outside <project>/.worktrees/ must be reported REFUSE"
  fi

  # Now act.
  local app; app="$(_sweep "$proj" --apply)"

  if [ ! -d "$proj/.worktrees/wt-merged" ] \
     && ! git -C "$proj" show-ref --verify --quiet refs/heads/merged; then
    ok "sweep-removes-clean-merged"
  else
    bad "sweep-removes-clean-merged" "a clean worktree with a merged PR was not reclaimed"
  fi

  if [ -d "$proj/.worktrees/wt-dirty" ]; then
    ok "sweep-keeps-dirty"
  else
    bad "sweep-keeps-dirty" "a dirty worktree was removed; uncommitted work is not recoverable"
  fi

  if [ -d "$proj/.worktrees/wt-unmerged" ] \
     && git -C "$proj" show-ref --verify --quiet refs/heads/unmerged; then
    ok "sweep-keeps-unmerged"
  else
    bad "sweep-keeps-unmerged" "a branch with no merged PR on the remote was swept"
  fi

  # A merged PR on a branch NAME is not a merged branch. Reproduced end to end:
  # a chunk branch merged once, deleted, recreated with new unmerged commits —
  # its worktree was removed and its branch deleted, and the commits survived
  # only because they happened to have been pushed.
  if [ -d "$proj/.worktrees/wt-rebuilt" ] \
     && git -C "$proj" show-ref --verify --quiet refs/heads/rebuilt \
     && printf '%s' "$app" | grep -q 'at a different commit'; then
    ok "sweep-keeps-a-rebuilt-branch"
  else
    bad "sweep-keeps-a-rebuilt-branch" \
        "a branch whose merged PR points at an EARLIER commit was swept; the head OID must match"
  fi

  if [ -d "$proj/outside-wt" ] && git -C "$proj" show-ref --verify --quiet refs/heads/elsewhere; then
    ok "sweep-never-touches-outside-the-bound"
  else
    bad "sweep-never-touches-outside-the-bound" \
        "APPLY reached a worktree outside <project>/.worktrees/ — the bound is the only thing making this runnable unattended"
  fi

  # THE BOUND MUST FAIL CLOSED, and this is the case that says so.
  #
  # `-d "$BOUND"` needs only `+x` on the PARENT; `cd "$BOUND"` needs `+x` on the
  # directory itself. When the two disagreed the command substitution produced
  # "", and the guard became `case "$path" in "/*")` — a glob matching every
  # absolute path. Reproduced: a sibling checkout OUTSIDE the bound was removed
  # and its branch deleted, at exit 0, with `0 refused` in the summary. Both
  # existing bound cases build a readable `.worktrees`, so neither could see it.
  _sweep_fixture || { bad "sweep-refuses-an-unreadable-bound" "fixture rebuild failed"; return; }
  local outside="$lab/outside-the-bound" ub_out ub_rc
  git -C "$proj" worktree add -q -b outsider "$outside" >/dev/null 2>&1
  chmod 000 "$proj/.worktrees"
  ub_out="$(_sweep "$proj" --apply)"; ub_rc=$?
  chmod 755 "$proj/.worktrees" 2>/dev/null
  if [ "$ub_rc" != 0 ] && [ -d "$outside" ] \
     && ! printf '%s' "$ub_out" | grep -q 'bound to:  /$'; then
    ok "sweep-refuses-an-unreadable-bound"
  elif [ "$(id -u)" = 0 ]; then
    skip "sweep-refuses-an-unreadable-bound" "running as root; chmod 000 does not deny"
  else
    bad "sweep-refuses-an-unreadable-bound" \
        "an un-enterable .worktrees must exit non-zero and touch nothing: exit $ub_rc, the outside worktree $([ -d "$outside" ] && echo survived || echo 'was REMOVED')"
  fi
  _sweep_fixture || { bad "sweep-never-force-deletes-a-branch" "fixture rebuild failed"; return; }
  app="$(_sweep "$proj" --apply)"

  # The whole point of `-d`: the worktree is reclaimed, the branch survives,
  # and the operator is told. `-D` here would delete the commit silently.
  if [ ! -d "$proj/.worktrees/wt-ahead" ] \
     && git -C "$proj" show-ref --verify --quiet refs/heads/ahead \
     && printf '%s' "$app" | grep -q 'RETAINED'; then
    ok "sweep-never-force-deletes-a-branch"
  else
    bad "sweep-never-force-deletes-a-branch" \
        "a branch whose commit is unreachable from HEAD must survive the sweep and be reported, never -D'd"
  fi

  # Comment lines are stripped first. The header says "NEVER `git branch -D`",
  # and a check that reads prose reports the explanation as the offence — the
  # same confusion as F65, running the other way.
  if ! grep -v '^[[:space:]]*#' "$sw" | grep -q 'branch -D'; then
    ok "sweep-carries-no-forced-delete"
  else
    bad "sweep-carries-no-forced-delete" "worktree-sweep.sh executes 'git branch -D'"
  fi

  # An empty `git status --porcelain` means clean; a git that could not run also
  # prints nothing. Reading the second as the first took a worktree holding an
  # untracked file all the way to removal — it survived only because `git
  # worktree remove` has its own independent check, and was then reported with
  # the wrong reason ("remove refused it", not "could not read status").
  _sweep_fixture || { bad "sweep-keeps-what-it-cannot-read" "fixture rebuild failed"; return; }
  printf 'precious\n' > "$proj/.worktrees/wt-merged/precious.txt"
  local blind; blind="$( export FAIL_GIT_ON=status; _sweep "$proj" --apply )"
  if [ -d "$proj/.worktrees/wt-merged" ] \
     && printf '%s' "$blind" | grep -q "could not read 'git status'"; then
    ok "sweep-keeps-what-it-cannot-read"
  else
    bad "sweep-keeps-what-it-cannot-read" \
        "a worktree whose status could not be read was judged clean; it must be kept AND named"
  fi

  # And an enumeration that failed is not an empty repository. This printed
  # "0 would be removed · 0 kept · 0 refused" and exited 0 — "nothing to sweep"
  # and "I could not look" were the same output.
  local enum_out enum_rc
  enum_out="$( export FAIL_GIT_ON=worktree; _sweep "$proj" )"; enum_rc=$?
  if [ "$enum_rc" != 0 ] && ! printf '%s' "$enum_out" | grep -q '0 would be removed'; then
    ok "sweep-fails-when-it-cannot-enumerate"
  else
    bad "sweep-fails-when-it-cannot-enumerate" \
        "a failed 'git worktree list' exited $enum_rc and read as an empty repository"
  fi

  # --help was `sed -n '2,33p'` over a 35-line header: it cut off the `Exit:`
  # contract, which is the line a caller most needs, and every paragraph added
  # above it would have moved the window further off.
  local helped; helped="$("./$sw" --help 2>&1)"
  if printf '%s' "$helped" | grep -q 'Exit:' && printf '%s' "$helped" | grep -q 'Usage:'; then
    ok "sweep-help-names-its-exit-contract"
  else
    bad "sweep-help-names-its-exit-contract" \
        "--help must carry the whole header block, including Usage: and Exit:"
  fi

  # The merge may already have deleted the remote branch. That is the normal
  # end state, not an error: nothing here may require origin/<branch> to exist.
  _sweep_fixture || { bad "sweep-tolerates-missing-remote-branch" "fixture rebuild failed"; return; }
  git -C "$proj" config branch.merged.remote origin >/dev/null 2>&1
  git -C "$proj" config branch.merged.merge refs/heads/merged >/dev/null 2>&1
  _sweep "$proj" --apply >/dev/null 2>&1
  if [ ! -d "$proj/.worktrees/wt-merged" ]; then
    ok "sweep-tolerates-missing-remote-branch"
  else
    bad "sweep-tolerates-missing-remote-branch" \
        "a branch whose upstream no longer exists blocked the sweep; the merge deletes it, so this is the common case"
  fi

  rm -rf "$lab" "$mk"
}
wants sweep     && run_sweep_group

# ---------------------------------------------------------------------------
# roadmap/ — the sizing rules at PLAN time (ADR-0012, audit F53).
#
# Every case below is a MUTATION of one checked-in passing roadmap: copy the
# good fixture, reintroduce exactly one defect, and assert that the one check
# responsible warns. A fixture that cannot reproduce production behaviour proves
# nothing (F51), so the group's first two cases are not mutations at all — they
# run the real contract the audited run shipped, straight out of the prejudge
# recording, and assert the check reports the defects the audit counted by hand.
# ---------------------------------------------------------------------------
run_roadmap_group() {
  group roadmap
  local rc="$REPO_ROOT/scripts/roadmap-check.sh"
  local good="$REPO_ROOT/scripts/fixtures/roadmap/good"
  # Offline and deterministic: never `hermes kanban assignees` from a test.
  #
  # `forge-operator-handoff` was in this list and is `on_disk: false` on the live
  # host — a name that exists only because it once stranded a card. The fixture
  # was encoding the contract the checker got wrong, so a check written against
  # the fixture could not have found it. Only names a profile actually backs.
  export FORGE_ASSIGNEES="forge-codex-lane forge-prejudge"

  local reachable_line
  reachable_line="$("$rc" "$good" -v 2>/dev/null | awk '$2=="reachable"{getline; print}')"
  if printf '%s' "$reachable_line" | grep -Fq 'diagnostic evidence' \
     && grep -Fq 'not an independent detector' docs/adr/0012-sizing-at-plan-time.md; then
    ok "reachable-is-diagnostic-evidence"
  else
    bad "reachable-is-diagnostic-evidence" \
        "reachable pass must label itself diagnostic evidence and ADR-0012 must say it is not an independent detector"
  fi

  # Status/evidence of one check id, from the real script's real output. The
  # `|| true` is load-bearing under `set -o pipefail`: these two read OUTPUT,
  # and without it the checker's exit status leaks into every case that uses
  # them — a mutation making the script block was reported by three cases as
  # "CHUNK-5 does not serve 12 requirements", which it does. `warns-without-
  # blocking` is the case that owns the exit status, and it owns it alone.
  _rc_status() { { "$rc" "$1" 2>/dev/null || true; } | awk -v id="$2" '$2==id{print tolower($1)}'; }
  _rc_evidence() { { "$rc" "$1" 2>/dev/null || true; } | awk -v id="$2" '$2==id{getline; print}'; }
  # a copy of the passing fixture with ONE defect reintroduced
  _rc_mutate() {  # $1=name $2=shell snippet run inside the copy
    local d="$TMPROOT/roadmap-$1"
    rm -rf "$d"; mkdir -p "$d"; cp -R "$good/." "$d/"
    ( cd "$d" && eval "$2" ) || return 1
    printf '%s' "$d"
  }
  _rc_case() {  # $1=name $2=snippet $3=check-id $4=expected status
    local d got
    d="$(_rc_mutate "$1" "$2")" || { bad "$1" "the mutation itself failed to apply"; return; }
    got="$(_rc_status "$d" "$3")"
    if [ "$got" = "$4" ]; then ok "$1"
    else bad "$1" "$3 reported '$got', expected '$4' with the defect reintroduced"; fi
  }

  # -- the fixture is a claim about production, so check it against production --
  # The audited run's CHUNK-5, byte-identical to the copy in the prejudge
  # recording. Serves 12 requirements; F11 caps it at 4.
  local real="$TMPROOT/roadmap-real/docs/chunks"
  mkdir -p "$real"
  cp "$REPO_ROOT/scripts/fixtures/prejudge-prs/pr-9/tree/docs/chunks/CHUNK-5.md" "$real/"
  printf '[{"id":"CHUNK-5","lane":"forge-codex-lane","depends_on":[]}]\n' > "$real/graph.json"
  if [ "$(_rc_status "$TMPROOT/roadmap-real" serves)" = warn ] \
     && _rc_evidence "$TMPROOT/roadmap-real" serves | grep -q 'CHUNK-5(12)'; then
    ok "real-run-contract-fails-on-serves"
  else
    bad "real-run-contract-fails-on-serves" \
        "the run's own CHUNK-5 serves FR-1..9 + NFR-1,2,5 and this did not report 12 over the cap of 4"
  fi

  # Its five bullets specify eight scenarios. Counting bullets would say five
  # and clear it, which is the naive count F11 says passes.
  if [ "$(_rc_status "$TMPROOT/roadmap-real" scenarios)" = warn ] \
     && _rc_evidence "$TMPROOT/roadmap-real" scenarios | grep -q '8 from 5 bullet(s)'; then
    ok "counting-bullets-is-not-counting-scenarios"
  else
    bad "counting-bullets-is-not-counting-scenarios" \
        "CHUNK-5's 5 bullets specify 8 scenarios; a check that reports 5 is counting bullets"
  fi

  # The audit's verbatim CHUNK-6 scenario 2 — six scenarios in one bullet. The
  # single sentence this whole check exists for.
  _rc_case compound-bullet-is-not-one-scenario \
    "python3 - <<'PY'
import io
p='docs/chunks/CHUNK-2.md'
s=open(p).read().split('\n')
for i,l in enumerate(s):
    if l.startswith('  - Given a record with every field'):
        s[i]='  - Given invalid input, an unknown/changing board, cyclic graph, unavailable/old GitHub CLI, malformed canonical evidence, or publication failure, when the command runs, then a specific error is raised.'
        break
open(p,'w').write('\n'.join(s))
PY" \
    scenarios warn

  # ...and the conjunctive twin must NOT fire. 'Given A, B, and C' is one
  # scenario with a compound setup: one report containing several kinds of
  # field is still one report. Without this case the arity heuristic could
  # degenerate into 'any comma list', which fires on almost every real bullet.
  _rc_case conjunctive-list-is-still-one-scenario \
    "python3 - <<'PY'
p='docs/chunks/CHUNK-2.md'
s=open(p).read().split('\n')
for i,l in enumerate(s):
    if l.startswith('  - Given a record with every field'):
        s[i]='  - Given a record with populated, unavailable, nested, and escaped fields, when it is serialised, then the field order matches the schema exactly.'
        break
open(p,'w').write('\n'.join(s))
PY" \
    scenarios pass

  # -- one mutation per rule family --
  _rc_case bijection-id-with-no-file "rm docs/chunks/CHUNK-3.md" bijection warn
  _rc_case bijection-file-with-no-id \
    "cp docs/chunks/CHUNK-3.md docs/chunks/CHUNK-4.md" bijection warn
  _rc_case bijection-dangling-depends-on \
    "jq '(.[]|select(.id==\"CHUNK-3\")|.depends_on) = [\"CHUNK-9\"]' docs/chunks/graph.json > g && mv g docs/chunks/graph.json" \
    bijection warn
  _rc_case acyclic-catches-a-cycle \
    "jq '(.[]|select(.id==\"CHUNK-1\")|.depends_on) = [\"CHUNK-3\"]' docs/chunks/graph.json > g && mv g docs/chunks/graph.json" \
    acyclic warn
  _rc_case single-root-catches-two-roots \
    "jq '(.[]|select(.id==\"CHUNK-2\")|.depends_on) = []' docs/chunks/graph.json > g && mv g docs/chunks/graph.json" \
    single-root warn
  _rc_case fields-names-the-missing-one "sed -i.bak '/\*\*Done when:\*\*/d' docs/chunks/CHUNK-1.md && rm -f docs/chunks/*.bak" \
    fields warn
  _rc_case serves-over-four \
    "sed -i.bak 's/\*\*Serves:\*\* \`FR-4\`, \`NFR-1\`/**Serves:** \`FR-4\`, \`NFR-1\`, \`NFR-2\`, \`NFR-3\`, \`NFR-4\`/' docs/chunks/CHUNK-2.md && rm -f docs/chunks/*.bak" \
    serves warn
  _rc_case touches-over-six \
    "sed -i.bak 's#\`tests/fixtures/board.sql\`#\`tests/fixtures/board.sql\`, \`src/digest/cli.py\`#' docs/chunks/CHUNK-1.md && rm -f docs/chunks/*.bak" \
    touches warn
  _rc_case scenario-count-over-five \
    "sed -i.bak 's#^- \*\*Out of scope:\*\*#  - Given a sixth condition, when it happens, then it is handled.\n- **Out of scope:**#' docs/chunks/CHUNK-1.md && rm -f docs/chunks/*.bak" \
    scenarios warn
  _rc_case scenario-shape-needs-one-given-when-then \
    "sed -i.bak 's#, when the reader runs, then exactly one record is emitted\.#and it is read.#' docs/chunks/CHUNK-1.md && rm -f docs/chunks/*.bak" \
    scenarios warn
  _rc_case lane-catches-an-unknown-assignee \
    "sed -i.bak 's/forge-codex-lane/forge-code-lane/' docs/chunks/graph.json && rm -f docs/chunks/*.bak" \
    lane warn

  # -- the graph's SHAPE, before any algorithm reads it --
  #
  # `type == "array" and length > 0` was the whole of the validation. Three
  # shapes got past it and each produced PASS lines over a broken plan, so each
  # must now be exit 2 — the substrate code, because a plan that cannot be
  # parsed has not been checked.
  _rc_schema() {  # $1=case  $2=graph.json body  $3=extra snippet
    local d rc_out rc_code
    d="$(_rc_mutate "$1" "cat > docs/chunks/graph.json <<'GJSON'
$2
GJSON
${3:-true}")" || { bad "$1" "the mutation itself failed to apply"; return; }
    rc_out="$("$rc" "$d" 2>&1)"; rc_code=$?
    if [ "$rc_code" = 2 ] && ! printf '%s' "$rc_out" | grep -q 'PASS'; then
      ok "$1"
    else
      bad "$1" "expected exit 2 and no PASS line; got exit $rc_code: $(printf '%s' "$rc_out" | tr '\n' ' ' | cut -c1-160)"
    fi
  }

  # A numeric id killed the jq graph program, and the error went to stderr while
  # GRAPHFACTS was left empty and unchecked — so `acyclic` and `reachable` read
  # an empty fact string as "no cycle" and "nothing unreachable". Measured: a
  # graph with a genuine three-node cycle printed PASS acyclic, PASS reachable.
  _rc_schema graph-schema-rejects-a-numeric-id \
    '[{"id":"CHUNK-1","lane":"forge-codex-lane","depends_on":["CHUNK-3"]},
      {"id":"CHUNK-2","lane":"forge-codex-lane","depends_on":["CHUNK-1"]},
      {"id":"CHUNK-3","lane":"forge-codex-lane","depends_on":["CHUNK-2"]},
      {"id":7,"lane":"forge-codex-lane","depends_on":[]}]'

  # An id with a space was word-split by every content loop, so all five content
  # checks skipped it and each reported pass — eight PASS lines over a chunk
  # nothing had read.
  _rc_schema graph-schema-rejects-an-id-with-a-space \
    '[{"id":"CHUNK 1","lane":"forge-codex-lane","depends_on":[]}]' \
    "mv 'docs/chunks/CHUNK-1.md' 'docs/chunks/CHUNK 1.md' && rm -f docs/chunks/CHUNK-2.md docs/chunks/CHUNK-3.md"

  # Duplicate ids make the lane lookup return two records, whose embedded
  # newline splits one tab-separated result into several — and the display loop
  # then reads an action line as a status and uppercases it.
  _rc_schema graph-schema-rejects-duplicate-ids \
    '[{"id":"CHUNK-1","lane":"forge-codex-lane","depends_on":[]},
      {"id":"CHUNK-1","lane":"forge-codex-lane","depends_on":[]}]'

  # A depends_on that is a bare string rather than an array reached the same jq
  # program and produced the same false pass.
  _rc_schema graph-schema-rejects-a-scalar-depends-on \
    '[{"id":"CHUNK-1","lane":"forge-codex-lane","depends_on":[]},
      {"id":"CHUNK-2","lane":"forge-codex-lane","depends_on":"CHUNK-1"}]'

  # -- scenario arity, both directions --
  # `" or "` scored a flat 2, which is wrong twice over. A comparative is a
  # RANGE: "a record of 5 or more fields" is one scenario, and reporting it as
  # compound tells a planner to edit a correct plan.
  _rc_case range-is-not-a-disjunction \
    "sed -i.bak 's#^  - Given a record#  - Given a record of 5 or more fields, when it is parsed, then it is accepted.\n  - Given a record#' docs/chunks/CHUNK-1.md 2>/dev/null; sed -i.bak 's#^- \*\*Out of scope:\*\*#  - Given a record of 5 or more fields, when it is parsed, then it is accepted.\n- **Out of scope:**#' docs/chunks/CHUNK-2.md && rm -f docs/chunks/*.bak" \
    scenarios pass

  # …and a clause is worth as many scenarios as it LISTS (ADR-0012 D12.3). Five
  # alternatives scored 2 under the old rule — the same undercount the check
  # exists to catch, in the check itself.
  local d5
  d5="$(_rc_mutate disjunction-counts-every-alternative \
    "sed -i.bak 's#^- \*\*Out of scope:\*\*#  - Given an empty or partial or corrupt or truncated or absent record, when read, then it is refused.\n- **Out of scope:**#' docs/chunks/CHUNK-2.md && rm -f docs/chunks/*.bak")"
  if [ -n "$d5" ] && _rc_evidence "$d5" scenarios | grep -q '=5'; then
    ok "disjunction-counts-every-alternative"
  else
    bad "disjunction-counts-every-alternative" \
        "five alternatives in one bullet must score 5: $(_rc_evidence "$d5" scenarios | tr '\n' ' ' | cut -c1-140)"
  fi

  # A bullet wrapped over two physical lines is ordinary Markdown — and is how
  # docs/roadmap-first-run.md writes its own C1 scenarios. The scorer was
  # line-oriented, so it reported the plan document that specified it as
  # malformed. Every fixture bullet was one long line, so verify could not see.
  _rc_case wrapped-bullet-is-still-one-scenario \
    "sed -i.bak 's#^- \*\*Out of scope:\*\*#  - Given a bullet that wraps, when it is scored,\n    then it is one scenario.\n- **Out of scope:**#' docs/chunks/CHUNK-2.md && rm -f docs/chunks/*.bak" \
    scenarios pass

  # -- the F55 exemption, at plan time --
  # CHUNK-1 declares eight paths and clears a six-path budget, because two of
  # them are process docs the methodology obliges every chunk to change. Adding
  # three more of the same kind must not move the count. A check that counted
  # them would punish the one planner honest enough to write them down, and the
  # cheapest way to pass it would be to delete them from Touches — which then
  # manufactures prejudge's `touches` drift finding on the same chunk.
  _rc_case process-docs-do-not-count-against-touches \
    "sed -i.bak 's#\`docs/ROADMAP.md\`#\`docs/ROADMAP.md\`, \`docs/chunks/CHUNK-1.md\`, \`docs/chunks/CHUNK-2.md\`, \`docs/chunks/CHUNK-3.md\`#' docs/chunks/CHUNK-1.md && rm -f docs/chunks/*.bak" \
    touches pass

  # One definition of that exemption in the whole repo, or the two ends of it
  # disagree the first time one is edited (F30's defect class). Assignments
  # only: a comment naming the variable is documentation, not a second copy.
  local defs
  defs="$(grep -rn '^[[:space:]]*TOUCHES_EXEMPT=' "$REPO_ROOT/scripts" "$REPO_ROOT/hermes" \
          "$REPO_ROOT/skills" 2>/dev/null | grep -c . || true)"
  if [ "$defs" = 1 ] && grep -q 'touches-exempt\.sh' "$REPO_ROOT/scripts/prejudge.sh" \
     && grep -q 'touches-exempt\.sh' "$REPO_ROOT/scripts/roadmap-check.sh"; then
    ok "touches-exemption-has-one-definition"
  else
    bad "touches-exemption-has-one-definition" \
        "$defs TOUCHES_EXEMPT assignment(s) found; plan time and review time must source scripts/touches-exempt.sh"
  fi

  # Two independent defects in two independent contracts, and an if/elif chain
  # meant the first hid the second: one chunk missing its Touches list
  # suppressed the over-budget finding for every OTHER chunk in the plan.
  local dt
  dt="$(_rc_mutate touches-findings-are-independent \
    "sed -i.bak 's#^- \*\*Touches:\*\*.*##' docs/chunks/CHUNK-2.md \
     && sed -i.bak 's#^\(- \*\*Touches:\*\*\).*#\1 \`a/1.py\`, \`a/2.py\`, \`a/3.py\`, \`a/4.py\`, \`a/5.py\`, \`a/6.py\`, \`a/7.py\`, \`a/8.py\`, \`a/9.py\`, \`a/10.py\`#' docs/chunks/CHUNK-1.md \
     && rm -f docs/chunks/*.bak")"
  if [ -n "$dt" ] \
     && _rc_evidence "$dt" touches | grep -q 'CHUNK-2' \
     && _rc_evidence "$dt" touches | grep -q 'CHUNK-1'; then
    ok "touches-findings-are-independent"
  else
    bad "touches-findings-are-independent" \
        "a chunk with no Touches list must not suppress the over-budget finding for another chunk: $(_rc_evidence "$dt" touches | tr '\n' ' ' | cut -c1-160)"
  fi

  # -- the hermes branch, which had NO coverage at all --
  #
  # $FORGE_ASSIGNEES is exported for this whole group, so every case above takes
  # the offline path and the `hermes kanban assignees` branch was never executed
  # by anything. That is the branch the defect was in: it read the formatted
  # TABLE and matched any space-delimited token in it, so `yes`, `no`, `NAME`,
  # `COUNTS`, `done=1` and `(idle)` all cleared the check — and so did any name
  # with `on_disk: false`, which is to say any lane that had ALREADY stranded a
  # card, since that list is derived from cards.
  local hstub="$TMPROOT/roadmap-hermes"
  mkdir -p "$hstub/bin"
  cat > "$hstub/bin/hermes" <<'HSTUB'
#!/usr/bin/env bash
# Stands in for `hermes kanban assignees [--json]`, reproducing the live shape:
# a name present in the card-derived list but with NO profile on disk.
for a in "$@"; do [ "$a" = "--json" ] && { cat <<'J'
[{"name":"forge-codex-lane","on_disk":true,"counts":{"done":22}},
 {"name":"forge-operator","on_disk":false,"counts":{"done":1}}]
J
  exit 0; }; done
printf 'NAME                  ON DISK   COUNTS\n'
printf 'forge-codex-lane      yes       done=22\n'
printf 'forge-operator        no        done=1\n'
HSTUB
  chmod +x "$hstub/bin/hermes"
  local dh hstatus
  dh="$(_rc_mutate lane-accepts-only-on-disk-profiles \
    "sed -i.bak 's/\"forge-codex-lane\"/\"forge-operator\"/' docs/chunks/graph.json && rm -f docs/chunks/*.bak")"
  hstatus="$( { env -u FORGE_ASSIGNEES PATH="$hstub/bin:$PATH" "$rc" "$dh" 2>/dev/null || true; } \
              | awk '$2=="lane"{print tolower($1)}')"
  local hgood
  hgood="$( { env -u FORGE_ASSIGNEES PATH="$hstub/bin:$PATH" "$rc" "$good" 2>/dev/null || true; } \
            | awk '$2=="lane"{print tolower($1)}')"
  if [ "$hstatus" = warn ] && [ "$hgood" = pass ]; then
    ok "lane-accepts-only-on-disk-profiles"
  else
    bad "lane-accepts-only-on-disk-profiles" \
        "reading the assignee list from hermes must accept on_disk names only: an on_disk:false lane reported '$hstatus' (expected warn) and a real one reported '$hgood' (expected pass)"
  fi

  # -- what independent review found in this branch --
  #
  # N1, and it is this file's headline defect happening inside this file: the
  # `touches-exempt.sh` source was UNGUARDED, so a missing file left
  # TOUCHES_EXEMPT unbound; `set -u` killed only the `$( )` SUBSHELL that counts
  # paths, `touches()` fell through to `emit touches pass`, and the run printed
  # `CLEAR — 9 pass, 0 warn` at exit 0. `prejudge.sh` guarded the same source.
  local dexempt de_out de_rc
  dexempt="$TMPROOT/roadmap-noexempt"
  rm -rf "$dexempt"; mkdir -p "$dexempt"
  cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/rubrics" "$dexempt/" 2>/dev/null
  rm -f "$dexempt/scripts/touches-exempt.sh"
  de_out="$("$dexempt/scripts/roadmap-check.sh" "$good" 2>&1)"; de_rc=$?
  if [ "$de_rc" = 2 ] && ! printf '%s' "$de_out" | grep -q 'PASS'; then
    ok "missing-touches-exemption-is-exit-2-not-a-pass"
  else
    bad "missing-touches-exemption-is-exit-2-not-a-pass" \
        "a missing touches-exempt.sh must exit 2, not report PASS touches: exit $de_rc: $(printf '%s' "$de_out" | tr '\n' ' ' | cut -c1-160)"
  fi

  # N2. The commas only belong to the "or" when the separator is the Oxford
  # ", or ". A conjunctive list followed by one plain "or" was scored as a
  # disjunction of the whole list — 9 for a bullet worth 2 — which blows the cap
  # and tells a planner to split a correct chunk.
  # The bullet IS a two-way disjunction ("absent or stale"), so it is correctly
  # reported as compound — at 2. What must not happen is 9, which is what the
  # conjunctive commas produced, and which blows the five-scenario cap.
  local dcc
  dcc="$(_rc_mutate conjunctive-commas \
    "sed -i.bak 's#^- \*\*Out of scope:\*\*#  - Given a run record carrying a start time, an end time, a status, a cost, a model name, a lane name, a card id, and a digest that is absent or stale, when the reader reads it, then the run is marked unavailable.\n- **Out of scope:**#' docs/chunks/CHUNK-2.md && rm -f docs/chunks/*.bak")"
  local cc_ev; cc_ev="$(_rc_evidence "$dcc" scenarios)"
  if printf '%s' "$cc_ev" | grep -q '=2' \
     && ! printf '%s' "$cc_ev" | grep -qE '=[3-9]|scenario cap'; then
    ok "conjunctive-commas-are-not-alternatives"
  else
    bad "conjunctive-commas-are-not-alternatives" \
        "a comma list plus one plain 'or' is a 2-way disjunction, not a 9-way one: $(printf '%s' "$cc_ev" | tr '\n' ' ' | cut -c1-140)"
  fi

  # N3. Given/When/Then were counted as WORD OCCURRENCES, so ordinary English
  # tripped the shape check: "then the record GIVEN to the caller" scored
  # given=2. A bullet rejected on vocabulary is never sized either, because the
  # shape branch returns before arity is computed.
  _rc_case keyword-inside-a-clause-is-not-a-marker \
    "sed -i.bak 's#^- \*\*Out of scope:\*\*#  - Given a board snapshot, when the reader runs, then the record given to the caller is immutable and is returned when it is ready.\n- **Out of scope:**#' docs/chunks/CHUNK-2.md && rm -f docs/chunks/*.bak" \
    scenarios pass

  # N4. `null` and an ABSENT key are the same thing to every consumer —
  # `(.lane // "")`, `(.depends_on // [])` — so rejecting one while warning
  # about the other was the validator disagreeing with the script it guards.
  # A validator that rejects valid plans is worse than the bug it fixed.
  local dnull dn_rc
  dnull="$(_rc_mutate accepts-null "cat > docs/chunks/graph.json <<'GJSON'
[{\"id\":\"CHUNK-1\",\"lane\":null,\"depends_on\":null},
 {\"id\":\"CHUNK-2\",\"lane\":\"forge-codex-lane\",\"depends_on\":[\"CHUNK-1\"]},
 {\"id\":\"CHUNK-3\",\"lane\":\"forge-codex-lane\",\"depends_on\":[\"CHUNK-2\"]}]
GJSON")" || { bad "null-is-the-same-as-an-absent-key" "the mutation itself failed to apply"; return; }
  "$rc" "$dnull" >/dev/null 2>&1; dn_rc=$?
  if [ "$dn_rc" = 0 ] && [ "$(_rc_status "$dnull" lane)" = warn ]; then
    ok "null-is-the-same-as-an-absent-key"
  else
    bad "null-is-the-same-as-an-absent-key" \
        "a null lane/depends_on must be treated as absent (warn), not rejected as unparseable: exit $dn_rc, lane '$(_rc_status "$dnull" lane)'"
  fi

  # -- the properties of the check itself --
  # Warn-first is the shipped decision (F53), not an accident, and an exit
  # status is how a caller would find out. A plan full of findings still exits
  # 0; only a substrate failure is non-zero. When this flips to blocking it
  # flips as a recorded decision and this case is the one that has to change.
  local d; d="$(_rc_mutate exit-status "rm docs/chunks/CHUNK-3.md")"
  if "$rc" "$d" >/dev/null 2>&1; then
    ok "warns-without-blocking"
  else
    bad "warns-without-blocking" \
        "a plan with findings exited non-zero — ADR-0012 ships this advisory; blocking is a later recorded decision"
  fi
  if "$rc" "$TMPROOT/no-such-project-dir" >/dev/null 2>&1; then
    bad "unrunnable-is-exit-2-not-a-pass" "a missing project exited 0 — an absent plan is not a clean plan"
  elif [ "$?" = 2 ]; then ok "unrunnable-is-exit-2-not-a-pass"
  else bad "unrunnable-is-exit-2-not-a-pass" "expected exit 2 for a missing project"; fi

  # skip is not pass: with no assignee list readable, `lane` has cleared nothing.
  if [ "$(env -u FORGE_ASSIGNEES PATH=/usr/bin:/bin "$rc" "$good" 2>/dev/null \
          | awk '$2=="lane"{print tolower($1)}')" = skip ]; then
    ok "unreadable-assignee-list-skips-never-passes"
  else
    bad "unreadable-assignee-list-skips-never-passes" \
        "with no hermes and no \$FORGE_ASSIGNEES the lane check must skip; a check that could not run has not passed (F5)"
  fi

  # Every warning must carry an action a planner can execute — the same
  # contract prejudge's blocking findings are held to.
  # Counted over every mutation this group made, so the set grows with the
  # group rather than with a list somebody has to remember to extend.
  local seen=0 missing=0 m out
  for m in "$TMPROOT"/roadmap-*; do
    [ -d "$m/docs/chunks" ] || continue
    out="$("$rc" "$m" 2>/dev/null | awk '
      /^  WARN   /   { if (pend) miss++; pend = 1; warns++; next }
      /^      -> /   { pend = 0 }
      END { if (pend) miss++; printf "%d %d", warns + 0, miss + 0 }')"
    seen=$(( seen + ${out% *} )); missing=$(( missing + ${out#* } ))
  done
  if [ "$missing" = 0 ] && [ "$seen" -gt 0 ]; then
    ok "every-warning-carries-an-action ($seen warning(s) over $(ls -d "$TMPROOT"/roadmap-* | wc -l | tr -d ' ') mutated plans)"
  else
    bad "every-warning-carries-an-action" \
        "$missing of $seen warning(s) named a defect without saying what to do about it"
  fi

  # ADR-0003 applied to the claim this slice just added to a skill body: the
  # roadmap ceremony tells a machine to run this script, through the
  # ~/.forge/repo form that resolves from a project worktree, and the script it
  # names has to exist. A bare relative path here cannot resolve at all.
  if grep -q '~/\.forge/repo/scripts/roadmap-check\.sh' skills/roadmap/SKILL.md \
     && [ -x "$rc" ]; then
    ok "skill-delegates-to-the-checker"
  else
    bad "skill-delegates-to-the-checker" \
        "skills/roadmap/SKILL.md must name ~/.forge/repo/scripts/roadmap-check.sh, and it must be executable"
  fi

  # The skill states the numbers; the checker must not have drifted from them.
  # ADR-0003 applied to the one skill body this slice makes executable.
  if grep -q '<= 5 BDD scenarios' skills/roadmap/SKILL.md \
     || grep -q '≤ 5 BDD scenarios' skills/roadmap/SKILL.md; then
    if grep -q '^SCENARIO_MAX=5' "$rc" && grep -q '^TOUCHES_MAX=6' "$rc" \
       && grep -q '^SERVES_MAX=4' "$rc"; then
      ok "thresholds-are-the-skills-own-numbers"
    else
      bad "thresholds-are-the-skills-own-numbers" \
          "roadmap-check.sh's caps drifted from skills/roadmap/SKILL.md's '<= ~6 files, <= 5 BDD scenarios' and F11's '~4 requirements'"
    fi
  else
    skip "thresholds-are-the-skills-own-numbers" "SKILL.md no longer states the scenario cap"
  fi

  # -- acceptance is a planning artifact, not implementation work (ADR-0014) --
  #
  # One fixture owns the whole seam: the chunk contract, the generated Gherkin,
  # and the manifest producer. Each case mutates one edge of that seam and runs
  # the real command. This keeps the assertions about behaviour rather than the
  # implementation shape of acceptance-freeze.sh.
  local freeze="$REPO_ROOT/scripts/acceptance-freeze.sh"
  _acceptance_fixture() { # $1=fixture root
    local af_root="$1"
    rm -rf "$af_root"
    mkdir -p "$af_root/docs/chunks" "$af_root/tests/features"
    cat > "$af_root/docs/chunks/graph.json" <<'AF_GRAPH'
[
  {"id":"CHUNK-6","lane":"claude-interactive","depends_on":[]}
]
AF_GRAPH
    cat > "$af_root/docs/chunks/CHUNK-6.md" <<'AF_CHUNK'
### CHUNK-6: Read a real source
- **Goal:** Prove planning emits acceptance before implementation.
- **Milestone:** M1 · **Depends on:** none
- **Serves:** F25 · **Relevant ADRs:** 0014
- **Touches:** `tests/features/chunk_6.feature`
- **Scenarios:**
  - Given a SQLite source, When the reader runs, Then one real record is returned.
  - Given an opaque telemetry lake, When the reader runs, Then one opaque record is returned.
  - Given the same plan twice, When acceptance is frozen, Then the manifest bytes are identical.
- **Real sources:** `SQLite source` → scenario 1; `opaque telemetry lake` → scenario 2
- **Acceptance:** tests/features/chunk_6.feature
- **Out of scope:** step definitions.
- **Done when:** acceptance is frozen.
- **Lane:** claude-interactive · **Risk:** high
AF_CHUNK
    cat > "$af_root/tests/features/chunk_6.feature" <<'AF_FEATURE'
Feature: CHUNK-6 acceptance

  @real-source
  Scenario: Read the real source
    Given a SQLite source
    When the reader runs
    Then one real record is returned

  @real-source
  Scenario: Read an arbitrary source label
    Given an opaque telemetry lake
    When the reader runs
    Then one opaque record is returned

  Scenario: Freeze deterministically
    Given the same plan twice
    When acceptance is frozen
    Then the manifest bytes are identical
AF_FEATURE
  }

  if grep -Fq '**Acceptance:** tests/features/chunk_<id>.feature' skills/roadmap/SKILL.md \
     && grep -Fq '**Real sources:**' skills/roadmap/SKILL.md \
     && grep -Fq '@real-source' skills/roadmap/SKILL.md \
     && grep -Fq '~/.forge/repo/scripts/acceptance-freeze.sh' skills/roadmap/SKILL.md; then
    ok "skill-emits-frozen-acceptance"
  else
    bad "skill-emits-frozen-acceptance" \
        "roadmap must emit the Acceptance field and feature files, tag real sources, then invoke ~/.forge/repo/scripts/acceptance-freeze.sh in the same planning pass"
  fi

  if [ ! -x "$freeze" ]; then
    bad "acceptance-matches-contract" "$freeze is missing or not executable"
    bad "real-source-is-planned" "$freeze is missing or not executable"
    bad "freeze-is-deterministic" "$freeze is missing or not executable"
    bad "missing-feature-is-named" "$freeze is missing or not executable"
  else
    local af_good="$TMPROOT/acceptance-good" af_out af_rc
    _acceptance_fixture "$af_good"
    af_out="$("$freeze" "$af_good" 2>&1)"; af_rc=$?
    if [ "$af_rc" = 0 ]; then
      sed -i.bak 's/Then one real record is returned/Then two records are returned/' \
        "$af_good/tests/features/chunk_6.feature"
      rm -f "$af_good/tests/features/chunk_6.feature.bak"
      af_out="$("$freeze" "$af_good" 2>&1)"; af_rc=$?
      if [ "$af_rc" -ne 0 ] \
         && printf '%s' "$af_out" | grep -Fq 'CHUNK-6' \
         && printf '%s' "$af_out" | grep -qi 'match'; then
        ok "acceptance-matches-contract"
      else
        bad "acceptance-matches-contract" \
            "a changed Then step must fail and name CHUNK-6's contract mismatch (exit $af_rc: ${af_out:-no diagnostic})"
      fi
    else
      bad "acceptance-matches-contract" \
          "the matching contract and feature did not freeze (exit $af_rc: ${af_out:-no diagnostic})"
    fi

    local af_source="$TMPROOT/acceptance-source" af_moved="$TMPROOT/acceptance-source-moved"
    _acceptance_fixture "$af_source"
    sed -i.bak '/@real-source/d' "$af_source/tests/features/chunk_6.feature"
    rm -f "$af_source/tests/features/chunk_6.feature.bak"
    af_out="$("$freeze" "$af_source" 2>&1)"; af_rc=$?
    _acceptance_fixture "$af_moved"
    sed -i.bak '/@real-source/d' "$af_moved/tests/features/chunk_6.feature"
    sed -i.bak '/Scenario: Freeze deterministically/i\
  @real-source' "$af_moved/tests/features/chunk_6.feature"
    rm -f "$af_moved/tests/features/chunk_6.feature.bak"
    local af_moved_out af_moved_rc
    af_moved_out="$("$freeze" "$af_moved" 2>&1)"; af_moved_rc=$?
    if [ "$af_rc" -ne 0 ] \
       && printf '%s' "$af_out" | grep -Fq 'CHUNK-6' \
       && printf '%s' "$af_out" | grep -Fq '@real-source' \
       && [ "$af_moved_rc" -ne 0 ] \
       && printf '%s' "$af_moved_out" | grep -Fq 'declared source scenarios'; then
      ok "real-source-is-planned (two arbitrary labels; missing or misplaced tags fail)"
    else
      bad "real-source-is-planned" \
          "declared source mappings must reject missing and unrelated tags (exits $af_rc/$af_moved_rc: ${af_out:-no diagnostic}; ${af_moved_out:-no moved diagnostic})"
    fi

    local af_deterministic="$TMPROOT/acceptance-deterministic" af_digest
    _acceptance_fixture "$af_deterministic"
    af_out="$("$freeze" "$af_deterministic" 2>&1)"; af_rc=$?
    cp "$af_deterministic/docs/chunks/contract-freeze.json" \
       "$af_deterministic/docs/chunks/contract-freeze.first.json" 2>/dev/null || true
    "$freeze" "$af_deterministic" >/dev/null 2>&1; local af_second_rc=$?
    af_digest="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
      "$af_deterministic/tests/features/chunk_6.feature" 2>/dev/null)"
    if [ "$af_rc" = 0 ] && [ "$af_second_rc" = 0 ] \
       && cmp -s "$af_deterministic/docs/chunks/contract-freeze.first.json" \
                 "$af_deterministic/docs/chunks/contract-freeze.json" \
       && jq -e --arg digest "$af_digest" \
            'keys == ["tests/features/chunk_6.feature"] and .["tests/features/chunk_6.feature"] == $digest' \
            "$af_deterministic/docs/chunks/contract-freeze.json" >/dev/null 2>&1; then
      ok "freeze-is-deterministic"
    else
      bad "freeze-is-deterministic" \
          "two freezes must emit identical JSON mapping the repo-relative feature path to its SHA-256 digest"
    fi

    local af_missing="$TMPROOT/acceptance-missing"
    _acceptance_fixture "$af_missing"
    "$freeze" "$af_missing" >/dev/null 2>&1
    cp "$af_missing/docs/chunks/contract-freeze.json" \
       "$af_missing/docs/chunks/contract-freeze.before.json" 2>/dev/null || true
    rm -f "$af_missing/tests/features/chunk_6.feature"
    af_out="$("$freeze" "$af_missing" 2>&1)"; af_rc=$?
    if [ "$af_rc" -ne 0 ] \
       && printf '%s' "$af_out" | grep -Fq 'CHUNK-6' \
       && printf '%s' "$af_out" | grep -Fq 'tests/features/chunk_6.feature' \
       && cmp -s "$af_missing/docs/chunks/contract-freeze.before.json" \
                 "$af_missing/docs/chunks/contract-freeze.json"; then
      ok "missing-feature-is-named"
    else
      bad "missing-feature-is-named" \
          "a missing feature must name CHUNK-6 and its expected path without rewriting the last good manifest (exit $af_rc: ${af_out:-no diagnostic})"
    fi
  fi
}
wants roadmap   && run_roadmap_group

# ---------------------------------------------------------------------------
# gate/ — the merge gate, asked as a program.
#
# F79's first executable check was written inline in preflight.sh and driven by
# nothing. It shipped with two crashes and two false verdicts, and CI stayed
# green throughout, because no case could reach it: the decision was tangled up
# with a live API call and a live repo. Extracting it into merge-gate.sh is what
# makes it assertable (ADR-0003), and this group is the assertion.
#
# Every case runs the real script against a `gh` stub. None of them greps it.
# Two of them — checks-without-a-pr-rule and other-branch-ruleset — are the
# shapes the first version reported as GATED, so they are the regression cases
# that must stay red if this ever collapses back to "any rule anywhere".
# ---------------------------------------------------------------------------
run_gate_group() {
  group "gate"

  local lab="$TMPROOT/gate"
  mkdir -p "$lab/bin" "$lab/fix" 2>/dev/null

  # The stub answers the four endpoints merge-gate.sh uses, out of files the
  # cases write. A missing file is a FAILED call, which is how 403 and 404 are
  # expressed; `$FIX/protection.403` distinguishes "not answered" from "no".
  cat > "$lab/bin/gh" <<'STUB'
#!/usr/bin/env bash
last=""; for a in "$@"; do last="$a"; done
upgrade() {
  # Both lines, because that is what `gh` really writes: its own summary AND
  # the raw body, both on stderr. Copied from a live 403 (wielas/JobApp).
  echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2
  echo '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}' >&2
  exit 1
}
case "$last" in
  */rulesets)
    [ -f "$FIX/rulesets.upgrade403" ] && upgrade
    [ -f "$FIX/rulesets.403" ] && { echo "HTTP 403: Resource not accessible" >&2; exit 1; }
    cat "$FIX/rulesets.json" 2>/dev/null || echo '[]' ;;
  */rulesets/*)
    id="${last##*/}"
    cat "$FIX/ruleset-$id.json" 2>/dev/null || exit 1 ;;
  */protection)
    [ -f "$FIX/protection.upgrade403" ] && upgrade
    [ -f "$FIX/protection.403" ] && { echo "HTTP 403: Must have admin rights to Repository." >&2; exit 1; }
    [ -f "$FIX/protection.json" ] || { echo "HTTP 404: Branch not protected" >&2; exit 1; }
    cat "$FIX/protection.json" ;;
  repos/*)
    [ -f "$FIX/norepo" ] && { echo "HTTP 404" >&2; exit 1; }
    cat "$FIX/repo.json" 2>/dev/null || echo '{"default_branch":"main"}' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$lab/bin/gh" 2>/dev/null

  if [ ! -x "$lab/bin/gh" ]; then
    bad "fixture-builds" "could not construct the gh stub under $lab"
    return
  fi

  # A fixture that cannot be built is a FAILURE, not a skip: a group that
  # silently collapses to one skip is how a whole thesis goes unchecked (F5).
  local script="$REPO_ROOT/scripts/merge-gate.sh"
  if [ ! -x "$script" ]; then
    bad "merge-gate-is-executable" "scripts/merge-gate.sh is missing or not executable"
    return
  fi

  # $1=case name  $2=expected rc  $3=grep -E pattern the stdout verdict must match
  # (empty to skip the pattern)  $4..=extra args to merge-gate.sh
  _gate_run() {
    local name="$1" want_rc="$2" pat="$3"; shift 3
    local out rc
    out="$(PATH="$lab/bin:$PATH" FIX="$lab/fix" "$script" owner/repo "$@" 2>/dev/null)"
    rc=$?
    if [ "$rc" != "$want_rc" ]; then
      bad "$name" "expected exit $want_rc, got $rc (stdout: ${out:-<empty>})"
      return
    fi
    if [ -n "$pat" ] && ! printf '%s\n' "$out" | grep -Eq "$pat"; then
      bad "$name" "exit $rc was right but the verdict line was '${out:-<empty>}', expected /$pat/"
      return
    fi
    ok "$name"
  }

  _fix_reset() { rm -f "$lab/fix"/* 2>/dev/null; }

  local RS_PR_CHECKS='[{"id":1,"enforcement":"active"}]'
  local RULE_PR_CHECKS='{"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"pull_request"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"validate"},{"context":"verify"}]}}]}'

  # --- the shape `make protect` creates, and the one the first version FAILed --
  # templates/python-service/template/Makefile issues PUT /branches/main/protection
  # and creates ZERO rulesets. wielas/forgeboard-report — the repo docs/state.md
  # cites as the proof branch protection works — is exactly this, and the
  # rulesets-only check reported "nothing gates a direct push" for it.
  _fix_reset
  printf '[]' > "$lab/fix/rulesets.json"
  printf '{"required_pull_request_reviews":{"required_approving_review_count":0},"required_status_checks":{"contexts":["validate","verify"]}}' \
    > "$lab/fix/protection.json"
  _gate_run "classic-protection-is-a-gate" 0 'GATED.*via=classic.*pr=yes' --require validate,verify

  # --- rulesets, the modern mechanism ---------------------------------------
  _fix_reset
  printf '%s' "$RS_PR_CHECKS"  > "$lab/fix/rulesets.json"
  printf '%s' "$RULE_PR_CHECKS" > "$lab/fix/ruleset-1.json"
  _gate_run "rulesets-are-a-gate" 0 'GATED.*via=rulesets.*checks=validate,verify' --require validate,verify

  # --- REGRESSION: required checks alone are not a gate ----------------------
  # The first version tested required_status_checks FIRST and short-circuited,
  # so this exact shape printed "main is gated: PR + required status checks"
  # while a direct push to main bypassed every check.
  _fix_reset
  printf '%s' "$RS_PR_CHECKS" > "$lab/fix/rulesets.json"
  printf '{"conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"validate"},{"context":"verify"}]}}]}' \
    > "$lab/fix/ruleset-1.json"
  _gate_run "checks-without-a-pr-rule-is-not-a-gate" 3 'PARTIAL.*pr=no' --require validate,verify

  # --- a PR with nothing required is the state this repo was actually in -----
  _fix_reset
  printf '%s' "$RS_PR_CHECKS" > "$lab/fix/rulesets.json"
  printf '{"conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"pull_request"}]}' \
    > "$lab/fix/ruleset-1.json"
  _gate_run "a-pr-requiring-no-checks-is-not-a-gate" 3 'PARTIAL.*checks=none'

  # --- REGRESSION: a rule for another branch says nothing about main ---------
  # Nothing in the first version read conditions.ref_name, so rules were
  # flattened across every active ruleset and a release/* ruleset gated main.
  _fix_reset
  printf '%s' "$RS_PR_CHECKS" > "$lab/fix/rulesets.json"
  printf '{"conditions":{"ref_name":{"include":["refs/heads/release/*"],"exclude":[]}},"rules":[{"type":"pull_request"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"validate"}]}}]}' \
    > "$lab/fix/ruleset-1.json"
  _gate_run "a-ruleset-for-another-branch-does-not-gate-main" 4 'NONE'

  # --- exclude beats include ------------------------------------------------
  _fix_reset
  printf '%s' "$RS_PR_CHECKS" > "$lab/fix/rulesets.json"
  printf '{"conditions":{"ref_name":{"include":["~ALL"],"exclude":["refs/heads/main"]}},"rules":[{"type":"pull_request"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"validate"}]}}]}' \
    > "$lab/fix/ruleset-1.json"
  _gate_run "an-excluded-branch-is-not-gated" 4 'NONE'

  # --- an inactive ruleset is not a gate ------------------------------------
  _fix_reset
  printf '[{"id":1,"enforcement":"disabled"}]' > "$lab/fix/rulesets.json"
  printf '%s' "$RULE_PR_CHECKS" > "$lab/fix/ruleset-1.json"
  _gate_run "an-inactive-ruleset-is-not-a-gate" 4 'NONE'

  # --- the contexts are checked BY NAME -------------------------------------
  # The first version printed "PR + required status checks" without inspecting
  # which, so swapping validate/verify for a context that never runs still
  # passed — while docs/state.md and CLAUDE.md both name the two specifically.
  _fix_reset
  printf '%s' "$RS_PR_CHECKS" > "$lab/fix/rulesets.json"
  printf '{"conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"pull_request"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"lint"}]}}]}' \
    > "$lab/fix/ruleset-1.json"
  _gate_run "required-contexts-are-checked-by-name" 3 'missing=validate,verify' --require validate,verify

  # --- nothing anywhere ------------------------------------------------------
  _fix_reset
  printf '[]' > "$lab/fix/rulesets.json"
  _gate_run "no-rule-from-either-mechanism-is-exit-4" 4 'NONE.*via=none'

  # --- ADR-0017: a paid feature this repository does not have ----------------
  # Branch protection and rulesets are Pro/Team features. On a PRIVATE repo on a
  # free plan both endpoints answer 403 with GitHub's own "Upgrade to GitHub
  # Pro" sentence. That is an ANSWER — no gate can exist, so none was missed —
  # and reporting it as exit 2 refused every private product at commissioning
  # time (F120). The verdict must never be GATED, and must never be 4 either:
  # "no rule exists" and "no rule CAN exist" are different facts.
  local REPO_PRIVATE='{"default_branch":"main","private":true}'
  local REPO_PUBLIC='{"default_branch":"main","private":false}'

  _fix_reset
  printf '%s' "$REPO_PRIVATE" > "$lab/fix/repo.json"
  : > "$lab/fix/rulesets.upgrade403"
  : > "$lab/fix/protection.upgrade403"
  _gate_run "an-unavailable-plan-is-exit-5-not-exit-2" 5 \
            '^UNAVAILABLE via=none pr=no checks=none missing=check$' --require check

  # The same fixture, asserted from the other side: whatever else this verdict
  # says, it may not say the repository is gated. UNAVAILABLE means ungated for
  # a reason no configuration can fix, and a caller reading exit 5 as success
  # would launch unattended work against an unprotected main.
  _fix_reset
  printf '%s' "$REPO_PRIVATE" > "$lab/fix/repo.json"
  : > "$lab/fix/rulesets.upgrade403"
  : > "$lab/fix/protection.upgrade403"
  out="$(PATH="$lab/bin:$PATH" FIX="$lab/fix" "$script" owner/repo --require check 2>/dev/null)"
  rc=$?
  if [ "$rc" != 0 ] && ! printf '%s\n' "$out" | grep -q 'GATED'; then
    ok "an-unavailable-repo-is-never-reported-gated"
  else
    bad "an-unavailable-repo-is-never-reported-gated" \
        "an ungatable repository must never report a gate (exit $rc, verdict '${out:-<empty>}')"
  fi

  # REGRESSION: the sentinel is a GitHub-owned prose string, so it is only ever
  # read as a conjunction with what GitHub says about the repo itself. A public
  # repository cannot be short of a paid feature; that reading is incoherent and
  # incoherent is UNKNOWN, never a licence to skip the gate.
  #
  # THE EXIT CODE ALONE DOES NOT PIN THIS, which a mutation run proved: drop the
  # `.private` conjunct from the RULESETS arm only, and the classic arm's
  # generic `HTTP 403` grep still refuses, so exit 2 survives and the case stays
  # green over a live hole. The refusal is therefore asserted by WHICH ARM
  # produced it — the one under test — and not merely by its status.
  _fix_reset
  printf '%s' "$REPO_PUBLIC" > "$lab/fix/repo.json"
  : > "$lab/fix/rulesets.upgrade403"
  : > "$lab/fix/protection.upgrade403"
  err="$(PATH="$lab/bin:$PATH" FIX="$lab/fix" "$script" owner/repo --require check 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" = 2 ] && printf '%s\n' "$err" | grep -Fq 'cannot read rulesets'; then
    ok "a-public-repo-upgrade-403-is-exit-2"
  else
    bad "a-public-repo-upgrade-403-is-exit-2" \
        "a public repo claiming a paid-feature 403 is incoherent and must be refused BY THE RULESETS ARM (exit $rc: $(printf '%s' "$err" | head -1))"
  fi

  # The SAME conjunct, on the classic arm, needs its own fixture: with both
  # mechanisms unavailable the rulesets arm refuses first and the classic arm is
  # never reached, so the case above cannot see it. Here rulesets ANSWERS (`[]`)
  # and only classic claims the paid-feature 403. Both readings exit 2, so once
  # again the status alone pins nothing — it is the diagnostic that says which
  # branch decided, and "needs admin" is the correct one for a public repo.
  _fix_reset
  printf '%s' "$REPO_PUBLIC" > "$lab/fix/repo.json"
  printf '[]' > "$lab/fix/rulesets.json"
  : > "$lab/fix/protection.upgrade403"
  err="$(PATH="$lab/bin:$PATH" FIX="$lab/fix" "$script" owner/repo --require check 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" = 2 ] && printf '%s\n' "$err" | grep -Fq 'cannot read classic protection'; then
    ok "a-public-repo-classic-upgrade-403-is-needs-admin"
  else
    bad "a-public-repo-classic-upgrade-403-is-needs-admin" \
        "a public repo cannot lack a paid feature; the classic arm must refuse it as a permissions problem (exit $rc: $(printf '%s' "$err" | head -1))"
  fi

  # REGRESSION: the new branch must not swallow the 403 that was always exit 2.
  # "Must have admin" on a private repo is a token problem, not a plan problem.
  #
  # BOTH mechanisms carry the generic 403 deliberately. With only one of them
  # set, a widened sentinel (matching any "403" rather than the sentence) still
  # produced exit 2 — via the one-mechanism-disagrees branch — and this case
  # passed over the defect. With both set, a widened sentinel reaches exit 5 and
  # the case goes red, which is also the realistic shape: a token short of admin
  # fails to read either mechanism.
  _fix_reset
  printf '%s' "$REPO_PRIVATE" > "$lab/fix/repo.json"
  : > "$lab/fix/rulesets.403"
  : > "$lab/fix/protection.403"
  _gate_run "a-needs-admin-403-is-still-exit-2" 2 "" --require check

  # One mechanism unavailable while the other ANSWERS (404 = "not protected")
  # cannot both be true of one repository. Rather than pick a reading, refuse.
  _fix_reset
  printf '%s' "$REPO_PRIVATE" > "$lab/fix/repo.json"
  : > "$lab/fix/rulesets.upgrade403"
  _gate_run "one-mechanism-unavailable-is-exit-2" 2 "" --require check

  # --- F5: a control that could not run has NOT passed ----------------------
  # Both of these used to be indistinguishable from "ungated", which would have
  # turned preflight red on every private free-plan repo — F79's own condition.
  _fix_reset
  : > "$lab/fix/rulesets.403"
  _gate_run "unreadable-rulesets-is-exit-2-not-exit-4" 2 ""

  _fix_reset
  printf '[]' > "$lab/fix/rulesets.json"
  : > "$lab/fix/protection.403"
  _gate_run "unreadable-classic-protection-is-exit-2" 2 ""

  # A repo that cannot be read at all is also 2, not 4.
  _fix_reset
  : > "$lab/fix/norepo"
  _gate_run "an-unreadable-repo-is-exit-2" 2 ""

  # --- a malformed slug is a naming bug, not a permissions problem -----------
  # `ssh://git@github.com/o/r` used to be passed through verbatim; every call
  # 404'd and the operator was told they had no access.
  local out rc
  out="$(PATH="$lab/bin:$PATH" FIX="$lab/fix" "$script" 'ssh://git@github.com/o/r' 2>&1 >/dev/null)"
  rc=$?
  if printf '%s' "$out" | grep -q 'not an owner/repo slug'; then
    ok "a-malformed-slug-is-named-not-misreported"
  else
    bad "a-malformed-slug-is-named-not-misreported" \
        "expected a slug-shape refusal, got: ${out:-<empty>}"
  fi

  # --- one implementation ----------------------------------------------------
  # preflight must ASK the primitive, not re-derive the answer. A second copy is
  # how the metrics/verify pair drifted for weeks (F67), and this check exists
  # because that exact drift is the reason merge-gate.sh was extracted.
  if grep -q 'merge-gate\.sh' scripts/preflight.sh \
     && ! grep -q '/rulesets' scripts/preflight.sh; then
    ok "preflight-has-no-second-implementation"
  else
    bad "preflight-has-no-second-implementation" \
        "preflight.sh must route the gate question through scripts/merge-gate.sh and must not call the rulesets API itself"
  fi

  # --- the check cannot vanish when gh is absent -----------------------------
  # The first version was nested inside `if command -v gh`, so on a host without
  # gh it emitted no PASS, no FAIL and no WARN — it simply did not appear, which
  # is the "could not run has NOT passed" violation its own comment invoked.
  if grep -q 'gh is not on PATH — cannot ask whether main is gated' scripts/preflight.sh; then
    ok "a-missing-gh-warns-rather-than-vanishing"
  else
    bad "a-missing-gh-warns-rather-than-vanishing" \
        "preflight must WARN when gh is absent; a check that emits nothing has not passed (F5)"
  fi

  # --- help is anchored to content, not to line numbers ---------------------
  if PATH="$lab/bin:$PATH" "$script" --help 2>/dev/null | grep -q 'Exit codes'; then
    ok "help-is-anchored-to-the-header-rules"
  else
    bad "help-is-anchored-to-the-header-rules" \
        "--help must print the header block; a sed line range goes blind the first time a paragraph moves"
  fi
}
wants gate      && run_gate_group

# ---------------------------------------------------------------------------
# docs/ — CHUNK-10's launch ledger is an operator contract, not four essays.
# These assertions deliberately use stable headings and disposition tokens;
# historical measurements beneath the audit headers remain untouched.
# ---------------------------------------------------------------------------
run_docs_group() {
  group docs
  local audit=docs/audit-forgeboard-2026-07-30.md
  local roadmap=docs/roadmap-first-run.md
  local state=docs/state.md
  local guide=docs/operator-guide.md
  local id expected header bad_headers=0

  _docs_slice_contract_ok() { # $1=guide $2=audit
    local checked_guide="$1" checked_audit="$2" slice f40
    slice="$(awk '
      /^\*\*Isolate every human-driven slice/ { printing=1 }
      printing && /^\*\*Reclaim merged chunk worktrees/ { exit }
      printing { print }
    ' "$checked_guide" | tr '\n' ' ' | tr -s ' ')"
    f40="$(awk '
      /^### F40([^0-9]|$)/ { printing=1 }
      printing && /^## Priority order/ { exit }
      printing { print }
    ' "$checked_audit" | tr '\n' ' ' | tr -s ' ')"
    grep -Fq 'Reserve the main checkout for the manager/orchestrator' <<<"$slice" \
      && grep -Fq 'git worktree add ../forge-slices/<slice-id> -b slice/<slice-id> main' <<<"$slice" \
      && grep -Fq "The audit ledger is the manager's file" <<<"$slice" \
      && grep -Fq 'may read it and commit it once' <<<"$slice" \
      && grep -Fq 'must never be the only writer' <<<"$slice" \
      && grep -Fq 'exact worktree path, branch, HEAD, clean/dirty' <<<"$slice" \
      && grep -Fq 'unpushed commits' <<<"$slice" \
      && grep -Fq '**Reconciled by CHUNK-10.**' <<<"$f40" \
      && grep -Fq 'docs suite mutates those ownership and creation clauses' <<<"$f40"
  }

  _docs_f102_contract_ok() { # $1=audit $2=state
    local checked_audit="$1" checked_state="$2" f102
    f102="$(awk '
      /^### F102([^0-9]|$)/ { printing=1 }
      printing && /^### F103([^0-9]|$)/ { exit }
      printing { print }
    ' "$checked_audit" | tr '\n' ' ' | tr -s ' ')"
    grep -Fq '**Resolution evidence (CHUNK-9 independent review, 2026-08-11).**' <<<"$f102" \
      && grep -Fq '`wielas/forgeboard-report`' <<<"$f102" \
      && grep -Fq '6 pass / 3 warn / 0 skip' <<<"$f102" \
      && grep -Fq 'does not authorize the future advisory-to-blocking flip' <<<"$f102" \
      && grep -Fq '`wielas/forgeboard-report`' "$checked_state" \
      && grep -Fq '813af7f013c301869079d49b408e53788049dd0bfec1e4a57c652066fb72bc80' "$checked_state"
  }

  while IFS='|' read -r id expected; do
    [ -n "$id" ] || continue
    header="$(grep -E "^### F${id}([^0-9]|$)" "$audit" | head -1)"
    if [ -z "$header" ] || ! printf '%s' "$header" | grep -Fq "$expected"; then
      bad_headers=$((bad_headers+1))
    fi
  done <<'DISPOSITIONS'
1|CHUNK-4 CONTRACTED — PRODUCT RUN PROOF REQUIRED
2|CHUNK-4 CONTRACTED — PRODUCT RUN PROOF REQUIRED
3|PARTLY FIXED — CHUNK-4 PRODUCT RUN PROOF REQUIRED
14|FIXED BY CHUNK-6/CHUNK-7
25|STAGED BY CHUNK-9 — PRODUCT RUN REQUIRED
26|CHUNK-4 CONTRACTED — PRODUCT RUN PROOF REQUIRED
31|FIXED BY CHUNK-5
34|FIXED BY CHUNK-1
36|FIXED BY CHUNK-1
40|FIXED — RECONCILED BY CHUNK-10
44|CHUNK-4 CONTRACTED — PRODUCT RUN PROOF REQUIRED
48|FIXED BY CHUNK-5
53|DECIDED BY ADR-0012 — PRODUCT RUN PROOF REQUIRED
57|FIXED BY CHUNK-2
81|SUPERSEDED BY CHUNK-10
91|FIXED BY CHUNK-3
92|FIXED BY CHUNK-3
93|FIXED BY CHUNK-3
101|RESOLVED BY CHUNK-3 / ADR-0012
102|RESOLVED BY CHUNK-9
103|RESOLVED BY ADR-0012 — RECONCILED BY CHUNK-10
DISPOSITIONS
  if [ "$bad_headers" = 0 ]; then
    ok "launch-ledger-reconciles-touched-findings"
  else
    bad "launch-ledger-reconciles-touched-findings" \
        "$bad_headers readiness finding header(s) lack their closing chunk or remaining proof"
  fi

  if grep -Fq '**Status: superseded as a planning proposal' "$roadmap" \
     && grep -Fq '### Landed tracks' "$roadmap" \
     && grep -Fq '### Remaining proof' "$roadmap" \
     && grep -Fq '### Operational run sequence' "$roadmap"; then
    ok "launch-roadmap-separates-state-and-sequence"
  else
    bad "launch-roadmap-separates-state-and-sequence" \
        "roadmap must label the proposal superseded and separate landed tracks, remaining proof, and run sequence"
  fi

  if _docs_slice_contract_ok "$guide" "$audit"; then
    ok "launch-slices-own-worktrees-and-manager-owned-ledger"
  else
    bad "launch-slices-own-worktrees-and-manager-owned-ledger" \
        "F40 requires an isolated sibling worktree, manager-owned main/ledger, and an explicit handoff"
  fi

  local mutated="$TMPROOT/docs-contract-mutations"
  mkdir -p "$mutated"
  sed 's#git worktree add ../forge-slices/<slice-id> -b slice/<slice-id> main#git switch -c slice/<slice-id> main#' \
    "$guide" > "$mutated/operator-guide.md"
  sed "s#The audit ledger is the manager's file#The audit ledger is the slice's file#" \
    "$guide" > "$mutated/operator-guide-owner.md"
  if _docs_slice_contract_ok "$mutated/operator-guide.md" "$audit" \
     || _docs_slice_contract_ok "$mutated/operator-guide-owner.md" "$audit"; then
    bad "launch-slice-contract-mutation-is-caught" \
        "a guide without isolated creation or manager ledger ownership still satisfied F40"
  else
    ok "launch-slice-contract-mutation-is-caught"
  fi

  local cleanup
  cleanup="$(sed -n '/^\*\*Reclaim merged chunk worktrees/,/^\*\*Reading a live board/p' "$guide")"
  if printf '%s' "$cleanup" | grep -Fq 'only reaches worktrees under `<project>/.worktrees/`' \
     && printf '%s' "$cleanup" | grep -Fq '**Explicit review outside the bound.**' \
     && printf '%s' "$cleanup" | grep -Fq 'Never widen the unattended sweep'; then
    ok "launch-cleanup-stays-bounded"
  else
    bad "launch-cleanup-stays-bounded" \
        "operator cleanup must retain the .worktrees boundary and require explicit review outside it"
  fi

  local f81 f103
  f81="$(awk '
    /^### F81([^0-9]|$)/ { printing=1 }
    printing && /^### F82([^0-9]|$)/ { exit }
    printing { print }
  ' "$audit")"
  f103="$(awk '
    /^### F103([^0-9]|$)/ { printing=1 }
    printing && /^## Ledger addition from the merge-gate slice/ { exit }
    printing { print }
  ' "$audit")"
  if printf '%s' "$f81" | grep -Fq 'It is **not edited here**' \
     && printf '%s' "$f81" | grep -Fq '**Superseding decision (CHUNK-10).' \
     && printf '%s' "$f103" | grep -Fq 'Recorded because a future reader' \
     && printf '%s' "$f103" | grep -Fq '**Superseding record (CHUNK-10).' \
     && printf '%s' "$f103" | grep -Fq 'ADR-0012 D12.4'; then
    ok "launch-prior-dispositions-are-superseded"
  else
    bad "launch-prior-dispositions-are-superseded" \
        "F81/F103 must retain their original text and append linked CHUNK-10 superseding records"
  fi

  if _docs_f102_contract_ok "$audit" "$state"; then
    ok "launch-f102-cites-real-product-roadmap"
  else
    bad "launch-f102-cites-real-product-roadmap" \
        "F102 must name the measured product, advisory result, report digest, and still-pending blocking decision"
  fi

  sed 's#wielas/forgeboard-report#wielas/fixture#g' \
    "$audit" > "$mutated/audit.md"
  if _docs_f102_contract_ok "$mutated/audit.md" "$state"; then
    bad "launch-f102-evidence-mutation-is-caught" \
        "changing the real product identity still satisfied F102"
  else
    ok "launch-f102-evidence-mutation-is-caught"
  fi

  local shared='make roadmap-check PROJECT="$PROJECT"' file missing=0
  for file in "$audit" "$roadmap" "$state" "$guide"; do
    grep -Fq "$shared" "$file" || missing=$((missing+1))
  done
  if [ "$missing" = 0 ]; then
    ok "launch-docs-share-next-command"
  else
    bad "launch-docs-share-next-command" \
        "$missing of the four launch documents do not name '$shared' as the next command"
  fi
}
wants docs      && run_docs_group

# ---------------------------------------------------------------------------
# quota/ — the usage-limit park (ADR-0016).
#
# Codex quota is a rolling window whose shape the provider chooses and can
# change. Nothing here may assume a window length: every case drives the real
# decision function over checked-in streams in scripts/fixtures/quota/, and the
# end-to-end cases drive the real runner against a stubbed `codex` on PATH —
# the technique gate/ already uses for `gh`. This group spends nothing.
#
# Each case asserts both halves where there are two: the program behaves, and
# the skill still calls it. A behavioural test of a program nothing invokes is
# green and worthless.
# ---------------------------------------------------------------------------
run_quota_group() {
  group quota
  local qw=scripts/quota-window.py
  local runner=scripts/codex-run.sh
  local fx=scripts/fixtures/quota
  local lane=skills/forge-lane/SKILL.md

  if [ ! -x "$qw" ] || [ ! -x "$runner" ]; then
    bad "runner-and-parser-exist" "$qw and $runner must both exist and be executable"
    return
  fi

  # THE CLOCK IS PINNED. Fixtures carry literal epochs, and the parser now
  # (correctly) treats a reset that has already passed as stale evidence rather
  # than a live block. Judged against the wall clock, every fixture here would
  # therefore start returning `clear` the moment real time overtook the numbers
  # in it -- the whole group going quietly, permanently green on a date nobody
  # chose. A checked-in epoch is only meaningful beside a checked-in now.
  local QNOW=1786900000          # before every reset any fixture states
  local QLATER=1788000000        # after every reset any fixture states
  _q() { "$qw" --threshold "${2:-95}" --now "${3:-$QNOW}" "$fx/$1.jsonl" 2>/dev/null; }

  # THE case. A short window clearing in minutes and a weekly one clearing in
  # days are both spent; the run is blocked until BOTH clear. Waking at the
  # nearer reset wakes straight back into a block, and a lane looping on that
  # burns a night making no progress.
  if [ "$(_q both-windows-exhausted)" = "blocked wake_at=1787200231 windows=primary,secondary" ]; then
    ok "latest-reset-wins"
  else
    bad "latest-reset-wins" \
        "two exhausted windows must wait for max(resets_at); got '$(_q both-windows-exhausted)'"
  fi

  # The mutation that proves the case above is load-bearing rather than merely
  # agreeing with today's fixture: swap max for min and this group must redden.
  local qwmut="$TMPROOT/quota-window-min.py"
  sed 's/int(max(resets))/int(min(resets))/' "$qw" > "$qwmut" && chmod +x "$qwmut"
  if [ "$(sed -n 's/.*int(\(m..\)(resets)).*/\1/p' "$qw" | head -1)" = max ] \
     && [ "$("$qwmut" --threshold 95 --now $QNOW "$fx/both-windows-exhausted.jsonl" 2>/dev/null)" \
          = "blocked wake_at=1787000000 windows=primary,secondary" ]; then
    ok "nearest-reset-mutation-is-caught"
  else
    bad "nearest-reset-mutation-is-caught" \
        "the max-over-resets_at rule must be the thing latest-reset-wins tests"
  fi

  # The same rule from the other side, and the half that `latest-reset-wins`
  # structurally cannot see: max runs over the BLOCKED windows, not over every
  # window reported. A spent short window beside a healthy weekly one is the
  # ordinary shape under the rolling regime, and taking the weekly reset there
  # sleeps five days because five hours filled.
  local qwall="$TMPROOT/quota-window-allwindows.py"
  sed 's/for _, w in blocked)/for _, w in windows)/' "$qw" > "$qwall" \
    && chmod +x "$qwall"
  if [ "$(_q short-window-exhausted)" = "blocked wake_at=1787000000 windows=primary" ] \
     && [ "$("$qwall" --threshold 95 --now $QNOW "$fx/short-window-exhausted.jsonl" 2>/dev/null)" \
          = "blocked wake_at=1787200231 windows=primary" ]; then
    ok "the-wait-is-bounded-by-the-blocked-windows"
  else
    bad "the-wait-is-bounded-by-the-blocked-windows" \
        "max must run over blocked windows only; got '$(_q short-window-exhausted)'"
  fi

  # When the provider NAMES the window it refused on, that name is the most
  # precise fact in the payload. Widening it to every window is the same
  # five-days-for-five-hours failure, reached through the hard-limit path
  # instead of the percentage one -- and it is invisible to
  # `hard-limit-outranks-percentage`, whose fixture has a null secondary.
  local qwwide="$TMPROOT/quota-window-widenamed.py"
  sed 's/blocked = named if named else windows/blocked = windows/' "$qw" \
    > "$qwwide" && chmod +x "$qwwide"
  if [ "$(_q named-window-reached)" = "blocked wake_at=1787000000 windows=primary" ] \
     && [ "$("$qwwide" --threshold 95 --now $QNOW "$fx/named-window-reached.jsonl" 2>/dev/null)" \
          = "blocked wake_at=1787500000 windows=primary,secondary" ]; then
    ok "a-named-refusal-blocks-only-the-window-it-names"
  else
    bad "a-named-refusal-blocks-only-the-window-it-names" \
        "rate_limit_reached_type must not widen to healthy windows; got '$(_q named-window-reached)'"
  fi

  # A reset that has already passed describes a window which has SINCE reset.
  # Believing it is how a pre-flight read of an old rollout, or a reactive read
  # of a log holding an earlier attempt, parks on a limit that expired hours
  # ago -- with nothing bounding the wait by default.
  if [ "$(_q both-windows-exhausted 95 $QLATER)" = clear ] \
     && [ "$(_q named-window-reached 95 $QLATER)" = clear ]; then
    ok "a-reset-in-the-past-is-stale-not-blocking"
  else
    bad "a-reset-in-the-past-is-stale-not-blocking" \
        "an elapsed resets_at must not block; got '$(_q both-windows-exhausted 95 $QLATER)'"
  fi

  # An epoch reported in MILLISECONDS is the shape most likely to arrive
  # unannounced, and it reads as the year 58000. Sleeping on it is
  # indistinguishable from hanging, so it must degrade to a bounded re-probe.
  if [ "$("$qw" --threshold 95 --now $QNOW \
            --rate-limits '{"primary":{"used_percent":100.0,"resets_at":1787000000000}}' \
            2>/dev/null)" = "blocked wake_at=unknown windows=primary" ]; then
    ok "an-incredible-reset-is-not-slept-on"
  else
    bad "an-incredible-reset-is-not-slept-on" \
        "a resets_at beyond the horizon must read as wake_at=unknown, not as a wait"
  fi

  # A stream carrying no rate-limit data at all -- including a torn final line,
  # which is what a killed process leaves -- is unknown, and unknown lets the
  # run start. Refusing there would deadlock a machine that has never run Codex.
  "$qw" --threshold 95 --now $QNOW "$fx/no-rate-limits.jsonl" >/dev/null 2>&1
  if [ "$?" = 3 ] && [ "$(_q no-rate-limits)" = "unknown no-rate-limit-data" ]; then
    ok "a-stream-without-windows-is-unknown-not-clear"
  else
    bad "a-stream-without-windows-is-unknown-not-clear" \
        "no rate-limit data must be exit 3 unknown; got '$(_q no-rate-limits)'"
  fi

  # A marker is evidence about the moment it was written. Carried forward over
  # a FRESHER snapshot, one refused attempt condemns every later reading of the
  # same log however healthy the provider now says the windows are -- which is
  # exactly how a run parks forever on a stale log.
  local qsticky="$TMPROOT/sticky.jsonl"
  {
    printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"resets_at":1787000000}}}}\n'
    printf '{"type":"event_msg","payload":{"type":"error","error_type":"usage_limit_reached"}}\n'
    printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5.0,"resets_at":1787000000}}}}\n'
  } > "$qsticky"
  if [ "$("$qw" --threshold 95 --now $QNOW "$qsticky" 2>/dev/null)" = clear ]; then
    ok "a-fresh-snapshot-supersedes-an-earlier-refusal"
  else
    bad "a-fresh-snapshot-supersedes-an-earlier-refusal" \
        "a reached marker must not outlive the snapshot it described"
  fi

  # Rollouts on the machine this shipped from still report ONE window of 10080
  # minutes with a null secondary; the regime this feature exists for reports a
  # short window beside it. Both must read without a branch on window_minutes.
  if [ "$(_q weekly-only-clear)" = clear ] \
     && [ "$(_q five-hour-and-weekly-clear)" = clear ] \
     && [ "$(_q weekly-only-clear 30)" = "blocked wake_at=1787200231 windows=primary" ] \
     && ! grep -qE 'window_minutes[[:space:]]*(==|!=|<|>)' "$qw"; then
    ok "window-shape-is-not-hardcoded"
  else
    bad "window-shape-is-not-hardcoded" \
        "both the weekly-only and short-window shapes must read, with no window length in the parser"
  fi

  # The provider already refused. used_percent reads 98 in this fixture, under
  # the threshold — a percentage must not overrule a stated refusal.
  if [ "$(_q limit-reached-error)" = "blocked wake_at=1787000000 windows=primary" ]; then
    ok "hard-limit-outranks-percentage"
  else
    bad "hard-limit-outranks-percentage" \
        "a usage_limit_reached marker must block below the threshold; got '$(_q limit-reached-error)'"
  fi

  # A null used_percent is unknown, not clear. Counting it clear is how a
  # parser that quietly stopped parsing keeps licensing runs until one dies.
  "$qw" --threshold 95 "$fx/null-used-percent.jsonl" >/dev/null 2>&1
  if [ "$?" = 3 ] && [ "$(_q null-used-percent)" != clear ]; then
    ok "missing-fields-are-unknown-not-clear"
  else
    bad "missing-fields-are-unknown-not-clear" \
        "a null used_percent must be exit 3 'unknown', never 'clear'"
  fi

  if [ "$(_q blocked-without-resets)" = "blocked wake_at=unknown windows=primary" ]; then
    ok "blocked-without-reset-is-not-clear"
  else
    bad "blocked-without-reset-is-not-clear" \
        "exhausted with no resets_at is still blocked; got '$(_q blocked-without-resets)'"
  fi

  # The horizon is one fact held in two languages: quota-window.py refuses to
  # REPORT a reset beyond it, codex-run.sh refuses to SLEEP past it. If they
  # drift apart, one of the two defences silently stops being reachable and
  # everything stays green -- so make them one number by assertion, since the
  # code cannot share it.
  local qw_h cr_h
  qw_h="$(python3 -c 'import re; m = re.search(r"^WAKE_HORIZON = (.+)$", open("scripts/quota-window.py").read(), re.M); print(eval(m.group(1)))' 2>/dev/null)"
  cr_h="$(sed -n 's/^WAKE_HORIZON=\([0-9][0-9]*\).*/\1/p' scripts/codex-run.sh | head -1)"
  if [ -n "$qw_h" ] && [ "$qw_h" = "$cr_h" ]; then
    ok "the-horizon-is-one-number (${qw_h}s)"
  else
    bad "the-horizon-is-one-number" \
        "quota-window.py says '$qw_h' and codex-run.sh says '$cr_h'"
  fi

  # ---- end to end, against a stubbed codex --------------------------------
  #
  # Every end-to-end case below runs under a watchdog. There is no `timeout(1)`
  # to reach for -- macOS ships none -- and the regressions these cases exist to
  # catch are precisely the ones that make the runner never return. A hang has
  # no colour: it is worse than the skip/warn degradation CLAUDE.md warns about,
  # because CI reports nothing at all rather than something misleading.
  _qrun() { # <seconds> <command...>  -> merged output on stdout, real rc
    local limit="$1"; shift
    local out="$TMPROOT/qrun-out.$$" pid wpid rc
    "$@" > "$out" 2>&1 &
    pid=$!
    # stdout to /dev/null, or this subshell holds the caller's command
    # substitution open for the full sleep even after the runner exits.
    ( sleep "$limit"; kill -9 "$pid" ) >/dev/null 2>&1 &
    wpid=$!
    wait "$pid"; rc=$?
    kill -9 "$wpid" >/dev/null 2>&1
    wait "$wpid" >/dev/null 2>&1
    cat "$out"; rm -f "$out"
    return "$rc"
  }

  local qroot="$TMPROOT/quota-run" qbin qws qrt qpark
  qbin="$qroot/bin"; qws="$qroot/ws"; qrt="$qroot/runtime"; qpark="$qroot/parks"
  mkdir -p "$qbin" "$qws" "$qrt" "$qpark" "$qroot/codexhome/sessions"
  printf 'contract\n' > "$qrt/contract.md"
  ( cd "$qws" && git init -q . \
      && git -c user.email=q@q -c user.name=q commit -q --allow-empty -m init ) >/dev/null 2>&1

  # Limited on the first call, clean on the resume. Windows reset seconds out,
  # so the case exercises the real sleep rather than mocking it away.
  cat > "$qbin/codex" <<'QSTUB'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "codex-cli stub"; exit 0;; esac
for a in "$@"; do [ "$a" = resume ] && { echo "$*" > "$STUBDIR/resume-argv"
  printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":2.0,"resets_at":9999999999}}}}\n'
  printf '{"type":"event_msg","payload":{"type":"agent_message","message":"done"}}\n'
  exit 0; }; done
echo first >> "$STUBDIR/calls"
printf '{"type":"session_meta","payload":{"session_id":"verify-session-42"}}\n'
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"resets_at":%d},"secondary":{"used_percent":100.0,"resets_at":%d}}}}\n' "$(( $(date +%s) + 9 ))" "$(( $(date +%s) + 10 ))"
printf '{"type":"event_msg","payload":{"type":"error","error_type":"usage_limit_reached"}}\n'
exit 1
QSTUB
  chmod +x "$qbin/codex"

  local qrc qout
  qout="$(_qrun 120 env PATH="$qbin:$PATH" STUBDIR="$qroot" CODEX_HOME="$qroot/codexhome" \
            FORGE_LANE_RUNTIME="$qrt" FORGE_LANE_PARK_ROOT="$qpark" \
            FORGE_QUOTA_PAD=1 FORGE_QUOTA_POLL=1 FORGE_QUOTA_TICK=1 \
            "$runner" "$qws" qrun-1 qtask-1 2>&1)"
  qrc=$?
  if [ "$qrc" = 0 ] \
     && printf '%s' "$qout" | grep -q 'PARKED' \
     && printf '%s' "$qout" | grep -q 'resuming session verify-session-42' \
     && [ "$(grep -c first "$qroot/calls" 2>/dev/null)" = 1 ]; then
    ok "parks-then-resumes-the-same-session"
  else
    bad "parks-then-resumes-the-same-session" \
        "a limited run must park, wake and resume its own session exactly once (rc=$qrc)"
  fi

  # `codex exec resume` accepts neither -s, -C nor --add-dir, so a resumed run
  # that trusted inheritance would silently lose write access to the shared
  # .git — the failure that cost a rung the first time it was met.
  if grep -q 'writable_roots' "$qroot/resume-argv" 2>/dev/null \
     && grep -q 'sandbox_mode' "$qroot/resume-argv" 2>/dev/null; then
    ok "resume-carries-the-sandbox-grant"
  else
    bad "resume-carries-the-sandbox-grant" \
        "the resume path must restate the sandbox grant as -c overrides"
  fi

  # A park record left by a killed supervisor is the successor's way back into
  # the same session: a new run id means a new, empty scratch directory.
  local qrt2="$qroot/runtime2"
  mkdir -p "$qrt2" && printf 'contract\n' > "$qrt2/contract.md"
  cat > "$qpark/qtask-2.json" <<PARKED
{"schema":"forge.park.v1","task_id":"qtask-2","workspace":"$qws",
 "codex_session_id":"verify-session-99","wake_at":0,"parked_at":$(date +%s)}
PARKED
  qout="$(_qrun 120 env PATH="$qbin:$PATH" STUBDIR="$qroot" CODEX_HOME="$qroot/codexhome" \
            FORGE_LANE_RUNTIME="$qrt2" FORGE_LANE_PARK_ROOT="$qpark" \
            FORGE_QUOTA_PAD=1 FORGE_QUOTA_POLL=1 FORGE_QUOTA_TICK=1 \
            "$runner" "$qws" qrun-2 qtask-2 2>&1)"
  if printf '%s' "$qout" | grep -q 'adopting session verify-session-99'; then
    ok "park-record-is-adopted-by-a-successor"
  else
    bad "park-record-is-adopted-by-a-successor" \
        "a durable park record must let a NEW run id resume the parked session"
  fi

  # Adoption is for a supervisor killed DURING a park. A record naming another
  # workspace is a moved card, and one too old to date is debris -- resuming
  # either sends "a usage limit interrupted you, continue where you stopped"
  # into a session that was never interrupted, against a contract that has had
  # a week to change. Both refusals are checked; only the first was before.
  local qrt5="$qroot/runtime5"
  mkdir -p "$qrt5" && printf 'contract\n' > "$qrt5/contract.md"
  cat > "$qpark/qtask-5.json" <<PARKED5
{"schema":"forge.park.v1","task_id":"qtask-5","workspace":"/somewhere/else",
 "codex_session_id":"verify-session-elsewhere","parked_at":$(date +%s)}
PARKED5
  qout="$(_qrun 120 env PATH="$qbin:$PATH" STUBDIR="$qroot" CODEX_HOME="$qroot/codexhome" \
            FORGE_LANE_RUNTIME="$qrt5" FORGE_LANE_PARK_ROOT="$qpark" \
            FORGE_QUOTA_PAD=1 FORGE_QUOTA_POLL=1 FORGE_QUOTA_TICK=1 \
            "$runner" "$qws" qrun-5 qtask-5 2>&1)"
  local qforeign="$qout"
  cat > "$qpark/qtask-6.json" <<PARKED6
{"schema":"forge.park.v1","task_id":"qtask-6","workspace":"$qws",
 "codex_session_id":"verify-session-ancient","parked_at":1}
PARKED6
  local qrt6="$qroot/runtime6"
  mkdir -p "$qrt6" && printf 'contract\n' > "$qrt6/contract.md"
  qout="$(_qrun 120 env PATH="$qbin:$PATH" STUBDIR="$qroot" CODEX_HOME="$qroot/codexhome" \
            FORGE_LANE_RUNTIME="$qrt6" FORGE_LANE_PARK_ROOT="$qpark" \
            FORGE_QUOTA_PAD=1 FORGE_QUOTA_POLL=1 FORGE_QUOTA_TICK=1 \
            "$runner" "$qws" qrun-6 qtask-6 2>&1)"
  if printf '%s' "$qforeign" | grep -q 'ignoring park record: it names workspace' \
     && printf '%s' "$qout" | grep -q 'ignoring park record: parked' \
     && ! printf '%s' "$qout" | grep -q 'adopting session verify-session-ancient'; then
    ok "a-record-that-is-foreign-or-undatable-is-not-adopted"
  else
    bad "a-record-that-is-foreign-or-undatable-is-not-adopted" \
        "adoption must refuse another workspace's record and one past the TTL"
  fi

  # THE regression case, and the one no fixture can reach: the reactive check
  # must read the CURRENT attempt, not the append-only log.
  #
  # Attempt 1 is genuinely limited, and the provider does not say when the
  # window lifts. Attempt 2 resumes and dies of something else entirely -- a
  # dropped connection, an expired token -- before saying anything about quota
  # at all.
  #
  # Both halves of that stub are load-bearing, and each defeats a DIFFERENT
  # defence, which is the only way to isolate this one. Attempt 2's silence
  # means the newest snapshot in the append-only log is still attempt 1's, so
  # superseding a stale marker cannot save it. Attempt 1's missing resets_at
  # means that evidence never ages out, so dropping elapsed windows cannot save
  # it either. What is left is the question this case exists to ask: which file
  # did the reactive check read?
  #
  # Reading the attempt's own stream finds no rate-limit data, which is
  # `unknown`, which routes to the env: block this actually is. Reading the run
  # log finds attempt 1's exhausted window, parks, wakes, re-invokes, and finds
  # the same dead evidence again -- every POLL seconds, forever, spending quota
  # on each pass, while the card heartbeats and looks perfectly alive. MAX_WAIT
  # is 0 by default, so nothing bounds it. The watchdog is what turns that into
  # a red case rather than a suite that never returns.
  cat > "$qbin/codex" <<'QSTUB5'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "codex-cli stub"; exit 0;; esac
for a in "$@"; do [ "$a" = resume ] && {
  printf '{"type":"event_msg","payload":{"type":"error","message":"connection reset by peer"}}\n'
  exit 7; }; done
printf '{"type":"session_meta","payload":{"session_id":"verify-session-11"}}\n'
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0}}}}\n'
exit 1
QSTUB5
  chmod +x "$qbin/codex"
  local qrt7="$qroot/runtime7"
  mkdir -p "$qrt7" && printf 'contract\n' > "$qrt7/contract.md"
  qout="$(_qrun 30 env PATH="$qbin:$PATH" STUBDIR="$qroot" CODEX_HOME="$qroot/codexhome" \
            FORGE_LANE_RUNTIME="$qrt7" FORGE_LANE_PARK_ROOT="$qpark" \
            FORGE_QUOTA_PAD=1 FORGE_QUOTA_POLL=1 FORGE_QUOTA_TICK=1 \
            "$runner" "$qws" qrun-7 qtask-7 2>&1)"
  qrc=$?
  # And the mechanism the case turns on, asserted directly: the run log
  # accumulates across attempts while the current-attempt log is truncated for
  # each one. If those two ever became the same file, every defence above is
  # reasoning about a distinction that no longer exists.
  if [ "$qrc" = 4 ] \
     && [ "$(printf '%s' "$qout" | grep -c PARKED)" = 1 ] \
     && printf '%s' "$qout" | grep -q 'no usage limit' \
     && grep -q used_percent "$qrt7/codex-events.jsonl" \
     && ! grep -q used_percent "$qrt7/codex-events.current.jsonl"; then
    ok "the-reactive-check-reads-the-current-attempt"
  else
    bad "the-reactive-check-reads-the-current-attempt" \
        "a later failure must be judged on the attempt's own stream, not the run's log (rc=$qrc)"
  fi

  # A knob that reads as garbage must not degrade quietly. MAX_WAIT=4h makes
  # every `-gt` test fail with `integer expression expected`, which && reads as
  # false -- silently removing the only bound on the wait. PARK_PCT=high reaches
  # argparse, which exits 2, leaving an empty verdict that turns every quota
  # block into a hard env: failure. Both must be usage errors, by name.
  local qrt8="$qroot/runtime8" qbadrc=0 qbadout
  mkdir -p "$qrt8" && printf 'contract\n' > "$qrt8/contract.md"
  qbadout="$(_qrun 60 env PATH="$qbin:$PATH" CODEX_HOME="$qroot/codexhome" \
               FORGE_LANE_RUNTIME="$qrt8" FORGE_LANE_PARK_ROOT="$qpark" \
               FORGE_QUOTA_MAX_WAIT=4h "$runner" "$qws" qrun-8 qtask-8 2>&1)"
  qbadrc=$?
  qout="$(_qrun 60 env PATH="$qbin:$PATH" CODEX_HOME="$qroot/codexhome" \
            FORGE_LANE_RUNTIME="$qrt8" FORGE_LANE_PARK_ROOT="$qpark" \
            FORGE_QUOTA_PARK_PCT=high "$runner" "$qws" qrun-8 qtask-8 2>&1)"
  qrc=$?
  if [ "$qbadrc" = 2 ] && [ "$qrc" = 2 ] \
     && printf '%s' "$qbadout" | grep -q 'FORGE_QUOTA_MAX_WAIT' \
     && printf '%s' "$qout" | grep -q 'FORGE_QUOTA_PARK_PCT'; then
    ok "a-knob-that-reads-as-garbage-is-a-usage-error"
  else
    bad "a-knob-that-reads-as-garbage-is-a-usage-error" \
        "an unparseable knob must exit 2 naming itself, not silently disable its own bound"
  fi

  # The record declares a schema and a successor parses it. A codex --version
  # carrying a quote must not be able to make the only route back into a
  # half-finished session unreadable.
  cat > "$qbin/codex" <<'QSTUB6'
#!/usr/bin/env bash
case "${1:-}" in --version) printf 'codex "quoted" \\ version\n'; exit 0;; esac
printf '{"type":"session_meta","payload":{"session_id":"verify-session-12"}}\n'
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"resets_at":9999999999}}}}\n'
exit 1
QSTUB6
  chmod +x "$qbin/codex"
  local qrt9="$qroot/runtime9"
  mkdir -p "$qrt9" && printf 'contract\n' > "$qrt9/contract.md"
  qout="$(_qrun 60 env PATH="$qbin:$PATH" CODEX_HOME="$qroot/codexhome" \
            FORGE_LANE_RUNTIME="$qrt9" FORGE_LANE_PARK_ROOT="$qpark" \
            FORGE_QUOTA_PAD=1 FORGE_QUOTA_POLL=1 FORGE_QUOTA_TICK=1 \
            FORGE_QUOTA_MAX_WAIT=2 "$runner" "$qws" qrun-9 qtask-9 2>&1)"
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
       "$qpark/qtask-9.json" >/dev/null 2>&1 \
     && printf '%s' "$qout" | grep -q '^[0-9:Z]* codex-run: PARK-COMMENT env: codex usage limit'; then
    ok "the-park-record-is-json-and-the-comment-is-prefixed"
  else
    bad "the-park-record-is-json-and-the-comment-is-prefixed" \
        "the record must survive a hostile --version as JSON, and §1's PARK-COMMENT marker must be what the runner prints"
  fi

  # §4 documents both. An override nothing asserts drifts out of the argv
  # silently, and a missing runtime is the substrate class, not an env failure:
  # the driver routes those differently.
  cat > "$qbin/argv-echo" <<'QARGV'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "argv-echo stub"; exit 0;; esac
echo "argv: $*" >&2
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"resets_at":9999999999}}}}\n'
exit 1
QARGV
  chmod +x "$qbin/argv-echo"
  local qrt10="$qroot/runtime10" qmodelout qsubrc
  mkdir -p "$qrt10" && printf 'contract\n' > "$qrt10/contract.md"
  qmodelout="$(_qrun 60 env PATH="$qbin:$PATH" CODEX_HOME="$qroot/codexhome" \
                 FORGE_LANE_RUNTIME="$qrt10" FORGE_LANE_PARK_ROOT="$qpark" \
                 FORGE_QUOTA_PAD=1 FORGE_QUOTA_POLL=1 FORGE_QUOTA_TICK=1 \
                 FORGE_QUOTA_MAX_WAIT=1 FORGE_CODEX_MODEL=gpt-probe-9 \
                 FORGE_CODEX_BIN="$qbin/argv-echo" "$runner" "$qws" qrun-10 qtask-10 2>&1)"
  _qrun 30 env PATH="$qbin:$PATH" FORGE_LANE_RUNTIME=/nonexistent-runtime \
    FORGE_LANE_PARK_ROOT="$qpark" "$runner" "$qws" qrun-11 qtask-11 >/dev/null 2>&1
  qsubrc=$?
  if printf '%s' "$qmodelout" | grep -q 'argv: .*-m gpt-probe-9' && [ "$qsubrc" = 3 ]; then
    ok "the-model-override-reaches-argv-and-a-missing-runtime-is-substrate"
  else
    bad "the-model-override-reaches-argv-and-a-missing-runtime-is-substrate" \
        "FORGE_CODEX_MODEL must appear as -m in the argv, and no runtime must exit 3 (got $qsubrc)"
  fi

  # Codex fails for many reasons and only one is worth waiting out. Sleeping on
  # the others would turn a five-second failure into an overnight silence.
  cat > "$qbin/codex" <<'QSTUB2'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "codex-cli stub"; exit 0;; esac
printf '{"type":"session_meta","payload":{"session_id":"verify-session-7"}}\n'
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":4.0,"resets_at":9999999999}}}}\n'
exit 7
QSTUB2
  chmod +x "$qbin/codex"
  local qrt3="$qroot/runtime3"; mkdir -p "$qrt3"; printf 'c\n' > "$qrt3/contract.md"
  # Seeded with a park record so the exit-4 path is exercised against one: a
  # run that ended for a reason unrelated to quota is not parked, and leaving a
  # live session id behind would invite a successor to adopt a session that
  # died for a reason no amount of waiting fixes.
  cat > "$qpark/qtask-3.json" <<PARKED3
{"schema":"forge.park.v1","task_id":"qtask-3","workspace":"$qws",
 "codex_session_id":"verify-session-stale","wake_at":0}
PARKED3
  qout="$(_qrun 120 env PATH="$qbin:$PATH" STUBDIR="$qroot" CODEX_HOME="$qroot/codexhome" \
            FORGE_LANE_RUNTIME="$qrt3" FORGE_LANE_PARK_ROOT="$qpark" \
            FORGE_QUOTA_PAD=1 FORGE_QUOTA_POLL=1 FORGE_QUOTA_TICK=1 \
            "$runner" "$qws" qrun-3 qtask-3 2>&1)"
  qrc=$?
  if [ "$qrc" = 4 ] && printf '%s' "$qout" | grep -q '^env: ' \
     && ! printf '%s' "$qout" | grep -q 'PARKED' \
     && [ ! -e "$qpark/qtask-3.json" ]; then
    ok "non-quota-failure-is-not-parked"
  else
    bad "non-quota-failure-is-not-parked" \
        "an unrelated nonzero exit must block as env: without sleeping, and must not leave a park record behind (rc=$qrc)"
  fi

  # An operator who bounds the wait gets a blockable reason and keeps the park
  # record — the record is the evidence, so giving up must not delete it.
  cat > "$qbin/codex" <<'QSTUB3'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "codex-cli stub"; exit 0;; esac
printf '{"type":"session_meta","payload":{"session_id":"verify-session-8"}}\n'
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"resets_at":9999999999}}}}\n'
exit 1
QSTUB3
  chmod +x "$qbin/codex"
  local qrt4="$qroot/runtime4"; mkdir -p "$qrt4"; printf 'c\n' > "$qrt4/contract.md"
  qout="$(_qrun 120 env PATH="$qbin:$PATH" STUBDIR="$qroot" CODEX_HOME="$qroot/codexhome" \
            FORGE_LANE_RUNTIME="$qrt4" FORGE_LANE_PARK_ROOT="$qpark" \
            FORGE_QUOTA_PAD=1 FORGE_QUOTA_POLL=1 FORGE_QUOTA_TICK=1 \
            FORGE_QUOTA_MAX_WAIT=2 "$runner" "$qws" qrun-4 qtask-4 2>&1)"
  qrc=$?
  if [ "$qrc" = 5 ] \
     && printf '%s' "$qout" | grep -qE '^env: codex usage limit' \
     && [ -s "$qpark/qtask-4.json" ]; then
    ok "wait-cap-blocks-with-a-board-class"
  else
    bad "wait-cap-blocks-with-a-board-class" \
        "exceeding FORGE_QUOTA_MAX_WAIT must exit 5 with an env: reason and keep the record (rc=$qrc)"
  fi

  # The other half: a runner the lane does not call is dead code. §4 must reach
  # it through ~/.forge/repo, the only path that resolves from a worktree.
  if grep -Fq '~/.forge/repo/scripts/codex-run.sh' "$lane" \
     && grep -Fq 'PARK-COMMENT' "$lane" \
     && ! grep -Eq '^UV_CACHE_DIR=.*codex exec' "$lane"; then
    ok "lane-invokes-the-runner"
  else
    bad "lane-invokes-the-runner" \
        "forge-lane §4 must call codex-run.sh via ~/.forge/repo and stop invoking codex exec inline"
  fi
}
wants quota     && run_quota_group

# ---------------------------------------------------------------------------
# manifest/ — `--list` is a hand-maintained catalogue, and nothing compared it
# to the suite it describes. Measured 2026-09-01 on this branch's base, `main`
# at 49cc60b: 48 existing cases executed under names `--list` never mentions,
# including ALL TWENTY-TWO of the `gate/` group, half of `quota/`, ADR-0017's
# four `commission/` cases, and `cli/codex-run-flags-exist` — the newest check
# in the repo was invisible to the one command a newcomer would use to discover
# checks. (An earlier draft of this comment cited the same measurement taken at
# 273b207, one merge earlier: 38 and sixteen. Correct then, stale by the time it
# was written down, in a check whose whole subject is exactly that.)
#
# This is the same failure as F65/F66 wearing different clothes: a description
# that has stopped matching reality looks exactly like one that never did. The
# repair is to make the catalogue an executable claim.
#
# It runs LAST because it can only judge a run that has finished, and only a
# COMPLETE one: a narrowed `SUITES=` emits a subset, and reporting the absent
# groups as drift would be a check that cries wolf. That case skips, loudly.
# ---------------------------------------------------------------------------
run_manifest_group() {
  group manifest

  if [ "$SUITES" != "$DEFAULT_SUITES" ]; then
    skip "list-matches-the-suite" "narrowed run (SUITES='$SUITES'); the emitted set is a subset by construction"
    return
  fi
  local emitted="$TMPROOT/emitted.txt"
  if [ ! -s "$emitted" ]; then
    bad "list-matches-the-suite" "no case names were recorded — the recorder is broken, not the manifest"
    return
  fi

  # The catalogue documents parameterised families with a `<placeholder>`, e.g.
  # `config/soul-in-sync/<profile>` standing for one case per profile. Turn each
  # placeholder into a glob so one entry legitimately covers its whole family.
  # Read the catalogue out of this script's own source rather than re-running it.
  # `"$0" --list` would re-execute the whole file, and the child installs
  # `trap cleanup EXIT` over $LABROOT — a FIXED path under $HOME, not a mktemp —
  # so the child's exit would delete the live run's sandbox lab. That is
  # harmless only while this group runs last, which is a property of the file's
  # ordering rather than anything asserted. Reading the heredoc needs no child.
  local entries="$TMPROOT/manifest.txt"
  sed -n '/^if \[ "\$LIST_ONLY" = 1 \]/,/^EOF$/p' "$0" \
    | grep -E '^[a-z]+/' | awk '{print $1}' | sort -u > "$entries"
  if [ ! -s "$entries" ]; then
    bad "list-matches-the-suite" "could not read the --list catalogue out of $0 — the reader is broken, not the manifest"
    return
  fi
  # The glob below substitutes every <placeholder> at once, so an entry carrying
  # TWO of them collapses to the group root and would match every case in it.
  # No entry does today; nothing stopped one from being added, and the failure
  # would widen the match into a silent pass, which is this repo's signature bug.
  if grep -qE '<[^>]*>.*<[^>]*>' "$entries"; then
    bad "list-matches-the-suite" \
        "a catalogue entry carries two <placeholders>; its glob collapses to the group root and would match anything: $(grep -m1 -E '<[^>]*>.*<[^>]*>' "$entries")"
    return
  fi

  local name pat matched unlisted="" unlisted_n=0 checked=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    checked=$((checked+1)); matched=0
    while IFS= read -r pat; do
      # shellcheck disable=SC2254
      case "$name" in ${pat//<*>/*}) matched=1; break;; esac
    done < "$entries"
    [ "$matched" = 1 ] || { unlisted="$unlisted $name"; unlisted_n=$((unlisted_n+1)); }
  done < <(sort -u "$emitted")

  # WHAT THIS DELIBERATELY DOES NOT CHECK: the reverse direction, "a catalogue
  # entry that matched no case in this run". Which cases emit is
  # platform-dependent — `cli/flags-exist/<command>`, `config/per-profile`,
  # `template/stamp-setup-check`, `template/push-gate` and `sweep/sweep-fixture`
  # are emitted only where a tool is ABSENT, so they appear on a bare CI runner
  # and never here. Asserting the reverse would therefore be red on one platform
  # or the other by construction.
  #
  # Note what that does NOT justify: those entries still belong in the
  # catalogue. In this direction an entry matching nothing costs nothing, and
  # leaving them out is what would turn CI red. An earlier draft of this comment
  # used the orphan argument to omit them and would have failed the required
  # `verify` check on the very PR that introduced it.
  #
  # The real cost of the missing direction: a stale entry for a deleted case is
  # not caught. That is the weaker half — fiction in the catalogue misleads,
  # while a case running undocumented is the failure that actually happened.
  if [ -n "$unlisted" ]; then
    bad "list-matches-the-suite" \
        "$unlisted_n case(s) ran under names --list does not mention:$(printf '%s' "$unlisted" | cut -c1-400)"
  else
    ok "list-matches-the-suite ($checked cases ran, every one documented)"
  fi
}
wants manifest  && run_manifest_group


printf '\n---\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ] || exit 1
