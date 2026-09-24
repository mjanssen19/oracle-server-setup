#!/bin/bash
# /usr/local/sbin/docker-firewall.sh  (root:root 0750). Run by docker-firewall.service after Docker starts.
#
# Docker publishes ports by writing its own NAT/FORWARD rules, so UFW or iptables
# INPUT rules do NOT protect `-p 8080:8080`. DOCKER-USER is the chain Docker leaves
# for you, and it is evaluated before Docker's own forwarding rules.
#
# First line of defence: publish on loopback (`127.0.0.1:8080:8080`). This script is
# the second line: anything published on 0.0.0.0 by mistake is still unreachable
# from the internet.
#
# Based on lurch's version (2026-05-22) with the VPS case added.
set -euo pipefail

LAN_CIDR="${LAN_CIDR:-}"          # home server: e.g. 192.168.1.0/24. VPS: leave empty
TAILNET_V4="100.64.0.0/10"
PUBLIC_TCP_PORTS=""               # e.g. "6881" for torrent peers; keep empty on a VPS
PUBLIC_UDP_PORTS=""

apply() {  # $1 = iptables | ip6tables
  local ipt=$1
  if ! $ipt -L DOCKER-USER -n >/dev/null 2>&1; then
    echo "$ipt: DOCKER-USER chain not found (Docker not running, or no IPv6 in Docker); skipping"; return 0
  fi
  $ipt -F DOCKER-USER
  $ipt -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  $ipt -A DOCKER-USER -i docker0 -j RETURN                 # container → anything
  $ipt -A DOCKER-USER -i br-+ -j RETURN                    # compose networks
  $ipt -A DOCKER-USER -i lo -j RETURN
  $ipt -A DOCKER-USER -i tailscale0 -j RETURN              # tailnet clients
  if [ "$ipt" = iptables ]; then
    $ipt -A DOCKER-USER -s "$TAILNET_V4" -j RETURN
    [ -n "$LAN_CIDR" ] && $ipt -A DOCKER-USER -s "$LAN_CIDR" -j RETURN
  fi
  for p in $PUBLIC_TCP_PORTS; do $ipt -A DOCKER-USER -p tcp --dport "$p" -j RETURN; done
  for p in $PUBLIC_UDP_PORTS; do $ipt -A DOCKER-USER -p udp --dport "$p" -j RETURN; done
  $ipt -A DOCKER-USER -j DROP
}

apply iptables
apply ip6tables
echo "docker-firewall: DOCKER-USER rules applied"
