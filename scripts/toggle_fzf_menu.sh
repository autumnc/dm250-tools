#!/bin/bash

# 获取当前菜单状态
STATE=$(tmux show-option -gqv @fzf_menu_active)

if [ "$STATE" == "1" ]; then
    # 如果菜单已激活，则取消（重置状态并发送中断信号或关闭）
    tmux set-option -g @fzf_menu_active 0
    # 这里可以执行清理逻辑，比如向运行 fzf 的窗格发送 Ctrl-C
    tmux send-keys C-c
else
    # 如果菜单未激活，则标记为激活并启动 fzf
    tmux set-option -g @fzf_menu_active 1
    # 运行你的 fzf 菜单脚本（请替换为实际路径）
    /root/bin/mymenu
    
    # 当 fzf 正常退出或按 Esc 退出后，自动重置状态
    tmux set-option -g @fzf_menu_active 0
fi
