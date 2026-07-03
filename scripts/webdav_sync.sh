#!/bin/bash

# ============================================
# rclone WebDAV 双向同步脚本 (时间戳优先)
# ============================================

set -euo pipefail

# --- 配置文件和变量 ---
CONFIG_DIR="$HOME/.config/rclone-bisync"
CONFIG_FILE="$CONFIG_DIR/sync.conf"
LOG_DIR="$CONFIG_DIR/logs"

# --- 函数定义 ---

# 初始化配置目录和日志目录
init_env() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
}

# 检查 rclone 是否安装
check_rclone() {
    if ! command -v rclone &> /dev/null; then
        echo "错误：未找到 rclone，请先安装 rclone。"
        echo "安装指南：https://rclone.org/install/"
        exit 1
    fi
}

# 交互式获取配置信息
get_config() {
    echo "===== 首次运行配置 ====="
    echo "正在设置 WebDAV 远程连接 (将存储为名为 'mydav' 的 rclone 配置)"
    echo ""

    read -p "请输入 WebDAV 服务器地址 (例如 https://example.com/remote.php/dav/files/username/): " WEBDAV_URL
    read -p "请输入 WebDAV 用户名: " WEBDAV_USER
    read -s -p "请输入 WebDAV 密码: " WEBDAV_PASS
    echo ""
    read -p "请输入 WebDAV 上的远程同步目录 (例如 /Documents/Sync，留空表示根目录): " REMOTE_DIR
    read -p "请输入本地同步目录的完整路径: " LOCAL_DIR

    # 处理远程目录路径，确保不以 / 开头(如果用户习惯输入绝对路径)
    REMOTE_DIR="${REMOTE_DIR#/}"
    if [ -z "$REMOTE_DIR" ]; then
        REMOTE_DIR="."
    fi

    # 创建本地目录
    mkdir -p "$LOCAL_DIR"

    # 配置 rclone remote
    echo "正在创建 rclone 远程配置 'mydav'..."
    rclone config create mydav webdav \
        url "$WEBDAV_URL" \
        vendor other \
        user "$WEBDAV_USER" \
        pass "$(rclone obscure "$WEBDAV_PASS")" \
        --non-interactive &> /dev/null

    if [ $? -ne 0 ]; then
        echo "错误：创建 rclone 配置失败，请检查输入信息。"
        exit 1
    fi

    # 保存配置到文件
    cat > "$CONFIG_FILE" <<EOF
REMOTE_DIR="$REMOTE_DIR"
LOCAL_DIR="$LOCAL_DIR"
EOF

    echo "配置已保存至 $CONFIG_FILE"
    echo ""
}

# 加载配置文件
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "未找到配置文件，将进入首次配置..."
        get_config
    fi
    source "$CONFIG_FILE"
}

# 检查连通性
check_connectivity() {
    echo "正在检查 WebDAV 连接..."
    if ! rclone lsd mydav:/ &> /dev/null; then
        echo "错误：无法连接到 WebDAV 服务器，请检查网络、地址和凭证。"
        echo "您可以删除配置文件重新配置：rm -f $CONFIG_FILE && rclone config delete mydav"
        exit 1
    fi
    echo "连接成功。"
}

# 初次同步逻辑 (处理空目录情况)
initial_sync() {
    local remote_full="mydav:/$REMOTE_DIR"
    local remote_count=0
    local local_count=0

    echo "正在检查目录状态..."

    # 统计远程文件数量 (忽略目录)
    remote_count=$(rclone ls "$remote_full" 2>/dev/null | grep -v '/$' | wc -l)
    # 统计本地文件数量
    local_count=$(find "$LOCAL_DIR" -type f 2>/dev/null | wc -l)

    echo "远程文件数: $remote_count, 本地文件数: $local_count"

    # 情况1: 双方都为空，无需操作
    if [ "$remote_count" -eq 0 ] && [ "$local_count" -eq 0 ]; then
        echo "远程和本地目录均为空，无需初始化同步。"
        return
    fi

    # 情况2: 本地为空，从远程下载
    if [ "$local_count" -eq 0 ] && [ "$remote_count" -gt 0 ]; then
        echo "本地目录为空，正在从远程下载所有文件..."
        rclone sync "$remote_full" "$LOCAL_DIR" \
            --verbose \
            --progress \
            --create-empty-src-dirs
        echo "初始化下载完成。"
        return
    fi

    # 情况3: 远程为空，从本地上传
    if [ "$remote_count" -eq 0 ] && [ "$local_count" -gt 0 ]; then
        echo "远程目录为空，正在上传本地所有文件..."
        rclone sync "$LOCAL_DIR" "$remote_full" \
            --verbose \
            --progress \
            --create-empty-src-dirs
        echo "初始化上传完成。"
        return
    fi

    # 情况4: 双方都不为空，运行一次 bisync 并依赖其冲突解决
    echo "双方目录均不为空，将以安全方式运行初次双向同步..."
    echo "注意：如果有同名文件，将保留修改时间较新的版本。"
    perform_bisync --resync
}

# 执行双向同步
perform_bisync() {
    local extra_flags="${1:-}"
    local remote_full="mydav:/$REMOTE_DIR"
    local log_file="$LOG_DIR/bisync_$(date +%Y%m%d_%H%M%S).log"

    echo "开始双向同步... (日志: $log_file)"

    # 核心双向同步命令
    # --create-empty-src-dirs: 同步空目录
    # --ignore-size: 只依靠时间戳和哈希判断修改(更精确)
    # --resilient: 增强错误恢复能力
    # --conflict-resolve newer: 冲突时保留较新版本
    # --compare: 比较模式，可选 size,modtime,checksum (modtime 优先)
    rclone bisync "$LOCAL_DIR" "$remote_full" \
        --create-empty-src-dirs \
        --resilient \
        --conflict-resolve newer \
        --compare size,modtime \
        --recover \
        --max-lock 10m \
        --verbose \
        --log-file "$log_file" \
        $extra_flags

    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo "双向同步成功完成。"
    elif [ $exit_code -eq 2 ]; then
        echo "警告：同步完成但存在部分错误或冲突，请检查日志: $log_file"
    else
        echo "错误：双向同步失败 (退出码: $exit_code)，请检查日志: $log_file"
        exit 1
    fi

    # 清理旧日志 (保留最近10个)
    ls -t "$LOG_DIR"/bisync_*.log 2>/dev/null | tail -n +11 | xargs rm -f
}

# --- 主流程 ---
main() {
    init_env
    check_rclone
    load_config
    check_connectivity

    # 处理命令行参数
    case "${1:-}" in
        --force-initial)
            echo "强制执行初次同步检查..."
            initial_sync
            ;;
        --reconfig)
            echo "重新配置..."
            rm -f "$CONFIG_FILE"
            # 也可选删除rclone config: rclone config delete mydav
            load_config
            check_connectivity
            initial_sync
            echo "配置更新并初始化完成。"
            ;;
        *)
            echo "========================================="
            echo "  WebDAV 双向同步脚本 (时间戳优先)"
            echo "========================================="
            # 检查是否是首次同步或需要初始化
            if [ ! -f "$CONFIG_DIR/.initialized" ]; then
                echo "检测到尚未进行初次同步，正在执行初始化流程..."
                initial_sync
                touch "$CONFIG_DIR/.initialized"
            else
                perform_bisync
            fi
            ;;
    esac

    echo "操作完成。"
}

# 运行主函数并传递参数
main "$@"