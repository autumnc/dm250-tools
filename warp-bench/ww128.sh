#!/bin/sh
# ww128: WARM warp on #127, clean run to actually exercise Fix A.
#
# Why this run differs from ww127: ww127's "echo disk" returned EIO in 0.5s
# (a real warm warp takes seconds), so the warp never ran and Fix A was never
# tested against a post-warp SDIO bus.  This run:
#   - magic is ALREADY armed at boot (verified), so warp_work_init() -> warp_load_drv()
#     can read the W5HD driver header from p5 at warp time;
#   - times the warp precisely so we can tell "ran" from "rejected";
#   - clears magic+bootflag IMMEDIATELY after echo disk returns (reboot safety);
#   - captures the full dmesg (not just a filtered tail) so the warp's own
#     messages are preserved;
#   - then re-inits the dongle via the known-good rkwifi reload and waits long
#     enough for wpa_supplicant to re-associate.
#
# Fix A (sdio.c: sdio_reset_comm clears MMC_CARD_REMOVED) is what should make
# the reload's sdio_reset_comm() succeed instead of returning -ENOMEDIUM once
# the warp's SDIO timeout has set the sticky removed flag.
F=/root/ww128.txt
GW=192.168.50.1
MAGIC=/etc/warp/p5_magic8.bin

alive  () { ping -c1 -W2 "$GW" >/dev/null 2>&1 && echo OK || echo FAIL; }
ts     () { cut -d' ' -f1 /proc/uptime; }
op     () { cat /sys/class/net/wlan0/operstate 2>&1; }
wst    () { echo "halt=$(cat /proc/warp/halt 2>&1) err=$(cat /proc/warp/error 2>&1) stat=$(cat /proc/warp/stat 2>&1) loadno=$(cat /proc/warp/loadno 2>&1)"; }
magic  () { od -An -tx1 -N8 -j0 /dev/mmcblk0p5 2>/dev/null | tr -d ' \n'; echo; }
bfshow () { od -An -tx1 -N4 -j$((0x20000)) /dev/mmcblk0p5 2>/dev/null | tr -d ' \n'; echo; }
bfclear(){ dd if=/dev/zero of=/dev/mmcblk0p5 bs=1024 seek=128 count=1 conv=notrunc 2>/dev/null; }
magclear(){ dd if=/dev/zero of=/dev/mmcblk0p5 bs=1 seek=0 count=8 conv=notrunc 2>/dev/null; }

{
	echo "================ ww128 start $(date) ================"
	echo "uname: $(uname -a)"
	echo "bootid: $(cat /proc/sys/kernel/random/boot_id)"
	[ -e /proc/warp_watch_auto ] && echo 0 > /proc/warp_watch_auto
	echo "PRE t=$(ts) $(wst) operstate=$(op) ping=$(alive) magic=$(magic) bf=$(bfshow)"

	echo ">>> ensure magic armed (should already be), clear bootflag"
	bfclear; dd if="$MAGIC" of=/dev/mmcblk0p5 bs=1 seek=0 count=8 conv=notrunc 2>/dev/null; sync
	echo "    magic=$(magic) bf=$(bfshow)"

	echo ">>> quiesce wifi traffic"
	pkill -f 'soak2[.]sh gw' 2>&1
	sleep 15
	echo "    after quiesce t=$(ts) ping=$(alive) operstate=$(op)"

	echo ">>> WARM warp (halt=0) -- timing it"
	echo 0 > /proc/warp/halt
	echo 0 > /proc/warp/canceled 2>/dev/null
	echo 1 > /proc/warp/compress 2>/dev/null
	sync
	T0=$(ts)
	echo disk > /sys/power/state
	RC=$?
	T1=$(ts)
	echo ">>> echo disk RETURNED rc=$RC  t0=$T0 t1=$T1 delta=$(awk "BEGIN{print $T1-$T0}")"
	echo "    post-warp $(wst) operstate=$(op) ping=$(alive)"

	echo ">>> clear magic+bootflag NOW (reboot safety)"
	magclear; bfclear; sync
	echo "    magic=$(magic) bf=$(bfshow)"

	echo ">>> dump journal"
	dd if=/dev/mmcblk0p5 bs=1 skip=98304 count=8192 2>/dev/null > /root/jrnl-warm128.bin
	ls -l /root/jrnl-warm128.bin

	echo ">>> dmesg snapshot (warp window) -> /root/dmesg-ww128.log"
	dmesg > /root/dmesg-ww128.log 2>&1
	wc -l /root/dmesg-ww128.log

	echo ">>> [B] rkwifi driver reload (known recovery path, exercises sdio_reset_comm)"
	echo 0 > /sys/class/rkwifi/driver 2>&1
	sleep 3
	echo 1 > /sys/class/rkwifi/driver 2>&1
	echo "    reloaded at t=$(ts), waiting 25s for wpa_supplicant to re-associate"
	sleep 25
	echo "    after reload+wait t=$(ts) operstate=$(op) ping=$(alive) ip=$(ip -4 addr show wlan0 2>/dev/null | /bin/grep -oE 'inet [0-9.]+' | head -1)"

	echo ">>> if still down, bounce wpa_supplicant + dhcpcd"
	if [ "$(alive)" = "FAIL" ]; then
		killall wpa_supplicant 2>/dev/null; sleep 2
		killall dhcpcd 2>/dev/null; sleep 2
		wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf 2>&1
		sleep 8
		dhcpcd wlan0 2>&1
		sleep 10
		echo "    after wpa/dhcpcd bounce t=$(ts) operstate=$(op) ping=$(alive) ip=$(ip -4 addr show wlan0 2>/dev/null | /bin/grep -oE 'inet [0-9.]+' | head -1)"
	fi

	echo ">>> dmesg tail (wifi) after recovery"
	dmesg 2>&1 | /bin/grep -iE 'sdio_reset_comm|resetting SDIO|marking card removed|dhd_open|wlan|mmc2|wifi' | tail -40
	echo "================ ww128 end $(date) ================"
} >>"$F" 2>&1
