#!/bin/sh
# tmux status bar IM monitor
# Usage: set -g status-right "#(sh /opt/bin/im_status)"

CURRENT_IM=yong
[ -f /root/.profile ] && . /root/.profile 2>/dev/null

if [ "$CURRENT_IM" = "fcitx5" ]; then
    printf '#[fg=colour119] #[fg=colour255]'
    cat /tmp/fcitx5_status 2>/dev/null
elif [ "$CURRENT_IM" = "yong" ]; then
    printf '#[fg=colour119] #[fg=colour255]'
    iconv -f gbk -t utf8 /tmp/yong_status 2>/dev/null
fi
