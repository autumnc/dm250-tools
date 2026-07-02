#!/bin/sh
PROFILE=/root/.profile

# Read current value
CURRENT_IM=yong
if [ -f "$PROFILE" ]; then
    val=$(grep '^CURRENT_IM=' "$PROFILE" 2>/dev/null | cut -d= -f2)
    [ -n "$val" ] && CURRENT_IM="$val"
fi

case "$CURRENT_IM" in
    yong)      im_display="yong 输入法" ;;
    fcitx5)    im_display="fcitx5-rime" ;;
    *)         im_display="$CURRENT_IM (未知)" ;;
esac

echo "当前输入法: $im_display"
echo ""
echo "可选:"
echo "  1) yong 输入法"
echo "  2) fcitx5-rime"
echo "  q) 退出"
echo ""
printf "请选择 [1/2/q]: "
read choice

case "$choice" in
    1) new_val="yong"; new_name="yong 输入法" ;;
    2) new_val="fcitx5"; new_name="fcitx5-rime" ;;
    q|Q) exit 0 ;;
    *) echo "无效选择"; exit 1 ;;
esac

if [ "$new_val" = "$CURRENT_IM" ]; then
    echo "已经是 $new_name，无需切换。"
    exit 0
fi

sed -i "s/^CURRENT_IM=.*/CURRENT_IM=$new_val/" "$PROFILE"
echo "已切换为: $new_name"
echo "改动之后注销重新登录起效。"
sleep 3
