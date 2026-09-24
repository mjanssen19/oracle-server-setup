#!/bin/bash
# cf-hostname.sh: publish, unpublish or list hostnames on a remotely managed Cloudflare Tunnel.
#
#   cf-hostname.sh list
#   cf-hostname.sh add    <hostname> <service>  [--dry-run] [--force-dns]
#   cf-hostname.sh remove <hostname>            [--dry-run]
#
#   <service> examples: http://127.0.0.1:8081   https://localhost:8443   http_status:404
#
# Env (use with-secrets.sh so the token is never typed or printed):
#   CF_API_TOKEN   account-owned token: Cloudflare Tunnel (connector) Edit + DNS Edit on the zone(s)
#   CF_ACCOUNT_ID  account id
#   CF_TUNNEL_ID   the tunnel of THIS server (check it: journalctl -u cloudflared | grep tunnelID)
#   CF_ZONE_ID     optional; looked up from the hostname if unset
#
# Why a script: PUT .../configurations REPLACES the whole ingress list, so a hand-written
# PUT with one rule silently unpublishes every other hostname. This reads the current
# config, merges, keeps the catch-all last, saves a backup, then writes, and adds/removes
# the proxied CNAME to <tunnel>.cfargotunnel.com.
# API reference (look it up if a call fails): https://developers.cloudflare.com/api/
set -euo pipefail

API=https://api.cloudflare.com/client/v4
: "${CF_API_TOKEN:?set via with-secrets.sh}" "${CF_ACCOUNT_ID:?}" "${CF_TUNNEL_ID:?}"
DRY=0; FORCE_DNS=0; ARGS=()
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; --force-dns) FORCE_DNS=1 ;; *) ARGS+=("$a") ;; esac; done
set -- "${ARGS[@]}"
CMD=${1:-list}

# token goes in a header file descriptor, never on curl's command line (ps-visible)
cf() { curl -fsS -H @<(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$CF_API_TOKEN") "$@"; }

get_config() { cf "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations"; }

zone_for() {  # longest matching zone for a hostname
  local h=$1 cand=$1 id
  [ -n "${CF_ZONE_ID:-}" ] && { echo "$CF_ZONE_ID"; return; }
  while [[ "$cand" == *.* ]]; do
    id=$(cf "$API/zones?name=$cand" | jq -r '.result[0].id // empty')
    [ -n "$id" ] && { echo "$id"; return; }
    cand=${cand#*.}
  done
  echo "no Cloudflare zone found for $h" >&2; return 1
}

put_config() {  # $1 = file with {"config": {...}}
  local bdir=${XDG_CACHE_HOME:-$HOME/.cache}/cf-hostname
  mkdir -p "$bdir"; chmod 700 "$bdir"
  get_config | jq '.result.config' > "$(mktemp "$bdir/$CF_TUNNEL_ID-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
  cf -X PUT "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations" --data @"$1" \
    | jq -e '.success' >/dev/null && echo "tunnel config updated (previous saved in $bdir)"
}

case "$CMD" in
list)
  get_config | jq -r '.result.config.ingress[]? | "\(.hostname // "*")\t\(.service)\(if .path then "\tpath=" + .path else "" end)"'
  ;;
add)
  H=${2:?hostname}; S=${3:?service}
  NEW=$(mktemp); trap 'rm -f "$NEW"' EXIT
  get_config | jq --arg h "$H" --arg s "$S" '
    (.result.config // {}) as $c
    | ($c.ingress // []) as $in
    | ($in | map(select(.hostname != null and .hostname != $h))) as $named
    | ($in | map(select(.hostname == null))) as $catch
    | {config: ($c + {ingress: ($named + [{hostname: $h, service: $s}]
                                 + (if ($catch | length) == 0 then [{service: "http_status:404"}] else $catch end))})}' > "$NEW"
  echo "new ingress:"; jq -r '.config.ingress[] | "  \(.hostname // "*")\t\(.service)"' "$NEW"
  Z=$(zone_for "$H")
  REC=$(cf "$API/zones/$Z/dns_records?name=$H" | jq -c '.result[0] // empty')
  TARGET="$CF_TUNNEL_ID.cfargotunnel.com"
  if [ -n "$REC" ] && [ "$(jq -r .content <<<"$REC")" != "$TARGET" ] && [ "$FORCE_DNS" != 1 ]; then
    echo "DNS: $H already exists as $(jq -r '.type + " " + .content' <<<"$REC"). Not touching it; use --force-dns to repoint." >&2
    exit 1
  fi
  [ "$DRY" = 1 ] && { echo "(dry run: nothing written)"; exit 0; }
  put_config "$NEW"
  BODY=$(jq -nc --arg n "$H" --arg c "$TARGET" '{type:"CNAME", name:$n, content:$c, proxied:true}')
  if [ -z "$REC" ]; then
    cf -X POST "$API/zones/$Z/dns_records" --data "$BODY" | jq -e .success >/dev/null && echo "DNS: CNAME $H -> $TARGET created"
  elif [ "$(jq -r .content <<<"$REC")" != "$TARGET" ]; then
    cf -X PUT "$API/zones/$Z/dns_records/$(jq -r .id <<<"$REC")" --data "$BODY" | jq -e .success >/dev/null && echo "DNS: $H repointed to $TARGET"
  else
    echo "DNS: $H already points to this tunnel"
  fi
  echo "check: curl -s -o /dev/null -w '%{http_code}\\n' https://$H/"
  ;;
remove)
  H=${2:?hostname}
  NEW=$(mktemp); trap 'rm -f "$NEW"' EXIT
  get_config | jq --arg h "$H" '(.result.config // {}) as $c | {config: ($c + {ingress: [($c.ingress // [])[] | select(.hostname != $h)]})}' > "$NEW"
  echo "new ingress:"; jq -r '.config.ingress[] | "  \(.hostname // "*")\t\(.service)"' "$NEW"
  Z=$(zone_for "$H")
  REC=$(cf "$API/zones/$Z/dns_records?name=$H" | jq -c '.result[0] // empty')
  [ "$DRY" = 1 ] && { echo "(dry run: nothing written)"; exit 0; }
  put_config "$NEW"
  if [ -n "$REC" ] && [ "$(jq -r .content <<<"$REC")" = "$CF_TUNNEL_ID.cfargotunnel.com" ]; then
    cf -X DELETE "$API/zones/$Z/dns_records/$(jq -r .id <<<"$REC")" | jq -e .success >/dev/null && echo "DNS: $H removed"
  else
    echo "DNS: left as is (no record, or it doesn't point to this tunnel)"
  fi
  ;;
*) sed -n '2,9p' "$0"; exit 2 ;;
esac
