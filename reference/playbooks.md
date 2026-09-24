# Playbooks: the everyday tasks, done from the machine

Each playbook follows the same pattern:
1. **Plan:** tell the operator exactly what will change.
2. **Dry run.**
3. **Go:** wait for an explicit go from the operator.
4. **Change.**
5. **Verify from the outside.**
6. **Log:** write it into the setup log.

Credentials come from `automation-credentials.md`. The helper scripts are in
`templates/`: `with-secrets.sh`, `cf-hostname.sh`, `oci-seclist.sh`. Install
them once on the machine the agent runs on:

```bash
sudo install -m 755 templates/with-secrets.sh templates/cf-hostname.sh templates/oci-seclist.sh /usr/local/bin/
```

Below, `ws` is short for `with-secrets.sh <map> --`. The map is
`/etc/agent/cloudflare.map` on the VPS, or `~/.config/agent/cloudflare.map` on
the laptop.

> **Check live, don't trust this file blindly.** Before running an
> unfamiliar command, check `--help`. If an API call returns an error, look up
> the current endpoint on developers.cloudflare.com or docs.oracle.com and
> adapt the script. The scripts save a backup before every write.

---

## 1. New website or app on this server, on its own hostname

Target: `blog.example.com` serving on the internet within minutes, with no
ports opened.

1. **Run the site on loopback.** Pick a free port (`ss -tlnp` shows what's
   taken).
   - Static site, nginx:
     ```nginx
     # /etc/nginx/sites-available/blog.example.com
     server {
         listen 127.0.0.1:8081;
         server_name blog.example.com;
         root /var/www/blog.example.com;
         index index.html;
         location / { try_files $uri $uri/ =404; }
     }
     ```
     Enable it: `ln -s ../sites-available/blog.example.com /etc/nginx/sites-enabled/`,
     then `nginx -t && systemctl reload nginx`. The first bind of a new port
     works with a reload. Changing an existing listen address needs a restart.
   - Docker app: `ports: ["127.0.0.1:8081:80"]`.
   - Node/Python app: a systemd unit (`systemd-service-hardening.md`) that
     listens on `127.0.0.1:8081`.
2. **Check locally:** `curl -sI http://127.0.0.1:8081/`.
3. **Publish:**
   ```bash
   ws cf-hostname.sh add blog.example.com http://127.0.0.1:8081 --dry-run   # show the plan
   ws cf-hostname.sh add blog.example.com http://127.0.0.1:8081             # after the go
   ```
   This adds the ingress rule (keeping all existing ones and the catch-all
   last) and a proxied CNAME to `<tunnel-id>.cfargotunnel.com`. It refuses to
   overwrite an existing non-tunnel DNS record unless you pass `--force-dns`.
4. **Private instead of public?** Add an Access app for the hostname, with an
   email allow-list (`cloudflare.md` 4.4). Ideally do it *before* step 3, so
   the site is never briefly public.
5. **Verify from outside:**
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://blog.example.com/
   ```
   The result should be 200, or 302 to `…cloudflareaccess.com` for Access.
   `ss -tlnp` should show the new port on 127.0.0.1 only.
6. **Log** the hostname → port mapping and its exposure in the setup log's
   hostname table.

To take it down: `ws cf-hostname.sh remove blog.example.com`. That removes the
rule and the DNS record, if it pointed to this tunnel.

## 2. Open, close or change a port in the Oracle firewall

```bash
export OCI_CLI_AUTH=instance_principal        # on the VPS (or security_token on the laptop)
oci-seclist.sh detect                          # once: find this VNIC's security list(s), and any NSGs
export OCI_SECLIST_ID=ocid1.securitylist...
oci-seclist.sh show
oci-seclist.sh add tcp 22 <new-home-ip>/32 "home ssh $(date +%F)" --dry-run
oci-seclist.sh add tcp 22 <new-home-ip>/32 "home ssh $(date +%F)"      # after the go
oci-seclist.sh remove tcp 22 <old-home-ip>/32                           # only once the new rule works
```

- **Order for anything you're connected through:** add the new rule, test it,
  and only then remove the old one. Keep a Tailscale session open while you
  do it.
- **Both families:** IPv4 and IPv6 are separate rules (`::/0` vs `0.0.0.0/0`).
- **NSGs:** if `detect` shows NSGs on the VNIC, those filter too. Change them
  in the console, or extend the script.
- **Host firewall:** if the host has one (iptables/ip6tables on the Oracle
  image), a newly opened port also needs a host rule (`host-hardening.md` 3.6).
  The owner may run with the Security List as the only layer; the setup log
  says which.
- **Verify** from a network that is *not* allowed (a phone hotspot). A probe
  from an allowed IP proves nothing.
- Restoring from a backup: the command is at the top of `oci-seclist.sh`.
  Backups are in `~/.cache/oci-seclist/`.

## 3. Home IP changed / locked out

Use this when you're away from home or the ISP changed your IP, and Tailscale
isn't working:
- **From any browser:** Oracle Console → the VCN's security list → edit the
  22 rule's source (`oracle-cloud.md` 2.6), or run `oci-seclist.sh` in
  **Cloud Shell**, where the CLI is already logged in.
- **From the laptop with a working agent:** playbook 2, run with
  `OCI_CLI_AUTH=security_token` after `oci session authenticate`.

## 4. Spin up a new Oracle instance

This needs the extra `instance-family` policy lines (`automation-credentials.md`).
Look up the current values live; don't hard-code them:

```bash
C=<compartment ocid>
AD=$(oci iam availability-domain list -c "$C" --query 'data[0].name' --raw-output)
IMG=$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" --shape VM.Standard.A1.Flex \
        --sort-by TIMECREATED --sort-order DESC --query 'data[?!contains("display-name", `Minimal`)] | [0].id' --raw-output)
SUBNET=<subnet ocid>                      # same public subnet as the existing server, or a new one
oci compute instance launch -c "$C" --availability-domain "$AD" --display-name <name> \
  --shape VM.Standard.A1.Flex --shape-config '{"ocpus":2,"memoryInGBs":12}' \
  --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
  --boot-volume-size-in-gbs 100 --is-pv-encryption-in-transit-enabled true \
  --instance-options '{"areLegacyImdsEndpointsDisabled": true}' \
  --ssh-authorized-keys-file ~/.ssh/<name>.pub --wait-for-state RUNNING
```

- **Always Free:** 4 OCPU, 24 GB and 200 GB in total across *all* A1
  instances. Check what's already in use before launching.
- "Out of host capacity": try another AD, or retry later.
- Check every flag against `oci compute instance launch --help` first. The CLI
  changes.
- Then the human steps:
  - a Tailscale auth key (tagged)
  - a tunnel for the new box, or a hostname on an existing one
  - a boot volume backup policy
- Then run SKILL.md Phases 3–7 on the new instance over SSH.

## 5. Backup before risky work

```bash
BV=<boot volume ocid>
oci bv boot-volume-backup create --boot-volume-id "$BV" --type INCREMENTAL \
  --display-name "manual-$(date +%F)-before-<what>" --wait-for-state AVAILABLE
```

Delete old manual backups yourself, to stay within the 5 free backups
(`backups-and-monitoring.md` A.4).

## 6. Rotate the tunnel token

See `cloudflare.md` 4.7. The dashboard's **Rotate token** doesn't reach the
server, so install the new token right away:
`sudo cloudflared service uninstall && sudo cloudflared service install eyJ…`.
Then check that `tunnelID=` in the journal is **this** server's tunnel.

## 7. Add or remove someone's SSH access

See `ssh-keys-and-1password.md` §4:
- one ed25519 key per person, with a comment
- test in a second session
- archive unknown keys instead of deleting them

For Tailscale SSH, also update the ACL's `ssh` rule in the admin console (a
human step).
