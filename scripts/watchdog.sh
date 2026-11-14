#!/usr/bin/env bash
# =============================================================================
# forge watchdog — is Forge alive? Run by launchd every 10 minutes, outside Hermes.
#
# Nothing Hermes runs can report that Hermes is down, so this is a plain bash script that needs
# neither the gateway nor Hermes cron nor the `hermes` binary: it reads Hermes' own files and asks
# launchd. It is READ-ONLY on boards and config. Five checks, each one OK or FAIL line (the fifth can also
# say WARN or SKIP, below):
#
#   gateway          launchd reports ai.hermes.gateway loaded and `state = running`
#   ticker           the newest output file of the cron job named forge-merge-watcher (found by name in
#                    cron/jobs.json) is younger than FORGE_WATCHDOG_TICK_MAX_MIN minutes (default 30)
#   digest           the newest output file of forge-digest is younger than 26 hours
#   auto_decompose   kanban.auto_decompose is false in the root config.yaml. True, absent (the kernel
#                    default is true), a quoted "false" (the kernel does bool("false") = true) or a
#                    form this reader cannot parse are all FAIL: with it on, Hermes turns every
#                    `triage` card on every board into new cards and dispatches workers on them,
#                    outside Forge's plan-and-contract flow
#   token            the verifier's `claude` still authenticates. `make preflight` only sees that the
#                    CLAUDE_CODE_OAUTH_TOKEN line is PRESENT; a dead token passed it twice and every verifier run
#                    then failed with a 401. This asks the question the verifier's call asks: it sources
#                    scripts/claude-token.sh and runs `claude -p "reply with exactly: OK" --model haiku
#                    --output-format json` with no CLAUDE_CODE_OAUTH_TOKEN in the environment, so the token comes
#                    from the root .env exactly as a worker's does. Three outcomes, kept apart:
#                      OK    the answer was JSON with is_error false
#                      FAIL  the answer was JSON with is_error true: the token is dead. Unhealthy, alerts like any FAIL
#                      WARN  could not ask (no claude binary, no token line, a timeout, output that is not JSON,
#                            e.g. the network is down): logged and named in the summary, never an alert, never a
#                            recovery. It is not cached as a verdict, and an earlier FAIL stays a FAIL until a probe
#                            answers OK, so a network blip cannot send "healthy again".
#                    A probe spends a (tiny) model call, so it runs at most every FORGE_WATCHDOG_TOKEN_EVERY seconds
#                    (default 21600, 6 h) and the verdict between probes is the cached one, with its age. A FAIL, or
#                    a probe that could not ask, is repeated every FORGE_WATCHDOG_TOKEN_RETRY seconds (default 1800)
#                    so a renewed token is noticed within half an hour. A probe is bounded by
#                    FORGE_WATCHDOG_TOKEN_TIMEOUT seconds (default 90): its whole process group is killed. The
#                    cache is <watchdog root>/token.json. FORGE_WATCHDOG_TOKEN=0 switches the check off (a SKIP line).
#                    The binary is $FORGE_WATCHDOG_CLAUDE, else <HERMES_HOME>/node/bin/claude (the one workers run),
#                    else `claude` on PATH. The token reaches only that child's environment: it is in no argv, no log,
#                    no state or cache file and no alert (an API error text is scrubbed of it before it is shown).
#
# Alerts go on a state CHANGE: healthy to unhealthy sends one message naming the failing checks,
# unhealthy to healthy sends one recovery message, and while it stays unhealthy the message repeats
# at most every FORGE_WATCHDOG_REMIND_HOURS (default 6). A message counts as delivered only when
# Telegram answers HTTP 200 with "ok":true; until then it is owed and the next pass tries again. It
# goes straight to the Telegram Bot API with curl, using TELEGRAM_BOT_TOKEN and TELEGRAM_HOME_CHANNEL
# from <HERMES_HOME>/.env. The token is parsed, never sourced or exported, and reaches curl on stdin
# (`curl --config -`), so it is in no argv, no environment, no output and no state file.
#
# Heartbeat (the dead-man's switch for the case nothing local can see): if <state root>/watchdog.env
# (~/.forge/watchdog.env) sets FORGE_HEARTBEAT_URL, a HEALTHY pass does a GET of it, and an unhealthy
# or unrunnable pass does not. A hosted dead-man's-switch service alerts when the pings stop. The URL
# is a secret: it lives only in that file and is never printed.
#
# Usage:
#   scripts/watchdog.sh                  # evaluate, alert on a change, ping the heartbeat when healthy
#   scripts/watchdog.sh --no-alert       # evaluate and print only: no send, no ping, no state, no directory
#   scripts/watchdog.sh --dry-run        # as --no-alert, and print what would be sent (token redacted)
#   scripts/watchdog-install.sh          # run this every 10 minutes under launchd
# Under --no-alert and --dry-run a due token probe is still asked (live), but its answer is not cached.
# To force a fresh answer after renewing the token:
#   FORGE_WATCHDOG_TOKEN_EVERY=0 FORGE_WATCHDOG_TOKEN_RETRY=0 scripts/watchdog.sh --no-alert
# Exit: 0 healthy (a WARN is still healthy), 1 unhealthy, 2 cannot run (no jq, an unwritable state directory,
# a bad argument).
#
# Paths: HERMES_HOME (default ~/.hermes) and the forge state root (scripts/forge-state.sh; the alert
# state is <root>/watchdog/state.json). Test seams, not operator knobs: FORGE_WATCHDOG_NOW (epoch
# seconds), FORGE_WATCHDOG_LAUNCHCTL, FORGE_WATCHDOG_CURL, FORGE_WATCHDOG_CLAUDE.
# =============================================================================
set -uo pipefail

wd_help() { awk 'NR>2 && /^# ={10,}/{exit} NR>2 {sub(/^# ?/, ""); print}' "$0"; }

NO_ALERT=0; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-alert) NO_ALERT=1; shift;;
    --dry-run)  DRY_RUN=1; shift;;
    -h|--help)  wd_help; exit 0;;
    *) echo "watchdog: unknown argument '$1'" >&2; exit 2;;
  esac
done

die() { echo "watchdog: cannot run: $*" >&2; exit 2; }

# launchd hands a LaunchAgent /usr/bin:/bin:/usr/sbin:/sbin, and jq is Homebrew's. APPENDED, so a
# stub earlier on PATH still wins.
PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin"
export PATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || die "the script directory cannot be resolved"
[ -n "${HOME:-}" ] || die "HOME is not set"
# shellcheck source=forge-state.sh
. "$HERE/forge-state.sh" || die "cannot source forge-state.sh beside this script"
command -v jq >/dev/null 2>&1 || die "jq is not on PATH (looked in \$PATH plus /opt/homebrew/bin and /usr/local/bin)"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
NOW="${FORGE_WATCHDOG_NOW:-$(date +%s)}"
TICK_MAX_MIN="${FORGE_WATCHDOG_TICK_MAX_MIN:-30}"
REMIND_H="${FORGE_WATCHDOG_REMIND_HOURS:-6}"
DIGEST_MAX_H=26
TOKEN_ON=1; [ "${FORGE_WATCHDOG_TOKEN:-1}" != 0 ] || TOKEN_ON=0
TOKEN_EVERY="${FORGE_WATCHDOG_TOKEN_EVERY:-21600}"
TOKEN_RETRY="${FORGE_WATCHDOG_TOKEN_RETRY:-1800}"
TOKEN_TIMEOUT="${FORGE_WATCHDOG_TOKEN_TIMEOUT:-90}"
LAUNCHCTL="${FORGE_WATCHDOG_LAUNCHCTL:-launchctl}"
CURL="${FORGE_WATCHDOG_CURL:-curl}"
TG_API="https://api.telegram.org"   # fixed: no override may redirect where the bot token is sent
GW_LABEL="ai.hermes.gateway"
for _v in NOW TICK_MAX_MIN REMIND_H TOKEN_EVERY TOKEN_RETRY TOKEN_TIMEOUT; do
  eval "_val=\${$_v}"
  case "$_val" in ''|*[!0-9]*) die "$_v must be a non-negative integer, got '$_val'";; esac
  eval "$_v=\$((10#\$_val))"   # a leading zero is not octal
done
[ "$TICK_MAX_MIN" -ge 1 ] || die "FORGE_WATCHDOG_TICK_MAX_MIN must be at least 1"
[ "$TOKEN_TIMEOUT" -ge 1 ] || die "FORGE_WATCHDOG_TOKEN_TIMEOUT must be at least 1"

WD_ROOT="$(forge_watchdog_root)"
STATE_FILE="$WD_ROOT/state.json"
TOKEN_FILE="$WD_ROOT/token.json"
HB_ENV="$(forge_state_root)/watchdog.env"
ENV_FILE="$HERMES_HOME/.env"
CFG_FILE="$HERMES_HOME/config.yaml"
JOBS_FILE="$HERMES_HOME/cron/jobs.json"
TAB=$'\t'; CR=$'\r'; NLC=$'\n'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
wd_stamp() { # epoch -> a readable time (GNU date, then BSD date, then the bare epoch)
  date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf 'epoch %s' "$1"
}

wd_mtime() { # file -> its mtime in epoch seconds (GNU stat, then BSD stat), or fails
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)" || m=""
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null)" || m="";; esac
  case "$m" in ''|*[!0-9]*) return 1;; esac
  printf '%s' "$m"
}

# Prints the value of the LAST `NAME=` line of a dotenv file, or nothing. The file is parsed with bash
# builtins, never sourced: an optional `export `, then a double-quoted, single-quoted or bare value (the
# forms Hermes' own loader accepts, as scripts/claude-token.sh does). Runs in a subshell with xtrace off.
wd_env_get() { # file name
  (
    set +x
    f="$1"; name="$2"; last=""
    [ -r "$f" ] || exit 0
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%"$CR"}"
      line="${line#"${line%%[![:space:]]*}"}"
      case "$line" in export[[:space:]]*) line="${line#export}"; line="${line#"${line%%[![:space:]]*}"}";; esac
      case "$line" in "$name"=*) ;; *) continue;; esac
      v="${line#"$name"=}"
      case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}";;
        \'*\') v="${v#\'}"; v="${v%\'}";;
        *) v="${v%%[[:space:]]#*}"; v="${v%"${v##*[![:space:]]}"}";;
      esac
      last="$v"
    done < "$f"
    printf '%s' "$last"
  )
}

wd_clean() { # text going into a message or a curl config: no control characters, quotes or backslashes
  printf '%s' "$1" | tr -d '\000-\037"\\' | cut -c1-220
}

# ---------------------------------------------------------------------------
# the five checks
# ---------------------------------------------------------------------------
FAIL_NAMES=""
FAIL_LINES=""
WARN_NAMES=""
res() { # ok|fail|warn|skip name reason. Only fail makes the run unhealthy: a warn is "could not ask", a skip is "switched off".
  case "$1" in
    ok)   printf 'OK    %-15s %s\n' "$2" "$3";;
    warn) printf 'WARN  %-15s %s\n' "$2" "$3"; WARN_NAMES="$WARN_NAMES $2";;
    skip) printf 'SKIP  %-15s %s\n' "$2" "$3";;
    *)
      printf 'FAIL  %-15s %s\n' "$2" "$3"
      FAIL_NAMES="$FAIL_NAMES $2"
      FAIL_LINES="$FAIL_LINES$2|$3$NLC";;
  esac
}

chk_gateway() {
  # `launchctl print gui/<uid>/<label>` names the domain, so it does not depend on which session runs it,
  # and tells "not loaded" (non-zero exit) from "loaded, not running" (state is not `running`).
  local uid out rc state
  uid="$(id -u)"
  out="$("$LAUNCHCTL" print "gui/$uid/$GW_LABEL" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    res fail gateway "$GW_LABEL is not loaded in gui/$uid (launchctl print exited $rc: $(printf '%s' "$out" | head -n 1 | cut -c1-80))"
    return
  fi
  state="$(printf '%s\n' "$out" | awk '$1 == "state" && $2 == "=" { $1 = ""; $2 = ""; sub(/^ +/, ""); print; exit }')"
  case "$state" in
    running) res ok gateway "$GW_LABEL is running";;
    "")      res fail gateway "$GW_LABEL is loaded but launchctl print shows no state";;
    *)       res fail gateway "$GW_LABEL is loaded but not running (state = $state)";;
  esac
}

job_id() { # job name -> its id from cron/jobs.json, or nothing
  jq -r --arg n "$1" '[.jobs[]? | select(.name == $n) | .id][0] // empty' "$JOBS_FILE" 2>/dev/null
}

chk_cron_output() { # check-name job-name max-age-seconds age-unit(m|h)
  local check="$1" job="$2" max="$3" unit="$4" id dir newest m age shown limit
  if [ ! -r "$JOBS_FILE" ]; then res fail "$check" "$JOBS_FILE is not readable, so the $job job cannot be found"; return; fi
  id="$(job_id "$job")"
  if [ -z "$id" ]; then res fail "$check" "no cron job named $job in $JOBS_FILE"; return; fi
  dir="$HERMES_HOME/cron/output/$id"
  newest="$(ls -t "$dir" 2>/dev/null | head -n 1)"
  if [ -z "$newest" ]; then res fail "$check" "$job ($id) has never written an output file in $dir"; return; fi
  if ! m="$(wd_mtime "$dir/$newest")"; then res fail "$check" "cannot read the mtime of $dir/$newest"; return; fi
  age=$((NOW - m)); [ "$age" -ge 0 ] || age=0
  if [ "$unit" = h ]; then shown="$((age / 3600))h"; limit="$((max / 3600))h"; else shown="$((age / 60))m"; limit="$((max / 60))m"; fi
  if [ "$age" -lt "$max" ]; then
    res ok "$check" "newest $job output is $shown old (limit $limit)"
  else
    res fail "$check" "newest $job output is $shown old, over the $limit limit ($newest)"
  fi
}

chk_auto_decompose() {
  # Read straight from config.yaml, scoped to the top-level kanban: block's own keys: Hermes may be the thing
  # that is broken, and `hermes` is not on a LaunchAgent's PATH. Only a bare false (or the YAML spellings no and
  # off, which Hermes' loader also reads as false) passes.
  local r
  if [ ! -r "$CFG_FILE" ]; then res fail auto_decompose "$CFG_FILE is not readable"; return; fi
  r="$(awk '
    BEGIN { inblk = 0; ind = -1; res = "absent" }
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^[[:space:]]*(#.*)?$/ { next }
    {
      match(line, /^ */); n = RLENGTH
      if (n == 0) {
        inblk = 0; ind = -1
        if (line ~ /^kanban:[[:space:]]*(#.*)?$/) { inblk = 1; res = "absent" }
        else if (line ~ /^kanban:/) { res = "flow" }
        next
      }
      if (!inblk) next
      if (ind < 0) ind = n
      if (n != ind) next
      if (line ~ /^ *auto_decompose:([[:space:]]|$)/) {
        v = line; sub(/^ *auto_decompose:[[:space:]]*/, "", v)
        if (substr(v, 1, 1) == "\"" || substr(v, 1, 1) == "\047") { res = "quoted" }
        else { sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v); res = "bare:" tolower(v) }
      }
    }
    END { print res }' "$CFG_FILE" 2>/dev/null)"
  case "$r" in
    bare:false|bare:no|bare:off) res ok auto_decompose "kanban.auto_decompose is false";;
    absent)  res fail auto_decompose "kanban.auto_decompose is not set in $CFG_FILE, and the kernel default is true";;
    quoted)  res fail auto_decompose "kanban.auto_decompose is a quoted string, which the kernel reads as true";;
    flow)    res fail auto_decompose "kanban: is not a block mapping in $CFG_FILE, so kanban.auto_decompose cannot be read";;
    bare:*)  res fail auto_decompose "kanban.auto_decompose is '$(printf '%s' "${r#bare:}" | tr -d '\000-\037' | cut -c1-30)', not false";;
    *)       res fail auto_decompose "kanban.auto_decompose could not be read from $CFG_FILE";;
  esac
}

# ---------------------------------------------------------------------------
# the token check: does the verifier's `claude` still authenticate? (see the header)
# ---------------------------------------------------------------------------
# Which claude to ask. Prints its path and returns 0, or prints why there is none and returns 1. An explicit
# FORGE_WATCHDOG_CLAUDE that is not an executable file is an answer, not a hint: it does not fall through.
wd_claude_bin() {
  local b
  if [ -n "${FORGE_WATCHDOG_CLAUDE:-}" ]; then
    b="$FORGE_WATCHDOG_CLAUDE"
    if [ -f "$b" ] && [ -x "$b" ]; then printf '%s' "$b"; return 0; fi
    printf 'FORGE_WATCHDOG_CLAUDE (%s) is not an executable file' "$b"; return 1
  fi
  b="$HERMES_HOME/node/bin/claude"   # the one a worker runs; a LaunchAgent's PATH does not have it
  if [ -x "$b" ] && [ ! -d "$b" ]; then printf '%s' "$b"; return 0; fi
  b="$(type -P claude 2>/dev/null)" || b=""   # -P: the file on PATH, never the `claude` function claude-token.sh defines
  case "$b" in /*) if [ -x "$b" ]; then printf '%s' "$b"; return 0; fi;; esac
  printf 'no claude binary at %s/node/bin/claude or on PATH' "$HERMES_HOME"; return 1
}

# Asks the question and prints ONE line: `ok`, `dead <reason>` or `unknown <reason>`. The token is read in here, by
# claude-token.sh's own parser, and travels only into the child's environment: no argv, no output, no file. xtrace is off
# for the whole subshell, and a reason that quotes the token (or any sk-ant-... string) is scrubbed before it is printed.
wd_token_probe() {
  (
    set +x
    LC_ALL=C; export LC_ALL
    unset CLAUDE_CODE_OAUTH_TOKEN   # the child must get the root .env's token the way a worker does, not ours
    export HERMES_HOME
    # shellcheck source=claude-token.sh
    . "$HERE/claude-token.sh" 2>/dev/null || { echo "unknown cannot source claude-token.sh beside the watchdog"; exit 0; }
    envf="$(forge_claude_root_env)"
    tok="$(forge_claude_token_read "$envf")"
    if [ -z "$tok" ]; then echo "unknown no CLAUDE_CODE_OAUTH_TOKEN line in $envf, so there is nothing to ask with"; exit 0; fi
    if ! bin="$(wd_claude_bin)"; then echo "unknown $bin"; exit 0; fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/forge-wd-token.XXXXXX" 2>/dev/null)" || { echo "unknown cannot make a scratch directory"; exit 0; }
    trap 'rm -rf "$work"' EXIT
    # claude-token.sh's `claude` function execs the first `claude` PATH finds. Make that the binary resolved above
    # (its own directory first, which is where a node-based claude finds node; a shim when it is not called claude).
    bdir="$(dirname "$bin")"
    if [ "$(basename "$bin")" != claude ] && ln -s "$bin" "$work/claude" 2>/dev/null; then bdir="$work"; fi
    PATH="$bdir:$HERMES_HOME/node/bin:$PATH"; export PATH
    if [ "$(head -c 2 "$bin" 2>/dev/null)" = '#!' ] && head -n 1 "$bin" 2>/dev/null | grep -q node && ! command -v node >/dev/null 2>&1; then
      echo "unknown $bin is a node script and node is not on PATH"; exit 0
    fi
    cd / 2>/dev/null   # a neutral directory: no CLAUDE.md, .claude/ or hooks of whatever repo this was run from
    # Bounded, and macOS has no timeout(1): the child leads its own process group (set -m) and a watcher kills the group.
    set -m
    ( claude -p "reply with exactly: OK" --model haiku --output-format json ) >"$work/out" 2>/dev/null </dev/null &
    pid=$!
    ( sleep "$TOKEN_TIMEOUT"; : > "$work/timedout"; kill -TERM -- "-$pid"; sleep 2; kill -KILL -- "-$pid" ) >/dev/null 2>&1 &
    wpid=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill -TERM -- "-$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
    set +m
    if [ -e "$work/timedout" ]; then
      kill -KILL -- "-$pid" 2>/dev/null
      echo "unknown claude did not answer within ${TOKEN_TIMEOUT}s"; exit 0
    fi
    v="$(jq -r '
      (if type == "array" then (map(select(type == "object" and .type == "result")) | last) else . end) as $r
      | if ($r | type) != "object" then "unknown"
        elif $r.is_error == false then "ok"
        elif $r.is_error == true then
          "dead " + ([($r.api_error_status // empty | tostring), ($r.result // "" | tostring | gsub("[\\s]+"; " "))] | map(select(. != "")) | join(": "))
        else "unknown" end' "$work/out" 2>/dev/null | head -n 1)"
    case "$v" in
      ok) echo ok;;
      dead*)
        r="${v#dead}"; red='<redacted>'
        r="${r//"$tok"/$red}"
        r="$(printf '%s' "$r" | tr -cd ' -~' | sed 's/sk-ant-[A-Za-z0-9_-]*/<redacted>/g; s/^ *//' | cut -c1-70)"
        echo "dead ${r:-no reason given}";;
      *) echo "unknown claude answered with something that is not a JSON result with is_error (exit $rc), e.g. the network is down";;
    esac
  ) 2>/dev/null
}

# The cache, <watchdog root>/token.json: the last VERDICT (ok or fail, when, and why) and the last ATTEMPT (when, and why
# it could not ask, if it could not). A probe that could not ask is never a verdict. A file that cannot be read, or whose
# fields are not what this writes, is as good as none.
TK_VERDICT=none; TK_AT=0; TK_REASON=""; TK_TRIED=0; TK_NOTE=""; TK_WRITE_NOTE=""
tk_get() { jq -r --arg k "$1" '.[$k] // empty | tostring' "$TOKEN_FILE" 2>/dev/null; }
tk_read() {
  local v va r t n
  [ -f "$TOKEN_FILE" ] || return 0
  v="$(tk_get verdict)"; va="$(tk_get verdict_at)"; r="$(tk_get reason)"; t="$(tk_get tried_at)"; n="$(tk_get tried_note)"
  case "$v" in ok|fail|none) ;; *) return 0;; esac
  case "$va" in ''|*[!0-9]*) return 0;; esac
  case "$t" in ''|*[!0-9]*) return 0;; esac
  TK_VERDICT="$v"; TK_AT="$((10#$va))"; TK_REASON="$r"; TK_TRIED="$((10#$t))"; TK_NOTE="$n"
}
tk_write() {
  local tmp
  mkdir -p "$WD_ROOT" 2>/dev/null || return 1
  tmp="$(mktemp "$WD_ROOT/token.json.XXXXXX" 2>/dev/null)" || return 1
  if jq -n --arg v "$TK_VERDICT" --argjson va "$TK_AT" --arg r "$TK_REASON" --argjson t "$TK_TRIED" --arg n "$TK_NOTE" '
       { schema: "forge.watchdog.token.v1", verdict: $v, verdict_at: $va, reason: $r, tried_at: $t, tried_note: $n }' > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$TOKEN_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}
tk_due() { # is a probe owed? An ok verdict is good for TOKEN_EVERY; everything else is asked again after TOKEN_RETRY.
  local every="$TOKEN_RETRY"
  [ "$TK_TRIED" -gt 0 ] || return 0                 # never asked
  [ "$TK_TRIED" -le "$NOW" ] || return 0            # dated in the future: not to be trusted
  if [ "$TK_VERDICT" = ok ] && [ "$TK_TRIED" = "$TK_AT" ]; then every="$TOKEN_EVERY"; fi
  [ $((NOW - TK_TRIED)) -ge "$every" ]
}
wd_ago() { # seconds -> "just now", "12m ago" or "2h ago"
  local s="$1"; [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 60 ]; then echo "just now"; elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m ago"; else echo "$((s / 3600))h ago"; fi
}

chk_token() {
  local out kind why ago env_shown txt note
  if [ "$TOKEN_ON" = 0 ]; then res skip token "switched off (FORGE_WATCHDOG_TOKEN=0)"; return; fi
  tk_read
  if tk_due; then
    out="$(wd_token_probe)"; [ -n "$out" ] || out="unknown the probe produced no answer"
    kind="${out%% *}"; why="${out#* }"
    case "$kind" in
      ok)   TK_VERDICT=ok;   TK_AT="$NOW"; TK_REASON="";     TK_TRIED="$NOW"; TK_NOTE="";;
      dead) TK_VERDICT=fail; TK_AT="$NOW"; TK_REASON="$why"; TK_TRIED="$NOW"; TK_NOTE="";;
      *)    TK_TRIED="$NOW"; TK_NOTE="$why";;
    esac
    if [ "$READONLY" = 0 ]; then tk_write || TK_WRITE_NOTE="the token cache $TOKEN_FILE could not be written, so the next pass asks again"; fi
  fi
  ago="$(wd_ago $((NOW - TK_AT)))"
  note="$(wd_clean "$TK_NOTE")"
  case "$ENV_FILE" in "$HOME"/*) env_shown="~/${ENV_FILE#"$HOME"/}";; *) env_shown="$ENV_FILE";; esac
  case "$TK_VERDICT" in
    fail)
      txt="the verifier's claude token did not authenticate ($(wd_clean "$TK_REASON")) - renew CLAUDE_CODE_OAUTH_TOKEN in $env_shown and restart the gateway"
      if [ "$TK_TRIED" = "$TK_AT" ]; then txt="$txt [asked $ago]"
      else txt="$txt [asked $ago; the re-check could not ask: $(printf '%s' "$note" | cut -c1-50)]"; fi
      res fail token "$txt";;
    ok)
      if [ "$TK_TRIED" = "$TK_AT" ]; then res ok token "the verifier's claude token answered $ago"
      else res warn token "could not ask the verifier's claude token: $note (it last answered $ago)"; fi;;
    *)
      res warn token "could not ask the verifier's claude token: $note";;
  esac
}

# ---------------------------------------------------------------------------
# curl, with the secret on stdin only
# ---------------------------------------------------------------------------
# Telegram. Prints one line saying what happened (never the token, the URL or the response body) and returns 0
# only when Telegram answered HTTP 200 with "ok":true. MODE is check (are the credentials usable?), dry (print the
# request with the token redacted) or send.
wd_telegram() { # mode text
  (
    set +x
    mode="$1"; text="$2"
    tok="$(wd_env_get "$ENV_FILE" TELEGRAM_BOT_TOKEN)"; chat="$(wd_env_get "$ENV_FILE" TELEGRAM_HOME_CHANNEL)"
    if [ ! -r "$ENV_FILE" ]; then echo "$ENV_FILE is not readable, so there is no TELEGRAM_BOT_TOKEN"; exit 1; fi
    if [ -z "$tok" ]; then echo "TELEGRAM_BOT_TOKEN is not set in $ENV_FILE"; exit 1; fi
    if [ -z "$chat" ]; then echo "TELEGRAM_HOME_CHANNEL is not set in $ENV_FILE"; exit 1; fi
    case "$tok" in *[!A-Za-z0-9:_-]*) echo "TELEGRAM_BOT_TOKEN in $ENV_FILE has characters a token does not"; exit 1;; esac
    case "$chat" in *[!A-Za-z0-9:_@.-]*) echo "TELEGRAM_HOME_CHANNEL in $ENV_FILE has characters a chat id does not"; exit 1;; esac
    [ "$mode" = check ] && { echo "credentials present"; exit 0; }
    if [ "$mode" = dry ]; then
      echo "would POST $TG_API/bot<redacted>/sendMessage chat_id=$chat"
      printf '%s\n' "$text" | sed 's/^/        /'
      exit 0
    fi
    esc="$(printf '%s' "$text" | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
    cfg="url = \"$TG_API/bot$tok/sendMessage\"
data-urlencode = \"chat_id=$chat\"
data-urlencode = \"text=$esc\"
silent
max-time = 20
write-out = \"\\n%{http_code}\""
    out="$(printf '%s\n' "$cfg" | "$CURL" -q --config - 2>/dev/null)"; rc=$?
    if [ "$rc" != 0 ] && [ -z "$out" ]; then echo "curl exited $rc"; exit 1; fi
    code="${out##*"$NLC"}"; body="${out%"$NLC"*}"
    if [ "$code" = 200 ]; then
      case "$body" in *'"ok":true'*) echo "sent"; exit 0;; esac
      echo "HTTP 200 without \"ok\":true"; exit 1
    fi
    echo "HTTP ${code:-none}$([ "$rc" != 0 ] && echo ", curl exited $rc")"
    exit 1
  )
}

# The dead-man's-switch ping. Prints one line, never the URL. A failure is not fatal and not retried.
wd_heartbeat() { # mode (dry|send)
  (
    set +x
    url="$(wd_env_get "$HB_ENV" FORGE_HEARTBEAT_URL)"
    [ -n "$url" ] || { echo "not configured (no FORGE_HEARTBEAT_URL in $HB_ENV)"; exit 3; }
    case "$url" in http://*|https://*) ;; *) echo "FORGE_HEARTBEAT_URL in $HB_ENV is not an http(s) URL"; exit 1;; esac
    case "$url" in *[[:space:]\"\\]*) echo "FORGE_HEARTBEAT_URL in $HB_ENV has characters a URL does not"; exit 1;; esac
    [ "$1" = dry ] && { echo "would GET the heartbeat URL (not printed)"; exit 0; }
    printf 'url = "%s"\nsilent\nfail\nmax-time = 10\noutput = "/dev/null"\n' "$url" | "$CURL" -q --config - >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then echo "pinged"; exit 0; fi
    echo "failed (curl exited $rc), ignored"; exit 1
  )
}

# ---------------------------------------------------------------------------
# alert state: what the operator last HEARD, kept apart from what is observed now
# ---------------------------------------------------------------------------
A_STATUS=healthy; A_AT=0; STATE_NOTE=""
if [ -f "$STATE_FILE" ]; then
  _row="$(jq -r '[(.alerted // "healthy"), (.alerted_at // 0)] | @tsv' "$STATE_FILE" 2>/dev/null)" || _row=""
  case "$_row" in
    healthy"$TAB"[0-9]*|unhealthy"$TAB"[0-9]*) A_STATUS="${_row%%"$TAB"*}"; A_AT="${_row#*"$TAB"}";;
    *) STATE_NOTE="the state file $STATE_FILE could not be read and was treated as a healthy baseline";;
  esac
fi

state_write() { # observed alerted alerted_at
  local tmp
  mkdir -p "$WD_ROOT" 2>/dev/null || return 1
  tmp="$(mktemp "$WD_ROOT/state.json.XXXXXX" 2>/dev/null)" || return 1
  if jq -n --argjson now "$NOW" --arg obs "$1" --arg failing "$FAIL_NAMES" --arg al "$2" --argjson at "$3" '
       { schema: "forge.watchdog.v1", checked_at: $now, observed: $obs,
         failing: ($failing | split(" ") | map(select(. != ""))), alerted: $al, alerted_at: $at }' > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$STATE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
READONLY=0; [ "$NO_ALERT" = 1 ] || [ "$DRY_RUN" = 1 ] && READONLY=1
if [ "$READONLY" = 0 ]; then
  mkdir -p "$WD_ROOT" 2>/dev/null && [ -w "$WD_ROOT" ] || die "the state directory $WD_ROOT cannot be created or written"
fi

printf 'forge watchdog %s\n' "$(wd_stamp "$NOW")"
chk_gateway
chk_cron_output ticker forge-merge-watcher "$((TICK_MAX_MIN * 60))" m
chk_cron_output digest forge-digest "$((DIGEST_MAX_H * 3600))" h
chk_auto_decompose
chk_token

if [ -z "$FAIL_NAMES" ]; then OBSERVED=healthy; else OBSERVED=unhealthy; fi
[ -z "$STATE_NOTE" ] || echo "note: $STATE_NOTE"
[ -z "$TK_WRITE_NOTE" ] || echo "note: $TK_WRITE_NOTE"
WARN_SUFFIX=""; [ -z "$WARN_NAMES" ] || WARN_SUFFIX=" (warning: $(printf '%s' "${WARN_NAMES# }" | tr ' ' ','))"
# Say whether an alert COULD be sent, every pass, so a missing token shows in the log and not only on the day it matters.
if _out="$(wd_telegram check "")"; then echo "alerts: ready (TELEGRAM_BOT_TOKEN and TELEGRAM_HOME_CHANNEL read from $ENV_FILE)"
else echo "alerts: NOT READY, $_out"; fi

KIND=none
if [ "$OBSERVED" = unhealthy ]; then
  if [ "$A_STATUS" != unhealthy ]; then KIND=alert
  elif [ $((NOW - A_AT)) -ge $((REMIND_H * 3600)) ]; then KIND=reminder; fi
elif [ "$A_STATUS" = unhealthy ]; then
  KIND=recovery
fi

HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
HOST="$(wd_clean "$HOST")"
MSG=""
case "$KIND" in
  alert|reminder)
    if [ "$KIND" = alert ]; then MSG="Forge watchdog ($HOST): UNHEALTHY"; else MSG="Forge watchdog ($HOST): still UNHEALTHY"; fi
    while IFS='|' read -r _n _r; do
      [ -n "$_n" ] || continue
      MSG="$MSG$NLC- $_n: $(wd_clean "$_r")"
    done <<EOF
$FAIL_LINES
EOF
    ;;
  recovery)
    MSG="Forge watchdog ($HOST): healthy again"
    ;;
esac

NEW_A="$A_STATUS"; NEW_AT="$A_AT"
if [ "$KIND" = none ]; then
  echo "alert: none needed (alerted state: $A_STATUS)"
elif [ "$READONLY" = 1 ]; then
  if [ "$DRY_RUN" = 1 ]; then
    _out="$(wd_telegram dry "$MSG")"
    echo "alert: $KIND would be sent ($_out)"
  else
    echo "alert: $KIND is due but --no-alert was given"
  fi
else
  _out="$(wd_telegram send "$MSG")"; _rc=$?
  if [ "$_rc" = 0 ]; then
    echo "alert: $KIND sent"
    if [ "$KIND" = recovery ]; then NEW_A=healthy; else NEW_A=unhealthy; fi
    NEW_AT="$NOW"
  else
    echo "alert: $KIND NOT sent: $_out (it is still owed, and the next pass tries again)"
  fi
fi

if [ "$READONLY" = 0 ]; then
  state_write "$OBSERVED" "$NEW_A" "$NEW_AT" || echo "note: the state file $STATE_FILE could not be written"
fi

if [ "$OBSERVED" = healthy ]; then
  if [ "$NO_ALERT" = 1 ]; then echo "heartbeat: skipped (--no-alert)"
  elif [ "$DRY_RUN" = 1 ]; then _out="$(wd_heartbeat dry)"; echo "heartbeat: $_out"
  else _out="$(wd_heartbeat send)"; echo "heartbeat: $_out"; fi
else
  echo "heartbeat: not sent (unhealthy)"
fi

if [ "$OBSERVED" = healthy ]; then
  echo "watchdog: healthy$WARN_SUFFIX"
  exit 0
fi
echo "watchdog: UNHEALTHY ($(printf '%s' "${FAIL_NAMES# }" | tr ' ' ','))$WARN_SUFFIX"
exit 1
