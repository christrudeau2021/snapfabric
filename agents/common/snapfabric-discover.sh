#!/bin/bash
# snapfabric discover — find candidate backup hosts on the local network.
#
#   usage: snapfabric-discover.sh [--subnet 192.0.2] [--plain]
#
# READ-ONLY. Touches nothing, logs in nowhere, changes no host. It reports what
# it can see and what it can infer, and nothing more.
#
# Pure shell — no nmap, no python. Discovery has to work before anything is
# installed, so it cannot depend on anything being installed.

set -uo pipefail

PLAIN=0; SUBNET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --subnet) SUBNET="${2:-}"; shift 2 ;;
    --plain)  PLAIN=1; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "usage: $0 [--subnet 192.0.2] [--plain]" >&2; exit 2 ;;
  esac
done

B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; N=$'\033[0m'
{ [ -t 1 ] && [ "$PLAIN" -eq 0 ]; } || { B=""; D=""; G=""; N=""; }

# --- work out the local subnet ----------------------------------------------
if [ -z "$SUBNET" ]; then
  myip=$(ipconfig getifaddr "$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')" 2>/dev/null)
  [ -z "$myip" ] && myip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  [ -z "$myip" ] && { echo "cannot determine local subnet; pass --subnet" >&2; exit 2; }
  SUBNET="${myip%.*}"
fi

printf "${B}snapfabric discover${N}  ${D}subnet %s.0/24${N}\n" "$SUBNET"
printf "${D}read-only: nothing is logged into or changed${N}\n\n"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# One-second TCP connect test. macOS nc uses -G for connect timeout, GNU nc uses
# -w; fall back to a backgrounded /dev/tcp probe that we kill ourselves.
# Capture help text first rather than pipe it: `nc -h` exits 1, and under
# `set -o pipefail` the pipeline then reports failure even when grep matched.
# That silently selected the GNU branch, whose -w does NOT bound the CONNECT on
# macOS -- probes went unbounded and a /24 scan took 84s instead of 9s.
_nc_help=$(nc -h 2>&1 || true)
if command -v nc >/dev/null 2>&1 && printf '%s' "$_nc_help" | grep -q -- '-G'; then
  probe_ssh(){ nc -z -G1 -w1 "$1" 22 >/dev/null 2>&1; }
elif command -v nc >/dev/null 2>&1; then
  probe_ssh(){ nc -z -w1 "$1" 22 >/dev/null 2>&1; }
else
  probe_ssh(){
    ( exec 3<>"/dev/tcp/$1/22" ) >/dev/null 2>&1 &
    local pid=$!; ( sleep 1; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    wait "$pid" 2>/dev/null
  }
fi

# --- sweep ------------------------------------------------------------------
# Parallel pings to populate the ARP cache, then read the cache. Backgrounded
# with a bounded wait so an unreachable /24 cannot hang the command.
printf "${D}sweeping…${N}"
for i in $(seq 1 254); do ( ping -c1 -W1 "$SUBNET.$i" >/dev/null 2>&1 & ) ; done
sleep 4
printf "\r                    \r"

# Drop "(incomplete)" entries. A /24 sweep leaves an ARP row for every address
# it tried, resolved or not -- 230 of 255 here. Probing those dead entries at
# one second each is what made discovery look like it had hung.
arp -an 2>/dev/null | grep -v incomplete | awk '{print $2, $4}' | tr -d '()' \
  | grep -E "^$SUBNET\." | sort -t. -k4 -n > "$TMP/arp" 2>/dev/null || true

# --- mDNS names, where available --------------------------------------------
: > "$TMP/mdns"
if command -v dns-sd >/dev/null 2>&1; then
  dns-sd -B _ssh._tcp local > "$TMP/raw" 2>&1 &
  _dpid=$!
  sleep 4
  kill "$_dpid" 2>/dev/null; wait "$_dpid" 2>/dev/null
  awk '/Add/{ $1=$2=$3=$4=$5=$6=""; sub(/^ +/,""); print }' "$TMP/raw" 2>/dev/null | sort -u > "$TMP/mdns"
elif command -v avahi-browse >/dev/null 2>&1; then
  avahi-browse -atrp 2>/dev/null | awk -F';' '/^=/{print $4}' | sort -u > "$TMP/mdns"
fi

# --- report ------------------------------------------------------------------
SELF_IP=$(ipconfig getifaddr "$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')" 2>/dev/null)
printf "${B}%-16s %-20s %-8s %s${N}\n" "ADDRESS" "NAME" "SSH" "NOTES"
found=0; sshable=0

# Probe hosts in parallel and collect rows, so total time is bounded by the
# slowest single probe rather than their sum.
while read -r ip mac; do
  [ -n "$ip" ] || continue
  ( probe_ssh "$ip" && echo open > "$TMP/p.$ip" || echo closed > "$TMP/p.$ip" ) &
done < "$TMP/arp"
wait

while read -r ip mac; do
  [ -n "$ip" ] || continue
  found=$((found+1))

  name=$(dscacheutil -q host -a ip_address "$ip" 2>/dev/null | awk '/^name:/{print $2; exit}')
  [ -z "$name" ] && name=$(getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')
  [ -z "$name" ] && name="—"

  # Bounded TCP probe. No auth attempt, no banner grab. bash's /dev/tcp has no
  # timeout, so a host that is in the ARP cache but not answering on 22 blocks
  # for the full ~75s TCP timeout -- which made a /24 sweep appear to hang.
  if [ "$(cat "$TMP/p.$ip" 2>/dev/null)" = "open" ]; then
    ssh_state="${G}open${N}"; sshable=$((sshable+1))
  else
    ssh_state="${D}—${N}"
  fi

  note=""
  [ "$ip" = "${SELF_IP:-}" ] && note="this machine"
  case "$mac" in
    ac:de:48:*|f0:18:98:*|a4:83:e7:*) [ -z "$note" ] && note="Apple" ;;
  esac

  printf "%-16s %-20s %-8b %s\n" "$ip" "${name%%.*}" "$ssh_state" "$note"
done < "$TMP/arp"

echo
printf "  %d hosts responded, %d with SSH open\n" "$found" "$sshable"

if [ -s "$TMP/mdns" ]; then
  printf "\n${B}mDNS advertising SSH${N}\n"
  sed 's/^/  /' "$TMP/mdns"
fi

cat <<EOF

${D}Next: snapfabric plan — choose which of these to back up, what to call them,
and which drive to use. plan writes a config for review; it changes nothing.${N}
EOF
