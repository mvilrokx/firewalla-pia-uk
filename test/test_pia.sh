#!/bin/bash
set -u
PASS=0; FAIL=0
T=$(mktemp -d)
export PATH="$SHIM:$PATH" APP_DIR="$T" SHIM_LOG="$T/shim.log"
source "$ROOT/lib/common.sh"; source "$ROOT/lib/pia.sh"
F="$FIXTURES/serverlist.json"

assert_eq "endpoint listed" "$(serverlist_resolve "$F" 85.203.46.72 uk_2)" "CURRENT 85.203.46.72 Server-10870-2a"
assert_eq "listed in another region" "$(serverlist_resolve "$F" 212.102.53.10 uk_2)" "CURRENT 212.102.53.10 london401"
assert_eq "retired → first uk_2 server" "$(serverlist_resolve "$F" 85.203.46.180 uk_2)" "RETIRED 85.203.46.72 Server-10870-2a"
serverlist_resolve "$F" 85.203.46.180 uk_manchester >/dev/null 2>&1; assert_eq "region without wg → 2" "$?" 2
serverlist_resolve "$F" 85.203.46.180 nowhere >/dev/null 2>&1; assert_eq "unknown region → 2" "$?" 2
serverlist_resolve "$FIXTURES/serverlist_broken.json" 85.203.46.180 uk_2 >/dev/null 2>&1; assert_eq "HTML → 3" "$?" 3
assert_eq "region_server" "$(region_server "$F" uk_2)" "85.203.46.72 Server-10870-2a"
region_server "$FIXTURES/serverlist_broken.json" uk_2 >/dev/null 2>&1; assert_eq "region_server HTML → 3" "$?" 3

PIA_SERVERLIST_URL="file://$F" fetch_serverlist "$T/sl"
assert_eq "fetch_serverlist copies the list" "$(head -c 10 "$T/sl")" '{"groups":'

# shellcheck disable=SC2016  # the $ is part of the test password, not an expansion
pw='@p;w<"$x ,y'
printf '%s\n%s\n' 'p1234567' "$pw" > "$CREDS_FILE"
: > "$SHIM_LOG"
assert_eq "get_token prints the token" "$(get_token)" "TKN"
assert_contains "token URL" "$(cat "$SHIM_LOG")" "curl-arg $PIA_TOKEN_URL"
assert_contains "username as form-string" "$(cat "$SHIM_LOG")" "$(printf 'curl-arg --form-string\ncurl-arg username=p1234567')"
assert_contains "password reaches curl unchanged" "$(cat "$SHIM_LOG")" "$(printf 'curl-arg --form-string\ncurl-arg password=%s' "$pw")"
SHIM_TOKEN_BODY='{}' get_token >/dev/null; assert_eq "no token → 1" "$?" 1
SHIM_TOKEN_BODY='<html>' get_token >/dev/null 2>&1; assert_eq "non-JSON token answer → 1" "$?" 1

: > "$SHIM_LOG"
body=$(add_key 85.203.46.72 Server-10870-2a CLIENTPUB= TKN)
assert_contains "add_key body" "$body" '"status":"OK"'
log_text=$(cat "$SHIM_LOG")
assert_contains "connect-to" "$log_text" "curl-arg Server-10870-2a::85.203.46.72:"
assert_contains "cacert" "$log_text" "curl-arg $CA_FILE"
assert_contains "addKey URL" "$log_text" "curl-arg https://Server-10870-2a:1337/addKey"
assert_contains "token param" "$log_text" "curl-arg pt=TKN"
assert_contains "pubkey param" "$log_text" "curl-arg pubkey=CLIENTPUB="

assert_eq "parse OK" "$(parse_addkey "$(cat "$FIXTURES/addkey_ok.json")")" "10.186.0.136 NEWSERVERKEY= 10.0.0.243"
parse_addkey "$(cat "$FIXTURES/addkey_error.json")" >/dev/null; assert_eq "parse ERROR → 1" "$?" 1
parse_addkey "<html>" >/dev/null 2>&1; assert_eq "parse non-JSON → 1" "$?" 1

rm -rf "$T"
echo "PASS $PASS"; (( FAIL == 0 ))
