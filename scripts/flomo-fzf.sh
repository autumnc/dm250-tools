#!/bin/bash

DB_FILE="$HOME/.flomolist.json"
TEMP_DIR=$(mktemp -d)

# 清理函数
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# 更新数据库的函数
update_database_full() {
    echo "正在完全重建数据库..."
    flomo-go list --all --json > "$DB_FILE"
    echo "数据库已完全重建"
}

update_database_incremental() {
    echo "正在获取最新数据进行增量更新..."
    local temp_new_data="$TEMP_DIR/new_data.json"
    flomo-go list --limit 100 --json > "$temp_new_data"
    
    if [ -f "$DB_FILE" ]; then
        # 合并现有数据和新数据，去重
        local temp_merged="$TEMP_DIR/merged.json"
        jq -s '
            def merge_unique:
                .[0].data as $existing |
                .[1].data as $new |
                ($existing + $new | group_by(.slug) | map(.[0])) as $merged |
                {data: $merged};
            merge_unique
        ' "$DB_FILE" "$temp_new_data" > "$temp_merged"
        
        mv "$temp_merged" "$DB_FILE"
    else
        mv "$temp_new_data" "$DB_FILE"
    fi
    
    # 按 updated_at 排序（从新到旧）
    local temp_sorted="$TEMP_DIR/sorted.json"
    jq '
        .data |= sort_by(.updated_at) | 
        .data |= reverse |
        .
    ' "$DB_FILE" > "$temp_sorted"
    
    mv "$temp_sorted" "$DB_FILE"
    
    echo "数据库已增量更新"
}

update_database_recent() {
    echo "正在更新最新条目..."
    local temp_recent="$TEMP_DIR/recent.json"
    flomo-go list --limit 1 --json > "$temp_recent"
    
    if [ -f "$DB_FILE" ]; then
        local temp_updated="$TEMP_DIR/updated.json"
        jq -s '
            def update_or_add:
                .[0].data as $existing |
                .[1].data as $recent |
                reduce $recent[] as $item ($existing; 
                    if any(.slug == $item.slug) then 
                        map(if .slug == $item.slug then $item else . end)
                    else 
                        . + [$item]
                    end
                ) |
                {data: .};
            update_or_add
        ' "$DB_FILE" "$temp_recent" > "$temp_updated"
        
        mv "$temp_updated" "$DB_FILE"
    else
        mv "$temp_recent" "$DB_FILE"
    fi
    
    # 再次排序
    local temp_sorted="$TEMP_DIR/sorted.json"
    jq '
        .data |= sort_by(.updated_at) | 
        .data |= reverse |
        .
    ' "$DB_FILE" > "$temp_sorted"
    
    mv "$temp_sorted" "$DB_FILE"
    
    echo "最新条目已更新"
}

delete_from_database() {
    local slug_to_delete="$1"
    if [ -f "$DB_FILE" ]; then
        echo "正在从本地数据库删除条目: $slug_to_delete"
        # 使用jq过滤掉要删除的slug
        local temp_filtered="$TEMP_DIR/filtered.json"
        jq --arg slug "$slug_to_delete" '
            .data |= map(select(.slug != $slug))
        ' "$DB_FILE" > "$temp_filtered"
        
        # 检查过滤后的结果
        local original_count=$(jq '.data | length' "$DB_FILE")
        local filtered_count=$(jq '.data | length' "$temp_filtered")
        
        mv "$temp_filtered" "$DB_FILE"
        
        if [ "$filtered_count" -lt "$original_count" ]; then
            echo "成功从本地数据库删除条目 $slug_to_delete (从 $original_count 条减少到 $filtered_count 条)"
        else
            echo "警告: 本地数据库中未找到条目 $slug_to_delete"
        fi
    else
        echo "本地数据库文件不存在: $DB_FILE"
    fi
}

# 检查并初始化数据库
initialize_database() {
    if [ ! -f "$DB_FILE" ]; then
        echo "数据库文件不存在，正在创建..."
        update_database_full
    else
        echo "检查数据库更新时间..."
        # 获取数据库中最晚的更新时间
        if jq -e '.data | length > 0' "$DB_FILE" >/dev/null 2>&1; then
            latest_update=$(jq -r '.data[0].updated_at' "$DB_FILE" 2>/dev/null)
            
            if [ -n "$latest_update" ] && [ "$latest_update" != "null" ]; then
                # 转换时间为秒级时间戳
                latest_timestamp=$(date -d "$latest_update" +%s 2>/dev/null)
                current_timestamp=$(date +%s)
                
                if [ -n "$latest_timestamp" ]; then
                    days_diff=$(( (current_timestamp - latest_timestamp) / 86400 ))
                    
                    if [ $days_diff -gt 90 ]; then
                        echo "数据库已超过90天未更新，正在完全重建..."
                        update_database_full
                    else
                        echo "数据库较新($days_diff天)，执行增量更新..."
                        update_database_incremental
                    fi
                else
                    echo "无法解析更新时间，执行完全重建..."
                    update_database_full
                fi
            else
                echo "无法获取更新时间，执行完全重建..."
                update_database_full
            fi
        else
            echo "数据库为空，执行完全重建..."
            update_database_full
        fi
    fi
}

# 在程序开始时执行一次增量更新
initialize_database

# 主循环
while true; do
    # 检查数据库是否有数据
    if ! jq -e '.data | length > 0' "$DB_FILE" >/dev/null 2>&1; then
        echo "数据库为空，请先添加一些笔记"
        break
    fi
    
    # 解析JSON并构建一个临时文件，每行格式：SLUG|CONTENT|UPDATED_AT
    temp_file="$TEMP_DIR/selection.txt"
    jq -r '.data[] | "\(.slug)|\(.content)|\(.updated_at)"' "$DB_FILE" > "$temp_file"
    
    # 使用fzf选择，显示CONTENT，直接区分各种快捷键
    result=$(cat "$temp_file" | fzf \
        --with-nth=2 \
        --delimiter='|' \
        --preview='echo {2} |fold -s -w 120' \
        --preview-window='top:50%,border-bottom' \
        --header='C-d 删除 | C-e 编辑 | C-n 新建 | Enter 详情 | ESC 退出' \
        --header-lines=0 \
        --bind 'enter:become(echo "ENTER|{}")' \
        --bind 'ctrl-e:become(echo "EDIT|{}")' \
        --bind 'ctrl-d:become(echo "DELETE|{}")' \
        --bind 'ctrl-n:become(echo "NEW|{}")' \
        --bind 'esc:abort')
    
    # 检查是否按下ESC退出
    if [ $? -eq 130 ]; then
        echo "退出程序"
        break
    fi
    
    if [ -n "$result" ]; then
        mode=$(echo "$result" | cut -d'|' -f1)
        data=$(echo "$result" | cut -d'|' -f2-)
        slug=$(echo "$data" | cut -d'|' -f1 |sed "s/'//g")
        

        if [ "$mode" = "ENTER" ]; then
            # 运行 flomo-go get
            flomo-go get "$slug"
            echo "按任意键继续..."
            read -n 1 -s
        elif [ "$mode" = "EDIT" ]; then
            # 提取content
            content=$(echo "$data" | cut -d'|' -f2-)
            
            # 创建临时文件用于编辑
            edit_temp="$TEMP_DIR/edit_temp.txt"
            echo "$content" > "$edit_temp"
            
            # 打开vim编辑
            tmux display-popup -w 80% -h 15% -E vim -c startinsert -u ~/.vimhiderc "$edit_temp"
            
            # 读取编辑后的内容
            new_content=$(cat "$edit_temp")
            
            # 执行 flomo-go edit 命令
            flomo-go edit "$slug" "$new_content"
            
            # 增量更新数据库（获取最新条目）
            update_database_recent
            
            # 清理临时文件
            rm -f "$edit_temp"
            
            echo "笔记已编辑并更新数据库"
            echo "按任意键继续..."
            read -n 1 -s
        elif [ "$mode" = "DELETE" ]; then
            # 确认删除
            read -p "确认删除笔记 $slug 吗？(y/n): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                # 先从远程删除
                echo "正在从远程删除笔记..."
                flomo-go delete "$slug"
                
                # 然后从本地数据库中删除对应条目
		echo "$slug"
                delete_from_database "$slug"
                
                echo "笔记已从远程和本地数据库删除"
            else
                echo "已取消删除"
            fi
            echo "按任意键继续..."
            read -n 1 -s
        elif [ "$mode" = "NEW" ]; then
            # 创建临时文件用于新建笔记
            new_temp="$TEMP_DIR/new_temp.txt"
            
            # 打开vim编辑器，让用户输入新笔记内容
            tmux display-popup -w 80% -h 15% -E vim -c startinsert -u ~/.vimhiderc "$new_temp"
            
            # 读取编辑后的内容
            new_content=$(cat "$new_temp")
            
            # 检查内容是否为空
            if [ -n "$new_content" ]; then
                # 执行 flomo-go new 命令
                flomo-go new "$new_content"
                # 增量更新数据库（获取最新条目）
                update_database_recent
                echo "新笔记已创建并更新数据库"
            else
                echo "内容为空，已取消创建"
            fi
            
            # 清理临时文件
            rm -f "$new_temp"
            
            echo "按任意键继续..."
            read -n 1 -s
        fi
    else
        echo "未选择任何项目，退出程序"
        break
    fi
done

echo "程序结束"

