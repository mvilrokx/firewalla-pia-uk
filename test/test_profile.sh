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
mkdir "$T/shapes"
printf '[Interface]\nAddress = fd00::1337/128\n[Peer]\nEndpoint = 1.2.3.4:51820\n' > "$T/shapes/V6V6_V6V60.conf"
printf '[Peer]\nEndpoint = 1.2.3.4:13370\n' > "$T/shapes/PORT_PORT0.conf"
printf '[Peer]\nPublicKey=y\nEndpoint=5.6.7.8:1337\n' > "$T/shapes/TIGH_TIGH0.conf"
assert_eq "find_profiles: only an IPv4 endpoint on port 1337" "$(WG_DIR="$T/shapes" find_profiles)" "TIGH_TIGH0"

find_profile >/dev/null 2>&1; assert_eq "no client chosen → 1" "$?" 1
echo 1D17_1D170 > "$CLIENT_FILE"
assert_eq "client_id" "$(client_id)" "1D17_1D170"
assert_eq "find_profile reads the chosen client" "$(find_profile)" "1D17_1D170 85.203.46.180 OLDSERVERKEY= 10.65.10.126"
assert_eq "read_profile" "$(read_profile 1D17_1D170)" "1D17_1D170 85.203.46.180 OLDSERVERKEY= 10.65.10.126"
assert_eq "profile_name" "$(profile_name 1D17_1D170)" "PIA UK Streaming (WG)"
assert_eq "profile_pubkey" "$(profile_pubkey 1D17_1D170)" "PUBOF:FAKEPRIVATEKEY="

mkdir -p "$APP_DIR/backup"
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do mkdir "$APP_DIR/backup/20200101_0000$i"; done
bdir=$(backup_profile 1D17_1D170)
assert_eq "backup has three files" "$(ls "$bdir" | wc -l | tr -d ' ')" "3"
assert_eq "keeps newest 10 backups" "$(ls "$APP_DIR/backup" | wc -l | tr -d ' ')" "10"
assert_eq "new backup kept" "$(ls "$APP_DIR/backup" | tail -1)" "$(basename "$bdir")"

chmod 640 "$WG_DIR/1D17_1D170.json"
inode_before=$(ls -i "$WG_DIR/1D17_1D170.json" | awk '{ print $1 }')
patch_profile 1D17_1D170 85.203.46.72 NEWSERVERKEY0000000000000000000000000000000= 10.186.0.136
assert_eq "conf: only key and endpoint change" "$(cat "$WG_DIR/1D17_1D170.conf"; echo '|')" \
  "$(printf '[Interface]\nPrivateKey = FAKEPRIVATEKEY=\n[Peer]\nPersistentKeepalive = 25\nPublicKey = NEWSERVERKEY0000000000000000000000000000000=\nEndpoint = 85.203.46.72:1337\nAllowedIPs = 0.0.0.0/0|')"
assert_eq "json" "$(cat "$WG_DIR/1D17_1D170.json")" \
  '{"addresses":["10.186.0.136/32"],"dns":["10.0.0.243"],"peers":[{"persistentKeepalive":"25","publicKey":"NEWSERVERKEY0000000000000000000000000000000=","endpoint":"85.203.46.72:1337","allowedIPs":["0.0.0.0/0"]}],"privateKey":"FAKEPRIVATEKEY="}'
assert_eq "settings: only serverDDNS changes" "$(cat "$WG_DIR/1D17_1D170.settings")" \
  "$(sed 's/"serverDDNS":"85.203.46.180"/"serverDDNS":"85.203.46.72"/' "$FIXTURES/profile/1D17_1D170.settings")"
assert_eq "find_profile sees the patch" "$(find_profile)" "1D17_1D170 85.203.46.72 NEWSERVERKEY0000000000000000000000000000000= 10.186.0.136"
inode_after=$(ls -i "$WG_DIR/1D17_1D170.json" | awk '{ print $1 }')
assert_eq "json replaced in one step (a new file renamed over it)" "$(( inode_after != inode_before ))" "1"
assert_eq "json keeps its mode" "$(ls -l "$WG_DIR/1D17_1D170.json" | cut -c1-10)" "-rw-r-----"
assert_eq "no temporary files left" "$(find "$WG_DIR" -name '*.tmp' | wc -l | tr -d ' ')" "0"

cp "$FIXTURES"/imported/* "$WG_DIR/"
assert_eq "two PIA clients listed" "$(find_profiles | tr '\n' ' ')" "1D17_1D170 2C3D_2C3D0 "
assert_eq "two PIA clients: find_profile takes the chosen one" "$(find_profile | cut -d' ' -f1)" "1D17_1D170"

rm -f "$WG_DIR"/1D17_1D170.*
find_profile >/dev/null 2>&1; assert_eq "chosen client gone → 2" "$?" 2

cp "$FIXTURES"/profile/* "$WG_DIR/"
printf '{"addresses":["10.65.10.126/32"]}' > "$WG_DIR/1D17_1D170.json"
find_profile >/dev/null 2>&1; assert_eq "unreadable json → 3" "$?" 3

cp "$FIXTURES"/profile/* "$WG_DIR/"
printf '[Interface]\nPrivateKey=FAKEPRIVATEKEY=\n[Peer]\nPublicKey=OLDSERVERKEY=\nEndpoint=85.203.46.180:1337\n' > "$WG_DIR/1D17_1D170.conf"
patch_profile 1D17_1D170 85.203.46.72 NEWSERVERKEY0000000000000000000000000000000= 10.186.0.136
assert_eq "conf without spaces: patched" "$(cat "$WG_DIR/1D17_1D170.conf")" \
  "$(printf '[Interface]\nPrivateKey=FAKEPRIVATEKEY=\n[Peer]\nPublicKey = NEWSERVERKEY0000000000000000000000000000000=\nEndpoint = 85.203.46.72:1337')"

cp "$FIXTURES"/profile/* "$WG_DIR/"
printf '[Interface]\nPrivateKey = FAKEPRIVATEKEY=\n[Peer]\nPublicKey = OLDSERVERKEY=\n' > "$WG_DIR/1D17_1D170.conf"
patch_profile 1D17_1D170 85.203.46.72 NEWSERVERKEY0000000000000000000000000000000= 10.186.0.136 2>/dev/null
assert_eq "conf without Endpoint → patch fails" "$?" 1
assert_eq "conf without Endpoint → json unchanged" "$(cat "$WG_DIR/1D17_1D170.json")" "$(cat "$FIXTURES/profile/1D17_1D170.json")"

cp "$FIXTURES"/profile/* "$WG_DIR/"
chmod 444 "$WG_DIR/1D17_1D170.settings"
patch_profile 1D17_1D170 85.203.46.72 NEWSERVERKEY0000000000000000000000000000000= 10.186.0.136 2>/dev/null
assert_eq "read-only file → patch fails" "$?" 1
assert_eq "read-only file → json unchanged" "$(cat "$WG_DIR/1D17_1D170.json")" "$(cat "$FIXTURES/profile/1D17_1D170.json")"
assert_eq "read-only file → conf unchanged" "$(cat "$WG_DIR/1D17_1D170.conf")" "$(cat "$FIXTURES/profile/1D17_1D170.conf")"
chmod 644 "$WG_DIR/1D17_1D170.settings"

chmod 555 "$WG_DIR"
patch_profile 1D17_1D170 85.203.46.72 NEWSERVERKEY0000000000000000000000000000000= 10.186.0.136 2>/dev/null
assert_eq "read-only folder → patch fails" "$?" 1
assert_eq "read-only folder → json unchanged" "$(cat "$WG_DIR/1D17_1D170.json")" "$(cat "$FIXTURES/profile/1D17_1D170.json")"
chmod 755 "$WG_DIR"

rm -rf "$APP_DIR/backup"; mkdir "$APP_DIR/backup"; chmod 555 "$APP_DIR/backup"
backup_profile 1D17_1D170 >/dev/null 2>&1; assert_eq "backup fails when it cannot write" "$?" 1
chmod 755 "$APP_DIR/backup"

rm -rf "$T"
echo "PASS $PASS"; (( FAIL == 0 ))
