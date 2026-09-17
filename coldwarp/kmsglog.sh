#!/bin/sh
# Durable dmesg trail for hang debugging. APPEND (not truncate) so the trail
# spans reboots; a START marker delimits each boot's capture.
# NOTE: a shell `read` loop over /dev/kmsg fails with EINVAL (byte-wise reads
# are not supported); `cat` reads in record-sized chunks and streams fine.
LOG=/var/log/kmsg.log
echo "===== LOGGER START uptime=$(cut -d. -f1 /proc/uptime)s $(date '+%H:%M:%S') =====" >> "$LOG"
( while :; do sync; sleep 1; done ) &
cat /dev/kmsg >> "$LOG"
