# Patching that really patches

## Why not stock unattended-upgrades alone
Both of these faults log **success**:

1. **u-u never refreshes package lists.**
   - The list refresh is `apt-daily.timer`, at `6,18:00` with
     `RandomizedDelaySec=12h`. The install is `apt-daily-upgrade.timer`, at
     `6:00 +60m`. Nothing orders them.
   - On 2026-08-11, numbersgamearm01 logged "No packages found that can be
     upgraded" against lists 12 hours old, and missed an 11-package systemd
     security update.
2. **`Automatic-Reboot-Time` before the upgrade window slips a whole day.**
   `shutdown -r 03:00` means the *next* 03:00. Measured: 20h09m running the
   unpatched kernel.

Also: `apt-get upgrade` without `--with-new-pkgs` never installs a new
**kernel ABI** package (`linux-image-…-1020` is a new package name, not a
version bump). Silent, forever.

## The pattern (all three servers converged on it)
- **One** systemd timer (`templates/nightly-patch.timer`) runs
  `templates/nightly-patch.sh` as root. That script:
  1. runs `apt-get update` and `apt-get --with-new-pkgs upgrade` **in one
     process**
  2. runs `autoremove --purge`. `/boot` on Oracle is under 1 GB and old
     kernels fill it.
  3. reports held packages that have a newer version waiting
  4. reboots if `/var/run/reboot-required` exists, after a 60 s grace
  5. on success, pings Healthchecks; on failure, sends an ntfy alert
- `apt-daily-upgrade.timer` is **masked**, so only one thing installs
  packages. `apt-daily.timer` can stay; it just refreshes lists.
- Scripts live in root-owned `/usr/local/sbin`. A root job running a script
  from a user-writable repo is a privilege escalation.
- **Pick a time nothing else uses.** A reboot on the same minute as a backup
  or integrity scan kills it, on exactly the nights a kernel shipped.
  Suggested: backups at 02:00, patching at 04:00.

## Install

```bash
sudo install -m 750 -o root -g root templates/nightly-patch.sh /usr/local/sbin/nightly-patch.sh
sudo install -m 644 templates/nightly-patch.service /etc/systemd/system/
sudo install -m 644 templates/nightly-patch.timer   /etc/systemd/system/
sudo install -m 750 -o root -g root templates/notify.sh /usr/local/sbin/notify.sh
sudo install -m 600 -o root -g root /dev/null /etc/server-notify.env    # then add NTFY_URL= / HC_PATCH_URL=
sudo systemctl mask apt-daily-upgrade.timer
sudo systemctl daemon-reload && sudo systemctl enable --now nightly-patch.timer
sudo /usr/local/sbin/nightly-patch.sh --dry-run    # simulates apt, lists hooks, never reboots: test with this
```

Don't `systemctl start nightly-patch.service` on a live box to test it. A
real run reboots the server if a kernel update is pending.

**Hooks** handle updates that apt doesn't know about. Put an executable in
`/etc/nightly-patch.d/` and it runs as root after apt and before the reboot
decision, in name order. A failing hook is logged and pushed to ntfy, but it
doesn't stop patching. alfred example, `/etc/nightly-patch.d/50-openclaw-update`:
```bash
#!/bin/bash
exec su - ubuntu -c '/home/ubuntu/.npm-global/bin/openclaw update'
```
Make it executable (`chmod 750`) and check with `--dry-run` that it's listed.

## Ubuntu Pro

```bash
sudo pro attach <token>          # token from ubuntu.com/pro (free, 5 machines)
sudo pro status | grep -E 'esm|livepatch'
# optional: sudo pro enable livepatch   (fewer urgent reboots; the nightly reboot still handles the rest)
```

## Third-party repos and holds
- `apt-mark hold` a package whose breakage would be **silent**, i.e. its
  service still reports `active` while the thing it does is broken.
  - numbersgamearm01 holds `caddy`, `nodejs` and `vector`. Vector 0.57 once
    broke log shipping for 19 days while it showed green.
  - Upgrade a held package deliberately:
    ```bash
    sudo apt-mark unhold <pkg>
    sudo apt-get install --only-upgrade <pkg>
    # verify the outcome
    sudo apt-mark hold <pkg>
    ```
  - The nightly script reports pending held upgrades, so "held" cannot
    quietly turn into "forgotten".
- Repos pinned to a **codename** (Docker; Tailscale on some setups) need
  editing after a release upgrade. `cloudflared` (`any`), NodeSource and
  Syncthing are codename-independent.
- NodeSource: `npm install -g npm` breaks, because dpkg owns the npm
  directory. Upgrade npm by re-extracting the tarball, or leave the bundled
  npm alone.
- npm global installs can silently skip lifecycle scripts under
  `allow-scripts`. After `npm i -g <pkg>`, check its postinstall ran; on alfred
  this needed `--allow-scripts=<pkgs>`.

## Things apt doesn't update: give each an owner and a cadence
| Thing | How | Cadence |
|---|---|---|
| Docker images | `docker compose pull && up -d` per stack, or Watchtower with **exclusions** for stateful apps (DBs, Portainer, Nextcloud) | weekly, after a backup |
| Native Pi-hole | `pihole -up` on its own timer (a DNS outage during the restart) | weekly |
| npm globals / agent CLIs | a hook in `/etc/nightly-patch.d/`, e.g. alfred's `50-openclaw-update` | daily or weekly |
| Tailscale | `tailscale set --auto-update` | automatic |
| OS release (LTS → LTS) | manual runbook: boot volume backup first, `tmux`, wait for `.1` | once per 2 years |

Watchtower notes (lurch):
- It needs `DOCKER_API_VERSION` on Docker 29 and later.
- Settings changed only in the Portainer UI are lost when Watchtower recreates
  the container. Put them in the compose file.
- `docker restart` never applies compose changes; `docker compose up -d` does.
- The containrrr/watchtower project is archived. Prefer explicit
  `compose pull` on a timer for new setups.

## Verify: the right thing
The log being green proves nothing. This proves patching:

```bash
sudo apt-get update -qq && apt list --upgradable 2>/dev/null | tail -n +2    # should be empty (or only held pkgs)
ls /var/run/reboot-required 2>/dev/null && echo "reboot pending"
systemctl list-timers nightly-patch.timer
```
