#!/bin/bash


# 定义两个状态文件路径
state_file="/sys/rk818_battery/state"
state_file2="/sys/class/power_supply/BATTERY/device/state"

# 优先使用 state_file，如果不存在则使用 state_file2
if [[ -f "$state_file" ]]; then
    # 从第一个文件读取 remain_capacity（实际是 soc 值）
    remain_capacity=$(grep -oP 'real_soc\s*=\s*\K\d+' "$state_file")
    if [[ -n "$remain_capacity" ]]; then
        remain=$remain_capacity  # 直接使用 soc 值，不除以 42
    else
        remain=0
    fi
elif [[ -f "$state_file2" ]]; then
    # 从第二个文件读取 remain_capacity
    remain_capacity=$(grep -oP 'remain_capacity\s*=\s*\K\d+' "$state_file2")
    if [[ -n "$remain_capacity" ]]; then
        remain=$remain_capacity  # 直接使用 soc 值
    else
        remain=0
    fi
else
    echo "Error: Neither $state_file nor $state_file2 found"
    exit 1
fi

# 从 state_file2 读取 status（始终使用第二个文件）
status=""
if [[ -f "$state_file2" ]]; then
    status=$(grep -oP 'status\s*=\s*\K\d+' "$state_file2")
fi

# 根据 status 设置 sign
if [[ "$status" -eq 2 ]]; then
    sign=""
elif [[ "$status" -eq 1 ]]; then
    sign=""
else
    sign=""
fi

# 根据 remain 设置 batcap
if [[ "$remain" -ge 90 ]]; then
    batcap=""
elif [[ "$remain" -ge 80 ]]; then
    batcap=""
elif [[ "$remain" -ge 70 ]]; then
    batcap=""
elif [[ "$remain" -ge 60 ]]; then
    batcap=""
elif [[ "$remain" -ge 50 ]]; then
    batcap=""
elif [[ "$remain" -ge 40 ]]; then
    batcap=""
elif [[ "$remain" -ge 30 ]]; then
    batcap=""
elif [[ "$remain" -ge 20 ]]; then
    batcap=""
elif [[ "$remain" -ge 10 ]]; then
    batcap=""
else
    batcap=""
fi

# 电量低于 20% 时显示警告
if [[ "$remain" -lt 20 ]]; then
    tmux display-message "电量低，请注意充电。"
fi

# 输出结果
echo "${batcap}${sign}"
