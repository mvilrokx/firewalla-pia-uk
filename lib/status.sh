#!/bin/bash
# The status command: what the keepalive sees, plus a BBC check through the tunnel.
# There are no notifications, so this is how the user finds out what happened.

# bbc_classify <mediaselector body> → OK | blocked | unknown
bbc_classify() {
  case $1 in
    *'"result":"geolocation"'*) echo blocked ;;
    *'"media"'*) echo OK ;;
    *) echo unknown ;;
  esac
}

# bbc_verdict <iface> — asks BBC's media selector through the tunnel itself.
bbc_verdict() {
  bbc_classify "$(curl -s --max-time 15 --interface "$1" "$BBC_CHECK_URL")"
}

# fmt_time <epoch> → local "YYYY-mm-dd HH:MM". python3, because `date -r` and
# `date -d` differ between macOS and Linux.
fmt_time() {
  python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d %H:%M", time.localtime(int(sys.argv[1]))))' "$1"
}

row() { printf '%-13s%s\n' "$1:" "$2"; }

cmd_status() {
  local profile rc id ep _server_pub addr iface age last fails healthy=1 up=1
  profile=$(find_profile); rc=$?
  if (( rc == 1 )); then row client "none — run install.sh"; return 1; fi
  if (( rc == 2 )); then
    row client "more than one PIA client: $(find_profiles | paste -sd ' ' -) — remove the extra ones in the Firewalla app"
    return 1
  fi
  read -r id ep _server_pub addr <<< "$profile"
  iface="vpn_$id"

  row client "$(profile_name "$id") ($id)"
  row server "$ep"
  row address "$addr"
  if interface_exists "$iface"; then
    age=$(handshake_age "$(sudo wg show "$iface" latest-handshakes 2>/dev/null)")
    if (( age == 999999999 )); then row handshake never; else row handshake "$age s ago"; fi
    if (( age >= STALE_SECS )); then healthy=0; fi
  else
    row handshake "interface down (client turned off in the app)"
    up=0; healthy=0
  fi

  last=$(grep 'repaired:' "$LOG_FILE" 2>/dev/null | tail -n 1)
  row "last repair" "${last:-none}"
  fails=$(state_get fail_count)
  if [[ $fails =~ ^[1-9] ]]; then
    row failures "$fails (next attempt $(fmt_time "$(state_get next_attempt)"))"
  fi

  if (( up )); then
    case $(bbc_verdict "$iface") in
      OK) row BBC OK ;;
      blocked) row BBC "blocked (geolocation)"; healthy=0 ;;
      *) row BBC "unknown (no answer)"; healthy=0 ;;
    esac
  fi

  echo "recent log:"
  if [[ -s $LOG_FILE ]]; then tail -n 5 "$LOG_FILE"; else echo "(empty)"; fi
  (( healthy ))
}
