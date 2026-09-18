#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# New Machine Setup - Debian
#
# 统一调用仓库中的新机配置脚本：
#   1. Debian VPS / TCP 调优
#   2. SSH 密钥管理
#   3. 3x-ui 安装
#   4. Cloudflared 自动更新任务
#   5. CrowdSec + nftables 防火墙
#
# 菜单循环运行，只有选择 0 才退出。
# ============================================================

readonly TTY='/dev/tty'
readonly RAW_BASE='https://raw.githubusercontent.com/flush-of-hope/my-scripts/main'

readonly SCRIPT_TUNING='linux/tcp/Debian_VPS_Tuning.sh'
readonly SCRIPT_SSH='linux/ssh/notPasswordLogin.sh'
readonly SCRIPT_3XUI='3x-ui/install-3x-ui.sh'
readonly SCRIPT_CLOUDFLARED='cloudflare/cloudflared-auto-update-installer.sh'
readonly SCRIPT_CROWDSEC='CrowdSec/install-crowdsec-guard.sh'

green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
cyan='\033[1;36m'
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

    local url="${RAW_BASE}/${path}"
    local tmp=''
    local rc=0

    tmp="$(mktemp -t new-machine-script.XXXXXX)"

    log "下载：${path}"

    if ! curl \
        --fail \
        --show-error \
        --silent \
        --location \
        --proto '=https' \
        --proto-redir '=https' \
        --connect-timeout 15 \
        --max-time 120 \
        -o "$tmp" \
        "$url"; then

        rm -f -- "$tmp"
        error "下载失败：${url}"
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
    warn '此操作会运行 Debian VPS/TCP 调优脚本，并可能修改系统网络参数。'
    ask_yes_no '确认继续吗？' || {
        warn '已取消。'
        return 0
    }

    run_remote_script "$SCRIPT_TUNING"
}

run_ssh_manager() {
    echo
    log '启动 SSH Key Manager。'
    warn 'SSH 子脚本本身也是循环菜单；在 SSH 菜单中选择 0 后会返回本菜单。'
    run_remote_script "$SCRIPT_SSH"
}

run_3xui() {
    echo
    warn '3x-ui 安装脚本会要求输入域名、管理员账号和密码。'
    warn '默认面板端口为 8443，ACME HTTP-01 使用 80 端口。'
    ask_yes_no '确认安装 3x-ui 吗？' || {
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

    if ! cloudflared_installed; then
        warn '当前没有检测到通过 APT 安装的 cloudflared。'
        warn '该子脚本只负责配置 cloudflared 自动更新，不负责首次安装 Tunnel。'
        return 1
    fi

    run_remote_script "$SCRIPT_CLOUDFLARED" install
}

run_crowdsec() {
    echo
    warn 'CrowdSec 脚本会安装 nftables Firewall Bouncer，并接管主机入站防火墙。'
    warn '最终公网仅允许 80、443 和确认后的 SSH 端口；8443 公网访问会被阻止。'
    warn '建议把 CrowdSec 放在新机配置流程最后执行。'
    echo

    ask_yes_no '确认安装 CrowdSec 并应用防火墙吗？' || {
        warn '已取消。'
        return 0
    }

    run_remote_script "$SCRIPT_CROWDSEC"
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

    echo
}

run_recommended_flow() {
    echo
    echo '============================================================'
    echo ' 推荐新机初始化流程'
    echo '============================================================'
    echo
    echo '执行顺序：'
    echo '  1. Debian VPS / TCP 调优'
    echo '  2. SSH 密钥管理'
    echo '  3. 3x-ui'
    echo '  4. Cloudflared 自动更新（仅 cloudflared 已安装时）'
    echo '  5. CrowdSec + nftables（最后执行）'
    echo
    warn '该流程仍会保留各子脚本自己的安全确认和交互输入。'
    warn 'SSH Key Manager 内需要选择 0 退出后，才会继续下一步。'
    echo

    ask_yes_no '确认开始推荐流程吗？' || {
        warn '已取消。'
        return 0
    }

    echo
    log '[1/5] Debian VPS / TCP 调优'
    if ! run_remote_script "$SCRIPT_TUNING"; then
        warn 'TCP 调优失败，推荐流程停止。'
        return 1
    fi

    echo
    log '[2/5] SSH Key Manager'
    if ! run_remote_script "$SCRIPT_SSH"; then
        warn 'SSH 配置脚本执行失败，推荐流程停止。'
        return 1
    fi

    echo
    log '[3/5] 3x-ui'
    if ! run_remote_script "$SCRIPT_3XUI"; then
        warn '3x-ui 安装失败，推荐流程停止。'
        return 1
    fi

    echo
    log '[4/5] Cloudflared 自动更新'
    if cloudflared_installed; then
        if ! run_remote_script "$SCRIPT_CLOUDFLARED" install; then
            warn 'Cloudflared 自动更新配置失败，继续进入 CrowdSec 前请自行确认。'
            if ! ask_yes_no '仍然继续安装 CrowdSec 吗？'; then
                return 1
            fi
        fi
    else
        warn '未检测到 APT 安装的 cloudflared，跳过自动更新配置。'
    fi

    echo
    log '[5/5] CrowdSec + nftables'
    warn '这是最后一步，会收紧公网入站端口。'

    if ! ask_yes_no '确认继续执行 CrowdSec 防火墙配置吗？'; then
        warn '已跳过 CrowdSec。'
        return 0
    fi

    run_remote_script "$SCRIPT_CROWDSEC"
}

print_menu() {
    clear 2>/dev/null || true

    echo '============================================================'
    echo ' New Machine Setup - Debian'
    echo '============================================================'
    echo
    echo '1) Debian VPS / TCP 调优'
    echo '2) SSH 密钥管理'
    echo '3) 安装 3x-ui'
    echo '4) 安装 Cloudflared 自动更新任务'
    echo '5) 安装 CrowdSec + nftables 防火墙'
    echo '6) 执行推荐新机初始化流程'
    echo '7) 查看当前状态'
    echo '0) 退出'
    echo
}

main_loop() {
    local choice=''

    while true; do
        print_menu
        printf '请选择 [0-7]: ' >"$TTY"
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
                show_status || true
                pause_menu
                ;;
            0)
                echo
                log '已退出 New Machine Setup。'
                exit 0
                ;;
            *)
                warn '无效选择，请输入 0-7。'
                sleep 1
                ;;
        esac
    done
}

check_environment
main_loop
