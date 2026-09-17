#!/bin/sh
# Cron wrapper for the DM250 patrol. Runs the patrol, and only when it has
# something to say (a reboot/crash or a persistent outage): append it to the
# patrol log and pop a desktop notification. Silent otherwise, so a cron
# every 30 min generates no noise.
set -u
OUT=$(/home/ywz/dm250-patrol.sh 2>&1) || true
[ -n "$OUT" ] || exit 0

printf '%s %s\n' "$(date '+%F %T')" "$OUT" >> /home/ywz/dm250-crashes/patrol.log

bus="unix:path=/run/user/$(id -u)/bus"
[ -S "/run/user/$(id -u)/bus" ] && DISPLAY="${DISPLAY:-:0}" DBUS_SESSION_BUS_ADDRESS="$bus" \
	notify-send -u critical "DM250 崩溃巡检" "$OUT" 2>/dev/null
exit 0
