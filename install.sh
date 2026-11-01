#!/bin/bash
# install.sh — installs or updates firewalla-pia-uk on this Firewalla.
# Run it as `pi` from the unpacked release folder. Running it again updates the
# scripts and keeps the saved PIA login and the PIA client.
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

mkdir -p "$APP_DIR"
cp -R "$SRC/bin" "$SRC/lib" "$SRC/share" "$APP_DIR/"
cp "$SRC/uninstall.sh" "$APP_DIR/"
chmod 755 "$APP_DIR/bin/firewalla-pia-uk" "$APP_DIR/uninstall.sh"
echo "Installed the scripts in $APP_DIR."

# The login is needed later by the keepalive, without anyone at the keyboard,
# so it is stored on the box (readable by pi only) and sent only to PIA.
if [[ -f $CREDS_FILE ]]; then
  echo "Using the saved PIA login."
else
  user="" pass=""
  { read -r -p "PIA username: " user; read -r -s -p "PIA password: " pass; } < "$PROMPT_IN"
  echo
  [[ -n $user && -n $pass ]] || die "the PIA username and password must not be empty"
  (umask 077; printf '%s\n%s\n' "$user" "$pass" > "$CREDS_FILE")
  get_token > /dev/null || { rm -f "$CREDS_FILE"; die "PIA rejected the login. Run install.sh again."; }
  echo "PIA login OK."
fi

ids=$(find_profiles)
case $(printf '%s' "$ids" | grep -c .) in
  0) "$APP_DIR/bin/firewalla-pia-uk" setup || exit 1 ;;
  1) echo "Using existing PIA client: $(profile_name "$ids") ($ids)" ;;
  *) die "more than one PIA client: $(echo "$ids" | paste -sd ' ' -) — remove the extra ones in the Firewalla app, then run install.sh again" ;;
esac

# Firewalla adds user_crontab to pi's crontab at every boot, so the line
# survives reboots and firmware updates.
line="*/5 * * * * flock -n /dev/shm/firewalla-pia-uk.lock timeout 110 $APP_DIR/bin/firewalla-pia-uk keepalive >/dev/null 2>&1"
touch "$USER_CRONTAB"
if [[ -s $USER_CRONTAB && -n $(tail -c 1 "$USER_CRONTAB") ]]; then echo >> "$USER_CRONTAB"; fi
grep -q 'firewalla-pia-uk keepalive' "$USER_CRONTAB" || echo "$line" >> "$USER_CRONTAB"
bash "$FW_UPDATE_CRONTAB"
crontab -l | grep -q 'firewalla-pia-uk keepalive' || die "the cron line did not install"
echo "The keepalive runs every 5 minutes."

echo "Test run (changes nothing):"
"$APP_DIR/bin/firewalla-pia-uk" keepalive --dry-run --force
tail -n 3 "$LOG_FILE" 2>/dev/null
echo 'Next: make the BBC Route rule. See "Route rule" in the README.'
