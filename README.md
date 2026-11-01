# firewalla-pia-uk

Watch BBC iPlayer from outside the UK on every device in your house — smart TVs
and Apple TVs too — with a [Firewalla](https://firewalla.com) and a
[PIA](https://www.privateinternetaccess.com) (Private Internet Access) subscription.

PIA's OpenVPN servers and PIA's Smart DNS do not pass BBC's location check. A
WireGuard key that is registered through PIA's own API gets a clean UK exit IP
that BBC accepts. PIA does not give you WireGuard config files, and it retires
its UK streaming servers about once a week, so the tunnel stops without warning.

This project does three things:

1. **Setup** — registers a WireGuard key with PIA's UK streaming server and shows
   the config as a QR code. You scan it with the Firewalla app.
2. **Route rule** — instructions (below) to send only BBC traffic through the tunnel.
3. **Keepalive** — a job on the box that checks the tunnel every 5 minutes and
   repairs it when PIA forgets the key or retires the server.

## Requirements

- A Firewalla box (tested on the Firewalla Gold Pro).
- A PIA subscription.
- SSH access to the box as `pi` (Firewalla app → Settings → Advanced → Configurations → SSH Console).
- The Firewalla phone app and the Firewalla web app ([my.firewalla.com](https://my.firewalla.com)).

## Install

Connect to the box with SSH as `pi`, then:

```bash
cd /tmp
curl -fsSL -o firewalla-pia-uk.tar.gz https://github.com/mvilrokx/firewalla-pia-uk/archive/refs/tags/v0.1.0.tar.gz
tar xzf firewalla-pia-uk.tar.gz && cd firewalla-pia-uk-0.1.0
less install.sh   # read it first
./install.sh
```

The installer:

1. Checks that the box has the tools it needs.
2. Copies the scripts to `/home/pi/.firewalla/config/firewalla-pia-uk/`.
3. Asks for your PIA username and password, and checks them with PIA. The login is
   stored on the box in `credentials` (readable by `pi` only) and is sent only to
   PIA, because the keepalive needs it to register the key again.
4. Uses your PIA WireGuard client if one exists (a client on port 1337). If there is
   none, it registers a new key and shows a **QR code**. In the Firewalla app, go to
   **VPN Client → add → WireGuard → Scan QR Code**, scan it, name the client
   (for example "PIA UK Streaming"), and save. If you prefer, use **Import Profile**
   with the file the installer names.
5. Adds one line to Firewalla's `user_crontab`, so the keepalive runs every 5 minutes
   and survives reboots and firmware updates.
6. Does a test run that changes nothing.

## Route rule

Send only BBC traffic through the tunnel:

1. In the **web app** ([my.firewalla.com](https://my.firewalla.com)), make a Target
   List named "BBC iPlayer". The phone app cannot enter these entries. Use
   **wildcard** entries (they match subdomains; a plain `bbc.co.uk` misses the
   live-TV hosts):
   - `*.bbc.co.uk`
   - `*.bbci.co.uk`
   - `*.bbc.com`
   - `*.bbctvapps.co.uk`
   - `*.bidi.net.uk`

   and these exact hosts:
   - `vod-dash-uk-live.akamaized.net`
   - `vod-hls-uk-live.akamaized.net`
   - `as-hls-uk-live.akamaized.net`
   - `as-dash-uk-live.akamaized.net`
2. In the phone app, tap **Routes** on the box's main page, then **+**, and make a
   route with **Matching:** Target List "BBC iPlayer", **On:** All Devices,
   **Interface:** your PIA WireGuard client, and **Route Preference:** Static.
   If you later replace the PIA client, open this route under **Routes** and select
   the new client as **Interface**.

Good to know:

- Devices must use Firewalla's DNS, or the rule does not see their traffic. On an
  iPhone, turn off **Limit IP Address Tracking** for your home Wi-Fi.
- After you change the rule, flush the device's DNS cache (on iOS: airplane mode on
  and off). Pausing a video does not do this.
- Target-list changes in the web app reach the box at Firewalla's next refresh. To
  force it, delete the Route rule and make it again with the same list.
- When any VPN client is added or deleted, Firewalla reloads its routing, and
  streams that are playing stop. Start them again.
- A very fast player (for example Music Assistant) can fail the first time it plays
  from a new CDN address, because Firewalla learns the address about 300 ms after
  the DNS answer. Press play again.

## Check that it works

```bash
/home/pi/.firewalla/config/firewalla-pia-uk/bin/firewalla-pia-uk status
```

```
client:      PIA UK Streaming (WG) (1D17_1D170)
server:      85.203.46.72
address:     10.186.0.136
handshake:   12 s ago
last repair: 2026-11-01 03:10:22 repaired: now on 85.203.46.72 (Server-10870-2a), address 10.186.0.136 — handshake OK (backup: …)
BBC:         OK
recent log:
…
```

- **handshake** — when PIA last answered. Older than 5 minutes means the tunnel is
  down; `never` means PIA never answered.
- **last repair** — the last time the keepalive registered the key again.
- **failures** — only shown after failed repairs, with the time of the next attempt.
- **BBC** — asks BBC through the tunnel itself: `OK`, `blocked (geolocation)`, or
  `unknown (no answer)`.

`status` exits with 0 when the handshake is recent and BBC says OK, else with 1.
The project sends no notifications: `status` and the log
(`/home/pi/.firewalla/config/firewalla-pia-uk/keepalive.log`) show what happened.

## How it works

Every 5 minutes the keepalive:

1. Finds the PIA client: the one WireGuard client on port 1337.
2. Does nothing if the client is turned off in the app, or if the handshake is
   younger than 5 minutes (no Internet calls in that case).
3. Otherwise reads PIA's server list. If the client's server is gone (retired), it
   takes the current UK streaming server (`uk_2`).
4. Gets a token with your PIA login and registers the client's public key again.
5. Backs up the client's three profile files (the newest 10 backups are kept in
   `backup/`), writes the new server, server key, and address into them, and
   applies the change to the live tunnel. Firewalla's app shows the new values.

After a failure it waits 15 minutes, then 30, and so on, up to 6 hours.

It writes only to its own folder, to one line in `user_crontab`, and to the three
profile files of the PIA client.

## Troubleshooting

- **`BBC: blocked (geolocation)`** while the handshake is recent — BBC blocks the
  exit IP that PIA gave you. Nothing repairs this automatically. You can force a new
  registration with
  `/home/pi/.firewalla/config/firewalla-pia-uk/bin/firewalla-pia-uk keepalive --force`,
  which possibly gives a different exit IP.
- **`handshake: never`** with failures — read `keepalive.log`. `PIA login failed`
  means PIA rejected the saved login: delete `credentials` and run `./install.sh`
  again.
- **"more than one PIA client"** — delete the extra WireGuard clients on port 1337
  in the app. The keepalive does nothing until only one is left.
- **Setup timed out** — import the file the installer named
  (`/home/pi/.firewalla/config/firewalla-pia-uk/pia-uk.conf`) with **Import
  Profile**, then run `./install.sh` again. It finds the client and continues.
- **iPlayer fails on an IPv6 network** while `status` is OK — the tunnel carries IPv4
  only. BBC has no IPv6 addresses today (October 2026). If that changes, BBC traffic
  can go around the tunnel over IPv6.

## Update

Download the new release as in [Install](#install) and run `./install.sh` again. It
keeps your PIA login and your client.

## Uninstall

```bash
/home/pi/.firewalla/config/firewalla-pia-uk/uninstall.sh
```

It removes the cron line and asks before it deletes the folder (with your saved
login). Then delete the PIA client and the BBC Route rule in the Firewalla app.

## Notes

- You need a UK TV licence to watch BBC iPlayer, and using a VPN may be against
  BBC's terms of use. You are responsible for how you use this project.
- This project is not affiliated with the BBC, PIA, or Firewalla.

## Credits and license

The PIA API flow and PIA's CA certificate (`share/ca.rsa.4096.crt`) come from
[pia-foss/manual-connections](https://github.com/pia-foss/manual-connections)
(MIT license).

This project is released under the [MIT license](LICENSE).
