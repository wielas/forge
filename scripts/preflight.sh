#!/usr/bin/env bash
# =============================================================================
# forge preflight — revalidate the mini before it takes over unattended work.
#
# READ-ONLY BY DESIGN. It runs --help/--version/status/config reads and one
# tiny "reply with OK" prompt per harness. It never creates, claims, mutates,
# or archives a kanban task, never writes to ~/.hermes, never pushes.
#
# Usage (on the Mac mini):
#   ./scripts/preflight.sh                      # human-readable to stdout
#   ./scripts/preflight.sh --out ../preflight.md # also tee a markdown report
#   ./scripts/preflight.sh --skip-llm           # no model calls at all
#
# Exit code: 0 if no FAIL, 1 if any FAIL. WARN never fails the run.
#
# WHY EACH CHECK EXISTS: every check below maps to a specific way the
# unattended lane is known to break. The check name is the failure mode.
# =============================================================================
set -uo pipefail   # deliberately NOT -e: a failing probe is data, not a crash

OUT=""; SKIP_LLM=0; FORGE_DIR_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a path}"; shift 2;;
    --forge-dir) FORGE_DIR_OPT="${2:?--forge-dir needs a path}"; shift 2;;
    --skip-llm) SKIP_LLM=1; shift;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

P=0; F=0; W=0
# Every helper MUST return 0. They are used as `cond && pass ... || fail ...`,
# so a non-zero return makes BOTH branches fire — which is exactly what happened
# on the first real run: `[ -n "$OUT" ]` was false, say() returned 1, and every
# check printed a PASS immediately followed by a contradictory FAIL.
say()  { printf '%s\n' "$*"; [ -n "$OUT" ] && printf '%s\n' "$*" >> "$OUT"; return 0; }
sect() { say ""; say "## $*"; say ""; return 0; }
pass() { P=$((P+1)); say "PASS  $*"; return 0; }
fail() { F=$((F+1)); say "FAIL  $*"; return 0; }
warn() { W=$((W+1)); say "WARN  $*"; return 0; }
info() { say "info  $*"; return 0; }

[ -n "$OUT" ] && : > "$OUT"
say "# forge preflight — $(date '+%Y-%m-%d %H:%M:%S %Z')"

# ---------------------------------------------------------------------------
sect "0. Where am I, and does that invalidate the auth checks?"
# ---------------------------------------------------------------------------
info "host: $(hostname)  user: $(whoami)  arch: $(uname -m)  os: $(uname -sr)"
if [ -n "${SSH_CONNECTION:-}" ]; then
  warn "running over SSH. On macOS the login keychain may be locked in a"
  say  "      non-GUI session, so a keychain-auth failure below may be an"
  say  "      artifact of HOW you ran this, not a real fault. Re-run from a"
  say  "      local Terminal (or Screen Sharing) and compare the two results."
else
  pass "running in a local session (keychain checks are trustworthy)"
fi

# Piped in over ssh (`ssh host 'bash -s' < preflight.sh`)? Then BASH_SOURCE is
# unset and the shell is non-login, so PATH is the bare /usr/bin:/bin default and
# every Homebrew binary looks "missing". Detect it and say so loudly.
PIPED=0
[ -z "${BASH_SOURCE[0]:-}" ] && PIPED=1
if [ "$PIPED" = 1 ]; then
  warn "script was piped in on stdin, not run from a file. That means a"
  say  "      non-login shell with a minimal PATH. Prefer running it from a"
  say  "      checkout so PATH and the repo location are real:"
  say  "        ssh <host> 'bash -lc \"cd ~/dev/forge && ./scripts/preflight.sh\"'"
fi

# ---------------------------------------------------------------------------
# The PATH that matters is the one the DISPATCHER hands a worker, not the one
# this shell happens to have. Find the gateway early and probe with its PATH,
# topped up with the usual macOS install dirs. §7 still checks the gateway's own
# PATH separately — that check must not be affected by what we do here.
# ---------------------------------------------------------------------------
GWPID="$(pgrep -f 'hermes.*gateway' 2>/dev/null | head -1)"
GWPATH=""
if [ -n "$GWPID" ]; then
  GWPATH="$(ps eww -p "$GWPID" 2>/dev/null | tr ' ' '\n' | grep '^PATH=' | head -1 | cut -d= -f2-)"
fi
PROBE_PATH="$PATH"
[ -n "$GWPATH" ] && PROBE_PATH="$GWPATH:$PROBE_PATH"
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.codex/bin" \
         "$HOME/.claude/bin" "$HOME/.bun/bin" "$HOME/.npm-global/bin"; do
  [ -d "$d" ] && PROBE_PATH="$PROBE_PATH:$d"
done
if [ "$PROBE_PATH" != "$PATH" ]; then
  info "probing with an augmented PATH (gateway PATH + standard install dirs)"
  [ -n "$GWPATH" ] && info "adopted the live gateway's PATH (pid $GWPID)"
  export PATH="$PROBE_PATH"
fi

# ---------------------------------------------------------------------------
sect "1. Binaries present"
# ---------------------------------------------------------------------------
need() { # $1=binary $2=required|optional $3=note
  local p; p="$(command -v "$1" 2>/dev/null)"
  if [ -n "$p" ]; then pass "$1 -> $p"
  elif [ "$2" = required ]; then fail "$1 MISSING ${3:-}"
  else warn "$1 missing (optional) ${3:-}"; fi
}
need hermes  required
need claude  required "judge lane + interactive lane depend on it"
need codex   required "implementation lane depends on it"
need gh      required "end-chunk opens the PR with gh"
need git     required
need make    required "make check is THE green proof (ADR-0003)"
need jq      required
need uv      optional "needed for copier / make new"
need copier  optional "needed for make new"
need lefthook optional "installed per-project by make setup, not globally"

for b in hermes claude codex gh; do
  command -v "$b" >/dev/null 2>&1 && info "$b version: $("$b" --version 2>&1 | head -1)"
done

# Every later section that shells out to hermes is guarded by this, so a missing
# binary produces ONE finding instead of thirty misleading ones.
HAVE_HERMES=0; command -v hermes >/dev/null 2>&1 && HAVE_HERMES=1

# ---------------------------------------------------------------------------
sect "2. The money invariant: no metered implementation/review tokens"
# ---------------------------------------------------------------------------
# Forge rule: bulk implementation and deep review run on subscriptions.
# The ONLY sanctioned metered surface is small OpenRouter aux calls (Hermes
# routing + the /goal judge). A stray provider key in a lane's env silently
# breaks that rule and bills per token.
[ -n "${ANTHROPIC_API_KEY:-}" ] \
  && fail "ANTHROPIC_API_KEY is set here — a lane inheriting it would bill per token" \
  || pass "ANTHROPIC_API_KEY not set"
[ -n "${OPENAI_API_KEY:-}" ] \
  && fail "OPENAI_API_KEY is set here — a lane inheriting it would bill per token" \
  || pass "OPENAI_API_KEY not set"
if [ -f "$HOME/.hermes/.env" ]; then
  grep -qE '^(ANTHROPIC|OPENAI)_API_KEY=.+' "$HOME/.hermes/.env" 2>/dev/null \
    && fail "~/.hermes/.env contains an ANTHROPIC/OPENAI key — workers inherit it" \
    || pass "~/.hermes/.env has no ANTHROPIC/OPENAI key"
  grep -q '^OPENROUTER_API_KEY=.\+' "$HOME/.hermes/.env" 2>/dev/null \
    && pass "OPENROUTER_API_KEY present (Hermes brain + aux judge)" \
    || warn "no OPENROUTER_API_KEY in ~/.hermes/.env — is Hermes on another provider?"
else
  warn "~/.hermes/.env not found"
fi

# ---------------------------------------------------------------------------
sect "3. Headless auth — the load-bearing question"
# ---------------------------------------------------------------------------
# On macOS, Claude Code credentials live in the encrypted login Keychain. A
# non-GUI session (SSH, LaunchDaemon) may not be able to unlock it, so `claude
# -p` reports "Not logged in" even though the same binary works fine in a local
# Terminal. That is NOT a policy block and NOT a missing login.
#
# The two probes below vary the ENV, not the session type, so they cannot tell
# keychain-scope apart from a genuine logout — both fail identically. The
# discriminator is running the same probe from a GUI session, or better: setting
# CLAUDE_CODE_OAUTH_TOKEN, which is read from the environment and needs no
# keychain at all. Checked explicitly below.
llm_probe() { # $1=label  $2..=command
  local label="$1"; shift
  local out rc
  # </dev/null is MANDATORY. Both `claude -p` and `codex exec` read stdin, and
  # when this script is piped in (`bash -s < preflight.sh`) stdin IS the rest of
  # the script — the probe silently eats it and everything after §3 never runs.
  out="$("$@" </dev/null 2>&1)"; rc=$?
  # -w so the "ok" inside "tokens" cannot fake a pass
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qiw 'ok'; then
    pass "$label responded (rc=0)"
    printf '%s' "$out" | grep -oE '"total_cost_usd":[0-9.e-]+' | head -1 \
      | sed 's/^/      /' | while read -r l; do info "$l"; done
  else
    fail "$label failed (rc=$rc): $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  fi
}
# CLAUDE_CODE_OAUTH_TOKEN is a subscription credential (`claude setup-token`,
# one-year lifetime), NOT metered API access — it is the sanctioned way to
# authenticate a headless run and does not violate the money invariant in §2.
# The token that matters is the one HERMES injects into the children it spawns,
# which it reads from ~/.hermes/.env — not the one this SSH shell happens to
# have. So: look in the env, then fall back to ~/.hermes/.env, and probe with
# whatever we find. Otherwise an SSH run reports a false failure while the real
# lane works fine (exactly what happened on 2026-07-27).
TOKEN_SRC=""
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  TOKEN_SRC="this shell's env"
elif [ -f "$HOME/.hermes/.env" ] \
     && grep -q '^CLAUDE_CODE_OAUTH_TOKEN=.\+' "$HOME/.hermes/.env" 2>/dev/null; then
  CLAUDE_CODE_OAUTH_TOKEN="$(grep -m1 '^CLAUDE_CODE_OAUTH_TOKEN=' "$HOME/.hermes/.env" \
    | cut -d= -f2- | tr -d '"'"'"' \r')"
  export CLAUDE_CODE_OAUTH_TOKEN
  TOKEN_SRC="~/.hermes/.env (what Hermes gives its children)"
fi
if [ -n "$TOKEN_SRC" ]; then
  pass "CLAUDE_CODE_OAUTH_TOKEN found in $TOKEN_SRC — keychain-independent auth"
else
  warn "CLAUDE_CODE_OAUTH_TOKEN nowhere to be found. If the probes below say"
  say  "      'Not logged in' while a local Terminal works, this is the fix: run"
  say  "      'claude setup-token' once in a GUI session and put the token in"
  say  "      ~/.hermes/.env so the gateway's children inherit it. Do NOT pass"
  say  "      --bare in the lane: bare mode does not read this variable."
fi
if [ "$SKIP_LLM" = 1 ]; then
  warn "--skip-llm: headless auth NOT tested (this is the check that matters most)"
else
  if command -v claude >/dev/null 2>&1; then
    llm_probe "claude -p (normal env)" \
      claude -p "reply with exactly: OK" --output-format json
    # Stripped env ≈ dispatcher-spawned child. PATH is passed through because a
    # missing PATH tests nothing but PATH; we are testing credential reach.
    # Pass the token through explicitly: this is what a Hermes-spawned child gets.
    llm_probe "claude -p (stripped env, gateway-like)" \
      env -i HOME="$HOME" PATH="$PATH" TERM=dumb \
      CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
      claude -p "reply with exactly: OK" --output-format json
  fi
  if command -v codex >/dev/null 2>&1; then
    # --skip-git-repo-check: codex refuses to run outside a trusted git repo.
    # Real lane runs happen inside a worktree so they are fine; this probe is not.
    llm_probe "codex exec (normal env)" \
      codex exec --skip-git-repo-check "reply with exactly: OK"
    llm_probe "codex exec (stripped env, gateway-like)" \
      env -i HOME="$HOME" PATH="$PATH" TERM=dumb \
      codex exec --skip-git-repo-check "reply with exactly: OK"
  fi
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then pass "gh authenticated"
  else
    fail "gh NOT authenticated — end-chunk cannot open a PR. Fix on the mini with"
    say  "      'gh auth login' (device flow works over SSH; needs repo scope). If the"
    say  "      gateway's children need it too, put GH_TOKEN in ~/.hermes/.env."
  fi
fi

# ---------------------------------------------------------------------------
sect "4. Hermes config truths (burns down the README VERIFY list)"
# ---------------------------------------------------------------------------
CFG="$HOME/.hermes/config.yaml"
if [ "$HAVE_HERMES" = 0 ]; then
  warn "hermes not on PATH — skipping sections 4, 5, 6 and 8 entirely"
fi
hcfg() { # $1=dotted.key -> value or empty; tries CLI then falls back to yaml grep
  local v
  v="$(hermes config get "$1" 2>/dev/null | tail -1)"
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  # BSD grep (macOS) has no \s — use a POSIX class
  [ -f "$CFG" ] && grep -E "^[[:space:]]*${1##*.}:" "$CFG" 2>/dev/null | head -1 \
    | sed 's/.*: *//; s/ *#.*//'
}
[ -f "$CFG" ] && pass "config.yaml found" || fail "no ~/.hermes/config.yaml"

TMO="$(hcfg terminal.timeout)"
if [ -z "$TMO" ]; then warn "terminal.timeout not readable — default is 180s"
elif ! printf '%s' "$TMO" | grep -qE '^[0-9]+$'; then
  warn "terminal.timeout read as non-numeric ('$TMO') — check it by hand"
elif [ "$TMO" -le 300 ]; then
  fail "terminal.timeout=${TMO}s — a real chunk run dies mid-flight. Either raise it"
  say  "      (hermes config set terminal.timeout 1800) or have the lane skill run the"
  say  "      delegation in the BACKGROUND and poll, which is the pattern we chose."
else pass "terminal.timeout=${TMO}s"; fi

for k in approvals.mode kanban.dispatch_in_gateway kanban.max_in_progress \
         skills.write_approval goals.max_turns; do
  v="$(hcfg "$k")"; [ -n "$v" ] && info "$k = $v" || info "$k = (unset → built-in default)"
done

# approvals.mode cuts both ways for unattended work:
#   manual → a flagged command waits for a human who is not there; the card
#            burns its runtime and gets reclaimed. Safe, but it hangs lanes.
#   off    → nothing is checked; a message to the bot can run anything.
#   smart  → LLM auto-approves low-risk commands. The only mode that is both
#            safe and unattended-viable.
AM="$(hcfg approvals.mode | tr -d "\"' ")"
case "$AM" in
  smart) pass "approvals.mode=smart — safe and viable for unattended lanes";;
  manual) warn "approvals.mode=manual — a dispatched worker hitting a flagged"
          say  "      command will wait for an approval nobody is there to give."
          say  "      Prefer 'smart' with a tight allowlist before the first night run.";;
  off)   warn "approvals.mode=off (HERMES_YOLO_MODE) — nothing is checked. With the"
         say  "      local backend and a reachable bot, any message can run anything.";;
  *)     info "approvals.mode could not be read cleanly ('$AM')";;
esac
[ "$(hcfg skills.write_approval)" = "true" ] \
  && pass "skills.write_approval on (L5 consent gate)" \
  || warn "skills.write_approval not confirmed on — the flywheel's consent gate (ADR-0005)"

# ---------------------------------------------------------------------------
sect "5. Kanban CLI surface — does the real CLI match what we designed against?"
# ---------------------------------------------------------------------------
if [ "$HAVE_HERMES" = 0 ]; then
  fail "cannot probe the kanban CLI without hermes — every flag below is unverified"
else
KH="$(hermes kanban --help 2>&1)"
for sub in create list show comment complete block unblock link heartbeat \
           runs assignees stats log watch specify boards swarm; do
  printf '%s' "$KH" | grep -qw -- "$sub" \
    && pass "kanban subcommand: $sub" \
    || warn "kanban subcommand MISSING: $sub (version older than the docs we read?)"
done

CH="$(hermes kanban create --help 2>&1)"
# Each flag below is load-bearing for the Hermes-native lane design:
#   --workspace  scratch workspaces are DELETED on completion; we need worktree
#   --branch     lane branches must be named by the card, not guessed
#   --max-retries / --max-runtime  circuit breaker instead of bash `timeout`
#   --idempotency-key  re-running board bootstrap must not duplicate cards
#   --skill      pin judge/lane skills per card without editing the profile
#   --body       there is NO --body-file; pass file contents with --body "$(cat f)"
for fl in --workspace --branch --max-retries --max-runtime --idempotency-key --skill --assignee --body; do
  printf '%s' "$CH" | grep -q -- "$fl" \
    && pass "kanban create flag: $fl" \
    || fail "kanban create flag MISSING: $fl — the lane design assumes it"
done
printf '%s' "$CH" | grep -q -- '--body-file' \
  && info "--body-file exists after all; board-bootstrap may use it directly" \
  || info "no --body-file (expected) — bootstrap must use --body \"\$(cat …)\""
fi

# ---------------------------------------------------------------------------
sect "6. Profiles — the dispatcher silently fails on unknown assignees"
# ---------------------------------------------------------------------------
# Docs: an unknown assignee name is not skipped, it fails to spawn, and after
# kanban.failure_limit (default 2) consecutive failures the card AUTO-BLOCKS.
# So every assignee the roadmap emits must exist here before any card is made.
PROF=""
[ "$HAVE_HERMES" = 1 ] && PROF="$( (hermes kanban assignees 2>/dev/null \
         || hermes profile list 2>/dev/null) | tr -d '\r')"
[ -z "$PROF" ] && PROF="$(ls -1 "$HOME/.hermes/profiles" 2>/dev/null | tr -d '\r')"
if [ -n "$PROF" ]; then
  info "profiles/assignees visible to the board:"
  printf '%s\n' "$PROF" | sed 's/^/      /' | while read -r l; do say "$l"; done
  for want in forge-orchestrator forge-codex-lane forge-prejudge forge-digest; do
    printf '%s' "$PROF" | grep -q "$want" \
      && pass "profile exists: $want" \
      || warn "profile NOT yet created: $want (cards assigned to it will auto-block)"
  done
else
  warn "could not enumerate profiles — check 'hermes profiles --help'"
fi

# ---------------------------------------------------------------------------
sect "7. Dispatcher liveness and the env it will hand workers"
# ---------------------------------------------------------------------------
# The dispatcher runs inside the gateway. If the gateway's PATH lacks claude or
# codex, every lane card fails with 'command not found' — the single most
# common orchestrator failure mode. We inspect the LIVE process env, because
# your interactive shell's PATH proves nothing about the gateway's.
# GWPID / GWPATH were resolved in section 0 so the binary probes could use them.
if [ -n "$GWPID" ]; then
  pass "gateway running (pid $GWPID) — dispatcher should be ticking"
  GWENV="$(ps eww -p "$GWPID" 2>/dev/null | tr ' ' '\n' \
    | grep -E '^(PATH|HOME|TERMINAL_CWD|MESSAGING_CWD|HERMES_|CLAUDE_CODE_OAUTH_TOKEN=)' \
    | sed 's/^CLAUDE_CODE_OAUTH_TOKEN=.*/CLAUDE_CODE_OAUTH_TOKEN=<redacted, present>/')"
  # The gateway's env is what a dispatched worker inherits. Whether YOUR shell
  # has the token is irrelevant; this is the copy that matters.
  printf '%s' "$GWENV" | grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' \
    && pass "gateway env carries CLAUDE_CODE_OAUTH_TOKEN — workers can auth headlessly" \
    || warn "gateway env has NO CLAUDE_CODE_OAUTH_TOKEN — a dispatched 'claude -p' will"
  printf '%s' "$GWENV" | grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' \
    || say  "      depend on the login keychain being unlockable from the gateway's session"
  [ -n "$GWENV" ] && { info "gateway env of interest:"; printf '%s\n' "$GWENV" | sed 's/^/      /' | while read -r l; do say "$l"; done; }
  if [ -n "$GWPATH" ]; then
    for b in claude codex gh git make; do
      found=0
      IFS=: read -ra dirs <<< "$GWPATH"
      for d in "${dirs[@]}"; do [ -x "$d/$b" ] && { found=1; break; }; done
      [ "$found" = 1 ] && pass "gateway PATH can reach $b" \
        || fail "gateway PATH CANNOT reach $b — lane cards will fail 'command not found'"
    done
  else
    warn "could not read the gateway's PATH from ps"
  fi
  launchctl list 2>/dev/null | grep -qi hermes \
    && pass "a hermes launchd job exists (survives logout/reboot)" \
    || warn "no hermes launchd job — gateway started by hand will die with your shell,"
  say  "      and a gateway started over SSH may not reach the login keychain"
else
  fail "no hermes gateway process — the embedded dispatcher is not running, so"
  say  "      ready cards will sit untouched (this is safe, but nothing progresses)"
fi

# ---------------------------------------------------------------------------
sect "8. Board state"
# ---------------------------------------------------------------------------
if [ -f "$HOME/.hermes/kanban.db" ]; then pass "kanban.db exists"
else warn "no ~/.hermes/kanban.db yet — 'hermes kanban init' has not run"; fi
if [ "$HAVE_HERMES" = 1 ]; then
  BL="$(hermes kanban boards list 2>&1 | head -20)"
  [ -n "$BL" ] && { info "boards:"; printf '%s\n' "$BL" | sed 's/^/      /' | while read -r l; do say "$l"; done; }
  # Board resolution falls back to the persisted "current" board. A bootstrap
  # script that omits --board silently lands its cards on whatever that is.
  CUR="$(printf '%s' "$BL" | sed -n 's/^Current board: *//p' | head -1)"
  if [ -n "$CUR" ] && [ "$CUR" != "default" ]; then
    warn "current board is '$CUR' — any 'hermes kanban create' without --board"
    say  "      lands there, NOT on a forge board. Always pass --board explicitly."
  fi
  ST="$(hermes kanban stats 2>&1 | head -20)"
  [ -n "$ST" ] && { info "stats:"; printf '%s\n' "$ST" | sed 's/^/      /' | while read -r l; do say "$l"; done; }
fi

# ---------------------------------------------------------------------------
sect "9. Skills: discovery, and the curator risk"
# ---------------------------------------------------------------------------
# Hermes now runs a curator that reviews, archives and rewrites agent-managed
# skills. Forge skills are git-tracked. If the curator can edit them in place
# through a symlink, methodology drifts OUTSIDE version control — silently.
HSK="${HERMES_SKILLS_DIR:-$HOME/.hermes/skills}"
if [ -d "$HSK" ]; then
  pass "hermes skills dir: $HSK"
  LINKS="$(find "$HSK" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
  info "symlinked skills in that dir: $LINKS"
  for s in scope architect roadmap start-chunk end-chunk judge retro; do
    if [ -L "$HSK/$s" ]; then
      warn "forge skill '$s' is symlinked into the curated dir — verify the curator"
      say  "      cannot rewrite it (hermes config: curator.*), or install a COPY instead"
    fi
  done
  [ "$LINKS" = 0 ] && pass "no forge symlinks in the curated dir yet (install.sh not run here)"
else
  warn "hermes skills dir not found at $HSK — confirm with 'hermes skills list'"
fi
for d in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
  [ -d "$d" ] && info "harness skills dir present: $d" || info "absent: $d"
done

# ---------------------------------------------------------------------------
sect "10. Forge repo readiness"
# ---------------------------------------------------------------------------
# BASH_SOURCE is unset when the script is piped in on stdin, so resolve
# defensively and let the caller override with --forge-dir.
if [ -n "$FORGE_DIR_OPT" ]; then
  FORGE_DIR="$FORGE_DIR_OPT"
elif [ -n "${BASH_SOURCE[0]:-}" ]; then
  FORGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
elif [ -f "./Makefile" ] && [ -d "./skills" ]; then
  FORGE_DIR="$(pwd)"
else
  FORGE_DIR=""
fi
if [ -z "$FORGE_DIR" ]; then
  warn "cannot locate the forge repo from here (piped invocation, no --forge-dir)."
  say  "      Section 10 is meaningless in this run — re-run from a checkout or pass"
  say  "      --forge-dir /path/to/forge."
fi
if [ -n "$FORGE_DIR" ]; then
  info "forge dir: $FORGE_DIR"
  if git -C "$FORGE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    pass "forge is a git repo"
    R="$(git -C "$FORGE_DIR" remote -v | head -1)"
    [ -n "$R" ] && pass "remote: $R" \
      || fail "no git remote — /retro proposes PRs against this repo and cannot"
    git -C "$FORGE_DIR" diff --quiet && git -C "$FORGE_DIR" diff --cached --quiet \
      && pass "working tree clean" || warn "uncommitted changes in the forge repo"
  else
    fail "forge is NOT a git repo — the flywheel (ADR-0005) proposes PRs against it,"
    say  "      and the mini needs something to clone."
  fi
  ( cd "$FORGE_DIR" && make validate >/dev/null 2>&1 ) \
    && pass "make validate green" || fail "make validate failed — run it to see why"
fi

# ---------------------------------------------------------------------------
say ""
say "## Summary"
say ""
say "PASS $P   WARN $W   FAIL $F"
if [ "$F" -gt 0 ]; then
  say ""
  say "Not ready for unattended work. Fix every FAIL, then re-run."
  exit 1
fi
say ""
say "No hard failures. Read the WARNs before the first night run."
exit 0
