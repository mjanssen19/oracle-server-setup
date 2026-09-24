# Accounts and API credentials

> **Click paths are unverified.** The console and dashboard steps in this file were written
> from memory and haven't been checked click by click. If a label doesn't match, look it up in
> the vendor docs; don't guess. CLI and API commands are more stable, but check `--help` too.

Goal: in about 30 minutes the operator has every account and a
**least-privilege, short-lived** credential for each. These are the *setup-time* credentials, deleted in
Phase 8. The long-lived ones the agent uses afterwards (instance principal, account-owned
Cloudflare token, Vault or 1Password storage) are in `automation-credentials.md`. Claude can then do the
tedious parts (VCN rules, tunnel, DNS, Access) through APIs, not by describing
dashboard clicks.

Ground rules to tell the operator up front:

- Setup credentials live on **the laptop**, in files with mode 600 or in the
  macOS Keychain. They never go on the server and never into chat.
- Each one gets **deleted or expires** when setup is done.
- The server only ever holds narrow runtime secrets: the tunnel token, the R2
  key and the notify URL. Each sits in a root-only file.
- Everything goes into the owner's password manager as well.

> Console paths change. If a label below doesn't match, search the console
> for the key word ("API keys", "API Tokens", "Auth keys"). Don't guess.

---

## 1.0 Password manager and laptop tools (laptop)

**Recommended: 1Password.** It holds the SSH key through the 1Password SSH
agent, and every token below as an item in a `Server-<name>` vault. Commands
then use `op run` / `op read`. Follow
[`ssh-keys-and-1password.md`](ssh-keys-and-1password.md) first. The file- and
Keychain-based steps in this section are the fallback without 1Password.
**Prefer open source and local?** Use KeePassXC (`local-password-manager.md`) in the same places.

```bash
# macOS
brew install oci-cli jq
brew install --cask tailscale      # or the App Store version
oci --version && jq --version
mkdir -p ~/.config/serversetup && chmod 700 ~/.config/serversetup
```

Store secrets without echoing them:

```bash
read -rs CF_API_TOKEN && printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" >> ~/.config/serversetup/cloudflare.env
chmod 600 ~/.config/serversetup/cloudflare.env
```

Or use the Keychain:

```bash
security add-generic-password -a "$USER" -s cf-setup-token -w     # prompts for the value
CF_API_TOKEN=$(security find-generic-password -a "$USER" -s cf-setup-token -w)
```

---

## 1.1 Oracle Cloud

### Account
1. Sign up at <https://signup.cloud.oracle.com>. A credit card is required for
   verification.
   - **Home region is permanent.** Pick the one closest to the users.
   - A1 (ARM) capacity varies a lot by region.
2. *(Recommended)* **Upgrade to Pay As You Go.** Go to Billing → Upgrade and
   Manage Payment.
   - Always Free resources stay free.
   - Idle Always Free instances are no longer reclaimed (Oracle reclaims an
     instance whose 95th-percentile CPU stays below 20% for 7 days).
   - "Out of host capacity" becomes much rarer.
3. Right after that, set a budget. Go to Billing → Budgets → Create Budget:
   €1/month, alert at 100% to the owner's email. That way any accidental paid
   resource is noticed within a day.
4. Turn on **MFA** for the console user under Profile → Security.

### CLI access: recommended, browser session (no long-lived key)

```bash
oci session authenticate --region eu-amsterdam-1 --profile-name setup
# A browser opens, you log in, the token is saved in ~/.oci/sessions/setup
export OCI_CLI_PROFILE=setup OCI_CLI_AUTH=security_token
oci iam region-subscription list --query 'data[].{"region":"region-name","home":"is-home-region"}' --output table
```

- The session lasts 1 hour. Refresh it with
  `oci session refresh --profile setup`, which works for up to 24 hours;
  after that, authenticate again.
- Nothing needs deleting afterwards. This is the right choice for a one-time
  setup.

### CLI access: alternative, API signing key

Use this when a long-running script, or CLI use spread over several days, is
needed.

1. Console → profile icon (top right) → **My profile** → **API keys** →
   **Add API key** → *Generate API key pair*.
   - **Download the private key.** It is shown only once.
   - Click **Add**.
2. Copy the **Configuration file preview** into `~/.oci/config`. Set
   `key_file=~/.oci/oci_api_key.pem`.
3. Lock down the files:
   ```bash
   mv ~/Downloads/*.pem ~/.oci/oci_api_key.pem
   chmod 600 ~/.oci/oci_api_key.pem ~/.oci/config
   oci setup repair-file-permissions --file ~/.oci/config
   oci iam region-subscription list        # should list the home region
   ```
4. **After setup:** go back to My profile → API keys, delete the key, and
   remove `~/.oci/oci_api_key.pem`.

### IDs you'll need (save them in the setup log; they are not secret)

```bash
TENANCY=$(oci iam compartment list --include-root --query 'data[?"compartment-id"==null].id | [0]' --raw-output 2>/dev/null \
          || awk -F= '/^tenancy/{print $2}' ~/.oci/config)
oci iam availability-domain list --compartment-id "$TENANCY" --query 'data[].name'
```

---

## 1.2 Cloudflare

### Account and domain
1. Sign up at <https://dash.cloudflare.com/sign-up> and turn on 2FA (My
   Profile → Authentication).
2. **Add the domain** (Add a site → Free plan). At the registrar, change the
   nameservers to the two Cloudflare gives you. Wait until the zone shows
   **Active**; usually minutes, sometimes a few hours.
3. **Zero Trust**:
   - Open *Zero Trust* in the sidebar and pick a team name. It becomes
     `<team>.cloudflareaccess.com`.
   - Choose the Free plan (up to 50 users; it asks for a card but charges
     €0).
   - Under Settings → Authentication, make sure **One-time PIN** is enabled
     as a login method.
4. Write down the **Account ID** and **Zone ID**. Both are shown on the
   domain's Overview page, bottom right.

### Setup API token (custom, narrow, expiring)

Go to My Profile → **API Tokens** → **Create Token** → *Create Custom Token*.

| Section | Permission | Access |
|---|---|---|
| Account | **Cloudflare Tunnel** | Edit |
| Account | **Access: Apps and Policies** | Edit |
| Account | Access: Organizations, Identity Providers, and Groups | Read |
| Zone | **DNS** | Edit |
| Zone | Zone WAF | Edit *(only if Claude should create the rate-limit rule)* |

Then set:
- **Account Resources:** Include → *the owner's account*.
- **Zone Resources:** Include → Specific zone → *the domain*. Never "All zones".
- **TTL:** end date about 7 days out.
- Optional: *Client IP Address Filtering* set to the operator's current public
  IP.

Store it in 1Password: item `Cloudflare setup token`, with fields
`credential`, `account id` and `zone id`. Then use it through `op run`
(`ssh-keys-and-1password.md` §5). Without 1Password, store it as in 1.0,
together with the IDs:

```bash
cat >> ~/.config/serversetup/cloudflare.env <<'EOF'
CF_ACCOUNT_ID=<account id>
CF_ZONE_ID=<zone id>
CF_ZONE=<example.com>
EOF
set -a; . ~/.config/serversetup/cloudflare.env; set +a
curl -s https://api.cloudflare.com/client/v4/user/tokens/verify \
  -H "Authorization: Bearer $CF_API_TOKEN" | jq '.result.status'      # expect "active"
```

**After setup:** delete the token under My Profile → API Tokens, and delete
`~/.config/serversetup/cloudflare.env`. The tunnel keeps working, because
it has its own token (1.5).

### R2 bucket and key for backups (only if Phase 6 uses R2)
1. R2 → Overview.
   - Enable R2. The free tier covers 10 GB and zero egress. It asks for a card.
   - Create a bucket named `<server>-backup`. Location: automatic, or EU
     jurisdiction if that matters.
2. R2 → **Manage API tokens** → **Create API token**:
   - Permission: **Object Read & Write**
   - Specify bucket(s): **only** that bucket
   - TTL: forever. This key is used at runtime.
3. Copy the **Access Key ID**, the **Secret Access Key** and the **S3 endpoint**
   (`https://<account-id>.r2.cloudflarestorage.com`). The secret is shown only
   once, so put it straight into the password manager. It goes to the server
   in Phase 6, into `/etc/restic/env`.

---

## 1.3 Tailscale

### Account
1. Sign up at <https://login.tailscale.com> with the identity the owner
   already uses (Google, Apple, Microsoft or GitHub). That account's 2FA
   protects the whole network.
2. Install Tailscale on the operator's laptop and phone, and log in.
3. DNS page: keep **MagicDNS** on. Enable **HTTPS certificates**; this is
   needed for `tailscale serve` HTTPS.

### ACL policy: tags and SSH, before the server joins
Access controls → edit the policy file. Merge in the following (keep the
existing `grants`/`acls` that let the owner's devices talk to each other):

```jsonc
{
  "tagOwners": {
    "tag:server": ["autogroup:admin"]
  },
  "grants": [
    // owner's devices may reach servers on any port
    {"src": ["autogroup:member"], "dst": ["tag:server"], "ip": ["*"]}
    // servers do NOT get a rule to reach members' devices unless needed
  ],
  "ssh": [
    {
      // "check" = re-authenticate in the browser every checkPeriod.
      // Because the admin user has sudo, any SSH login is effectively root.
      "action": "check",
      "checkPeriod": "12h",
      "src": ["autogroup:admin"],
      "dst": ["tag:server"],
      "users": ["ubuntu"]          // name the account explicitly; never "autogroup:nonroot" + "*":"=" maps
    }
  ]
}
```

Lessons behind this:
- Lurch's policy let every personal device log in with `accept` (no check)
  and mapped `"*":"="`. That included devices belonging to a second tailnet
  user, and other servers.
- Keep `src` to the people who administer the box, `dst` to the tag, and
  `users` to one account.

### Auth key for the server
Settings → **Keys** → **Generate auth key**:
- Reusable: **off**
- Ephemeral: **off** (a server must survive reboots)
- **Pre-approved: on** (if device approval is enabled)
- **Tags: `tag:server`**. Tagged nodes have key expiry disabled, so the server
  won't drop off after 180 days.
- Expiration: **1 day**

The key is used once, in Phase 3.3. It is typed on the server command line,
used, and then expires. It never goes into a file.

---

## 1.4 Ubuntu Pro (free: 5 machines)

<https://ubuntu.com/pro/dashboard>: sign in with an Ubuntu One account and
copy the **free personal token**. It is used once, as
`sudo pro attach <token>`, in Phase 4. It enables ESM security updates for
`main` and `universe`. Livepatch is optional (kernel patches without a reboot).

---

## 1.5 Alerting endpoints

- **ntfy** (push to phone):
  1. Install the ntfy app.
  2. Pick an unguessable topic, e.g. `openssl rand -hex 12`. On the free
     server the topic name is the only access control.
  3. Subscribe to `https://ntfy.sh/<topic>` in the app.
- **Healthchecks.io** (dead-man switch):
  1. Create a free account.
  2. Create one check per job (`nightly-patch`, `restic-backup`). Set the
     period to 1 day and the grace to 2 hours.
  3. Copy each ping URL.
  4. Integrations: email, or ntfy/Pushover.

Both URLs go on the server into `/etc/server-notify.env` (`0600 root`) in
Phase 4.

---

## Checklist before Phase 2

- [ ] The OCI CLI answers `region-subscription list`.
- [ ] The Cloudflare zone is Active, `tokens/verify` returns `active`, and the
      Account and Zone IDs are in the log.
- [ ] The Zero Trust team name is chosen and OTP is enabled.
- [ ] The Tailscale ACL has `tag:server` and the SSH `check` rule. The auth
      key is generated.
- [ ] The Ubuntu Pro token, the R2 key (if used) and the ntfy/Healthchecks
      URLs are in the password manager.
