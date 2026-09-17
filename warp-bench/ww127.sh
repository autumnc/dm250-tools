#!/bin/sh
# ww127: WARM warp on #127 to test the sdio_reset_comm fix.
#
# #127 clears MMC_CARD_REMOVED at the top of sdio_reset_comm() (sdio.c), so the
# SDIO re-init after a warp can actually probe the (rfkill power-cycled) dongle
# instead of short-circuiting every command with -ENOMEDIUM(-123).  On #126 the
# warm warp resumed fine (rc=0) but wifi stayed dead: dhd_open ->
# wl_android_wifi_on -> sdio_reset_comm -> -123.  Expected on #127: the wifi
# recovery (echo 0/1 > /sys/class/rkwifi/driver) brings wlan0 back.
#
# Magic is cleared the instant the warp returns so a surprise self-reboot (seen
# once on #126) cannot drop us into a U-Boot warp-boot black screen.
F=/root/ww127.txt
GW=192.168.50.1
MAGIC=/etc/warp/p5_magic8.bin

alive  () { ping -c1 -W2 "$GW" >/dev/null 2>&1 && echo OK || echo FAIL; }
ts     () { cut -d' ' -f1 /proc/uptime; }
op     () { cat /sys/class/net/wlan0/operstate 2>&1; }
magic  () { od -An -tx1 -N8 -j0 /dev/mmcblk0p5 2>/dev/null | tr -d ' \n'; echo; }
bfshow () { od -An -tx1 -N4 -j$((0x20000)) /dev/mmcblk0p5 2>/dev/null | tr -d ' \n'; echo; }
bfclear(){ dd if=/dev/zero of=/dev/mmcblk0p5 bs=1024 seek=128 count=1 conv=notrunc 2>/dev/null; }
magclear(){ dd if=/dev/zero of=/dev/mmcblk0p5 bs=1 seek=0 count=8 conv=notrunc 2>/dev/null; }

{
	echo "================ ww127 start $(date) ================"
	echo "uname: $(uname -a)"
	[ -e /proc/warp_watch_auto ] && echo 0 > /proc/warp_watch_auto
	echo "PRE t=$(ts) operstate=$(op) ping=$(alive) magic=$(magic) bf=$(bfshow)"

	echo ">>> quiesce wifi traffic"
	pkill -f 'soak2[.]sh gw' 2>&1
	sleep 15
	echo "    after quiesce t=$(ts) ping=$(alive) operstate=$(op)"

	echo ">>> arm magic, clear bootflag"
	bfclear; dd if="$MAGIC" of=/dev/mmcblk0p5 bs=1 seek=0 count=8 conv=notrunc 2>/dev/null; sync
	echo "    magic=$(magic) bf=$(bfshow)"

	echo ">>> WARM warp (halt=0)"
	echo 0 > /proc/warp/halt
	echo 0 > /proc/warp/canceled 2>/dev/null
	echo 1 > /proc/warp/compress 2>/dev/null
	sync
	echo disk > /sys/power/state
	RC=$?
	echo ">>> echo disk RETURNED rc=$RC at t=$(ts)"
	echo "    post-warp operstate=$(op) ping=$(alive)"

	echo ">>> clear magic+bf now (reboot safety)"
	magclear; bfclear; sync
	echo "    magic=$(magic) bf=$(bfshow)"

	echo ">>> dump journal"
	dd if=/dev/mmcblk0p5 bs=1 skip=98304 count=8192 2>/dev/null > /root/jrnl-warm127.bin
	ls -l /root/jrnl-warm127.bin

	echo ">>> [A] force dhd_open via link down/up"
	ip link set wlan0 down 2>&1
	sleep 2
	ip link set wlan0 up 2>&1
	sleep 5
	echo "    after link cycle operstate=$(op) ping=$(alive)"

	echo ">>> [B] rkwifi driver reload (known recovery path)"
	echo 0 > /sys/class/rkwifi/driver 2>&1
	sleep 3
	echo 1 > /sys/class/rkwifi/driver 2>&1
	sleep 8
	echo "    after reload operstate=$(op) ping=$(alive)"

	echo ">>> dmesg tail (wifi)"
	dmesg 2>&1 | /bin/grep -iE 'sdio_reset_comm|resetting SDIO|dhd_open|wlan|mmc2|marking card removed|wifi' | tail -30
	echo "================ ww127 end $(date) ================"
} >>"$F" 2>&1
