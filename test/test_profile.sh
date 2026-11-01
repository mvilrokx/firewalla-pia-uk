#!/bin/bash
# shellcheck disable=SC2012  # ls only counts files with fixed, safe names here
set -u
PASS=0; FAIL=0
T=$(mktemp -d)
export PATH="$SHIM:$PATH" APP_DIR="$T/app" WG_DIR="$T/wg"
mkdir -p "$APP_DIR" "$WG_DIR"
cp "$FIXTURES"/profile/* "$WG_DIR/"
printf '[Interface]\nPrivateKey = x\n[Peer]\nPublicKey = y\nEndpoint = 1.2.3.4:51820' > "$WG_DIR/AAAA_AAAA0.conf"   # not PIA
source "$ROOT/lib/common.sh"; source "$ROOT/lib/profile.sh"

assert_eq "find_profiles ignores non-PIA" "$(find_profiles)" "1D17_1D170"
assert_eq "find_profile reads the json" "$(find_profile)" "1D17_1D170 85.203.46.180 OLDSERVERKEY= 10.65.10.126"
assert_eq "profile_name" "$(profile_name 1D17_1D170)" "PIA UK Streaming (WG)"
assert_eq "profile_pubkey" "$(profile_pubkey 1D17_1D170)" "PUBOF:FAKEPRIVATEKEY="

mkdir -p "$APP_DIR/backup"
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do mkdir "$APP_DIR/backup/20200101_0000$i"; done
bdir=$(backup_profile 1D17_1D170)
assert_eq "backup has three files" "$(ls "$bdir" | wc -l | tr -d ' ')" "3"
assert_eq "keeps newest 10 backups" "$(ls "$APP_DIR/backup" | wc -l | tr -d ' ')" "10"
assert_eq "new backup kept" "$(ls "$APP_DIR/backup" | tail -1)" "$(basename "$bdir")"

patch_profile 1D17_1D170 85.203.46.72 NEWSERVERKEY= 10.186.0.136
assert_eq "conf: only key and endpoint change" "$(cat "$WG_DIR/1D17_1D170.conf"; echo '|')" \
  "$(printf '[Interface]\nPrivateKey = FAKEPRIVATEKEY=\n[Peer]\nPersistentKeepalive = 25\nPublicKey = NEWSERVERKEY=\nEndpoint = 85.203.46.72:1337\nAllowedIPs = 0.0.0.0/0|')"
assert_eq "json" "$(cat "$WG_DIR/1D17_1D170.json")" \
  '{"addresses":["10.186.0.136/32"],"dns":["10.0.0.243"],"peers":[{"persistentKeepalive":"25","publicKey":"NEWSERVERKEY=","endpoint":"85.203.46.72:1337","allowedIPs":["0.0.0.0/0"]}],"privateKey":"FAKEPRIVATEKEY="}'
assert_eq "settings: only serverDDNS changes" "$(cat "$WG_DIR/1D17_1D170.settings")" \
  "$(sed 's/"serverDDNS":"85.203.46.180"/"serverDDNS":"85.203.46.72"/' "$FIXTURES/profile/1D17_1D170.settings")"
assert_eq "find_profile sees the patch" "$(find_profile)" "1D17_1D170 85.203.46.72 NEWSERVERKEY= 10.186.0.136"

cp "$FIXTURES"/imported/* "$WG_DIR/"
assert_eq "two PIA clients listed" "$(find_profiles | tr '\n' ' ')" "1D17_1D170 2C3D_2C3D0 "
find_profile >/dev/null 2>&1; assert_eq "two PIA clients → 2" "$?" 2

rm -f "$WG_DIR"/1D17_1D170.* "$WG_DIR"/2C3D_2C3D0.*
find_profile >/dev/null 2>&1; assert_eq "no PIA client → 1" "$?" 1

rm -rf "$T"
echo "PASS $PASS"; (( FAIL == 0 ))
