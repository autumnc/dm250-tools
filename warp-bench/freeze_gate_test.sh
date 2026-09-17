#!/bin/sh
# Cheap proxy for the warp freeze gate.
# warp's -EBUSY comes from dpm_suspend(PMSG_FREEZE) failing on mmc2:0001.
# `echo freeze > /sys/power/state` drives the SAME dpm_suspend(PMSG_FREEZE)
# path but costs ~1s instead of a full 14s image save. So:
#   A wifi LOADED   -> expect rc!=0, -16
#   B wifi UNLOADED -> if rc==0, the gate is gone => the warp lever works.
# Runs detached (unload kills wlan0/SSH). Watchdog reboots if we hang.
GW=192.168.50.1
F=/root/freeze-gate-test.txt
ts(){ cut -d' ' -f1 /proc/uptime; }
d(){ dmesg | /bin/grep -iE 'mmc2:0001|failed to freeze|dpm_run_callback|bcmsdh|Warp|Freezing|PM: ' | tail -n "${1:-20}"; }
( sleep 150; echo b > /proc/sysrq-trigger ) & WD=$!
{
echo "start $(date +%H:%M:%S) boot=$(cat /proc/sys/kernel/random/boot_id)"
echo "--A-- wifi LOADED, echo freeze"
T0=$(ts); echo freeze > /sys/power/state; RC=$?; T1=$(ts)
echo "A rc=$RC t0=$T0 t1=$T1 delta=$(awk "BEGIN{print $T1-$T0}")"
echo "A dmesg:"; d
echo "--B-- unload wifi, echo freeze"
echo 0 > /sys/class/rkwifi/driver; sleep 3
echo "B module-bcmdhd=[$(ls /sys/module/bcmdhd 2>&1 | head -c40)] func1-drv=[$(readlink /sys/bus/sdio/devices/mmc2:0001:1/driver 2>&1)] binddir=[$(ls /sys/bus/sdio/drivers/bcmsdh_sdmmc/ 2>/dev/null | tr '\n' ' ')]"
T2=$(ts); echo freeze > /sys/power/state; RC2=$?; T3=$(ts)
echo "B rc=$RC2 t0=$T2 t1=$T3 delta=$(awk "BEGIN{print $T3-$T2}")"
echo "B dmesg:"; d
echo "--C-- reload wifi"
echo 1 > /sys/class/rkwifi/driver; sleep 20
echo "C ping=$(ping -c1 -W2 $GW >/dev/null 2>&1 && echo OK || echo FAIL) operstate=$(cat /sys/class/net/wlan0/operstate 2>&1)"
echo "done $(date +%H:%M:%S)"
} >"$F" 2>&1
kill $WD 2>/dev/null
