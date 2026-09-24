# Cloudflare: Tunnel, Access and WAF

The tunnel is outbound-only: cloudflared dials Cloudflare, so the Security
List and the host firewall need **no** 80/443 rules. TLS for visitors ends at
Cloudflare's edge.

> **Dashboard labels move.** Paths in this file other than token rotation were written from memory
> and have not been checked click by click. If a label doesn't match, search the dashboard or
> developers.cloudflare.com; don't guess. The API calls are the stable part.

The API calls below run on the **laptop** with the setup token from
`accounts-and-api-keys.md` 1.2. Only the *tunnel token* goes to the server.

```bash
# With 1Password: cloudflare.env holds only op:// references (ssh-keys-and-1password.md §5).
# Open a subshell with the values resolved, do the steps below in it, then `exit`:
op run --env-file ~/.config/serversetup/cloudflare.env -- bash
# Without 1Password: set -a; . ~/.config/serversetup/cloudflare.env; set +a
CF=https://api.cloudflare.com/client/v4
AUTH=(-H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
```

## 4.1 Create a remotely managed tunnel

"Remotely managed" means the ingress rules live in Cloudflare. The server runs
a generic connector with a token.

```bash
TUNNEL_NAME=<server>
TUNNEL_ID=$(curl -s "${AUTH[@]}" -X POST "$CF/accounts/$CF_ACCOUNT_ID/cfd_tunnel" \
  -d "{\"name\":\"$TUNNEL_NAME\",\"config_src\":\"cloudflare\"}" | jq -r '.result.id')
echo "TUNNEL_ID=$TUNNEL_ID" >> ~/.config/serversetup/cloudflare.env
```

The connector token for this tunnel is installed on the server in 4.3. It never
needs to be stored on the laptop: 4.3 pipes it from the API straight into the
standard installer. If you do want a copy (for example for a second replica),
save it in 1Password as item `Tunnel token` (type Password) in the server vault.

## 4.2 Ingress rules and DNS

Each hostname maps to a **loopback** service. The list ends with a
`http_status:404` catch-all.

```bash
cat > ingress.json <<'EOF'
{"config": {"ingress": [
  {"hostname": "example.com",       "service": "http://127.0.0.1:8088"},
  {"hostname": "app.example.com",   "service": "http://127.0.0.1:3000"},
  {"service": "http_status:404"}
]}}
EOF
curl -s "${AUTH[@]}" -X PUT "$CF/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" -d @ingress.json | jq '.success'
```

One proxied CNAME per hostname:

```bash
for h in example.com app.example.com; do
  curl -s "${AUTH[@]}" -X POST "$CF/zones/$CF_ZONE_ID/dns_records" \
    -d "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true}" | jq -c '{h:"'$h'",ok:.success,err:.errors}'
done
```

If a record already exists (for example an old A record for the apex),
update or delete it first. The API returns an error rather than overwriting.

**Prefer plain HTTP on the loopback hop.** If the origin must be HTTPS
(nginx with a real cert on 127.0.0.1:8443, as on alfred), set
`"originRequest": {"originServerName": "<hostname>", "matchSNItoHost": true}`
on that rule. Otherwise cloudflared sends SNI `localhost`, no vhost matches,
and visitors get a 502. A scheme/port mismatch (`http://` to a TLS port)
gives a 400. alfred hit both. Plain HTTP on loopback avoids the whole class.

## 4.3 The connector on the server: standard install

Use Cloudflare's own installer, so the dashboard and the docs match what's on
the box. (A hand-built hardened unit was tried on 2026-09-23 and reverted. The
dashboard's "install connector" steps then no longer matched, and following
them caused an outage. See lessons-learned.md.)

```bash
# cloudflared from the official apt repo (codename-independent "any" suite)
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install -y cloudflared
```

Install the service with **this tunnel's** token. Either:

- **From the laptop, token straight from the API** (never printed, no file):
  ```bash
  curl -s "${AUTH[@]}" "$CF/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | jq -r .result | \
    ssh <server> 'sudo cloudflared service install "$(cat)"'
  ```
- **Or from the dashboard:** Networking → Tunnels → **this server's tunnel**
  (check the name *and* the tunnel ID) → Add replica / install connector. Run
  the `sudo cloudflared service install eyJ…` line on the server.

What the standard install does (cloudflared 2026.9.1, observed on alfred and
lurch):
- It writes the token to `/etc/cloudflared/token` (0600 root) and a unit that
  runs `cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token`
  as root. The token is **not** in the unit or in `ps`. (Older cloudflared
  versions put it inline in the unit. If you find `--token eyJ…` in
  `systemctl cat cloudflared`, reinstall with a current version.)
- It creates `cloudflared-update.service/.timer` (daily `cloudflared update`).
  Keep it enabled: `sudo systemctl enable --now cloudflared-update.timer`.

**Verify it joined the right tunnel.** Getting this wrong is silent: the
connector is healthy, but it serves another tunnel's hostnames.

```bash
sudo journalctl -u cloudflared -n 50 --no-pager | grep -oE 'tunnelID=[0-9a-f-]{36}' | tail -1   # must be $TUNNEL_ID
curl -s http://127.0.0.1:20241/ready                                                         # readyConnections: 4
```

Then curl every hostname of **every** tunnel on the account. A connector on
the wrong tunnel breaks both tunnels.

**To reinstall or change the token:**
```bash
sudo cloudflared service uninstall && sudo cloudflared service install eyJ…
```
Running both in one line keeps the downtime to seconds.

**Updates.** cloudflared updates itself daily through its own timer, and
apt updates it as well. In 2026-08, releases 8.0/8.1 rewrote `https://` in
request paths, which broke an app on lurch and caused 16 hours of outage on
numbersgamearm01. The owner treats that as incidental and keeps normal
updates. The safety net is an **external probe** of the public hostnames
(Phase 6) that alerts within minutes of a bad update.

Check what the connector actually received, from the server:

```bash
curl -s http://127.0.0.1:20241/config | jq -r '.config.ingress[] | "\(.hostname // "*")\t\(.service)"'
```

## 4.4 Cloudflare Access for anything not fully public

Admin UIs, web terminals, private documents, dashboards, staging.

First create a reusable allow policy with the email allow-list:

```bash
POLICY_ID=$(curl -s "${AUTH[@]}" -X POST "$CF/accounts/$CF_ACCOUNT_ID/access/policies" -d '{
  "name": "owner-only", "decision": "allow",
  "include": [ {"email": {"email": "owner@example.com"}} ],
  "session_duration": "24h"
}' | jq -r '.result.id')
```

Then create an app per hostname and attach the policy:

```bash
curl -s "${AUTH[@]}" -X POST "$CF/accounts/$CF_ACCOUNT_ID/access/apps" -d "{
  \"name\": \"admin\", \"type\": \"self_hosted\", \"domain\": \"admin.example.com\",
  \"session_duration\": \"24h\", \"app_launcher_visible\": false,
  \"policies\": [ {\"id\": \"$POLICY_ID\", \"precedence\": 1} ]
}" | jq '.success, .errors'
```

If the API shape has moved, create the same thing in the dashboard: Zero
Trust → Access → Applications → Add → Self-hosted.

- **The email allow-list is what does the protecting.** One-time PIN is only
  the login method, and OTP without an allow-list lets anyone mail themselves
  a code.
- **Create the Access app before (or together with) the DNS record** for a
  private hostname, so it is never briefly public.
- **Verify** in a private window, or with:
  ```bash
  curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://admin.example.com/
  ```
  The expected result is `302 https://<team>.cloudflareaccess.com/...`.
- Access on a web terminal (alfred's `term.` → ttyd on 127.0.0.1) is the
  *only* thing between the internet and a shell. Keep its allow-list to one
  person and a short session. Better, don't publish a terminal at all: use
  Tailscale SSH.
- **Unguessable URLs are not access control**, but they are a fine second
  layer. alfred's `decks.` uses `/d/<random-hex>/` slugs behind Access, and
  its landing page lists nothing.

## 4.5 Brute force behind a tunnel

Every tunnelled request reaches the origin from `127.0.0.1`, or from the
cloudflared host's LAN IP on a home server. As a result:

- **fail2ban on the origin cannot ban anyone.** Banning the source bans
  cloudflared.
- An app's own throttling counts all users as one IP. Fix this with the
  trusted-proxy setting, e.g. Nextcloud `TRUSTED_PROXIES`, Home Assistant
  `trusted_proxies`, or SABnzbd `verify_xff_header`.
- **The real defences are at Cloudflare:**
  - Access, for anything private.
  - For truly public logins, a **WAF rate-limiting rule**. Free plans get one.
    Set it up under Security → WAF → Rate limiting rules. Example: path
    contains `/login` → 5 requests per 10 s per IP → Block for 10 min.
- Test that failed logins actually get logged and throttled. On lurch,
  Nextcloud WebDAV Basic-Auth failures were neither logged nor throttled.

## 4.6 Grey-cloud (DNS-only) hosts

Use these only when the origin must terminate TLS itself: non-HTTP protocols,
client-certificate auth, or an MCP/OAuth endpoint with special needs
(numbersgamearm01's `mcp.`). That needs 80/443 in *both* firewalls, plus
Caddy with Let's Encrypt HTTP-01, plus UDP 443 if HTTP/3 is advertised.
**Don't add Caddy site blocks for hostnames that don't resolve to the box.**
ACME retries forever and fills the journal.

## 4.7 After setup
- Delete the setup API token (My Profile → API Tokens).
- Record in the log: the tunnel name/ID, the hostname table, the Access apps
  and their allow-lists, the WAF rule, and where the tunnel token lives.
- Rotate the tunnel token if it is ever exposed (checked against developers.cloudflare.com and
  done on alfred and lurch, 2026-09-23):
  1. Dashboard → **Networking → Tunnels** → *this server's tunnel* (check the ID) → **Rotate token**
     (some docs pages: Overview → **Refresh token**).
  2. **The rotation does not reach the server.** The running connector keeps working on its
     existing session, but the next restart fails with "Invalid tunnel secret", so finish step 3
     right away (a nightly reboot would take the tunnel down).
  3. Get the new token: **Add replica** shows `sudo cloudflared service install eyJ…`. On the server:
     `sudo cloudflared service uninstall && sudo cloudflared service install eyJ…`.
     Alternatives: `cloudflared tunnel login` (browser approval) then `cloudflared tunnel token <tunnel-id>`,
     and delete `~/.cloudflared/cert.pem` afterwards, since it can manage every tunnel in the account.
     Or the API: `PATCH /accounts/{account_id}/cfd_tunnel/{tunnel_id}` with a new base64 `tunnel_secret`.
  4. Verify the tunnel ID in the journal, and curl all hostnames of all tunnels.
