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
REQUIRED_TOOLS=${REQUIRED_TOOLS:-bash curl python3 wg flock timeout qrencode ip sudo}

refuse_root install.sh
for tool in $REQUIRED_TOOLS; do
  command -v "$tool" > /dev/null || die "missing tool: $tool"
done

# All answers come from one open PROMPT_IN, so that a test can give them as the
# lines of one file. It is opened only when there is a question.
answers_open=0
open_answers() {
  if (( ! answers_open )); then
    exec 3< "$PROMPT_IN" || die "cannot read the answers from $PROMPT_IN"
    answers_open=1
  fi
}

# A server on port 1337 does not make a client PIA's, and some users have more
# than one PIA client: the user says which one the keepalive may change. This
# happens before anything is copied, so a wrong answer changes nothing.
chosen="" answer=""
ids=$(find_profiles)
if [[ -n $ids ]]; then
  echo "WireGuard clients on port 1337:"
  n=0 default=""
  for id in $ids; do
    n=$(( n + 1 ))
    if [[ $id == "$(client_id)" ]]; then
      default=$n
      echo "  $n) $(profile_name "$id") ($id) — in use"
    else
      echo "  $n) $(profile_name "$id") ($id)"
    fi
  done
  open_answers
  IFS= read -r -p "Which one is your PIA UK client? Type its number, or 0 to make a new one${default:+ [$default]}: " answer <&3
  answer=${answer:-$default}
  if ! [[ $answer =~ ^(0|[1-9][0-9]*)$ ]] || (( answer > n )); then
    die "type a number from 0 to $n, then run install.sh again"
  fi
  if (( answer > 0 )); then
    chosen=$(echo "$ids" | sed -n "${answer}p")
    read_profile "$chosen" > /dev/null || die "cannot read the PIA client profile ($chosen.json)"
  fi
fi

mkdir -p "$APP_DIR"
# A clean copy: a file that this release no longer has must not stay behind.
rm -rf "${APP_DIR:?}/bin" "${APP_DIR:?}/lib" "${APP_DIR:?}/share"
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
  open_answers
  # IFS= keeps spaces at the start and end of the password.
  { IFS= read -r -p "PIA username: " user; IFS= read -r -s -p "PIA password: " pass; } <&3
  echo
  [[ -n $user && -n $pass ]] || die "the PIA username and password must not be empty"
  (umask 077; printf '%s\n%s\n' "$user" "$pass" > "$new_creds")
  status=$(CREDS_FILE=$new_creds get_token); rc=$?
  case $rc in
    0) mv "$new_creds" "$CREDS_FILE" ;;
    1) rm -f "$new_creds"; die "PIA rejected the login. Run install.sh again." ;;
    2) rm -f "$new_creds"; die "cannot reach PIA to check the login. Check the Internet connection, then run install.sh again." ;;
    *) rm -f "$new_creds"; die "PIA's login server gave no usable answer (HTTP $status). Try again later: run install.sh again." ;;
  esac
  echo "PIA login OK."
fi

if [[ -n $chosen ]]; then
  echo "$chosen" > "$CLIENT_FILE"
  # Left by a setup that timed out: the imported client has the private key now.
  rm -f "$APP_DIR/pia-uk.conf"
  echo "Using PIA client: $(profile_name "$chosen") ($chosen)"
else
  rm -f "$CLIENT_FILE"
  if ! "$APP_DIR/bin/firewalla-pia-uk" setup; then
    # A client that exists but has no handshake yet is what the keepalive
    # repairs, so it must still be installed.
    [[ -s $CLIENT_FILE ]] || exit 1
    echo "The client exists, so the installation continues. The keepalive will keep trying to connect it."
  fi
fi

# Firewalla adds user_crontab to pi's crontab at every boot, so the line
# survives reboots and firmware updates. The line of an older release is
# replaced, so a new release can change it. Errors go to the log, not to /dev/null.
touch "$USER_CRONTAB"
tmp=$(mktemp)
without_our_cron_lines "$USER_CRONTAB" > "$tmp"
if [[ -s $tmp && -n $(tail -c 1 "$tmp") ]]; then echo >> "$tmp"; fi
echo "$CRON_LINE" >> "$tmp"
cat "$tmp" > "$USER_CRONTAB"   # cat, not mv: keeps the file's owner and mode
rm -f "$tmp"
bash "$FW_UPDATE_CRONTAB"
crontab -l | grep -qxF "$CRON_LINE" || die "the cron line did not install"
echo "The keepalive runs every 5 minutes."

echo "Test run (changes nothing):"
log_lines=0
if [[ -f $LOG_FILE ]]; then log_lines=$(wc -l < "$LOG_FILE" | tr -d ' '); fi
"$APP_DIR/bin/firewalla-pia-uk" keepalive --dry-run --force
new_lines=$(tail -n +$(( log_lines + 1 )) "$LOG_FILE" 2>/dev/null)
echo "${new_lines:-(no log lines)}"
echo 'Next: make the BBC Route rule. See "Route rule" in the README.'
