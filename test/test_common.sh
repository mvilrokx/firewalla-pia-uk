#!/bin/bash
set -u
PASS=0; FAIL=0
export APP_DIR; APP_DIR=$(mktemp -d)
source "$ROOT/lib/common.sh"

assert_eq "missing key is empty" "$(state_get fail_count)" ""
state_set fail_count 1
assert_eq "set then get" "$(state_get fail_count)" "1"
state_set next_attempt 1700000000
state_set fail_count 2
assert_eq "overwrite keeps one line" "$(grep -c '^fail_count=' "$STATE_FILE")" "1"
assert_eq "overwritten value" "$(state_get fail_count)" "2"
assert_eq "other key untouched" "$(state_get next_attempt)" "1700000000"

assert_eq "delay 1" "$(next_delay 1)" 900
assert_eq "delay 2" "$(next_delay 2)" 1800
assert_eq "delay 5" "$(next_delay 5)" 14400
assert_eq "delay capped" "$(next_delay 6)" 21600
assert_eq "delay stays capped" "$(next_delay 12)" 21600

log "hello world"
assert_contains "log line format" "$(cat "$LOG_FILE")" " hello world"
assert_eq "log line starts with a date" "$(cut -c5,8,11,14,17 "$LOG_FILE")" "-- ::"

yes "$(printf 'x%.0s' {1..100})" | head -3000 > "$LOG_FILE"
rotate_log
assert_eq "rotate_log keeps 500 lines" "$(wc -l < "$LOG_FILE" | tr -d ' ')" "500"
printf 'short\n' > "$LOG_FILE"; rotate_log
assert_eq "small log untouched" "$(cat "$LOG_FILE")" "short"

out=$( (die "boom") 2>&1 ); rc=$?
assert_eq "die message" "$out" "error: boom"
assert_eq "die exit code" "$rc" "1"

rm -rf "$APP_DIR"
echo "PASS $PASS"; (( FAIL == 0 ))
