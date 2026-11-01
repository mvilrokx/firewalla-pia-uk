#!/bin/bash
# shellcheck disable=SC2012  # ls only looks at files with fixed, safe names here
set -u
PASS=0; FAIL=0
T=$(mktemp -d)
export PATH="$SHIM:$PATH" POLL_SECS=0 SETUP_IMPORT_SECS=0 SETUP_HINT_SECS=0 SETUP_IFACE_SECS=0
export APP_DIR="$T/app" WG_DIR="$T/wg" SHIM_STATE="$T/shim" SHIM_LOG="$T/shim/shim.log"
export PIA_SERVERLIST_URL="file://$FIXTURES/serverlist.json"
CLI="$ROOT/bin/firewalla-pia-uk"
reset() {
  rm -rf "$APP_DIR" "$WG_DIR" "$SHIM_STATE"; mkdir -p "$APP_DIR" "$WG_DIR" "$SHIM_STATE"; : > "$SHIM_LOG"
  printf '%s\n%s\n' p1234567 pw > "$APP_DIR/credentials"
}
source "$ROOT/lib/common.sh"; source "$ROOT/lib/wg.sh"; source "$ROOT/lib/profile.sh"; source "$ROOT/lib/setup.sh"

assert_eq "make_conf" "$(make_conf PRIV 10.186.0.136 10.0.0.243 SRVKEY 85.203.46.72)" \
  "$(printf '[Interface]\nPrivateKey = PRIV\nAddress = 10.186.0.136/32\nDNS = 10.0.0.243\n\n[Peer]\nPublicKey = SRVKEY\nEndpoint = 85.203.46.72:1337\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25')"

reset; cp "$FIXTURES"/profile/* "$WG_DIR/"
wait_for_import "PUBOF:PRIVTEST=" 0 >/dev/null; assert_eq "import: other client is not ours" "$?" 1
cp "$FIXTURES"/imported/* "$WG_DIR/"
assert_eq "import: finds our client" "$(wait_for_import "PUBOF:PRIVTEST=" 0)" "2C3D_2C3D0"

reset; out=$(SHIM_IMPORT_FROM="$FIXTURES/imported" SHIM_HANDSHAKE_AGE=10 "$BASH" "$CLI" setup 2>&1; echo "rc=$?")
assert_contains "setup: QR shows the conf" "$out" "QR<<[Interface]"
assert_contains "setup: QR has the address" "$out" "Address = 10.186.0.136/32"
assert_contains "setup: instructions" "$out" "Scan QR Code"
assert_contains "setup: done" "$out" 'Setup complete: "PIA UK Streaming" (2C3D_2C3D0) is connected.'
assert_contains "setup: rc 0" "$out" "rc=0"
assert_eq "setup: temporary conf deleted" "$(ls "$APP_DIR/pia-uk.conf" 2>/dev/null)" ""
assert_contains "setup: registered our key" "$(cat "$SHIM_LOG")" "curl-arg pubkey=PUBOF:PRIVTEST="
assert_eq "setup: the new client is the chosen one" "$(cat "$APP_DIR/client")" "2C3D_2C3D0"
assert_contains "setup: how to import without the QR code" "$out" "Or copy $APP_DIR/pia-uk.conf to the phone and use Import Profile."

reset; out=$(SHIM_ADDKEY_FILE="$FIXTURES/addkey_error.json" "$BASH" "$CLI" setup 2>&1; echo "rc=$?")
assert_contains "addKey error: message" "$out" "error: PIA did not register the key: "
assert_contains "addKey error: PIA text" "$out" "Login failed!"
assert_contains "addKey error: rc 1" "$out" "rc=1"
assert_eq "addKey error: no conf" "$(ls "$APP_DIR/pia-uk.conf" 2>/dev/null)" ""

reset; out=$("$BASH" "$CLI" setup 2>&1; echo "rc=$?")
assert_contains "no import: tells the user" "$out" "no new client after 15 min. To show the QR code again: qrencode -t ansiutf8 < $APP_DIR/pia-uk.conf. After the import, run install.sh again"
assert_eq "no import: no client chosen" "$(cat "$APP_DIR/client" 2>/dev/null)" ""
assert_eq "no import: conf kept for Import Profile" "$(ls "$APP_DIR/pia-uk.conf")" "$APP_DIR/pia-uk.conf"
assert_eq "no import: conf is private" "$(ls -l "$APP_DIR/pia-uk.conf" | cut -c1-10)" "-rw-------"

reset; cp "$FIXTURES"/profile/* "$WG_DIR/"; echo 1D17_1D170 > "$APP_DIR/client"
out=$(SHIM_IMPORT_FROM="$FIXTURES/imported" SHIM_HANDSHAKE_AGE=10 "$BASH" "$CLI" setup 2>&1; echo "rc=$?")
assert_contains "other client present: new client made" "$out" 'Setup complete: "PIA UK Streaming" (2C3D_2C3D0) is connected.'
assert_eq "other client present: the new client is the chosen one" "$(cat "$APP_DIR/client")" "2C3D_2C3D0"

reset; out=$(SHIM_FLOCK_BUSY=1 "$BASH" "$CLI" setup 2>&1; echo "rc=$?")
assert_contains "keepalive busy: says so" "$out" "error: another firewalla-pia-uk run is busy; try again in a few minutes"
assert_contains "keepalive busy: rc 1" "$out" "rc=1"
assert_not_contains "keepalive busy: no PIA call" "$(cat "$SHIM_LOG")" "curl-arg"

# 3 s, not 2: with whole-second clocks a 2 s wait can end before the first note.
reset; out=$(POLL_SECS=1 SETUP_PROGRESS_SECS=1 wait_for_import "PUBOF:nobody" 3 2>&1)
assert_contains "progress while waiting" "$out" "Still waiting for the new client ("

reset; out=$(SHIM_IMPORT_FROM="$FIXTURES/imported" SHIM_HANDSHAKE_AGE=100000 "$BASH" "$CLI" setup 2>&1; echo "rc=$?")
assert_contains "no handshake: rc 1" "$out" "rc=1"
assert_eq "no handshake: conf deleted once imported" "$(ls "$APP_DIR/pia-uk.conf" 2>/dev/null)" ""
assert_eq "no handshake: the new client is the chosen one" "$(cat "$APP_DIR/client")" "2C3D_2C3D0"

reset; out=$(SHIM_CURL_FAIL_URL=token "$BASH" "$CLI" setup 2>&1)
assert_contains "no answer from PIA" "$out" "error: cannot reach PIA's login server"
reset; out=$(SHIM_HTTP_CODE=401 SHIM_TOKEN_BODY='HTTP Token: Access denied.' "$BASH" "$CLI" setup 2>&1)
assert_contains "wrong login" "$out" "error: PIA rejected the saved login"
reset; out=$(SHIM_HTTP_CODE=503 SHIM_TOKEN_BODY='<html>503</html>' "$BASH" "$CLI" setup 2>&1)
assert_contains "PIA outage" "$out" "error: PIA's login server gave no usable answer (HTTP 503). Try again later"
reset; printf '%s' '{"status":"OK","server_key":"NEWSERVERKEY0000000000000000000000000000000=","peer_ip":"10.186.0.136"}' > "$T/nodns.json"
out=$(SHIM_ADDKEY_FILE="$T/nodns.json" "$BASH" "$CLI" setup 2>&1)
assert_contains "no DNS server" "$out" "error: PIA sent no DNS server"

reset; out=$(SHIM_IMPORT_FROM="$FIXTURES/imported" SHIM_IFACE_MISSING=1 "$BASH" "$CLI" setup 2>&1; echo "rc=$?")
assert_contains "client off: hint" "$out" 'Turn on "PIA UK Streaming" in the Firewalla app (VPN Client), then wait here.'
assert_contains "client off: rc 1" "$out" "rc=1"

rm -rf "$T"
echo "PASS $PASS"; (( FAIL == 0 ))
