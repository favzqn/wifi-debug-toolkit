# wifi-debug-toolkit

Find what's slowing your Wi-Fi on macOS, then fix what you can — with a
working replacement for the removed `airport` CLI, a diagnosis runbook, and
automation for Huawei EG8041V5 ONTs (Biznet `BIZNETEBG2` build).

Everything here was extracted from a real debugging session where the root
causes were: **stuck on 2.4 GHz instead of 5 GHz**, and **auto channel
selection picking a channel stomped by a −54 dBm neighbor**.

## Quick diagnosis runbook (macOS)

Run in order, ~2 minutes total:

```bash
# 1. Throughput + responsiveness (Apple's built-in speed test, ~60s)
networkQuality -s

# 2. Latency / jitter / loss (gateway, then public resolvers)
ping -c 20 -i 0.2 <gateway-ip>
ping -c 20 -i 0.2 1.1.1.1

# 3. Your link: band, channel, PHY rate, noise, airtime (CCA), faults
sudo wdutil info

# 4. Nearby networks: SSIDs, bands, channels, RSSI (airport is gone; use this)
swift tools/wifiscan.swift

# 5. Who's eating bandwidth: per-process rates (two samples, diffed)
nettop -P -L 1 -x > /tmp/nt1.csv
sleep 8
nettop -P -L 1 -x > /tmp/nt2.csv
# diff bytes columns of the two files; or just eyeball totals:
nettop -P -L 1 -x

# 6. Every device on the LAN (ping sweep), then name them via mDNS
seq 1 254 | xargs -P 64 -n1 sh -c \
  'ping -c1 -W200 192.168.1.$0 >/dev/null 2>&1 && echo 192.168.1.$0'
dns-sd -B _googlecast._tcp local.   # Chromecast/Android TV
dns-sd -B _airplay._tcp local.      # Apple devices
dns-sd -B _spotify-connect._tcp local.
dns-sd -B _adb._tcp local.          # Android with ADB-over-network enabled
```

Notes:
- `arp -a` may return empty in sandboxed shells — the ping sweep + mDNS
  browse identifies devices without it.
- `CURRENT_SSID` in the scanner prints nil until you grant the terminal
  Location Services (Privacy settings). Channel/band/RSSI still work.

## Reading the results

| Observation | Meaning | Fix |
|---|---|---|
| PHY rate ~144 Mbps, 2.4 GHz, 20 MHz | stuck on 2.4 GHz half-duplex | join the 5 GHz SSID (biggest single win) |
| neighbor AP same channel, stronger RSSI | co-channel interference | manual channel 1/6/11 — pick the one neighbors aren't using |
| `wdutil info` CCA high (>40%) | congested airtime | channel change or move to 5 GHz |
| idle latency fine, `networkQuality` responsiveness "Low" (400+ ms) | bufferbloat or airtime contention | QoS on router, pause bulk transfers during calls |
| 0% loss but gateway max >> avg | occasional interference spikes | same as channel fix |

Example outcome from one session (before → after):

| Metric | Before | After |
|---|---|---|
| Band / channel | 2.4 GHz ch4 (auto), overlapped by −54 dBm neighbor on ch4/40 | 5 GHz ch149/80 + 2.4 GHz manual ch11 |
| PHY rate | 144 Mbps | 585 Mbps |
| Down / up capacity | 78 / 85 Mbps | 95–117 Mbps |
| Responsiveness (down/up) | Low, 421/536 ms | Medium, ~107–267 ms |
| Jitter to 1.1.1.1 | max 16 ms | max 12 ms |

## Huawei EG8041V5 ONT automation

`tools/huawei-ont.sh` drives the web UI of the Biznet `BIZNETEBG2` firmware
without a browser.

```bash
./tools/huawei-ont.sh login              # get session (idle timeout ~30-60s)
./tools/huawei-ont.sh show               # wlanArr dump: channels, auto-chan, power
./tools/huawei-ont.sh channel 11         # 2.4 GHz -> manual channel 11
./tools/huawei-ont.sh qos-status         # Smart QoS state
./tools/huawei-ont.sh qos-enable         # known-broken, see below
```

Override defaults with env vars: `ROUTER`, `HW_USER`, `HW_PASS`.

Login flow (reverse-engineered):

1. `POST /asp/GetRandCount.asp` → token (strip UTF-8 BOM)
2. `POST /login.cgi` with `UserName`, `PassWord=<base64>`, `Language=english`,
   `x.X_HW_Token=<token>`, header `Cookie: Cookie=body:Language:english:id=-1`
3. Response sets `Set-cookie: Cookie=sid=<hex>:Language:english:id=1`

`Epadmin` / `adminEp` is the **factory default superadmin account** on these
Biznet ONTs — change it after first login.

Config writes are TR-069-style partial sets: `set.cgi?y=<object>` with only
the parameters you want to change (e.g. `y.Channel` + `y.AutoChannelEnable`),
plus the page's `hwonttoken` as `x.X_HW_Token`.

### Known firmware bug: Smart QoS never applies

`set.cgi?x=InternetGatewayDevice.QueueManagement` accepts a valid token, then
**hangs forever** (verified: enable-only, bandwidth-only, combined payloads;
10/20/25/120 s timeouts; state never changes). The browser sends a
byte-identical request and hangs the same way — it's the backend, not the
client. Workaround: none on this build; needs an ISP firmware update.

## Privacy

This repo deliberately contains no real SSIDs, BSSIDs, MACs, serials,
IPv6 prefixes, or session tokens. The default router credentials are factory
defaults, not secrets.

## License

MIT