#!/bin/bash
# The setup command: registers a new WireGuard key with PIA's UK streaming
# server and shows the client config as a QR code. Only the Firewalla app can
# add a VPN client, so the user scans the code with the app.

# make_conf <private-key> <address> <dns> <server-pub> <endpoint-ip>
make_conf() {
  printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\nDNS = %s\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:1337\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' "$@"
}

# wait_for_import <client-pub> <timeout-secs> → the id of the PIA client whose
# private key belongs to <client-pub>. A timeout of 0 checks one time.
wait_for_import() {
  local pub=$1 timeout=$2 start id
  start=$(date +%s)
  while true; do
    for id in $(find_profiles); do
      if [[ $(profile_pubkey "$id" 2>/dev/null) == "$pub" ]]; then echo "$id"; return 0; fi
    done
    if (( $(date +%s) - start >= timeout )); then return 1; fi
    sleep "$POLL_SECS"
  done
}

# wait_for_interface <id> <hint-secs> <timeout-secs>
# Nobody knows yet whether a client added in the app starts by itself, so after
# <hint-secs> the user is told to turn it on.
wait_for_interface() {
  local id=$1 hint=$2 timeout=$3 start waited hinted=0
  start=$(date +%s)
  until interface_exists "vpn_$id"; do
    waited=$(( $(date +%s) - start ))
    if (( waited >= hint && hinted == 0 )); then
      echo "Turn on \"$(profile_name "$id")\" in the Firewalla app (VPN Client), then wait here."
      hinted=1
    fi
    if (( waited >= timeout )); then return 1; fi
    sleep "$POLL_SECS"
  done
}

cmd_setup() {
  local priv pub list server rc server_ip server_cn token body parsed addr server_key dns conf id
  priv=$(wg genkey)
  pub=$(printf '%s' "$priv" | wg pubkey)

  list=$(mktemp)
  fetch_serverlist "$list" && server=$(region_server "$list" "$PIA_REGION"); rc=$?
  rm -f "$list"
  (( rc == 0 )) || die "cannot read PIA's server list"
  read -r server_ip server_cn <<< "$server"

  token=$(get_token) || die "PIA login failed"
  body=$(add_key "$server_ip" "$server_cn" "$pub" "$token")
  parsed=$(parse_addkey "$body") \
    || die "PIA did not register the key: $(printf '%s' "$body" | tr '\n' ' ' | cut -c1-200)"
  read -r addr server_key dns <<< "$parsed"

  conf="$APP_DIR/pia-uk.conf"
  (umask 077; make_conf "$priv" "$addr" "$dns" "$server_key" "$server_ip" > "$conf")
  qrencode -t ansiutf8 < "$conf"
  echo 'In the Firewalla app: VPN Client → add → WireGuard → Scan QR Code. Name it "PIA UK Streaming" and save.'
  echo "Or use Import Profile with $conf. Waiting for the new client…"

  id=$(wait_for_import "$pub" "${SETUP_IMPORT_SECS:-900}") \
    || die "no new client after 15 min. Import $conf, then run install.sh again"
  wait_for_interface "$id" "${SETUP_HINT_SECS:-60}" "${SETUP_IFACE_SECS:-600}" \
    || die "the client is still off. Turn it on in the app, then run install.sh again"
  wait_handshake "vpn_$id" || die "no handshake from PIA yet. Run 'firewalla-pia-uk status' in a few minutes"
  rm -f "$conf"
  echo "Setup complete: \"$(profile_name "$id")\" ($id) is connected."
}
