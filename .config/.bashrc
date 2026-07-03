PATH=/opt/bin:/root/bin:/usr/local/bin:$PATH
#if [ -z "$FBTERM" ] && [ -z "$TMUX" ] && [ "$TERM" = "linux" ]; then
#	exec fbterm -- tmux new-session -A -s main
#fi

#if [ -n "$FBTERM" ] && [ -z "$TMUX" ]; then
#	exec tmux new-session -A -s main
#fi
# ==========================================
# 现代命令行工具无缝替换配置 (rg & fd)
# ==========================================

# 1. 将 grep 替换为 rg (ripgrep)
grep() {
    local rg_unsafe_args=("-P" "--perl-regexp" "-z" "--null-data" "-U" "--binary" "--mmap")
    for arg in "$@"; do
        for unsafe in "${rg_unsafe_args[@]}"; do
            if [[ "$arg" == "$unsafe" ]]; then
                command grep "$@"
                return
            fi
        done
    done
    # 默认加上 --no-ignore 和 --hidden，使其行为等同于传统 grep
    command rg --no-ignore --hidden "$@"
}

# 2. 将 find 替换为 fd
find() {
    local fd_unsafe_args=("-execdir" "-fprint" "-fprintf" "-fls" "-ok" "-okdir" "-printf" "-print0")
    local fd_args=("-H" "-I") # 默认包含隐藏文件并忽略 .gitignore 规则
    
    # 参数转换与安全检查
    local i=1
    while [[ $i -le $# ]]; do
        local arg="${!i}"
        case "$arg" in
            -execdir|-fprint|-fprintf|-fls|-ok|-okdir|-printf|-print0)
                # 发现不兼容参数，直接调用原生 find
                command find "$@"
                return
                ;;
            -name)
                # 自动转换 -name "*.ext" 为 -e ext
                local next_i=$((i + 1))
                local next_arg="${!next_i}"
                if [[ "$next_arg" == \*.* ]]; then
                    fd_args+=("-e" "${next_arg#\*.}")
                    ((i++)) # 跳过下一个参数
                else
                    fd_args+=("-g" "$next_arg") # 其他情况转为 glob 搜索
                    ((i++))
                fi
                ;;
            -type)
                # 自动转换 -type f 为 -t f
                local next_i=$((i + 1))
                fd_args+=("-t" "${!next_i}")
                ((i++))
                ;;
            *)
                fd_args+=("$arg")
                ;;
        esac
        ((i++))
    done

    command fd "${fd_args[@]}"
}
