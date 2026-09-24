# Running workloads safely

## The binding rule
| Who should reach it | Bind to | Published how |
|---|---|---|
| The internet | `127.0.0.1:<port>` | Cloudflare Tunnel ingress |
| Specific people on the internet | `127.0.0.1:<port>` | Tunnel + **Cloudflare Access** |
| The operator only | `127.0.0.1:<port>` | `tailscale serve`, or SSH port-forward |
| Other servers on the tailnet (metrics, APIs) | `127.0.0.1` + `tailscale serve --tcp`, or the Tailscale IP with `Restart=always` | tailnet ACL grant |
| Nobody (internal to the box) | `127.0.0.1` or a unix socket | none |

`0.0.0.0` or `[::]` is **never** the answer on a VPS. Audit it after every
deployment:

```bash
sudo ss -tulpn | grep -vE '127\.0\.0\.|\[::1\]|%lo|100\.|fd7a:'
```

alfred findings, which serve as examples of what the audit catches:
- a Next.js app on `*:3000`
- Portainer on `0.0.0.0:8000/9443`
- rpcbind on `0.0.0.0:111`

None of them was reachable, but only because the Security List held.

## Docker

**Docker bypasses the host firewall.** It writes its own NAT/FORWARD rules, so
a `-p 8080:8080` container is reachable from wherever the packet arrives,
whatever INPUT says.

0. **Publishing on the Tailscale IP** (`100.x.y.z:9090:9090`, for tailnet-only
   dashboards) needs a boot-order drop-in. docker-proxy can't bind an address
   that doesn't exist yet, and a failed bind at start is **not** retried by
   the restart policy. alfred has
   `/etc/systemd/system/docker.service.d/10-wait-tailscale.conf`:
   ```ini
   [Unit]
   After=tailscaled.service
   Wants=tailscaled.service

   [Service]
   # wait up to 60s for tailscale0; "-" = Docker still starts if Tailscale is down
   ExecStartPre=-/bin/sh -c 'for i in $(seq 1 60); do ip -4 addr show dev tailscale0 2>/dev/null | grep -q "inet 100\." && exit 0; sleep 1; done; exit 0'
   ```
   Then run `sudo systemctl daemon-reload`. It takes effect at the next Docker
   start; don't restart Docker just for this.
1. **Publish on loopback** by default:
   ```yaml
   ports:
     - "127.0.0.1:8080:8080"      # yes
   # - "8080:8080"                # no: 0.0.0.0 and [::]
   ```
2. **Add a DOCKER-USER chain** as the second layer (`templates/docker-firewall.sh`
   and `docker-firewall.service`, run after docker starts). It allows
   established traffic, container-to-container traffic and the tailnet, then
   **drops** everything from the public interface, IPv4 and IPv6.
3. Install from Docker's apt repo (`get.docker.com` is fine for a first
   install). The repo is **codename-pinned**, so fix it after a release upgrade.
4. The `docker` group equals root. Only the admin belongs in it. Remove stale
   members (lurch still had `netdata` there after Netdata was removed).
5. Check image architectures on ARM: `docker manifest inspect <image> | jq '.manifests[].platform'`.
   Some images are amd64-only; alfred had to build `nuq-postgres` locally.
6. Put a DB behind named volumes and back it up with a dump, not by copying
   the volume while it runs.
7. **Portainer** is optional. If used, bind it to loopback/tailnet, and
   upgrade it with a runbook:
   - tar the volume first
   - rename the old container rather than removing it
   - verify the InstanceID afterwards
   - keep Watchtower off it (anonymous volumes wipe the DB)

## Native services (Node, Python, Go)

**Tailnet-only Node app under PM2** (alfred's Command Center, 2026-09-23). Bind
it to the Tailscale IP, and let PM2 retry until that IP exists at boot:
```js
// ecosystem.config.js
{ name: 'command-center', script: 'node_modules/.bin/next',
  args: 'start -H 100.x.y.z -p 3000',      // was `start` → listened on *:3000
  restart_delay: 5000, max_restarts: 100 }  // PM2's default (16 quick restarts) gives up before tailscaled is up
```
Then:
1. `pm2 delete <app> && pm2 start ecosystem.config.js && pm2 save`
2. Check with `ss -tlnp | grep :3000`: it should show the 100.x address only.

First check which env vars the app gets. The PM2 dump holds the env of the
shell it was started from, and Next.js loads `.env.production` itself.

For new services, prefer a systemd unit
(`reference/systemd-service-hardening.md`):
- one system user per service
- code owned by root and read-only
- `ProtectSystem=strict` and `ReadWritePaths` for the rest
- secrets in `EnvironmentFile=` (`0640 root:<svc>`)
- aim for `systemd-analyze security` under 3.0

For secrets on production boxes, numbersgamearm01 goes further:
- env files are GPG-encrypted at rest
- one key is fetched at boot from **OCI Vault** using the **instance
  principal**, so no credential sits on disk
- they are decrypted into tmpfs `/run/<app>/`
- the units **fail closed** if decryption fails

This is worth it once customer data is involved. For a personal server,
`0640` files are enough; record the decision in the log.

## Untrusted code: CI runners, AI agents, anything that runs other people's code
- Run it as an **unprivileged user** (no sudo) with **rootless podman**,
  `loginctl enable-linger`, and systemd *user* units.
- **Never mount the Docker socket.** It is root-equivalent. If jobs need
  service containers, give that user its **own rootless dockerd**; the ceiling
  is then an unprivileged account.
- Keep it **off the box that holds production secrets.** alfred runs CI for
  numbersgamearm01 for exactly this reason. It also matches production's
  aarch64 architecture, which is a free bonus.
- AI agent hosts (alfred: OpenClaw and Hermes) have tokens for chat platforms
  and model APIs.
  - Bind their gateways to loopback.
  - Publish dashboards only over `tailscale serve`.
  - Allow-list who may talk to them (for example, a Telegram owner ID and
    `requireMention` in groups).

## Web servers
- **Static sites:** nginx or Caddy on `127.0.0.1:<port>`, plain HTTP, behind
  the tunnel. There is no certificate to manage.
- **nginx gotcha:** changing a `listen` from wildcard to `127.0.0.1` on the
  same port needs a **restart**, not a reload. The old workers keep the
  wildcard socket, bind fails with EADDRINUSE, and nginx silently keeps the old
  config. Check `/var/log/nginx/error.log` and `ss -tlnp` afterwards.
- **Caddy direct (grey-cloud):**
  - It needs 80/443 TCP (plus UDP 443 for HTTP/3) in both firewalls.
  - Add a `(security_headers)` snippet and `-Server`.
  - Add a `Restart=on-failure` drop-in; the package unit ships `Restart=no`.
  - Never bind a Tailscale IP.
  - Keep the Caddyfile in a repo with a `--check` deploy script.

## Databases
- PostgreSQL:
  - `listen_addresses = 'localhost'`
  - `pg_hba` uses peer locally and scram-sha-256 on 127.0.0.1/::1
  - one role per app
  - Tables created by hand as `postgres` don't inherit the app role's
    grants. That broke `pg_dump` for 15 days on numbersgamearm01. Use
    `ALTER DEFAULT PRIVILEGES`.
- Major-version upgrades are manual. Hold the package, or move to the PGDG
  repo before an OS release upgrade.
