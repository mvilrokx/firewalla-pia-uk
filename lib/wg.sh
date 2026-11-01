#!/bin/bash
# WireGuard helpers. Only `wg` and `ip` run with sudo.

# handshake_age "<output of: wg show IFACE latest-handshakes>"
# Seconds since the newest handshake of any peer; 999999999 when there is none.
handshake_age() {
  local newest=0 _peer ts
  while IFS=$'\t' read -r _peer ts; do
    if [[ -n ${ts:-} ]] && (( ts > newest )); then newest=$ts; fi
  done <<< "$1"
  if (( newest == 0 )); then echo 999999999; else echo $(( $(date +%s) - newest )); fi
}

# `ip link show` needs no sudo, so a broken sudo or wg shows up as a loud
# failure later, not as "the client is turned off".
interface_exists() { ip link show "$1" > /dev/null 2>&1; }

client_pubkey() { sudo wg show "$1" public-key 2>/dev/null; }

# apply_live <iface> <old-server-pub> <new-server-pub> <endpoint-ip> <old-addr> <new-addr>
# Routing on Firewalla is interface-based, so the peer and the address are all
# that must change. The peer is removed also when its key stays the same: the
# new peer makes a new handshake, which proves that the change works.
apply_live() {
  local iface=$1 old_pub=$2 new_pub=$3 ip=$4 old_addr=$5 new_addr=$6
  sudo wg set "$iface" peer "$old_pub" remove
  sudo wg set "$iface" peer "$new_pub" endpoint "$ip:1337" allowed-ips 0.0.0.0/0 persistent-keepalive 25 || return 1
  if [[ $old_addr != "$new_addr" ]]; then
    # Keep the old address unless the new one is in place.
    sudo ip addr add "$new_addr/32" dev "$iface" || return 1
    # This fails only when the old address is not there.
    sudo ip addr del "$old_addr/32" dev "$iface" || true
  fi
}

# wait_handshake <iface> [<since>] — up to 6 polls for a handshake younger than
# 60 s and, with <since> (epoch seconds), not older than that moment.
wait_handshake() {
  local since=${2:-0} _i age
  for _i in 1 2 3 4 5 6; do
    sleep "$POLL_SECS"
    age=$(handshake_age "$(sudo wg show "$1" latest-handshakes 2>/dev/null)")
    if (( age < 60 && $(date +%s) - age >= since )); then return 0; fi
  done
  return 1
}
