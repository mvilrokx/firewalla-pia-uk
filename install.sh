#!/bin/bash
# install.sh — installs or updates firewalla-pia-uk on this Firewalla.
# Run it as `pi` from the unpacked release folder. Running it again updates the
# scripts and the cron line, and keeps the saved PIA login and the PIA client.
set -uo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
for part in common pia profile; do
  source "$SRC/lib/$part.sh"
done
PROMPT_IN=${PROMPT_IN:-/dev/tty}
REQUIRED_TOOLS=${REQUIRED_TOOLS:-bash curl python3 wg flock timeout openssl qrencode ip sudo}

for tool in $REQUIRED_TOOLS; do
  command -v "$tool" > /dev/null || die "missing tool: $tool"
done

# Refuse a box we cannot work with before anything is copied or asked.
ids=$(find_profiles)
count=$(printf '%s' "$ids" | grep -c .)
if (( count > 1 )); then
  die "more than one PIA client: $(echo "$ids" | paste -sd ' ' -) — remove the extra ones in the Firewalla app, then run install.sh again"
fi
if (( count == 1 )); then
  find_profile > /dev/null || die "cannot read the PIA client profile ($ids.json)"
fi

mkdir -p "$APP_DIR"
cp -R "$SRC/bin" "$SRC/lib" "$SRC/share" "$APP_DIR/"
cp "$SRC/uninstall.sh" "$APP_DIR/"
chmod 755 "$APP_DIR/bin/firewalla-pia-uk" "$APP_DIR/uninstall.sh"
echo "Installed the scripts in $APP_DIR."

# The login is needed later by the keepalive, without anyone at the keyboard,
# so it is stored on the box (readable by pi only) and sent only to PIA. It is
# checked in a temporary file first, so an interrupted install never leaves an
# unchecked login behind.
if [[ -f $CREDS_FILE ]]; then
  echo "Using the saved PIA login."
else
  new_creds="$CREDS_FILE.new"
  rm -f "$new_creds"
  user="" pass=""
  # IFS= keeps spaces at the start and end of the password.
  { IFS= read -r -p "PIA username: " user; IFS= read -r -s -p "PIA password: " pass; } < "$PROMPT_IN"
  echo
  [[ -n $user && -n $pass ]] || die "the PIA username and password must not be empty"
  (umask 077; printf '%s\n%s\n' "$user" "$pass" > "$new_creds")
  CREDS_FILE=$new_creds get_token > /dev/null; rc=$?
  case $rc in
    0) mv "$new_creds" "$CREDS_FILE" ;;
    1) rm -f "$new_creds"; die "PIA rejected the login. Run install.sh again." ;;
    *) rm -f "$new_creds"; die "cannot reach PIA to check the login. Check the Internet connection, then run install.sh again." ;;
  esac
  echo "PIA login OK."
fi

if (( count == 0 )); then
  if ! "$APP_DIR/bin/firewalla-pia-uk" setup; then
    # A client that exists but has no handshake yet is what the keepalive
    # repairs, so it must still be installed.
    [[ $(find_profiles | grep -c .) == 1 ]] || exit 1
    echo "The client exists, so the installation continues. The keepalive will keep trying to connect it."
  fi
else
  echo "Using existing PIA client: $(profile_name "$ids") ($ids)"
fi

# Firewalla adds user_crontab to pi's crontab at every boot, so the line
# survives reboots and firmware updates. An older line of ours is replaced, so
# a new release can change it. Errors go to the log, not to /dev/null.
line="*/5 * * * * timeout 240 $APP_DIR/bin/firewalla-pia-uk keepalive >>$APP_DIR/keepalive.log 2>&1"
touch "$USER_CRONTAB"
tmp=$(mktemp)
grep -v 'firewalla-pia-uk keepalive' "$USER_CRONTAB" > "$tmp"
if [[ -s $tmp && -n $(tail -c 1 "$tmp") ]]; then echo >> "$tmp"; fi
echo "$line" >> "$tmp"
cat "$tmp" > "$USER_CRONTAB"   # cat, not mv: keeps the file's owner and mode
rm -f "$tmp"
bash "$FW_UPDATE_CRONTAB"
crontab -l | grep -q 'firewalla-pia-uk keepalive' || die "the cron line did not install"
echo "The keepalive runs every 5 minutes."

echo "Test run (changes nothing):"
log_lines=0
if [[ -f $LOG_FILE ]]; then log_lines=$(wc -l < "$LOG_FILE" | tr -d ' '); fi
"$APP_DIR/bin/firewalla-pia-uk" keepalive --dry-run --force
new_lines=$(tail -n +$(( log_lines + 1 )) "$LOG_FILE" 2>/dev/null)
echo "${new_lines:-(no log lines)}"
echo 'Next: make the BBC Route rule. See "Route rule" in the README.'
