#!/bin/bash
# /usr/local/sbin/notify.sh "message"  (root:root 0750)
# Push a message to the owner's phone via ntfy. Config: /etc/server-notify.env (0600 root)
#   NTFY_URL=https://ntfy.sh/<unguessable-topic>
#   NOTIFY_NAME=<short server name>             # message title; defaults to hostname
#   HC_PATCH_URL=https://hc-ping.com/<uuid>      # used by nightly-patch.sh
#   HC_BACKUP_URL=https://hc-ping.com/<uuid>     # used by restic-backup.sh
# There is no MTA on the server, so do not rely on MAILTO or unattended-upgrades mail.
set -u
# shellcheck disable=SC1091
[ -r /etc/server-notify.env ] && . /etc/server-notify.env
msg=${1:-"(no message)"}
logger -t notify -- "$msg"
[ -n "${NTFY_URL:-}" ] || exit 0
curl -fsS -m 10 --retry 2 -H "Title: ${NOTIFY_NAME:-$(hostname)}" -H "Tags: warning" -d "$msg" "$NTFY_URL" >/dev/null \
  || logger -t notify -- "ntfy send failed"
