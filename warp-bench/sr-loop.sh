#!/bin/sh
# sr-loop.sh -- SR reliability loop: N suspend/resume cycles on ONE boot.
#
# Why:  v1 SR resumed cleanly; v2 hung at SR entry (after CPU1-3 shutdown) when an
# rk818 PMIC IRQ (i2c addr 0x1c) raced the noirq-suspend window -> the line stayed
# asserted -> suspend never completed -> HW watchdog reset the board.  We need the
# reliability RATE, and whether hangs correlate with rk818 IRQ activity.
#
# wlan0 down once (SR needs it).  RTC auto-wakes each cycle (no keypress).  A hang
# is caught by the hardware watchdog (observed Boot mode: WATCHDOG), so this is
# safe unattended.  Every cycle fsyncs its result, so a hang preserves prior cycles.
#
# usage: setsid /usr/local/sbin/sr-loop.sh >/tmp/srl.out 2>&1 &
# env:   N=5 (cycles)  A=12 (RTC lead secs)
LOG=/var/log/sr-loop.log
N=${N:-5}
A=${A:-12}

{
echo "=== SR reliability loop N=$N lead=${A}s $(date) ==="
echo "-- boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id) uptime=$(cut -d. -f1 /proc/uptime)"
echo "-- version: $(cut -d' ' -f1-3 /proc/version)"
[ -w /proc/warp_watch_auto ] && echo 0 > /proc/warp_watch_auto
echo 1 > /sys/power/pm_print_times 2>/dev/null
dmesg -n 8 2>/dev/null

sumirq() { /bin/grep -iE "$1" /proc/interrupts 2>/dev/null \
             | awk '{s=0; for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; t+=s} END{print t+0}'; }
u()   { cut -d. -f1 /proc/uptime; }
rk()  { sumirq 'GPIO  rk818'; }

echo "-- down wlan0 (mandatory for SR)"
ip link set wlan0 down
sleep 1
echo "-- wlan0 after down: [$(ip -o -4 addr show wlan0 2>/dev/null | awk '{print $4}')]"

ok=0; i=1
while [ $i -le $N ]; do
	u0=$(u); main0=$(rk); t0=$(date +%s)
	if [ "$A" -gt 0 ]; then
		echo "+$A" > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
		arm="alarm+${A}s"
	else
		arm="NO-ALARM"
	fi
	echo "-- cycle $i: echo mem ($arm) at $(date +%T) uptime=$u0 rk818_main=$main0"
	sync
	echo mem > /sys/power/state; rc=$?
	t1=$(date +%s); u1=$(u); main1=$(rk)
	echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
	if [ "$rc" = "0" ]; then ok=$((ok+1)); fi
	echo "-- cycle $i RESULT rc=$rc wall=$((t1-t0))s uptime $u0->$u1 rk818_main_d=$((main1-main0))  [ok=$ok/$i]"
	# capture any i2c/rk818 noise around this cycle
	dmesg | /bin/grep -iE 'i2c.*timeout|WARP-DIAG.*i2c|suspend exit|suspend entry' | tail -3
	dmesg -c >/dev/null 2>&1
	sync
	i=$((i+1))
	sleep 2
done

last=$((i-1))
echo "-- LOOP SUMMARY: ran=$last/$N ok=$ok"
if [ "$last" -lt "$N" ]; then
	echo "   -> cycle $((last+1)) HUNG at SR entry; HW watchdog reset the board."
else
	echo "   -> all $N cycles returned; SR reliable at this load this boot."
fi
echo "=== loop done, auto-reboot (sysrq-b) at $(date) ==="
sync
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo b > /proc/sysrq-trigger
} >> "$LOG" 2>&1
