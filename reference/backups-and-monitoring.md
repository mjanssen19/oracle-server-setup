# Backups and alerting

Two layers, and every server gets both:

| Layer | Covers | Target | Schedule | Use it when |
|---|---|---|---|---|
| **A. Full disk** | the entire boot volume (and attached block volumes) | **Oracle** volume backups, through a backup policy | weekly incremental, keep 4, plus a manual one before risky work | an upgrade or config change wrecked the box: restore the whole machine |
| **B. Config and data files** | `/etc`, service configs, app data, web roots, `/usr/local`, DB dumps | **Cloudflare R2** through restic, encrypted on the server | daily 02:00 UTC, 7 daily / 4 weekly / 6 monthly | one file or app needs to come back, or the Oracle account or region is gone |

Layer A is quick and complete, but it sits in the same tenancy and region as
the server. Layer B is the offsite copy: small, file-level, zero egress cost to
restore. alfred started with Layer A only. lurch had Layer B only. Neither
alone covers both failure types.

---

## Layer A: Oracle full-disk backup schedule

These commands run on the laptop, using the Phase 1 CLI session. The console
path is given with each step.

### A.1 Find the boot volume

```bash
C=<compartment ocid>; INSTANCE=<instance ocid>
AD=$(oci compute instance get --instance-id "$INSTANCE" --query 'data."availability-domain"' --raw-output)
BV=$(oci compute boot-volume-attachment list -c "$C" --availability-domain "$AD" --instance-id "$INSTANCE" \
       --query 'data[0]."boot-volume-id"' --raw-output)
```

Console: Compute → Instances → *instance* → Boot volume.

### A.2 Create a custom policy: weekly incremental, keep 4 weeks

Always Free includes **5 volume backups in total**. Weekly with 4 retained
leaves one slot for a manual backup before risky work. Oracle's built-in
policies don't fit that budget:
- Bronze: monthly, kept 12 months
- Silver: weekly plus monthly
- Gold: daily

```bash
POLICY=$(oci bv volume-backup-policy create -c "$C" --display-name "weekly-keep-4" \
  --schedules '[{"backupType":"INCREMENTAL","period":"ONE_WEEK","dayOfWeek":"SUNDAY",
                 "hourOfDay":1,"offsetType":"STRUCTURED","timeZone":"UTC",
                 "retentionSeconds":2419200}]' \
  --query data.id --raw-output)
```

`retentionSeconds` 2419200 is 28 days. Sunday 01:00 UTC keeps it clear of the
02:00 restic run and the 04:00 patch/reboot.

Console: Storage → Block Storage → **Backup Policies** → Create:
- Add schedule → Weekly, Incremental, Sunday, 01:00, UTC.
- Retention: 4 weeks.

If the CLI rejects a field, check `oci bv volume-backup-policy create --help`
for the current schedule schema.

### A.3 Assign it to the boot volume, plus any block volumes

```bash
oci bv volume-backup-policy-assignment create --asset-id "$BV" --policy-id "$POLICY"
oci bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment --asset-id "$BV" \
  --query 'data[0]."policy-id"' --raw-output          # must print $POLICY
```

Console: Boot volume → **Edit** → Backup policy → *weekly-keep-4* → Save.

**One policy per volume.** Assigning a new one replaces the old.

### A.4 Manual backup: now, and before every risky change
Risky changes include a release upgrade, a firewall rewrite or a large
migration.

```bash
oci bv boot-volume-backup create --boot-volume-id "$BV" --type INCREMENTAL \
  --display-name "manual-$(date +%F)-before-<what>" --wait-for-state AVAILABLE
oci bv boot-volume-backup list -c "$C" --boot-volume-id "$BV" \
  --query 'data[].{name:"display-name",created:"time-created",state:"lifecycle-state",type:type}' --output table
```

- Manual backups are **not** deleted by the policy. Remove old ones yourself
  to stay within the 5 free backups.
- Backups are crash-consistent, like pulling the power. For a database box,
  either stop the DB for a minute or rely on Layer B's dump for the data.

### A.5 Restore: the whole machine
1. Boot volume backups → *backup* → **Create boot volume**. Use the same AD
   and compartment.
2. Then either:
   - **Create instance** from that boot volume (Compute → Create instance →
     Change image → Boot volumes), or
   - stop the old instance, detach its boot volume and attach the restored
     one.
3. The new instance has a **new public IP**. Tailscale and the Cloudflare
   Tunnel don't care, because both connect outbound. That's another reason
   they are the only ways in.
4. If both the old and the restored machine run at once, they fight over the
   same Tailscale node key and tunnel. Keep only one running.

Practise it once per server (for example, restore into a throwaway instance
and log in over the serial console), then delete the test resources.

---

## Layer B: restic to Cloudflare R2 (config and data files)

### B.1 Bucket and key
Created in Phase 1 (`accounts-and-api-keys.md`):
- one bucket per server
- an R2 API token with **Object Read & Write on that bucket only**

Values go straight into the password manager and into the file below.
They never go into chat or docs.

### B.2 Install and initialise (server)

```bash
sudo apt-get install -y restic
sudo install -d -m 700 /etc/restic
sudo install -m 600 /dev/null /etc/restic/env
sudoedit /etc/restic/env
```

With 1Password, don't edit the file by hand. Inject it from a template of
`op://` references (`ssh-keys-and-1password.md` §5):
`op inject -i restic.env.tpl | ssh <server> 'sudo sh -c "umask 077; cat > /etc/restic/env"'`.

Otherwise, `/etc/restic/env` (every value from the password manager):

```sh
RESTIC_REPOSITORY=s3:https://<r2-endpoint-host>/<bucket>
RESTIC_PASSWORD=<long random: openssl rand -base64 32>
AWS_ACCESS_KEY_ID=<R2 access key id>
AWS_SECRET_ACCESS_KEY=<R2 secret>
AWS_DEFAULT_REGION=auto
```

The endpoint host is shown on the bucket's settings page as the "S3 API"
URL. Copy it from there; don't type it into docs.

```bash
sudo bash -c 'set -a; . /etc/restic/env; set +a; restic init'
```

### B.3 Choose what to back up
The point is **configuration and small data**. The OS itself comes back from
Layer A or a fresh install. Start from `PATHS` in
`templates/restic-backup.sh`, then add this server's app directories from
the Phase 0 component list.

| Include | Examples |
|---|---|
| system config | `/etc` (sshd, nginx, cloudflared unit, systemd units, sysctl, fail2ban, iptables rules), `/usr/local` (scripts) |
| app config and state | `/opt/<app>`, compose directories, `~/.config/<app>`, agent workspaces such as `~/.openclaw` and `~/.hermes` on alfred |
| web roots | `/var/www` |
| databases | **dumps** in `/var/backups/db/` (the script creates them); never live DB files |
| home | `/home/<admin>`, excluding caches, `node_modules` and downloads |

| Exclude | Why |
|---|---|
| `/etc/restic` | its secrets live in the password manager |
| caches, `node_modules`, build output, CI `_work` dirs, container images | rebuildable, and large |
| media, downloads | not config (put them in a separate repo if they matter) |

### B.4 Schedule and verify

```bash
sudo install -m 750 templates/restic-backup.sh /usr/local/sbin/restic-backup.sh
sudo install -m 644 templates/restic-backup.service templates/restic-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now restic-backup.timer
sudo systemctl start restic-backup.service && tail -30 /var/log/restic-backup.log
sudo bash -c 'set -a; . /etc/restic/env; set +a; restic snapshots'
```

**Restore test** (at setup, then quarterly):

```bash
sudo bash -c 'set -a; . /etc/restic/env; set +a; restic restore latest --target /tmp/restore-test --include /etc/ssh'
sudo diff -r /etc/ssh /tmp/restore-test/etc/ssh && echo "restore OK"; sudo rm -rf /tmp/restore-test
```

For a full rebuild on a *new* server:
1. Install restic.
2. Recreate `/etc/restic/env` from the password manager.
3. Run `restic restore latest --target /restore`.
4. Copy back what you need.

This works even if the Oracle account is gone.

### Rules learned the hard way
- **The repo password is not backed up by the backup.** Keep it in the
  password manager, or the R2 copy is noise.
- **An untested backup is a hope.** Write every restore test into the setup
  log.
- **Alert on the absence of success, not only on failure.**
  numbersgamearm01's backups failed for 15 days while cron `MAILTO` went to a
  box with no MTA. A Healthchecks.io check with a 1-day period and a 2-hour
  grace catches that.
- A cron `>>` redirect target the job can't write kills the job silently.
  Systemd timers and the journal avoid this.
- World-readable ad-hoc backups leak secrets. lurch had a 644 Portainer
  tarball containing stack env. Use `umask 077`.
- Never back up a live database directory. Dump it (Postgres: `pg_dump -Fc`;
  MariaDB: `mariadb-dump`).

## Alerting endpoints
`templates/notify.sh` reads `/etc/server-notify.env` (`0600 root`):

```sh
NTFY_URL=https://ntfy.sh/<unguessable-topic>
HC_PATCH_URL=https://hc-ping.com/<uuid>
HC_BACKUP_URL=https://hc-ping.com/<uuid>
```

Usage: `notify.sh "message"` sends a push. Scripts ping `HC_*_URL` on
success and `"$HC_URL/fail"` on failure.

- **No MTA.** A VPS has no working mail relay, and port 25 egress is blocked
  on most clouds. `MAILTO` and `Unattended-Upgrade::Mail` therefore do
  nothing. Use HTTP APIs: ntfy, Healthchecks, Slack webhooks, or Resend for
  email.
- Send a test from each script path once, and check it arrives on the phone.
- **Jobs you didn't write** (or don't want to edit): attach `templates/notify-failure@.service`
  through a drop-in, so any failure of that unit pushes a message with its last log lines:
  ```bash
  sudo install -m 644 templates/notify-failure@.service /etc/systemd/system/
  for u in restic-backup nightly-patch <other-jobs>; do
    sudo mkdir -p /etc/systemd/system/$u.service.d
    printf '[Unit]\nOnFailure=notify-failure@%%n.service\n' | sudo tee /etc/systemd/system/$u.service.d/10-notify.conf >/dev/null
  done
  sudo systemctl daemon-reload
  sudo systemd-run --unit=notify-test -p OnFailure=notify-failure@notify-test.service.service /bin/false   # test
  ```
  This only works if the job's script exits non-zero on failure (`set -euo pipefail`). lurch uses it for its
  nightly-update, restic, Pi-hole, media-permissions and docker-firewall units.
- **Several servers, one topic:** give each its own `NOTIFY_NAME`, so the phone shows which box is talking.

## Monitoring (optional, scale to taste)
- **Minimum:**
  - Healthchecks for the timers.
  - An **external** uptime probe of each public URL: Healthchecks, Better
    Stack or UptimeRobot free tiers, or Uptime Kuma on the home server. It must
    run from *outside* the box. A probe on the serving host passes while DNS,
    the edge or the tunnel is broken, which is exactly when every real user is
    down.
- **Fleet (alfred's design):**
  - Prometheus, Alertmanager, Grafana and Blackbox on one hub.
  - `node_exporter` on each server, exposed on the tailnet only.
  - `file_sd` target files, one per host.
  - Blackbox probes public hostnames from the hub, with `served_by` labels.
  - Alerts go to Slack or ntfy.
  - Upgrade the hub **last** during fleet OS upgrades, so you're never blind.
  - **Watch the watcher.** alfred's Alertmanager stopped in a reboot on
    2026-08-17 and stayed down for 5 weeks. Nothing noticed, because the only
    alerting path was the thing that was down. Two cheap guards:
    - `restart: unless-stopped` on every monitoring container, and a check
      after each reboot that all of them are up.
    - An always-firing **Watchdog** rule routed to a Healthchecks.io check:
      `expr: vector(1)` → Alertmanager `webhook_configs` to the check's ping URL
      with `send_resolved: false` and `repeat_interval: 5m`. When
      Prometheus, Alertmanager or the route dies, the pings stop and
      Healthchecks emails you.
- Uptime Kuma with **zero monitors** is not monitoring. That was lurch's
  state: installed, never configured. Add the monitors and a notification
  target, or remove it.
