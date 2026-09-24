# The agent as operator: Claude Code, Hermes, OpenClaw

This skill is meant to be **run by an agent**, with the operator helping. The
human does what only a human can do, and the agent does the rest over SSH, the
Oracle CLI and the Cloudflare API. It works with any agent that can run shell
commands and read these files:
- Claude Code (CLI)
- Hermes Agent
- OpenClaw
- similar tools

## Step 1: work out where you are running

Run these read-only checks first, and adapt the rest of the skill to the
answers:

```bash
uname -s                                   # Darwin = operator's Mac, Linux = a server
[ -f /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME"
curl -s -m 2 -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/ | jq -r '.displayName // empty'   # non-empty = on an Oracle instance
command -v oci op cloudflared tailscale jq restic 2>/dev/null
tailscale status --self 2>/dev/null | head -1
```

| You are on | Reach the server by | Oracle auth | Secrets from |
|---|---|---|---|
| the operator's **Mac** | `ssh <server> '…'` (Tailscale name; `<server>-public` as fallback) | `oci session authenticate` (browser) or an IAM user key | 1Password (`op`), or a KeePassXC agent vault |
| **the Oracle VPS itself** | local shell | `OCI_CLI_AUTH=instance_principal` | OCI Vault, a KeePassXC agent vault, or a root-only file |
| another server / home server | `ssh` over Tailscale | IAM user key | 1Password Service Account, or a root-only file |

Say out loud which situation applies, before Phase 0.

## Human-only steps (the agent prepares, the human clicks)

The agent can't and shouldn't do these. For each one, look up the current
click path at that moment (vendor docs), give the operator exact steps, and
wait:
- creating accounts, payment, MFA and recovery codes (Oracle, Cloudflare,
  Tailscale, 1Password, ntfy, Healthchecks)
- moving the domain's nameservers at the registrar
- creating API tokens and keys, and storing them in 1Password or Vault (the
  agent never sees the value)
- approving browser logins: `oci session authenticate`, `cloudflared tunnel
  login`, and the Tailscale `check` mode confirmation
- editing the Tailscale ACL, and generating a tagged auth key
- Touch ID prompts from 1Password
- decisions: the interview, accepted risks, "go" for each write

Everything else is the agent's work: hardening, packages, scripts, tunnel
config, DNS, firewall rules through the playbooks, backups, alerts and
verification.

## Look it up live

Dashboards, CLI flags and permission names change. This skill records what
was true when it was written (dates are noted). At the moment of use:
- **CLI:** check `<tool> <cmd> --help` before running an unfamiliar command.
- **Click paths and permission names:** fetch the vendor doc page, and give
  the operator the current path. Say when you couldn't verify something;
  never present a remembered path as fact.
- **APIs:** on an error, read the current API reference, then fix the call.
- Record in the setup log what you checked and when ("checked 2026-10-02
  against …").

Start from these doc pages:
- Oracle IAM and instance principals: <https://docs.oracle.com/en-us/iaas/Content/Identity/home.htm>
- OCI CLI reference: <https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/>
- Cloudflare tunnels: <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/>
- Cloudflare API: <https://developers.cloudflare.com/api/>
- Tailscale: <https://tailscale.com/kb>
- 1Password SSH and CLI: <https://developer.1password.com/docs/>

## Working safely as the operator

- **A question is not an instruction.** Answer, propose, wait for a go.
  Read-only checks are fine.
- **Plan → dry run → go → change → verify → log**, for every write (see
  `playbooks.md`).
- **Secrets never enter the session:**
  - use `with-secrets.sh`, `op run` or pipes
  - check files by length, hash or fingerprint
  - redact `--token` values in any output you show
  - AI session logs are stored on disk, and have leaked tunnel tokens before
- **Prefer the vendor's standard way** (for example `cloudflared service
  install`). Harden only what the standard leaves open, and write down why.
- **The admin user has passwordless sudo**, so the agent effectively works as
  root. Be as careful as a root shell requires.
- **Don't build shell one-liners with nested quotes over SSH.** Put the
  script in a file and send it over stdin (`ssh host 'bash -s' < script.sh`,
  or `python3 -` for Python). A broken quote once made the local shell run
  documentation text as commands.

## Agent-specific notes

- **Claude Code:**
  - Run it on the operator's Mac, in a folder holding the setup log.
  - Use permission mode "ask" for writes, and allow read-only commands
    (`ss`, `systemctl status`, `journalctl`, `cat` of non-secret files).
  - Its transcripts live in `~/.claude/projects/…`, so keep secrets out of
    the session.
- **Hermes and OpenClaw** (both run on alfred):
  - They run *on* the server, with the server's user rights.
  - Their gateways listen on loopback only; their dashboards are published
    via `tailscale serve` only.
  - Give them the same `/etc/agent/*.map` + `with-secrets.sh` route, not raw
    tokens in their config.
  - Remember that chat channels (Telegram etc.) are a way in to a root-capable
    agent. Allow-list the owner only.
- **SSH from the Mac:**
  - Tailscale SSH needs no key prompts. `check` mode asks for a browser
    re-auth every 12 hours.
  - For OpenSSH with the 1Password agent, add connection sharing to
    `~/.ssh/config`, so one Touch ID covers a burst of agent commands:
    ```sshconfig
    Host *
        ControlMaster auto
        ControlPath ~/.ssh/cm-%C
        ControlPersist 10m
    ```
