#!/bin/bash
# shellcheck disable=SC2012,SC2016  # ls only looks at fixed, safe names; the $ is part of a test password
set -u
PASS=0; FAIL=0
T=$(mktemp -d)
export PATH="$SHIM:$PATH" POLL_SECS=0 SETUP_IMPORT_SECS=0 SETUP_HINT_SECS=0 SETUP_IFACE_SECS=0
export FW_HOME="$T/fw" SHIM_STATE="$T/shim" SHIM_LOG="$T/shim/shim.log" SHIM_CRONTAB="$T/shim/crontab"
export APP_DIR="$FW_HOME/config/firewalla-pia-uk" WG_DIR="$FW_HOME/run/wg_profile" USER_CRONTAB="$FW_HOME/config/user_crontab"
export FW_UPDATE_CRONTAB="$SHIM/update_crontab.sh" PIA_SERVERLIST_URL="file://$FIXTURES/serverlist.json"
export REQUIRED_TOOLS="bash curl python3 wg qrencode ip sudo"
export PROMPT_IN="$T/answers"
reset() { rm -rf "$FW_HOME" "$SHIM_STATE"; mkdir -p "$WG_DIR" "$FW_HOME/config" "$SHIM_STATE"; : > "$SHIM_LOG"; }
inst() { "$BASH" "$ROOT/install.sh" 2>&1; echo "rc=$?"; }
cronlines() { if [[ -f $USER_CRONTAB ]]; then grep -c 'firewalla-pia-uk keepalive' "$USER_CRONTAB"; else echo 0; fi; }

reset; cp "$FIXTURES"/profile/* "$WG_DIR/"
printf 'p1234567\n@p;w<"$x ,y\n' > "$PROMPT_IN"
out=$(SHIM_HANDSHAKE_AGE=10 inst)
assert_contains "adopt: rc 0" "$out" "rc=0"
assert_contains "adopt: message" "$out" "Using existing PIA client: PIA UK Streaming (WG) (1D17_1D170)"
assert_eq "credentials saved" "$(cat "$APP_DIR/credentials")" "$(printf 'p1234567\n@p;w<"$x ,y')"
assert_eq "credentials private" "$(ls -l "$APP_DIR/credentials" | cut -c1-10)" "-rw-------"
assert_eq "one cron line" "$(cronlines)" "1"
assert_contains "cron line" "$(cat "$USER_CRONTAB")" "*/5 * * * * flock -n /dev/shm/firewalla-pia-uk.lock timeout 110 $APP_DIR/bin/firewalla-pia-uk keepalive >>$APP_DIR/keepalive.log 2>&1"
assert_contains "crontab installed" "$(cat "$SHIM_CRONTAB")" "firewalla-pia-uk keepalive"
assert_eq "CLI copied" "$(ls -l "$APP_DIR/bin/firewalla-pia-uk" | cut -c4)" "x"
assert_contains "dry run shown" "$out" "DRY RUN"
assert_contains "route rule pointer" "$out" 'Next: make the BBC Route rule. See "Route rule" in the README.'

: > "$PROMPT_IN"; out=$(SHIM_HANDSHAKE_AGE=10 inst)
assert_contains "update: rc 0" "$out" "rc=0"
assert_contains "update: keeps login" "$out" "Using the saved PIA login."
assert_eq "update: login unchanged" "$(sed -n 2p "$APP_DIR/credentials")" '@p;w<"$x ,y'
assert_eq "update: still one cron line" "$(cronlines)" "1"

reset; cp "$FIXTURES"/profile/* "$WG_DIR/"; printf 'p1234567\nwrong\n' > "$PROMPT_IN"
out=$(SHIM_TOKEN_BODY='{}' inst)
assert_contains "bad login: message" "$out" "error: PIA rejected the login. Run install.sh again."
assert_contains "bad login: rc 1" "$out" "rc=1"
assert_eq "bad login: no credentials" "$(ls "$APP_DIR/credentials" 2>/dev/null)" ""
assert_eq "bad login: no cron line" "$(cronlines)" "0"

reset; cp "$FIXTURES"/profile/* "$FIXTURES"/imported/* "$WG_DIR/"; printf 'p1234567\npw\n' > "$PROMPT_IN"
out=$(inst)
assert_contains "two clients: message" "$out" "error: more than one PIA client: 1D17_1D170 2C3D_2C3D0"
assert_eq "two clients: no cron line" "$(cronlines)" "0"

reset; cp "$FIXTURES"/profile/* "$WG_DIR/"; printf 'p1234567\n  pw with spaces  \n' > "$PROMPT_IN"
SHIM_HANDSHAKE_AGE=10 inst >/dev/null
assert_eq "password keeps its spaces" "$(sed -n 2p "$APP_DIR/credentials")" "  pw with spaces  "

reset; cp "$FIXTURES"/profile/* "$WG_DIR/"; printf '{"addresses":[]}' > "$WG_DIR/1D17_1D170.json"
printf 'p1234567\npw\n' > "$PROMPT_IN"; out=$(inst)
assert_contains "unreadable profile: install stops" "$out" "error: cannot read the PIA client profile (1D17_1D170.json)"
assert_eq "unreadable profile: no cron line" "$(cronlines)" "0"

reset; printf 'p1234567\npw\n' > "$PROMPT_IN"
out=$(SHIM_IMPORT_FROM="$FIXTURES/imported" SHIM_HANDSHAKE_AGE=100000 inst)
assert_contains "setup without handshake: explained" "$out" "The client exists, so the installation continues. The keepalive will keep trying to connect it."
assert_contains "setup without handshake: rc 0" "$out" "rc=0"
assert_eq "setup without handshake: cron line" "$(cronlines)" "1"

reset; printf 'p1234567\npw\n' > "$PROMPT_IN"
out=$(SHIM_IMPORT_FROM="$FIXTURES/imported" SHIM_HANDSHAKE_AGE=10 inst)
assert_contains "fresh box: setup runs" "$out" 'Setup complete: "PIA UK Streaming" (2C3D_2C3D0) is connected.'
assert_eq "fresh box: cron line" "$(cronlines)" "1"

out=$(REQUIRED_TOOLS="bash nosuchtool" inst)
assert_contains "missing tool" "$out" "error: missing tool: nosuchtool"

printf 'n\n' > "$PROMPT_IN"; out=$("$BASH" "$APP_DIR/uninstall.sh" 2>&1)
assert_eq "uninstall n: cron line gone" "$(cronlines)" "0"
assert_eq "uninstall n: folder kept" "$(ls -d "$APP_DIR")" "$APP_DIR"
assert_contains "uninstall: reminder" "$out" "Delete the PIA client and the BBC Route rule in the Firewalla app."
printf 'y\n' > "$PROMPT_IN"; "$BASH" "$APP_DIR/uninstall.sh" >/dev/null 2>&1
assert_eq "uninstall y: folder gone" "$(ls -d "$APP_DIR" 2>/dev/null)" ""

rm -rf "$T"
echo "PASS $PASS"; (( FAIL == 0 ))
