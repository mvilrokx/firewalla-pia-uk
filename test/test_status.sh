#!/bin/bash
set -u
PASS=0; FAIL=0
T=$(mktemp -d)
export PATH="$SHIM:$PATH" APP_DIR="$T/app" WG_DIR="$T/wg" SHIM_LOG="$T/shim.log"
mkdir -p "$APP_DIR" "$WG_DIR"; cp "$FIXTURES"/profile/* "$WG_DIR/"
CLI="$ROOT/bin/firewalla-pia-uk"
source "$ROOT/lib/common.sh"; source "$ROOT/lib/status.sh"
st() { "$BASH" "$CLI" status; echo "rc=$?"; }

assert_eq "classify OK" "$(bbc_classify "$(cat "$FIXTURES/mediaselector_ok.json")")" "OK"
assert_eq "classify blocked" "$(bbc_classify "$(cat "$FIXTURES/mediaselector_blocked.json")")" "blocked"
assert_eq "classify other" "$(bbc_classify "<html>")" "unknown"

printf '2026-11-01 03:10:22 repaired: now on 85.203.46.72 (Server-10870-2a), address 10.186.0.136 — handshake OK (backup: x)\n' > "$APP_DIR/keepalive.log"
: > "$SHIM_LOG"; out=$(SHIM_HANDSHAKE_AGE=10 st)
assert_contains "healthy: client" "$out" "client:      PIA UK Streaming (WG) (1D17_1D170)"
assert_contains "healthy: server" "$out" "server:      85.203.46.180"
assert_contains "healthy: handshake" "$out" " s ago"
assert_contains "healthy: last repair" "$out" "last repair: 2026-11-01 03:10:22 repaired: now on 85.203.46.72"
assert_contains "healthy: BBC" "$out" "BBC:         OK"
assert_not_contains "healthy: no failures line" "$out" "failures:"
assert_contains "healthy: rc 0" "$out" "rc=0"
assert_contains "BBC probe through the tunnel" "$(cat "$SHIM_LOG")" "$(printf 'curl-arg --interface\ncurl-arg vpn_1D17_1D170')"

out=$(SHIM_HANDSHAKE_AGE=10 SHIM_BBC_FILE="$FIXTURES/mediaselector_blocked.json" st)
assert_contains "blocked: BBC" "$out" "BBC:         blocked (geolocation)"
assert_contains "blocked: rc 1" "$out" "rc=1"

printf 'fail_count=2\nnext_attempt=1793500000\n' > "$APP_DIR/state"
out=$(SHIM_HANDSHAKE_AGE=never st)
assert_contains "never" "$out" "handshake:   never"
assert_contains "failures line" "$out" "failures:    2 (next attempt "
assert_contains "stale: rc 1" "$out" "rc=1"

out=$(SHIM_IFACE_MISSING=1 st)
assert_contains "interface down" "$out" "handshake:   interface down (client turned off in the app)"
assert_not_contains "no BBC probe when down" "$out" "BBC:"

cp "$FIXTURES"/imported/* "$WG_DIR/"; out=$(st)
assert_contains "two clients" "$out" "client:      more than one PIA client: 1D17_1D170 2C3D_2C3D0"
rm -f "$WG_DIR"/*; out=$(st)
assert_contains "no client" "$out" "client:      none — run install.sh"
assert_contains "no client: rc 1" "$out" "rc=1"

cp "$FIXTURES"/profile/* "$WG_DIR/"; printf '{"addresses":[]}' > "$WG_DIR/1D17_1D170.json"; out=$(st)
assert_contains "unreadable profile" "$out" "client:      cannot read the PIA client profile (1D17_1D170.json)"
assert_contains "unreadable profile: rc 1" "$out" "rc=1"

rm -rf "$T"
echo "PASS $PASS"; (( FAIL == 0 ))
