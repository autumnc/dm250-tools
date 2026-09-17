#!/bin/sh
# ww126: WARM warp control on #126. #126 == #125 minus the two pre-resume
# journal markers (irq-en@2073, pdup-ok@2091). Those wrote to /dev/mmcblk0p5
# while the mmc host was still suspended by pm_device_suspend() (save side,
# warp.c:1927) and not yet re-activated by pm_device_resume() (resume side),
# which hung the warp. With them gone a warm warp (halt=0) must again run the
# in-place resume and write the post-resume markers (pm-resume, dev-resume,
# console, dpm-complete, pre-thaw, post-thaw, live-start).
#
# On success we clear the W5HD magic + bootflag so a later reboot does NOT
# trigger a U-Boot warp-boot (black screen). If the warp hangs, this tail is
# never reached and recovery must clear the magic.
F=/root/ww126.txt
GW=192.168.50.1
MAGIC=/etc/warp/p5_magic8.bin

alive  () { ping -c1 -W2 "$GW" >/dev/null 2>&1 && echo OK || echo FAIL; }
ts     () { cut -d' ' -f1 /proc/uptime; }
wst    () { echo "halt=$(cat /proc/warp/halt 2>&1) err=$(cat /proc/warp/error 2>&1) stat=$(cat /proc/warp/stat 2>&1) loadno=$(cat /proc/warp/loadno 2>&1)"; }
magic  () { od -An -tx1 -N8 -j0 /dev/mmcblk0p5 2>/dev/null | tr -d ' \n'; echo; }
bfshow () { od -An -tx1 -N4 -j$((0x20000)) /dev/mmcblk0p5 2>/dev/null | tr -d ' \n'; echo; }
bfclear(){ dd if=/dev/zero of=/dev/mmcblk0p5 bs=1024 seek=128 count=1 conv=notrunc 2>/dev/null; }
magclear(){ dd if=/dev/zero of=/dev/mmcblk0p5 bs=1 seek=0 count=8 conv=notrunc 2>/dev/null; }

{
	echo "================ ww126 start $(date) ================"
	echo "uname: $(uname -a)"
	[ -e /proc/warp_watch_auto ] && echo 0 > /proc/warp_watch_auto
	echo "PRE t=$(ts) $(wst) operstate=$(cat /sys/class/net/wlan0/operstate 2>&1) ping=$(alive) magic=$(magic) bootflag=$(bfshow)"

	echo ">>> quiesce wifi traffic"
	pkill -f 'soak2[.]sh gw' 2>&1
	sleep 15
	echo "    after quiesce t=$(ts) ping=$(alive)"

	echo ">>> arm 8-byte W5HD magic, clear bootflag"
	bfclear; dd if="$MAGIC" of=/dev/mmcblk0p5 bs=1 seek=0 count=8 conv=notrunc 2>/dev/null; sync
	echo "    magic=$(magic) bootflag=$(bfshow)"

	echo ">>> WARM warp (halt=0)"
	echo 0 > /proc/warp/halt
	echo 0 > /proc/warp/canceled 2>/dev/null
	echo 1 > /proc/warp/compress 2>/dev/null
	sync
	echo disk > /sys/power/state
	RC=$?
	echo ">>> echo disk RETURNED rc=$RC at t=$(ts) $(wst)"

	echo ">>> dump journal"
	dd if=/dev/mmcblk0p5 bs=1 skip=98304 count=8192 2>/dev/null > /root/jrnl-warm126.bin
	ls -l /root/jrnl-warm126.bin

	echo ">>> clearing magic + bootflag so a later reboot is safe"
	magclear; bfclear; sync
	echo "    final magic=$(magic) bootflag=$(bfshow)"
	echo "================ ww126 end $(date) ================"
} >>"$F" 2>&1
