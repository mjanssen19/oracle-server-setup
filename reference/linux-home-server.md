# Linux home server (lurch pattern)

This is for a Linux box at home, behind NAT, on the LAN. It differs from the
VPS in these ways:
- **UFW** is fine here. There is no Oracle image ruleset to protect.
- There is a trusted **LAN** (192.168.x.0/24) as well as the tailnet.
- The Cloudflare Tunnel runs on the box, and apps see the **box's LAN IP** as
  the client.

Lurch: Ubuntu 26.04, x86_64, Pi-hole, Caddy plus mkcert `*.lurch.home`, an
*arr media stack, Home Assistant, Nextcloud, UniFi OS, and restic to a local
HDD plus R2.

## Firewall: UFW plus DOCKER-USER

```bash
sudo ufw default deny incoming && sudo ufw default allow outgoing
sudo ufw allow in on <lan-if> from 192.168.1.0/24 to any port 22 proto tcp comment 'SSH LAN'
sudo ufw allow in on tailscale0 to any port 22 proto tcp comment 'SSH tailnet'
sudo ufw allow 41641/udp comment 'Tailscale direct'
sudo ufw enable && sudo ufw status numbered
```

- **Every rule gets a source and a comment.** Lurch drifted:
  - `8090` was open on the LAN interface from any source
  - `11443` and `8080` were open to *Anywhere*, with no comment, "because the
    router doesn't forward them"
  - The router is then the only control. Keep the host rule itself narrow.
- Docker bypasses UFW. Use `templates/docker-firewall.sh` with `LAN_CIDR`
  set. Host-network containers (Caddy, Home Assistant) *are* covered by UFW
  instead.
- The only intentional public port on lurch is Plex `32400`, forwarded by the
  router. Everything public is otherwise the tunnel.

## SSH
- OpenSSH is limited to LAN plus tailnet, and Tailscale SSH is on.
- Remove the user from `lxd` with `sudo gpasswd -d <user> lxd`. The old guide
  said `gdeluser`, which doesn't exist.

## Cloudflare Tunnel from home
- Install the connector the standard way (`cloudflared service install <token>`; see cloudflare.md 4.3). Keep its update timer on.
  Lurch was reinstalled this way on 2026-09-23. The token is now in `/etc/cloudflared/token`, not in the unit.
- Ingress targets `http://192.168.1.2:<port>` or `127.0.0.1:<port>`.
- The apps see `192.168.1.2`:
  - Set their trusted proxies.
  - fail2ban can't ban tunnel users.
  - Put Access on anything not meant for everyone. Lurch's `cloud.`
    (Nextcloud) has no Access policy and no rate limit yet.

## Local DNS and HTTPS: Pi-hole plus Caddy plus mkcert
1. **Pi-hole v6, native install.**
   - Move its web UI off port 80 so Caddy can use it: in
     `/etc/pihole/pihole.toml`, set `webserver.port = "8090"`.
   - Set `misc.etc_dnsmasq_d = true`.
   - Set `dns.interface` to the **real** NIC name. Lurch's was left as `end0`
     while the NIC is `eno1`.
   - Updates come from `pihole -up` on its own weekly timer. apt doesn't know
     about it, and a restart takes DNS down.
2. **Wildcard DNS:** create `/etc/dnsmasq.d/99-local.conf` containing
   `address=/.<name>.home/192.168.1.2`.
3. **mkcert:**
   - Run `mkcert -install && mkcert "*.<name>.home"`. The cert is valid about
     2 years, so put the expiry in the log.
   - Distribute `rootCA.pem` to devices (macOS: Keychain → Always Trust; iOS:
     install the profile, then enable it under About → Certificate Trust).
   - Keep the key file at mode 600.
4. **Caddy** in Docker with `network_mode: host`, `admin off`, and a `(tls)`
   snippet with the mkcert files.
   - `http://` redirects `*.name.home` to https, and a bare IP goes to the
     dashboard.
   - Deploy Caddy through the direct port, not through its own proxy.
5. **Per-app proxy settings:**
   - Home Assistant: `trusted_proxies`
   - SABnzbd: `host_whitelist` + `verify_xff_header=0`
   - Homepage: `HOMEPAGE_ALLOWED_HOSTS`
   - Nextcloud: `TRUSTED_PROXIES` and `trusted_domains`
   - HTTPS upstreams (Portainer, UniFi) use `tls_insecure_skip_verify`.
6. **Tailscale DNS:** a Pi-hole as the tailnet's global nameserver gives every
   device ad-blocking plus `*.name.home` resolution. It also makes every
   device depend on this one box.

## Media stack notes (from lurch)
| Service | Port | Note |
|---|---|---|
| Plex | 32400 | the only intentionally public port; prefer MKV (moov-at-end MP4 causes seek storms) |
| Sonarr / Radarr / Bazarr / Prowlarr | 8989 / 7878 / 6767 / 9696 | Prowlarr is the single indexer source; use container names on the shared compose network |
| SABnzbd / qBittorrent | 8383 / 8180 (+6881 peers, public via DOCKER-USER) | the incomplete dir must be owned by PUID; config paths must match mount points exactly |
| Seerr | 5055 | public via tunnel for Plex OAuth |
| Homepage | 3000 | a mount change needs `compose up -d`, not a restart |

- `PUID/PGID=1000` and `UMASK=002` go in the **compose file**. Changes made
  only in the Portainer UI are lost when the container is recreated.
- Use setgid on every media directory, plus a nightly self-healing timer that
  **logs drift before fixing it**. Recurring permission bugs had three
  separate causes on lurch.
- Watchtower: exclude stateful apps (Portainer, Nextcloud, databases) with the
  `com.centurylinklabs.watchtower.enable=false` label.

## Home Assistant
Run it with `network_mode: host` for mDNS/SSDP discovery. UFW then protects it
directly. Allow `8123` from the LAN plus the tailnet. `privileged: true` is
only needed for USB radios; drop it otherwise.

## Monitoring
- Scrutiny for SMART. NVMe needs `SYS_ADMIN`, not just `SYS_RAWIO`.
- Uptime Kuma: configure monitors **and** a notification, or remove it.
- Netdata was removed on 2026-07-14: heavy CPU use and not used. When removing
  a service, remove *everything*: packages, UFW rules, the proxy vhost, the
  backup path, **and group memberships** (the `netdata` user stayed in
  `docker`).

## Hardware lessons
- USB disks: check UAS vs BOT. Set APM through a **udev rule**, because the
  Debian hdparm hook ignores USB devices. Always **unmount before resetting**
  a USB device.
- ExFAT has no Unix permissions. With Samba you need `force user`. Keep
  `nofail,x-systemd.device-timeout=5` in fstab so boot doesn't hang if the disk
  is missing.
