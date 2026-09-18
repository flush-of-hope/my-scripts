#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# CrowdSec Guard TCP Port Manager
#
# 功能：
#   1. 开放自定义 TCP 端口
#   2. 关闭自定义 TCP 端口
#   3. 查看自定义开放端口
#
# 持久化方式：
#   - /etc/crowdsec-guard/custom-tcp-ports.conf 保存端口
#   - systemd drop-in 在 crowdsec-guard-fw.service 启动/重载后
#     自动重新应用自定义端口
# ============================================================

readonly TTY='/dev/tty'
readonly TABLE='crowdsec_guard'
readonly CHAIN='input'
readonly GUARD_SERVICE='crowdsec-guard-fw.service'
readonly GUARD_HELPER='/usr/local/sbin/crowdsec-guard-fw'
readonly GUARD_DIR='/etc/crowdsec-guard'
readonly PORTS_FILE='${GUARD_DIR}/custom-tcp-ports.conf'
readonly CUSTOM_HELPER='/usr/local/sbin/crowdsec-guard-custom-ports'
readonly DROPIN_DIR='/etc/systemd/system/crowdsec-guard-fw.service.d'
readonly DROPIN_FILE='${DROPIN_DIR}/custom-ports.conf'

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

pause_menu() {
    echo
    printf '按 Enter 返回主菜单...' >"$TTY"
    IFS= read -r _ <"$TTY" || true
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

check_environment() {
    [[ $EUID -eq 0 ]] || fatal '请使用 root 权限运行。'
    [[ -r "$TTY" && -w "$TTY" ]] || fatal '需要在交互式终端中运行。'
    command -v nft >/dev/null 2>&1 || fatal '未找到 nft 命令，请先安装 CrowdSec Guard。'
    command -v systemctl >/dev/null 2>&1 || fatal '未找到 systemctl。'

    nft list table inet "$TABLE" >/dev/null 2>&1 ||
        fatal '未检测到 crowdsec_guard 防火墙，请先执行 CrowdSec 安装脚本。'

    [[ -x "$GUARD_HELPER" ]] ||
        fatal "未找到 ${GUARD_HELPER}，请先执行 CrowdSec 安装脚本。"

    install -d -m 0755 "$GUARD_DIR" "$DROPIN_DIR"
    touch "$PORTS_FILE"
    chmod 0644 "$PORTS_FILE"
}

normalize_ports_file() {
    local tmp
    tmp="$(mktemp)"

    awk '
        /^[0-9]+$/ {
            p=$1+0
            if (p >= 1 && p <= 65535 && !seen[p]++) print p
        }
    ' "$PORTS_FILE" | sort -n >"$tmp"

    install -m 0644 "$tmp" "$PORTS_FILE"
    rm -f "$tmp"
}

write_custom_helper() {
    cat >"$CUSTOM_HELPER" <<'EOF_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly TABLE='crowdsec_guard'
readonly CHAIN='input'
readonly PORTS_FILE='/etc/crowdsec-guard/custom-tcp-ports.conf'

[[ -f "$PORTS_FILE" ]] || exit 0
nft list table inet "$TABLE" >/dev/null 2>&1 || exit 0

while IFS= read -r port; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    (( port >= 1 && port <= 65535 )) || continue

    nft add rule inet "$TABLE" "$CHAIN" \
        tcp dport "$port" \
        ct state new accept \
        comment "crowdsec-guard-custom-tcp-${port}"
done < "$PORTS_FILE"
EOF_HELPER

    chmod 0755 "$CUSTOM_HELPER"
}

write_systemd_dropin() {
    cat >"$DROPIN_FILE" <<EOF_DROPIN
[Service]
ExecStartPost=${CUSTOM_HELPER}
ExecReload=
ExecReload=${GUARD_HELPER} apply
ExecReload=${CUSTOM_HELPER}
EOF_DROPIN

    systemctl daemon-reload
}

ensure_integration() {
    write_custom_helper
    write_systemd_dropin
}

reload_guard() {
    ensure_integration

    if ! systemctl reload "$GUARD_SERVICE"; then
        error '重新加载 crowdsec_guard 失败。'
        systemctl status "$GUARD_SERVICE" --no-pager -l || true
        return 1
    fi

    return 0
}

port_exists() {
    local port="$1"
    awk -v p="$port" '$1 == p {found=1} END {exit found ? 0 : 1}' "$PORTS_FILE"
}

open_port() {
    local port=''

    echo
    printf '请输入要开放的 TCP 端口 [1-65535]: ' >"$TTY"
    IFS= read -r port <"$TTY"

    valid_port "$port" || {
        error "端口无效：${port}"
        return 1
    }

    if port_exists "$port"; then
        warn "TCP ${port} 已经在自定义开放列表中。"
        return 0
    fi

    printf '%s\n' "$port" >>"$PORTS_FILE"
    normalize_ports_file

    if reload_guard; then
        log "TCP ${port} 已开放，并已持久化。"
    else
        grep -vxF "$port" "$PORTS_FILE" >"${PORTS_FILE}.tmp" || true
        mv "${PORTS_FILE}.tmp" "$PORTS_FILE"
        normalize_ports_file
        return 1
    fi
}

close_port() {
    local port=''

    echo
    printf '请输入要关闭的自定义 TCP 端口 [1-65535]: ' >"$TTY"
    IFS= read -r port <"$TTY"

    valid_port "$port" || {
        error "端口无效：${port}"
        return 1
    }

    if ! port_exists "$port"; then
        warn "TCP ${port} 不在自定义开放列表中。"
        warn '80 / 443 / SSH 等基础端口不由本脚本关闭。'
        return 0
    fi

    grep -vxF "$port" "$PORTS_FILE" >"${PORTS_FILE}.tmp" || true
    mv "${PORTS_FILE}.tmp" "$PORTS_FILE"
    chmod 0644 "$PORTS_FILE"
    normalize_ports_file

    if reload_guard; then
        log "TCP ${port} 已从自定义开放列表删除。"
    else
        return 1
    fi
}

list_ports() {
    echo
    echo '============================================================'
    echo ' 自定义开放 TCP 端口'
    echo '============================================================'
    echo

    normalize_ports_file

    if [[ ! -s "$PORTS_FILE" ]]; then
        echo '当前没有自定义开放端口。'
    else
        nl -w2 -s') ' "$PORTS_FILE"
    fi

    echo
    echo '说明：80、443、SSH 端口属于 CrowdSec Guard 基础规则，不显示在这里。'
    echo
}

show_runtime_rules() {
    echo
    echo '当前 crowdsec_guard 中的自定义端口规则：'
    nft -a list chain inet "$TABLE" "$CHAIN" 2>/dev/null |
        awk '/crowdsec-guard-custom-tcp-/ {print}' || true
}

print_menu() {
    clear 2>/dev/null || true

    echo '============================================================'
    echo ' CrowdSec Guard - TCP 端口管理'
    echo '============================================================'
    echo
    echo '1) 开放 TCP 端口'
    echo '2) 关闭自定义 TCP 端口'
    echo '3) 查看自定义开放端口'
    echo '4) 查看当前实际 nftables 规则'
    echo '0) 退出'
    echo
}

main_loop() {
    local choice=''

    while true; do
        print_menu
        printf '请选择 [0-4]: ' >"$TTY"
        IFS= read -r choice <"$TTY" || choice='0'

        case "$choice" in
            1)
                open_port || true
                pause_menu
                ;;
            2)
                close_port || true
                pause_menu
                ;;
            3)
                list_ports || true
                pause_menu
                ;;
            4)
                show_runtime_rules || true
                pause_menu
                ;;
            0)
                echo
                log '已退出端口管理。'
                exit 0
                ;;
            *)
                warn '无效选择，请输入 0-4。'
                sleep 1
                ;;
        esac
    done
}

check_environment
ensure_integration
main_loop
