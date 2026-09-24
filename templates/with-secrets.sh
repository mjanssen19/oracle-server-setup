#!/bin/bash
# with-secrets.sh <map-file> -- <command> [args...]
#
# Run a command with secrets in its environment, fetched at the moment of use
# from wherever this machine keeps them, so scripts and agents never need to
# know (or print) the values. Works the same on the operator's Mac and on the VPS.
#
# map-file (not secret itself: it holds references, mode 644 is fine), one per line:
#   CF_API_TOKEN=op://Server-alfred/cloudflare-automation/credential      # 1Password (op CLI)
#   CF_API_TOKEN=ocivault:ocid1.vaultsecret.oc1...                        # OCI Vault via instance principal
#   CF_API_TOKEN=file:/etc/agent/cloudflare-token                         # root-only file (0600)
#   CF_API_TOKEN=kpxc:cloudflare-automation                               # KeePassXC entry (Password attribute)
#   RESTIC_PASSWORD=kpxc:restic-repository#Password                       # KeePassXC entry, explicit attribute
#   CF_API_TOKEN=bw:cloudflare-automation                                 # Bitwarden/Vaultwarden item password (bw CLI, needs BW_SESSION)
#   CF_API_TOKEN=pass:agent/cloudflare-automation                         # pass (GPG) entry, first line
#   CF_ACCOUNT_ID=4f0c...                                                 # plain value (IDs are not secret)
#   # comments and blank lines are ignored
#
# Examples:
#   with-secrets.sh ~/.config/agent/cloudflare.map -- cf-hostname.sh list
#   sudo with-secrets.sh /etc/agent/cloudflare.map -- cf-hostname.sh add blog.example.com http://127.0.0.1:8081
#
# KeePassXC settings (defaults suit a server "machine vault"):
#   KPXC_DB=/etc/agent/secrets.kdbx   KPXC_KEY=/etc/agent/secrets.keyx   (both 0600 root)
#   KPXC_PASSWORD_CMD="security find-generic-password -w -s kpxc-agent"   (Mac: DB password from the Keychain)
#   Without KPXC_PASSWORD_CMD the database is opened with the key file only (--no-password).
#
# Never echo the values; this script doesn't either. OCI Vault output field is
# data."secret-bundle-content".content (base64). If the CLI changes, check
# `oci secrets secret-bundle get --help` and adjust.
set -euo pipefail

[ $# -ge 3 ] && [ "$2" = "--" ] || { echo "usage: $0 <map-file> -- <command> [args...]" >&2; exit 2; }
MAP=$1; shift 2
[ -r "$MAP" ] || { echo "cannot read map file $MAP" >&2; exit 2; }

while IFS= read -r line || [ -n "$line" ]; do
  line=${line%%#*}; line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  [ -z "$line" ] && continue
  var=${line%%=*}; ref=${line#*=}
  [[ "$var" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "bad variable name in $MAP: $var" >&2; exit 2; }
  case "$ref" in
    op://*)
      val=$(op read "$ref") || { echo "op read failed for $var" >&2; exit 1; } ;;
    ocivault:*)
      val=$(oci secrets secret-bundle get --secret-id "${ref#ocivault:}" --auth "${OCI_CLI_AUTH:-instance_principal}" \
              --query 'data."secret-bundle-content".content' --raw-output | base64 -d) \
        || { echo "OCI Vault read failed for $var" >&2; exit 1; } ;;
    kpxc:*)
      e=${ref#kpxc:}; attr=Password; [[ "$e" == *#* ]] && { attr=${e##*#}; e=${e%#*}; }
      db=${KPXC_DB:-/etc/agent/secrets.kdbx}; key=${KPXC_KEY:-/etc/agent/secrets.keyx}
      kargs=(show -q -s -a "$attr"); [ -f "$key" ] && kargs+=(-k "$key")
      if [ -n "${KPXC_PASSWORD_CMD:-}" ]; then
        val=$(sh -c "$KPXC_PASSWORD_CMD" | keepassxc-cli "${kargs[@]}" "$db" "$e") || { echo "KeePassXC read failed for $var" >&2; exit 1; }
      else
        val=$(keepassxc-cli "${kargs[@]}" --no-password "$db" "$e" </dev/null) || { echo "KeePassXC read failed for $var" >&2; exit 1; }
      fi ;;
    bw:*)
      [ -n "${BW_SESSION:-}" ] || { echo "bw: unlock first (export BW_SESSION=\$(bw unlock --raw))" >&2; exit 1; }
      val=$(bw get password "${ref#bw:}") || { echo "bw read failed for $var" >&2; exit 1; } ;;
    pass:*)
      val=$(pass show "${ref#pass:}" | head -n1) || { echo "pass read failed for $var" >&2; exit 1; } ;;
    file:*)
      f=${ref#file:}
      perms=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")
      case "$perms" in 600|400) ;; *) echo "refusing $f: mode $perms, expected 600 or 400" >&2; exit 1 ;; esac
      val=$(<"$f") ;;
    *)
      val=$ref ;;
  esac
  [ -n "$val" ] || { echo "empty value for $var" >&2; exit 1; }
  export "$var=$val"
done < "$MAP"
unset val line ref

exec "$@"
