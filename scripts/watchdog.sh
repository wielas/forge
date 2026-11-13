#!/usr/bin/env bash
# =============================================================================
# forge watchdog — is Forge alive? Run by launchd every 10 minutes, outside Hermes.
#
# Nothing Hermes runs can report that Hermes is down, so this is a plain bash script that needs
# neither the gateway nor Hermes cron nor the `hermes` binary: it reads Hermes' own files and asks
# launchd. It is READ-ONLY on boards and config. Four checks, each one OK or FAIL line:
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
# Exit: 0 healthy, 1 unhealthy, 2 cannot run (no jq, an unwritable state directory, a bad argument).
#
# Paths: HERMES_HOME (default ~/.hermes) and the forge state root (scripts/forge-state.sh; the alert
# state is <root>/watchdog/state.json). Test seams, not operator knobs: FORGE_WATCHDOG_NOW (epoch
# seconds), FORGE_WATCHDOG_LAUNCHCTL, FORGE_WATCHDOG_CURL.
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
LAUNCHCTL="${FORGE_WATCHDOG_LAUNCHCTL:-launchctl}"
CURL="${FORGE_WATCHDOG_CURL:-curl}"
TG_API="https://api.telegram.org"   # fixed: no override may redirect where the bot token is sent
GW_LABEL="ai.hermes.gateway"
for _v in NOW TICK_MAX_MIN REMIND_H; do
  eval "_val=\${$_v}"
  case "$_val" in ''|*[!0-9]*) die "$_v must be a non-negative integer, got '$_val'";; esac
  eval "$_v=\$((10#\$_val))"   # a leading zero is not octal
done
[ "$TICK_MAX_MIN" -ge 1 ] || die "FORGE_WATCHDOG_TICK_MAX_MIN must be at least 1"

WD_ROOT="$(forge_watchdog_root)"
STATE_FILE="$WD_ROOT/state.json"
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
# the four checks
# ---------------------------------------------------------------------------
FAIL_NAMES=""
FAIL_LINES=""
res() { # ok|fail name reason
  if [ "$1" = ok ]; then
    printf 'OK    %-15s %s\n' "$2" "$3"
  else
    printf 'FAIL  %-15s %s\n' "$2" "$3"
    FAIL_NAMES="$FAIL_NAMES $2"
    FAIL_LINES="$FAIL_LINES$2|$3$NLC"
  fi
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

if [ -z "$FAIL_NAMES" ]; then OBSERVED=healthy; else OBSERVED=unhealthy; fi
[ -z "$STATE_NOTE" ] || echo "note: $STATE_NOTE"
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
  echo "watchdog: healthy"
  exit 0
fi
echo "watchdog: UNHEALTHY ($(printf '%s' "${FAIL_NAMES# }" | tr ' ' ','))"
exit 1
