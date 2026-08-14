#!/bin/sh
# tmux status bar IM monitor
# Usage: set -g status-right "#(sh /opt/bin/im_status)"

CURRENT_IM=yong
[ -f /root/.profile ] && . /root/.profile 2>/dev/null

if [ "$CURRENT_IM" = "fcitx5" ]; then
    fcitx5_status=$(fcitx5-remote 2>/dev/null)
    if [ "$fcitx5_status" = "1" ]; then
        printf '#[fg=gray] #[fg=colour255]'
        cat /tmp/fcitx5_status 2>/dev/null
    else
        echo ""
    fi
elif [ "$CURRENT_IM" = "yong" ]; then
    if [ -s /tmp/yong_status ]; then
        printf '#[fg=gray] #[fg=colour255]'
        iconv -f gbk -t utf8 /tmp/yong_status 2>/dev/null
    else
        echo ""
    fi
fi
