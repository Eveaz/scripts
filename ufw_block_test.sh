#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# UFW 批量屏蔽 IP 段脚本
# 数据源格式：IP|备注
# 执行方式：
# bash <(curl -fsSL https://raw.githubusercontent.com/Eveaz/scripts/main/ufw_block.sh)
# ============================================================

TXT_URL="https://raw.githubusercontent.com/Eveaz/scripts/main/ufw_block_ips.txt"

TMP_DIR=""
TMP_FILE=""

# -----------------------------
# 颜色与日志
# -----------------------------
if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_BLUE="\033[34m"
    C_CYAN="\033[36m"
    C_BOLD="\033[1m"
else
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
    C_BOLD=""
fi

print_line() {
    printf '%b\n' "${C_CYAN}────────────────────────────────────────────────────────────${C_RESET}"
}

log_info() {
    printf '%b\n' "${C_BLUE}[信息]${C_RESET} $*"
}

log_ok() {
    printf '%b\n' "${C_GREEN}[完成]${C_RESET} $*"
}

log_warn() {
    printf '%b\n' "${C_YELLOW}[警告]${C_RESET} $*"
}

log_error() {
    printf '%b\n' "${C_RED}[错误]${C_RESET} $*" >&2
}

title() {
    print_line
    printf '%b\n' "${C_BOLD}$*${C_RESET}"
    print_line
}

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
        log_ok "已删除临时目录：$TMP_DIR"
    fi
}

trap cleanup EXIT

trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

ufw_cmd() {
    LANG=C ufw "$@"
}

# -----------------------------
# 基础检查
# -----------------------------
check_env() {
    title "UFW 批量屏蔽 IP 段脚本"

    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "请使用 root 用户执行此脚本。"
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "未找到 curl，请先安装：apt update && apt install -y curl"
        exit 1
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        log_error "未找到 ufw，请先安装：apt update && apt install -y ufw"
        exit 1
    fi

    log_ok "运行用户：root"
    log_ok "curl：已安装"
    log_ok "ufw：已安装"
}

# -----------------------------
# 下载 TXT 文件
# -----------------------------
download_txt() {
    title "下载远程 IP 规则文件"

    TMP_DIR="$(mktemp -d /tmp/ufw_block.XXXXXX)"
    TMP_FILE="$TMP_DIR/ufw_block_ips.txt"

    log_info "临时目录：$TMP_DIR"
    log_info "规则地址：$TXT_URL"

    if curl -fsSL "$TXT_URL" -o "$TMP_FILE"; then
        log_ok "规则文件下载成功：$TMP_FILE"
    else
        log_error "规则文件下载失败。"
        exit 1
    fi
}

# -----------------------------
# 解析 TXT 文件
# -----------------------------
declare -a WANT_IPS=()
declare -a WANT_COMMENTS=()

parse_txt() {
    title "解析 IP 规则"

    local line
    local line_no=0
    local ip
    local comment

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))

        # 去除 Windows 换行符
        line="${line//$'\r'/}"

        # 去除首尾空白
        line="$(trim "$line")"

        # 跳过空行和注释行
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        if [[ "$line" == *"|"* ]]; then
            ip="$(trim "${line%%|*}")"
            comment="$(trim "${line#*|}")"
        else
            ip="$(trim "$line")"
            comment=""
        fi

        if [[ -z "$ip" ]]; then
            log_error "第 $line_no 行 IP 为空，请检查规则文件。"
            exit 1
        fi

        WANT_IPS+=("$ip")
        WANT_COMMENTS+=("$comment")
    done < "$TMP_FILE"

    if [[ "${#WANT_IPS[@]}" -eq 0 ]]; then
        log_error "规则文件中没有可用的 IP 规则。"
        exit 1
    fi

    log_ok "解析完成，共 ${#WANT_IPS[@]} 条 IP 规则。"
}

# -----------------------------
# 检查重复 IP
# -----------------------------
check_duplicates() {
    title "检查重复 IP"

    local seen_file="$TMP_DIR/seen.txt"
    : > "$seen_file"

    local ip
    local duplicate_found=0

    for ip in "${WANT_IPS[@]}"; do
        if grep -Fxq "$ip" "$seen_file"; then
            log_error "发现重复 IP 规则：$ip"
            duplicate_found=1
        else
            printf '%s\n' "$ip" >> "$seen_file"
        fi
    done

    if [[ "$duplicate_found" -eq 1 ]]; then
        log_error "请先清理 TXT 文件中的重复 IP 后再执行。"
        exit 1
    fi

    log_ok "未发现重复 IP。"
}

# -----------------------------
# 使用 ufw dry-run 预检查规则合法性
# -----------------------------
validate_rules() {
    title "预检查 UFW 规则合法性"

    local total="${#WANT_IPS[@]}"
    local i
    local ip

    for ((i = 0; i < total; i++)); do
        ip="${WANT_IPS[$i]}"

        printf '  [%0*d/%0*d] 检查 %-40s' \
            "${#total}" "$((i + 1))" "${#total}" "$total" "$ip"

        if ufw_cmd --dry-run deny from "$ip" >/dev/null 2>&1; then
            printf '%b\n' " ${C_GREEN}OK${C_RESET}"
        else
            printf '%b\n' " ${C_RED}失败${C_RESET}"
            log_error "UFW 无法识别该 IP/IP段：$ip"
            exit 1
        fi
    done

    log_ok "所有 IP 规则预检查通过。"
}

# -----------------------------
# 获取当前 UFW 中的 DENY IN 规则
# -----------------------------
declare -a EXIST_RULE_NUMS=()
declare -a EXIST_IPS=()

load_existing_deny_rules() {
    EXIST_RULE_NUMS=()
    EXIST_IPS=()

    local line
    local num
    local src

    while IFS= read -r line; do
        # 示例：
        # [ 1] Anywhere                   DENY IN     1.2.3.4
        # [12] Anywhere                   DENY IN     1.2.3.0/24
        if [[ "$line" =~ ^\[\ *([0-9]+)\].*[[:space:]]DENY[[:space:]]+IN[[:space:]]+(.+)$ ]]; then
            num="${BASH_REMATCH[1]}"
            src="${BASH_REMATCH[2]}"

            # 如果 ufw 显示 comment，这里去掉 comment 部分
            src="${src%%#*}"
            src="$(trim "$src")"

            EXIST_RULE_NUMS+=("$num")
            EXIST_IPS+=("$src")
        fi
    done < <(ufw_cmd status numbered)
}

# -----------------------------
# 对比目标规则和当前规则
# -----------------------------
rules_are_same() {
    local want_count="${#WANT_IPS[@]}"
    local exist_count="${#EXIST_IPS[@]}"
    local i

    if [[ "$want_count" -ne "$exist_count" ]]; then
        return 1
    fi

    for ((i = 0; i < want_count; i++)); do
        if [[ "${WANT_IPS[$i]}" != "${EXIST_IPS[$i]}" ]]; then
            return 1
        fi
    done

    return 0
}

show_compare_result() {
    title "对比当前 UFW DENY IN 规则"

    log_info "TXT 规则数量：${#WANT_IPS[@]}"
    log_info "UFW 现有 DENY IN 规则数量：${#EXIST_IPS[@]}"

    if rules_are_same; then
        log_ok "当前 UFW DENY IN 规则数量和顺序与 TXT 完全一致。"
        return 0
    else
        log_warn "当前 UFW DENY IN 规则数量或顺序与 TXT 不一致，需要重新同步。"
        return 1
    fi
}

# -----------------------------
# 删除现有 DENY IN 规则
# -----------------------------
delete_existing_deny_rules() {
    title "删除现有 UFW DENY IN 规则"

    local total="${#EXIST_RULE_NUMS[@]}"
    local idx
    local progress=0
    local num
    local ip

    if [[ "$total" -eq 0 ]]; then
        log_info "当前没有需要删除的 DENY IN 规则。"
        return 0
    fi

    log_warn "将删除 $total 条现有 DENY IN 规则。"

    # 删除 numbered 规则必须从大到小删除，避免编号变化
    for ((idx = total - 1; idx >= 0; idx--)); do
        progress=$((progress + 1))
        num="${EXIST_RULE_NUMS[$idx]}"
        ip="${EXIST_IPS[$idx]}"

        printf '  [%0*d/%0*d] 删除规则 #%-4s %-40s' \
            "${#total}" "$progress" "${#total}" "$total" "$num" "$ip"

        if ufw_cmd --force delete "$num" >/dev/null 2>&1; then
            printf '%b\n' " ${C_GREEN}OK${C_RESET}"
        else
            printf '%b\n' " ${C_RED}失败${C_RESET}"
            log_error "删除 UFW 规则失败，规则编号：$num，IP：$ip"
            exit 1
        fi
    done

    log_ok "现有 DENY IN 规则删除完成。"
}

# -----------------------------
# 添加新的 deny 规则
# -----------------------------
add_new_deny_rules() {
    title "按 TXT 顺序添加新的 UFW deny 规则"

    local total="${#WANT_IPS[@]}"
    local i
    local pos
    local ip
    local comment
    local ufw_comment

    for ((i = 0; i < total; i++)); do
        pos=$((i + 1))
        ip="${WANT_IPS[$i]}"
        comment="${WANT_COMMENTS[$i]}"

        if [[ -n "$comment" ]]; then
            ufw_comment="ufw_block: $comment"
        else
            ufw_comment="ufw_block"
        fi

        # ufw comment 长度不宜过长
        ufw_comment="${ufw_comment:0:240}"

        printf '  [%0*d/%0*d] 添加 deny from %-40s' \
            "${#total}" "$pos" "${#total}" "$total" "$ip"

        # 使用 insert 保证最终规则顺序与 TXT 顺序一致
        if ufw_cmd --force insert "$pos" deny from "$ip" comment "$ufw_comment" >/dev/null 2>&1; then
            printf '%b\n' " ${C_GREEN}OK${C_RESET}"
        else
            printf '%b\n' " ${C_RED}失败${C_RESET}"
            log_error "添加 UFW deny 规则失败：$ip"
            exit 1
        fi
    done

    log_ok "新的 deny 规则添加完成。"
}

# -----------------------------
# 展示最终 UFW 规则
# -----------------------------
show_final_status() {
    title "当前 UFW 所有规则"

    ufw_cmd status numbered

    print_line
    log_ok "同步完成。"
}

main() {
    check_env
    download_txt
    parse_txt
    check_duplicates
    validate_rules

    load_existing_deny_rules

    if show_compare_result; then
        log_info "无需删除或新增 UFW 规则，跳过同步。"
        show_final_status
        exit 0
    fi

    delete_existing_deny_rules
    add_new_deny_rules
    show_final_status
}

main "$@"
