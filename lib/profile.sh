#!/bin/bash
# The Firewalla app keeps each WireGuard client in $WG_DIR/<id>.{conf,json,settings}.
# The .json is the source of truth: the .conf loses its PrivateKey while the
# client is turned off. PIA's WireGuard servers are the only ones on port 1337.

# find_profiles → the ids of all PIA clients, sorted, one per line.
find_profiles() {
  local conf
  for conf in "$WG_DIR"/*.conf; do
    if [[ -f $conf ]] && grep -q ':1337' "$conf"; then basename "$conf" .conf; fi
  done | sort
}

# find_profile → "<id> <endpoint-ip> <server-pub> <address>" of the one PIA client.
# Exit 1: none. Exit 2: more than one. Exit 3: its .json cannot be read.
find_profile() {
  local ids
  ids=$(find_profiles)
  [[ -n $ids ]] || return 1
  (( $(echo "$ids" | wc -l) == 1 )) || return 2
  python3 - "$WG_DIR/$ids.json" "$ids" <<'PY'
import json, sys
path, pid = sys.argv[1:3]
try:
    with open(path) as f:
        j = json.load(f)
    peer = j["peers"][0]
    print(pid, peer["endpoint"].rsplit(":", 1)[0], peer["publicKey"], j["addresses"][0].split("/")[0])
except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError):
    sys.exit(3)
PY
}

# profile_name <id> → the name the user gave the client in the app.
profile_name() {
  python3 - "$WG_DIR/$1.settings" "$1" <<'PY'
import json, sys
path, pid = sys.argv[1:3]
try:
    with open(path) as f:
        print(json.load(f).get("displayName") or pid)
except (OSError, ValueError):
    print(pid)
PY
}

# profile_pubkey <id> → the client public key that belongs to the profile's private key.
profile_pubkey() {
  local priv
  priv=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("privateKey", ""))' "$WG_DIR/$1.json")
  [[ -n $priv ]] || return 1
  printf '%s' "$priv" | wg pubkey
}

# backup_profile <id> → copies the three files to $APP_DIR/backup/<timestamp>/,
# keeps the newest 10 backups, and prints the new directory.
backup_profile() {
  local dir backups excess i
  dir="$APP_DIR/backup/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$dir" && cp "$WG_DIR/$1.conf" "$WG_DIR/$1.json" "$WG_DIR/$1.settings" "$dir/" || return 1
  backups=("$APP_DIR"/backup/*/)
  excess=$(( ${#backups[@]} - 10 ))
  for (( i = 0; i < excess; i++ )); do rm -rf "${backups[$i]}"; done
  echo "$dir"
}

# patch_profile <id> <endpoint-ip> <server-pub> <address>
# Changes only the server key, endpoint, and address, in the same shape that
# Firewalla writes (one-line JSON, no trailing newline), so the app shows the
# new values and Firewalla's own restart reads them. All three files change, or
# none: files that disagree would send the client back to the old server at the
# next Firewalla restart.
patch_profile() {
  python3 - "$WG_DIR" "$@" <<'PY'
import json, os, re, sys
d, pid, ip, pub, addr = sys.argv[1:6]
conf, js, settings = (f"{d}/{pid}.{ext}" for ext in ("conf", "json", "settings"))

for path in (conf, js, settings):
    if not os.access(path, os.W_OK):
        sys.exit(f"cannot write {path}")

with open(conf) as f:
    text = f.read()
text = re.sub(r"^PublicKey = .*$", f"PublicKey = {pub}", text, flags=re.M)
text = re.sub(r"^Endpoint = .*$", f"Endpoint = {ip}:1337", text, flags=re.M)

with open(js, encoding="utf-8") as f:
    j = json.load(f)
j["addresses"] = [f"{addr}/32"]
j["peers"][0]["publicKey"] = pub
j["peers"][0]["endpoint"] = f"{ip}:1337"

with open(settings, encoding="utf-8") as f:
    s = json.load(f)
s["serverDDNS"] = ip

with open(conf, "w") as f:
    f.write(text)
for path, data in ((js, j), (settings, s)):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
PY
}
