#!/bin/bash
set -u
PASS=0; FAIL=0
export PATH="$SHIM:$PATH" POLL_SECS=0 SHIM_STATE; SHIM_STATE=$(mktemp -d)
export SHIM_LOG="$SHIM_STATE/shim.log"
source "$ROOT/lib/common.sh"; source "$ROOT/lib/wg.sh"
now=$(date +%s)

assert_between "42 s old" "$(handshake_age "$(printf 'PUB\t%s' $((now - 42)))")" 42 44
assert_between "newest of two peers" "$(handshake_age "$(printf 'A\t%s\nB\t%s' $((now - 500)) $((now - 7)))")" 7 9
assert_eq "timestamp 0 = never" "$(handshake_age "$(printf 'PUB\t0')")" 999999999
assert_eq "empty = never" "$(handshake_age "")" 999999999

interface_exists vpn_X; assert_eq "interface present" "$?" 0
SHIM_IFACE_MISSING=1 interface_exists vpn_X; assert_eq "interface missing" "$?" 1
assert_eq "client pubkey" "$(client_pubkey vpn_X)" "CLIENTPUB="

: > "$SHIM_LOG"
apply_live vpn_X OLDPUB NEWPUB 85.203.46.72 10.1.1.1 10.2.2.2
assert_eq "apply_live: changed key and address" "$(cat "$SHIM_LOG")" "$(printf '%s\n' \
  'wg set vpn_X peer OLDPUB remove' \
  'wg set vpn_X peer NEWPUB endpoint 85.203.46.72:1337 allowed-ips 0.0.0.0/0 persistent-keepalive 25' \
  'ip addr add 10.2.2.2/32 dev vpn_X' \
  'ip addr del 10.1.1.1/32 dev vpn_X')"
: > "$SHIM_LOG"
apply_live vpn_X SAME SAME 85.203.46.72 10.1.1.1 10.1.1.1
assert_eq "apply_live: unchanged → one wg set" "$(cat "$SHIM_LOG")" \
  "wg set vpn_X peer SAME endpoint 85.203.46.72:1337 allowed-ips 0.0.0.0/0 persistent-keepalive 25"
SHIM_WG_SET_RC=1 apply_live vpn_X SAME SAME 1.2.3.4 10.1.1.1 10.1.1.1; assert_eq "apply_live: wg set fails" "$?" 1

rm -f "$SHIM_STATE/fresh"
SHIM_HANDSHAKE_AGE=10 wait_handshake vpn_X; assert_eq "wait_handshake: fresh" "$?" 0
SHIM_HANDSHAKE_AGE=100000 wait_handshake vpn_X; assert_eq "wait_handshake: stale" "$?" 1

rm -rf "$SHIM_STATE"
echo "PASS $PASS"; (( FAIL == 0 ))
