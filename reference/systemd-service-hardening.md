# systemd service hardening template

Reference for Phase 5 of the `oracle-server-setup` skill (from numbersgamearm01). Use this
pattern when deploying any long-running Node/Python/Go process. The goal: the
service runs as a dedicated non-login user, can read its code but not modify it,
writes only where you explicitly allow, and is sandboxed so a code-exec bug has
almost nothing to reach.

---

## 1. Create a dedicated service user

One non-login system user **per service** — services should not share a UID.

```bash
sudo adduser --system --group --no-create-home --disabled-login \
     --shell /usr/sbin/nologin myapp
# Optional explicit state dir (or use StateDirectory= in the unit, below)
sudo install -d -m 0750 -o myapp -g myapp /var/lib/myapp
```

## 2. Lay down the code

Code root-owned and read-only to the service user; writable dirs explicitly
owned by the service user.

```bash
sudo install -d -m 0755 /opt/myapp
sudo cp -r ./build/* /opt/myapp/
sudo chown -R root:root /opt/myapp     # service user can read, not modify
```

## 3. The unit — `/etc/systemd/system/myapp.service`

```ini
[Unit]
Description=My application
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=myapp
Group=myapp
WorkingDirectory=/opt/myapp
ExecStart=/usr/bin/node /opt/myapp/index.js
Restart=on-failure
RestartSec=5
TimeoutStopSec=20

# Secrets: prefer EnvironmentFile (chmod 0640, owned root:myapp). Leading '-'
# makes the file optional.
EnvironmentFile=-/etc/myapp/env

# --- Filesystem isolation ---
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
# systemd-managed dirs under /var/{lib,log,cache}, created with correct owner+mode
StateDirectory=myapp
LogsDirectory=myapp
CacheDirectory=myapp

# --- Process hardening ---
NoNewPrivileges=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
PrivateUsers=yes
CapabilityBoundingSet=
AmbientCapabilities=

# --- Network ---
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
IPAddressDeny=any
IPAddressAllow=localhost
IPAddressAllow=link-local
# For general outbound (most apps need it) remove IPAddressDeny, or add
# IPAddressAllow=<cidr> lines for specific destinations.

# --- Syscalls ---
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@mount ~@reboot ~@swap ~@module ~@raw-io ~@privileged ~@debug

# --- Memory ---
# Blocks classic shellcode (RWX pages). Safe for Go/Python/Rust. Node's V8 has
# been W^X-friendly since ~v12 but some paths (legacy wasm, some eval) trip it:
# try ON; if the app dies at startup/under load with EPERM near JIT/mmap, remove.
MemoryDenyWriteExecute=yes

[Install]
WantedBy=multi-user.target
```

## 4. Enable and verify

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now myapp.service
sudo systemctl status myapp.service
sudo systemd-analyze security myapp.service     # aim for exposure under ~3.0
sudo ss -tlnp | grep myapp                       # should listen on 127.0.0.1 only
journalctl -u myapp -n 50                         # clean startup, no perm errors
```

---

## What each block buys you

| Directive | Blocks |
|---|---|
| `NoNewPrivileges=yes` | setuid/setgid escalation inside the service |
| `ProtectSystem=strict` | writes to `/`, `/usr`, `/boot`, `/etc` (override via `ReadWritePaths=`) |
| `ProtectHome=yes` | reading `/home`, `/root`, `/run/user` |
| `PrivateTmp=yes` | reading or fighting over other services' `/tmp` files |
| `PrivateDevices=yes` | access to real device nodes (only `/dev/null`, `zero`, etc. remain) |
| `PrivateUsers=yes` | seeing real UIDs of users outside the service |
| `ProtectKernelTunables/Modules/Logs` | writing `/proc/sys`, loading modules, reading kmsg |
| `ProtectControlGroups=yes` | cgroup tampering (a container-escape primitive) |
| `ProtectProc=invisible` + `ProcSubset=pid` | seeing other processes in `/proc` |
| `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` | netlink/packet sockets used in many kernel exploits |
| `RestrictNamespaces=yes` | creating new user/mount/PID namespaces |
| `RestrictSUIDSGID=yes` | creating setuid binaries on writable paths |
| `LockPersonality=yes` | changing exec personality (32-bit emulation tricks) |
| `MemoryDenyWriteExecute=yes` | classic shellcode (RWX pages) |
| `SystemCallFilter=@system-service` + denies | a large chunk of kernel attack surface |
| `CapabilityBoundingSet=` (empty) | every Linux capability — service has none |
| `IPAddressDeny=any` + selective `IPAddressAllow=` | egress to anywhere not whitelisted |

---

To publish the service, add an ingress rule pointing at `http://127.0.0.1:<port>` (see `cloudflare.md` 4.2). Don't edit a local config.yml; the tunnel is remotely managed.
