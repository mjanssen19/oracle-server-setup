# Tailscale: the admin and internal plane

> **Click paths are unverified.** The console and dashboard steps in this file were written
> from memory and haven't been checked click by click. If a label doesn't match, look it up in
> the vendor docs; don't guess. CLI and API commands are more stable, but check `--help` too.

## Model
- **Every** admin path and internal-only service goes over the tailnet.
- The server is a **tagged** node (`tag:server`):
  - no key expiry
  - it is owned by the tailnet rather than by a person
  - ACLs can target it
- **Tailscale SSH** (`--ssh`) is the primary way in. OpenSSH is the fallback:
  over `tailscale0`, or from the home IP through the Oracle Security List. The
  Oracle Console is the last resort (`oracle-cloud.md` 2.6). Never make
  Tailscale the *only* way in. A bad ACL edit, an expired auth, or an update
  that breaks tailscaled would otherwise lock you out.

## ACL / SSH policy essentials
See `accounts-and-api-keys.md` 1.3 for the JSON. Rules:
- The `ssh` rule uses `"action": "check"` with a `checkPeriod`.
- `src` is the admins, `dst` is `tag:server`, and `users` names the one
  account.
- Never map `"*": "="` (log in as any user), and never include other people's
  devices "because they're on the tailnet".
- Servers don't need a grant to reach members' laptops. Add
  server-to-server grants only for real flows, such as the monitoring hub
  scraping exporters on specific ports.

## Exposing internal services
In order of preference:

1. **Bind to `127.0.0.1` and publish with `tailscale serve`.**
   ```bash
   sudo tailscale serve --bg --https=443 http://127.0.0.1:3000     # https://<server>.<tailnet>.ts.net
   sudo tailscale serve --bg --tcp=9100 tcp://127.0.0.1:9100       # raw TCP, e.g. an exporter
   tailscale serve status
   ```
   - The listener only exists on the tailnet, and TLS is automatic.
   - Behind `serve --tcp`, the Host header is the tailnet IP. A Caddy/nginx
     site needs a bare `:port` address or it returns an empty 200.
   - `tailscale serve status` only shows **persisted** (`--bg`) config. A
     foreground `serve` run by an app (OpenClaw on alfred) works but shows "No
     serve config". Don't read that as an outage.
2. **Bind directly to the Tailscale IP** (`100.x.y.z:port`), only for daemons
   that tolerate it:
   - The IP doesn't exist early in boot. Give the unit
     `After=tailscaled.service`, `Restart=always`, `RestartSec=5` and
     `StartLimitIntervalSec=0`.
   - **Never do this in Caddy.** Its config load is all-or-nothing, so one
     `EADDRNOTAVAIL` at boot took the *public* site down for 14 minutes on
     numbersgamearm01.
   - For Docker, publish on the tailnet IP (`100.x.y.z:9090:9090`) only if the
     container restarts on failure. Otherwise use loopback plus `tailscale serve`.
3. **Never `0.0.0.0` "because the firewall blocks it anyway."** Lurch has more
   than 20 containers on `0.0.0.0` held back only by the DOCKER-USER chain.
   It works, but it is one mistake away from exposure.

## Funnel
`tailscale funnel` makes a service **public on the internet**. For public
things, prefer the Cloudflare Tunnel plus Access: it gives WAF, rate limiting,
Access policies and your own domain. Check `tailscale funnel status` in audits;
it should be empty.

## DNS
- `--accept-dns` (the default) is fine.
- If the tailnet uses a Pi-hole as global nameserver (lurch does), every
  server's DNS depends on that home box. For a VPS, consider
  `tailscale set --accept-dns=false` so a home outage can't break the server's
  apt, ACME or tunnel.

## Health warnings you can ignore
"Some peers are advertising routes but --accept-routes is false" is expected
on servers that should not route through lurch's LAN subnet. Leave
`--accept-routes` off.

## Exit nodes
Only advertise an exit node deliberately. It needs `ip_forward`, and it lets
tailnet members route internet traffic through the box. alfred and lurch both
advertise `0.0.0.0/0`; for a friend's server, don't unless asked.
