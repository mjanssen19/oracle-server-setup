#!/bin/bash
# /usr/local/sbin/restic-backup.sh  (root:root 0750). Run by restic-backup.timer.
# Layer B: encrypted offsite backup of config and data files to Cloudflare R2.
# (Layer A, the full disk, is the Oracle boot volume backup policy. See reference/backups-and-monitoring.md.)
#
# /etc/restic/env (0600 root). Every value is also in the owner's password manager:
#   RESTIC_REPOSITORY=s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>
#   RESTIC_PASSWORD=...            # without this the backup is unreadable. Keep it OFF this box too.
#   AWS_ACCESS_KEY_ID=...          # R2 token scoped to this ONE bucket, Object Read & Write
#   AWS_SECRET_ACCESS_KEY=...
#   AWS_DEFAULT_REGION=auto
#
# Lessons: lurch had no `restic check` and no failure alert. numbersgamearm01 went 15 days
# without a backup and nobody knew. Hence: dump DBs first, check weekly, ping on success,
# alert on failure.
set -Eeuo pipefail
umask 077
exec >>/var/log/restic-backup.log 2>&1

set -a; . /etc/restic/env; set +a
# shellcheck disable=SC1091
[ -r /etc/server-notify.env ] && . /etc/server-notify.env
HC_URL=${HC_BACKUP_URL:-}
ping_hc() { [ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 "$HC_URL$1" >/dev/null || true; }
trap 'echo "FAILED line $LINENO"; /usr/local/sbin/notify.sh "restic backup FAILED on $(hostname) (line $LINENO)" || true; ping_hc /fail' ERR

# ---- adjust per server --------------------------------------------------------
# Config and small data only: the whole disk is covered by the Oracle boot volume policy (Layer A).
# Add app dirs from the Phase 0 component list, e.g. compose dirs, /opt/<app>, agent workspaces.
# Docker named volumes with app state: add /var/lib/docker/volumes/<name> explicitly (never DB volumes; dump those).
PATHS=(/etc /usr/local /opt /srv /var/www /root /home /var/backups/db)
EXCLUDES=(--exclude /etc/restic --exclude /etc/agent/secrets.keyx --exclude '/home/*/.cache' --exclude '/home/*/.npm' \
          --exclude '/root/.cache' --exclude '*/node_modules' --exclude '*/_work' --exclude '/home/*/Downloads' \
          --exclude '/home/*/snap')
# -------------------------------------------------------------------------------

echo "=== $(date -u '+%F %T')Z start ==="
ping_hc /start

# 1. Database dumps: never back up live DB files
install -d -m 700 /var/backups/db
if command -v pg_dumpall >/dev/null && systemctl is-active --quiet postgresql; then
  for db in $(sudo -u postgres psql -Atc "select datname from pg_database where not datistemplate"); do
    sudo -u postgres pg_dump -Fc "$db" > "/var/backups/db/$db.dump"
  done
  sudo -u postgres pg_dumpall --globals-only > /var/backups/db/globals.sql
fi
# Docker DBs: add e.g.  docker exec nextcloud-db mariadb-dump --all-databases -uroot -p"$X" > /var/backups/db/nextcloud.sql

# 2. Backup (only paths that exist)
existing=(); for p in "${PATHS[@]}"; do [ -e "$p" ] && existing+=("$p"); done
restic backup --one-file-system --exclude-caches "${EXCLUDES[@]}" --tag "$(hostname)" --compression max "${existing[@]}"

# 3. Retention
restic forget --tag "$(hostname)" --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# 4. Integrity: read a sample of the data weekly (Sunday)
[ "$(date +%u)" = 7 ] && restic check --read-data-subset=5%

echo "=== $(date -u '+%F %T')Z done ==="
ping_hc ""
