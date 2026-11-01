#!/bin/bash
# The keepalive: cron runs it every 5 minutes. While the handshake is fresh it
# does nothing. When PIA has forgotten the key or retired the server, it
# registers the key again (on the region's current server if needed), patches
# the client's profile files, and applies the change to the live interface.

# fail <msg> — record the failure, schedule the next attempt, exit 1.
fail() {
  local n delay
  n=$(state_get fail_count); n=$(( ${n:-0} + 1 ))
  delay=$(next_delay "$n")
  state_set fail_count "$n"
  state_set next_attempt $(( $(date +%s) + delay ))
  log "FAIL($n): $* — next attempt in $(( delay / 60 )) min"
  exit 1
}

cmd_keepalive() {
  local dry=0 force=0 arg
  for arg in "$@"; do
    case $arg in
      --dry-run) dry=1 ;;
      --force) force=1 ;;
      *) echo "unknown flag: $arg" >&2; exit 64 ;;
    esac
  done
  rotate_log

  local profile rc id ep server_pub addr
  profile=$(find_profile); rc=$?
  if (( rc == 1 )); then
    # Logged once, not every 5 minutes, until a client appears.
    if [[ $(state_get no_client) != 1 ]]; then
      log "no PIA WireGuard client (port 1337) found"
      state_set no_client 1
    fi
    exit 0
  fi
  if (( rc == 2 )); then
    log "more than one PIA client: $(find_profiles | paste -sd ' ' -) — remove the extra ones in the Firewalla app"
    exit 1
  fi
  read -r id ep server_pub addr <<< "$profile"
  if [[ $(state_get no_client) == 1 ]]; then state_set no_client 0; fi

  # No interface: the user turned the client off in the app. Not ours to undo.
  local iface="vpn_$id"
  interface_exists "$iface" || exit 0

  local age next
  age=$(handshake_age "$(sudo wg show "$iface" latest-handshakes 2>/dev/null)")
  if (( age < STALE_SECS && force == 0 )); then
    if [[ $(state_get fail_count) =~ ^[1-9] ]]; then state_set fail_count 0; fi
    exit 0
  fi
  next=$(state_get next_attempt)
  if (( $(date +%s) < ${next:-0} && force == 0 )); then exit 0; fi

  log "handshake ${age}s old — re-registering (profile $id, endpoint $ep)"

  local check_ep=${PIA_EP_OVERRIDE:-$ep} list resolved status server_ip server_cn
  list=$(mktemp)
  fetch_serverlist "$list" || { rm -f "$list"; fail "server list download failed"; }
  resolved=$(serverlist_resolve "$list" "$check_ep" "$PIA_REGION"); rc=$?
  rm -f "$list"
  case $rc in
    0) ;;
    2) fail "region $PIA_REGION has no WireGuard servers" ;;
    *) fail "server list is not valid JSON" ;;
  esac
  read -r status server_ip server_cn <<< "$resolved"
  if [[ $status == RETIRED ]]; then
    log "endpoint $check_ep retired — replacement $server_ip ($server_cn)"
  fi

  local client_pub
  client_pub=$(client_pubkey "$iface")
  [[ -n $client_pub ]] || fail "cannot read the client public key from $iface"

  if (( dry )); then
    log "DRY RUN: would addKey $client_pub at https://$server_cn:1337 ($server_ip)"
    exit 0
  fi

  local token body parsed new_addr new_pub _dns
  token=$(get_token) || fail "PIA login failed (no token)"
  body=$(add_key "$server_ip" "$server_cn" "$client_pub" "$token")
  parsed=$(parse_addkey "$body") || fail "addKey failed: $(printf '%s' "$body" | tr '\n' ' ' | cut -c1-200)"
  read -r new_addr new_pub _dns <<< "$parsed"

  local backup handshake="no handshake within 30 s"
  backup=$(backup_profile "$id")
  patch_profile "$id" "$server_ip" "$new_pub" "$new_addr"
  apply_live "$iface" "$server_pub" "$new_pub" "$server_ip" "$addr" "$new_addr" \
    || log "live apply failed — Firewalla's restart will read the patched files"
  if wait_handshake "$iface"; then handshake="handshake OK"; fi
  log "repaired: now on $server_ip ($server_cn), address $new_addr — $handshake (backup: $backup)"
  state_set fail_count 0
  state_set next_attempt 0
}
