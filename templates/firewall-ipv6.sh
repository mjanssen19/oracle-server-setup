#!/bin/bash
# Host IPv6 firewall for an Oracle Cloud Ubuntu image, where ip6tables ships
# EMPTY with policy ACCEPT. Mirrors the IPv4 image rules (default deny, terminal
# REJECT) and adds the IPv6-specific allowances found necessary on numbersgamearm01.
#
# APPENDS rules and never flushes, so tailscaled's own chains (-A INPUT -j ts-input,
# which tailscaled inserts first) survive. Idempotent: it exits if our REJECT is already there.
#
# Run it with a rollback armed (see reference/host-hardening.md 3.6):
#   sudo ip6tables-save > /root/rules.v6.rollback
#   sudo systemd-run --on-active=600 --unit=fw-rollback ip6tables-restore /root/rules.v6.rollback
#   sudo ./firewall-ipv6.sh
#   (verify from a NEW session) → sudo netfilter-persistent save && sudo systemctl stop fw-rollback.timer
#
# Opening a public port (only for non-HTTP services from Phase 0): add
#   ip6tables -I INPUT <n> -p tcp --dport <port> -m comment --comment "<why>" -j ACCEPT
# above the REJECT, and add the same rule in iptables and in the Security List.
set -euo pipefail

if ip6tables -C INPUT -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null; then
  echo "IPv6 ruleset already present; nothing to do."; exit 0
fi

add() { ip6tables -A "$@"; }

add INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
add INPUT -i lo -j ACCEPT

# ICMPv6 is not optional. Neighbour discovery (133-137) keeps the next hop working;
# Packet Too Big (2) is IPv6's only PMTU signal. Dropping them black-holes IPv6 from inside.
declare -A ICMP6=(
  [1]="destination unreachable" [2]="packet too big - PMTU" [3]="time exceeded" [4]="parameter problem"
  [128]="echo request" [129]="echo reply" [130]="MLD query" [131]="MLD report" [132]="MLD done"
  [133]="router solicitation" [134]="router advertisement" [135]="neighbour solicitation"
  [136]="neighbour advertisement" [137]="redirect"
)
for t in 1 2 3 4 128 129 130 131 132 133 134 135 136 137; do
  add INPUT -p ipv6-icmp -m icmp6 --icmpv6-type "$t" -m comment --comment "${ICMP6[$t]}" -j ACCEPT
done

# The Oracle IPv6 address is DHCPv6-leased (~19h valid_lft). Without this, renewal
# replies are dropped and IPv6 vanishes about a day later.
add INPUT -s fe80::/10 -p udp -m udp --dport 546 -m comment --comment "DHCPv6 reply - lease renewal" -j ACCEPT

# No port 22 over IPv6: the home-IP SSH fallback is IPv4 (plus Tailscale via ts-input).
# If the home line has a stable IPv6 prefix, add above this line:
#   ip6tables -A INPUT -p tcp -s <home-prefix>/56 --dport 22 -m conntrack --ctstate NEW -j ACCEPT
# and the same source in the Security List.
add INPUT -j REJECT --reject-with icmp6-adm-prohibited

# Forwarding: tailscaled put "-j ts-forward" first; reject the rest.
if ! ip6tables -C FORWARD -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null; then
  add FORWARD -j REJECT --reject-with icmp6-adm-prohibited
fi

echo "IPv6 rules applied:"
ip6tables -S INPUT
echo
echo "Now verify from a NEW session (tailnet SSH + curl -6 https://ifconfig.co), then:"
echo "  sudo netfilter-persistent save && sudo systemctl stop fw-rollback.timer"
