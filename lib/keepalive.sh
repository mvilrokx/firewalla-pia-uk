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
  n=$(( $(state_num fail_count) + 1 ))
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

# clear_once <state-key> — the problem is gone: log it again when it comes back.
clear_once() {
  if [[ $(state_get "$1") == 1 ]]; then state_set "$1" 0; fi
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
  if ! take_lock -n; then
    echo "another firewalla-pia-uk run is busy; nothing done" >&2
    exit 0
  fi
  rotate_log

  local profile rc id ep server_pub addr
  profile=$(find_profile); rc=$?
  case $rc in
    0) ;;
    1) log_once no_client "no PIA client chosen — run install.sh"; exit 0 ;;
    2) log_once client_gone "the PIA client $(client_id) is gone (deleted in the app?) — run install.sh again"; exit 1 ;;
    *) log_once bad_profile "cannot read the PIA client profile ($(client_id).json)"; exit 1 ;;
  esac
  read -r id ep server_pub addr <<< "$profile"
  clear_once no_client; clear_once client_gone; clear_once bad_profile

  # No interface: the user turned the client off in the app. Not ours to undo.
  local iface="vpn_$id"
  if ! interface_exists "$iface"; then
    log_once client_off "the PIA client $(profile_name "$id") ($id) is turned off in the Firewalla app — nothing to do"
    exit 0
  fi
  clear_once client_off

  local age now next
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
  now=$(date +%s); next=$(state_num next_attempt)
  # More than the longest back-off (6 h) ahead: set while the clock was wrong.
  if (( now < next && next - now <= 21600 && force == 0 )); then exit 0; fi

  log "handshake ${age}s old — re-registering (profile $id, endpoint $ep)"

  local check_ep=${PIA_EP_OVERRIDE:-$ep} list resolved status server_ip server_cn
  list=$(mktemp)
  fetch_serverlist "$list" || { rm -f "$list"; fail "server list download failed"; }
  resolved=$(serverlist_resolve "$list" "$check_ep" "$PIA_REGION" "$(state_get avoid_ip)"); rc=$?
  rm -f "$list"
  case $rc in
    0) ;;
    2) fail "region $PIA_REGION has no WireGuard servers" ;;
    *) fail "server list is not valid JSON" ;;
  esac
  read -r status server_ip server_cn <<< "$resolved"
  # PIA's list shows a changing subset of its servers, so "not listed" does not
  # prove that the server is gone; a listed server is a safe choice either way.
  case $status in
    RETIRED) log "endpoint $check_ep is not in PIA's list now — using $server_ip ($server_cn)" ;;
    AVOIDED) log "endpoint $check_ep did not answer last time — using $server_ip ($server_cn)" ;;
  esac

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
    2) fail "cannot reach PIA's login server" ;;
    *) fail "PIA's login server gave no usable answer (HTTP $token)" ;;
  esac
  body=$(add_key "$server_ip" "$server_cn" "$client_pub" "$token" 2>&1); rc=$?
  # No answer at all (PIA's errors come as an answer): the next attempt uses
  # another server, else a server that is blocked for this box is tried forever.
  if (( rc != 0 )); then state_set avoid_ip "$server_ip"; fi
  parsed=$(parse_addkey "$body") || fail "addKey failed: $(printf '%s' "$body" | tr '\n' ' ' | cut -c1-200)"
  read -r new_addr new_pub _dns <<< "$parsed"

  local backup since
  backup=$(backup_profile "$id") || fail "cannot back up the profile files"
  patch_profile "$id" "$server_ip" "$new_pub" "$new_addr" || fail "cannot write the profile files"
  since=$(date +%s)
  apply_live "$iface" "$server_pub" "$new_pub" "$server_ip" "$addr" "$new_addr" \
    || log "live apply failed — Firewalla's restart will read the patched files"
  # Only a handshake after the change proves the repair. Without one, back off
  # instead of registering again (and making a new backup) every 5 minutes.
  wait_handshake "$iface" "$since" \
    || fail "registered on $server_ip ($server_cn), address $new_addr, but no handshake within 30 s (backup: $backup)"
  log "repaired: now on $server_ip ($server_cn), address $new_addr — handshake OK (profile $id, backup: $backup)"
  state_set fail_count 0
  state_set next_attempt 0
  state_set avoid_ip ""
}
