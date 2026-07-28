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
#
# Exit 0 iff every case passes. Run it in CI, and as a hard gate after every
# `hermes update` and every codex/claude upgrade.
# =============================================================================
set -uo pipefail   # NOT -e: a failing case is a result, not a crash

cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 2
REPO_ROOT="$(pwd)"

WITH_CODEX=0; LIST_ONLY=0; SUITES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-codex) WITH_CODEX=1; shift;;
    --list) LIST_ONLY=1; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    cli|config|substrate|template|lane) SUITES="$SUITES $1"; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$SUITES" ] || SUITES="cli config substrate template lane"

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
  local profs; profs=$(hermes kanban assignees 2>/dev/null | grep -oE '\bforge-[a-z-]+\b' | sort -u)
  if [ -z "$profs" ]; then
    bad "per-profile" "no forge-* profiles are known assignees"; return
  fi
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

    v="$(hermes -p "$p" config get skills.external_dirs 2>/dev/null)"
    case "$v" in
      *"$REPO_ROOT/skills"*) ok "external-dirs/$p";;
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

  # A real file change, NOT --allow-empty. lefthook 2.1.10 skips every pre-push
  # command when the push carries no changed files (measured 2026-07-28; there
  # is no config key to disable it — see the template lefthook.yml), so an
  # empty push tests the hole rather than the gate. Push what people push.
  echo "# second" >> "$dest/README.md"
  git -C "$dest" add -A >/dev/null 2>&1
  git -C "$dest" -c user.email=v@v -c user.name=v commit -qm second >/dev/null 2>&1
  if git -C "$dest" push origin main >"$TMPROOT/push2.log" 2>&1; then
    bad "main-push-blocked" "direct push to an existing main succeeded — the pre-push guard is inert"
  else
    ok "main-push-blocked"
  fi
}

# ---------------------------------------------------------------------------
if [ "$LIST_ONLY" = 1 ]; then
  cat <<'EOF'
cli/flags-exist                   every long flag named beside a tracked command exists in its --help
cli/no-unverified-claims-in-skills  skill bodies carry no unverified-claim markers
config/terminal-timeout/<profile> >= 1800s per profile
config/write-approval/<profile>   ADR-0005 consent gate on per profile
config/external-dirs/<profile>    points at this checkout's skills/
config/soul-in-sync/<profile>     live ~/.hermes SOUL matches the one in git
config/lane-skill-scope           start-chunk/end-chunk not loadable by the lane
config/board-default-workdir      every forge board has a worktree anchor
substrate/worktree-ownership      dispatcher resolves the worktree before spawning
substrate/worktree-gitfile        .git is a file in a linked worktree; writes fail
substrate/codex-worktree-commit   codex can commit in a worktree with --add-dir (--with-codex)
template/stamp,setup,hooks-installed,check-green
template/gitignores-worktrees     .worktrees/ is ignored (dispatcher worktrees live in-repo)
template/bootstrap-push-allowed   the push that CREATES main is allowed (real bare remote)
template/main-push-blocked        every later direct push to main is refused
lane/env-prepared-before-codex    forge-lane §3 runs make setup — the sandbox has no network
lane/role-boundary-prepended      every contract states codex must not push/PR/touch the board
lane/uv-cache-dir-is-deterministic  UV_CACHE_DIR points inside the worktree, not ~/.cache/uv
lane/verification-is-plain-make-check   no UV_OFFLINE/UV_CACHE_DIR green counts
lane/template-agents-scopes-ceremonies  AGENTS.md scopes ceremonies to the operator
lane/prejudge-approve-routes-to-tier2   an approval creates a card for the human
lane/prejudge-judge-model-is-observed   judge_model comes from --model, not self-report
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

  # An approval is a hand-off, not an ending. Without a tier-2 card the chunk
  # and review cards both go `done`, the PR sits at REVIEW_REQUIRED, and
  # nothing on the board says a human still owes it a look (measured
  # 2026-07-28 on the first real chunk).
  local soul=hermes/profiles/forge-prejudge.SOUL.md
  if sed -n '/approve` \/ `approve-with-nits/,/bounce`:/p' "$soul" \
       | grep -q 'kanban_create' ; then
    ok "prejudge-approve-routes-to-tier2"
  else
    bad "prejudge-approve-routes-to-tier2" \
        "prejudge's approve path must create a tier-2 card, or approved PRs strand"
  fi

  # A model cannot report its own id: the first real verdict claimed
  # `claude-opus-4-8`, which does not exist. judge_model is schema-REQUIRED, so
  # an invented value poisons provenance silently.
  if grep -q -- '--model' "$soul" && grep -q 'Overwrite `judge_model`' "$soul"; then
    ok "prejudge-judge-model-is-observed"
  else
    bad "prejudge-judge-model-is-observed" \
        "prejudge must pass --model explicitly and stamp judge_model from it, not trust self-report"
  fi
}
wants lane      && run_lane_group

printf '\n---\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ] || exit 1
