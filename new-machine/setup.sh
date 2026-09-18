#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# New Machine Setup - Debian
#
# 推荐执行顺序：
#   1. Debian VPS / TCP 调优
#   2. SSH 密钥管理
#   3. 3x-ui 安装
#   4. Cloudflared 自动更新任务
#   5. CrowdSec + nftables 防火墙（最后执行）
#
# 菜单中的 1-5 就是实际推荐执行顺序。
# 端口管理属于 CrowdSec 安装完成后的辅助功能。
# 菜单循环运行，只有选择 0 才退出。
# ============================================================

readonly SETUP_VERSION='2026-09-18.3'
readonly TTY='/dev/tty'
readonly RAW_BASE='https://raw.githubusercontent.com/flush-of-hope/my-scripts/main'

readonly SCRIPT_TUNING='linux/tcp/Debian_VPS_Tuning.sh'
readonly SCRIPT_SSH='linux/ssh/notPasswordLogin.sh'
readonly SCRIPT_3XUI='3x-ui/install-3x-ui.sh'
readonly SCRIPT_CLOUDFLARED='cloudflare/cloudflared-auto-update-installer.sh'
readonly SCRIPT_CROWDSEC='CrowdSec/install-crowdsec-guard.sh'
readonly SCRIPT_PORT_MANAGER='CrowdSec/manage-ports.sh'

green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
reset='\033[0m'

log() {
    printf "${green}[+]${reset} %s\n" "$*"
}

warn() {
    printf "${yellow}[!]${reset} %s\n" "$*"
}

error() {
    printf "${red}[x]${reset} %s\n" "$*" >&2
}

fatal() {
    error "$*"
    exit 1
}

ask_yes_no() {
    local prompt="$1"
    local answer=''

    printf '%s [y/N]: ' "$prompt" >"$TTY"
    IFS= read -r answer <"$TTY" || return 1
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

pause_menu() {
    echo
    printf '按 Enter 返回主菜单...' >"$TTY"
    IFS= read -r _ <"$TTY" || true
}

check_environment() {
    [[ $EUID -eq 0 ]] || fatal '请使用 root 权限运行。'
    [[ -r "$TTY" && -w "$TTY" ]] || fatal '需要在交互式终端中运行。'
    [[ -f /etc/debian_version ]] || fatal '此入口脚本仅支持 Debian / Ubuntu。'

    if ! command -v curl >/dev/null 2>&1; then
        log '未检测到 curl，正在安装 curl 和 ca-certificates...'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
    fi
}

run_remote_script() {
    local path="$1"
    shift || true

    local cache_buster=''
    local url=''
    local tmp=''
    local rc=0

    cache_buster="$(date +%s%N 2>/dev/null || date +%s)"
    url="${RAW_BASE}/${path}?cb=${cache_buster}"

    tmp="$(mktemp -t new-machine-script.XXXXXX)"

    log "下载：${path}"

    if ! curl \
        --fail \
        --show-error \
        --silent \
        --location \
        --header 'Cache-Control: no-cache' \
        --header 'Pragma: no-cache' \
        --proto '=https' \
        --proto-redir '=https' \
        --connect-timeout 15 \
        --max-time 120 \
        -o "$tmp" \
        "$url"; then

        rm -f -- "$tmp"
        error "下载失败：${path}"
        return 1
    fi

    [[ -s "$tmp" ]] || {
        rm -f -- "$tmp"
        error "下载文件为空：${path}"
        return 1
    }

    echo
    log "开始执行：${path}"
    echo

    set +e
    bash "$tmp" "$@"
    rc=$?
    set -e

    rm -f -- "$tmp"

    if (( rc == 0 )); then
        log "执行完成：${path}"
    else
        error "脚本执行失败：${path}，退出码 ${rc}"
    fi

    return "$rc"
}

run_tuning() {
    echo
    warn '【第 1 步】Debian VPS / TCP 调优。'
    warn '此操作可能修改系统网络参数。'
    ask_yes_no '确认执行第 1 步吗？' || {
        warn '已取消。'
        return 0
    }

    run_remote_script "$SCRIPT_TUNING"
}

run_ssh_manager() {
    echo
    log '【第 2 步】启动 SSH Key Manager。'
    warn 'SSH 子脚本本身也是循环菜单；在 SSH 菜单中选择 0 后会返回本菜单。'
    run_remote_script "$SCRIPT_SSH"
}

run_3xui() {
    echo
    warn '【第 3 步】安装 3x-ui。'
    warn '脚本会要求输入域名、管理员账号和密码。'
    warn '默认面板端口为 8443，ACME HTTP-01 使用 80 端口。'
    ask_yes_no '确认执行第 3 步吗？' || {
        warn '已取消。'
        return 0
    }

    run_remote_script "$SCRIPT_3XUI"
}

cloudflared_installed() {
    command -v dpkg-query >/dev/null 2>&1 &&
        dpkg-query -W -f='${Status}' cloudflared 2>/dev/null | grep -Fq 'install ok installed'
}

run_cloudflared_update() {
    echo
    log '【第 4 步】配置 Cloudflared 自动更新。'

    if ! cloudflared_installed; then
        warn '当前没有检测到通过 APT 安装的 cloudflared。'
        warn '该子脚本只负责配置 cloudflared 自动更新，不负责首次安装 Tunnel。'
        return 1
    fi

    run_remote_script "$SCRIPT_CLOUDFLARED" install
}

run_crowdsec() {
    echo
    warn '【第 5 步 / 最后一步】安装 CrowdSec + nftables 防火墙。'
    warn 'CrowdSec 脚本会安装 nftables Firewall Bouncer，并接管主机入站防火墙。'
    warn '最终公网仅允许 80、443 和确认后的 SSH 端口；8443 公网访问会被阻止。'
    warn '因此这一项固定建议最后执行。'
    echo

    ask_yes_no '确认执行最后一步吗？' || {
        warn '已取消。'
        return 0
    }

    run_remote_script "$SCRIPT_CROWDSEC"
}

run_port_manager() {
    echo

    if ! command -v nft >/dev/null 2>&1 || ! nft list table inet crowdsec_guard >/dev/null 2>&1; then
        warn '未检测到 crowdsec_guard 防火墙。'
        warn '请先执行第 5 步安装 CrowdSec + nftables，再使用端口管理。'
        return 1
    fi

    log '启动 CrowdSec Guard TCP 端口管理器。'
    warn '端口管理器执行完成后选择 0，会返回本菜单。'
    run_remote_script "$SCRIPT_PORT_MANAGER"
}

show_status() {
    local ssh_port='unknown'
    local pubkey='unknown'
    local password='unknown'

    clear 2>/dev/null || true

    echo '============================================================'
    echo ' 新机当前状态'
    echo '============================================================'
    echo

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        printf '系统:              %s\n' "${PRETTY_NAME:-unknown}"
    fi

    printf '内核:              %s\n' "$(uname -r)"

    if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
        local sshd_bin
        sshd_bin="$(command -v sshd 2>/dev/null || printf '/usr/sbin/sshd')"

        ssh_port="$($sshd_bin -T 2>/dev/null | awk '$1=="port" {print $2; exit}' || true)"
        pubkey="$($sshd_bin -T 2>/dev/null | awk '$1=="pubkeyauthentication" {print $2; exit}' || true)"
        password="$($sshd_bin -T 2>/dev/null | awk '$1=="passwordauthentication" {print $2; exit}' || true)"
    fi

    printf 'SSH 端口:          %s\n' "${ssh_port:-unknown}"
    printf 'SSH 公钥认证:      %s\n' "${pubkey:-unknown}"
    printf 'SSH 密码认证:      %s\n' "${password:-unknown}"
    echo

    printf '3x-ui:             '
    if command -v x-ui >/dev/null 2>&1; then
        echo '已安装'
    else
        echo '未检测到'
    fi

    printf 'cloudflared:       '
    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared --version 2>/dev/null | head -n1 || echo '已安装'
    else
        echo '未安装'
    fi

    printf 'cloudflared timer: '
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled cloudflared-auto-update.timer >/dev/null 2>&1; then
        echo '已启用'
    else
        echo '未启用'
    fi

    printf 'CrowdSec:          '
    if command -v crowdsec >/dev/null 2>&1 || command -v cscli >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet crowdsec 2>/dev/null; then
            echo '已安装 / active'
        else
            echo '已安装 / 非 active'
        fi
    else
        echo '未安装'
    fi

    printf 'CrowdSec Guard:    '
    if command -v nft >/dev/null 2>&1 && nft list table inet crowdsec_guard >/dev/null 2>&1; then
        echo '规则已加载'
    else
        echo '未检测到'
    fi

    printf '自定义 TCP 端口:  '
    if [[ -s /etc/crowdsec-guard/custom-tcp-ports.conf ]]; then
        tr '\n' ' ' </etc/crowdsec-guard/custom-tcp-ports.conf
        echo
    else
        echo '无'
    fi

    echo
}

run_recommended_flow() {
    echo
    echo '============================================================'
    echo ' 按推荐顺序执行全部步骤'
    echo '============================================================'
    echo
    echo '将严格按照菜单 1 → 5 执行：'
    echo
    echo '  1. Debian VPS / TCP 调优'
    echo '  2. SSH 密钥管理'
    echo '  3. 3x-ui'
    echo '  4. Cloudflared 自动更新（仅 cloudflared 已安装时）'
    echo '  5. CrowdSec + nftables（最后执行）'
    echo
    warn '各子脚本自己的安全确认和交互输入仍然保留。'
    warn 'SSH Key Manager 内需要选择 0 退出后，才会继续第 3 步。'
    echo

    ask_yes_no '确认按 1 → 5 顺序开始执行吗？' || {
        warn '已取消。'
        return 0
    }

    echo
    log '[第 1 步 / 5] Debian VPS / TCP 调优'
    if ! run_remote_script "$SCRIPT_TUNING"; then
        warn '第 1 步执行失败，流程停止。'
        return 1
    fi

    echo
    log '[第 2 步 / 5] SSH Key Manager'
    if ! run_remote_script "$SCRIPT_SSH"; then
        warn '第 2 步执行失败，流程停止。'
        return 1
    fi

    echo
    log '[第 3 步 / 5] 3x-ui'
    if ! run_remote_script "$SCRIPT_3XUI"; then
        warn '第 3 步执行失败，流程停止。'
        return 1
    fi

    echo
    log '[第 4 步 / 5] Cloudflared 自动更新'
    if cloudflared_installed; then
        if ! run_remote_script "$SCRIPT_CLOUDFLARED" install; then
            warn '第 4 步执行失败。'
            if ! ask_yes_no '是否仍然继续执行最后一步 CrowdSec？'; then
                return 1
            fi
        fi
    else
        warn '未检测到 APT 安装的 cloudflared，第 4 步自动跳过。'
    fi

    echo
    log '[第 5 步 / 5] CrowdSec + nftables'
    warn '最后一步会收紧公网入站端口。'

    if ! ask_yes_no '确认执行最后一步 CrowdSec 防火墙配置吗？'; then
        warn '已跳过第 5 步 CrowdSec。'
        return 0
    fi

    run_remote_script "$SCRIPT_CROWDSEC"
}

print_menu() {
    clear 2>/dev/null || true

    echo '============================================================'
    echo ' New Machine Setup - Debian'
    echo " 版本: ${SETUP_VERSION}"
    echo '============================================================'
    echo
    echo '【推荐执行顺序：从 1 开始依次往下执行】'
    echo
    echo '1) 第 1 步：Debian VPS / TCP 调优'
    echo '2) 第 2 步：SSH 密钥管理'
    echo '3) 第 3 步：安装 3x-ui'
    echo '4) 第 4 步：安装 Cloudflared 自动更新任务'
    echo '5) 第 5 步：安装 CrowdSec + nftables 防火墙（最后）'
    echo
    echo '【辅助功能】'
    echo
    echo '6) 一键按 1 → 5 顺序执行全部步骤'
    echo '7) CrowdSec Guard 端口管理'
    echo '8) 查看当前状态'
    echo '0) 退出'
    echo
}

main_loop() {
    local choice=''

    while true; do
        print_menu
        printf '请选择 [0-8]: ' >"$TTY"
        IFS= read -r choice <"$TTY" || choice='0'

        case "$choice" in
            1)
                run_tuning || true
                pause_menu
                ;;
            2)
                run_ssh_manager || true
                pause_menu
                ;;
            3)
                run_3xui || true
                pause_menu
                ;;
            4)
                run_cloudflared_update || true
                pause_menu
                ;;
            5)
                run_crowdsec || true
                pause_menu
                ;;
            6)
                run_recommended_flow || true
                pause_menu
                ;;
            7)
                run_port_manager || true
                pause_menu
                ;;
            8)
                show_status || true
                pause_menu
                ;;
            0)
                echo
                log '已退出 New Machine Setup。'
                exit 0
                ;;
            *)
                warn '无效选择，请输入 0-8。'
                sleep 1
                ;;
        esac
    done
}

check_environment
main_loop
