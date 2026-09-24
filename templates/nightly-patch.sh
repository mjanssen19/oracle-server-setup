#!/bin/bash
# /usr/local/sbin/nightly-patch.sh  (root:root 0750). Run by nightly-patch.timer.
#
# Nightly OS patching. It replaces unattended-upgrades as the only thing that
# installs packages (mask apt-daily-upgrade.timer). Built from the three reference servers:
#   - update and upgrade run in ONE process. Stock u-u evaluated lists up to 12h stale
#     and missed a security update while logging success (numbersgamearm01, 2026-08-11).
#   - --with-new-pkgs is load-bearing: without it a new kernel ABI package
#     (linux-image-X.Y-NNNN) is never installed. Silently, forever.
#   - Reboot right after the upgrade, not at a fixed clock time "before" the window.
#     That slipped a day and left 20h on an unpatched kernel.
#   - Lock waits use DPkg::Lock::Timeout, not process-name checks. pgrep -x never
#     matches "unattended-upgrade" because of the 15-char comm limit.
#   - Success pings Healthchecks and failure pushes to ntfy, so silence is
#     noticed. A box with no MTA drops MAILTO mail.
#
# Hooks: executables in /etc/nightly-patch.d/ run after apt and before the reboot
# decision, in name order, as root (e.g. 50-openclaw-update on alfred). A failing
# hook is logged and alerted but does not stop patching or the reboot.
#
# Usage: nightly-patch.sh [--dry-run]   (--dry-run: simulate apt, list hooks, never reboot)
set -Eeuo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG=/var/log/nightly-patch.log
[ "$DRY" = 1 ] || exec >>"$LOG" 2>&1
# shellcheck disable=SC1091
[ -r /etc/server-notify.env ] && . /etc/server-notify.env
HC_URL=${HC_PATCH_URL:-}

log()  { echo "$(date -u '+%F %T')Z $*"; logger -t nightly-patch -- "$*"; }
ping_hc() { [ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 "$HC_URL$1" >/dev/null || true; }
fail() {
  log "FAILED at line $1"
  /usr/local/sbin/notify.sh "nightly-patch FAILED on $(hostname) (line $1). See $LOG" || true
  ping_hc /fail
}
trap 'fail $LINENO' ERR

APT=(apt-get -q -o DPkg::Lock::Timeout=900
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log "=== start$([ "$DRY" = 1 ] && echo ' (dry run)') ==="
if [ "$DRY" = 1 ]; then
  timeout 900 "${APT[@]}" update
  "${APT[@]}" -s --with-new-pkgs upgrade | grep -E '^(Inst|Remv)' || echo "(nothing to upgrade)"
  "${APT[@]}" -s autoremove --purge | grep -E '^(Purg|Remv)' || echo "(nothing to autoremove)"
else
  ping_hc /start
  timeout 900  "${APT[@]}" update
  timeout 3600 "${APT[@]}" -y --with-new-pkgs upgrade
  timeout 900  "${APT[@]}" -y autoremove --purge   # /boot on Oracle is <1 GB; old kernels fill it
  "${APT[@]}" -y autoclean
fi

# Held packages (apt-mark hold) are upgraded by hand. Report pending ones so a hold doesn't become "forgotten".
held=$(apt-mark showhold || true)
upgradable=$(apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1 || true)
pending=$(comm -12 <(sort -u <<<"$held") <(sort -u <<<"$upgradable") | sed '/^$/d' | paste -sd' ')
left=$(comm -13 <(sort -u <<<"$held") <(sort -u <<<"$upgradable") | sed '/^$/d' | paste -sd' ')
if [ -n "$pending" ]; then
  log "held packages with upgrades waiting: $pending"
  /usr/local/sbin/notify.sh "$(hostname): held packages have upgrades waiting: $pending" || true
fi
[ -n "$left" ] && log "still upgradable after run (phased updates are normal): $left"

# Hooks: non-fatal
if [ -d /etc/nightly-patch.d ]; then
  for h in /etc/nightly-patch.d/*; do
    [ -f "$h" ] && [ -x "$h" ] || continue
    if [ "$DRY" = 1 ]; then log "would run hook $h"; continue; fi
    log "hook $h"
    if ! timeout 1800 "$h"; then
      log "hook $h FAILED (continuing)"
      /usr/local/sbin/notify.sh "$(hostname): nightly-patch hook $(basename "$h") failed" || true
    fi
  done
fi

if [ "$DRY" = 1 ]; then
  [ -f /var/run/reboot-required ] && log "reboot currently pending (dry run: not rebooting)" || log "no reboot pending"
  log "=== dry run done ==="; exit 0
fi

ping_hc ""
if [ -f /var/run/reboot-required ]; then
  log "reboot required ($(cat /var/run/reboot-required.pkgs 2>/dev/null | paste -sd' ')), rebooting in 60s"
  sleep 60                                  # let logs flush and the ping land
  systemctl reboot
else
  log "no reboot required"
fi
log "=== done ==="
