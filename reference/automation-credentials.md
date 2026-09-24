# Automation credentials: Oracle Cloud and Cloudflare, stored safely

Setup-time credentials (`accounts-and-api-keys.md`) are short-lived and deleted
afterwards. This file covers the **long-lived, narrow** credentials that let the
agent (Claude Code, Hermes, OpenClaw) keep doing the routine work later:
- publish a new site on the tunnel, with DNS
- open or close a port in the Oracle Security List
- spin up a new instance
- take a boot volume backup before risky work

> **Look it up live.** Checked against the vendor docs on 2026-09-23:
> - OCI instance-principal auth (`--auth instance_principal`)
> - dynamic-group matching rules
> - the `manage security-lists` requirement
> - the instance-launch permissions
> - Cloudflare account-owned tokens, IP filtering and TTL
> - the tunnel-configuration API
>
> Permission *names* in dashboards get renamed. Before creating a credential,
> fetch the current page (links below) and adapt.

## Which credential, by where the agent runs

| Agent runs on | Oracle Cloud | Cloudflare | Where the Cloudflare token lives |
|---|---|---|---|
| **the Oracle VPS** it manages | **instance principal**: no key file at all | account-owned API token, **IP-filtered to the VPS's public IP** | **OCI Vault** secret, read through the instance principal; fallback a root-only file |
| **the operator's laptop** | `oci session authenticate` (browser, ≤24h), or an API key for a dedicated IAM user | account-owned API token, IP-filtered to the home IP | **1Password**, used through `op run` or `with-secrets.sh` |
| **another server** (home server, other cloud) | API key for a dedicated IAM user | same, IP-filtered to that host | 1Password Service Account, or a root-only file |

A **local open-source vault** can replace 1Password or OCI Vault in any row:
KeePassXC (recommended), Vaultwarden or `pass`. See `local-password-manager.md`.
On the VPS, that's a separate *agent vault* (`/etc/agent/secrets.kdbx` plus a
root-only key file); on the Mac, an agent vault whose password is in the
Keychain.

Scripts don't care which row applies. `templates/with-secrets.sh` reads a map
of `VAR=op://…`, `VAR=ocivault:<ocid>` or `VAR=file:/path` entries and runs the
command with those variables set. It never prints them.

---

## Oracle Cloud

### A. Agent on the VPS: instance principal (recommended)
The instance itself authenticates, so there is no key on disk to leak.
Docs: <https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/callingservicesfrominstances.htm>

1. **Dynamic group.** In the console's Identity section, create a dynamic
   group, e.g. `agent-<server>`. Matching rule for just this instance:
   ```
   instance.id = 'ocid1.instance.oc1....'
   ```
   `instance.compartment.id = '…'` would include every instance in the
   compartment, including future ones. Use it only if that's intended.
2. **Policy** in the server's compartment. Start with the least that the
   playbooks need, and add lines only when a playbook needs them:
   ```
   Allow dynamic-group agent-<server> to manage security-lists in compartment <c>
   Allow dynamic-group agent-<server> to inspect virtual-network-family in compartment <c>
   Allow dynamic-group agent-<server> to manage boot-volume-backups in compartment <c>
   Allow dynamic-group agent-<server> to read secret-bundles in compartment <c>
   ```
   Only for "spin up a new instance":
   ```
   Allow dynamic-group agent-<server> to manage instance-family in compartment <c>
   Allow dynamic-group agent-<server> to use subnets in compartment <c>
   Allow dynamic-group agent-<server> to use vnics in compartment <c>
   Allow dynamic-group agent-<server> to read instance-images in compartment <c>
   Allow dynamic-group agent-<server> to read app-catalog-listing in tenancy
   ```
   - Updating a security list needs `manage security-lists`; `use` isn't
     enough (core policy reference).
   - A dynamic group in a non-default identity domain is written as
     `'<domain>'/'agent-<server>'` in policies. Check the docs for the current form.
3. **Use it:** `export OCI_CLI_AUTH=instance_principal`, then
   `oci iam region list` should work with no config file.

**Warning: every process on the box can use the instance principal.** The
metadata endpoint `169.254.169.254` is reachable by every local user and every
container that has network access. On a box that runs **untrusted code** (CI
runners, agents executing arbitrary commands for other people), that code
could change your firewall. For such a box, either:
- keep the policy minimal and rely on the ntfy and Console fallbacks, or
- use an API key for a dedicated IAM user (B), stored root-only, instead of
  the instance principal.

Decide explicitly and write it in the log. (alfred runs GitHub runners, so
this applies there.)

### B. Agent elsewhere: a dedicated IAM user, not your own login
1. Create an IAM user `automation-<server>`, a group `automation-<server>`, and
   the same policy lines as in A, with `group` instead of `dynamic-group`.
2. Profile of that user → **API keys → Add API key → Generate** → download the
   private key. Copy the config snippet into `~/.oci/config`
   (`chmod 600 ~/.oci/config ~/.oci/*.pem`). Put the private key in 1Password
   as well.
3. **Rotation:** add a new key, switch the config, delete the old key. Once a
   year, or whenever the laptop changes hands.

For a laptop agent that only works while the operator is at the keyboard,
**`oci session authenticate`** is simpler and safer: a browser login, tokens
valid for up to 24 hours, and nothing to rotate.

---

## Cloudflare

Docs: <https://developers.cloudflare.com/fundamentals/api/get-started/create-token/>

### One account-owned token per machine
Create it under **Manage Account → API Tokens**, not My Profile.
Account-owned tokens aren't tied to one person's login.

| Permission (names change: pick the closest current one) | Scope |
|---|---|
| Account: **Cloudflare Tunnel** / "Cloudflare One Connector: cloudflared" **Edit** | this account |
| Zone: **DNS Edit** | only the zone(s) this server publishes |
| Account: **Access: Apps and Policies Edit** | only if the agent should add Access apps |

- **Client IP Address Filtering:** the machine's public IP. On the VPS, that's
  its reserved public IP: `curl -4 ifconfig.co` *from the VPS*. A stolen token
  is then useless elsewhere.
- **TTL:** optional. With IP filtering, a long TTL is acceptable. Otherwise
  90 days, with a reminder to renew.
- The secret is shown **once**. Store it straight away (below). Don't paste it
  into chat.

### Storing it

**On the VPS, OCI Vault** (no plaintext on disk; read through the instance
principal):
1. Console → Identity & Security → **Vault** (path not verified; check the OCI Vault docs) → create a vault (software-protected
   keys; check the free-tier limits) → a master key → **Secrets → Create
   secret**, e.g. `cloudflare-automation`, pasting the token as the content.
2. Put the secret's OCID in the map file:
   ```
   # /etc/agent/cloudflare.map   (references only, not secret)
   CF_API_TOKEN=ocivault:ocid1.vaultsecret.oc1....
   CF_ACCOUNT_ID=<account id>
   CF_TUNNEL_ID=<this server's tunnel id>
   ```
3. Test that it resolves without printing: `with-secrets.sh /etc/agent/cloudflare.map -- sh -c 'echo ${#CF_API_TOKEN}'`
   (prints the length only).

The CLI returns the secret as base64 in `data."secret-bundle-content".content`.
`with-secrets.sh` decodes it. Check the field once against
`oci secrets secret-bundle get --help` / the output.

**Or a local KeePassXC agent vault** (`local-password-manager.md`): map entry
`CF_API_TOKEN=kpxc:cloudflare-automation`, run with `sudo with-secrets.sh …`.

**Fallback on any Linux box: a root-only file**
```bash
sudo install -d -m 700 /etc/agent
sudo sh -c 'umask 077; cat > /etc/agent/cloudflare-token'   # paste, Ctrl-D (never on the command line)
# map: CF_API_TOKEN=file:/etc/agent/cloudflare-token   → run the agent's helper with sudo
```
`with-secrets.sh` refuses the file unless it is mode 600 or 400.

**On the laptop: 1Password.** Store it as item `cloudflare-automation` in the
server's vault. Map entry:
`CF_API_TOKEN=op://Server-<name>/cloudflare-automation/credential`.
For an agent running unattended on another host, a **1Password Service
Account** token scoped to that one vault replaces the Touch ID prompt. Store
it root-only.

### Rotation
Cloudflare: API Tokens → **⋯ → Roll → Confirm**. The old secret stops working at once; the
permissions stay the same (checked 2026-09-23, <https://developers.cloudflare.com/fundamentals/api/how-to/roll-token/>). Then update the Vault secret (a new version), the file
or the 1Password item. There is nothing to restart, because scripts read it at
each use.

---

## Rules the agent follows with these credentials
- Resolve secrets only inside the command that needs them (`with-secrets.sh …
  -- <cmd>`). Never `echo`, `cat` or `env` them, and never paste them into a
  command line you type.
- Before any write, show the **plan**: which hostname or port, which
  direction, and the dry-run output. Wait for the operator's go (see
  SKILL.md, "A question is not an instruction").
- After a write, verify from the outside: curl the hostname, or probe the
  port from a non-allowed network.
- Every change lands in the setup log: what, when, the backup file path.
