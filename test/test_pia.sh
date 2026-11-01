#!/bin/bash
# shellcheck disable=SC2016  # $ inside single quotes is part of the test password
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

assert_eq "avoided endpoint → the region's next server" "$(serverlist_resolve "$F" 85.203.46.72 uk_2 85.203.46.72)" "AVOIDED 85.203.46.73 Server-10871-2a"
assert_eq "retired, first server avoided → the next one" "$(serverlist_resolve "$F" 85.203.46.180 uk_2 85.203.46.72)" "RETIRED 85.203.46.73 Server-10871-2a"
assert_eq "avoided, no other server → the same one" "$(serverlist_resolve "$F" 212.102.53.10 uk_london 212.102.53.10)" "AVOIDED 212.102.53.10 london401"
assert_eq "avoid another server → endpoint still current" "$(serverlist_resolve "$F" 85.203.46.72 uk_2 85.203.46.73)" "CURRENT 85.203.46.72 Server-10870-2a"

{ python3 -c 'import json, sys; print(json.dumps(json.loads(open(sys.argv[1]).readline()), indent=2))' "$F"; echo 'c2lnbmF0dXJl'; } > "$T/pretty.json"
assert_eq "list over more than one line" "$(serverlist_resolve "$T/pretty.json" 85.203.46.180 uk_2)" "RETIRED 85.203.46.72 Server-10870-2a"
printf '%s\n' '{"regions":[{"id":"uk_2","servers":{"wg":[{"ip":null,"cn":"a"},{"ip":"1.2.3.4","cn":"b c"},"x",{"ip":"85.203.46.73","cn":"Server-10871-2a"}]}}]}' > "$T/odd.json"
assert_eq "bad server entries are skipped" "$(serverlist_resolve "$T/odd.json" 9.9.9.9 uk_2)" "RETIRED 85.203.46.73 Server-10871-2a"
printf '%s\n' '{"regions":[{"id":"uk_2","servers":{"wg":[{"ip":"1.2.3.4","cn":"a/b"}]}}]}' > "$T/badcn.json"
serverlist_resolve "$T/badcn.json" 9.9.9.9 uk_2 >/dev/null 2>&1; assert_eq "no valid server in the region → 2" "$?" 2
printf '%s\n' '{"regions":"none"}' > "$T/shape.json"
out=$(serverlist_resolve "$T/shape.json" 9.9.9.9 uk_2 2>&1); assert_eq "wrong shape → 3, no traceback" "$?|$out" "3|"

PIA_SERVERLIST_URL="file://$F" fetch_serverlist "$T/sl"
assert_eq "fetch_serverlist copies the list" "$(head -c 10 "$T/sl")" '{"groups":'

pw='@p;w<"$x ,y\z'
printf '%s\n%s\n' 'p1234567' "$pw" > "$CREDS_FILE"
: > "$SHIM_LOG"
assert_eq "get_token prints the token" "$(get_token)" "TKN"
assert_contains "token URL" "$(cat "$SHIM_LOG")" "curl-arg $PIA_TOKEN_URL"
assert_contains "login read from stdin" "$(cat "$SHIM_LOG")" "$(printf 'curl-arg -K\ncurl-arg -')"
assert_not_contains "password not in curl's arguments" "$(grep '^curl-arg' "$SHIM_LOG")" 'p;w<'
assert_contains "username in curl's config" "$(cat "$SHIM_LOG")" 'curl-config form-string = "username=p1234567"'
assert_contains "password in curl's config, escaped" "$(cat "$SHIM_LOG")" 'curl-config form-string = "password=@p;w<\"$x ,y\\z"'
assert_contains "token: asks curl for the HTTP status" "$(cat "$SHIM_LOG")" "$(printf 'curl-arg -w\ncurl-arg \\n%%{http_code}')"
SHIM_HTTP_CODE=401 SHIM_TOKEN_BODY='HTTP Token: Access denied.' get_token >/dev/null; assert_eq "wrong login (401) → 1" "$?" 1
SHIM_HTTP_CODE=403 SHIM_TOKEN_BODY='{}' get_token >/dev/null; assert_eq "403 → 1" "$?" 1
out=$(SHIM_HTTP_CODE=503 SHIM_TOKEN_BODY='<html>503 Service Unavailable</html>' get_token); rc=$?
assert_eq "outage (503) → 3 and the status" "$rc|$out" "3|503"
out=$(SHIM_HTTP_CODE=429 SHIM_TOKEN_BODY='{"message":"rate limited"}' get_token); rc=$?
assert_eq "rate limit (429) → 3 and the status" "$rc|$out" "3|429"
out=$(SHIM_TOKEN_BODY='{}' get_token); rc=$?
assert_eq "200 without a token → 3" "$rc|$out" "3|200"
SHIM_CURL_FAIL_URL=token get_token >/dev/null 2>&1; assert_eq "no answer from PIA → 2" "$?" 2

: > "$SHIM_LOG"
body=$(add_key 85.203.46.72 Server-10870-2a CLIENTPUB= TKN)
assert_contains "add_key body" "$body" '"status":"OK"'
log_text=$(cat "$SHIM_LOG")
assert_contains "connect-to" "$log_text" "curl-arg Server-10870-2a::85.203.46.72:"
assert_contains "cacert" "$log_text" "curl-arg $CA_FILE"
assert_contains "addKey URL" "$log_text" "curl-arg https://Server-10870-2a:1337/addKey"
assert_contains "pubkey param" "$log_text" "curl-arg pubkey=CLIENTPUB="
assert_contains "curl shows its errors" "$log_text" "curl-arg -sS"
assert_not_contains "token not in curl's arguments" "$(grep '^curl-arg' "$SHIM_LOG")" "pt=TKN"
assert_contains "token in curl's config" "$log_text" 'curl-config data-urlencode = "pt=TKN"'
SHIM_CURL_FAIL_URL=addKey add_key 85.203.46.72 Server-10870-2a CLIENTPUB= TKN 2>"$T/err" >/dev/null
assert_eq "addKey: curl failure → curl's code" "$?" 28
assert_contains "addKey: curl says why" "$(cat "$T/err")" "curl: (28)"

assert_eq "parse OK" "$(parse_addkey "$(cat "$FIXTURES/addkey_ok.json")")" "10.186.0.136 NEWSERVERKEY0000000000000000000000000000000= 10.0.0.243"
parse_addkey "$(cat "$FIXTURES/addkey_error.json")" >/dev/null; assert_eq "parse ERROR → 1" "$?" 1
parse_addkey "<html>" >/dev/null 2>&1; assert_eq "parse non-JSON → 1" "$?" 1
K=NEWSERVERKEY0000000000000000000000000000000=
parse_addkey '{"status":"OK","peer_ip":"10.186.0.136","server_key":"short=","dns_servers":["10.0.0.243"]}' >/dev/null
assert_eq "parse: bad server key → 1" "$?" 1
parse_addkey "{\"status\":\"OK\",\"peer_ip\":\"10.186.0.999\",\"server_key\":\"$K\",\"dns_servers\":[\"10.0.0.243\"]}" >/dev/null
assert_eq "parse: bad address → 1" "$?" 1
parse_addkey "{\"status\":\"OK\",\"peer_ip\":\"10.186.0.136\",\"server_key\":\"$K\",\"dns_servers\":[\"x; rm\"]}" >/dev/null
assert_eq "parse: bad dns → 1" "$?" 1

rm -rf "$T"
echo "PASS $PASS"; (( FAIL == 0 ))
