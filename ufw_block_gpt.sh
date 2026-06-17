#!/usr/bin/env bash

# ==============================================================================
# 脚本名称：ufw-sync-github-block.sh
# 脚本用途：
#   从 GitHub 上读取 IP 规则文本，并同步到 Debian 12 的 UFW 防火墙。
#
# 规则文本格式：
#   add | 1.2.3.0/24 | censys扫描
#   del | 9.9.9.0/24 | 删除旧规则
#
# 处理逻辑：
#   1. 下载 GitHub 上的 txt 规则文件。
#   2. 解析 add 和 del 规则。
#   3. 先删除 del 规则中的 IP 段。
#   4. 再删除 add 规则中对应的旧 UFW deny 规则。
#   5. 最后按照 txt 文件中 add 规则的顺序重新添加 deny 规则。
#   6. 这样可以保证脚本管理的 deny 规则顺序与 txt 文件中的 add 顺序一致。
# ==============================================================================

set -Eeuo pipefail

# ==============================================================================
# 一、基础配置
# ==============================================================================

# GitHub raw txt 规则文件地址，请修改为你自己的地址。
RULE_URL="${RULE_URL:-https://raw.githubusercontent.com/Eveaz/scripts/main/ufw_block_ips.txt}"

# UFW 规则备注前缀，用于标记这些规则由本脚本管理。
COMMENT_PREFIX="${COMMENT_PREFIX:-github-block}"

# 是否只测试不真正执行。
# 0 表示真实执行。
# 1 表示只打印将要执行的命令，不修改 UFW。
DRY_RUN="${DRY_RUN:-0}"

# 临时文件路径，用于保存下载下来的规则文本。
TMP_RULE_FILE="$(mktemp)"

# 锁文件路径，用于防止脚本被重复同时运行。
LOCK_FILE="/run/ufw-sync-github-block.lock"

# ==============================================================================
# 二、退出时清理临时文件
# ==============================================================================

# 脚本退出时自动删除临时规则文件。
trap 'rm -f "$TMP_RULE_FILE"' EXIT

# ==============================================================================
# 三、基础环境检查
# ==============================================================================

# 检查当前用户是否为 root。
# UFW 修改防火墙规则需要 root 权限。
if [[ "${EUID}" -ne 0 ]]; then
    echo "错误：请使用 root 用户运行此脚本。"
    exit 1
fi

# 检查 ufw、curl、python3 是否存在。
# ufw 用于管理防火墙。
# curl 用于下载 GitHub 规则文件。
# python3 用于校验 IP 或 CIDR 网段是否合法。
for cmd in ufw curl python3 flock; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "错误：系统缺少必要命令：$cmd"
        exit 1
    fi
done

# ==============================================================================
# 四、加锁，防止脚本重复运行
# ==============================================================================

# 打开锁文件。
exec 9>"$LOCK_FILE"

# 尝试获取锁。
# 如果已经有另一个脚本实例正在运行，则直接退出。
if ! flock -n 9; then
    echo "提示：已有一个同步任务正在运行，本次退出。"
    exit 1
fi

# ==============================================================================
# 五、通用函数
# ==============================================================================

# ------------------------------------------------------------------------------
# 函数：去除字符串首尾空白字符
# 用途：
#   清理规则文本中的字段，例如去掉字段前后的空格。
# ------------------------------------------------------------------------------
trim_string() {
    local value="$1"

    # 去掉 Windows 文本中可能存在的回车符。
    value="${value%$'\r'}"

    # 去掉字符串开头的空白字符。
    value="${value#"${value%%[![:space:]]*}"}"

    # 去掉字符串结尾的空白字符。
    value="${value%"${value##*[![:space:]]}"}"

    printf '%s' "$value"
}

# ------------------------------------------------------------------------------
# 函数：校验 IP 或 IP 段是否合法
# 用途：
#   支持 IPv4、IPv4 CIDR、IPv6、IPv6 CIDR。
# 示例：
#   1.2.3.4
#   1.2.3.0/24
#   2001:db8::1
#   2001:db8::/32
# ------------------------------------------------------------------------------
validate_ip_or_cidr() {
    local ip_value="$1"

    python3 - "$ip_value" <<'PY'
import ipaddress
import sys

value = sys.argv[1]

try:
    ipaddress.ip_network(value, strict=False)
except ValueError:
    sys.exit(1)
PY
}

# ------------------------------------------------------------------------------
# 函数：执行命令
# 用途：
#   如果 DRY_RUN=1，则只打印命令，不真正执行。
#   如果 DRY_RUN=0，则真实执行命令。
# ------------------------------------------------------------------------------
run_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '[测试模式] '
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# ------------------------------------------------------------------------------
# 函数：删除某个 IP 段对应的 UFW deny 规则
# 用途：
#   删除形如 ufw deny from IP段 的规则。
#   使用循环删除，是为了处理可能存在重复规则的情况。
# ------------------------------------------------------------------------------
delete_ufw_deny_rule() {
    local ip_cidr="$1"
    local deleted_count=0

    # 如果是测试模式，则只显示将要删除的规则。
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[测试模式] 将循环删除直到不存在：ufw --force delete deny from $ip_cidr"
        return 0
    fi

    # 循环删除同一个 IP 段对应的 deny 规则，直到删除失败为止。
    while ufw --force delete deny from "$ip_cidr" >/dev/null 2>&1; do
        ((deleted_count+=1))
    done

    # 输出删除结果。
    if (( deleted_count > 0 )); then
        echo "已删除 deny from $ip_cidr，共 $deleted_count 条。"
    else
        echo "未发现 deny from $ip_cidr，跳过删除。"
    fi
}

# ------------------------------------------------------------------------------
# 函数：添加某个 IP 段为 UFW deny 规则
# 用途：
#   添加形如 ufw deny from IP段 comment 备注 的规则。
# ------------------------------------------------------------------------------
add_ufw_deny_rule() {
    local ip_cidr="$1"
    local remark="$2"
    local comment_text=""

    # 生成 UFW 备注内容。
    if [[ -n "$remark" ]]; then
        comment_text="$COMMENT_PREFIX: $remark"
    else
        comment_text="$COMMENT_PREFIX"
    fi

    # 输出当前正在添加的规则。
    echo "添加 deny from $ip_cidr，备注：$comment_text"

    # 添加 UFW deny 规则。
    run_cmd ufw deny from "$ip_cidr" comment "$comment_text" >/dev/null
}

# ==============================================================================
# 六、下载 GitHub 规则文件
# ==============================================================================

echo "开始下载规则文件：$RULE_URL"

# 使用 curl 下载规则文件。
if ! curl -fsSL "$RULE_URL" -o "$TMP_RULE_FILE"; then
    echo "错误：下载规则文件失败，请检查 RULE_URL 是否正确。"
    exit 1
fi

echo "规则文件下载完成。"
echo

# ==============================================================================
# 七、解析规则文件
# ==============================================================================

# 用数组保存 add 规则中的 IP 段。
declare -a ADD_IP_LIST=()

# 用数组保存 add 规则中的备注。
declare -a ADD_REMARK_LIST=()

# 用数组保存 del 规则中的 IP 段。
declare -a DEL_IP_LIST=()

# 用数组保存 del 规则中的备注。
declare -a DEL_REMARK_LIST=()

# 用关联数组记录已出现过的 add IP 段，用于跳过重复项。
declare -A SEEN_ADD_IP=()

# 用关联数组记录已出现过的 del IP 段，用于跳过重复项。
declare -A SEEN_DEL_IP=()

# 记录当前读取到第几行，用于报错提示。
line_number=0

# 逐行读取规则文件。
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    # 行号加一。
    ((line_number+=1))

    # 清理整行首尾空白字符。
    line="$(trim_string "$raw_line")"

    # 跳过空行。
    if [[ -z "$line" ]]; then
        continue
    fi

    # 跳过以 # 开头的注释行。
    if [[ "$line" =~ ^# ]]; then
        continue
    fi

    # 使用 | 分隔规则。
    # 标准格式为：
    #   add | IP段 | 备注
    #   del | IP段 | 备注
    IFS='|' read -r action_field ip_field remark_field extra_field <<< "$line"

    # 如果存在第四段，说明格式中包含多余的 |，这里直接报错。
    if [[ -n "${extra_field:-}" ]]; then
        echo "错误：第 $line_number 行格式不正确，包含多余的 | ：$line"
        exit 1
    fi

    # 清理动作字段。
    action="$(trim_string "${action_field:-}")"

    # 清理 IP 段字段。
    ip_cidr="$(trim_string "${ip_field:-}")"

    # 清理备注字段。
    remark="$(trim_string "${remark_field:-}")"

    # 将动作转换为小写，允许 ADD、Add、add 等写法。
    action="${action,,}"

    # 检查动作是否为 add 或 del。
    if [[ "$action" != "add" && "$action" != "del" ]]; then
        echo "错误：第 $line_number 行动作只能是 add 或 del：$line"
        exit 1
    fi

    # 检查 IP 段字段是否为空。
    if [[ -z "$ip_cidr" ]]; then
        echo "错误：第 $line_number 行缺少 IP 或 IP 段：$line"
        exit 1
    fi

    # 校验 IP 或 IP 段是否合法。
    if ! validate_ip_or_cidr "$ip_cidr"; then
        echo "错误：第 $line_number 行 IP 或 IP 段不合法：$ip_cidr"
        exit 1
    fi

    # 处理 add 规则。
    if [[ "$action" == "add" ]]; then
        # 如果同一个 add IP 段重复出现，则保留第一次出现的位置，忽略后续重复项。
        if [[ -n "${SEEN_ADD_IP[$ip_cidr]+x}" ]]; then
            echo "警告：第 $line_number 行 add IP 段重复，已忽略：$ip_cidr"
            continue
        fi

        # 记录该 add IP 段已经出现。
        SEEN_ADD_IP["$ip_cidr"]=1

        # 保存 add IP 段。
        ADD_IP_LIST+=("$ip_cidr")

        # 保存 add 备注。
        ADD_REMARK_LIST+=("$remark")
    fi

    # 处理 del 规则。
    if [[ "$action" == "del" ]]; then
        # 如果同一个 del IP 段重复出现，则保留第一次出现的位置，忽略后续重复项。
        if [[ -n "${SEEN_DEL_IP[$ip_cidr]+x}" ]]; then
            echo "警告：第 $line_number 行 del IP 段重复，已忽略：$ip_cidr"
            continue
        fi

        # 记录该 del IP 段已经出现。
        SEEN_DEL_IP["$ip_cidr"]=1

        # 保存 del IP 段。
        DEL_IP_LIST+=("$ip_cidr")

        # 保存 del 备注。
        DEL_REMARK_LIST+=("$remark")
    fi
done < "$TMP_RULE_FILE"

# 输出解析结果。
echo "规则解析完成："
echo "add 规则数量：${#ADD_IP_LIST[@]}"
echo "del 规则数量：${#DEL_IP_LIST[@]}"
echo

# ==============================================================================
# 八、显示同步前的 UFW 状态
# ==============================================================================

echo "同步前的 UFW 状态："
LC_ALL=C ufw status numbered | sed 's/^/  /'
echo

# ==============================================================================
# 九、先处理 del 规则
# ==============================================================================

echo "开始处理 del 规则。"

# 如果 del 规则数量为 0，则提示无需处理。
if (( ${#DEL_IP_LIST[@]} == 0 )); then
    echo "没有 del 规则需要处理。"
else
    # 按规则文件中的 del 顺序逐条删除。
    for i in "${!DEL_IP_LIST[@]}"; do
        del_ip="${DEL_IP_LIST[$i]}"
        del_remark="${DEL_REMARK_LIST[$i]}"

        echo "处理 del：$del_ip，备注：$del_remark"
        delete_ufw_deny_rule "$del_ip"
    done
fi

echo

# ==============================================================================
# 十、删除 add 规则中对应的旧 UFW deny 规则
# ==============================================================================

echo "开始删除 add 规则中对应的旧 UFW deny 规则。"
echo "说明：为了保证最终顺序与 txt 文件中的 add 顺序一致，这里会先删除旧规则再重新添加。"

# 如果 add 规则数量为 0，则提示无需处理。
if (( ${#ADD_IP_LIST[@]} == 0 )); then
    echo "没有 add 规则需要处理。"
else
    # 删除所有 add IP 段对应的旧 deny 规则。
    for ip_cidr in "${ADD_IP_LIST[@]}"; do
        delete_ufw_deny_rule "$ip_cidr"
    done
fi

echo

# ==============================================================================
# 十一、按照 txt 文件中的 add 顺序重新添加 UFW deny 规则
# ==============================================================================

echo "开始按照 txt 文件中的 add 顺序重新添加 UFW deny 规则。"

# 如果 add 规则数量为 0，则提示无需添加。
if (( ${#ADD_IP_LIST[@]} == 0 )); then
    echo "没有 add 规则需要添加。"
else
    # 按数组顺序添加 deny 规则。
    # 这个顺序就是 txt 文件中 add 规则出现的顺序。
    for i in "${!ADD_IP_LIST[@]}"; do
        add_ip="${ADD_IP_LIST[$i]}"
        add_remark="${ADD_REMARK_LIST[$i]}"

        add_ufw_deny_rule "$add_ip" "$add_remark"
    done
fi

echo

# ==============================================================================
# 十二、重新加载 UFW
# ==============================================================================

echo "重新加载 UFW。"

# 重新加载 UFW，使规则状态刷新。
run_cmd ufw reload >/dev/null

echo

# ==============================================================================
# 十三、显示同步后的 UFW 状态
# ==============================================================================

echo "同步完成。"
echo "同步后的 UFW 状态："
LC_ALL=C ufw status numbered
