#!/bin/bash
set -u
PASS=0; FAIL=0
export PATH="$SHIM:$PATH" APP_DIR; APP_DIR=$(mktemp -d)
source "$ROOT/lib/common.sh"

assert_eq "missing key is empty" "$(state_get fail_count)" ""
state_set fail_count 1
assert_eq "set then get" "$(state_get fail_count)" "1"
state_set next_attempt 1700000000
state_set fail_count 2
assert_eq "overwrite keeps one line" "$(grep -c '^fail_count=' "$STATE_FILE")" "1"
assert_eq "overwritten value" "$(state_get fail_count)" "2"
assert_eq "other key untouched" "$(state_get next_attempt)" "1700000000"

assert_eq "state_num: a number" "$(state_num next_attempt)" "1700000000"
assert_eq "state_num: missing → 0" "$(state_num nothing)" "0"
state_set fail_count abc; assert_eq "state_num: not a number → 0" "$(state_num fail_count)" "0"
state_set fail_count 08; assert_eq "state_num: leading zero → 0" "$(state_num fail_count)" "0"
state_set fail_count 2

assert_eq "delay 1" "$(next_delay 1)" 900
assert_eq "delay 2" "$(next_delay 2)" 1800
assert_eq "delay 5" "$(next_delay 5)" 14400
assert_eq "delay capped" "$(next_delay 6)" 21600
assert_eq "delay stays capped" "$(next_delay 12)" 21600
assert_eq "delay does not overflow at 55" "$(next_delay 55)" 21600
assert_eq "delay does not overflow at 100" "$(next_delay 100)" 21600

log "hello world"
assert_contains "log line format" "$(cat "$LOG_FILE")" " hello world"
assert_eq "log line starts with a date" "$(cut -c5,8,11,14,17 "$LOG_FILE")" "-- ::"

yes "$(printf 'x%.0s' {1..100})" | head -3000 > "$LOG_FILE"
rotate_log
assert_eq "rotate_log keeps 500 lines" "$(wc -l < "$LOG_FILE" | tr -d ' ')" "500"
yes "$(printf 'x%.0s' {1..100})" | head -3000 > "$LOG_FILE"
exec 8>> "$LOG_FILE"   # cron's >> opens the log before the run starts
rotate_log
echo "error output after the trim" >&8
exec 8>&-
assert_eq "output through an already open log reaches the log" "$(tail -n 1 "$LOG_FILE")" "error output after the trim"
printf 'short\n' > "$LOG_FILE"; rotate_log
assert_eq "small log untouched" "$(cat "$LOG_FILE")" "short"

out=$( (take_lock -n; echo "rc=$?") 2>&1 )
assert_eq "take_lock: free lock" "$out" "rc=0"
out=$( (SHIM_FLOCK_BUSY=1 take_lock -n; echo "rc=$?") 2>&1 )
assert_eq "take_lock: busy lock" "$out" "rc=1"
out=$( (LOCK_FILE="$APP_DIR/no/such/folder/lock"; take_lock -n; echo "rc=$?") 2>&1 ); rc=$?
assert_contains "take_lock: lock file cannot be opened → error" "$out" "error: cannot open the lock file $APP_DIR/no/such/folder/lock"
assert_eq "take_lock: lock file cannot be opened → exit 1" "$rc" "1"

out=$( (SHIM_UID=0 refuse_root install.sh; echo "rc=$?") 2>&1 ); rc=$?
assert_eq "refuse_root: root" "$out|$rc" "error: do not run install.sh as root or with sudo: run it as pi|1"
out=$( (refuse_root install.sh; echo "rc=$?") 2>&1 )
assert_eq "refuse_root: not root" "$out" "rc=0"

printf '%s\n' '0 3 * * * echo other' '# firewalla-pia-uk keepalive runs every 5 min' \
  '*/10 * * * * /home/pi/notify.sh   # tails the firewalla-pia-uk keepalive log' \
  "$CRON_LINE" \
  "*/5 * * * * flock -n /dev/shm/firewalla-pia-uk.lock timeout 110 $APP_DIR/bin/firewalla-pia-uk keepalive >>$APP_DIR/keepalive.log 2>&1" \
  > "$APP_DIR/crontab"
assert_eq "without_our_cron_lines: only the user's lines stay" "$(without_our_cron_lines "$APP_DIR/crontab")" \
  "$(printf '%s\n' '0 3 * * * echo other' '# firewalla-pia-uk keepalive runs every 5 min' \
     '*/10 * * * * /home/pi/notify.sh   # tails the firewalla-pia-uk keepalive log')"
assert_eq "cron line" "$CRON_LINE" "*/5 * * * * timeout 240 $APP_DIR/bin/firewalla-pia-uk keepalive >>$APP_DIR/keepalive.log 2>&1"

out=$( (die "boom") 2>&1 ); rc=$?
assert_eq "die message" "$out" "error: boom"
assert_eq "die exit code" "$rc" "1"

rm -rf "$APP_DIR"
echo "PASS $PASS"; (( FAIL == 0 ))
