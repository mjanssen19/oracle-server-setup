# macOS home server: easy hardening and config

> **Click paths are unverified.** The console and dashboard steps in this file were written
> from memory and haven't been checked click by click. If a label doesn't match, look it up in
> the vendor docs; don't guess. CLI and API commands are more stable, but check `--help` too.

Scope: a Mac (mini or old MacBook) at home running a few services, reached
remotely **over Tailscale only**. Configuring the apps themselves is out of
scope. This covers the ten or so settings that make it safe and keep it
running unattended.

Walk the operator through these in order, and record each one in the setup
log. Most are System Settings clicks, so say where to click. The Terminal
equivalents are here for checking.

## 1. Accounts
- **Two accounts:** an *admin* account used only for changes, and a *standard*
  account that runs the services and the day-to-day login. Services run as
  the standard user.
- Disable the guest account (System Settings → Users & Groups → Guest User →
  off).
- Use a long login password, stored in the password manager.
- Turn on **Find My Mac** (Activation Lock).

## 2. Disk encryption: know the trade-off
- **FileVault on** (Privacy & Security → FileVault). Store the recovery key in
  the password manager, **not** in iCloud if the Mac is shared.
- Consequence for a headless server: after a **power loss** the Mac boots to
  the FileVault unlock screen and **stays offline** until someone types the
  password on it.
  - Planned restarts: `sudo fdesetup authrestart` skips the prompt once.
  - Unplanned ones: a small UPS, or accept it.
  - Disabling FileVault instead means anyone who takes the Mac takes the data.
    Discuss it with the owner and record the choice.
- Auto-login is incompatible with FileVault. That's fine; services shouldn't
  depend on a GUI login (see 6).

```bash
fdesetup status; csrutil status; spctl --status      # FileVault On, SIP enabled, Gatekeeper enabled
```

## 3. Updates
- System Settings → General → Software Update → Automatic Updates: turn on
  **all**, including "Install Security Responses and system files".
- macOS updates need a reboot, which triggers the FileVault prompt (2). On a
  server, set up `authrestart` or plan a weekly check.
- Homebrew doesn't update itself. Add a weekly
  `brew update && brew upgrade && brew cleanup`, via a launchd job or
  `brew autoupdate` (`brew tap homebrew/autoupdate`).

## 4. Stay awake and come back after power loss

```bash
sudo pmset -a sleep 0 disksleep 0 displaysleep 10 womp 1 autorestart 1
pmset -g | grep -E 'sleep|womp|autorestart'
```

The same settings are in System Settings → Energy (desktop Macs): "Prevent
automatic sleeping", "Wake for network access" and "Start up automatically
after a power failure". A laptop should stay on its charger with "Optimize
battery charging" on.

## 5. Firewall and sharing
- **Firewall on**, plus **stealth mode** (Network → Firewall → Options):
  ```bash
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
  ```
- System Settings → General → **Sharing**: turn **everything off** except what
  is needed:
  - Remote Login (SSH) only if Tailscale SSH isn't used (see 6).
  - Screen Sharing for remote help. It is reachable on LAN and tailnet only.
  - File Sharing only if needed, and only to named users.
  - Off: AirPlay Receiver, Media Sharing, Printer Sharing, Remote Management
    and Remote Apple Events.
- **Router:** no port forwards to the Mac, **UPnP/NAT-PMP off**, strong router
  admin password, firmware updates on. Remote access goes through Tailscale;
  nothing else comes in.

## 6. Tailscale on a headless Mac
- The App Store and standalone apps run in the logged-in user's session. For
  a server that must be reachable **before anyone logs in** (for example after
  an `authrestart`), use the **open-source `tailscaled`** through Homebrew. It
  runs as a root LaunchDaemon:
  ```bash
  brew install tailscale
  sudo brew services start tailscale
  sudo tailscale up --ssh --hostname=<mac-name> --auth-key=tskey-auth-XXXX    # tagged key, e.g. tag:home
  ```
- The Tailscale SSH **server** is only supported by this open-source variant
  on macOS; the GUI apps can't host it. Verify against the current Tailscale
  docs before relying on it. If it isn't available, use macOS Remote Login
  with the key-only drop-in below.
- Don't run the GUI app and the Homebrew daemon at the same time.
- Tag it (`tag:home`) and add an SSH `check` rule for it in the ACL, as for the
  VPS.

Key-only macOS OpenSSH (only if Remote Login is on):

```bash
sudo tee /etc/ssh/sshd_config.d/100-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers <admin-user>
EOF
sudo sshd -t && sudo launchctl kickstart -k system/com.openssh.sshd
```

Put the key in `~<admin-user>/.ssh/authorized_keys` **before** you reload. Use
the same 1Password ed25519 approach as for the VPS
(`ssh-keys-and-1password.md`): a separate key item for the Mac server, and a
`Host` entry with `IdentityFile …pub` and `IdentitiesOnly yes`.

## 7. Services on the Mac
- Run them as **launchd** agents/daemons (`brew services`, or a plist in
  `/Library/LaunchDaemons` with `UserName` set to the standard user), not in an
  open Terminal window.
- **Bind to `127.0.0.1`** and publish:
  - to the tailnet: `tailscale serve`
  - to the internet: `cloudflared` on the Mac (`brew install cloudflared`, same
    standard `cloudflared service install <token>` as the VPS) plus Access
- Docker Desktop and OrbStack publish `-p 8080:8080` on **all interfaces**,
  just as on Linux. Use `127.0.0.1:8080:8080`.

## 8. Backups
- **Time Machine** to an external disk with **encryption on** (Time Machine →
  add disk → Encrypt backup).
- Offsite: `brew install restic` and back up to R2, same as the VPS, from a
  launchd job. Or back up to the VPS over Tailscale.
- Test a restore once: Finder → Enter Time Machine on a folder.

## 9. Health checks
- Ping Healthchecks.io from the Mac every hour (a launchd job with `curl -fsS`).
  If it misses, the Mac is down, asleep, stuck at the FileVault prompt, or
  offline.
- Optional: Uptime Kuma or the VPS's monitoring can probe the Mac over the
  tailnet.

## 10. Checklist for the log
- [ ] Separate admin and standard accounts; guest off; Find My on
- [ ] FileVault on, recovery key in the password manager, power-loss plan recorded
- [ ] Automatic macOS updates on; Homebrew update cadence set
- [ ] pmset: no sleep, autorestart on
- [ ] Firewall and stealth mode on; unused Sharing off; router has no forwards and UPnP off
- [ ] Tailscale daemon (brew) up, tagged, SSH policy in check mode
- [ ] Services on launchd, bound to 127.0.0.1
- [ ] Time Machine encrypted, offsite backup, restore tested
- [ ] Healthchecks heartbeat
