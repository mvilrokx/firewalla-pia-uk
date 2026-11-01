#!/bin/bash
# Test stand-in for Firewalla's update_crontab.sh: "installs" $USER_CRONTAB.
cp "$USER_CRONTAB" "$SHIM_CRONTAB"
