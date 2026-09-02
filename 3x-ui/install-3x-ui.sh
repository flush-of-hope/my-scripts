#!/usr/bin/env bash

# One-click 3x-ui installer based on the official installer.
# Defaults follow the referenced guide:
#   - SQLite database
#   - Panel port 8443
#   - Let's Encrypt certificate for the entered domain
#   - ACME HTTP-01 listener on port 80
#   - Enable BBR when the running kernel supports it

set -Eeuo pipefail

readonly XUI_INSTALL_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
readonly XUI_PANEL_PORT="8443"
readonly XUI_ACME_PORT="80"

log() {
    printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${installer_file:-}" && -f "${installer_file}" ]]; then
        rm -f -- "${installer_file}"
    fi
}
trap cleanup EXIT

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行此脚本。"
}

check_os() {
    [[ -r /etc/os-release ]] || die "找不到 /etc/os-release，无法识别系统。"
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian|ubuntu|armbian) ;;
        *) die "本文档默认面向 Debian/Ubuntu；当前系统为 '${ID:-unknown}'。"
    esac
    command -v apt-get >/dev/null 2>&1 || die "找不到 apt-get。"
}

read_domain() {
    local input=""

    while :; do
        if [[ -r /dev/tty ]]; then
            read -r -p "请输入已解析到本机公网 IP 的域名（不要带 http:// 或路径）: " input </dev/tty
        else
            read -r -p "请输入已解析到本机公网 IP 的域名（不要带 http:// 或路径）: " input
        fi

        # Remove accidental surrounding whitespace only; reject URL-like input.
        input="${input#${input%%[![:space:]]*}}"
        input="${input%${input##*[![:space:]]}}"
        input="${input,,}"

        if [[ "${input}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
            DOMAIN="${input}"
            return 0
        fi

        warn "域名格式不正确：${input}"
    done
}

read_credentials() {
    if [[ -r /dev/tty ]]; then
        read -r -p "请输入管理员账号: " XUI_USERNAME </dev/tty
        read -r -s -p "请输入管理员密码: " XUI_PASSWORD </dev/tty; printf '\n'
        local confirm
        read -r -s -p "请再次输入管理员密码: " confirm </dev/tty; printf '\n'
    else
        read -r -p "请输入管理员账号: " XUI_USERNAME
        read -r -s -p "请输入管理员密码: " XUI_PASSWORD; printf '\n'
        local confirm
        read -r -s -p "请再次输入管理员密码: " confirm; printf '\n'
    fi
    [[ -n "${XUI_USERNAME}" && -n "${XUI_PASSWORD}" ]] || die "账号和密码不能为空。"
    [[ "${XUI_PASSWORD}" == "${confirm}" ]] || die "两次输入的密码不一致。"
}

check_ports() {
    local port
    for port in "${XUI_PANEL_PORT}" "${XUI_ACME_PORT}"; do
        if command -v ss >/dev/null 2>&1 && ss -ltnH 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END {exit found ? 0 : 1}'; then
            die "端口 ${port} 已被占用，请先释放该端口后再运行。"
        fi
    done
}

update_system() {
    log "更新软件源并升级系统软件包（保留现有配置文件）"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -o Dpkg::Options::=--force-confold upgrade -y
    apt-get install -y --no-install-recommends curl wget ca-certificates openssl iproute2
}

install_xui() {
    installer_file="$(mktemp -t 3x-ui-install.XXXXXX)"

    log "下载官方 3x-ui 安装器"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 5 --retry-delay 3 \
        --connect-timeout 15 --max-time 120 --silent --show-error \
        "${XUI_INSTALL_URL}" -o "${installer_file}"
    [[ -s "${installer_file}" ]] || die "官方安装器下载失败或文件为空。"

    log "安装 3x-ui：SQLite、面板端口 ${XUI_PANEL_PORT}、域名证书"
    # The current official installer supports these environment variables in
    # non-interactive mode. This avoids brittle expect/terminal prompt matching.
    XUI_NONINTERACTIVE=1 \
    XUI_DB_TYPE=sqlite \
    XUI_PANEL_PORT="${XUI_PANEL_PORT}" \
    XUI_SSL_MODE=domain \
    XUI_DOMAIN="${DOMAIN}" \
    XUI_USERNAME="${XUI_USERNAME}" \
    XUI_PASSWORD="${XUI_PASSWORD}" \
    XUI_ACME_HTTP_PORT="${XUI_ACME_PORT}" \
    bash "${installer_file}"
}

enable_bbr() {
    log "尝试开启 BBR"

    command -v sysctl >/dev/null 2>&1 || {
        warn "系统没有 sysctl，跳过 BBR。"
        return 0
    }

    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr; then
        warn "当前内核不支持 BBR，跳过。"
        return 0
    fi

    # Write a dedicated drop-in instead of modifying an existing sysctl file.
    install -d -m 755 /etc/sysctl.d
    cat >/etc/sysctl.d/99-3x-ui-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == "bbr" ]]; then
        log "BBR 已启用。"
    else
        warn "BBR 配置已写入，但当前运行状态未显示为 bbr。"
    fi
}

show_result() {
    local result_file="/etc/x-ui/install-result.env"

    printf '\n==============================================\n'
    printf '3x-ui 安装流程已完成\n'
    printf '==============================================\n'
    printf '面板域名： https://%s:%s（完整 WebBasePath 请以上方安装器输出为准）\n' "${DOMAIN}" "${XUI_PANEL_PORT}"
    printf '账号密码：请查看上方安装器输出，或读取：%s\n' "${result_file}"
    printf '\n前提：域名 A 记录必须指向本机公网 IP，且云防火墙/安全组放行 TCP %s 和 TCP %s。\n' "${XUI_PANEL_PORT}" "${XUI_ACME_PORT}"
    printf '管理命令：x-ui\n'
}

main() {
    require_root
    check_os
    read_domain
    read_credentials
    check_ports

    log "目标域名：${DOMAIN}"
    log "域名证书申请需要域名已解析到本机，并确保公网 TCP 端口 ${XUI_ACME_PORT} 可访问。"

    update_system
    install_xui
    enable_bbr
    show_result
}

main "$@"
