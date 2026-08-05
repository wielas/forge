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
#   ./scripts/verify.sh                 # cli + config + substrate(free) + template
#   ./scripts/verify.sh cli config      # only these groups
#   ./scripts/verify.sh --with-codex    # also run the sandbox probes (spend tokens)
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
#   metrics/    the flywheel's three numbers, computed from a checked-in SQL
#               fixture and diffed against a checked-in expectation. A schema
#               drift must fail a check rather than a quarter                (F27)
#   prejudge/   tier 1 as a program: the AST walker against a checked-in fixture
#               of real and near-miss step shapes, and the gate's own safety
#               properties — absent CI is not a pass, skip is not pass, it does
#               not speak the verdict schema, and it gates nothing       (F35)
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

WITH_CODEX=0; LIST_ONLY=0; SUITES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-codex) WITH_CODEX=1; shift;;
    --list) LIST_ONLY=1; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    cli|config|substrate|template|lane|metrics|prejudge) SUITES="$SUITES $1"; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$SUITES" ] || SUITES="cli config substrate template lane metrics prejudge"

PASS=0; FAIL=0; SKIP=0
CURRENT_GROUP=""
ok()    { PASS=$((PASS+1)); printf '  ok    %s/%s\n' "$CURRENT_GROUP" "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL  %s/%s\n        %s\n' "$CURRENT_GROUP" "$1" "$2"; }
skip()  { SKIP=$((SKIP+1)); printf '  skip  %s/%s (%s)\n' "$CURRENT_GROUP" "$1" "$2"; }
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

run_cli_group() {
  group cli
  # No early return when hermes is missing: each command is judged (or skipped)
  # on its own, so CI still checks every tool it does have.
  local claims="$TMPROOT/claims.tsv"; : > "$claims"

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
}

# ---------------------------------------------------------------------------
# config/ — the invariants, read PER PROFILE. Section 4 of preflight reads the
# default profile; workers do not run there (F11).
# ---------------------------------------------------------------------------
run_config_group() {
  group config
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
    git -c user.email=v@v -c user.name=v commit -q --allow-empty -m init >/dev/null 2>&1
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
    if [ -z "$shape_err" ]; then
      ok "kanban-json-shapes (boards list = array; show = nested under .task)"
    else
      bad "kanban-json-shapes" "$shape_err"
    fi
  fi

  # F15: codex `workspace-write` cannot commit inside a worktree without
  # --add-dir on the git common dir. Costs tokens, so it is opt-in.
  if [ "$WITH_CODEX" != 1 ]; then
    skip "codex-worktree-commit" "needs --with-codex (spends tokens)"
  elif ! command -v codex >/dev/null 2>&1; then
    skip "codex-worktree-commit" "codex not on PATH"
  else
    local out common
    common=$(git -C "$LABROOT/linked" rev-parse --git-common-dir)
    out=$(cd "$LABROOT/linked" && codex exec -s workspace-write \
            --ephemeral --ignore-user-config \
            --add-dir "$common" \
            "create a file probe.txt containing hi, then git add and git commit it" \
            </dev/null 2>&1)
    # Assert the FILE is in HEAD, not merely that some commit exists — the lab
    # repo already has an `init` commit, so "log is non-empty" proves nothing.
    # (Do not pipe `git log` into `grep -q`: grep exits early, git takes SIGPIPE,
    # and pipefail then reports a failure that did not happen.)
    if git -C "$LABROOT/linked" cat-file -e HEAD:probe.txt 2>/dev/null; then
      ok "codex-worktree-commit (--add-dir on git-common-dir still permits the commit)"
    else
      bad "codex-worktree-commit" "commit failed under workspace-write + --add-dir: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
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
cli/no-unverified-claims-in-skills  skill bodies carry no unverified-claim markers
cli/skill-body-budget             ceremonies <= 150 lines, the lane protocol <= 300
cli/soul-body-budget              every profile SOUL <= 60 lines (identity, not protocol)
cli/no-programs-in-souls          no fenced block in a SOUL exceeds 6 lines
config/terminal-timeout/<profile> >= 1800s per profile
config/write-approval/<profile>   ADR-0005 consent gate on per profile
config/external-dirs/<profile>    points at this checkout's skills/
config/soul-in-sync/<profile>     live ~/.hermes SOUL matches the one in git
config/lane-skill-scope           start-chunk/end-chunk not loadable by the lane
config/board-default-workdir      every forge board has a worktree anchor
substrate/worktree-ownership      dispatcher resolves the worktree before spawning
substrate/worktree-gitfile        .git is a file in a linked worktree; writes fail
substrate/kanban-json-shapes      the --json shapes board-bootstrap and monitoring read are unchanged
substrate/codex-worktree-commit   codex can commit in a worktree with --add-dir (--with-codex)
template/stamp,setup,hooks-installed,check-green
template/gitignores-worktrees     .worktrees/ is ignored (dispatcher worktrees live in-repo)
template/bootstrap-push-allowed   the push that CREATES main is allowed (real bare remote)
template/main-push-blocked        every later direct push to main is refused
template/main-push-guard-fails-closed  an unreachable tracked remote does not unlock the bootstrap exception
template/check-reads-no-cache     make lint cannot answer from a warm ruff cache
template/python-pinned            .python-version is stamped and the venv actually uses it
lane/env-prepared-before-codex    forge-lane §3 runs make setup — the sandbox has no network
lane/role-boundary-prepended      every contract states codex must not push/PR/touch the board
lane/driver-never-authors-diff    the cheap driver cannot substitute a direct patch for codex exec
lane/final-worktree-is-clean      hook drift and untracked leftovers block the handoff
lane/dependent-pr-must-be-merged  parent card completion cannot substitute for code integration
lane/graph-parents-are-atomic     dependent cards carry --parent before the dispatcher can claim them
lane/uv-cache-dir-is-deterministic  UV_CACHE_DIR points inside the worktree, not ~/.cache/uv
lane/verification-is-plain-make-check   no UV_OFFLINE/UV_CACHE_DIR green counts
lane/template-agents-scopes-ceremonies  AGENTS.md scopes ceremonies to the operator
lane/prejudge-delegates-its-protocol    the SOUL names the script and the script exists (ADR-0010)
lane/prejudge-terminator-mapping        rc 0 -> kanban_complete, rc 3 -> kanban_block; an outage is not a rejection
lane/driver-never-reads-the-diff        the metered driver redirects the diff; it never renders one
lane/prejudge-stores-what-happened      gate result or verdict, never a manufactured one; ci-red sentinel retired
metrics/help-exits-zero           scripts/metrics.sh --help works with no board and no ~/.hermes
metrics/fixture-numbers-exact     a checked-in SQL board reproduces a checked-in JSON expectation, field for field
metrics/detects-noncanonical-envelope  a nested chunk envelope is reported as nonconforming, not normalized or dropped
metrics/gate-blocks-are-not-bounces    forge.gate.v1 blocks are counted apart from bounces (ADR-0009 D9.4)
metrics/reads-a-quiescent-board   a board at rest, with no WAL sidecars, is still readable (F47)
metrics/is-read-only              reading a board does not change its sha256
metrics/live-schema-has-fixture-columns  the columns the fixture declares still exist on a real board
metrics/retro-skill-runs-the-command    /retro runs `make metrics`, and does not compute the numbers itself
prejudge/help-exits-zero          scripts/prejudge.sh --help works with no PR
prejudge/steps-walker-exact       a checked-in fixture of step shapes reproduces a checked-in expectation
prejudge/steps-walker-catches-both-cited-shapes  F14's no-assertion and render(x)==render(x) are both reported
prejudge/steps-walker-has-no-false-positives     six legitimate Then-step shapes are not reported
prejudge/recorded-prs-exact       two recorded PRs reproduce a checked-in severity map, offline
prejudge/blocks-with-exit-1       a blocking check exits 1; a clear-with-warnings PR exits 0
prejudge/absent-ci-is-not-a-pass  an empty statusCheckRollup blocks after a wait, never passes (F5)
prejudge/scenario-count-is-asymmetric  fewer scenarios than the contract blocks, more only warns
prejudge/skip-is-distinguishable-from-pass  a check that could not run has not passed
prejudge/emits-an-action-per-block  every blocking finding carries an action a fresh worker can execute
prejudge/emits-its-own-shape-not-the-verdict-schema  the gate emits forge.gate.v1, never a scored verdict
prejudge/gate-is-a-stage-not-a-replacement  no model in the gate, and the protocol's scorer still there
prejudge/scorer-is-the-control-arm  the claude -p call is byte-identical to the recorded baseline (S5's control; never skips)
prejudge/review-routes-by-gate-result  a gate block bounces with no model spawned, carrying forge.gate.v1
prejudge/review-emits-a-terminator-envelope  one forge.review.v1 object tells the model which terminator to call
prejudge/review-never-prints-the-diff  a recorded 63 KB patch reaches the prompt file and not stdout
prejudge/schema-hides-stamped-fields  the model is not asked for the fields the operator stamps
prejudge/cost-is-storable         the verdict schema takes cost + session_id, optional, cache field intact
EOF
  exit 0
fi

echo "forge verify — $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "groups:$SUITES$([ "$WITH_CODEX" = 1 ] && echo ' (+codex probes)')"

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

  # `-s workspace-write` grants NO network. A dispatcher worktree is a fresh
  # checkout with no .venv, so unless the lane builds it while it still has a
  # network, `make check` cannot run inside the sandbox at all.
  if sed -n '/^## 3\./,/^## 4\./p' "$lane" | grep -q 'make setup'; then
    ok "env-prepared-before-codex"
  else
    bad "env-prepared-before-codex" \
        "forge-lane §3 must run 'make setup' — the lane has a network, the codex sandbox does not"
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

  # The first Codex-driven role rerun dismissed the old hook check's exit 128
  # and completed with .orig/.rej files untracked. A green test is not a clean
  # handoff; hash the hooks and fail on any final worktree dirt.
  if grep -Fq 'shasum -a 256' "$lane" \
     && grep -Fq 'cmp .forge/hooks.before .forge/hooks.after' "$lane" \
     && grep -Fq 'git status --porcelain --untracked-files=all' "$lane"; then
    ok "lane-final-worktree-is-clean"
  else
    bad "lane-final-worktree-is-clean" \
        "forge-lane must hash shared hooks and refuse a dirty final worktree"
  fi

  # A parent chunk is marked done when its PR opens. Measured on D1 -> D2:
  # D2 promoted immediately, blocked because key.py was absent, auto-promoted
  # again when it used kind=dependency, then invented a stacked-branch rebase.
  # Code dependencies need the parent PR integrated, and the wait must be
  # sticky because the board-level parent is already done.
  if grep -Fq 'mergedAt' "$lane" \
     && grep -Fq 'reason_class=failing-prereq' "$lane" \
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

  # `uv run` writes a cache and ~/.cache/uv is outside the sandbox. Unset,
  # Codex reroutes it mid-run to a path of its own choosing (measured twice,
  # 2026-07-28) — so hand it a deterministic one inside the worktree.
  if grep -q 'UV_CACHE_DIR=.*\.forge/uv-cache' "$lane"; then
    ok "uv-cache-dir-is-deterministic"
  else
    bad "uv-cache-dir-is-deterministic" \
        "forge-lane must set UV_CACHE_DIR under .forge/ — ~/.cache/uv is not writable in the sandbox"
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

  local home="$TMPROOT/kanban" db="$TMPROOT/kanban/boards/metrics-fixture/kanban.db"
  mkdir -p "$(dirname "$db")"
  # stdout is discarded: the fixture's `PRAGMA journal_mode=wal` echoes its
  # result, and that is fixture noise, not a case result.
  if ! sqlite3 "$db" < "$fx" >/dev/null 2>"$TMPROOT/fixture.log"; then
    bad "fixture-numbers-exact" "fixture would not load: $(tail -2 "$TMPROOT/fixture.log" | tr '\n' ' ')"
    return
  fi

  # Exact, whole-document diff. Asserting a handful of fields would let a new
  # bucket appear, or an old one silently vanish, without failing anything.
  HERMES_KANBAN_HOME="$home" "$ms" metrics-fixture --json > "$TMPROOT/metrics.json" 2>&1
  if diff -u "$exp" "$TMPROOT/metrics.json" > "$TMPROOT/metrics.diff" 2>&1; then
    ok "fixture-numbers-exact ($(jq -r '.verdicts.total' "$exp") verdicts, every field)"
  else
    bad "fixture-numbers-exact" "$(head -12 "$TMPROOT/metrics.diff" | tr '\n' ' ')"
  fi

  # The lane writes chunk metadata NESTED under a key named for the schema,
  # while the documented shape is flat with an inner "schema" field (F1). This
  # slice must REPORT that divergence, never repair it — and the card carrying
  # the malformed envelope must stay in the denominator, or the conformance
  # count would be blind to exactly the fault it exists to find.
  local e
  e="$(jq -c '[.envelope.flat,.envelope.nested,.envelope.neither,.envelope.total,.chunk_cards]' \
        "$TMPROOT/metrics.json" 2>/dev/null)"
  if [ "$e" = "[1,1,1,3,3]" ]; then
    ok "detects-noncanonical-envelope (1 flat, 1 nested, 1 neither, none normalized away)"
  else
    bad "detects-noncanonical-envelope" \
        "expected [flat,nested,neither,total,chunk_cards]=[1,1,1,3,3], got ${e:-nothing} — a nonconforming envelope was normalized or dropped from the denominator"
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
  if HERMES_KANBAN_HOME="$qhome" "$ms" metrics-fixture --json > "$TMPROOT/quiescent.json" 2>&1 \
     && jq -e '.verdicts.total' "$TMPROOT/quiescent.json" >/dev/null 2>&1; then
    ok "reads-a-quiescent-board (no -wal, no -shm, nothing holding it open)"
  else
    bad "reads-a-quiescent-board" \
        "a board at rest could not be read — the state every /retro finds it in: $(head -2 "$TMPROOT/quiescent.json" | tr '\n' ' ')"
  fi

  # A live board is production data for the whole flywheel. The script snapshots
  # it and reads the copy; this proves the original's bytes, because "read-only"
  # is a claim in a comment and claims in comments are what this suite is for.
  local before after
  before="$(shasum -a 256 "$db" | cut -d' ' -f1)"
  HERMES_KANBAN_HOME="$home" "$ms" metrics-fixture >/dev/null 2>&1
  HERMES_KANBAN_HOME="$home" "$ms" metrics-fixture --since 2026-07-28 --markdown-row >/dev/null 2>&1
  after="$(shasum -a 256 "$db" | cut -d' ' -f1)"
  if [ "$before" = "$after" ]; then
    ok "is-read-only (sha256 unchanged across three invocations)"
  else
    bad "is-read-only" "the database changed while being read — mode=ro is not holding"
  fi

  # The fixture declares a schema by hand, so it can drift away from the real
  # one and keep passing. Read the columns metrics.sh depends on off a live
  # board instead of asserting in a comment that they are the same.
  local live
  live="$(ls -1 "${HERMES_KANBAN_HOME:-${HERMES_HOME:-$HOME/.hermes}/kanban}/boards"/*/kanban.db 2>/dev/null | head -1)"
  if [ -z "$live" ]; then
    skip "live-schema-has-fixture-columns" "no live board to compare against"
  else
    local missing="" t c
    for spec in "tasks:id,status" "task_runs:task_id,profile,outcome,started_at,metadata" \
                "task_events:kind,payload,created_at" "task_comments:author,created_at" \
                "task_links:parent_id,child_id"; do
      t="${spec%%:*}"
      for c in $(printf '%s' "${spec#*:}" | tr ',' ' '); do
        sqlite3 "file:$live?mode=ro" "SELECT $c FROM $t LIMIT 0;" >/dev/null 2>&1 \
          || missing="$missing $t.$c"
      done
    done
    [ -z "$missing" ] && ok "live-schema-has-fixture-columns ($(basename "$(dirname "$live")"))" \
      || bad "live-schema-has-fixture-columns" "a live board no longer has:$missing — the fixture is testing a schema that no longer exists"
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
wants metrics   && run_metrics_group

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
#
# The recorded `tree/` carries the contract and the feature file and NOT the
# 3,500-line test suite, so `then-asserts` skips on these fixtures. That check
# is covered exactly, and separately, by the walker fixture above — the point of
# these two is the four checks that were covered by nothing.
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
  [ -z "$drift" ] && ok "recorded-prs-exact (2 PRs, 7 checks each, offline)" \
    || bad "recorded-prs-exact" "the severity map moved on:$drift — $(jq -c . "$TMPROOT/${drift## }.json" 2>/dev/null | cut -c1-200)"

  # The gate blocks. This is the property the whole slice turns on, and it is
  # asserted on the exit code rather than on the printed word, because that is
  # what a hook, a CI job and the driver will all read.
  "$gate" --fixture "$prs/pr-8" >/dev/null 2>&1; local rc8=$?
  "$gate" --fixture "$prs/pr-9" >/dev/null 2>&1; local rc9=$?
  if [ "$rc8" = 1 ] && [ "$rc9" = 0 ]; then
    ok "blocks-with-exit-1 (pr-8 blocks, pr-9 clears with 2 warnings)"
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
  if ! command -v jq >/dev/null 2>&1; then
    skip "cost-is-storable" "jq not on PATH"
  elif jq -e '
      (.properties.cost.required | index("cache_read_input_tokens"))
      and (.properties.cost.required | index("total_cost_usd"))
      and (.properties.session_id.type == "string")
      and ((.required | index("cost")) == null)
      and ((.required | index("session_id")) == null)
      and (.required | index("tokens_estimate"))
    ' rubrics/judge-verdict.schema.json >/dev/null 2>&1; then
    ok "cost-is-storable"
  else
    bad "cost-is-storable" \
        "judge-verdict.schema.json must accept cost/session_id as OPTIONAL, keep tokens_estimate required, and require cache_read_input_tokens inside cost"
  fi
}
wants prejudge  && run_prejudge_group

printf '\n---\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ] || exit 1
