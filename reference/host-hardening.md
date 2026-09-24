# Host baseline hardening (server)

Order matters. **Tailscale SSH has to work before you touch SSH or the
firewall.** OpenSSH from the home IP stays as the fallback. Keep a second
session open through every SSH or firewall change.

---

## 3.1 Audit first

```bash
lsb_release -ds; uname -rm
getent passwd | awk -F: '$7 ~ /sh$/ {print $1, $3, $7}'
sudo grep -RhE '^[^#]' /etc/sudoers /etc/sudoers.d/ 2>/dev/null
id ubuntu                                   # lxd group? remove it (3.4)
sudo ss -tulpn
sudo sshd -T | grep -Ei 'passwordauth|permitroot|pubkey|allowusers|x11|tcpforward'
sudo iptables -S; sudo ip6tables -S         # v6 is usually EMPTY with policy ACCEPT
```

Paste a summary (not keys) into the setup log as the "before" state.

## 3.2 Patch and reboot

```bash
sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade && sudo reboot
```

## 3.3 Tailscale plus Tailscale SSH

```bash
curl -fsSL https://tailscale.com/install.sh | sh
# The auth key carries tag:server, so no --advertise-tags is needed. Type it here; don't store it.
sudo tailscale up --ssh --hostname=<server> --auth-key=tskey-auth-XXXX
tailscale status && tailscale ip -4
sudo tailscale set --auto-update
```

**Test from the laptop in a new terminal**, over the tailnet:
`ssh ubuntu@<server>`. The first login in `check` mode opens a browser to
confirm.

If you are converting an existing box while connected over plain SSH, run
`tailscale set --ssh --accept-risk=lose-ssh` so the current session isn't cut.

Tailscale SSH logins bypass sshd and fail2ban. They are audited in the
tailscaled journal:

```bash
sudo journalctl -u tailscaled | grep 'audit: SSH'
```

## 3.4 Users

```bash
# OCI sometimes ships an extra admin "opc" with the same key: two doors, one lock
sudo find / -xdev -user opc -not -path '/var/lib/docker/*' 2>/dev/null | head   # look before deleting
(umask 077; sudo tar czf /root/opc-home-$(date +%F).tar.gz -C /home opc)
sudo userdel -r opc || sudo userdel -f -r opc   # -f only if it refuses because container processes share UID 1000
sudo rm -f /etc/cloud/cloud.cfg.d/99-oracle-compute-user-redirect.cfg   # cloud-init would recreate the redirect user
sudo gpasswd -d ubuntu lxd 2>/dev/null     # lxd group membership = root via a privileged container
cat ~/.ssh/authorized_keys                  # exactly one ed25519 key, the operator's
```

`ubuntu` keeps the image's `NOPASSWD: ALL` (`/etc/sudoers.d/90-cloud-init-users`).
This is an accepted risk on a single-admin box. Because of it, any SSH login is
effectively root, which is why the Tailscale SSH rule uses `check` mode and one
named user. Write the decision into the log.

## 3.5 sshd drop-in

Install `templates/sshd-99-hardening.conf` as
`/etc/ssh/sshd_config.d/99-hardening.conf`, then:

```bash
sudo rm -f /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ecdsa_key.pub
sudo sshd -t && sudo systemctl reload ssh      # -t MUST pass first
```

Notes:
- **After removing the ECDSA host key**, every client that had pinned it will
  ask once to accept the ed25519 key ("keys of a different type are already
  known"). Tell the operator in advance, so it isn't mistaken for an attack.
  Verify the fingerprint against `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
  on the server.
- On Ubuntu 24.04 and later, sshd is **socket-activated** (`ssh.socket`), so it
  still listens on `0.0.0.0:22`. That's fine: the host firewall and the Security
  List decide who reaches it. Don't try `ListenAddress <tailscale-ip>`. The
  Tailscale IP doesn't exist yet at boot, and sshd fails to bind.
- **VS Code Remote-SSH and port forwarding** need `AllowTcpForwarding yes`. The
  template defaults to `no`. If the operator uses VS Code over SSH, set `yes`
  deliberately and note it in the log. On numbersgamearm01 it drifted to `yes`
  without a note.
- Older SSH clients (Termius/libssh2) may need
  `PubkeyAcceptedAlgorithms ssh-ed25519,rsa-sha2-256,rsa-sha2-512` (lurch has
  this).

## 3.6 Host firewall: IPv4 and IPv6, with a rollback armed

Oracle images use iptables through `netfilter-persistent`. **Don't install
UFW on Oracle.** Mixing it with the image rules risks a lockout and breaks
`InstanceServices`.

### Arm the rollback before touching anything

```bash
sudo iptables-save  | sudo tee /root/rules.v4.rollback >/dev/null
sudo ip6tables-save | sudo tee /root/rules.v6.rollback >/dev/null
sudo systemd-run --on-active=600 --unit=fw-rollback \
  /bin/sh -c 'iptables-restore /root/rules.v4.rollback; ip6tables-restore /root/rules.v6.rollback'
# ...make changes, verify from a NEW session, then disarm:
sudo systemctl stop fw-rollback.timer
```

### IPv4
Keep the image ruleset. It ends in `REJECT`, with the `InstanceServices` chain
guarding `169.254.0.0/16`. Oracle **requires** that chain; changing it can
break boot volume or metadata access. **Keep the stock `--dport 22` ACCEPT.**
The Security List limits who reaches it to the home IP, and it is the
fallback path.

```bash
sudo iptables -S INPUT                        # stock: ts-input, ESTABLISHED, icmp, lo, --dport 22, REJECT
sudo iptables -S INPUT | tail -1              # must be: -A INPUT -j REJECT --reject-with icmp-host-prohibited
```

Optional, stricter: limit 22 at the host too, e.g.
`iptables -R INPUT <n> -p tcp -s <home-ip>/32 --dport 22 -m state --state NEW -j ACCEPT`.
The downside is that a home-IP change then needs **two** edits, and the
host-side one can't be done from the Console without the serial console.
Most setups leave the source check to the Security List only.

Tailscale's `ts-input` chain (first in INPUT) already accepts everything from
`tailscale0` and UDP 41641.

**Anti-pattern seen on alfred:** the INPUT chain was reduced to
`-j ts-input` with policy ACCEPT and no REJECT, and saved that way. Every
listener on `0.0.0.0` was then protected only by the Security List. Never
flush INPUT to "tidy up".

### IPv6
The image ships ip6tables **empty, policy ACCEPT**. Run
`templates/firewall-ipv6.sh`. It appends, it doesn't flush, so tailscaled's
chains survive. It adds:
- ESTABLISHED and loopback
- **ICMPv6 1–4 and 128–137.** Neighbour discovery and Packet Too Big are
  mandatory; dropping them black-holes IPv6 from the inside.
- **UDP 546 from `fe80::/10`.** The address is DHCPv6-leased (~19h); without
  this it disappears a day later.
- a terminal REJECT, and no port 22

### Verify from a new session, then persist

```bash
ssh ubuntu@<server> true && echo "tailnet ssh OK"      # from the laptop
sudo iptables -S | wc -l; sudo ip6tables -S | wc -l    # counts look sane
sudo netfilter-persistent save                         # writes /etc/iptables/rules.v4 + rules.v6
sudo systemctl stop fw-rollback.timer
```

Don't trust `ip6tables-restore --test`. It once passed a file whose real
restore aborted halfway, leaving no REJECT. Check the live ruleset after any
restore.

### Then check the cloud edge
- The Security List has TCP 22 from the home IP only, with no `0.0.0.0/0` or
  `::/0` rule for 22 (oracle-cloud.md 2.2b).
- Run the outside port scan from `SKILL.md` Phase 3 **from a non-home network**,
  for both IPv4 and IPv6.

## 3.7 Surface reduction

```bash
sudo apt purge -y rpcbind nfs-common          # :111 on 0.0.0.0, never needed on a VPS
systemctl list-unit-files --state=enabled --type=service
sudo ss -tulpn | grep -vE '127\.0\.0\.|\[::1\]|%lo'
```

The only public listeners allowed are tailscaled (41641/udp) and sshd (the
socket; the Security List limits it to home). Anything else is either rebound
to loopback or the Tailscale IP, or written down with a reason.

## 3.8 Kernel and logs

```bash
sudo install -m 644 templates/sysctl-99-hardening.conf /etc/sysctl.d/99-hardening.conf
sudo sysctl --system
sudo install -d /etc/systemd/journald.conf.d
sudo install -m 644 templates/journald-99-persistent.conf /etc/systemd/journald.conf.d/99-persistent.conf
sudo systemctl restart systemd-journald
```

**Warning: the restart vacuums immediately.** `MaxRetentionSec=1month` and
`SystemMaxUse` delete older entries at once. On alfred this took the journal
from 2.7 GB to 172 MB and removed a month of history. If older logs might
matter, export them first, e.g.
`journalctl --until -30d -o export | zstd > /root/journal-archive.zst`.

If the server becomes a Tailscale **exit node or subnet router**, it needs
`net.ipv4.ip_forward=1` in its own file (`99-tailscale.conf`). The hardening
file doesn't disable forwarding, so the two don't conflict. Exit nodes are
usually unnecessary on a VPS; skip unless asked.

## 3.9 Swap (A1 has none)

```bash
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/60-swappiness.conf && sudo sysctl --system
```

## 3.10 fail2ban

The sshd jail covers the home-IP fallback path. It should stay at 0 bans; a
ban usually means the home IP range changed. Use
`templates/fail2ban-jail.local`:
- `ignoreip` includes `100.64.0.0/10` and `169.254.0.0/16`
- escalating bans

It **cannot** protect tunnel traffic. See cloudflare.md.

## 3.11 Optional, stronger (numbersgamearm01 has these)

- **auditd** with watch rules on identity files, sudoers, sshd config,
  `.ssh`, `/etc/systemd/system`, cron dirs, secret dirs and module loading.
- **AIDE** file-integrity check nightly, with the result sent to alerting.
- These are worth it for production boxes that hold customer data. For a
  personal box, skip them and say so in the log.
