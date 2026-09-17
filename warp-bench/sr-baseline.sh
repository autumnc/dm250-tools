#!/bin/sh
# sr-baseline.sh -- SR (suspend-to-RAM) baseline with auto-reboot recovery. v2
#
# IRON LAW: SR aborts with wlan0 UP (mmc2:0001 mmc_bus_suspend -16); downing
# wlan0 wedges bcmdhd so we ALWAYS end with sysrq-b -> device reboots itself,
# network returns, no manual power-cycle.
#
# v2 instrumentation: the rk818 RTC-alarm IRQ (line "29:164: rk818 RTC alarm")
# did NOT increment on the v1 run even though the box slept ~31s.  So v2 dumps
# the rk818 PMIC interrupt lines (main 162 / period 163 / alarm 164) before and
# after, reads /sys/power/suspend_stats, and we vary A to prove the sleep time
# tracks the alarm lead (=> alarm-driven) rather than a fixed timeout.
#
# usage:  setsid /usr/local/sbin/sr-baseline.sh >/tmp/srb.out 2>&1 &
# env:    A=15 (RTC wake lead seconds)
LOG=/var/log/sr-baseline.log
A=${A:-15}

{
echo "=== SR baseline v2 (auto-reboot recovery) $(date) lead=${A}s ==="
echo "-- boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id) uptime=$(cut -d. -f1 /proc/uptime)"
echo "-- version: $(cut -d' ' -f1-3 /proc/version)"
[ -w /proc/warp_watch_auto ] && echo 0 > /proc/warp_watch_auto
echo 1 > /sys/power/pm_print_times 2>/dev/null
dmesg -n 8 2>/dev/null

# sum every numeric field on matching irq lines (robust to "NN:MMC:" prefix)
sumirq() { /bin/grep -iE "$1" /proc/interrupts 2>/dev/null \
             | awk '{s=0; for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; t+=s} END{print t+0}'; }
showirq() { /bin/grep -iE "rk818|RTC alarm|RTC period" /proc/interrupts 2>/dev/null; }

u0=$(cut -d. -f1 /proc/uptime)
main0=$(sumirq 'GPIO  rk818'); per0=$(sumirq 'RTC period'); alm0=$(sumirq 'RTC alarm')
echo "-- before: uptime=$u0  rk818_main=$main0  rtc_period=$per0  rtc_alarm=$alm0"
echo "-- irq lines before:"; showirq
echo "-- suspend_stats before:"; for f in /sys/power/suspend_stats/*; do echo "   $(basename $f)=$(cat $f 2>/dev/null)"; done
echo "-- autosleep=$(cat /sys/power/autosleep 2>/dev/null) wake_lock=[$(cat /sys/power/wake_lock 2>/dev/null)]"

echo "-- down wlan0 (mandatory for SR)"
ip link set wlan0 down
sleep 1
echo "-- wlan0 after down: [$(ip -o -4 addr show wlan0 2>/dev/null | awk '{print $4}')]"

echo "+$A" > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
al=$(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null)
t_arm=$(date +%s)
echo "-- RTC alarm armed epoch=$al now=$t_arm (lead ${A}s)"
sync
echo "-- step: echo mem  (RTC wakes in ~${A}s; NO keypress needed)"
echo mem > /sys/power/state; rc=$?

t_wake=$(date +%s)
u1=$(cut -d. -f1 /proc/uptime)
main1=$(sumirq 'GPIO  rk818'); per1=$(sumirq 'RTC period'); alm1=$(sumirq 'RTC alarm')
echo "-- echo mem RETURNED rc=$rc at $(date +%T)"
echo "-- WALL sleep = $((t_wake - t_arm))s (uptime $u0 -> $u1, +$((u1-u0))s running)"
echo "-- irq deltas: rk818_main=$((main1-main0))  rtc_period=$((per1-per0))  rtc_alarm=$((alm1-alm0))"
echo "-- irq lines after:"; showirq
echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null

echo "-- suspend_stats after:"; for f in /sys/power/suspend_stats/*; do echo "   $(basename $f)=$(cat $f 2>/dev/null)"; done
echo "-- PM/rtc trace:"
dmesg | /bin/grep -iE 'PM: suspend|PM: resume|rtc|alarm|Disabling non-boot|wakeup' | tail -16
b=$(dmesg | /bin/grep -cE 'Oops|Kernel panic|Call trace|Internal error|WARP-TMRBAD')
echo "-- bad sig: $b"

sleep=$((t_wake - t_arm))
if [ "$rc" = "0" ] && [ "$sleep" -ge "$((A/2))" ] && [ "$sleep" -le "$((A+A))" ]; then
	echo "VERDICT: PASS -- real SR in/out, ${sleep}s sleep tracking ${A}s alarm lead; woke w/o keypress"
else
	echo "VERDICT: CHECK -- rc=$rc wall_sleep=${sleep}s (lead=$A) main_d=$((main1-main0)) per_d=$((per1-per0)) alm_d=$((alm1-alm0))"
fi

echo "-- auto-reboot (sysrq-b) to restore wlan0; network returns after boot"
echo "=== rebooting at $(date) ==="
sync
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo b > /proc/sysrq-trigger
} >> "$LOG" 2>&1
