#!/bin/sh
# sr-keepup.sh -- minimal suspend-to-RAM probe that does NOT touch wlan0.
#
# Question: does SR (echo mem) actually need wlan0 down?
#   * echo mem returns 0 and RTC wakes us  -> SR is fine with wlan0 up
#     (=> future warp/SR tests keep SSH alive, no reboot-per-test)
#   * echo mem returns -EBUSY (rc=-16)      -> a wakelock blocks suspend
#     (=> we must release wlan0's wakelock somehow)
#
# Runs detached; auto-wakes via /sys/class/rtc/rtc0/wakealarm (+30s), no keypress.
LOG=/var/log/sr-keepup.log
{
echo "=== SR keep-wlan0-up probe $(date) ==="
echo "-- version: $(cut -d' ' -f1-3 /proc/version)"
[ -w /proc/warp_watch_auto ] && echo 0 > /proc/warp_watch_auto
echo 1 > /sys/power/pm_print_times 2>/dev/null
dmesg -n 8 2>/dev/null

sumirq() { /bin/grep -i "$1" /proc/interrupts 2>/dev/null \
             | awk '{for(i=2;i<=9;i++) if($i ~ /^[0-9]+$/) s+=$i} END{print s+0}'; }
u0=$(cut -d. -f1 /proc/uptime)
r0=$(sumirq "RTC alarm")
echo "-- pre: uptime=$u0 rtc_alarm_irq=$r0"
echo "-- pre wlan0: $(ip -o -4 addr show wlan0 2>/dev/null | awk '{print $4}')"
echo "-- pre wake_lock: [$(cat /sys/power/wake_lock 2>/dev/null)]"
echo "-- pre autosleep: $(cat /sys/power/autosleep 2>/dev/null)"

echo "+30" > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
al=$(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null)
echo "-- alarm epoch=$al now=$(date +%s)"
sync
echo "-- step: echo mem  (expect SR in/out; RTC wakes ~30s, NO keypress)"
echo mem > /sys/power/state; rc=$?

u1=$(cut -d. -f1 /proc/uptime)
r1=$(sumirq "RTC alarm")
echo "-- echo mem RETURNED rc=$rc at $(date +%T)"
echo "-- post: uptime=$u1 rtc_alarm_irq=$r1 (delta=$((r1-r0)))"
echo "-- post wlan0: $(ip -o -4 addr show wlan0 2>/dev/null | awk '{print $4}')"
echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null

echo "-- PM/rtc trace:"
dmesg | /bin/grep -iE "PM: suspend|PM: resume|rtc|alarm|wake" | tail -12
echo "-- bad sig: $(dmesg | /bin/grep -cE "Oops|Kernel panic|Call trace|Internal error|WARP-TMRBAD")"
if [ "$rc" = "0" ] && [ "$r1" -gt "$r0" ]; then
	echo "VERDICT: PASS -- SR works with wlan0 UP; RTC woke us. No need to down wlan0."
else
	echo "VERDICT: FAIL -- rc=$rc rtc_delta=$((r1-r0)); SR did not complete with wlan0 up."
fi
echo "=== done ==="
} >> "$LOG" 2>&1
