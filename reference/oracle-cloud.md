# Oracle Cloud: network, instance, backups

> **Click paths are unverified.** The console and dashboard steps in this file were written
> from memory and haven't been checked click by click. If a label doesn't match, look it up in
> the vendor docs; don't guess. CLI and API commands are more stable, but check `--help` too.

All CLI commands assume the laptop session from `accounts-and-api-keys.md`:

```bash
export OCI_CLI_PROFILE=setup OCI_CLI_AUTH=security_token
```

OCI CLI flags do change between versions. If a command errors, run
`oci <group> <cmd> --help` and adapt; don't guess.

**Security List updates replace the whole list.** Always `get`, edit the JSON,
then `update --force` with the full set. Never send a single rule.

---

## 2.1 Compartment

```bash
TENANCY=$(awk -F= '/^tenancy/{print $2; exit}' ~/.oci/config 2>/dev/null)  # or read from the console: Profile → Tenancy
C=$(oci iam compartment create --compartment-id "$TENANCY" --name <server> \
      --description "<server> VPS" --query data.id --raw-output)
echo "COMPARTMENT=$C" >> ~/.config/serversetup/oci.env
```

---

## 2.2 Network: the console wizard is fine, but finish IPv6 by hand

The quickest path is to let **Create instance** make a new VCN and public
subnet (2.4). Then fix the three things the wizard gets wrong or leaves out.

### a. IPv6: all or nothing
To enable it:
1. VCN → *IPv6 Prefixes* → Add an Oracle-allocated /56.
2. Subnet → Edit → add a /64 from it.
3. Instance VNIC → IPv6 Addresses → Assign.
4. **Route table: add `::/0` → Internet Gateway.** Oracle keeps a separate
   route rule per address family.

Without step 4, the box gets a global IPv6 address and a default route, but
every IPv6 packet is dropped at the virtual router:
- `curl` hides this with Happy Eyeballs.
- Python's `create_connection` hangs for minutes per call. This was an 8-minute
  hang in production.

```bash
RT=$(oci network route-table list -c "$C" --query 'data[0].id' --raw-output)
IGW=$(oci network internet-gateway list -c "$C" --query 'data[0].id' --raw-output)
oci network route-table get --rt-id "$RT" --query 'data."route-rules"' > routes.json
jq --arg igw "$IGW" '. + [{"destination":"::/0","destinationType":"CIDR_BLOCK","networkEntityId":$igw}]
   | unique_by(.destination)' routes.json > routes.new.json
oci network route-table update --rt-id "$RT" --route-rules file://routes.new.json --force
```

If IPv6 isn't needed, don't assign an address at all. That is simpler than a
half-configured stack.

### b. Security List: final state
Make it **stateful ingress** with only this:

| Proto | Port | Source | Why |
|---|---|---|---|
| UDP | 41641 | `0.0.0.0/0` and `::/0` | Tailscale direct WireGuard (without it traffic falls back to DERP relays, which is slower but works) |
| ICMP | type 3 code 4 | `0.0.0.0/0` | PMTU; the default list has this |
| ICMPv6 | type 2 | `::/0` | Packet Too Big, the only PMTU signal IPv6 has |
| TCP | 22 | `<home-ip>/32` (or the ISP `/24`) | **permanent** OpenSSH fallback when Tailscale is down |

The default list also allows ICMP type 3 from the VCN CIDR; keep that.
**Delete** the default `0.0.0.0/0 → TCP 22` rule once the home-IP rule exists. Test it from home before deleting.

```bash
SL=$(oci network security-list list -c "$C" --query 'data[0].id' --raw-output)
oci network security-list get --security-list-id "$SL" --query 'data."ingress-security-rules"' > ingress.json
# edit ingress.json (or build it with jq), then:
oci network security-list update --security-list-id "$SL" --ingress-security-rules file://ingress.json --force
oci network security-list get --security-list-id "$SL" \
  --query 'data."ingress-security-rules"[].{src:source,proto:protocol,tcp:"tcp-options"."destination-port-range",udp:"udp-options"."destination-port-range"}' --output table
```

Protocol numbers: 6 = TCP, 17 = UDP, 1 = ICMP, 58 = ICMPv6.

Rule for building a `/32` TCP 22 rule with jq:
`{"source":"1.2.3.4/32","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}`.

**Always read back both families.** Production had IPv4 22 restricted to the
home /24 while an IPv6 `::/0 → 22` rule sat next to it.

NSGs (per-VNIC) work too and are cleaner when there are several instances in
one subnet. Pick one mechanism and document which. On `alfred` the doc
claimed one thing and the Security List did another.

### c. Egress
Leave the default egress (all). Tailscale, Cloudflare Tunnel, apt and restic
all need outbound only.

---

## 2.3 Capacity and cost notes

- Always Free A1 total: **4 OCPU, 24 GB RAM, 200 GB block storage, 5 volume
  backups**. You can split it into several VMs.
- "Out of host capacity":
  - try the other ADs (fault domains don't help)
  - retry every few minutes, or
  - upgrade to PAYG, which in practice fixes it
- Idle reclamation (Always Free accounts only): 7 days below 20% CPU p95, and
  similar thresholds for network and memory. PAYG accounts are exempt.
- A1 images ship with **no swap**. Add a swapfile (host-hardening.md).

---

## 2.4 Create the instance (console)

Compute → Instances → **Create instance**:

- **Name:** the server's hostname. **Compartment:** the one from 2.1.
- **Image:** Canonical Ubuntu, the newest **LTS** listed (not "Minimal"
  unless the operator wants to add everything by hand).
- **Shape:** Ampere → `VM.Standard.A1.Flex`, 4 OCPU, 24 GB. On a free
  account, check that the "Always Free-eligible" badge is shown.
- **Networking:** Create new VCN and a new *public* subnet. Assign a public
  IPv4 (needed for egress unless you add a NAT gateway).
- **SSH keys:** paste the operator's ed25519 **public** key. With 1Password,
  export it with
  `op read "op://Server-<name>/<server> admin/public key" > ~/.ssh/<server>.pub`
  (see `ssh-keys-and-1password.md`). Without 1Password, generate one first:
  `ssh-keygen -t ed25519 -a 100 -C "<name> laptop $(date +%Y-%m)"`.
- **Boot volume:** 100–200 GB (the default is ~47 GB; alfred reached 81% of 96
  GB). Enable in-transit encryption.
- **Advanced → Management:**
  - *Require an authorization header* (disables legacy IMDSv1).
  - Optionally, a cloud-init script is fine but not needed.
- **Advanced → Oracle Cloud Agent:** keep *Compute Instance Monitoring*. Turn
  off plugins you won't use (Vulnerability Scanning, OS Management Hub, Bastion,
  Block Volume Management, Management Agent) unless wanted. Each one is code
  running as root with broad sudoers rules (`/etc/sudoers.d/*oracle-cloud-agent*`).

The CLI equivalent for IMDS on an existing instance:

```bash
oci compute instance update --instance-id "$INSTANCE" \
  --instance-options '{"areLegacyImdsEndpointsDisabled": true}' --force
```

Get the IPs:

```bash
INSTANCE=$(oci compute instance list -c "$C" --lifecycle-state RUNNING --query 'data[0].id' --raw-output)
oci compute instance list-vnics --instance-id "$INSTANCE" \
  --query 'data[0].{public:"public-ip",private:"private-ip"}' --output table
```

---

## 2.5 Boot volume backups (the full-disk layer)

The schedule, the manual backups and the restore steps are all in
[`backups-and-monitoring.md` → Layer A](backups-and-monitoring.md#layer-a-oracle-full-disk-backup-schedule).
It is set up in Phase 6 together with the R2 file backups. **Take one manual
boot volume backup before Phase 3** anyway, so the hardening work has an undo.

## 2.6 Fallback access through the Oracle Console

The access paths, in order:
1. Tailscale SSH
2. OpenSSH from the home IP
3. **The Oracle Console**

The Console works from any browser, on any network, with only the Oracle
login. Set up every item below **during setup**, test it once, and write the
date into the setup log.

### a. Console login you can't lose
- Enable **MFA** on the Oracle user (Profile → Security → Multi-factor
  authentication). Store the recovery codes in the password manager.
- Optional, recommended for a friend's server: a **second admin user** (the
  helper) in the tenancy's Administrators group, with its own MFA. Then one
  lost phone doesn't lock the owner out.
- Bookmark the region's console URL, for example
  `https://cloud.oracle.com/?region=eu-amsterdam-1`.

### b. "My home IP changed" or "I'm away from home": re-open SSH for the current IP
Use this when Tailscale doesn't work and you aren't on the home IP.

1. Find the current public IP: open <https://ifconfig.co> on the device you're
   using.
2. Console → **Networking** → **Virtual cloud networks** → *the VCN* →
   **Security** → *Default Security List* (or the NSG) → **Security rules**.
   - **Edit** the TCP 22 rule and change the source to `<new-ip>/32`, or
     **Add Ingress Rule**: source CIDR `<ip>/32`, IP protocol TCP, destination
     port 22, description `temp <date> <why>`.
3. SSH in with the normal key. Fix whatever broke Tailscale.
4. **Remove the temporary rule afterwards.** If the home IP really changed,
   make the new IP the permanent rule and update the setup log.

Or from **Cloud Shell** (the `>_` icon top right in the Console; the OCI CLI
is already logged in):

```bash
SL=<security list ocid>     # store it in the setup log; it is not secret
MYIP=<current ip>
oci network security-list get --security-list-id "$SL" --query 'data."ingress-security-rules"' > rules.json
jq --arg ip "$MYIP/32" '. + [{"source":$ip,"protocol":"6","isStateless":false,
    "description":"temp ssh","tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}]' rules.json > new.json
oci network security-list update --security-list-id "$SL" --ingress-security-rules file://new.json --force
```

**Note:** Cloud Shell's own egress IP is *not* your laptop's IP. The rule is
for the device you will SSH from.

### c. Serial console: when SSH itself is broken
Examples: a broken sshd config, a firewall lockout, a failed boot, or a full
disk.

- Set a local password for the admin user once (sshd still refuses
  passwords):
  ```bash
  sudo passwd ubuntu      # long random value → password manager
  ```
- Console → Compute → Instances → *instance* → **OS management** /
  **Console connection** (the name varies) → **Launch Cloud Shell
  connection**. You get the login prompt in the browser. Press Enter a couple
  of times if it is blank.
- From the laptop instead: **Create console connection** with the operator's
  public key, then use the SSH command the Console shows.
- The serial console also shows boot messages. If the box hangs at boot,
  **Reboot** from the instance page while it is connected to see why.
- **Test it once during setup:** log in at the serial console, run `id`, and
  log out.

### d. Run Command: optional, commands without any login
- The Oracle Cloud Agent's **Compute Instance Run Command** plugin runs a
  script as root from the Console (Instance → Run command). It needs:
  - the plugin enabled
  - a dynamic group containing the instance
  - an IAM policy along the lines of
    `allow dynamic-group <dg> to use instance-agent-command-execution-family in compartment <c>`
- Useful for a one-line fix, e.g. `systemctl restart tailscaled` or reverting
  an sshd drop-in, without a password on the serial console.
- It is another way to run root commands. Enable it only if the owner wants
  it, and write it down.

### e. Last resort: restore the disk
Restore the latest boot volume backup into a new instance
(`backups-and-monitoring.md` A.5). Tailscale and the tunnel reconnect by
themselves, because both are outbound.

### Release upgrades
`do-release-upgrade` offers a fallback sshd on port 1022, and it is
unreachable: the Security List and the host firewall block it. Before an
upgrade:
1. Take a manual boot volume backup.
2. Confirm the serial console works.
3. Run the upgrade inside `tmux`.

---

## 2.7 Useful read-only checks later

```bash
# What is actually open at the cloud edge
oci network security-list get --security-list-id "$SL" --query 'data."ingress-security-rules"' | jq -c '.[] | {source, protocol, tcp:."tcp-options", udp:."udp-options"}'
# Route rules for both families
oci network route-table get --rt-id "$RT" --query 'data."route-rules"[].destination'
# Backup policy attached?
oci bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment --asset-id "$BV"
```
