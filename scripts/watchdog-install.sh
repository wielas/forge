#!/usr/bin/env bash
# =============================================================================
# forge watchdog-install — run scripts/watchdog.sh every 10 minutes under launchd, outside Hermes.
#
# Renders a per-user LaunchAgent, label ai.forge.watchdog, into ~/Library/LaunchAgents and loads it:
#   /bin/bash ~/.forge/repo/scripts/watchdog.sh   StartInterval 600, RunAtLoad true,
#   stdout and stderr to <forge state root>/watchdog/watchdog.log
# The program path is the runtime form ~/.forge/repo/scripts/..., expanded for this user: it is the only
# path that resolves from anywhere, and it follows the runtime when the runtime is redeployed. Run this
# from the RUNTIME, after the checkout that has watchdog.sh is deployed there.
#
# Usage:
#   ~/.forge/repo/scripts/watchdog-install.sh              # write the plist and load it (idempotent)
#   ~/.forge/repo/scripts/watchdog-install.sh --print      # print the plist and do nothing else
#   ~/.forge/repo/scripts/watchdog-install.sh --uninstall  # unload the job and remove the plist
# Exit: 0 done, 1 launchctl refused, 2 usage or the host cannot do it (the runtime has no watchdog.sh yet).
#
# Uninstalling leaves the state directory (the alert state and the log) in place. Test seam, not a knob:
# FORGE_WATCHDOG_LAUNCHCTL names the launchctl to call.
# =============================================================================
set -uo pipefail

wi_help() { awk 'NR>2 && /^# ={10,}/{exit} NR>2 {sub(/^# ?/, ""); print}' "$0"; }
die() { echo "watchdog-install: $*" >&2; exit 2; }

MODE=install
case "${1:-}" in
  "") ;;
  --print) MODE=print;;
  --uninstall) MODE=uninstall;;
  -h|--help) wi_help; exit 0;;
  *) die "unknown argument '$1'";;
esac
[ $# -le 1 ] || die "one argument at most"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || die "the script directory cannot be resolved"
[ -n "${HOME:-}" ] || die "HOME is not set"
# shellcheck source=forge-state.sh
. "$HERE/forge-state.sh" || die "cannot source forge-state.sh beside this script"

LABEL="ai.forge.watchdog"
LAUNCHCTL="${FORGE_WATCHDOG_LAUNCHCTL:-launchctl}"
PROGRAM="$HOME/.forge/repo/scripts/watchdog.sh"
WD_ROOT="$(forge_watchdog_root)"
LOG="$WD_ROOT/watchdog.log"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

render() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml "$PROGRAM")</string>
  </array>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml "$LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml "$LOG")</string>
</dict>
</plist>
EOF
}

if [ "$MODE" = print ]; then
  render
  exit 0
fi

UID_N="$(id -u)"
DOMAIN="gui/$UID_N"

if [ "$MODE" = uninstall ]; then
  "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || echo "note: $LABEL was not loaded"
  rm -f "$PLIST" || die "cannot remove $PLIST"
  echo "uninstalled $LABEL: unloaded and $PLIST removed; $WD_ROOT (state and log) is left in place"
  exit 0
fi

[ -f "$PROGRAM" ] || die "$PROGRAM does not exist. Deploy the runtime that has scripts/watchdog.sh first; launchd would run a program that is not there every 10 minutes"
mkdir -p "$WD_ROOT" "$AGENTS_DIR" || die "cannot create $WD_ROOT and $AGENTS_DIR (launchd will not create a log directory)"
TMP="$(mktemp "$AGENTS_DIR/.$LABEL.XXXXXX")" || die "cannot write in $AGENTS_DIR"
render > "$TMP" || { rm -f "$TMP"; die "cannot render the plist"; }
if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$TMP" >/dev/null 2>&1; then
  rm -f "$TMP"; die "the rendered plist does not lint; nothing was installed"
fi
chmod 644 "$TMP" && mv -f "$TMP" "$PLIST" || { rm -f "$TMP"; die "cannot install $PLIST"; }

# bootout then bootstrap, so a reinstall replaces a loaded job instead of failing on it.
"$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
if ! _err="$("$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" 2>&1)"; then
  echo "watchdog-install: launchctl bootstrap $DOMAIN $PLIST failed: $_err" >&2
  exit 1
fi
echo "installed $LABEL: $PLIST loaded in $DOMAIN; it runs now and every 10 minutes"
echo "log: $LOG"
echo "the first pass is already running; read the log, or run: /bin/bash $PROGRAM --no-alert"
exit 0
