#!/bin/sh
# Persist the kernel log to eMMC every second so a panic/oops survives reboot.
# Per-boot files: a crash log is never clobbered by the *next* boot.
SOAK=/root/soak
mkdir -p $SOAK
BOOT=$(cat /proc/sys/kernel/random/boot_id)
LOG=$SOAK/dmesg.$BOOT
ln -sf dmesg.$BOOT $SOAK/dmesg.last
echo "===== KCAPTURE START $(date '+%H:%M:%S') boot=$BOOT =====" > $LOG
sync

# keep only the newest 8 per-boot logs
ls -1t $SOAK/dmesg.* 2>/dev/null | /bin/grep -v 'dmesg.last' | tail -n +9 | while read f; do
	rm -f "$f"
done

while :; do
	tmp=$LOG.tmp
	{ echo "----- $(date '+%H:%M:%S') uptime=$(cut -d. -f1 /proc/uptime)s -----"; dmesg; } > $tmp 2>/dev/null
	mv $tmp $LOG 2>/dev/null
	sync
	sleep 1
done
