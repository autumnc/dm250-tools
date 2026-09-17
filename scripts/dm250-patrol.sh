#!/bin/bash
# DM250 crash patrol (host side).
#
# Polls the device's boot_id. When it changes, the previous boot ended
# without a clean shutdown -- on this device that means a crash (panic,
# lockup) or a watchdog reset. Pull that boot's captured dmesg back to the
# host and print one ALERT line. Silent when nothing changed, so it can be
# scheduled without generating noise.
#
# State: $STATE line1 = last seen boot_id, line2 = consecutive ssh failures.
set -u

HOST=root@192.168.50.251
DEVDIR=/root/soak
STATE=/home/ywz/.dm250-patrol.state
DEST=/home/ywz/dm250-crashes
SSHOPTS="-o ConnectTimeout=6 -o StrictHostKeyChecking=no -o BatchMode=yes"

mkdir -p "$DEST"

cur=$(ssh $SSHOPTS "$HOST" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
prev=""
fails=0
if [ -f "$STATE" ]; then
	prev=$(sed -n 1p "$STATE")
	fails=$(sed -n 2p "$STATE")
	fails=${fails:-0}
fi

if [ -z "$cur" ]; then
	# Unreachable. Only alert once it looks persistent, not on a single blip.
	fails=$((fails + 1))
	[ "$fails" -eq 3 ] && echo "PATROL ALERT: DM250 unreachable 3 checks in a row ($HOST)"
	printf '%s\n%s\n' "$prev" "$fails" > "$STATE"
	exit 0
fi

if [ -n "$prev" ] && [ "$cur" != "$prev" ]; then
	f="$DEST/dmesg.$prev"
	got_kcap=0
	if scp $SSHOPTS "$HOST:$DEVDIR/dmesg.$prev" "$f" >/dev/null 2>&1; then
		got_kcap=1
		echo "PATROL ALERT: DM250 rebooted $prev -> $cur; pulled $(basename "$f") ($(stat -c %s "$f") bytes)"
	else
		echo "PATROL ALERT: DM250 rebooted $prev -> $cur; kcapture log not retrievable (aged out)"
	fi

	# The ramoops/pstore records (persisted by the device's warpsave service
	# into /var/log/crash) hold the crash itself: kcapture is a periodic
	# snapshot and misses the final seconds before the reset. Archive them
	# per crashed boot. Filenames are fixed, so a stale record from an
	# earlier crash may persist; the ==== <unixtime> header disambiguates.
	crashdir="$DEST/crash.$prev"
	mkdir -p "$crashdir"
	if scp $SSHOPTS -q "$HOST:/var/log/crash/*" "$crashdir/" >/dev/null 2>&1; then
		echo "  ramoops: archived $(ls -1 "$crashdir" 2>/dev/null | wc -l) record(s) -> crash.$prev"
	fi

	# Why the board came back, from the new boot: PANIC means the panic path
	# ran (records are complete), WATCHDOG means the block reset the SoC.
	bmod=$(ssh $SSHOPTS "$HOST" \
		"dmesg | /bin/grep -m1 -aoE 'Boot mode: [A-Z_0-9]+ \([0-9]+\)'" 2>/dev/null)
	[ -n "$bmod" ] && echo "  boot: $bmod"

	# Prefer the ramoops record's signature -- it sees the fatal fault that
	# kcapture misses.
	sig=$(grep -ah -E 'Kernel panic|Internal error|Unable to handle|undefined instruction|hard LOCKUP|soft lockup|(^|[^A-Za-z])BUG:' \
		"$crashdir"/dmesg-ramoops-* 2>/dev/null | tail -1)
	[ -z "$sig" ] && [ "$got_kcap" = 1 ] && sig=$(grep -a -m1 -E 'Kernel panic|Internal error|Unable to handle|hard LOCKUP|soft lockup|(^|[^A-Za-z])BUG:' "$f")
	[ -n "$sig" ] && echo "  sign: $sig"
fi

printf '%s\n%s\n' "$cur" 0 > "$STATE"
exit 0
