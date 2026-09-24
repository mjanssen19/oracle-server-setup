#!/bin/bash
# oci-seclist.sh: view and change the Oracle Cloud Security List (the cloud firewall) from the machine.
#
#   oci-seclist.sh detect                                  # on an OCI instance: list this VNIC's security lists
#   oci-seclist.sh show
#   oci-seclist.sh add    tcp|udp <port>[-<port>] <cidr> "<description>" [--dry-run]
#   oci-seclist.sh remove tcp|udp <port>[-<port>] <cidr>                  [--dry-run]
#
#   <cidr>: 203.0.113.7/32, 0.0.0.0/0, 2001:db8::/56, ::/0
#
# Env:
#   OCI_SECLIST_ID   the security list to edit (from `detect`, or the console)
#   OCI_CLI_AUTH     instance_principal (agent on the VPS) | security_token (laptop session) | unset (API key)
#
# Safety:
#   - `update` REPLACES the whole ingress list, so this reads, edits one rule, writes back all of them.
#   - A backup of the current rules is saved before every write; restore with:
#       oci network security-list update --security-list-id $OCI_SECLIST_ID --ingress-security-rules file://<backup> --force
#   - `get` returns kebab-case keys, while CLI input is documented as camelCase, so keys are converted.
#   - Never remove the rule you are connected through without another path (Tailscale / Console).
#   - After a change, test from a network that is NOT allowed (phone hotspot); a probe from an allowed IP proves nothing.
# Needs IAM: manage security-lists (+ inspect vnics/subnets for `detect`) in the compartment.
set -euo pipefail

DRY=0; ARGS=()
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1 || ARGS+=("$a"); done
set -- "${ARGS[@]}"
CMD=${1:-show}

camel='walk(if type == "object" then with_entries(select(.value != null) | .key |= (split("-") | .[0] + (.[1:] | map((.[:1] | ascii_upcase) + .[1:]) | join("")))) else . end)'

rules() { oci network security-list get --security-list-id "${OCI_SECLIST_ID:?set OCI_SECLIST_ID}" --query 'data."ingress-security-rules"' | jq "$camel"; }

port_range() { local p=$1; echo "${p%-*} ${p#*-}"; }

write() {  # $1 = new rules file
  local bdir=${XDG_CACHE_HOME:-$HOME/.cache}/oci-seclist; mkdir -p "$bdir"; chmod 700 "$bdir"
  local b; b=$(mktemp "$bdir/$OCI_SECLIST_ID-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
  rules > "$b"
  oci network security-list update --security-list-id "$OCI_SECLIST_ID" --ingress-security-rules "file://$1" --force >/dev/null
  echo "security list updated; previous rules saved in $b"
  "$0" show
}

case "$CMD" in
detect)
  IMDS=http://169.254.169.254/opc/v2
  INST=$(curl -fsS -H "Authorization: Bearer Oracle" "$IMDS/instance/id")
  VNIC=$(curl -fsS -H "Authorization: Bearer Oracle" "$IMDS/vnics/" | jq -r '.[0].vnicId')
  SUBNET=$(oci network vnic get --vnic-id "$VNIC" --query 'data."subnet-id"' --raw-output)
  echo "instance: $INST"; echo "subnet:   $SUBNET"
  oci network subnet get --subnet-id "$SUBNET" --query 'data."security-list-ids"' | jq -r '.[]' | while read -r sl; do
    echo "security list: $sl  ($(oci network security-list get --security-list-id "$sl" --query 'data."display-name"' --raw-output))"
  done
  NSG=$(oci network vnic get --vnic-id "$VNIC" --query 'data."nsg-ids"' | jq -r '.[]?')
  [ -n "$NSG" ] && echo "NSGs on the VNIC (also filter traffic!): $NSG"
  echo "export OCI_SECLIST_ID=<one of the above>"
  ;;
show)
  rules | jq -r '.[] | [ (.source), (if .protocol=="6" then "tcp" elif .protocol=="17" then "udp" elif .protocol=="1" then "icmp" elif .protocol=="58" then "icmpv6" elif .protocol=="all" then "all" else .protocol end),
        ((.tcpOptions // .udpOptions // {}).destinationPortRange // {} | if .min then (if .min==.max then "\(.min)" else "\(.min)-\(.max)" end) else "-" end),
        (.description // "") ] | @tsv' | column -t -s $'\t'
  ;;
add|remove)
  PROTO=${2:?tcp|udp}; PORTS=${3:?port}; CIDR=${4:?cidr}; DESC=${5:-"added $(date -u +%F) by oci-seclist.sh"}
  case "$PROTO" in tcp) P=6; OPT=tcpOptions ;; udp) P=17; OPT=udpOptions ;; *) echo "tcp or udp" >&2; exit 2 ;; esac
  read -r MIN MAX < <(port_range "$PORTS")
  NEW=$(mktemp); trap 'rm -f "$NEW"' EXIT
  if [ "$CMD" = add ]; then
    rules | jq --arg s "$CIDR" --arg p "$P" --arg o "$OPT" --arg d "$DESC" --argjson mn "$MIN" --argjson mx "$MAX" '
      if any(.[]; .source==$s and .protocol==$p and (.[$o].destinationPortRange.min==$mn) and (.[$o].destinationPortRange.max==$mx))
      then error("rule already exists")
      else . + [{source:$s, sourceType:"CIDR_BLOCK", protocol:$p, isStateless:false, description:$d,
                 ($o): {destinationPortRange: {min:$mn, max:$mx}}}] end' > "$NEW"
  else
    rules | jq --arg s "$CIDR" --arg p "$P" --arg o "$OPT" --argjson mn "$MIN" --argjson mx "$MAX" '
      (map(select((.source==$s and .protocol==$p and (.[$o].destinationPortRange.min==$mn) and (.[$o].destinationPortRange.max==$mx)) | not))) as $keep
      | if ($keep|length) == length then error("no such rule") else $keep end' > "$NEW"
  fi
  echo "rules after change: $(jq length "$NEW") (now: $(rules | jq length))"
  [ "$DRY" = 1 ] && { jq -c '.[] | {source, protocol, tcpOptions, udpOptions, description}' "$NEW"; echo "(dry run: nothing written)"; exit 0; }
  write "$NEW"
  ;;
*) sed -n '2,12p' "$0"; exit 2 ;;
esac
