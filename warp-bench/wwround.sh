#!/bin/sh
# wwround.sh R : ONE clean warm-warp round WITH the "unload wifi before warp"
# lever (TASK #56) plus the wpa_supplicant race fix (TASK #57).
#
# Lever: `echo 0 > /sys/class/rkwifi/driver` clears bcmdhd + its bcmsdh_sdmmc
# sdio driver before `echo disk`, so dpm_suspend(PMSG_FREEZE) has no mmc2:0001
# function driver left to fail with -EBUSY.
# Race fix: wpa_supplicant is runit-supervised and owns the cfg80211 P2P device
# (p2p-dev-wlan0); it races the driver teardown with an nl80211 stop_p2p_device
# call -> UAF oops (round 6, 2026-09-15). So `sv down` it (kill would respawn).
# Always ends by self-rebooting.
R="$1"
F=/root/wwround.txt
GW=192.168.50.1
MAGIC=/etc/warp/p5_magic8.bin
QUIESCE=${QUIESCE:-30}

magic  () { od -An -tx1 -N8 -j0 /dev/mmcblk0p5 2>/dev/null | tr -d ' \n'; echo; }
snapm  () { od -An -tx1 -N4 -j$((0x20400)) /dev/mmcblk0p5 2>/dev/null | tr -d ' \n'; echo; }
bfshow () { od -An -tx1 -N4 -j$((0x20000)) /dev/mmcblk0p5 2>/dev/null | tr -d ' \n'; echo; }
magarm () { dd if="$MAGIC" of=/dev/mmcblk0p5 bs=1 seek=0 count=8 conv=notrunc 2>/dev/null; }
magclr () { dd if=/dev/zero of=/dev/mmcblk0p5 bs=1 seek=0 count=8 conv=notrunc 2>/dev/null; }
bfclr  () { dd if=/dev/zero of=/dev/mmcblk0p5 bs=1024 seek=128 count=1 conv=notrunc 2>/dev/null; }
ts     () { cut -d' ' -f1 /proc/uptime; }
alive  () { ping -c1 -W2 "$GW" >/dev/null 2>&1 && echo OK || echo FAIL; }
op     () { cat /sys/class/net/wlan0/operstate 2>&1; }
wst    () { echo "halt=$(cat /proc/warp/halt 2>/dev/null) err=$(cat /proc/warp/error 2>/dev/null) stat=$(cat /proc/warp/stat 2>/dev/null) loadno=$(cat /proc/warp/loadno 2>/dev/null)"; }

# Safety watchdog: reboot if a round wedges (a normal round is ~60s).
( sleep 300; echo b > /proc/sysrq-trigger ) & WD=$!

{
echo "---- round $R boot=$(cat /proc/sys/kernel/random/boot_id) start=$(date +%H:%M:%S) quiesce=${QUIESCE}s ----"
[ -e /proc/warp_watch_auto ] && echo 0 > /proc/warp_watch_auto
echo "  at-entry t=$(ts) operstate=$(op) ping=$(alive) magic=$(magic) bf=$(bfshow) snap=$(snapm)"

if [ "$(alive)" = "FAIL" ]; then
	echo 0 > /sys/class/rkwifi/driver 2>/dev/null; sleep 3
	echo 1 > /sys/class/rkwifi/driver 2>/dev/null; sleep 18
	echo "  after-recover t=$(ts) operstate=$(op) ping=$(alive)"
fi

pkill -f 'soak2[.]sh gw' 2>/dev/null; sleep "$QUIESCE"
echo "  post-quiesce t=$(ts) operstate=$(op) ping=$(alive)"

bfclr; magarm; sync
echo "  armed t=$(ts) magic=$(magic) bf=$(bfshow)"; sync

# --- LEVER (#56) + race fix (#57): stop wifi userspace, then unload the driver ---
sv down wpa_supplicant >/dev/null 2>&1
sv down dhcpcd >/dev/null 2>&1
i=0; while [ $i -lt 20 ]; do
	[ -z "$(pgrep -x wpa_supplicant)" ] && [ -z "$(pgrep -x dhcpcd)" ] && break
	sleep 0.5; i=$((i+1))
done
echo "  wifi-svdown t=$(ts) wpa=[$(pgrep -x wpa_supplicant | tr '\n' ' ')] dhcpcd=[$(pgrep -x dhcpcd | tr '\n' ' ')] operstate=$(op)"; sync
TU0=$(ts)
timeout 90 sh -c 'echo 0 > /sys/class/rkwifi/driver'
RU=$?
TU1=$(ts)
echo "  wifi-unload t0=$TU0 t1=$TU1 delta=$(awk "BEGIN{print $TU1-$TU0}") rc=$RU wlan0=[$(ip -o link show wlan0 2>&1 | head -c40)] ping=$(alive)"; sync

echo 0 > /proc/warp/halt; echo 0 > /proc/warp/canceled 2>/dev/null; echo 1 > /proc/warp/compress 2>/dev/null; sync
T0=$(ts)
echo disk > /sys/power/state
RC=$?
T1=$(ts)
echo "  RESULT r=$R rc=$RC t0=$T0 t1=$T1 delta=$(awk "BEGIN{print $T1-$T0}") $(wst) operstate=$(op) ping=$(alive)"; sync

magclr; bfclr; sync
echo "  cleared t=$(ts) magic=$(magic) bf=$(bfshow) snap=$(snapm)"; sync
dd if=/dev/mmcblk0p5 bs=1 skip=98304 count=8192 2>/dev/null > /root/jrnl-r$R.bin
dmesg > /root/dmesg-r$R.log 2>&1
echo "  ROUND_DONE r=$R rc=$RC"; sync
} >>"$F" 2>&1

kill $WD 2>/dev/null

# Self-reboot: guarantees wifi + display come back and gives the next round a
# clean state, without the host needing to reach a warp-dead wlan0.
sync
sleep 2
echo b > /proc/sysrq-trigger
