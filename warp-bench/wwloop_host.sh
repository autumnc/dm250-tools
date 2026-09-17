#!/bin/bash
# Host driver: run N warm-warp rounds. wwround.sh self-reboots at the end of
# each round, so we only have to wait for the device to come back -- we never
# depend on SSH reaching a device whose warp killed wlan0.
DEV=root@192.168.50.251
N=${N:-6}
QUIESCE=${QUIESCE:-30}
LOG=/home/ywz/wwloop_host.log
: > "$LOG"
S(){ timeout 20 ssh -o ConnectTimeout=6 -o StrictHostKeyChecking=no "$DEV" "$@" 2>/dev/null; }
L(){ echo "$*" | tee -a "$LOG"; }
up(){ S 'cut -d" " -f1 /proc/uptime'; }
bootid(){ S 'cat /proc/sys/kernel/random/boot_id'; }
pingable(){ S 'ping -c1 -W1 192.168.50.1 >/dev/null 2>&1 && echo OK || echo FAIL'; }
waitup(){
  for i in $(seq 1 40); do
    U=$(up); [ -z "$U" ] && { sleep 5; continue; }
    P=$(pingable)
    if [ "$P" = "OK" ] && awk "BEGIN{exit !($U>25)}"; then echo "$U"; return 0; fi
    sleep 5
  done; return 1
}

for R in $(seq 1 $N); do
  L ""; L "=== round $R ==="
  if ! U=$(waitup); then L "round $R: device/wifi not up before launch -> stopping loop"; break; fi
  B0=$(bootid)
  if [ -z "$B0" ]; then L "round $R: no bootid -> stopping loop"; break; fi
  L "round $R: pre-launch uptime=$U boot=$B0"
  S "QUIESCE=$QUIESCE nohup sh /root/wwround.sh $R >/dev/null 2>&1 &" >/dev/null 2>&1

  RES="no-return"
  for i in $(seq 1 90); do
    B1=$(bootid)
    if [ -n "$B1" ] && [ "$B1" != "$B0" ]; then RES="rebooted"; break; fi
    sleep 4
  done
  L "round $R: $RES"
  if ! U=$(waitup); then L "round $R: device/wifi not up after round -> stopping loop"; break; fi

  RLT=$(S "awk '/---- round $R /{p=1} p' /root/wwround.txt")
  L "----- round $R log -----"
  L "$RLT"
  RC=$(echo "$RLT" | /bin/grep -oE 'rc=[0-9]+' | tail -1)
  DL=$(echo "$RLT" | /bin/grep -oE 'delta=[0-9.]+' | tail -1)
  ER=$(echo "$RLT" | /bin/grep -oE 'err=-?[0-9]+' | tail -1)
  L "===== round $R SUMMARY rc='$RC' $DL $ER ====="
  scp -q -o ConnectTimeout=6 -o StrictHostKeyChecking=no "$DEV:/root/dmesg-r$R.log" "/home/ywz/dmesg-r$R.log" 2>/dev/null
  scp -q -o ConnectTimeout=6 -o StrictHostKeyChecking=no "$DEV:/root/jrnl-r$R.bin" "/home/ywz/jrnl-r$R.bin" 2>/dev/null
  sleep 2
done
L ""; L "=== ALL ROUNDS DONE ==="
