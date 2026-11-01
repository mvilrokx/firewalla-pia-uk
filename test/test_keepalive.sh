#!/bin/bash
# shellcheck disable=SC2012  # ls only counts files with fixed, safe names here
set -u
PASS=0; FAIL=0
T=$(mktemp -d)
export PATH="$SHIM:$PATH" POLL_SECS=0
export APP_DIR="$T/app" WG_DIR="$T/wg" SHIM_STATE="$T/shim" SHIM_LOG="$T/shim/shim.log"
export PIA_SERVERLIST_URL="file://$FIXTURES/serverlist.json"
CLI="$ROOT/bin/firewalla-pia-uk"; LOG="$APP_DIR/keepalive.log"
reset() {
  rm -rf "$APP_DIR" "$WG_DIR" "$SHIM_STATE"; mkdir -p "$APP_DIR" "$WG_DIR" "$SHIM_STATE"
  cp "$FIXTURES"/profile/* "$WG_DIR/"; : > "$SHIM_LOG"
  printf '%s\n%s\n' p1234567 'secret pw' > "$APP_DIR/credentials"
  echo 1D17_1D170 > "$APP_DIR/client"
}
run() { "$BASH" "$CLI" keepalive "$@"; echo "rc=$?"; }
logtext() { cat "$LOG" 2>/dev/null; }

reset; out=$(SHIM_HANDSHAKE_AGE=10 run)
assert_eq "fresh: rc 0" "$out" "rc=0"
assert_eq "fresh: no log" "$(logtext)" ""
assert_not_contains "fresh: no Internet call" "$(cat "$SHIM_LOG")" "curl-arg"

reset; SHIM_IFACE_MISSING=1 run >/dev/null; out=$(SHIM_IFACE_MISSING=1 run)
assert_eq "client off: rc 0" "$out" "rc=0"
assert_eq "client off: logged once" "$(grep -c 'the PIA client PIA UK Streaming (WG) (1D17_1D170) is turned off in the Firewalla app — nothing to do' "$LOG")" "1"
SHIM_HANDSHAKE_AGE=10 run >/dev/null; SHIM_IFACE_MISSING=1 run >/dev/null
assert_eq "client off again after it was on: logged again" "$(grep -c 'is turned off' "$LOG")" "2"

reset; rm -f "$APP_DIR/client"; run >/dev/null; out=$(run)
assert_eq "no client chosen: rc 0" "$out" "rc=0"
assert_eq "no client chosen: logged once" "$(grep -c 'no PIA client chosen — run install.sh' "$LOG")" "1"

reset; rm -f "$WG_DIR"/*; run >/dev/null; out=$(run)
assert_eq "chosen client gone: rc 1" "$out" "rc=1"
assert_eq "chosen client gone: logged once" "$(grep -c 'the PIA client 1D17_1D170 is gone (deleted in the app?) — run install.sh again' "$LOG")" "1"

reset; cp "$FIXTURES"/imported/* "$WG_DIR/"; out=$(SHIM_HANDSHAKE_AGE=100000 run --dry-run)
assert_eq "two clients: rc 0" "$out" "rc=0"
assert_contains "two clients: the chosen one is used" "$(logtext)" "(profile 1D17_1D170, endpoint 85.203.46.180)"
assert_not_contains "two clients: the other one is left alone" "$(logtext)" "2C3D_2C3D0"

reset; out=$(SHIM_HANDSHAKE_AGE=100000 PIA_EP_OVERRIDE=85.203.46.73 run --dry-run)
assert_eq "current dry-run: rc 0" "$out" "rc=0"
assert_contains "current dry-run: age" "$(logtext)" "handshake 10000"
assert_contains "current dry-run: target" "$(logtext)" "DRY RUN: would addKey CLIENTPUB= at https://Server-10871-2a:1337 (85.203.46.73)"

reset; SHIM_HANDSHAKE_AGE=100000 run --dry-run >/dev/null
assert_contains "unlisted dry-run" "$(logtext)" "endpoint 85.203.46.180 is not in PIA's list now — using 85.203.46.72 (Server-10870-2a)"

reset; echo "next_attempt=$(( $(date +%s) + 600 ))" > "$APP_DIR/state"
out=$(SHIM_HANDSHAKE_AGE=100000 run --dry-run)
assert_eq "back-off: silent" "$out|$(logtext)" "rc=0|"
SHIM_HANDSHAKE_AGE=100000 run --dry-run --force >/dev/null
assert_contains "--force ignores back-off" "$(logtext)" "DRY RUN"

reset; echo "next_attempt=4102444800" > "$APP_DIR/state"
out=$(SHIM_HANDSHAKE_AGE=100000 run --dry-run)
assert_contains "next attempt far in the future (clock was wrong): ignored" "$(logtext)" "DRY RUN"

reset; out=$(SHIM_HANDSHAKE_AGE=100000 PIA_SERVERLIST_URL="file://$FIXTURES/serverlist_broken.json" run)
assert_eq "broken list: rc 1" "$out" "rc=1"
assert_contains "broken list: logged" "$(logtext)" "FAIL(1): server list is not valid JSON — next attempt in 15 min"
assert_between "broken list: back-off" "$(( $(grep '^next_attempt=' "$APP_DIR/state" | cut -d= -f2) - $(date +%s) ))" 890 900

reset; printf 'fail_count=abc\nnext_attempt=\n' > "$APP_DIR/state"
out=$(SHIM_HANDSHAKE_AGE=100000 PIA_SERVERLIST_URL="file://$FIXTURES/serverlist_broken.json" run 2>&1)
assert_eq "damaged state file: rc 1" "$out" "rc=1"
assert_contains "damaged state file: failure counted from 0" "$(logtext)" "FAIL(1): server list is not valid JSON"

reset; out=$(SHIM_HANDSHAKE_AGE=100000 SHIM_ADDKEY_FILE="$FIXTURES/addkey_error.json" run)
assert_eq "addKey error: rc 1" "$out" "rc=1"
assert_contains "addKey error: PIA message logged" "$(logtext)" "Login failed!"
assert_eq "addKey error: no backup" "$(ls "$APP_DIR/backup" 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "addKey error: json unchanged" "$(cat "$WG_DIR/1D17_1D170.json")" "$(cat "$FIXTURES/profile/1D17_1D170.json")"
SHIM_HANDSHAKE_AGE=100000 run --dry-run --force >/dev/null
assert_contains "addKey error: PIA answered, so the same server next time" "$(logtext)" "DRY RUN: would addKey CLIENTPUB= at https://Server-10870-2a:1337 (85.203.46.72)"

reset; out=$(SHIM_HANDSHAKE_AGE=100000 run)
assert_eq "repair: rc 0" "$out" "rc=0"
assert_contains "repair: logged with the client" "$(logtext)" "repaired: now on 85.203.46.72 (Server-10870-2a), address 10.186.0.136 — handshake OK (profile 1D17_1D170, backup: $APP_DIR/backup/"
assert_contains "repair: live swap" "$(cat "$SHIM_LOG")" "$(printf '%s\n' \
  'wg set vpn_1D17_1D170 peer OLDSERVERKEY= remove' \
  'wg set vpn_1D17_1D170 peer NEWSERVERKEY0000000000000000000000000000000= endpoint 85.203.46.72:1337 allowed-ips 0.0.0.0/0 persistent-keepalive 25' \
  'ip addr add 10.186.0.136/32 dev vpn_1D17_1D170' \
  'ip addr del 10.65.10.126/32 dev vpn_1D17_1D170')"
assert_contains "repair: files patched" "$(cat "$WG_DIR/1D17_1D170.json")" '"endpoint":"85.203.46.72:1337"'
assert_not_contains "repair: password not logged" "$(logtext)" "secret pw"

reset; out=$(SHIM_HANDSHAKE_AGE=100000 SHIM_NO_FRESH=1 run)
assert_eq "no handshake after repair: rc 1" "$out" "rc=1"
assert_contains "no handshake after repair: logged" "$(logtext)" "FAIL(1): registered on 85.203.46.72 (Server-10870-2a), address 10.186.0.136, but no handshake within 30 s"
assert_not_contains "no handshake after repair: not 'repaired'" "$(logtext)" "repaired:"
assert_contains "no handshake after repair: files patched" "$(cat "$WG_DIR/1D17_1D170.json")" '"endpoint":"85.203.46.72:1337"'

reset; out=$(SHIM_HANDSHAKE_AGE=10 SHIM_NO_FRESH=1 run --force)
assert_eq "--force, working tunnel, no new handshake: rc 1" "$out" "rc=1"
assert_not_contains "--force, working tunnel, no new handshake: not 'repaired'" "$(logtext)" "repaired:"

reset; chmod 444 "$WG_DIR/1D17_1D170.settings"; out=$(SHIM_HANDSHAKE_AGE=100000 run)
assert_eq "read-only profile: rc 1" "$out" "rc=1"
assert_contains "read-only profile: logged" "$(logtext)" "FAIL(1): cannot write the profile files"
assert_not_contains "read-only profile: no live change" "$(cat "$SHIM_LOG")" "wg set"
chmod 644 "$WG_DIR/1D17_1D170.settings"

reset; printf '{"addresses":[]}' > "$WG_DIR/1D17_1D170.json"; run >/dev/null; out=$(SHIM_HANDSHAKE_AGE=100000 run)
assert_eq "unreadable profile: rc 1" "$out" "rc=1"
assert_eq "unreadable profile: logged once" "$(grep -c 'cannot read the PIA client profile (1D17_1D170.json)' "$LOG")" "1"

reset; out=$(SHIM_WG_BROKEN=1 run)
assert_eq "broken wg: rc 1" "$out" "rc=1"
assert_contains "broken wg: logged" "$(logtext)" "FAIL(1): cannot read the client public key from vpn_1D17_1D170"

reset; printf 'fail_count=2\nnext_attempt=%s\n' $(( $(date +%s) + 20000 )) > "$APP_DIR/state"
SHIM_HANDSHAKE_AGE=10 run >/dev/null
assert_eq "fresh handshake clears the back-off" "$(sort "$APP_DIR/state" | paste -sd ' ' -)" "fail_count=0 next_attempt=0"

reset; SHIM_HANDSHAKE_AGE=100000 PIA_SERVERLIST_URL="file://$FIXTURES/serverlist_broken.json" run --dry-run >/dev/null
assert_contains "dry-run failure: logged" "$(logtext)" "FAIL (dry run): server list is not valid JSON"
assert_eq "dry-run failure: no back-off" "$(cat "$APP_DIR/state" 2>/dev/null)" ""

reset; out=$(SHIM_HANDSHAKE_AGE=100000 SHIM_CURL_FAIL_URL=addKey run)
assert_eq "addKey timeout: rc 1" "$out" "rc=1"
assert_contains "addKey timeout: curl's reason logged" "$(logtext)" "FAIL(1): addKey failed: curl: (28) Operation timed out"
SHIM_HANDSHAKE_AGE=100000 run --dry-run --force >/dev/null
assert_contains "addKey timeout: next time another server" "$(logtext)" "DRY RUN: would addKey CLIENTPUB= at https://Server-10871-2a:1337 (85.203.46.73)"
SHIM_HANDSHAKE_AGE=100000 run --force >/dev/null
assert_contains "addKey timeout: repaired on the other server" "$(logtext)" "repaired: now on 85.203.46.73 (Server-10871-2a)"
assert_eq "addKey timeout: forgotten after the repair" "$(grep '^avoid_ip=' "$APP_DIR/state")" "avoid_ip="

reset; out=$(SHIM_HANDSHAKE_AGE=100000 SHIM_CURL_FAIL_URL=token run)
assert_contains "no answer from PIA: logged" "$(logtext)" "FAIL(1): cannot reach PIA's login server"
reset; out=$(SHIM_HANDSHAKE_AGE=100000 SHIM_HTTP_CODE=401 SHIM_TOKEN_BODY='HTTP Token: Access denied.' run)
assert_contains "wrong login: logged" "$(logtext)" "FAIL(1): PIA rejected the saved login"
reset; out=$(SHIM_HANDSHAKE_AGE=100000 SHIM_HTTP_CODE=503 SHIM_TOKEN_BODY='<html>503</html>' run)
assert_contains "PIA outage: logged" "$(logtext)" "FAIL(1): PIA's login server gave no usable answer (HTTP 503)"
assert_not_contains "PIA outage: not a wrong login" "$(logtext)" "rejected"

reset; out=$(SHIM_FLOCK_BUSY=1 SHIM_HANDSHAKE_AGE=100000 run 2>&1)
assert_contains "busy: says so" "$out" "another firewalla-pia-uk run is busy; nothing done"
assert_contains "busy: rc 0" "$out" "rc=0"
assert_eq "busy: no log" "$(logtext)" ""

reset; out=$(LOCK_FILE="$T/no/such/folder/lock" SHIM_HANDSHAKE_AGE=100000 run 2>&1)
assert_contains "lock file cannot be opened: says so" "$out" "error: cannot open the lock file $T/no/such/folder/lock"
assert_contains "lock file cannot be opened: rc 1" "$out" "rc=1"
assert_not_contains "lock file cannot be opened: no Internet call" "$(cat "$SHIM_LOG")" "curl-arg"

reset; out=$(SHIM_HANDSHAKE_AGE=never-then-fresh run)
assert_eq "just-started client: rc 0 and silent" "$out|$(logtext)" "rc=0|"
assert_not_contains "just-started client: no Internet call" "$(cat "$SHIM_LOG")" "curl-arg"
reset; out=$(SHIM_HANDSHAKE_AGE=never run)
assert_eq "never-handshaking client: repaired, rc 0" "$out" "rc=0"
assert_contains "never-handshaking client: logged" "$(logtext)" "repaired: now on 85.203.46.72"

reset; out=$(SHIM_UID=0 SHIM_HANDSHAKE_AGE=100000 run 2>&1)
assert_contains "as root: refused" "$out" "error: do not run firewalla-pia-uk as root or with sudo: run it as pi"
assert_contains "as root: rc 1" "$out" "rc=1"
assert_eq "as root: nothing done" "$(logtext)|$(cat "$SHIM_LOG")" "|"

reset; out=$(run --bogus 2>/dev/null); assert_eq "unknown flag: rc 64" "$out" "rc=64"
out=$("$BASH" "$CLI" 2>/dev/null; echo "rc=$?"); assert_eq "no command: rc 64" "$out" "rc=64"

rm -rf "$T"
echo "PASS $PASS"; (( FAIL == 0 ))
