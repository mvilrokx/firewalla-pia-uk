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

reset; out=$(SHIM_ADDKEY_FILE="$FIXTURES/addkey_error.json" "$BASH" "$CLI" setup 2>&1; echo "rc=$?")
assert_contains "addKey error: message" "$out" "error: PIA did not register the key: "
assert_contains "addKey error: PIA text" "$out" "Login failed!"
assert_contains "addKey error: rc 1" "$out" "rc=1"
assert_eq "addKey error: no conf" "$(ls "$APP_DIR/pia-uk.conf" 2>/dev/null)" ""

reset; out=$("$BASH" "$CLI" setup 2>&1; echo "rc=$?")
assert_contains "no import: tells the user" "$out" "no new client after 15 min. Import $APP_DIR/pia-uk.conf, then run install.sh again"
assert_eq "no import: conf kept for Import Profile" "$(ls "$APP_DIR/pia-uk.conf")" "$APP_DIR/pia-uk.conf"
assert_eq "no import: conf is private" "$(ls -l "$APP_DIR/pia-uk.conf" | cut -c1-10)" "-rw-------"

reset; out=$(SHIM_IMPORT_FROM="$FIXTURES/imported" SHIM_IFACE_MISSING=1 "$BASH" "$CLI" setup 2>&1; echo "rc=$?")
assert_contains "client off: hint" "$out" 'Turn on "PIA UK Streaming" in the Firewalla app (VPN Client), then wait here.'
assert_contains "client off: rc 1" "$out" "rc=1"

rm -rf "$T"
echo "PASS $PASS"; (( FAIL == 0 ))
