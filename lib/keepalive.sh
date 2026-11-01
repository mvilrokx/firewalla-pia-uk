#!/bin/bash
# The keepalive: cron runs it every 5 minutes. While the handshake is fresh it
# does nothing. When PIA has forgotten the key or the server has gone, it
# registers the key again (on a server in PIA's current list if needed),
# patches the client's profile files, and applies the change to the live
# interface.

DRY_RUN=0

# fail <msg> — record the failure, schedule the next attempt, exit 1. A dry run
# only logs: a test run must not delay the real one.
fail() {
  if (( DRY_RUN )); then
    log "FAIL (dry run): $*"
    exit 1
  fi
  local n delay
  n=$(state_get fail_count); n=$(( ${n:-0} + 1 ))
  delay=$(next_delay "$n")
  state_set fail_count "$n"
  state_set next_attempt $(( $(date +%s) + delay ))
  log "FAIL($n): $* — next attempt in $(( delay / 60 )) min"
  exit 1
}

# log_once <state-key> <msg> — logs a lasting problem once, not every 5 minutes,
# so that it does not push the "repaired:" lines out of the log.
log_once() {
  if [[ $(state_get "$1") != 1 ]]; then
    log "$2"
    state_set "$1" 1
  fi
}

cmd_keepalive() {
  local force=0 arg
  for arg in "$@"; do
    case $arg in
      --dry-run) DRY_RUN=1 ;;
      --force) force=1 ;;
      *) echo "unknown flag: $arg" >&2; exit 64 ;;
    esac
  done

  # One run at a time, also when someone runs it by hand while cron runs it.
  exec 9>> "$LOCK_FILE"
  if ! flock -n 9; then
    echo "another keepalive run is busy; nothing done" >&2
    exit 0
  fi
  rotate_log

  local profile rc id ep server_pub addr
  profile=$(find_profile); rc=$?
  if (( rc == 1 )); then
    log_once no_client "no PIA WireGuard client (port 1337) found"
    exit 0
  fi
  if (( rc == 2 )); then
    log_once many_clients "more than one PIA client: $(find_profiles | paste -sd ' ' -) — remove the extra ones in the Firewalla app"
    exit 1
  fi
  if (( rc != 0 )); then
    log "cannot read the PIA client profile ($(find_profiles).json)"
    exit 1
  fi
  read -r id ep server_pub addr <<< "$profile"
  if [[ $(state_get no_client) == 1 ]]; then state_set no_client 0; fi
  if [[ $(state_get many_clients) == 1 ]]; then state_set many_clients 0; fi

  # No interface: the user turned the client off in the app. Not ours to undo.
  local iface="vpn_$id"
  interface_exists "$iface" || exit 0

  local age next
  age=$(handshake_age "$(sudo wg show "$iface" latest-handshakes 2>/dev/null)")
  # "never" can also mean that Firewalla has just (re)started the client: give
  # it a moment for its first handshake before registering again.
  if (( age == 999999999 && force == 0 )) && wait_handshake "$iface"; then
    age=$(handshake_age "$(sudo wg show "$iface" latest-handshakes 2>/dev/null)")
  fi
  if (( age < STALE_SECS && force == 0 )); then
    # A working tunnel clears the back-off, so the next outage is repaired at once.
    if [[ $(state_get fail_count) =~ ^[1-9] || $(state_get next_attempt) =~ ^[1-9] ]]; then
      state_set fail_count 0
      state_set next_attempt 0
    fi
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
  # PIA's list shows a changing subset of its servers, so "not listed" does not
  # prove that the server is gone; a listed server is a safe choice either way.
  if [[ $status == RETIRED ]]; then
    log "endpoint $check_ep is not in PIA's list now — using $server_ip ($server_cn)"
  fi

  local client_pub
  client_pub=$(client_pubkey "$iface")
  [[ -n $client_pub ]] || fail "cannot read the client public key from $iface"

  if (( DRY_RUN )); then
    log "DRY RUN: would addKey $client_pub at https://$server_cn:1337 ($server_ip)"
    exit 0
  fi

  local token body parsed new_addr new_pub _dns
  token=$(get_token); rc=$?
  case $rc in
    0) ;;
    1) fail "PIA rejected the saved login" ;;
    *) fail "cannot reach PIA's login server" ;;
  esac
  body=$(add_key "$server_ip" "$server_cn" "$client_pub" "$token" 2>&1)
  parsed=$(parse_addkey "$body") || fail "addKey failed: $(printf '%s' "$body" | tr '\n' ' ' | cut -c1-200)"
  read -r new_addr new_pub _dns <<< "$parsed"

  local backup
  backup=$(backup_profile "$id") || fail "cannot back up the profile files"
  patch_profile "$id" "$server_ip" "$new_pub" "$new_addr" || fail "cannot write the profile files"
  apply_live "$iface" "$server_pub" "$new_pub" "$server_ip" "$addr" "$new_addr" \
    || log "live apply failed — Firewalla's restart will read the patched files"
  # Without a handshake the repair did not work: back off instead of
  # registering again (and making a new backup) every 5 minutes.
  wait_handshake "$iface" \
    || fail "registered on $server_ip ($server_cn), address $new_addr, but no handshake within 30 s (backup: $backup)"
  log "repaired: now on $server_ip ($server_cn), address $new_addr — handshake OK (backup: $backup)"
  state_set fail_count 0
  state_set next_attempt 0
}
