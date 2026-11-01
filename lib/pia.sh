#!/bin/bash
# PIA API: the public server list, the login token, and WireGuard key
# registration (addKey). The same flow as PIA's apps and pia-foss/manual-connections.

fetch_serverlist() { curl -sf --max-time 20 "$PIA_SERVERLIST_URL" -o "$1"; }

# serverlist_resolve <file> <endpoint-ip> <region>
# "CURRENT <ip> <cn>" while the endpoint is still a PIA WireGuard server, else
# "RETIRED <ip> <cn>" naming the region's first one. Exit 2: the region has no
# WireGuard servers. Exit 3: the file is not PIA's JSON.
serverlist_resolve() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, endpoint, region = sys.argv[1:4]
try:
    with open(path) as f:
        regions = json.loads(f.readline())["regions"]  # line 1 = JSON, line 2 = signature
except (ValueError, KeyError, TypeError):
    sys.exit(3)
for r in regions:
    for s in r.get("servers", {}).get("wg", []):
        if s["ip"] == endpoint:
            print("CURRENT", s["ip"], s["cn"])
            sys.exit(0)
for r in regions:
    if r["id"] == region and r.get("servers", {}).get("wg"):
        s = r["servers"]["wg"][0]
        print("RETIRED", s["ip"], s["cn"])
        sys.exit(0)
sys.exit(2)
PY
}

# region_server <file> <region> → "<ip> <cn>" of the region's first WireGuard server.
region_server() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, region = sys.argv[1:3]
try:
    with open(path) as f:
        regions = json.loads(f.readline())["regions"]
except (ValueError, KeyError, TypeError):
    sys.exit(3)
for r in regions:
    if r["id"] == region and r.get("servers", {}).get("wg"):
        s = r["servers"]["wg"][0]
        print(s["ip"], s["cn"])
        sys.exit(0)
sys.exit(2)
PY
}

# --form-string, not --form: with --form a password that starts with @ or <
# would be read as a file name, and ";type=" would become a header.
get_token() {
  local user pass token
  user=$(sed -n 1p "$CREDS_FILE")
  pass=$(sed -n 2p "$CREDS_FILE")
  token=$(curl -s --max-time 20 -X POST "$PIA_TOKEN_URL" \
            --form-string "username=$user" --form-string "password=$pass" \
          | python3 -c 'import json, sys; print(json.load(sys.stdin).get("token", ""))' 2>/dev/null)
  [[ -n $token ]] || return 1
  echo "$token"
}

# add_key <server-ip> <server-cn> <client-pub> <token>
# Connects to the server by IP but checks its certificate against the CN.
add_key() {
  local ip=$1 cn=$2 pub=$3 token=$4
  curl -sG --max-time 20 --connect-to "$cn::$ip:" --cacert "$CA_FILE" \
    --data-urlencode "pt=$token" --data-urlencode "pubkey=$pub" "https://$cn:1337/addKey"
}

# parse_addkey <json> → "<peer_ip> <server_key> <first dns server>" when PIA said OK.
parse_addkey() {
  python3 - "$1" <<'PY'
import json, sys
try:
    r = json.loads(sys.argv[1])
    ok = r.get("status") == "OK" and r.get("peer_ip") and r.get("server_key")
except (ValueError, AttributeError):
    ok = False
if not ok:
    sys.exit(1)
print(r["peer_ip"], r["server_key"], (r.get("dns_servers") or [""])[0])
PY
}
