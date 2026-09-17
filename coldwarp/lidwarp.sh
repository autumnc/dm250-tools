#!/bin/sh
# lidwarp.sh -- cold warp the board five minutes after the lid is closed.
#
# Three stages; this daemon owns only the timer and the power, because
# lidscreen already owns the panel (blank on close, unblank on the open
# transition, 30s re-blank watchdog).
#
#   1. lid closes           lidscreen blanks the panel and the system keeps
#                           running.  Deliberately no save here: a hot warp
#                           would burn a ~25s p5 write on every lid close for
#                           no benefit -- the session never stopped, so opening
#                           the lid is instant either way -- and it would turn
#                           #77's occasional save hang into a routine one.
#   2. lid opens < 5 min    lidscreen unblanks, the counter resets, and the
#                           same session just carries on.
#   3. lid closed >= 5 min  cold warp: save with the bootflag armed, then power
#                           off.  Press POWER to bring it back.
#
# On AC coldwarp.sh refuses, so a lid left shut on the charger stays awake.
# That is the point: a soft power-off on AC auto-reboots after ~60s.
LID=/sys/class/gpio/gpio20/value
TICK=5
LIMIT=300

closed=0
while :; do
	if [ "$(cat $LID 2>/dev/null)" = "0" ]; then
		closed=$((closed + TICK))
		if [ "$closed" -ge "$LIMIT" ]; then
			# Reset before the call so the replayed copy of this daemon
			# starts its next five minutes from scratch instead of
			# firing again the instant it thaws.
			closed=0
			echo "$(date '+%F %T') lid shut ${LIMIT}s -- cold warp" >>/tmp/lidwarp.log
			/root/bin/coldwarp.sh
		fi
	else
		closed=0
	fi
	sleep $TICK
done
