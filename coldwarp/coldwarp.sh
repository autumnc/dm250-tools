#!/bin/sh
# coldwarp.sh -- Lineo Warp!! cold warp on demand.
#
# A cold warp is a plain save (the only path on which the blob arms the W5BF
# bootflag at p5+0x20000) followed by an ordinary poweroff.  Both halves matter:
# keepbf must be set for the save so the bootflag survives it, and the poweroff
# below is what lets U-Boot take over on the next POWER press.
#
# The session that comes back is NOT this one continuing -- U-Boot rewinds DRAM
# to the save instant, so this script is replayed from the `echo disk` return.
# That is why the poweroff is guarded by a flash read: only the live side still
# has W5BF armed, and only the live side may power off.  Get that backwards and
# the board powers off again the moment it restores, forever.
#
# Refused on AC: a soft power-off on AC auto-reboots after ~60s, so the board
# would come straight back up instead of staying off.
#
# Everything this script prints goes to tmpfs.  Between the save and the
# poweroff nothing may touch ext4: the live session's newer metadata would be
# flushed by the shutdown umount while the restored kernel resumes with the
# ext4 view it had at the save instant, and the two disagreeing corrupts the
# filesystem.

exec >>/tmp/coldwarp.log 2>&1
echo "=== coldwarp $(date) pid=$$ ac=$(cat /sys/class/power_supply/ac/online 2>&1) ==="

# One cold warp at a time -- F12 and the lid timer share this script.
if [ -e /run/coldwarp.lock ]; then
    echo "REFUSED: already running (lock present)"
    exit 1
fi
: > /run/coldwarp.lock

ac=$(cat /sys/class/power_supply/ac/online 2>/dev/null)
if [ "$ac" != "0" ]; then
    echo "REFUSED: ac/online=$ac -- cold warp is forbidden on external power"
    rm -f /run/coldwarp.lock
    exit 1
fi

# #77: a lit panel hangs hibernate().  The lid path arrives here already
# blanked (lidscreen did it); the F12 path does not, so blank unconditionally.
# No unblank on the way out: the restored kernel unblanks itself, and if the
# lid is still shut lidscreen re-blanks it within its 30s watchdog.
echo 1 > /sys/class/graphics/fb0/blank
sleep 3

# Quiesce wifi.  Two separate reasons, both measured:
#  - hibernate() needs the mmc2 SDIO device to freeze, and bcmdhd will not let
#    it: the dongle holds a wakelock and the freeze request is refused, so
#    `echo disk` aborts with -EBUSY.  Unbinding the driver before the save is
#    what took hot warp from 87.5% to 8/8 (#56/#57).  wpa_supplicant is killed
#    first because it keeps the interface busy and races the unbind.
#  - dhcpcd is an ext4 writer (leases + hooks).  See the file header: nothing
#    may write ext4 between the save and the poweroff.
# warpnet is parked FIRST -- it is the service that would otherwise notice the
# link disappear and reload the driver, which is the same ext4 write.
# /run is tmpfs, so the flag rides into the restored session inside the blob;
# the replay side below deletes it there and gives warpnet its job back.
touch /run/warpnet.off
sv down wpa_supplicant dhcpcd 2>/dev/null
sleep 3
echo 0 > /sys/class/rkwifi/driver 2>/dev/null
sleep 2

# Plain save (halt=0) with keepbf set by hand.  DO NOT use halt=1: the blob
# treats a halt save as a different request and does not arm W5BF at all --
# the journal then records stat=1 on every record and p5+0x20000 stays zero,
# so U-Boot sees no bootflag and the next POWER is an ordinary boot.  That is
# exactly how the first F12 test came back as a hot warp.  halt=1 only sets
# keepbf+earlydisp before the save anyway, so ask for those two directly and
# leave the blob on the path that actually writes the bootflag.
echo 1 > /proc/warp/earlydisp
echo 1 > /proc/warp/keepbf
echo 0 > /proc/warp/halt
echo 0 > /proc/warp/canceled
echo 1 > /proc/warp/compress
sync

echo "saving ..."
echo disk > /sys/power/state
rc=$?
echo "save returned rc=$rc uptime=$(cut -d. -f1 /proc/uptime)"

# A failed save must not power off: the session is still live, so cutting the
# power would lose it outright and leave warpnet parked with no way back in.
if [ "$rc" != "0" ]; then
    echo "save failed -- staying up, unparking warpnet"
    rm -f /run/warpnet.off
    rm -f /run/coldwarp.lock
    exit 1
fi

# ---- replay guard --------------------------------------------------------
# Live side: W5BF is still armed, so powering off hands the image to U-Boot.
# Restored side: U-Boot consumed it and the kernel disarmed it, so this run is
# the replay -- leave the power alone and let the session carry on.
bf=$(dd if=/dev/mmcblk0p5 bs=1 skip=$((0x20000)) count=4 2>/dev/null \
     | od -An -tx1 | tr -d ' \n')
echo "post-save bootflag=$bf"

if [ "$bf" = "57354246" ]; then
    echo "live side -> poweroff (U-Boot cold-restores on the next POWER)"
    sync
    # -f: straight to reboot(RB_POWER_OFF), i.e. the kernel's device_shutdown()
    # and rk818 do the cutting.  WITHOUT it busybox signals init first, runit
    # then runs its shutdown scripts and umounts -- and that umount flushes
    # whatever the dying services wrote, which is the ext4 divergence this
    # script exists to avoid.  This is as close to the vendor's "save, then cut
    # power at once" as software gets.
    /usr/bin/poweroff -f
fi

echo "restored side -> not powering off; handing warpnet its job back"
# The wifi driver was unbound for the save, so this session comes back with no
# wlan0.  Un-parking warpnet is what re-enumerates the SDIO card and brings the
# link back (~95s in the cw150 runs).  Leave it parked and the board restores
# into a working session with no network and no way in.
rm -f /run/warpnet.off
rm -f /run/coldwarp.lock
