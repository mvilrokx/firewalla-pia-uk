#!/bin/bash
# Shared settings and helpers. Every setting can be overridden from the
# environment; the tests point them at temporary directories.

FW_HOME=${FW_HOME:-/home/pi/.firewalla}
APP_DIR=${APP_DIR:-$FW_HOME/config/firewalla-pia-uk}
WG_DIR=${WG_DIR:-$FW_HOME/run/wg_profile}
USER_CRONTAB=${USER_CRONTAB:-$FW_HOME/config/user_crontab}
FW_UPDATE_CRONTAB=${FW_UPDATE_CRONTAB:-/home/pi/firewalla/scripts/update_crontab.sh}

PIA_REGION=${PIA_REGION:-uk_2}
PIA_SERVERLIST_URL=${PIA_SERVERLIST_URL:-https://serverlist.piaservers.net/vpninfo/servers/v6}
PIA_TOKEN_URL=${PIA_TOKEN_URL:-https://www.privateinternetaccess.com/api/client/v2/token}
BBC_CHECK_URL=${BBC_CHECK_URL:-https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/bbc_one_london/format/json}

STALE_SECS=${STALE_SECS:-300}
POLL_SECS=${POLL_SECS:-5}

STATE_FILE=${STATE_FILE:-$APP_DIR/state}
LOG_FILE=${LOG_FILE:-$APP_DIR/keepalive.log}
CREDS_FILE=${CREDS_FILE:-$APP_DIR/credentials}
CA_FILE=${CA_FILE:-$APP_DIR/share/ca.rsa.4096.crt}
LOCK_FILE=${LOCK_FILE:-$APP_DIR/keepalive.lock}

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

die() { echo "error: $*" >&2; exit 1; }

# Cron runs every 5 minutes for months, so the log must not grow without limit.
rotate_log() {
  [[ -f $LOG_FILE ]] || return 0
  local size; size=$(wc -c < "$LOG_FILE" | tr -d ' ')
  if (( size > 200000 )); then
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

# Back-off bookkeeping: one key=value line per key.
state_get() {
  [[ -f $STATE_FILE ]] && awk -F= -v k="$1" '$1 == k { print $2 }' "$STATE_FILE"
  true
}

state_set() {
  local tmp; tmp=$(mktemp)
  { [[ -f $STATE_FILE ]] && grep -v "^$1=" "$STATE_FILE"; echo "$1=$2"; } > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# 15 min after the first failure, doubling, at most 6 h: PIA's API must not be
# hammered, and a dead account or region does not heal quickly.
next_delay() {
  local n=$1 d=900
  # Stop doubling at the cap: after ~55 doublings the number would overflow.
  while (( n > 1 && d < 21600 )); do d=$(( d * 2 )); n=$(( n - 1 )); done
  (( d > 21600 )) && d=21600
  echo "$d"
}
