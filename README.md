# oracle-server-setup (Claude Code skill)

A guided setup for a new **Oracle Cloud Ubuntu server** with no public admin
or app ports:
- admin access through Tailscale SSH, with OpenSSH from the home IP and the
  Oracle Console as fallbacks
- the public web goes through a Cloudflare Tunnel and Access
- IPv4 and IPv6 host firewalls
- patching that really patches
- encrypted offsite backups with alerts

It also covers easy hardening for a **macOS home server** on the same tailnet.

Claude starts with an **interview**: what the server is for, which hostnames,
who gets access. It then walks through creating the Oracle, Cloudflare,
Tailscale and Ubuntu Pro credentials, and builds and verifies the server
phase by phase.

Distilled on 2026-09-23 from three live servers:

| Server | Type | What it contributed |
|---|---|---|
| alfred | Oracle ARM, websites + AI agents + monitoring hub | tunnel/SNI gotchas, Access for private sites, monitoring hub, rootless CI runner |
| numbersgamearm01 | Oracle ARM, production SaaS | full hardening baseline, IPv6 firewall, patching fixes, tunnel lessons, backups and alerting |
| lurch | x86 home server | UFW + DOCKER-USER, Pi-hole + Caddy + mkcert, media stack, restic to R2 |

## Layout

```
ServerSetupSkill/
├── SKILL.md                       # the guided flow: Phase 0 interview → Phase 8 hand-over
├── README.md                      # this file
├── reference/
│   ├── agent-operator.md          # where the agent runs, human-only steps, look it up live, safe rules
│   ├── playbooks.md               # new site + hostname, Oracle firewall, new instance, backup, rotation
│   ├── automation-credentials.md  # long-lived Oracle/Cloudflare credentials + secure storage
│   ├── accounts-and-api-keys.md   # Oracle / Cloudflare / Tailscale / Ubuntu Pro / R2 / ntfy (setup-time)
│   ├── ssh-keys-and-1password.md  # ed25519 key in 1Password, SSH agent, VS Code, op run/inject
│   ├── local-password-manager.md  # open-source local vaults: KeePassXC, Vaultwarden, pass
│   ├── oracle-cloud.md            # VCN, IPv6, Security List, instance, IMDS, backups
│   ├── host-hardening.md          # SSH, users, v4+v6 firewall with rollback, sysctl, journald, swap
│   ├── tailscale.md               # tags, SSH policy, serve, binding gotchas
│   ├── cloudflare.md              # tunnel over the API, standard install, rotation, Access, WAF
│   ├── patching.md                # why stock unattended-upgrades fails, the nightly script
│   ├── workloads.md               # loopback binding, Docker, systemd sandbox, untrusted code
│   ├── systemd-service-hardening.md
│   ├── backups-and-monitoring.md  # restic + R2, Healthchecks, ntfy
│   ├── macos-home-server.md
│   ├── linux-home-server.md       # the lurch pattern
│   └── lessons-learned.md         # dated incidents behind every rule
├── templates/                     # configs, units, setup-log, and cf-hostname.sh / oci-seclist.sh / with-secrets.sh
└── Lurch/                         # the ORIGINAL June 2026 skill + lurch log (history; see note)
```

## Using it
- Copy the folder to `~/.claude/skills/oracle-server-setup/`
  on the operator's Mac.
- Then ask: "set up my new Oracle server".
- It also reads as a plain runbook, starting at `SKILL.md`.

> `Lurch/` is the original June 2026 skill plus lurch's log, kept for history. The
> keys, account ID and IPs in it are redacted. Everything useful from it is now in
> `reference/linux-home-server.md` and `reference/lessons-learned.md`.
