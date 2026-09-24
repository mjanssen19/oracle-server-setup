# SSH keys and secrets with 1Password

This is the recommended setup for the operator's Mac:
- The **SSH private key lives only in 1Password.** It is never a file in
  `~/.ssh`.
- Each use is approved with Touch ID.
- Every setup secret is read from 1Password at the moment it's needed.

It works the same for Terminal, VS Code Remote-SSH and git. Verified on the
owner's Mac with VS Code Remote-SSH to alfred (2026-09-23).

Without 1Password, the fallback is at the end: a local ed25519 key with a
passphrase, or a FIDO2 hardware key.

---

## 1. One-time setup on the Mac

1. Install the 1Password app, then the CLI: `brew install 1password-cli`.
2. 1Password → **Settings → Developer**:
   - **Use the SSH agent**: on
   - **Integrate with 1Password CLI**: on (lets `op` use Touch ID instead of a
     separate login)
   - Authorization: **Ask approval for each new application**. Optionally
     "remember for" a short period.
3. Point SSH at the 1Password agent. Add this to the **top** of `~/.ssh/config`:
   ```sshconfig
   Host *
       IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
   ```
4. Check it:
   ```bash
   op whoami                     # CLI talks to the app
   ssh-add -l                    # with SSH_AUTH_SOCK unset, this lists nothing; use the next line
   SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock ssh-add -l   # lists the 1Password keys
   ```

**Vault layout for a friend's server.** Make one vault per server, for example
`Server-<name>`. Share it with the helper only while setup runs, then remove
the helper, or keep them in on purpose as the second admin. Everything for the
server goes in that vault:
- the SSH key
- the Oracle login and MFA recovery codes
- the Cloudflare token
- the tunnel token
- the R2 key and the restic password
- the serial-console password
- the ntfy and Healthchecks URLs

## 2. Create the server key: ed25519, inside 1Password

The app: New Item → **SSH Key** → Add Private Key → **Generate a New Key** →
**Ed25519**. Title it `<server> admin (<person>)`.

Or with the CLI (check `op item create --help` if the flag has changed):

```bash
op item create --category ssh --vault "Server-<name>" --title "<server> admin" --ssh-generate-key ed25519
```

Export **only the public key**. This file is needed twice: for the Oracle
instance, and to tell SSH which key to use (section 3).

```bash
op read "op://Server-<name>/<server> admin/public key" > ~/.ssh/<server>.pub
chmod 644 ~/.ssh/<server>.pub
cat ~/.ssh/<server>.pub        # starts with ssh-ed25519
```

Paste this public key into **Create instance → Add SSH keys → Paste public
keys** (oracle-cloud.md 2.4).

Why ed25519:
- It is small and fast, with no parameter choices to get wrong.
- The hardened sshd (`templates/sshd-99-hardening.conf`) accepts it, and it is
  what every audited server uses.
- One key per person per server (or per fleet). Never share a key between
  people. Removing someone is then a single line in `authorized_keys`.

## 3. `~/.ssh/config` per server: avoid "Too many authentication failures"

The 1Password agent offers **every** key it holds, one after another. The
hardened server allows `MaxAuthTries 3`. With four or more keys in 1Password,
the server disconnects before the right key is tried.

The fix is to name the key by its **public** key file. 1Password then offers
only the matching private key:

```sshconfig
Host <server>                       # Tailscale MagicDNS name
    HostName <server>
    User ubuntu
    IdentityFile ~/.ssh/<server>.pub
    IdentitiesOnly yes
    ForwardAgent no

Host <server>-public                # fallback: from the home IP over the public address
    HostName <public-ip>
    User ubuntu
    IdentityFile ~/.ssh/<server>.pub
    IdentitiesOnly yes
    ForwardAgent no
```

Then:
- `ssh <server>` over Tailscale
- `ssh <server>-public` as the fallback from home
- In VS Code: Remote-SSH → *Connect to Host* → pick the same names. VS Code uses
  this config and the 1Password agent, and prompts for Touch ID.

Notes:
- **Tailscale SSH doesn't use the key at all.** It authenticates by tailnet
  identity, plus the browser check in `check` mode. The key matters for the
  OpenSSH fallback, for VS Code and for any `scp` or `rsync` over OpenSSH.
  Test both paths.
- **`ForwardAgent no`.** Forwarding the agent lets anyone with root on the
  server use your keys while you're connected. If git on the server needs your
  GitHub key, prefer a separate **deploy key** stored on the server. Otherwise,
  enable forwarding for that host only, and rely on 1Password's per-request
  approval.
- Optional: limit which keys the agent offers at all with
  `~/.config/1Password/ssh/agent.toml`. Set `[[ssh-keys]]` blocks to specific
  vaults or items.

## 4. On the server: one key per person, nothing else

```bash
cat ~/.ssh/authorized_keys          # expected: one ssh-ed25519 line per person, with a clear comment
```

- Add the comment in 1Password's public key, or append it by hand, e.g.
  `ssh-ed25519 AAAA… <person>-1password-2026-09`.
- Remove Oracle's launch-time key if it wasn't this one, and any `ssh-rsa`
  lines. Test the new key **first**, in a second session.
- Rotating a key:
  1. Generate a new key in 1Password and append it on the server.
  2. Test it.
  3. Delete the old line.
  4. Archive the old item in 1Password.

### Auditing keys by fingerprint

Public keys aren't secret, but fingerprints are easier to compare.
1Password shows the same SHA256 fingerprint on each SSH key item.

```bash
sudo sh -c 'for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do [ -s "$f" ] && { echo "-- $f"; ssh-keygen -lf "$f"; }; done'
# which keys were actually used (sshd logs the fingerprint of each login):
sudo journalctl -u ssh --since -30days | grep -oE 'Accepted publickey for [a-z]+ from [0-9.a-f:]+ .* SHA256:[A-Za-z0-9+/]+' | awk '{print $4,$6,$NF}' | sort | uniq -c
# is a given public key anywhere? (paste the key's base64 part)
sudo grep -rlF 'AAAAC3Nza…' /root/.ssh /home/*/.ssh
```

- **Oracle's launch key.** The key pasted at instance creation (often
  `ssh-rsa … ssh-key-YYYY-MM-DD`) sits in `ubuntu`'s file and in root's. Root's
  copy has a forced "log in as ubuntu" command. Confirm it with
  `curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/metadata/ssh_authorized_keys | ssh-keygen -lf -`.
  If it isn't the operator's key, remove it from both files, after checking
  the logs show it unused. cloud-init re-adds it only if the boot volume is
  restored into a **new** instance. Note that in the setup log.
- **Unknown key: archive, don't delete.** Comment the line out in place, with
  a note: what's known about it, the fingerprint, the date, and a revisit date
  about 1 month out. Put the revisit date in the log's open items.
  ```
  # ARCHIVED 2026-09-23: origin unknown, unused since <date>. Revisit 2026-10-23: delete if nothing broke.
  # ssh-ed25519 AAAA… deploy
  ```
  Restoring it means removing the leading `# `. Always back up the file first
  (`cp -p authorized_keys authorized_keys.bak-$(date +%F)`).
- **One key per person, plus deploy keys named by purpose.** A deploy key for
  CI or another server should say which one in its comment, e.g.
  `numbersgamearm01-deploy-to-alfred`. alfred's unnamed `deploy` key couldn't
  be traced to anything.

## 5. Setup secrets from 1Password, never in files

These replace the plain `~/.config/serversetup/*.env` files in
`accounts-and-api-keys.md`.

**The token is used from the laptop.** Keep an env file containing only
**references**:

```bash
cat > ~/.config/serversetup/cloudflare.env <<'EOF'
CF_API_TOKEN="op://Server-<name>/Cloudflare setup token/credential"
CF_ACCOUNT_ID="op://Server-<name>/Cloudflare setup token/account id"
CF_ZONE_ID="op://Server-<name>/Cloudflare setup token/zone id"
EOF
op run --env-file ~/.config/serversetup/cloudflare.env -- \
  sh -c 'curl -s https://api.cloudflare.com/client/v4/user/tokens/verify -H "Authorization: Bearer $CF_API_TOKEN" | jq .result.status'
```

`op run` resolves the references for that one command only, and masks the
values if they appear in the output.

**A secret goes to the server** (tunnel token, restic env). Pipe it straight
from 1Password into a root-only file, so it never touches the laptop's disk
or the shell history:

```bash
op read "op://Server-<name>/Tunnel token/password" | \
  ssh <server> 'sudo cloudflared service install "$(cat)"'      # standard install, token never on a command line you type

# multi-value files: keep a template with op:// references, inject, pipe
op inject -i restic.env.tpl | ssh <server> 'sudo sh -c "umask 077; mkdir -p /etc/restic; cat > /etc/restic/env"'
```

`restic.env.tpl` holds only references, so it's safe to keep with the setup
notes:

```sh
RESTIC_REPOSITORY=s3:https://{{ op://Server-<name>/R2 backup/endpoint }}/{{ op://Server-<name>/R2 backup/bucket }}
RESTIC_PASSWORD={{ op://Server-<name>/restic repository/password }}
AWS_ACCESS_KEY_ID={{ op://Server-<name>/R2 backup/access key id }}
AWS_SECRET_ACCESS_KEY={{ op://Server-<name>/R2 backup/secret access key }}
AWS_DEFAULT_REGION=auto
```

**Generating new secrets** (restic password, serial-console password): let
1Password generate them, e.g. `op item create --category password --generate-password=32,letters,digits …`.
Then read them with `op read`. They never get typed.

**Rule for Claude during setup:** use `op read` or `op run` inline, and never
`echo` a secret or put it in a command argument that lands in the transcript.
When a value has to be entered by hand, ask the operator to paste it into the
1Password item, not into the chat.

## 6. Without 1Password

- **KeePassXC** can be the SSH agent and the secret store instead (`local-password-manager.md`).
  Map entries become `kpxc:<entry>` in place of `op://…`.

- **Local key with a passphrase:**
  ```bash
  ssh-keygen -t ed25519 -a 100 -C "<person>@<laptop> $(date +%Y-%m)" -f ~/.ssh/<server>
  ```
  Add `UseKeychain yes` and `AddKeysToAgent yes` in `~/.ssh/config` on macOS.
- **FIDO2 hardware key** (YubiKey etc.):
  ```bash
  ssh-keygen -t ed25519-sk -O resident -O verify-required
  ```
  The private key can't leave the token, and each login needs a touch. The
  hardened sshd accepts `sk-ssh-ed25519@openssh.com` by default.
- Either way, the same `IdentityFile` plus `IdentitiesOnly yes` config applies.
