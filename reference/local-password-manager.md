# Local, open-source password manager

This is for people who don't want (or don't only want) a cloud password
manager: an **open-source vault on their own machines**, usable both by the
human (an app) and by the agent (a CLI, through `templates/with-secrets.sh`).
It works alongside or instead of 1Password. The rest of the skill doesn't care
which one is used: map entries just change from `op://…` to `kpxc:…`, `bw:…`
or `pass:…`.

> **Look it up live.** Checked on 2026-09-23 against the KeePassXC CLI manual,
> and tested with `keepassxc-cli` 2.7.6 on Ubuntu 24.04 (`db-create`, `add`,
> `show -s -a`, key-file-only and password databases). Vaultwarden and `pass`
> steps are from their docs' main pages. Check `--help` and the linked docs
> before relying on exact flags.

## Which one

| | **KeePassXC** (recommended default) | **Vaultwarden** (self-hosted Bitwarden) | **pass** |
|---|---|---|---|
| What | a local encrypted `.kdbx` file, desktop app + `keepassxc-cli` | a server you host; the official Bitwarden apps and browser extensions talk to it | GPG-encrypted files in `~/.password-store`, CLI only |
| Best for | one person, the Mac plus a machine vault on the server | several people and devices (friend + helper), phone autofill | a server-only agent vault, minimal |
| Runs where | nothing to host; the file lives on each machine | a container on the VPS, **tailnet-only** | wherever GPG is |
| Agent access | `kpxc:<entry>` (tested) | `bw:<item>` via the `bw` CLI | `pass:<path>` |
| Main risk | losing the file plus the key/password: back it up | the vault goes down with the server, so break-glass secrets must live elsewhere too | GPG key management |
| Source | <https://keepassxc.org> | <https://github.com/dani-garcia/vaultwarden/wiki> | <https://www.passwordstore.org> |

**Break-glass rule, whatever you choose.** These must never live *only*
inside something hosted on the server they help you recover:
- the Oracle login, MFA recovery codes and the serial-console password
- the restic repo password and the R2 key
- the Tailscale account
- the key file or master password of the machine vault

Keep them in the human vault on the Mac (plus an offline copy, such as a
printed sheet or a USB stick in a drawer).

---

## KeePassXC

### Two vaults, on purpose
1. **Human vault** on the Mac:
   - Everything, including break-glass.
   - A strong master password (optionally plus a key file). Touch ID quick
     unlock in the app.
   - Sync it to the phone if wanted: the `.kdbx` over Syncthing or iCloud
     Drive, and KeePassium or Strongbox on iOS (check their licences and
     current status).
2. **Agent vault**, separate and holding **only automation secrets** (the
   Cloudflare automation token, the restic password, ntfy/Healthchecks URLs):
   - On the **VPS**: `/etc/agent/secrets.kdbx`, unlocked by the key file
     `/etc/agent/secrets.keyx`, both `0600 root`, no password, for unattended
     use.
   - On the **Mac**: `~/.config/agent/secrets.kdbx`, with its password held in
     the macOS Keychain.

   Never point the agent at the human vault: it would get *everything*.

### Server: the agent vault (key file only)

```bash
sudo apt-get install -y --no-install-recommends keepassxc     # provides keepassxc-cli (there is no -minimal package on 24.04)
sudo install -d -m 700 /etc/agent
sudo sh -c 'umask 077; head -c 64 /dev/urandom > /etc/agent/secrets.keyx'    # any file can be a key file; random is best
sudo keepassxc-cli db-create -q --set-key-file /etc/agent/secrets.keyx /etc/agent/secrets.kdbx
sudo chmod 600 /etc/agent/secrets.kdbx
```

Add a secret. The CLI prompts for it, so the operator pastes it; it never
appears on a command line or in the agent's output:

```bash
sudo keepassxc-cli add -q --no-password -k /etc/agent/secrets.keyx -p /etc/agent/secrets.kdbx cloudflare-automation
```

Or let it generate one (for example the restic repo password):
`… add -q --no-password -k … -g /etc/agent/secrets.kdbx restic-repository`.
See `keepassxc-cli add --help` for length and character options. Copy
generated break-glass values into the human vault as well.

Use it from scripts, through the map file:

```
# /etc/agent/cloudflare.map
CF_API_TOKEN=kpxc:cloudflare-automation
CF_ACCOUNT_ID=<account id>
CF_TUNNEL_ID=<tunnel id>
```

```bash
sudo with-secrets.sh /etc/agent/cloudflare.map -- cf-hostname.sh list
sudo with-secrets.sh /etc/agent/cloudflare.map -- sh -c 'echo ${#CF_API_TOKEN}'   # sanity check: length only
```

`with-secrets.sh` uses `KPXC_DB` and `KPXC_KEY`, defaulting to the paths
above. Another attribute: `kpxc:<entry>#UserName`.

Backups:
- The `.kdbx` is encrypted, so including it in restic (Layer B) is fine.
- **Exclude the key file** (`--exclude /etc/agent/secrets.keyx`) and keep a
  copy of it in the human vault, as an attachment. Otherwise a stolen backup
  holds both halves.

### Mac: the agent vault with its password in the Keychain

```bash
brew install --cask keepassxc                        # the app includes keepassxc-cli
command -v keepassxc-cli || ln -s /Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli "$(brew --prefix)/bin/"
security add-generic-password -a "$USER" -s kpxc-agent -w       # prompts: store the agent vault's password
security find-generic-password -w -s kpxc-agent | sed p | keepassxc-cli db-create -q -p ~/.config/agent/secrets.kdbx   # sed p: db-create asks twice
```

Map-file users on the Mac set:

```bash
export KPXC_DB=~/.config/agent/secrets.kdbx KPXC_KEY=/nonexistent \
       KPXC_PASSWORD_CMD="security find-generic-password -w -s kpxc-agent"
with-secrets.sh ~/.config/agent/cloudflare.map -- cf-hostname.sh list
```

Add entries to the Mac agent vault in the KeePassXC **app**. That's the easiest way: open the file, then paste the
value into a new entry.

macOS may ask once to allow `security` to read that Keychain item. Choose
"Always Allow" only for this one item.

### KeePassXC as SSH agent (instead of 1Password's)
KeePassXC can hold the ed25519 private key, as an attachment on an entry, and
load it into the SSH agent while the vault is unlocked. The app's settings
have an **SSH Agent** section (path not verified; see the KeePassXC user guide).
The rest of `ssh-keys-and-1password.md` §3 (`IdentityFile …pub` +
`IdentitiesOnly yes`) applies unchanged.

---

## Vaultwarden (only if several people or devices need to share)

Outline only. Look up the current wiki pages for the image, the config and
the backups before doing it:
- **Run it on loopback.** Docker `127.0.0.1:8222:80`, with a data volume.
- **Publish it on the tailnet only,** with HTTPS from Tailscale:
  `tailscale serve --bg --https=8443 http://127.0.0.1:8222`.
  - The Bitwarden clients need HTTPS.
  - Don't put it on the public tunnel.
  - Pick a port that no other `serve` config uses. On alfred, OpenClaw
    already serves on 443.
- **Accounts:**
  1. Create the accounts.
  2. Then set `SIGNUPS_ALLOWED=false`.
  3. Protect the admin panel: set `ADMIN_TOKEN` (the wiki explains using a
     hashed value), or leave it unset to disable the panel.
- **Backups:** the data directory goes into restic Layer B. Stop the container,
  or use SQLite's `.backup`, to get a consistent copy of the database.
- **Agent access with the `bw` CLI** (check `bw --help`):
  ```bash
  bw config server https://<server>.<tailnet>.ts.net:8443
  bw login --apikey                         # personal API key from the web vault (BW_CLIENTID/BW_CLIENTSECRET)
  export BW_SESSION=$(bw unlock --raw)      # prompts for the master password
  with-secrets.sh map -- …                  # map entries: CF_API_TOKEN=bw:cloudflare-automation
  ```
- The break-glass rule above matters most here: if the server is down, so is
  this vault.

## pass (a minimal server-only vault)

```bash
sudo apt-get install -y pass gnupg
gpg --quick-generate-key "agent@<server>" default default never   # an unattended vault means no passphrase; say so in the log
pass init agent@<server>
pass insert agent/cloudflare-automation                          # prompts; nothing on the command line
# map: CF_API_TOKEN=pass:agent/cloudflare-automation
```

A GPG key without a passphrase is only as strong as the file permissions,
the same as a root-only file. The benefit is one encrypted, git-versionable
store. Back up `~/.gnupg` separately, into the human vault.
