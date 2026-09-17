#!/bin/sh
# cw148: cold warp end-to-end for kernel #142 -- does the restored session come
# up LIT by itself?
#
# Background.  #139/#140/#141 fixed the *registers*: a save taken with the panel
# blanked used to capture gated or non-live register state and replay it, which
# gave a colour bar / whole-screen snow.  The survivor of that work, cw147,
# reached a cold-restored session whose LCDC, LVDS and GRF fingerprints were all
# healthy -- and the screen was still BLACK.  Blank had cleared two GPIOs out of
# the LCDC's display-power list, GPIO0_D0 (panel power, bit 24) and GPIO0_D3
# (backlight enable, bit 27); the restored session had bit 24 back and bit 27
# missing (gpio0 = 01000000, healthy is 09000000).  The reason: the early
# display restore runs rk_disp_pwr_enable() before syscore_resume() has put the
# pin muxes back, so the backlight-enable write landed on a pad that was not a
# GPIO yet.  `echo 0 > /sys/class/graphics/fb0/blank` afterwards lit it, because
# by then the muxes were up.
#
# #142 replays that unblank from the kernel at the end of the cold-restore path
# (warp_display_unblank(), warp.c).  This script must therefore NOT unblank: the
# point is that the screen lights up on its own.
#
# Decisive readout at the replay point, with no eyes required:
#   FIXED  -> gpio0 bit27 = 1 (backlight enable driven) AND verdict LIT/OK
#   BROKEN -> gpio0 bit27 = 0 (backlight enable still missing) or snow
#
# Two-phase, exactly like cw147: FIRST arms and saves, then leaves p5 ARMED and
# the board UP.  Power it off from OUTSIDE and press POWER; the restored session
# resumes at the replay point and takes the REPLAY branch.  NO poweroff here --
# it would be replayed.
OBS=/root/warp-obs
LOG=$OBS/cw148.log
TMP=/tmp/cw148.txt
MAGIC=/etc/warp/p5_magic8.bin
W5HD=5735484400000150
W5BF=57354246
WATCH=240

ts   () { cut -d' ' -f1 /proc/uptime | cut -d. -f1; }
op   () { cat /sys/class/net/wlan0/operstate 2>&1; }
addr4(){ ip -4 addr show wlan0 2>/dev/null | /bin/grep -v 'inet 169\.254\.' \
           | /bin/grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2; }
wst  () { echo "halt=$(cat /proc/warp/halt 2>&1) err=$(cat /proc/warp/error 2>&1) stat=$(cat /proc/warp/stat 2>&1)"; }
magic  () { od -An -tx1 -N8 -j0 /dev/mmcblk0p5 2>/dev/null | tr -d ' \n'; }
bfdump () { dd if=/dev/mmcblk0p5 bs=1 skip=$((0x20000)) count=16 2>/dev/null | od -An -tx1 | tr -d ' \n'; }
bfclear(){ dd if=/dev/zero of=/dev/mmcblk0p5 bs=1024 seek=128 count=1 conv=notrunc 2>/dev/null; }
magclear(){ dd if=/dev/zero of=/dev/mmcblk0p5 bs=1 seek=0 count=8 conv=notrunc 2>/dev/null; }
mkclear(){ dd if=/dev/zero of=/dev/mmcblk0p5 bs=1 seek=$((0x1f000)) count=8 conv=notrunc 2>/dev/null; }
snapid () { dd if=/dev/mmcblk0p5 bs=1 skip=$((0x20404)) count=4 2>/dev/null | od -An -tx1 | tr -d ' \n'; }
p5off  () { magclear; bfclear; mkclear; sync; }
ac     () { cat /sys/class/power_supply/ac/online 2>/dev/null || echo '?'; }
kl     () { echo "cw148: $*" > /dev/kmsg 2>/dev/null; }
say    () { echo "$*"; kl "$*"; }

# The decisive readout: is window 0 scanning the framebuffer, or address 0?
verdict () {
	local tag="$1"
	local sys mst vir act
	sys=$(/root/bin/memdump r 0x1010e000 1 2>/dev/null | tail -1 | awk '{print $2}')
	mst=$(/root/bin/memdump r 0x1010e020 1 2>/dev/null | tail -1 | awk '{print $2}')
	vir=$(/root/bin/memdump r 0x1010e030 1 2>/dev/null | tail -1 | awk '{print $2}')
	act=$(/root/bin/memdump r 0x1010e034 1 2>/dev/null | tail -1 | awk '{print $2}')
	echo "  [VERDICT:$tag] sys0=$sys win0mst=$mst vir=$vir act=$act"
	case "$mst" in
	10000000) echo "  [VERDICT:$tag] ==> LIT/OK  (window 0 points at the framebuffer)" ;;
	00000000|ffffffff) echo "  [VERDICT:$tag] ==> BAD     (WIN0_YRGB_MST=$mst -- address 0: SNOW)" ;;
	*) echo "  [VERDICT:$tag] ==> UNKNOWN (WIN0_YRGB_MST=$mst)" ;;
	esac
}

# #142's own assertion: the backlight-enable line inside the LCDC power list.
blcheck () {
	local tag="$1" g pw bl
	g=$(/root/bin/memdump r 0x2007c000 1 2>/dev/null | tail -1 | awk '{print $2}')
	if [ -z "$g" ]; then
		echo "  [BL:$tag] gpio0 unreadable"
		return
	fi
	pw=$(( (0x$g >> 24) & 1 ))
	bl=$(( (0x$g >> 27) & 1 ))
	echo "  [BL:$tag] gpio0=$g panel_pwr(b24)=$pw backlight_en(b27)=$bl"
	if [ "$bl" = "1" ]; then
		echo "  [BL:$tag] ==> #142 FIXED (backlight enable driven by the kernel)"
	else
		echo "  [BL:$tag] ==> #142 BROKEN (backlight enable still 0 -- screen stays dark)"
	fi
}

disp () {
	local tag="$1"
	echo "  [disp:$tag] t=$(ts) blank=[$(cat /sys/class/graphics/fb0/blank 2>&1)]" \
	     "bl_power=[$(cat /sys/class/backlight/*/bl_power 2>&1)]" \
	     "brightness=[$(cat /sys/class/backlight/*/brightness 2>&1)]"
	echo "  [disp:$tag] fb0md5=[$(md5sum /dev/fb0 2>/dev/null | cut -d' ' -f1)]"
	echo "  [disp:$tag] lcdc 0x00-0xfc:"
	/root/bin/memdump r 0x1010e000 64 2>&1
	echo "  [disp:$tag] lvds_ctl:"
	/root/bin/memdump r 0x101100b0 4 2>&1
	echo "  [disp:$tag] mipiphy 0x00-0x3c:"
	/root/bin/memdump r 0x20038000 16 2>&1
	echo "  [disp:$tag] grf_lvds 0x140:"
	/root/bin/memdump r 0x20008140 12 2>&1
	echo "  [disp:$tag] gpio0 swport:"
	/root/bin/memdump r 0x2007c000 4 2>&1
	blcheck "$tag"
	verdict "$tag"
}

fbframe () {
	dd if=/dev/fb0 of=/tmp/fbcap.raw bs=4096 count=600 2>/dev/null
	gzip -1 -c /tmp/fbcap.raw > "$OBS/fb-$1.raw.gz" 2>/dev/null
	echo "  [fb:$1] raw=$(wc -c </tmp/fbcap.raw 2>&1) gz=$(wc -c <"$OBS/fb-$1.raw.gz" 2>&1)"
}

wifi_up () {
	say ">>> manual fallback: driver reload + userspace"
	echo 0 > /sys/class/rkwifi/driver 2>&1
	sleep 2
	echo 1 > /sys/class/rkwifi/driver 2>&1
	sleep 20
	sv up wpa_supplicant 2>&1
	sv up dhcpcd 2>&1
	sleep 15
	say "    fallback done drv=$(cat /sys/class/rkwifi/driver 2>&1) operstate=$(op) ip=$(addr4)"
}

mkdir -p "$OBS"

{
	echo "================ cw148 start $(date) ================"
	echo "uname: $(uname -a)"
	echo "bootid: $(cat /proc/sys/kernel/random/boot_id) pid=$$"
	echo "PRE t=$(ts) $(wst) operstate=$(op) ip=$(addr4) magic=$(magic) bf=$(bfdump) snapid=$(snapid) ac=$(ac)"
	disp pre
	fbframe pre

	if [ "$(ac)" != "0" ]; then
		echo "!!! ac/online != 0 -- EXTERNAL POWER STILL CONNECTED. aborting."
		exit 1
	fi

	# keep the box's boot-default watchdogs out of the experiment
	echo 0 > /proc/warp_watch_auto 2>/dev/null
	echo 0 > /proc/warp_watch 2>/dev/null
	echo 0 > /proc/sys/kernel/softlockup_panic 2>/dev/null

	say ">>> arm magic + clear bootflag / marker"
	p5off
	dd if="$MAGIC" of=/dev/mmcblk0p5 bs=1 seek=0 count=8 conv=notrunc 2>/dev/null
	sync
	echo "    magic=$(magic) bf=$(bfdump) snapid=$(snapid)"

	say ">>> arm earlydisp=1 keepbf=1"
	echo 1 > /proc/warp/earlydisp
	echo 1 > /proc/warp/keepbf
	echo "    earlydisp=$(cat /proc/warp/earlydisp) keepbf=$(cat /proc/warp/keepbf)"

	say ">>> quiesce wifi"
	sv down wpa_supplicant dhcpcd 2>&1
	sleep 3
	echo 0 > /sys/class/rkwifi/driver 2>&1
	sleep 2
	echo "    after quiesce t=$(ts) operstate=$(op) drv=$(cat /sys/class/rkwifi/driver 2>&1)"

	# Blank the panel ON PURPOSE: it is the only save condition known to be
	# reliable (panel lit at save hangs in hibernate() -- #77), and it is what
	# leaves the restored session dark in the first place.
	say ">>> blank the panel -- the save condition #77 forces, and #142's premise"
	echo 1 > /sys/class/graphics/fb0/blank 2>&1
	sleep 3
	disp blanked
	say "    ^ LCDC all-ones / MIPIPHY all-zero / lvdsctl all-ones = clock gated"

	say ">>> PLAIN save (halt=0) -- bootflag must stay armed"
	echo 0 > /proc/warp/halt
	echo 0 > /proc/warp/canceled 2>/dev/null
	echo 1 > /proc/warp/compress 2>/dev/null
	sync
	T0=$(ts)
	kl "calling echo disk t=$T0"
	echo disk > /sys/power/state
	RC=$?
	T1=$(ts)

	# ===================== the replay point =====================
	sync
	MG=$(magic)
	BF=$(bfdump)
	BFID=$(echo "$BF" | cut -c1-8)
	BFSID=$(echo "$BF" | cut -c9-16)
	SID=$(snapid)
	echo "    post t=$T1 rc=$RC $(wst) magic=$MG bf=$BF snapid=$SID"
	disp post
	fbframe post

	# ---------- cold-restored replay: kernel cleared W5BF, magic survives ----
	if [ "$RC" = "0" ] && [ "$MG" = "$W5HD" ] && [ "$BFID" != "$W5BF" ]; then
		say "REPLAY-ENTER t=$T1 rc=$RC -- bootflag gone, magic alive: cold restore"

		p5off
		say "REPLAY-DISARM magic=$(magic) bf=$(bfdump)"
		echo 0 > /proc/warp/keepbf
		echo 0 > /proc/warp/earlydisp

		# NO unblank here on purpose -- #142 must have done it in the kernel.
		echo "REPLAY-VERDICT-#142 follows; this script does not touch fb0/blank"
		fbframe enter
		disp enter

		echo "REPLAY $(date) uptime=$(ts) rc=$RC" >> "$LOG"
		dmesg > "$TMP.dmesg" 2>&1
		sync

		sleep 10
		disp settle
		fbframe settle

		echo "  --- blank/display lines in dmesg ---"
		/bin/grep -iE "blank mode|fb0 unblanked|display|iommu|vop|wifi reinit|W5BF disarmed|earlydisp" \
			"$TMP.dmesg" 2>&1 | tail -40

		echo "REPLAY-WATCH watchdog=$(sv status warpnet 2>&1)"
		k=0; GOT=""
		while [ $k -lt $WATCH ]; do
			sleep 5
			k=$((k+5))
			if [ -n "$(addr4)" ]; then
				GOT="yes after ${k}s"
				break
			fi
		done
		echo "REPLAY-WATCH result=[$GOT] operstate=$(op) ip=$(addr4) drv=$(cat /sys/class/rkwifi/driver 2>&1)"
		echo "--- warpnet.log tail ---"
		tail -20 /var/log/warpnet.log 2>&1
		disp done

		if [ -z "$GOT" ]; then
			say "REPLAY-WATCH warpnet did not restore the link in ${WATCH}s"
			wifi_up
		else
			say "REPLAY-WATCH warpnet restored the link unaided ($GOT)"
		fi

		say "REPLAY-DONE t=$(ts)"
		echo "================ cw148 REPLAY end $(date) ================" >> "$LOG"
		exit 0
	fi

	# ========================= first run only =========================
	say "FIRST-ENTER t=$T1 rc=$RC (live session after the save)"
	echo "    post-warp $(wst) operstate=$(op)"

	if [ "$RC" != "0" ] || [ "$BFID" != "$W5BF" ] || [ "$BFSID" != "$SID" ]; then
		echo "!!! save did NOT arm a paired bootflag (rc=$RC id=$BFID sid=$BFSID image=$SID)"
		echo "!!! no cold warp armed -- disarming and bringing wifi back"
		p5off
		echo 0 > /proc/warp/earlydisp
		echo 0 > /proc/warp/keepbf
		wifi_up
		echo "================ cw148 FIRST-ABORT $(date) ================"
		exit 1
	fi

	say "FIRST-BFCHK OK id=$BFID sid=$BFSID image=$SID"
	say "FIRST-DONE t=$(ts) bootflag=$(bfdump) -- save is armed"
	say "FIRST-DONE power off from OUTSIDE, then press POWER"
	wifi_up
	say "FIRST-UP t=$(ts) -- board left UP on purpose, p5 ARMED"
	echo "================ cw148 FIRST end $(date) ================"
	exit 0
} >>"$LOG" 2>&1
