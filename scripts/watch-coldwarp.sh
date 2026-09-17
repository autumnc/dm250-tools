#!/bin/bash
# watch-coldwarp.sh -- after an F12 cold warp, wait for the DM250 to leave the
# network and then come back on POWER, and capture the restored state.
#
# One line of stdout per event (these become Monitor notifications):
#   "board OFF ..."   -- confirmed dark, now press POWER
#   "board BACK ..."  -- captured to $CAP, exit 0
# Anything else is a timeout / error and also ends the watch.
HOST=root@192.168.50.251
SSH="ssh -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=no"
CAP=/home/ywz/dm250-evidence/coldwarp-test-capture.log
REMOTE=/home/ywz/dm250-tools/scripts/coldcap-remote.sh

up() { $SSH "$HOST" 'true' 2>/dev/null; }

# Phase 1: confirm it is dark.  Two consecutive failures, so a single dropped
# ssh does not read as "the board powered off".
gone=0
for _ in $(seq 1 120); do
    if up; then
        gone=0
    else
        gone=$((gone + 1))
        if [ "$gone" -ge 2 ]; then
            echo "board OFF the network at $(date '+%T') -- press POWER to bring it back"
            break
        fi
    fi
    sleep 5
done
if [ "$gone" -lt 2 ]; then
    echo "board never left the network within 10 min -- still up, nothing to wait for"
    exit 0
fi

# Phase 2: wait for the cold restore.  U-Boot restores DRAM on POWER, then the
# kernel resumes and warpnet re-enumerates the SDIO card (~95 s in the cw150 runs).
for _ in $(seq 1 240); do
    if up; then
        $SSH "$HOST" 'sh -s' < "$REMOTE" >"$CAP" 2>&1
        echo "board BACK at $(date '+%T') -- captured to $CAP"
        exit 0
    fi
    sleep 10
done
echo "board still down after 40 min -- check it by hand"
exit 1
