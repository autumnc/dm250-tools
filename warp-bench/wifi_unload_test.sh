#!/bin/sh
# Healthy-bus wifi unload/reload timing probe. Runs detached (nohup) because
# unloading bcmdhd removes wlan0, which our SSH rides on.
GW=192.168.50.1
F=/root/wifi-unload-test.txt
ts(){ cut -d' ' -f1 /proc/uptime; }
alive(){ ping -c1 -W2 "$GW" >/dev/null 2>&1 && echo OK || echo FAIL; }
op(){ cat /sys/class/net/wlan0/operstate 2>&1; }
sdio(){ ls /sys/bus/sdio/devices/ 2>&1 | tr '\n' ' '; }
{
echo "start $(date +%H:%M:%S) boot=$(cat /proc/sys/kernel/random/boot_id)"
echo "  pre    t=$(ts) operstate=$(op) ping=$(alive) sdio=[$(sdio)]"
T0=$(ts)
timeout 120 sh -c 'echo 0 > /sys/class/rkwifi/driver'
RC0=$?
T1=$(ts)
echo "  unload t0=$T0 t1=$T1 delta=$(awk "BEGIN{print $T1-$T0}") rc=$RC0"
echo "         wlan0=[$(ip -o link show wlan0 2>&1 | head -c48)] sdio=[$(sdio)] ping=$(alive)"
sleep 3
T2=$(ts)
timeout 120 sh -c 'echo 1 > /sys/class/rkwifi/driver'
RC1=$?
T3=$(ts)
echo "  reload t2=$T2 t3=$T3 delta=$(awk "BEGIN{print $T3-$T2}") rc=$RC1"
sleep 20
echo "  post   t=$(ts) operstate=$(op) ping=$(alive)"
echo "         ip=[$(ip -4 -o addr show wlan0 2>&1 | head -c64)] sdio=[$(sdio)]"
echo "done $(date +%H:%M:%S)"
} >"$F" 2>&1
dmesg > /root/wifi-unload-dmesg.txt 2>&1
