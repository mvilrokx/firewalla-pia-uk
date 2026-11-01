#!/bin/bash
# uninstall.sh — removes firewalla-pia-uk from this Firewalla. The PIA client
# and the BBC Route rule stay: delete those in the Firewalla app.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib/common.sh"
PROMPT_IN=${PROMPT_IN:-/dev/tty}

if [[ -f $USER_CRONTAB ]]; then
  tmp=$(mktemp)
  grep -v 'firewalla-pia-uk keepalive' "$USER_CRONTAB" > "$tmp"
  cat "$tmp" > "$USER_CRONTAB"   # cat, not mv: keeps the file's owner and mode
  rm -f "$tmp"
  bash "$FW_UPDATE_CRONTAB"
fi
if crontab -l | grep -q 'firewalla-pia-uk keepalive'; then
  die "the cron line is still in pi's crontab. Run: bash $FW_UPDATE_CRONTAB"
fi
echo "Removed the cron line."

answer=""
read -r -p "Remove $APP_DIR, including your saved PIA login? [y/N] " answer < "$PROMPT_IN"
case $answer in
  y|Y) rm -rf "$APP_DIR"; echo "Removed $APP_DIR." ;;
  *) echo "Kept $APP_DIR." ;;
esac
echo "Delete the PIA client and the BBC Route rule in the Firewalla app."
