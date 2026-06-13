#!/bin/bash

# ============================================================
# 配置区域
# ============================================================

IP_FILE_URL="https://raw.githubusercontent.com/Eveaz/scripts/main/ufw_block_ips.txt"
TMP_FILE="/tmp/ufw_block_ips.txt"

# 任何情况退出都自动清理临时文件
trap 'rm -f "$TMP_FILE" && echo "临时文件已清理：$TMP_FILE"' EXIT

# ============================================================
# 检查权限
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 root 权限运行（sudo ./ufw_block.sh）"
    exit 1
fi

# ============================================================
# 检查 ufw 运行状态并获取规则
# ============================================================

UFW_STATUS=$(ufw status numbered)

if ! echo "$UFW_STATUS" | grep -q "Status: active"; then
    echo "错误：UFW 未启用，请先执行 ufw enable"
    exit 1
fi

# ============================================================
# 下载 IP 列表
# ============================================================

echo "=== 从 GitHub 下载 IP 列表 ==="
echo "URL: $IP_FILE_URL"
echo ""

if command -v curl &> /dev/null; then
    curl -fsSL "$IP_FILE_URL" -o "$TMP_FILE"
    DOWNLOAD_STATUS=$?
elif command -v wget &> /dev/null; then
    wget -q "$IP_FILE_URL" -O "$TMP_FILE"
    DOWNLOAD_STATUS=$?
else
    echo "错误：系统未安装 curl 或 wget"
    exit 1
fi

if [[ $DOWNLOAD_STATUS -ne 0 || ! -s "$TMP_FILE" ]]; then
    echo "错误：下载失败，请检查 URL 或网络连接"
    exit 1
fi

ADD_COUNT=$(grep '^add|' "$TMP_FILE" 2>/dev/null | wc -l | tr -d ' ')
DEL_COUNT=$(grep '^del|' "$TMP_FILE" 2>/dev/null | wc -l | tr -d ' ')
echo "下载成功：待添加 $ADD_COUNT 条，待删除 $DEL_COUNT 条"
echo ""

# ============================================================
# 函数：获取新规则应插入的位置（最后一条 DENY IN 规则的下一位）
# ============================================================

get_insert_position() {
    local last_deny
    last_deny=$(echo "$UFW_STATUS" | grep "DENY IN" | grep -oP '(?<=\[)\s*\d+(?=\])' | tr -d ' ' | tail -1)
    if [[ -n "$last_deny" ]]; then
        echo $(( last_deny + 1 ))
    else
        echo 1
    fi
}

# ============================================================
# 函数：删除指定 IP 的 DENY IN 屏蔽规则
# 注意：函数内部会同步更新全局变量 UFW_STATUS
# 返回值：0=成功，1=失败
# ============================================================

delete_rule() {
    local ip="$1"
    local comment="$2"
    local rule_num
    local ERR=""
    local EXIT_CODE=0

    # 循环删除（可能存在多条重复规则，只删 DENY IN 行）
    while echo "$UFW_STATUS" | grep "DENY IN" | grep -qF "$ip"; do
        rule_num=$(echo "$UFW_STATUS" | grep "DENY IN" | grep -F "$ip" | grep -oP '(?<=\[)\s*\d+(?=\])' | tr -d ' ' | head -1)
        if [[ -n "$rule_num" ]]; then
            echo "[删除] 规则 [$rule_num]: $ip ${comment:+（$comment）}"
            ERR=$(ufw --force delete "$rule_num" 2>&1)
            EXIT_CODE=$?
            if [[ $EXIT_CODE -ne 0 ]]; then
                echo "[错误] 删除规则 [$rule_num] 失败：$ERR"
                return 1
            fi
            UFW_STATUS=$(ufw status numbered)
        else
            break
        fi
    done
    return 0
}

# ============================================================
# 读取文件并处理
# ============================================================

# --- 第一步：先处理所有删除操作 ---
echo "=== 第一步：处理删除规则 ==="
echo ""

DEL_DONE=0
DEL_SKIP=0
DEL_FAIL=0

if [[ $DEL_COUNT -eq 0 ]]; then
    echo "无需删除的规则，跳过"
else
    mapfile -t DEL_IPS < <(grep '^del|' "$TMP_FILE")
    for line in "${DEL_IPS[@]}"; do
        ip=$(echo "$line" | cut -d'|' -f2 | tr -d '[[:space:]]')
        comment=$(echo "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [[ -z "$ip" ]] && continue

        # 只在 DENY IN 行里匹配，避免误删 ALLOW 规则
        if echo "$UFW_STATUS" | grep "DENY IN" | grep -qF "$ip"; then
            # delete_rule 会在内部同步更新全局变量 UFW_STATUS
            if delete_rule "$ip" "$comment"; then
                (( DEL_DONE++ ))
            else
                (( DEL_FAIL++ ))
            fi
        else
            echo "[跳过] 规则不存在: $ip ${comment:+（$comment）}"
            (( DEL_SKIP++ ))
        fi
    done
fi

# --- 第二步：正向追加所有添加操作 ---
echo ""
echo "=== 第二步：处理添加规则 ==="
echo ""

ADD_DONE=0
ADD_SKIP=0
ADD_FAIL=0

if [[ $ADD_COUNT -eq 0 ]]; then
    echo "无需添加的规则，跳过"
else
    mapfile -t ADD_IPS < <(grep '^add|' "$TMP_FILE")
    for (( i=0; i<${#ADD_IPS[@]}; i++ )); do
        line="${ADD_IPS[$i]}"
        ip=$(echo "$line" | cut -d'|' -f2 | tr -d '[[:space:]]')
        comment=$(echo "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [[ -z "$ip" ]] && continue

        if echo "$UFW_STATUS" | grep "DENY IN" | grep -qF "$ip"; then
            echo "[跳过] 已存在: $ip ${comment:+（$comment）}"
            (( ADD_SKIP++ ))
        else
            INSERT_POS=$(get_insert_position)
            echo "[添加] 插入位置 [$INSERT_POS]: $ip ${comment:+（$comment）}"
            ERR=$(ufw insert "$INSERT_POS" deny from "$ip" to any 2>&1)
            EXIT_CODE=$?
            if [[ $EXIT_CODE -eq 0 ]]; then
                UFW_STATUS=$(ufw status numbered)
                (( ADD_DONE++ ))
            else
                echo "[错误] 添加规则失败：$ip，原因：$ERR"
                (( ADD_FAIL++ ))
            fi
        fi
    done
fi

# ============================================================
# 输出汇总
# ============================================================

echo ""
echo "=== 执行完毕 ==="
echo "删除规则：$DEL_DONE 条 | 失败：$DEL_FAIL 条 | 跳过：$DEL_SKIP 条"
echo "新增规则：$ADD_DONE 条 | 失败：$ADD_FAIL 条 | 跳过：$ADD_SKIP 条"
echo ""
echo "=== 当前规则 ==="
ufw status numbered
echo ""
