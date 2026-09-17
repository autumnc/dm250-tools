#!/bin/bash
# flash-p2.sh -- flash a kernel image to the DM250's p2 and reboot into it.
#
#   ./flash-p2.sh /home/ywz/dm200_debian_kernel/kernel-144.img [tag]
#
# p2 is the kernel partition and the ONLY partition this may ever write.  p1
# holds U-Boot: touching it bricks the board.  Nothing here goes near it.
#
# The image is dd'd to the START of p2, so the tail of the partition keeps
# whatever was there before -- that is how the previous flashes were done and
# the backup below is the full 12MiB partition, not just the image.
#
# Before rebooting, W5BF (p5+0x20000) and the cold-restore marker (p5+0x1f000)
# are cleared.  If W5BF is left armed, U-Boot's warp_checkboot() sees the
# W5HD+W5BF pair and cold-restores the OLD DRAM blob instead of booting the
# kernel we just wrote.  p5+0 (the W5HD hibernation-driver header) is NEVER
# touched -- clearing it breaks warp entirely.
set -euo pipefail

IMG=${1:?usage: flash-p2.sh <image> [tag]}
TAG=${2:-$(basename "$IMG" .img | sed 's/^kernel-//')}
HOST=${HOST:-root@192.168.50.251}
BACKUP_DIR=/home/ywz/p2-backups
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no $HOST"

[ -f "$IMG" ] || { echo "no such image: $IMG"; exit 1; }
mkdir -p "$BACKUP_DIR"

echo "== reachability =="
$SSH 'true' || { echo "board unreachable"; exit 1; }
$SSH 'uname -a; uptime'

echo "== disarm the write watchpoint (armed watch + heavy I/O soft-locks) =="
$SSH 'for f in /proc/warp_watch_auto /proc/warp_watch; do [ -e $f ] && echo 0 > $f; done; \
      echo "wdt=$(ls /proc/wdt 2>&1)"'

echo "== back up p2 -> $BACKUP_DIR/p2-backup-before-$TAG.img =="
P2SZ=$($SSH 'blockdev --getsize64 /dev/mmcblk0p2')
$SSH "dd if=/dev/mmcblk0p2 bs=1M 2>/dev/null" > "$BACKUP_DIR/p2-backup-before-$TAG.img"
GOT=$(stat -c%s "$BACKUP_DIR/p2-backup-before-$TAG.img")
ls -l "$BACKUP_DIR/p2-backup-before-$TAG.img"
if [ "$GOT" != "$P2SZ" ]; then
    echo "BACKUP SHORT: got $GOT bytes, p2 is $P2SZ -- refusing to continue"
    exit 1
fi
echo "backup md5: $(md5sum < "$BACKUP_DIR/p2-backup-before-$TAG.img")"

echo "== clear W5BF + cold marker so the reboot boots NORMALLY =="
$SSH 'dd if=/dev/zero of=/dev/mmcblk0p5 bs=1024 seek=128 count=1 conv=notrunc 2>/dev/null; \
      dd if=/dev/zero of=/dev/mmcblk0p5 bs=1 seek=$((0x1f000)) count=8 conv=notrunc 2>/dev/null; sync; \
      echo "p5+0 (W5HD, must stay): $(dd if=/dev/mmcblk0p5 bs=1 count=8 2>/dev/null | od -An -tx1 | tr -d " \n")"; \
      echo "p5+0x20000 (W5BF, must be 0): $(dd if=/dev/mmcblk0p5 bs=1 skip=$((0x20000)) count=4 2>/dev/null | od -An -tx1 | tr -d " \n")"'

echo "== push image =="
scp -q "$IMG" "$HOST:/tmp/flash.img"
$SSH "md5sum /tmp/flash.img"
echo "local md5: $(md5sum < "$IMG")"

echo "== write p2 =="
$SSH 'dd if=/tmp/flash.img of=/dev/mmcblk0p2 bs=1M conv=fsync 2>&1; sync; echo "wrote p2"'

echo "== reboot =="
$SSH 'rm -f /tmp/flash.img; sync; reboot' || true
echo "issued.  waiting for the board to come back..."
sleep 45
for i in $(seq 1 40); do
    if $SSH 'true' 2>/dev/null; then
        echo "== back up after $((45 + i*10))s =="
        $SSH 'uname -a; uptime; echo "wdt=$(ls -l /proc/wdt 2>&1)"; \
              echo "watch procs: $(ls /proc/warp_watch* 2>&1)"; true'
        exit 0
    fi
    sleep 10
done
echo "board did not come back within ~7 min -- check it by hand"
exit 1
