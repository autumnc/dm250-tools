#!/bin/sh
# fcitx5 status query for fbterm environment

# Find fcitx5's dbus session address from running process
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    PID=$(pgrep -x fcitx5 2>/dev/null | head -1)
    if [ -n "$PID" ]; then
        eval "$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | grep '^DBUS_SESSION_BUS_ADDRESS=')"
        export DBUS_SESSION_BUS_ADDRESS
    fi
fi

DEST=org.fcitx.Fcitx5
PATH=/controller
IFACE=org.fcitx.Fcitx.Controller1

dbus_call() {
    dbus-send --session --dest="$DEST" --print-reply "$PATH" "$IFACE.$1" 2>/dev/null
}

# State: 0=关闭 1=非激活 2=激活
state=$(dbus_call State | awk '/int32/{print $3}')
case "$state" in
    0) state_name="关闭(未输入中文)" ;;
    1) state_name="非激活" ;;
    2) state_name="激活(正在输入)" ;;
    *) state_name="fcitx5 未运行" ;;
esac

im=$(dbus_call CurrentInputMethod | awk -F'"' '/string/{print $2}')
[ -z "$im" ] && im="(无焦点时正常为空)"

echo "=== fcitx5 状态 ==="
echo "状态: $state_name"
echo "当前输入法: $im"
echo ""

echo "=== 已配置输入法 ==="
dbus_call AvailableInputMethods | tr ')' '\n' | grep 'string "' | while read line; do
    name=$(echo "$line" | grep -o '"\([^"]*\)"' | head -1 | tr -d '"')
    [ -n "$name" ] && echo "  $name"
done
