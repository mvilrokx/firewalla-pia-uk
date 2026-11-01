#!/bin/bash
# Test stand-in for Firewalla's update_crontab.sh: "installs" $USER_CRONTAB.
# SHIM_UPDATE_CRONTAB_NOOP=1 makes it do nothing, like a failed update.
if [[ ${SHIM_UPDATE_CRONTAB_NOOP:-0} == 1 ]]; then exit 0; fi
cp "$USER_CRONTAB" "$SHIM_CRONTAB"
