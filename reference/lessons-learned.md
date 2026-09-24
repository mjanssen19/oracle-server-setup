# Lessons learned: incidents and findings from the reference servers

Each line is something that really happened. Where a rule in the skill looks
fussy, this is why. Audit dates: 2026-09-23.

## Network exposure
| Where | What happened | Rule it produced |
|---|---|---|
| numbersgamearm01, 2026-08-14 | VCN allowed SSH from IPv6 `::/0` while IPv4 was limited to home; ip6tables was empty with policy ACCEPT | check **both** families in the Security List **and** the host firewall; mirror v4 into v6 |
| numbersgamearm01, 2026-08-14 | IPv6 egress black-holed: route table had `0.0.0.0/0` but no `::/0`; Python connects hung 8 minutes | add `::/0 → IGW`, or don't assign IPv6 at all |
| numbersgamearm01 | first v6 ruleset passed `ip6tables-restore --test`, then aborted halfway on the real restore and left no REJECT | arm a `systemd-run` rollback; check the live rules after applying |
| alfred, 2026-09-23 audit | a port probe from **lurch (on the home IP)** reported 22 "open" and was first read as public exposure. The Security List limits 22 to the home IP, so the probe only proved that the fallback works | probe from a network that is **not** allowed (phone hotspot) before calling something exposed |
| alfred | host INPUT reduced to `ts-input` + policy ACCEPT, so every listener relies on the Security List alone. The owner accepted this: the Security List allows only 22 (home) and Syncthing 22000 | a deliberate single-layer choice is fine if it is written down; keep listeners off `0.0.0.0` so the single layer has little to protect |
| owner decision, 2026-09-23 | Tailscale-only admin access was rejected: if Tailscale breaks, the owner wants plain SSH from home, and the Oracle Console to re-open ports | three access paths: Tailscale SSH, OpenSSH from the home IP, and the Oracle Console (`oracle-cloud.md` 2.6) |
| alfred | Next.js on `*:3000`, Portainer on `0.0.0.0`, rpcbind on `:111` | loopback by default; purge rpcbind; audit `ss -tulpn` after each deploy |
| lurch | 20+ containers on `0.0.0.0`, held back only by DOCKER-USER; UFW rules "Anywhere" without comments | loopback publishing; every rule has a source and a comment |
| numbersgamearm01 | Caddy served HTTP/3 but UDP 443 was never opened | if you advertise h3, open UDP 443 in both firewalls, or disable h3 |

## SSH and access
| Where | What happened | Rule |
|---|---|---|
| lurch | Tailscale SSH policy used `accept` (no check) for every personal device, including another user's phone and laptop, plus two servers mapped `"*":"="`; the user has NOPASSWD sudo | `check` mode, admins only, one named user |
| numbersgamearm01 | `AllowTcpForwarding` drifted to `yes` (VS Code Remote) with no note | a deliberate exception gets a log entry |
| OCI images | duplicate `opc` admin with the same key; ECDSA host key; `ubuntu` in `lxd` | delete opc and its cloud-init redirect; drop ECDSA; `gpasswd -d ubuntu lxd` |
| OCI release upgrade | the fallback sshd on port 1022 is unreachable | Tailscale SSH, home-IP SSH, serial console, tmux |

## Cloudflare
| Where | What happened | Rule |
|---|---|---|
| lurch, alfred | tunnel token inline in a mode-644 unit (older `service install`), readable in `ps`, and it ended up in AI session logs | reinstall with current cloudflared, which uses `/etc/cloudflared/token` (0600) itself; don't `cat` units with secrets in AI sessions |
| alfred, lurch, 2026-09-23 | a hand-built hardened cloudflared unit (own user, sandbox, masked updates) made the dashboard's instructions misleading; following them removed the token file | stay on the **standard** install where vendor tooling and docs assume it; harden only what the standard leaves open |
| lurch, 2026-09-23 | "Rotate token" doesn't push anything to the server: the old token died, the running connector survived, and the next restart would have failed | after rotating, install the new token immediately (Add replica → `service uninstall && service install`) |
| lurch, 2026-09-23 | the install command was copied from **alfred's** tunnel page: lurch joined alfred's tunnel, alfred's sites went 502 and lurch's own hostnames 530 | check the tunnel name and ID on the page; after install check `tunnelID=` in the journal and curl every tunnel's hostnames |
| session, 2026-09-23 | Cloudflare dashboard paths given from memory were wrong ("Zero Trust → Networks → Tunnels → Refresh token") | check vendor docs before giving click paths; mark what's verified |
| numbersgamearm01, lurch, 2026-08 | cloudflared 2026.8.0/8.1 rewrote `https://` in paths: a 16-hour outage and a broken app | owner treats it as incidental and keeps normal updates; an external probe catches a bad release fast |
| alfred, 2026-07-13 | `http://localhost:443` against a TLS listener caused 400 for every visitor; `https://localhost` with SNI `localhost` caused a 502 | plain HTTP on loopback; otherwise `originServerName` + `matchSNItoHost` |
| lurch, 2026-07-18 | Nextcloud via tunnel: every client looked like 192.168.1.2, so fail2ban can't ban and app throttling was per-proxy | trusted proxies; Access or WAF rate limit at the edge |
| alfred | Access with OTP needs an email allow-list, or anyone can mail themselves a PIN | allow-list is mandatory |
| numbersgamearm01 | Caddy blocks for hostnames not pointing at the box led to an endless ACME retry that filled the journal | only grey-cloud hosts in Caddy |

## Tailscale binding
| Where | What happened | Rule |
|---|---|---|
| numbersgamearm01 | Caddy bound to the Tailscale IP; `EADDRNOTAVAIL` at boot took the **public** site down for 14 minutes (all-or-nothing config) | Caddy binds 127.0.0.1, `tailscale serve --tcp` publishes |
| numbersgamearm01 | `tailscale serve --tcp` sends Host = the tailnet IP; the site block returned an empty 200 | bare `:port` site address |
| alfred | `tailscale serve status` said "No serve config" while an app's foreground serve worked | not an outage; check with curl |
| alfred | dead `tailscale-openclaw-serve.service` left enabled and failing after a reinstall | remove leftovers; `systemctl --failed` in every audit |

## Patching
| Where | What happened | Rule |
|---|---|---|
| numbersgamearm01, 2026-08-11 | u-u evaluated 12h-stale lists and missed an 11-package systemd security update, with a green log | update + upgrade in one process |
| numbersgamearm01, 2026-07-24 | reboot time before the upgrade window: 20h09m on the unpatched kernel | reboot right after the upgrade, at a free minute |
| numbersgamearm01 | `apt-get upgrade` without `--with-new-pkgs` never installs a new kernel ABI | `--with-new-pkgs` (or full-upgrade) |
| numbersgamearm01 | reboot guard `pgrep -x unattended-upgrade` could never match (15-char name limit) | check dpkg locks (`DPkg::Lock::Timeout`, `fuser`) |
| numbersgamearm01 | vector 0.57 broke log shipping for 19 days while `is-active` was green | hold silent-failure packages; report pending holds |
| alfred, 2026-09-08 | an npm global update skipped postinstall under `allow-scripts`: new version, broken install | check lifecycle scripts ran |
| lurch | native Pi-hole is invisible to apt | own weekly timer |

## Backups and alerting
| Where | What happened | Rule |
|---|---|---|
| numbersgamearm01, 2026-07-10 to 07-24 | `pg_dump` failed 15 nights (a hand-made table without grants); `MAILTO` went to a box with no MTA | Healthchecks dead-man + ntfy/Slack; `ALTER DEFAULT PRIVILEGES` |
| numbersgamearm01 | a cron redirect target not writable by the job owner killed the job before start, while cron logged it as dispatched | systemd timers, or root-owned log directories |
| lurch | restic had no `check` and no failure alert, and the repo password was only on the box | weekly `restic check`, alerts, password in the password manager |
| alfred | Oracle boot volume backups only: no file-level or offsite copy, so restoring one config means restoring the whole disk, and the tenancy is a single point of failure | both layers: the Oracle full-disk schedule **and** restic → R2 for config files |
| lurch | restic to local HDD + R2, but no full-disk image | an Oracle policy on VPSes; on home servers the local restic repo plays that role |
| lurch | Uptime Kuma installed with 0 monitors | configure it or remove it |
| alfred, found 2026-09-23 | the Alertmanager container had exited cleanly on 2026-08-17; Prometheus kept evaluating rules, but no fleet alert was delivered for 5 weeks, and nothing noticed | watch the watcher: an always-firing "Watchdog" alert to a Healthchecks dead-man, and `restart: unless-stopped` |
| lurch | world-readable Portainer tarball containing stack env | `umask 077` for ad-hoc backups |

## Docs and secrets
| Where | What happened | Rule |
|---|---|---|
| lurch `config.md` | contained a SABnzbd API key and R2 account ID in plain text | logs hold **paths**, never values |
| alfred `serversetup.md` | the architecture note contradicted the port table; versions stale; missing services | "verified on <date> with <command>"; re-audit before trusting |
| numbersgamearm01 | good practice: comments at the exact line someone would change, explaining *why* | copy this |

## Resources and platform
| Where | What happened | Rule |
|---|---|---|
| OCI A1 | no swap on the image | 4 GB swapfile |
| alfred | disk from 42 GB to 81% of 96 GB (Docker, runners, agent tooling) | 150–200 GB boot volume; alert at 80% |
| alfred | Docker containers' internal UID 999 collided with a host user in `ps` | map by container, not UID, when auditing |
| OCI | `oracle-cloud-agent` snap brings broad NOPASSWD sudoers for `snap_daemon` | enable only the plugins you use |
