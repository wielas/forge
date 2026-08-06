#!/usr/bin/env bash
# =============================================================================
# forge preflight — revalidate the mini before it takes over unattended work.
#
# READ-ONLY BY DESIGN. It runs --help/--version/status/config reads and one
# tiny "reply with OK" prompt per harness. It never creates, claims, mutates,
# or archives a kanban task, never writes to ~/.hermes, never pushes.
#
# Usage (on the Mac mini):
#   ./scripts/preflight.sh                      # inspection only — no model calls
#   ./scripts/preflight.sh --probe              # + headless auth probes (spends tokens)
#   ./scripts/preflight.sh --out ../preflight.md # also tee a markdown report
#   ./scripts/preflight.sh --skip-llm           # alias for the default
#
# Exit code: 0 if no FAIL, 1 if any FAIL. WARN never fails the run.
#
# WHY EACH CHECK EXISTS: every check below maps to a specific way the
# unattended lane is known to break. The check name is the failure mode.
# =============================================================================
set -uo pipefail   # deliberately NOT -e: a failing probe is data, not a crash

# Probes are OPT-IN. Inspection (config reads, --help, --version) is free,
# instant and safe; model probes cost tokens and can hang. Mixing them made the
# default run both slow and billable. --skip-llm is kept as a no-op alias for
# the default so existing invocations and docs keep working.
OUT=""; PROBE=0; FORGE_DIR_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a path}"; shift 2;;
    --forge-dir) FORGE_DIR_OPT="${2:?--forge-dir needs a path}"; shift 2;;
    --probe) PROBE=1; shift;;
    --skip-llm) PROBE=0; shift;;
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
  # An EMPTY assignment is not a billing risk today and does not break `claude -p`
  # (measured: is_error:false with ANTHROPIC_API_KEY="" alongside the OAuth token).
  # It is a landmine: the day someone pastes a value into that waiting line, every
  # lane silently starts metering, because the API key outranks the OAuth token.
  grep -qE '^(ANTHROPIC|OPENAI)_API_KEY=[[:space:]]*$' "$HOME/.hermes/.env" 2>/dev/null \
    && warn "~/.hermes/.env has an EMPTY ANTHROPIC/OPENAI key line — delete the line;"
  grep -qE '^(ANTHROPIC|OPENAI)_API_KEY=[[:space:]]*$' "$HOME/.hermes/.env" 2>/dev/null \
    && say  "      an empty slot invites a paste that silently breaks the money invariant"
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
# A hung probe must not hang the run. There is no timeout(1) on a stock macOS,
# so bound it in pure shell: run in the background, poll, escalate TERM->KILL.
# Sets BOUNDED_OUT; returns the command's rc, or 124 on timeout.
PROBE_TIMEOUT="${FORGE_PROBE_TIMEOUT:-120}"
bounded() { # $1=seconds  $2..=command
  local secs="$1"; shift
  local tmp pid waited=0 rc
  tmp="$(mktemp)"
  # </dev/null is MANDATORY. Both `claude -p` and `codex exec` read stdin, and
  # when this script is piped in (`bash -s < preflight.sh`) stdin IS the rest of
  # the script — the probe silently eats it and everything after §3 never runs.
  ( "$@" </dev/null >"$tmp" 2>&1 ) & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null
      BOUNDED_OUT="$(cat "$tmp")"; rm -f "$tmp"; return 124
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"; rc=$?
  BOUNDED_OUT="$(cat "$tmp")"; rm -f "$tmp"
  return $rc
}

# Claude: judge by the STRUCTURED result, not by grepping prose. `grep -qiw ok`
# passes on any transcript containing the word — including an error message that
# happens to say "not ok". --output-format json carries `is_error`.
llm_probe_claude() { # $1=label  $2..=command
  local label="$1"; shift
  local rc err
  bounded "$PROBE_TIMEOUT" "$@"; rc=$?
  if [ $rc -eq 124 ]; then
    fail "$label TIMED OUT after ${PROBE_TIMEOUT}s (killed)"; return 0
  fi
  err="$(printf '%s' "$BOUNDED_OUT" | jq -r 'if type=="object" then (.is_error|tostring) else "unparseable" end' 2>/dev/null)"
  if [ $rc -eq 0 ] && [ "$err" = "false" ]; then
    pass "$label responded (rc=0, is_error=false)"
    printf '%s' "$BOUNDED_OUT" | jq -r '"total_cost_usd: \(.total_cost_usd // "n/a")"' 2>/dev/null \
      | while read -r l; do info "      $l"; done
  elif [ "$err" = "unparseable" ]; then
    fail "$label returned no parseable JSON (rc=$rc): $(printf '%s' "$BOUNDED_OUT" | head -2 | tr '\n' ' ')"
  else
    fail "$label failed (rc=$rc, is_error=$err): $(printf '%s' "$BOUNDED_OUT" | head -2 | tr '\n' ' ')"
  fi
}

# Codex has no --output-format json, but it can write its FINAL message to a
# file — which is structured enough to judge without grepping the transcript.
# --ephemeral (no session files) and --ignore-user-config (no ambient
# ~/.codex/config.toml) keep the probe from touching or reading operator state.
llm_probe_codex() { # $1=label  $2..=command-prefix (env wrapper etc)
  local label="$1"; shift
  local rc last msg
  last="$(mktemp)"
  bounded "$PROBE_TIMEOUT" "$@" codex exec \
    --ephemeral --ignore-user-config --skip-git-repo-check \
    --output-last-message "$last" "reply with exactly: OK"
  rc=$?
  msg="$(tr -d '[:space:]' < "$last" 2>/dev/null)"; rm -f "$last"
  if [ $rc -eq 124 ]; then
    fail "$label TIMED OUT after ${PROBE_TIMEOUT}s (killed)"
  elif [ $rc -eq 0 ] && printf '%s' "$msg" | grep -qix 'ok'; then
    pass "$label responded (rc=0, final message = OK)"
  else
    fail "$label failed (rc=$rc, final message='$msg'): $(printf '%s' "$BOUNDED_OUT" | head -2 | tr '\n' ' ')"
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
if [ "$PROBE" = 0 ]; then
  info "model probes skipped (inspection-only run). Add --probe to spend tokens and"
  info "test headless auth for real — it is the check that matters most before a"
  info "night run, and the only one that cannot be answered by reading config."
else
  if command -v claude >/dev/null 2>&1; then
    llm_probe_claude "claude -p (normal env)" \
      claude -p "reply with exactly: OK" --output-format json
    # Stripped env ≈ dispatcher-spawned child. PATH is passed through because a
    # missing PATH tests nothing but PATH; we are testing credential reach.
    # Pass the token through explicitly: this is what a Hermes-spawned child gets.
    llm_probe_claude "claude -p (stripped env, gateway-like)" \
      env -i HOME="$HOME" PATH="$PATH" TERM=dumb \
      CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
      claude -p "reply with exactly: OK" --output-format json
  fi
  if command -v codex >/dev/null 2>&1; then
    # --skip-git-repo-check: codex refuses to run outside a trusted git repo.
    # Real lane runs happen inside a worktree so they are fine; this probe is not.
    llm_probe_codex "codex exec (normal env)"
    llm_probe_codex "codex exec (stripped env, gateway-like)" \
      env -i HOME="$HOME" PATH="$PATH" TERM=dumb
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
sect "4. GATEWAY config — the DEFAULT profile only. Lanes do NOT read this."
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
info "everything in section 4 describes the GATEWAY's own profile. Every value"
info "below is re-read PER LANE PROFILE in section 4b — that is the one that"
info "decides whether an unattended run lives or dies."

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
sect "4b. LANE config, read PER PROFILE — this is what workers actually run on"
# ---------------------------------------------------------------------------
# Section 4 reads the default profile. Workers do not run there: every profile
# is its own HERMES_HOME (~/.hermes/profiles/<name>) with its own config.yaml,
# so a green section 4 can coexist with lanes that die at terminal.timeout and a
# consent gate that is off. That is not hypothetical — it is exactly how a
# 180s timeout and write_approval=false stayed invisible for a day.
if [ "$HAVE_HERMES" = 0 ]; then
  warn "hermes not on PATH — cannot read lane profiles"
else
  # The profiles that can actually receive a card. `kanban assignees` is the
  # authority: an assignee that is not listed here strands its card silently.
  #
  # ON DISK IS PART OF THE ANSWER. `kanban assignees` lists every name that has
  # ever appeared on a card and marks each `yes`/`no` for whether a profile
  # exists for it. Taking every `forge-*` name regardless meant running
  # `hermes -p <name> config get` against profiles that have no config, which
  # returns nothing and fails three checks apiece.
  #
  # That produced six FAILs and "not ready for unattended work" on a system
  # that was correct: three from `forge-operator`, a historical mis-assignment
  # the audit already records, and three from `forge-operator-handoff` — the
  # tier-2 sentinel, which MUST NOT exist on disk. Preflight was failing
  # *because* the human gate was intact. A readiness gate that says FAIL when
  # the system is right teaches its operator to ignore it, and that is how the
  # real FAIL gets missed.
  #
  # A card parked on a profile that does not exist is a different defect, with
  # its own check below, which correctly looks at `ready` cards only.
  #
  # `make verify`'s config group already learned this as audit F43 — its
  # comment describes the same six failures — but the fix was never carried
  # across to preflight. Same `assignees --json` / `.on_disk` shape here, so
  # the two scripts answer "which profiles are real" the same way.
  LANE_PROFILES="$(hermes kanban assignees --json 2>/dev/null \
    | jq -r '.[]|select(.name|test("^forge-[a-z-]+$"))|select(.on_disk)|.name' 2>/dev/null | sort -u)"
  # Named, not silently dropped: a check that could not run has not passed.
  for _ghost in $(hermes kanban assignees --json 2>/dev/null \
    | jq -r '.[]|select(.name|test("^forge-[a-z-]+$"))|select(.on_disk|not)|.name' 2>/dev/null | sort -u); do
    info "── assignee '$_ghost' has no profile on disk — sentinel or ghost, not spawnable; config checks skipped"
  done
  if [ -z "$LANE_PROFILES" ]; then
    fail "no forge-* profiles are known assignees — run ./hermes/profiles-bootstrap.sh"
  else
    for prof in $LANE_PROFILES; do
      say ""
      info "── profile: $prof"
      pcfg() { hermes -p "$prof" config get "$1" 2>/dev/null | tail -1; }

      # terminal.timeout: `make check` runs SYNCHRONOUSLY in the lane. At 180s
      # it is killed after the code is written and before it is verified.
      v="$(pcfg terminal.timeout)"
      if [ -z "$v" ]; then
        fail "$prof: terminal.timeout unset → 180s default kills 'make check' mid-run"
      elif ! printf '%s' "$v" | grep -qE '^[0-9]+$'; then
        fail "$prof: terminal.timeout non-numeric ('$v')"
      elif [ "$v" -lt 1800 ]; then
        fail "$prof: terminal.timeout=${v}s (<1800) — a real chunk dies at 'make check'"
      else
        pass "$prof: terminal.timeout=${v}s"
      fi

      # skills.write_approval: ADR-0005's consent gate. Off means a lane's skill
      # edits take effect unattended with nobody consenting to anything.
      v="$(pcfg skills.write_approval)"
      [ "$v" = "true" ] \
        && pass "$prof: skills.write_approval=true (L5 consent gate)" \
        || fail "$prof: skills.write_approval='${v:-unset}' — ADR-0005's gate does not exist"

      # A profile with no external_dirs cannot see the forge skills at all;
      # ~/.hermes/skills reaches only the DEFAULT profile.
      v="$(pcfg skills.external_dirs)"
      case "$v" in
        *forge*) pass "$prof: skills.external_dirs points at a forge checkout";;
        "")      fail "$prof: skills.external_dirs unset — this profile sees NO forge skills";;
        *)       warn "$prof: skills.external_dirs='$v' — no forge path in it";;
      esac

      v="$(pcfg model.default)"
      [ -n "$v" ] && info "$prof: model.default = $v" \
                  || warn "$prof: model.default unset — inherits whatever is ambient"
    done
  fi
fi

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
      || warn "profile NOT yet created: $want (its cards will sit stranded in ready)"
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
    | grep -E '^(PATH|HOME|TERMINAL_CWD|MESSAGING_CWD|HERMES_)' )"
  # DO NOT ask ps whether the gateway has CLAUDE_CODE_OAUTH_TOKEN. On macOS
  # `ps eww` reports the env a process was EXEC'd with; hermes loads
  # ~/.hermes/.env at import via load_hermes_dotenv(), i.e. after exec, so the
  # token is in the live os.environ (which the dispatcher copies with
  # `env = dict(os.environ)` when it spawns a worker) but is invisible to ps.
  # Measured 2026-07-27: a Python process that sets os.environ[X] post-exec
  # shows zero matches in `ps eww`. The old check WARNed on a healthy gateway.
  # What actually matters, in order:
  #   1. the token is readable from the home the gateway was started with, and
  #   2. each profile carries its own copy, so a hand-run worker also has it.
  if [ -n "$TOKEN_SRC" ]; then
    pass "token resolvable for gateway children (from $TOKEN_SRC)"
  else
    warn "no CLAUDE_CODE_OAUTH_TOKEN anywhere — a dispatched 'claude -p' falls back"
    say  "      to the login keychain, which a non-GUI gateway session may not unlock"
  fi
  for pdir in "$HOME"/.hermes/profiles/forge-*/; do
    [ -d "$pdir" ] || continue
    grep -q '^CLAUDE_CODE_OAUTH_TOKEN=.\+' "$pdir/.env" 2>/dev/null \
      || warn "$(basename "$pdir")/.env has no CLAUDE_CODE_OAUTH_TOKEN — fine while it"
    grep -q '^CLAUDE_CODE_OAUTH_TOKEN=.\+' "$pdir/.env" 2>/dev/null \
      || say  "      inherits the gateway's env, but a hand-run 'hermes -p <name>' will not"
  done
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

  # A card assigned to a profile that does not exist is NOT an error anywhere:
  # the dispatcher records skipped_nonspawnable and the card sits in `ready`
  # forever. `board-bootstrap.sh` warns about this and refuses to create such a
  # card, but nothing ever looked at cards created by an AGENT at runtime.
  # Measured 2026-07-28: forge-prejudge parked a tier-2 review on the invented
  # profile `forge-operator`. The human gate held — but only because that name
  # happens not to exist, which stops being true the day someone creates it.
  # `hermes kanban assignees` already prints ON DISK per assignee; read it.
  # `assignees` is BOARD-SCOPED — reading it without a board only ever inspects
  # the persisted current board, which is exactly the board a forge card is
  # least likely to be on. Walk every board.
  #
  # Two refinements, both learned the moment this check met the tier-2 fix:
  #   * Only `ready` counts. A ghost assignee on a `done` card is history, not a
  #     stuck card; warning about it is noise that hides the real one.
  #   * The tier-2 hand-off parks on a sentinel assignee that is SUPPOSED not to
  #     exist — that is the whole mechanism keeping the human's card away from
  #     the dispatcher. Warning about it would be backwards, so the sentinel is
  #     read out of the hand-off itself (never hardcoded twice) and checked in
  #     reverse: the failure is that name EXISTING.
  # NOTE: $FORGE_DIR is resolved further down this script, so it is not usable
  # here. Derive the checkout from this script's own location instead.
  #
  # READ IT WHERE IT LIVES NOW. This used to sed the SOUL, which was right
  # until ADR-0010 moved the protocol out of the SOUL and into
  # prejudge-review.sh — after which the sed matched nothing, $SENTINEL went
  # empty, and the check below fell to its "could not read" branch and stopped
  # verifying anything. Same shape as F65: a check anchored to a location whose
  # content moved, going quiet at the merge that moved it. The name is still
  # not written twice — it is read out of route_tier2(), which is the only
  # place that parks a card on it, and the extraction captures whatever name is
  # there rather than asserting a known one.
  SELF_REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
  SENTINEL="$(sed -n '/^route_tier2()/,/^}/p' \
              "$SELF_REPO/scripts/prejudge-review.sh" 2>/dev/null \
              | sed -n 's/.*--assignee \([A-Za-z0-9_-]*\).*/\1/p' | head -1)"
  GHOSTS=""
  for b in $(hermes kanban boards list --json 2>/dev/null | jq -r '.[].slug' 2>/dev/null); do
    for g in $(HERMES_KANBAN_BOARD="$b" hermes kanban assignees 2>/dev/null \
               | awk -v s="$SENTINEL" \
                 'NR>1 && $2=="no" && NF>=3 && $1!=s && $0 ~ /ready=/ {print $1}'); do
      GHOSTS="$GHOSTS $b/$g"
    done
  done
  if [ -n "$GHOSTS" ]; then
    for g in $GHOSTS; do
      warn "board '${g%%/*}' has READY cards assigned to '${g##*/}', which has no profile on disk"
      say  "      they will never be dispatched and never fail — they just sit in"
      say  "      'ready'. Either create the profile or reassign/park the cards."
      say  "      A ghost assignee is a card parked by luck, not by design."
    done
  else
    pass "no ready card is parked on a non-existent profile (all boards)"
  fi

  # The sentinel, inverted. If a profile is ever created under this name, every
  # tier-2 card the hand-off has parked becomes claimable and ADR-0007's second
  # tier silently collapses into the first — the exact 2026-07-28 failure, but
  # with no code change to blame it on.
  if [ -z "$SENTINEL" ]; then
    # FAIL, not WARN. This branch means the check cannot see the thing it
    # exists to guard, and ADR-0007's human tier is unverified — a warning
    # there is a check reporting its own blindness as a minor note. F65 is the
    # same lesson one layer over: a control that cannot find its baseline is
    # not a passing control.
    fail "cannot read the tier-2 sentinel assignee out of scripts/prejudge-review.sh"
    say  "      route_tier2() must park the tier-2 card on an assignee with no"
    say  "      profile. Until that name can be read, nothing here verifies the"
    say  "      human gate is still unclaimable (ADR-0007)."
  elif [ -d "$HOME/.hermes/profiles/$SENTINEL" ]; then
    fail "a profile exists at ~/.hermes/profiles/$SENTINEL"
    say  "      that name MUST stay unspawnable: it is what keeps parked tier-2"
    say  "      review cards away from the dispatcher. Delete it, or the human"
    say  "      gate becomes claimable by a lane again (ADR-0007)."
  else
    pass "tier-2 sentinel '$SENTINEL' is correctly absent from disk"
  fi
fi

# ---------------------------------------------------------------------------
# The lane's protocol is partly a program too (audit F64): §3 and §5 invoke
# scripts/lane-setup.sh and scripts/lane-blast-radius.sh through ~/.forge/repo.
# An unattended lane reaches them by that path and by no other, so a missing
# symlink or a cleared executable bit is a night-run failure the operator would
# only meet as a reaped `crashed` run. Checked THROUGH ~/.forge/repo, the way
# the lane calls them, rather than in this checkout — the checkout being fine is
# not the property that matters, and `make verify` already covers that one.
# ---------------------------------------------------------------------------
for _lscript in lane-setup.sh lane-blast-radius.sh; do
  _lpath="$HOME/.forge/repo/scripts/$_lscript"
  if [ ! -e "$_lpath" ]; then
    fail "~/.forge/repo/scripts/$_lscript does not resolve"
    say  "      forge-lane §3/§5 invoke it by exactly that path. Check the"
    say  "      ~/.forge/repo symlink, then re-run ./hermes/profiles-bootstrap.sh."
  elif [ ! -x "$_lpath" ]; then
    fail "~/.forge/repo/scripts/$_lscript is not executable"
    say  "      chmod +x it in the checkout; an unattended lane cannot repair this."
  else
    pass "lane protocol '$_lscript' resolves through ~/.forge/repo and is executable"
  fi
done

# ---------------------------------------------------------------------------
sect "9. Skills: discovery, and the curator risk"
# ---------------------------------------------------------------------------
# Hermes runs a curator that reviews, archives and rewrites the skills in its
# OWN skills dir. Forge skills are git-tracked, so they must not live there:
# they are declared per profile as `skills.external_dirs`, which the curator is
# contractually forbidden to touch (agent/curator.py). A symlink into the
# curated dir is the failure mode — methodology drifting outside git, silently.
#
# Each profile is its own HERMES_HOME with its own skills tree, so the DEFAULT
# profile's dir proves nothing about what a LANE can see. Check per profile.
HSK="${HERMES_SKILLS_DIR:-$HOME/.hermes/skills}"
if [ -d "$HSK" ]; then
  pass "hermes skills dir: $HSK"
  for s in scope architect roadmap start-chunk end-chunk judge retro forge-lane; do
    [ -L "$HSK/$s" ] && warn "forge skill '$s' is SYMLINKED into the curated dir —"
    [ -L "$HSK/$s" ] && say  "      remove it and use skills.external_dirs instead"
  done
else
  warn "hermes skills dir not found at $HSK — confirm with 'hermes skills list'"
fi

for pdir in "$HOME"/.hermes/profiles/forge-*/; do
  [ -d "$pdir" ] || continue
  pname="$(basename "$pdir")"
  # A profile without the `skills` toolset cannot load skills at all — not a fault.
  grep -qE '^[[:space:]]+- skills$' "$pdir/config.yaml" 2>/dev/null || continue
  if grep -q 'external_dirs' "$pdir/config.yaml" 2>/dev/null; then
    # Capture, THEN grep. `hermes … | grep -q` looks right and is not: grep -q
    # exits on the first match, hermes takes SIGPIPE, and `set -o pipefail`
    # reports 141 for a pipeline that actually succeeded.
    SL=""
    [ "$HAVE_HERMES" = 1 ] && SL="$(hermes -p "$pname" skills list 2>/dev/null)"
    if printf '%s' "$SL" | grep -q 'forge-lane'; then
      pass "$pname sees the forge skills (forge-lane resolved)"
    else
      fail "$pname declares external_dirs but 'forge-lane' does not resolve — a"
      say  "      quoted string instead of a YAML list makes the dir silently skipped"
    fi
  else
    fail "$pname has the skills toolset but no skills.external_dirs — it cannot"
    say  "      see the lane protocol. Run ./install.sh and paste the block it prints."
  fi
done
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
