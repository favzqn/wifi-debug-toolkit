#!/bin/bash
# Huawei EG8041V5 ONT web automation (Biznet "BIZNETEBG2" firmware build).
#
# Login flow, reverse-engineered from the login page:
#   1. POST /asp/GetRandCount.asp  -> token (strip the UTF-8 BOM first)
#   2. POST /login.cgi with UserName=<user>, PassWord=<base64(password)>,
#      Language=english, x.X_HW_Token=<token>, plus header
#      Cookie: Cookie=body:Language:english:id=-1
#   3. Response sets the session cookie:
#      Set-cookie: Cookie=sid=<hex>:Language:english:id=1
#
# Epadmin/adminEp is the DEFAULT superadmin account shipped on these Biznet
# ONTs (confirmed by the device owner). Change it after first login.
#
# Sessions idle out in ~30-60s: run `login` immediately before each command.
#
# Known firmware bug: set.cgi?x=InternetGatewayDevice.QueueManagement
# (Smart QoS / "Intelligent Channel") accepts a valid token, then hangs
# forever and never applies. Verified with 10/20/25/120s timeouts, enable-only
# and bandwidth-only payloads. Same request from a browser hangs identically.
set -euo pipefail

ROUTER="${ROUTER:-http://192.168.18.1}"
HW_USER="${HW_USER:-Epadmin}"
HW_PASS="${HW_PASS:-adminEp}"
COOKIE_BODY='Cookie=body:Language:english:id=-1'
SID_FILE="${TMPDIR:-/tmp}/huawei_ont_sid"
WLAN2G_DOMAIN='InternetGatewayDevice.LANDevice.1.WLANConfiguration.1'

strip_bom() { sed $'s/\xEF\xBB\xBF//'; }

login() {
  local cnt pw sid
  curl -s -m 5 "$ROUTER/" -o /dev/null
  cnt=$(curl -s -m 5 -X POST "$ROUTER/asp/GetRandCount.asp" \
    -H "Cookie: $COOKIE_BODY" | strip_bom)
  pw=$(printf '%s' "$HW_PASS" | base64)
  sid=$(curl -s -m 6 -i \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H "Cookie: $COOKIE_BODY" \
    --data-urlencode "UserName=$HW_USER" \
    --data-urlencode "PassWord=$pw" \
    --data-urlencode 'Language=english' \
    --data-urlencode "x.X_HW_Token=$cnt" \
    "$ROUTER/login.cgi" \
    | grep -i '^Set-cookie:Cookie=' | head -1 \
    | sed 's/^[Ss]et-[Cc]ookie://;s/;.*//;s/ //g')
  [ -n "$sid" ] || { echo "login failed (wrong creds or lockout)" >&2; exit 1; }
  printf '%s' "$sid" > "$SID_FILE"
  echo "logged in, session saved to $SID_FILE"
}

sid() { cat "$SID_FILE"; }

get_token() {  # $1 = page path relative to router root
  curl -s -m 6 -H "Cookie: $(sid)" "$ROUTER/$1" \
    | grep -oE 'hwonttoken" value="[a-f0-9]{64}' | grep -oE '[a-f0-9]{64}'
}

cmd="${1:-help}"
case "$cmd" in
  login)
    login
    ;;
  show)
    # dump wlanArr: per-SSID domain, channel, AutoChannelEnable, power, ...
    curl -s -m 6 -H "Cookie: $(sid)" \
      "$ROUTER/html/amp/wlanadv/wlanadvance_com_api.asp" \
      | grep -o 'var wlanArr = new Array(.*' | head -c 700
    echo
    ;;
  channel)
    # usage: huawei-ont.sh login && huawei-ont.sh channel 11
    # sets 2.4 GHz to a manual channel (partial set: only channel params)
    ch="${2:?channel number 1-13 required}"
    tok=$(get_token 'html/amp/wlanadv/WlanAdvance.asp?2G')
    [ -n "$tok" ] || { echo "no token (session dead? rerun login)" >&2; exit 1; }
    curl -s -m 8 -H "Cookie: $(sid)" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "y.Channel=$ch" \
      --data-urlencode 'y.AutoChannelEnable=0' \
      --data-urlencode "x.X_HW_Token=$tok" \
      "$ROUTER/set.cgi?y=$WLAN2G_DOMAIN&RequestFile=html/amp/wlanadv/WlanAdvance.asp" \
      -o /dev/null -w 'HTTP %{http_code}\n'
    echo "2.4 GHz -> manual channel $ch (verify with: $0 show)"
    ;;
  qos-status)
    curl -s -m 6 -H "Cookie: $(sid)" "$ROUTER/html/bbsp/qossmart/qossmart.asp" \
      | grep -oE 'QosSmart(Enable|Bandwidth)Info\("[^"]+","[0-9]+"\)' || true
    ;;
  qos-enable)
    echo "WARNING: on BIZNETEBG2 firmware this POST hangs and never applies." >&2
    echo "Try once in a browser first; same request, same hang." >&2
    tok=$(get_token 'html/bbsp/qossmart/qossmart.asp')
    [ -n "$tok" ] || { echo "no token (session dead? rerun login)" >&2; exit 1; }
    curl -s --max-time 20 -H "Cookie: $(sid)" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'x.X_HW_ClassificationEnable=1' \
      --data-urlencode "x.X_HW_Token=$tok" \
      "$ROUTER/set.cgi?x=InternetGatewayDevice.QueueManagement&RequestFile=html/bbsp/qossmart/qossmart.asp" \
      -o /dev/null -w 'HTTP %{http_code} (000/timeout = known bug)\n' || true
    ;;
  *)
    echo "usage: $0 login | show | channel <1-13> | qos-status | qos-enable"
    echo "env:   ROUTER, HW_USER, HW_PASS (defaults: this LAN, Epadmin/adminEp)"
    ;;
esac