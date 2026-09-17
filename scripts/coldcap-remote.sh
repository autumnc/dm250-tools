#!/bin/sh
# coldcap-remote.sh -- dump the post-cold-restore state.  Piped to `sh` over ssh
# by watch-coldwarp.sh, so no quoting puzzle.  Runs on the DM250.

echo "--- date / uptime / kernel ---"
date '+%F %T'
uptime
echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
uname -a

echo
echo "--- warp stat / error ---"
cat /proc/warp/stat 2>&1
echo "error=$(cat /proc/warp/error 2>&1)"

echo
echo "--- /tmp/coldwarp.log (tmpfs: the live half rode into the blob) ---"
cat /tmp/coldwarp.log 2>&1

echo
echo "--- /tmp/lidwarp.log ---"
cat /tmp/lidwarp.log 2>&1

echo
echo "--- p5 journal @0x18000 ---"
dd if=/dev/mmcblk0p5 bs=1 skip=$((0x18000)) count=8192 2>/dev/null | strings | head -30

echo
echo "--- p5 magic / bootflag / coldmark ---"
printf "magic  (W5HD, want 5735484400000150): "; dd if=/dev/mmcblk0p5 bs=1 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n'; echo
printf "bf     (W5BF, want 00000000):        "; dd if=/dev/mmcblk0p5 bs=1 skip=$((0x20000)) count=4 2>/dev/null | od -An -tx1 | tr -d ' \n'; echo
printf "marker (WARPCLD, want 0):            "; dd if=/dev/mmcblk0p5 bs=1 skip=$((0x1f000)) count=8 2>/dev/null | od -An -tx1 | tr -d ' \n'; echo

echo
echo "--- ext4 ---"
echo "errors this boot = $(dmesg 2>/dev/null | /bin/grep -ac 'EXT4-fs error')"
dmesg 2>/dev/null | /bin/grep -aE 'EXT4-fs \((mmcblk0p8|mmcblk0p25)\)' | tail -8

echo
echo "--- display (blank / gpio0) ---"
cat /sys/class/graphics/fb0/blank 2>&1
cat /sys/class/gpio/gpio0/value 2>&1

echo
echo "--- watchdog ---"
cat /proc/wdt 2>&1

echo
echo "--- wifi ---"
cat /sys/class/rkwifi/driver 2>&1
ip -4 -o addr show wlan0 2>&1

echo
echo "--- services / run flags ---"
sv status warpnet lidwarp lidscreen 2>&1
ls -l /run/coldwarp.lock /run/warpnet.off 2>&1
