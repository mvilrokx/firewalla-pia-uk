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
CLIENT_FILE=${CLIENT_FILE:-$APP_DIR/client}

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

die() { echo "error: $*" >&2; exit 1; }

# refuse_root <script name> — the scripts use sudo themselves where they must.
# Run as root, they would leave files that pi's cron job cannot write, and every
# later repair would fail.
refuse_root() { [[ $(id -u) != 0 ]] || die "do not run $1 as root or with sudo: run it as pi"; }

# take_lock <flock option>… — one run at a time: cron's keepalive, a keepalive
# started by hand, and setup. A lock file that cannot be opened is an error, not
# "busy": else the keepalive would stop for good without a word.
take_lock() {
  exec 9>> "$LOCK_FILE" || die "cannot open the lock file $LOCK_FILE"
  flock "$@" 9
}

# The cron line of this release, and the one of v0.1.0. install.sh and
# uninstall.sh remove only these exact lines, never a line that the user wrote.
CRON_LINE="*/5 * * * * timeout 240 $APP_DIR/bin/firewalla-pia-uk keepalive >>$APP_DIR/keepalive.log 2>&1"
OLD_CRON_LINE="*/5 * * * * flock -n /dev/shm/firewalla-pia-uk.lock timeout 110 $APP_DIR/bin/firewalla-pia-uk keepalive >>$APP_DIR/keepalive.log 2>&1"
without_our_cron_lines() { grep -vxF -e "$CRON_LINE" -e "$OLD_CRON_LINE" "$1"; }

# Cron runs every 5 minutes for months, so the log must not grow without limit.
# The trim rewrites the same file (cat, not mv): cron has already opened it for
# the run's error output, and with mv that output would go to a deleted file.
rotate_log() {
  [[ -f $LOG_FILE ]] || return 0
  local size tmp
  size=$(wc -c < "$LOG_FILE" | tr -d ' ')
  if (( size > 200000 )); then
    tmp=$(mktemp)
    tail -n 500 "$LOG_FILE" > "$tmp" && cat "$tmp" > "$LOG_FILE"
    rm -f "$tmp"
  fi
}

# Back-off bookkeeping: one key=value line per key.
state_get() {
  [[ -f $STATE_FILE ]] && awk -F= -v k="$1" '$1 == k { print $2 }' "$STATE_FILE"
  true
}

# state_num <key> → the value when it is a number, else 0: a damaged state file
# must not stop the failure handling.
state_num() {
  local v; v=$(state_get "$1")
  if [[ $v =~ ^(0|[1-9][0-9]{0,17})$ ]]; then echo "$v"; else echo 0; fi
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
