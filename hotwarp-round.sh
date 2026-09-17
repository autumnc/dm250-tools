#!/bin/sh
# hotwarp-round.sh v2 -- 阶段2 hot warp regression, one round.
#
# Recipe is the literal #56/#57 one, no /proc/warp writes, to isolate whether
# the round-1 failure came from the explicit compress=1 (default is 2).
#
# On SUCCESS the wifi driver has been unbound and a hot warp does not reset the
# AP6212 the way a real power cycle does, so warpnet cannot re-enumerate it
# in-session -- the reboot at the end is what brings wifi back.
# On FAILURE the session never warped, so there is nothing to reboot for and the
# live dmesg is the evidence we want -- stay up, hand warpnet its job back (a
# plain driver cycle with no warp behind it reloads first try).

COMP="$1"   # optional /proc/warp/compress value; empty = leave at the default

exec >>/root/hotwarp.log 2>&1
echo "=================== round $(date '+%F %T') compress=${COMP:-default} ==================="
echo "kernel : $(uname -r)"
echo "mem    : $(awk '/^MemTotal|^MemFree|^MemAvailable/{printf "%s=%s ", $1, $2}' /proc/meminfo)"
echo "pre    : uptime=$(cut -d. -f1 /proc/uptime) wlan0=$(ip -4 addr show wlan0 2>/dev/null | /bin/grep -oE 'inet [0-9.]+' | head -1)"
echo "pre    : comp=$(cat /proc/warp/compress) shrink=$(cat /proc/warp/shrink) sep=$(cat /proc/warp/separate) div=$(cat /proc/warp/division) oneshot=$(cat /proc/warp/oneshot) switch=$(cat /proc/warp/switch)"
echo "pre    : magic=$(dd if=/dev/mmcblk0p5 bs=1 skip=0 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n') bf=$(dd if=/dev/mmcblk0p5 bs=1 skip=$((0x20000)) count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
echo "pre    : dmesg_lines=$(dmesg | wc -l)"

touch /run/warpnet.off
sv down wpa_supplicant dhcpcd 2>/dev/null
sleep 3
echo 0 > /sys/class/rkwifi/driver 2>/dev/null
sleep 2
echo "quiesce: wlan0=$(ip -4 addr show wlan0 2>/dev/null | /bin/grep -oE 'inet [0-9.]+' | head -1) operstate=$(cat /sys/class/net/wlan0/operstate 2>/dev/null)"
echo "mem2   : $(awk '/^MemFree|^MemAvailable/{printf "%s=%s ", $1, $2}' /proc/meminfo)"

if [ -n "$COMP" ]; then
    echo "$COMP" > /proc/warp/compress
    echo "set    : compress=$(cat /proc/warp/compress)"
fi

before=$(cut -d. -f1 /proc/uptime)
echo "saving : uptime_before=$before"
echo disk > /sys/power/state
rc=$?
echo "save   : rc=$rc uptime_after=$(cut -d. -f1 /proc/uptime)"
echo "save   : error=$(cat /proc/warp/error 2>/dev/null) stat=$(cat /proc/warp/stat 2>/dev/null) retry=$(cat /proc/warp/retry 2>/dev/null)"
echo "--- dmesg tail after save ---"
dmesg | tail -50
echo "--- dmesg filtered (warp/hib/snap/mem) ---"
dmesg | /bin/grep -aiE "warp|hibdrv|snapshot|out of memory|savearea" | tail -40
echo "post   : magic=$(dd if=/dev/mmcblk0p5 bs=1 skip=0 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n') bf=$(dd if=/dev/mmcblk0p5 bs=1 skip=$((0x20000)) count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"

if [ "$rc" != "0" ]; then
    echo "VERDICT: save FAILED (rc=$rc) -- staying up, unparking warpnet"
    rm -f /run/warpnet.off
    sv up wpa_supplicant dhcpcd 2>/dev/null
    echo "=================== round end (failed, still up) ==================="
    exit 0
fi

# Hot warp clears W5BF; if not, clear it by hand so the reboot is an ordinary
# boot rather than a U-Boot cold restore.
bf=$(dd if=/dev/mmcblk0p5 bs=1 skip=$((0x20000)) count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
if [ "$bf" = "57354246" ]; then
    echo "WARN   : bootflag still armed after hot warp -> clearing before reboot"
    dd if=/dev/zero of=/dev/mmcblk0p5 bs=1024 seek=128 count=1 conv=notrunc 2>/dev/null
fi
sync
echo "VERDICT: save OK (rc=0) -- rebooting to bring wifi back"
echo "=================== round end (ok, rebooting) ==================="
reboot
