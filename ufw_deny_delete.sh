#!/bin/bash

# ============================================================
# 检查权限
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 root 权限运行"
    exit 1
fi

# ============================================================
# 获取所有 DENY IN 规则
# ============================================================

UFW_STATUS=$(ufw status numbered)

DENY_COUNT=$(echo "$UFW_STATUS" | grep "DENY IN" | wc -l)

if [[ $DENY_COUNT -eq 0 ]]; then
    echo "当前没有任何 DENY IN 规则，无需操作"
    exit 0
fi

echo "=== 当前 DENY IN 规则（共 $DENY_COUNT 条）==="
echo "$UFW_STATUS" | grep "DENY IN"
echo ""

# ============================================================
# 二次确认（强制从终端读取，兼容 curl | bash 执行方式）
# ============================================================

read -rp "确认删除以上全部 $DENY_COUNT 条 DENY IN 规则？(yes/no): " CONFIRM < /dev/tty
if [[ "$CONFIRM" != "yes" ]]; then
    echo "已取消操作"
    exit 0
fi

echo ""
echo "=== 开始删除 DENY IN 规则 ==="
echo ""

# ============================================================
# 循环删除（--force 跳过确认，不依赖 stdin）
# ============================================================

DONE=0
FAIL=0

while true; do
    UFW_STATUS=$(ufw status numbered)
    rule_num=$(echo "$UFW_STATUS" | grep "DENY IN" | grep -oP '(?<=\[)\d+(?=\])' | head -1)

    [[ -z "$rule_num" ]] && break

    rule_info=$(echo "$UFW_STATUS" | grep "DENY IN" | head -1 | sed 's/^[ \t]*//')
    echo "[删除] $rule_info"

    if ufw --force delete "$rule_num" > /dev/null 2>&1; then
        (( DONE++ ))
    else
        echo "[错误] 删除规则 [$rule_num] 失败"
        (( FAIL++ ))
        break
    fi
done

# ============================================================
# 输出汇总
# ============================================================

echo ""
echo "=== 执行完毕 ==="
echo "成功删除：$DONE 条 | 失败：$FAIL 条"
echo ""
echo "=== 当前规则 ==="
ufw status numbered
