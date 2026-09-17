#!/bin/bash
# deploy-coldwarp.sh -- install the cold-warp userspace half on the DM250.
#
# Run from the host with the board reachable at $HOST.
#
#   ./deploy-coldwarp.sh [--keep-wdt]
#
# --keep-wdt leaves the /var/service/wdt-arm symlink in place.  Pass it when
# the running kernel has CONFIG_RK312X_WDT (i.e. #144 and later).  Without it
# the symlink is removed, which is only correct for a kernel built with
# CONFIG_WARP_DIAG=n and no separate watchdog -- there /proc/wdt does not
# exist and wdt-arm spins doing nothing.
set -euo pipefail

HOST=${HOST:-root@192.168.50.251}
SRC=$(cd "$(dirname "$0")" && pwd)
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no $HOST"

KEEP_WDT=0
[ "${1:-}" = "--keep-wdt" ] && KEEP_WDT=1

echo "== staging files to $HOST =="
$SSH 'mkdir -p /root/bin /etc/sv/lidwarp'
scp -q "$SRC/coldwarp.sh" "$SRC/lidwarp.sh" "$HOST:/root/bin/"
scp -q "$SRC/run" "$HOST:/etc/sv/lidwarp/run"
scp -q /tmp/tmux.conf.dm250 "$HOST:/root/.tmux.conf"

$SSH 'chmod +x /root/bin/coldwarp.sh /root/bin/lidwarp.sh /etc/sv/lidwarp/run'

echo "== enabling lidwarp =="
$SSH 'ln -sfn /etc/sv/lidwarp /var/service/lidwarp; sv status lidwarp 2>&1 || true'

if [ "$KEEP_WDT" = 1 ]; then
    echo "== keeping /var/service/wdt-arm (kernel has CONFIG_RK312X_WDT) =="
    $SSH '[ -L /var/service/wdt-arm ] && echo "wdt-arm present" || echo "WARNING: wdt-arm symlink missing"'
else
    echo "== removing /var/service/wdt-arm (no /proc/wdt in this kernel) =="
    $SSH 'if [ -L /var/service/wdt-arm ]; then rm -f /var/service/wdt-arm; echo removed; else echo "already absent"; fi'
fi

echo "== verify =="
$SSH '/bin/grep -n "coldwarp\|shutdown" /root/.tmux.conf | head; \
      echo "--- /proc/wdt ---"; ls -l /proc/wdt 2>&1; \
      echo "--- services ---"; sv status lidwarp warpnet 2>&1; \
      echo "--- ac ---"; cat /sys/class/power_supply/ac/online 2>&1'
echo "done."
