#!/bin/bash
# PIA API: the public server list, the login token, and WireGuard key
# registration (addKey). The same flow as PIA's apps and pia-foss/manual-connections.

fetch_serverlist() { curl -sf --max-time 20 "$PIA_SERVERLIST_URL" -o "$1"; }

# serverlist_resolve <file> <endpoint-ip> <region> [<avoid-ip>]
# "CURRENT <ip> <cn>" while the endpoint is still a PIA WireGuard server, else
# "RETIRED <ip> <cn>" naming the region's first one. <avoid-ip> did not answer
# last time: when it is the endpoint, "AVOIDED <ip> <cn>" names the region's
# first other server. Exit 2: the region has no WireGuard servers. Exit 3: the
# file is not PIA's JSON.
serverlist_resolve() {
  python3 - "$1" "$2" "$3" "${4:-}" <<'PY'
import ipaddress, json, re, sys
path, endpoint, region, avoid = sys.argv[1:5]

# ip and cn go into curl's arguments: only an IPv4 address and a host name.
def valid(s):
    try:
        ipaddress.IPv4Address(s["ip"])
    except (TypeError, KeyError, ValueError):
        return False
    return (isinstance(s["ip"], str) and isinstance(s.get("cn"), str)
            and re.fullmatch(r"[A-Za-z0-9.-]+", s["cn"]) is not None)

try:
    with open(path) as f:
        # The JSON is followed by a signature.
        data, _ = json.JSONDecoder().raw_decode(f.read().lstrip())
    regions = [(r["id"], [s for s in r.get("servers", {}).get("wg", []) if valid(s)])
               for r in data["regions"]]
except (ValueError, KeyError, TypeError, AttributeError):
    sys.exit(3)
avoided = avoid != "" and endpoint == avoid
if not avoided:
    for _, wg in regions:
        for s in wg:
            if s["ip"] == endpoint:
                print("CURRENT", s["ip"], s["cn"])
                sys.exit(0)
for rid, wg in regions:
    if rid == region and wg:
        s = ([s for s in wg if s["ip"] != avoid] or wg)[0]
        print("AVOIDED" if avoided else "RETIRED", s["ip"], s["cn"])
        sys.exit(0)
sys.exit(2)
PY
}

# region_server <file> <region> → "<ip> <cn>" of the region's first WireGuard server.
region_server() {
  local out rc
  out=$(serverlist_resolve "$1" "" "$2"); rc=$?
  (( rc == 0 )) || return "$rc"
  echo "${out#* }"
}

# cfg_quote <value> → the value escaped for a "quoted" string in a curl config.
cfg_quote() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# get_token → PIA's token. Exit 1: PIA rejected the login (HTTP 401 or 403).
# Exit 2: no answer (network). Exit 3: any other answer, such as an outage or a
# rate limit; prints the HTTP status. The login goes to curl on stdin (-K -),
# because any local user can read a command line. form-string, not form: with
# form, a password that starts with @ or < would be read as a file name.
get_token() {
  local user pass out code token
  user=$(sed -n 1p "$CREDS_FILE")
  pass=$(sed -n 2p "$CREDS_FILE")
  out=$(printf 'form-string = "username=%s"\nform-string = "password=%s"\n' \
          "$(cfg_quote "$user")" "$(cfg_quote "$pass")" \
        | curl -sS --max-time 20 -X POST "$PIA_TOKEN_URL" -K - -w '\n%{http_code}') || return 2
  code=${out##*$'\n'}
  case $code in 401|403) return 1 ;; esac
  token=$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("token", ""))' <<< "${out%$'\n'*}" 2>/dev/null)
  if [[ $code != 200 || -z $token ]]; then echo "$code"; return 3; fi
  echo "$token"
}

# add_key <server-ip> <server-cn> <client-pub> <token>
# Connects to the server by IP but checks its certificate against the CN. The
# token goes on stdin, like the login.
add_key() {
  local ip=$1 cn=$2 pub=$3 token=$4
  printf 'data-urlencode = "pt=%s"\n' "$(cfg_quote "$token")" \
    | curl -sS -G --max-time 20 --connect-to "$cn::$ip:" --cacert "$CA_FILE" -K - \
        --data-urlencode "pubkey=$pub" "https://$cn:1337/addKey"
}

# parse_addkey <json> → "<peer_ip> <server_key> <first dns server>" when PIA said
# OK and the values look right: they go into the client's profile files.
parse_addkey() {
  python3 - "$1" <<'PY'
import ipaddress, json, re, sys

def ipv4(value):
    try:
        ipaddress.IPv4Address(value)
        return True
    except ValueError:
        return False

try:
    r = json.loads(sys.argv[1])
    dns = (r.get("dns_servers") or [""])[0]
    ok = (r.get("status") == "OK"
          and isinstance(r.get("peer_ip"), str) and ipv4(r["peer_ip"])
          and re.fullmatch(r"[A-Za-z0-9+/]{43}=", str(r.get("server_key", ""))) is not None
          and (dns == "" or (isinstance(dns, str) and ipv4(dns))))
except (ValueError, AttributeError):
    ok = False
if not ok:
    sys.exit(1)
print(r["peer_ip"], r["server_key"], dns)
PY
}
