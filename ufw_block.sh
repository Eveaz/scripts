#!/bin/bash

# ============================================================
# 配置区域
# ============================================================

IP_FILE_URL="https://raw.githubusercontent.com/Eveaz/scripts/main/block_ips.txt"
TMP_FILE="/tmp/block_ips.txt"

# ============================================================
# 检查权限
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 root 权限运行（sudo ./ufw_block.sh）"
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
elif command -v wget &> /dev/null; then
    wget -q "$IP_FILE_URL" -O "$TMP_FILE"
else
    echo "错误：系统未安装 curl 或 wget"
    exit 1
fi

if [[ $? -ne 0 || ! -s "$TMP_FILE" ]]; then
    echo "错误：下载失败，请检查 URL 或网络连接"
    exit 1
fi

ADD_COUNT=$(grep -c '^add|' "$TMP_FILE" 2>/dev/null || echo 0)
DEL_COUNT=$(grep -c '^del|' "$TMP_FILE" 2>/dev/null || echo 0)
echo "下载成功：待添加 $ADD_COUNT 条，待删除 $DEL_COUNT 条"
echo ""

# ============================================================
# 函数：删除指定 IP 的屏蔽规则
# ============================================================

delete_rule() {
    local ip="$1"
    local comment="$2"

    # 检查规则是否存在
    if ! ufw status | grep -q "$ip"; then
        echo "[跳过] 规则不存在: $ip ${comment:+（$comment）}"
        return
    fi

    # 循环删除（可能存在多条重复规则）
    while ufw status numbered | grep -q "$ip"; do
        # 获取该 IP 规则的编号（取第一个）
        rule_num=$(ufw status numbered | grep "$ip" | grep -oP '(?<=\[)\d+(?=\])' | head -1)
        if [[ -n "$rule_num" ]]; then
            echo "[删除] 规则 [$rule_num]: $ip ${comment:+（$comment）}"
            yes | ufw delete "$rule_num"
        else
            break
        fi
    done
}

# ============================================================
# 读取文件并处理
# ============================================================

mapfile -t LINES < <(grep -v '^\s*$\|^\s*#' "$TMP_FILE")

# --- 第一步：先处理所有删除操作 ---
echo "=== 第一步：处理删除规则 ==="
echo ""

DEL_DONE=0
DEL_SKIP=0

for line in "${LINES[@]}"; do
    status=$(echo "$line" | cut -d'|' -f1 | tr -d ' ')
    ip=$(echo "$line" | cut -d'|' -f2 | tr -d ' ')
    comment=$(echo "$line" | cut -d'|' -f3)

    [[ "$status" != "del" ]] && continue
    [[ -z "$ip" ]] && continue

    if ufw status | grep -q "$ip"; then
        delete_rule "$ip" "$comment"
        (( DEL_DONE++ ))
    else
        echo "[跳过] 规则不存在: $ip ${comment:+（$comment）}"
        (( DEL_SKIP++ ))
    fi
done

[[ $DEL_COUNT -eq 0 ]] && echo "无需删除的规则"

# --- 第二步：反向插入所有添加操作 ---
echo ""
echo "=== 第二步：处理添加规则 ==="
echo ""

ADD_DONE=0
ADD_SKIP=0

# 过滤出 add 条目
mapfile -t ADD_IPS < <(grep '^add|' "$TMP_FILE")

for (( i=${#ADD_IPS[@]}-1; i>=0; i-- )); do
    line="${ADD_IPS[$i]}"
    ip=$(echo "$line" | cut -d'|' -f2 | tr -d ' ')
    comment=$(echo "$line" | cut -d'|' -f3)

    [[ -z "$ip" ]] && continue

    if ufw status | grep -q "$ip"; then
        echo "[跳过] 已存在: $ip ${comment:+（$comment）}"
        (( ADD_SKIP++ ))
    else
        echo "[添加] $ip ${comment:+（$comment）}"
        ufw insert 1 deny from "$ip" to any
        (( ADD_DONE++ ))
    fi
done

[[ ${#ADD_IPS[@]} -eq 0 ]] && echo "无需添加的规则"

# ============================================================
# 清理临时文件
# ============================================================

rm -f "$TMP_FILE"

# ============================================================
# 输出汇总
# ============================================================

echo ""
echo "=== 执行完毕 ==="
echo "删除规则：$DEL_DONE 条 | 跳过：$DEL_SKIP 条"
echo "新增规则：$ADD_DONE 条 | 跳过：$ADD_SKIP 条"
echo ""
echo "=== 当前规则 ==="
ufw status numbered
