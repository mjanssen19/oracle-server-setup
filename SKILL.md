---
name: oracle-server-setup
description: >-
  Set up, harden and operate an Oracle Cloud (OCI) Ubuntu server with an AI agent
  (Claude Code, Hermes, OpenClaw) doing most of the work, and the operator doing only
  the human steps. The agent can run on the operator's Mac, on the VPS itself, or on
  another host; it detects which and adapts. It covers: an interview; creating
  accounts and API credentials (Oracle CLI and instance principal, Cloudflare
  account-owned token, Tailscale, 1Password) with secure storage (1Password, OCI
  Vault, root-only files); hardening; Cloudflare Tunnel and Access; two-layer backups;
  ntfy alerts; and everyday playbooks: publish a new website on its own hostname,
  change the Oracle firewall from the machine, spin up a new instance, rotate
  tokens. It looks up current vendor docs at the moment of use rather than trusting
  remembered click paths. Also covers hardening a Mac or Linux home server on the
  same tailnet.
---

# Oracle Cloud server: set up and operate with an agent

**The idea.** The operator, with a helper, does the handful of things only a
human can do: accounts, payment, MFA, approving logins, creating tokens, and
decisions. The **agent does everything else**: SSH, the Oracle CLI, the
Cloudflare API, and the verification. After setup, the same agent does the
routine work from the machine, for example "put `blog.example.com` online" or
"open port X for my new IP".

**First, work out where you are running** (`reference/agent-operator.md`,
step 1): the operator's Mac, the Oracle VPS itself, or another host. The
answer decides how you reach the server, how you authenticate to Oracle
(browser session, instance principal or IAM key), and where secrets come from
(1Password, OCI Vault or a root-only file). Say which applies before starting.

**Two modes:**
- **New server → the phases below** (Phase 0 interview to Phase 8 hand-over).
- **An existing server plus a routine task →
  [`reference/playbooks.md`](reference/playbooks.md)**: a new site with
  hostname, Oracle firewall changes, a new instance, a backup before risky
  work, token rotation, SSH access. These use `templates/cf-hostname.sh`,
  `oci-seclist.sh` and `with-secrets.sh`, with long-lived narrow credentials
  from [`reference/automation-credentials.md`](reference/automation-credentials.md).

**Look it up live.** Everything here was true when written (dates noted). At
the moment of use:
- check CLI flags with `--help`
- check click paths and permission names on the vendor docs
- read the current API reference when a call fails

Give the operator the *current* steps, and say plainly when something couldn't
be verified. Adapt the steps to what you find. Nothing here overrides what
the live docs or the actual system show.

**The target design:**

- **Admin access has three independent paths.** Any one of them is enough:
  1. **Tailscale SSH** is the daily path.
  2. **OpenSSH on port 22, from the owner's home IP only.** The Oracle
     Security List does the restriction. This is the fallback when Tailscale
     is down or misconfigured.
  3. **The Oracle Console** is the last resort. From any browser you can
     re-open port 22 for your current IP (or run `oci-seclist.sh` in Cloud
     Shell), reach the serial console, or restore the disk. Set this up and
     test it during setup (Phase 2).
- **Public web traffic** goes through a Cloudflare Tunnel, which is outbound
  only, so no inbound port is needed. Anything that is not meant for the whole
  internet sits behind Cloudflare Access.
- **Everything else** binds to `127.0.0.1` or to the Tailscale IP.
- **Firewall layers:** the Oracle Security List always default-denies. A host
  firewall (IPv4 **and** IPv6) is recommended defence in depth. An owner can
  choose to run with the Security List alone (alfred does), and the setup log
  records that choice.

This design comes from three real servers. Each rule below exists because one
of them got it wrong once. The dated incidents are in
[`reference/lessons-learned.md`](reference/lessons-learned.md).

- `alfred`: Oracle ARM, websites plus AI agents (OpenClaw, Hermes) plus the monitoring hub
- `numbersgamearm01`: Oracle ARM, production SaaS
- `lurch`: an x86 home server

## How to run this skill

1. **Interview first (Phase 0). Change nothing until the plan is agreed.**
   Ask the questions and write the answers into a setup log (template:
   [`templates/server-log.md`](templates/server-log.md)). Every later step
   reads from that log.
2. **Work in phases, in order.** Finish each phase with its *verify* step
   before starting the next. A green exit code is not proof. Check the actual
   outcome, for example a port scan from outside or `apt list --upgradable`.
3. **Say what you're about to do before any lock-out-capable change** (SSH,
   firewall, Tailscale). Keep a second session open, and arm an automatic
   rollback for firewall changes (Phase 3.6).
4. **Credentials:**
   - Setup-time API keys stay on the **operator's laptop** and never go on the
     server.
   - They are revoked or deleted at the end (Phase 8).
   - Never paste a secret into chat, the setup log or a doc. **Recommended:
     1Password.** Secrets are read at the moment of use with `op read` or
     `op run`, and piped straight into root-only files on the server. See
     [`reference/ssh-keys-and-1password.md`](reference/ssh-keys-and-1password.md).
     **Open-source and local instead:** KeePassXC (or Vaultwarden, or `pass`),
     see [`reference/local-password-manager.md`](reference/local-password-manager.md).
     Ask in Phase 0 which the operator wants.
5. **Record as you go.** After each phase, append to the setup log: what was
   done, the date, *why* for anything non-obvious, and what was deliberately
   skipped. Paths yes, secrets no.
6. **A question is not an instruction.** When the operator asks ("is there…?",
   "can we…?", "what happens if…?"), answer it and propose a solution, then
   wait for a clear go before changing anything. Read-only checks to answer the
   question are fine.
7. **Never read secrets into the session.** Don't `cat`, `grep` or print files
   that contain tokens or keys: unit files with `--token`, `/etc/cloudflared/token`,
   env files, private SSH keys, `/etc/restic/env`. Check them by length, hash
   (`sha256sum`) or fingerprint (`ssh-keygen -lf`), and redact with
   `sed -E 's/(--token )[^ ]+/\1<redacted>/'`. Old AI session logs (Claude Code,
   Grok) on lurch and alfred still contained tunnel tokens, and those had to be
   rotated.
8. **Don't give click paths from memory.** Dashboards change. Check
   the vendor docs first, or say plainly that a path is unverified. A remembered
   Cloudflare path was wrong on 2026-09-23.
9. **Prefer the vendor's standard way** (for example `cloudflared service install`)
   over a hand-built variant, unless the operator chooses otherwise. The
   vendor's dashboard and docs assume the standard layout, and a deviation
   makes their instructions dangerous to follow.

Where the operator's laptop is a Mac, commands marked **(laptop)** run there.
Commands marked **(server)** run on the VPS.

---

## Phase 0: Interview

Ask these in small batches (use AskUserQuestion when available). Offer the
**recommended** answer as the default. Most people should take the defaults.

**A. People, agent and access**
0. Which agent will operate the server (Claude Code, Hermes, OpenClaw,
   several), and where does it run: the Mac, the VPS itself, or both? That
   determines the credential set-up (Phase 8) and where secrets live.
1. Who will operate the server day to day, and how comfortable are they with a
   terminal? This sets how much you explain.
2. Whose Oracle, Cloudflare and Tailscale accounts will this use? *(Recommended:
   the owner's own accounts. The helper gets invited, not the other way round.)*
3. Who else needs admin access, from which devices? This drives the Tailscale
   SSH policy (Phase 1.3).
4. What is the home connection's public IP, and does it change? Check it with
   `curl -4 ifconfig.co` from home. It becomes the SSH fallback rule. If it
   changes, the operator must know the Console procedure for updating it
   (Phase 2.6).
5. Which password manager: 1Password, or an open-source local one (KeePassXC,
   the default; Vaultwarden to share between people)? *(Either works; scripts
   read from both.)*
6. Where do alerts go? *(Recommended: the ntfy app on their phone, plus a
   Healthchecks.io dead-man switch.)* Email only works if an email API is set
   up, because a VPS has no working MTA.

**B. What the server is for (pick all that apply)**
- Static website(s), served by nginx or Caddy on loopback behind the tunnel
- Web app(s): Node, Python or Go, run as a hardened systemd service or in Docker
- Docker/Compose apps, and a list of which ones
- Database: PostgreSQL, bound to localhost
- File sync / NAS-like (Syncthing, Nextcloud)
- AI agent or automation host (see the untrusted-code note in Phase 5)
- Monitoring hub (Prometheus, Grafana, Uptime Kuma) or just alerting
- CI runner. *(If the server holds production secrets, put the runner on a
  different box.)*
- Something else

**C. Exposure**
1. Is there a domain, and is its DNS on Cloudflare? If not, the first task is
   moving the nameservers to Cloudflare (free plan).
2. For each public hostname: fully public, or only for specific people?
   *(Anything admin-like, such as dashboards, terminals or private docs, gets
   Cloudflare Access.)*
3. Anything that cannot go through an HTTP tunnel (game servers, SMTP, raw TCP
   for the public)? Only these get a Security List rule plus a host firewall
   rule.

**D. Oracle specifics**
1. Is there an Oracle account yet? Which **home region**? It is permanent, and
   Always Free A1 capacity depends on it. *(Recommended: the region closest to
   the users, e.g. `eu-amsterdam-1` or `eu-frankfurt-1` from NL.)*
2. Always Free only, or Pay As You Go with a budget alert? *(Recommended: PAYG
   plus a €1 budget alert. It still costs €0 inside the free limits, but it
   stops idle-instance reclamation and makes A1 capacity much easier to get.)*
3. Architecture: ARM (`VM.Standard.A1.Flex`, up to 4 OCPU and 24 GB free) or
   x86 (`E2.1.Micro`, 1 GB, which is tiny)? *(Recommended: ARM, 4 OCPU / 24 GB,
   100–200 GB boot volume.)* Check that every planned Docker image publishes
   `arm64`.
4. Ubuntu version: the newest LTS image Oracle offers. Don't jump to a new LTS
   before its `.1` point release.

**E. Home server (optional)**
1. Is there a home server, and what OS? For **macOS**, follow
   [`reference/macos-home-server.md`](reference/macos-home-server.md). For
   Linux, follow [`reference/linux-home-server.md`](reference/linux-home-server.md).
2. Should the VPS and the home server talk to each other, e.g. for backups or
   monitoring? That happens over Tailscale only.

**Output of Phase 0:** a filled-in `server-log.md` that contains:
- the component list
- the hostname → local port → public/Access table
- the alert channel
- the explicit "not doing" list

Read the plan back to the operator and get a yes before continuing.

---

## Phase 1: Accounts and API credentials

Full click-by-click steps are in
[`reference/accounts-and-api-keys.md`](reference/accounts-and-api-keys.md).
Summary of what to create, and where it lives:

**First, 1.0: the operator's key and the vault.** Enable the 1Password SSH
agent and CLI, and create a vault `Server-<name>`. Generate an **ed25519
SSH key inside 1Password** and export only its public key to
`~/.ssh/<server>.pub`. Add the `~/.ssh/config` host entries with
`IdentityFile ~/.ssh/<server>.pub` and `IdentitiesOnly yes`. Without them,
the agent offers every stored key and hits the server's `MaxAuthTries 3`.
Details: [`reference/ssh-keys-and-1password.md`](reference/ssh-keys-and-1password.md).

| # | Credential | Scope | Lives on | Lifetime |
|---|---|---|---|---|
| 1.0 | **SSH key**, ed25519 | admin login (OpenSSH fallback, VS Code, scp) | **1Password** (private key never on disk); public key in `~/.ssh/<server>.pub` | rotate when a person leaves or a device is lost |
| 1.1 | **OCI CLI session** (`oci session authenticate`), or an API signing key | the user's tenancy | laptop `~/.oci/` | session: ≤24h. Delete an API key after setup |
| 1.2 | **Cloudflare API token**, custom | Tunnel:Edit, Access Apps & Policies:Edit, DNS:Edit on *one* zone | 1Password item, used through `op run` | expiry ≈ 1 week, delete after setup |
| 1.3 | **Tailscale auth key**, plus ACL tag and SSH policy | `tag:server`, one-off, pre-approved | typed once on the server, then gone | 1 day |
| 1.4 | **Ubuntu Pro token** | free, 5 machines | used once with `pro attach` | permanent (account) |
| 1.5 | **Cloudflare tunnel token** (created in Phase 5) | runs one tunnel | server `/etc/cloudflared/token` (0600 root, written by `cloudflared service install`) | until rotated |
| 1.6 | **R2 access key** for backups (Phase 6) | Object Read & Write on *one* bucket | server `/etc/restic/env`, `0600 root` | until rotated |
| 1.7 | **ntfy topic / Healthchecks URL** | alerting | server `/etc/server-notify.env`, `0600 root` | until rotated |

Rules for all of them:
- Least privilege, and one purpose per credential.
- Server-side credentials go in root-only files, **never** in unit files,
  command lines or docs.
- Every server-side secret, including the backup repository password, lives
  in the server's 1Password vault first. The server file is written from it
  (`op read … | ssh … 'sudo sh -c "umask 077; cat > file"'`). The vault is
  the only off-box copy.

**Verify:**
- `oci iam region-subscription list` works.
- The Cloudflare `tokens/verify` call returns `active`.
- The ACL has `tag:server` and an SSH rule in `check` mode.

---

## Phase 2: Oracle network and instance

Details, CLI commands and console paths are in
[`reference/oracle-cloud.md`](reference/oracle-cloud.md).

1. **Compartment:** create one for this server. It gives clean scoping and
   simpler clean-up.
2. **VCN, dual-stack:**
   - Create a public subnet, an Internet Gateway, and route rules for
     **both** `0.0.0.0/0` **and** `::/0`. Oracle treats the two families
     separately, and a missing `::/0` silently black-holes IPv6 egress.
   - Either skip IPv6 or do it fully.
3. **Security List / NSG ingress (final state):**
   - `UDP 41641` from `0.0.0.0/0` and `::/0`, for Tailscale direct connections.
     Tailscale still works without it, but through a relay.
   - ICMP type 3 code 4 (IPv4) and ICMPv6 type 2 (Packet Too Big).
   - **TCP 22 from the owner's home IP only** (`/32`, or the ISP's `/24` if the
     IP changes within a range). This rule is permanent: it is the fallback
     when Tailscale fails. Delete the default `0.0.0.0/0 → 22` rule.
   - **Nothing else.** Specifically no 80 or 443 unless Phase 0 found a
     non-HTTP service.
   - Check **both** address families. An IPv4 rule restricted to home next to a
     `::/0` IPv6 rule is how production once had SSH open to the IPv6 internet.
     Leave IPv6 22 closed unless the home line has a stable IPv6 prefix.
4. **Instance:**
   - Image: Ubuntu LTS. Shape: A1.Flex 4/24. Boot volume 100–200 GB.
   - Paste the operator's **ed25519** public key (`~/.ssh/<server>.pub`,
     exported from 1Password).
   - Retry or switch availability domain on "Out of host capacity" (PAYG
     helps a lot).
5. **Instance settings:**
   - Disable legacy IMDSv1 endpoints.
   - Review the Oracle Cloud Agent plugins: keep monitoring, turn off what
     isn't used.
   - Backups are set up in Phase 6. The full-disk schedule is attached to this
     instance's boot volume there.
6. **Oracle Console fallback access: set it up and test it now**, while
   everything still works. Follow
   [`reference/oracle-cloud.md` 2.6](reference/oracle-cloud.md#26-fallback-access-through-the-oracle-console).
   - Console login with **MFA**, plus a second admin or a recovery method.
   - **Cloud Shell** opens, and `oci` works in it.
   - A practiced **"re-open SSH for my current IP"** procedure: a Security List
     edit, done from the phone or another network.
   - A **serial console** connection, plus a local password for the admin user
     (in the password manager; SSH still refuses passwords).
   - Optional: the **Run Command** plugin, to run a command on the instance
     without any network login.
   - Write each path, and the date it was tested, into the setup log.

**Verify:**
- `ssh ubuntu@<public-ip>` works from the operator's IP.
- From the server, `curl -6 https://ifconfig.co` works if IPv6 is enabled.

---

## Phase 3: Host baseline

Details and exact file contents are in
[`reference/host-hardening.md`](reference/host-hardening.md); templates are in
`templates/`. Order matters: **Tailscale SSH works before SSH or the firewall is touched.**

1. **Audit the starting state.** Record users, `ss -tulpn`, `sshd -T`,
   `iptables -S` and `ip6tables -S`.
2. **Patch now:** `apt update && apt full-upgrade`, then reboot.
3. **Tailscale plus Tailscale SSH:**
   - Run `tailscale up --ssh --auth-key=… --hostname=…`.
   - Test `ssh ubuntu@<hostname>` over the tailnet **from a second terminal**.
   - Only then continue.
4. **Users:**
   - Delete the `opc` duplicate admin if it exists, and its cloud-init
     redirect config.
   - Keep one admin (`ubuntu`), with exactly one ed25519 key per person, each
     with a clear comment. No `ssh-rsa` lines.
   - Test `ssh <server>` (Tailscale), `ssh <server>-public` (from home) and VS
     Code Remote-SSH. All three should use the 1Password key with Touch ID.
   - Remove the admin from the `lxd` group, since it is a root escalation path.
5. **sshd drop-in** (`templates/sshd-99-hardening.conf`):
   - key-only, `AllowUsers`, modern KEX/ciphers, VERBOSE logging, ECDSA host
     key removed.
   - Run `sshd -t` before reloading.
   - OpenSSH stays as the fallback path. It is reachable over `tailscale0`, and
     from the home IP through the Security List.
6. **Host firewall, both families, with an automatic rollback armed:**
   - IPv4: keep Oracle's rules, including the stock `--dport 22` ACCEPT (the
     Security List restricts the source) and the `InstanceServices` chain.
     Add nothing else.
   - IPv6: the image ships **empty with policy ACCEPT**. Add the ruleset from
     `templates/firewall-ipv6.sh` (ICMPv6 1–4 and 128–137, DHCPv6 546 from
     `fe80::/10`, terminal REJECT).
   - Persist with `netfilter-persistent save`.
   - **Never** flush INPUT to "clean up". A policy-ACCEPT INPUT with no REJECT
     is how `alfred` ended up relying on the Security List alone.
7. **Check the Security List:** TCP 22 comes from the home IP only, and
   there is no `0.0.0.0/0` or `::/0` rule for 22.
8. **Surface reduction:**
   - `apt purge rpcbind nfs-common` (it listens on `0.0.0.0:111`).
   - Disable unused services.
   - Re-run `ss -tulpn`. The only public listeners allowed are tailscaled
     (41641/udp) and sshd (22, which the Security List limits to home).
9. **Kernel and logs:** apply `templates/sysctl-99-hardening.conf` and
   `templates/journald-99-persistent.conf`.
10. **Swap:** A1 images ship with **no swap**. Add a 4 GB swapfile (without
    one, a full RAM means OOM kills).
11. **fail2ban:** install it for the sshd jail (`templates/fail2ban-jail.local`).
    With 22 limited to home it should stay at 0 bans; a ban means the home IP
    range changed or something is wrong. It can't see Tailscale SSH or tunnel
    traffic (Phase 5).

**Verify from a network that is NOT home.** Use a phone hotspot, or another
server's public IP. A probe from home only proves that home is allowed; that
exact mistake was made while auditing alfred.

```bash
for p in 22 80 111 443 3000 8080 8443 9443; do timeout 3 bash -c "</dev/tcp/<public-ip>/$p" 2>/dev/null && echo "$p OPEN" || echo "$p closed"; done
```

- From outside, everything must be closed, **including 22**.
- From home, 22 must be open, and that is the fallback working.
- Repeat against the IPv6 address.

---

## Phase 4: Patching that really patches

Details are in [`reference/patching.md`](reference/patching.md). Templates:
`templates/nightly-patch.sh`, `.service`, `.timer`.

- Attach **Ubuntu Pro** (ESM apps and infra). Livepatch is optional.
- The nightly timer runs `apt-get update` and `apt-get --with-new-pkgs upgrade`
  **in one process**:
  - Stock unattended-upgrades evaluates package lists up to 12 hours stale.
  - Plain `apt-get upgrade` never installs a new kernel ABI package.
- After the upgrade: reboot if `/var/run/reboot-required` exists, at a minute
  no other job uses.
- Mask `apt-daily-upgrade.timer`, so there is exactly one patcher.
- `apt-mark hold` any third-party package whose breakage would be silent
  (runtime, proxy, log shipper). The script reports held packages that have
  upgrades waiting.
- Things apt doesn't cover (Docker images, npm globals, native Pi-hole) get
  their own cadence, and each one is written down.
- Success pings Healthchecks.io; failure goes to ntfy.

**Verify:**
- `systemctl list-timers nightly-patch.timer`
- A manual run of `sudo systemctl start nightly-patch.service`, then read its
  log
- `apt list --upgradable` comes back empty

---

## Phase 5: Workloads and publishing

**Publishing through Cloudflare** (details and API calls in
[`reference/cloudflare.md`](reference/cloudflare.md)):

1. Create a **remotely managed tunnel** through the API with the Phase 1.2
   token.
2. Install the connector the **standard** way: `sudo cloudflared service install <token>`.
   Pipe the token from the API, or copy the line from **this** tunnel's dashboard page.
   Current cloudflared writes the token to `/etc/cloudflared/token` (root-only) itself.
   Keep `cloudflared-update.timer` enabled.
3. **Verify the tunnel ID** in the journal matches, then curl the hostnames of *every*
   tunnel on the account. A connector installed with another tunnel's token breaks both.
4. Ingress entries map hostnames to `http://127.0.0.1:<port>`, ending with a
   catch-all `http_status:404`.
5. **Cloudflare Access** on every non-public hostname:
   - an email allow-list and one-time PIN. OTP without an allow-list lets
     anyone in.
   - Test in a private window that you get the Access login page (302).
6. On a free-plan zone, add **one WAF rate-limit rule** for login paths. The
   origin only ever sees `127.0.0.1`, so fail2ban on the origin cannot ban
   tunnel traffic.
7. Apps behind the tunnel need their trusted-proxy setting, e.g. Nextcloud
   `TRUSTED_PROXIES`, or their own brute-force throttling counts everyone as
   `127.0.0.1`.

**Running things** (details in [`reference/workloads.md`](reference/workloads.md)):

- **Bind to loopback.** Every service listens on `127.0.0.1`. Tailnet-only
  services listen on `127.0.0.1` and are exposed with `tailscale serve`, or
  bind the Tailscale IP with `Restart=always`. Never `0.0.0.0`.
- **Docker ignores the host firewall.** Publish ports as `127.0.0.1:8080:8080`.
  Add the DOCKER-USER chain (`templates/docker-firewall.sh`) as a second layer.
- **Native apps** run as systemd services with a dedicated user and the
  sandbox template.
- **Untrusted code** (CI runners, AI agents running arbitrary commands,
  Dependabot builds) runs as an unprivileged user with rootless podman, and is
  never given the Docker socket. Better still, it runs on a box without
  production secrets.

**Verify:**
- `ss -tulpn` shows nothing new on `0.0.0.0` or `[::]`.
- Each public hostname returns 200.
- Each Access hostname returns 302 to `cloudflareaccess.com`.
- The outside port scan is still all closed.

---

## Phase 6: Backups (two layers) and alerting

Details are in [`reference/backups-and-monitoring.md`](reference/backups-and-monitoring.md).
Every server gets **both** layers. They protect against different things.

| Layer | What | Where | Schedule | Restores |
|---|---|---|---|---|
| **A. Full disk** | the whole boot volume: OS, packages, everything | **Oracle** block volume backups, through a backup policy | weekly incremental, keep 4 (fits the 5 free backups), plus a manual one before risky work | the whole machine, as a new instance (≈15 min) |
| **B. Config and data files** | `/etc`, service configs, app data, `/usr/local`, web roots, DB dumps | **Cloudflare R2** through restic (encrypted on the server) | daily 02:00 UTC | single files or directories, even if the Oracle account is gone |

**Layer A: Oracle full-disk schedule.**
1. Create a custom backup policy in the server's compartment (weekly,
   incremental, 4 weeks retention).
2. Assign it to the instance's **boot volume**, and to any attached block
   volumes.
3. Take one manual backup right away, so there is a restore point before
   Phase 7.
4. **Verify:** the policy shows on the boot volume, and after the first run a
   backup appears as `AVAILABLE`.

**Layer B: Cloudflare R2 for config files.**
1. Put the R2 bucket and its bucket-scoped key (Phase 1) into
   `/etc/restic/env` (0600 root), then run `restic init`.
2. Install `templates/restic-backup.sh` plus its timer. Adjust `PATHS` to
   this server's config and data dirs, from the Phase 0 component list.
3. Databases go through a dump (`pg_dump -Fc`), never live files.
4. The script runs `forget --prune` and a weekly `restic check`. It pings
   Healthchecks.io on success and ntfy on failure.
5. The repo password goes into the password manager. Without it the R2 copy
   is unreadable. `/etc/restic/env` is excluded from the backup.
6. **Do one test restore now**, into `/tmp/restore-test`, and write the date
   into the log.

**Why both:** Layer A is fast and complete, but it lives in the same Oracle
tenancy and region. Account suspension, a region outage or deleting the
compartment takes it along. Layer B is offsite and file-level, and costs
nothing in egress to restore.

- **Alerting:**
  - Healthchecks.io emails or pushes when a ping *doesn't* arrive. That catches
    "the job silently stopped", which is the failure that cost production 15
    days of backups.
  - Optional: Uptime Kuma or Prometheus on another box probing the **public**
    URLs. A probe from the serving host still passes while the tunnel or DNS
    is broken.

---

## Phase 7: Final verification

Run all of these and paste the results (not the secrets) into the setup log:

```bash
sudo ss -tulpn | grep -vE '127\.0\.0\.|\[::1\]|100\.|fd7a:'   # only tailscaled should remain
sudo sshd -T | grep -Ei 'passwordauth|permitroot|allowusers|authenticationmethods'
sudo iptables -S INPUT | tail -1; sudo ip6tables -S INPUT | tail -1   # both must be a REJECT
tailscale debug prefs | jq '{RunSSH, ShieldsUp, AdvertiseTags}'
systemctl --failed
systemctl list-timers | grep -E 'nightly-patch|restic'
sudo pro status | grep esm
apt list --upgradable 2>/dev/null | tail -n +2
```

Then from the laptop:
- the Oracle backup policy is on the boot volume, and a backup exists:
  `oci bv boot-volume-backup list -c "$C" --boot-volume-id "$BV" --query 'data[].{t:"time-created",s:"lifecycle-state",type:type}' --output table`
- the port scan (IPv4 and IPv6)
- a `curl` of each hostname
- the Access check in a private window

---

## Phase 8: Hand-over, automation, clean-up

**Set up the agent for everyday work** (`reference/automation-credentials.md`,
`reference/playbooks.md`):
1. Create the long-lived, narrow credentials for where the agent will run:
   - on the VPS: an instance principal (dynamic group plus a minimal policy),
     and an account-owned Cloudflare token IP-filtered to the VPS, stored in
     OCI Vault or a KeePassXC agent vault
   - on the Mac: an `oci session`, and the Cloudflare token in 1Password or a
     KeePassXC agent vault
   The operator creates them; the agent never sees the values.
2. Install `with-secrets.sh`, `cf-hostname.sh` and `oci-seclist.sh` in
   `/usr/local/bin`, and write the map file (references only).
3. **Rehearse every playbook once, read-only or dry-run:**
   - `cf-hostname.sh list`
   - `cf-hostname.sh add test.<domain> http_status:204 --dry-run`
   - `oci-seclist.sh detect` and `show`

   Then do one real round trip: add a test hostname, curl it, remove it.
   Write in the log that it worked.
4. If the box runs untrusted code (CI, shared agents), decide on the
   instance-principal risk and write it down.

**Clean up:**
- Delete the Cloudflare setup token, and delete the OCI API key if one was
  made. Tailscale auth keys expire by themselves.
- Check that the server's 1Password vault holds every server-side secret, the
  serial-console password, the restic repo password and the Oracle MFA
  recovery codes. Remove the helper from the vault, unless they stay on
  purpose as the second admin.
- Check that the Oracle Console fallback (Phase 2.6) was tested, and that the
  log says how to re-open SSH if the home IP changes.
- Setup log: final port table, hostnames, the Access policy, where each
  secret lives (by path), the update cadence, the backup and restore test
  date, and the "not doing / accepted risks" list.
- Schedule a reminder: a quarterly look at `ss -tulpn`, the outside port scan,
  the Access policies and a test restore.

---

## Reference index

| File | Covers |
|---|---|
| [`reference/agent-operator.md`](reference/agent-operator.md) | where the agent runs, human-only steps, look-it-up-live, safe operating rules, Claude Code / Hermes / OpenClaw notes |
| [`reference/playbooks.md`](reference/playbooks.md) | new site + hostname, Oracle firewall change, locked out, new instance, backup, token rotation, SSH access |
| [`reference/automation-credentials.md`](reference/automation-credentials.md) | long-lived Oracle (instance principal / IAM user) and Cloudflare (account-owned, IP-filtered) credentials and where to store them |
| [`reference/accounts-and-api-keys.md`](reference/accounts-and-api-keys.md) | creating each account and the setup-time credentials, step by step |
| [`reference/local-password-manager.md`](reference/local-password-manager.md) | open-source local vaults: KeePassXC (human + agent vault), Vaultwarden, pass; break-glass rule |
| [`reference/ssh-keys-and-1password.md`](reference/ssh-keys-and-1password.md) | ed25519 key in 1Password, SSH agent, `~/.ssh/config`, VS Code, `op run` / `op inject` for secrets |
| [`reference/oracle-cloud.md`](reference/oracle-cloud.md) | VCN, IPv6, Security List, instance, IMDS, agent, **Console fallback access**, reclamation, CLI |
| [`reference/host-hardening.md`](reference/host-hardening.md) | SSH, users, firewall v4/v6 with rollback, sysctl, journald, swap, fail2ban |
| [`reference/tailscale.md`](reference/tailscale.md) | ACL tags, SSH policy, serve, binding gotchas, exit nodes |
| [`reference/cloudflare.md`](reference/cloudflare.md) | tunnel over the API, standard connector install, rotation, Access, WAF, cloudflared gotchas |
| [`reference/patching.md`](reference/patching.md) | why stock u-u fails, the nightly script, holds, non-apt updates |
| [`reference/workloads.md`](reference/workloads.md) | loopback binding, Docker and DOCKER-USER, systemd sandbox, rootless runners, nginx/Caddy notes |
| [`reference/backups-and-monitoring.md`](reference/backups-and-monitoring.md) | Oracle full-disk backup schedule, restic to R2 for config files, restores, Healthchecks, ntfy, external probes |
| [`reference/macos-home-server.md`](reference/macos-home-server.md) | easy hardening for a Mac home server |
| [`reference/linux-home-server.md`](reference/linux-home-server.md) | lurch-style home server: UFW, Pi-hole, Caddy plus mkcert, media stack |
| [`reference/lessons-learned.md`](reference/lessons-learned.md) | dated incidents from the three reference servers |
| `templates/` | drop-in files and scripts, including `cf-hostname.sh`, `oci-seclist.sh`, `with-secrets.sh` |
