#!/bin/bash

# ============================================================
# 配置区域
# ============================================================

IP_FILE_URL="https://raw.githubusercontent.com/Eveaz/scripts/main/ufw_block_ips.txt"
TMP_FILE="/tmp/ufw_block_ips.txt"

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

IP_COUNT=$(grep -v '^[[:space:]]*$\|^[[:space:]]*#' "$TMP_FILE" | wc -l | tr -d ' ')
echo "下载成功：共 $IP_COUNT 条规则"
echo ""

# ============================================================
# 读取 txt，提取期望的 IP 顺序
# ============================================================

mapfile -t ADD_IPS < <(grep -v '^[[:space:]]*$\|^[[:space:]]*#' "$TMP_FILE")

EXPECTED_ORDER=()
for line in "${ADD_IPS[@]}"; do
    ip=$(echo "$line" | cut -d'|' -f1 | tr -d '[[:space:]]')
    [[ -n "$ip" ]] && EXPECTED_ORDER+=("$ip")
done

# ============================================================
# 提取当前 ufw 里 DENY IN 的 IP 顺序（精确匹配 CIDR 格式）
# ============================================================

mapfile -t CURRENT_ORDER < <(echo "$UFW_STATUS" | grep "DENY IN" | grep -oP '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}')

# ============================================================
# 对比顺序是否一致
# ============================================================

NEED_RESYNC=0

if [[ ${#EXPECTED_ORDER[@]} -ne ${#CURRENT_ORDER[@]} ]]; then
    NEED_RESYNC=1
else
    for (( i=0; i<${#EXPECTED_ORDER[@]}; i++ )); do
        if [[ "${EXPECTED_ORDER[$i]}" != "${CURRENT_ORDER[$i]}" ]]; then
            NEED_RESYNC=1
            break
        fi
    done
fi

# ============================================================
# 顺序一致：跳过
# ============================================================

if [[ $NEED_RESYNC -eq 0 ]]; then
    echo "=== 规则顺序已与 txt 文件完全一致，无需同步 ==="
    echo ""
    echo "=== 当前规则 ==="
    ufw status numbered
    echo ""
    exit 0
fi

# ============================================================
# 顺序不一致：清空所有 DENY IN 规则，按 txt 顺序重建
# ============================================================

echo "=== 检测到规则变动，开始重建 DENY IN 规则 ==="
echo ""

# --- 第一步：清除所有现有 DENY IN 规则 ---
echo "--- 第一步：清除现有 DENY IN 规则 ---"
echo ""

CLEAR_DONE=0
CLEAR_FAIL=0
CLEAR_TOTAL=${#CURRENT_ORDER[@]}

while true; do
    UFW_STATUS=$(ufw status numbered)
    rule_num=$(echo "$UFW_STATUS" | grep "DENY IN" | grep -oP '(?<=\[)\s*\d+(?=\])' | tr -d ' ' | head -1)
    [[ -z "$rule_num" ]] && break

    rule_ip=$(echo "$UFW_STATUS" | grep "DENY IN" | grep -oP '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}' | head -1)
    (( CLEAR_DONE++ ))
    echo "[清除 $CLEAR_DONE/$CLEAR_TOTAL] $rule_ip"

    ERR=$(ufw --force delete "$rule_num" 2>&1)
    EXIT_CODE=$?
    if [[ $EXIT_CODE -ne 0 ]]; then
        echo "[错误] 清除失败：$ERR"
        echo "清除阶段出错，中止操作，请手动检查 ufw 规则"
        (( CLEAR_FAIL++ ))
        exit 1
    fi
done

# --- 第二步：按 txt 顺序重新插入（从后往前 insert 1）---
echo ""
echo "--- 第二步：按 txt 顺序重新插入 ---"
echo ""

ADD_DONE=0
ADD_FAIL=0
ADD_TOTAL=${#ADD_IPS[@]}

for (( i=ADD_TOTAL-1; i>=0; i-- )); do
    line="${ADD_IPS[$i]}"
    ip=$(echo "$line" | cut -d'|' -f1 | tr -d '[[:space:]]')
    comment=$(echo "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    [[ -z "$ip" ]] && continue

    DISPLAY_NUM=$(( ADD_TOTAL - i ))
    echo "[添加 $DISPLAY_NUM/$ADD_TOTAL] $ip ${comment:+（$comment）}"

    ERR=$(ufw insert 1 deny from "$ip" to any 2>&1)
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 0 ]]; then
        (( ADD_DONE++ ))
    else
        echo "[错误] 添加失败：$ip，原因：$ERR"
        (( ADD_FAIL++ ))
    fi
done

# ============================================================
# 输出汇总
# ============================================================

echo ""
echo "=== 执行完毕 ==="
echo "清除规则：$CLEAR_DONE 条 | 失败：$CLEAR_FAIL 条"
echo "新增规则：$ADD_DONE 条 | 失败：$ADD_FAIL 条"
echo ""
echo "=== 当前规则 ==="
ufw status numbered
echo ""