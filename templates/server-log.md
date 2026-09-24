# <server> — setup and security log

> **Paths and decisions only. Never values.** Secrets live in the password
> manager and in root-only files on the box. This log names *where*, never
> *what*.
> Every "done" entry says **when** it was done and **how it was verified**.

| | |
|---|---|
| Owner | <name> |
| Operator(s) | <names> |
| Oracle | tenancy <name>, home region <region>, compartment <name>, PAYG yes/no, budget alert €<n> |
| Instance | <shape> <ocpu>/<gb> GB, boot volume <gb> GB, Ubuntu <version>, arch <aarch64> |
| Public IPv4 / IPv6 | <ip> / <ip or "not assigned"> |
| Tailscale | <hostname>.<tailnet>.ts.net, <100.x.y.z>, tag:server, Tailscale SSH on |
| Cloudflare | zone <domain>, tunnel <name> (<id>), Zero Trust team <team> |
| Alerts | ntfy topic in password manager; Healthchecks: nightly-patch, restic-backup |

## Plan (Phase 0)

**Components:**
- ...

**Hostnames:**

| Hostname | Local service | Exposure | Access policy |
|---|---|---|---|
| example.com | 127.0.0.1:8088 (nginx) | public | — |
| admin.example.com | 127.0.0.1:3000 | Access | owner-only (email allow-list, OTP) |

**Explicitly not doing (and why):**
- ...

## Where secrets live (paths only)

Password manager: <1Password | KeePassXC (human vault on Mac, agent vault /etc/agent/secrets.kdbx) | Vaultwarden | pass>

| Secret | Location | Also in password manager |
|---|---|---|
| SSH key (per person) | 1Password `Server-<name>` / `<server> admin (<person>)`; public key `~/.ssh/<server>.pub` | yes (only there) |
| Tunnel token | /etc/cloudflared/token (0600 root, written by `cloudflared service install`) | yes |
| restic repo password + R2 key | /etc/restic/env (0600 root) | yes |
| ntfy / Healthchecks URLs | /etc/server-notify.env (0600 root) | yes |
| Serial-console password for `ubuntu` | — | yes |

Setup-time credentials (Cloudflare setup token, OCI API key or session, Tailscale auth key): **deleted or expired on <date>**.

## Done

### <YYYY-MM-DD> Phase 2: Oracle network and instance
- ...
- Verified: `<command>` → `<result>`

### <YYYY-MM-DD> Phase 3: Host baseline
- ...
- Verified from outside (from <where>): IPv4 all closed, IPv6 all closed

## Port map (final)

| Port | Bound to | Reached via | Why |
|---|---|---|---|
| 41641/udp | 0.0.0.0 | Security List + host ts-input | Tailscale direct |
| 22/tcp | 0.0.0.0 (socket), firewalled | tailnet only | OpenSSH fallback |

## Schedules

| When (UTC) | What | Alert |
|---|---|---|
| 02:00 | restic-backup.timer | Healthchecks + ntfy on failure |
| 04:00 | nightly-patch.timer (upgrade, reboot if needed) | Healthchecks + ntfy on failure |
| weekly | Docker `compose pull && up -d` (per stack) | — |

## Accepted risks
- `ubuntu` has NOPASSWD sudo (single admin). Mitigation: Tailscale SSH `check` mode, one named user.
- ...

## Restore test log
| Date | What was restored | Result |
|---|---|---|

## Quarterly review
- [ ] `ss -tulpn` has no new `0.0.0.0` listeners
- [ ] Outside port scan (v4 + v6) is all closed
- [ ] Cloudflare Access apps and allow-lists are still right
- [ ] Tailscale devices and ACL: remove old devices
- [ ] Test restore done
- [ ] `apt list --upgradable` is empty; no stale holds
