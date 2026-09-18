#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# CrowdSec + nftables 一键安全安装脚本（Debian/Ubuntu 优先）
#
# 公网入站：
#   TCP 80
#   TCP 443
#   SSH 自动检测并由用户确认
#
# 8443：
#   公网禁止
#   localhost 允许，供 cloudflared -> 127.0.0.1:8443
#
# CrowdSec：
#   - 先启动 Security Engine / LAPI
#   - 再安装 Firewall Bouncer
#   - Bouncer 启动失败时自动修复 API Key
#
# 防锁死：
#   应用防火墙后启动 90 秒自动回滚
#   必须从另一个 SSH 窗口测试登录并再次确认
# ============================================================

readonly GUARD_TABLE="crowdsec_guard"
readonly GUARD_DIR="/etc/crowdsec-guard"
readonly NFT_RULES="${GUARD_DIR}/firewall.nft"
readonly APPLY_HELPER="/usr/local/sbin/crowdsec-guard-fw"
readonly SERVICE_FILE="/etc/systemd/system/crowdsec-guard-fw.service"
readonly ROLLBACK_HELPER="/usr/local/sbin/crowdsec-guard-rollback"
readonly TTY="/dev/tty"
readonly BOUNCER_SERVICE="crowdsec-firewall-bouncer.service"
readonly BOUNCER_CONFIG_DIR="/etc/crowdsec/bouncers"
readonly BOUNCER_LOCAL_CONFIG="${BOUNCER_CONFIG_DIR}/crowdsec-firewall-bouncer.yaml.local"
readonly LAPI_URL="http://127.0.0.1:8080/"

CANDIDATE_NFT="/run/crowdsec-guard-candidate-$$.nft"
BACKUP_NFT="/run/crowdsec-guard-old-$$.nft"
ROLLBACK_UNIT="crowdsec-guard-rollback-$$"

SSH_PORT=""
APPLIED=0
PERSISTED=0
UFW_WAS_ACTIVE=0
FIREWALLD_WAS_ACTIVE=0

log() {
    printf '\033[1;32m[+]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[!]\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
    exit 1
}

need_tty() {
    [[ -r "$TTY" && -w "$TTY" ]] ||
        die "需要交互式终端进行 SSH 安全确认。"
}

ask_yes_no() {
    local prompt="$1"
    local ans=""

    printf '%s [y/N]: ' "$prompt" >"$TTY"
    IFS= read -r ans <"$TTY" || return 1
    [[ "$ans" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

port_is_listening() {
    local p="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null |
            awk -v p="$p" '
                {
                    addr=$4
                    sub(/^.*:/, "", addr)
                    if (addr == p) found=1
                }
                END { exit found ? 0 : 1 }
            '
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null |
            awk -v p="$p" '
                NR>2 {
                    addr=$4
                    sub(/^.*:/, "", addr)
                    if (addr == p) found=1
                }
                END { exit found ? 0 : 1 }
            '
        return $?
    fi

    warn "没有 ss/netstat，无法验证监听状态，将以 SSH 配置检测结果为准。"
    return 0
}

detect_ssh_port() {
    local active_port=""
    local p=""
    local -a ports=()

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        active_port="$(awk '{print $4}' <<<"$SSH_CONNECTION" 2>/dev/null || true)"
        valid_port "$active_port" && ports+=("$active_port")
    fi

    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r p; do
            valid_port "$p" && ports+=("$p")
        done < <(
            ss -H -ltnp 2>/dev/null |
                awk '/sshd/ {
                    a=$4
                    sub(/^.*:/,"",a)
                    print a
                }' |
                sort -nu
        )
    fi

    if command -v sshd >/dev/null 2>&1; then
        while IFS= read -r p; do
            valid_port "$p" && ports+=("$p")
        done < <(
            sshd -T 2>/dev/null |
                awk '$1=="port" {print $2}' |
                sort -nu
        )
    elif [[ -x /usr/sbin/sshd ]]; then
        while IFS= read -r p; do
            valid_port "$p" && ports+=("$p")
        done < <(
            /usr/sbin/sshd -T 2>/dev/null |
                awk '$1=="port" {print $2}' |
                sort -nu
        )
    fi

    mapfile -t ports < <(
        printf '%s\n' "${ports[@]:-}" |
            awk 'NF' |
            sort -nu
    )

    if valid_port "$active_port"; then
        SSH_PORT="$active_port"
        log "从当前 SSH 会话检测到服务端 SSH 端口：${SSH_PORT}"
    elif ((${#ports[@]} == 1)); then
        SSH_PORT="${ports[0]}"
        log "检测到 SSH 监听端口：${SSH_PORT}"
    elif ((${#ports[@]} > 1)); then
        warn "检测到多个 SSH 端口："
        printf '  %s\n' "${ports[@]}"
        printf '请输入需要保留的 SSH 端口: ' >"$TTY"
        IFS= read -r SSH_PORT <"$TTY"
    else
        warn "无法自动识别 SSH 端口。"
        printf '请输入当前 SSH 端口: ' >"$TTY"
        IFS= read -r SSH_PORT <"$TTY"
    fi

    valid_port "$SSH_PORT" || die "SSH 端口无效：${SSH_PORT}"
    port_is_listening "$SSH_PORT" || die "TCP ${SSH_PORT} 当前没有监听。为防止 SSH 锁死，停止执行。"

    echo
    if ! ask_yes_no "确认当前 SSH 端口为 TCP ${SSH_PORT} 吗？"; then
        printf '请输入正确的 SSH 端口: ' >"$TTY"
        IFS= read -r SSH_PORT <"$TTY"
        valid_port "$SSH_PORT" || die "SSH 端口无效：${SSH_PORT}"
        port_is_listening "$SSH_PORT" || die "TCP ${SSH_PORT} 当前没有监听。停止执行。"
        ask_yes_no "最终确认放行 SSH TCP ${SSH_PORT}？" || die "用户取消。"
    fi
}

detect_conflicting_firewalls() {
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | awk '$0=="Status: active" {found=1} END {exit found ? 0 : 1}'; then
            UFW_WAS_ACTIVE=1
        fi
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        FIREWALLD_WAS_ACTIVE=1
    fi

    if (( UFW_WAS_ACTIVE || FIREWALLD_WAS_ACTIVE )); then
        local fw_names=""
        (( UFW_WAS_ACTIVE == 1 )) && fw_names+="UFW "
        (( FIREWALLD_WAS_ACTIVE == 1 )) && fw_names+="firewalld"

        echo
        warn "检测到已有活动防火墙：${fw_names}"
        warn "本脚本需要使用 nftables 接管主机入站规则。"
        ask_yes_no "允许脚本接管当前主机防火墙吗？" || die "用户取消。"
    fi
}

install_base_packages() {
    command -v apt-get >/dev/null 2>&1 || die "当前脚本仅支持 Debian / Ubuntu APT 系统。"

    export DEBIAN_FRONTEND=noninteractive

    log "安装基础依赖..."
    apt-get update
    apt-get install -y curl ca-certificates gnupg nftables iproute2

    log "添加 CrowdSec 官方仓库..."
    curl -fsSL https://install.crowdsec.net | bash
    apt-get update
}

wait_for_crowdsec_lapi() {
    local i

    for i in $(seq 1 20); do
        if cscli lapi status >/dev/null 2>&1; then
            log "CrowdSec LAPI 已就绪。"
            return 0
        fi
        sleep 1
    done

    warn "CrowdSec LAPI 未能在预期时间内就绪。"
    cscli lapi status || true
    systemctl status crowdsec --no-pager -l || true
    journalctl -u crowdsec -n 80 --no-pager || true
    return 1
}

install_crowdsec_engine() {
    log "安装 CrowdSec Security Engine..."
    apt-get install -y crowdsec

    systemctl enable --now crowdsec

    cscli hub update || true
    cscli collections install crowdsecurity/linux || true

    systemctl restart crowdsec

    if ! systemctl is-active --quiet crowdsec; then
        systemctl status crowdsec --no-pager -l || true
        journalctl -u crowdsec -n 100 --no-pager || true
        die "CrowdSec 主服务启动失败。"
    fi

    log "CrowdSec 主服务正常。"
    wait_for_crowdsec_lapi || die "CrowdSec LAPI 不可用，停止安装。"
}

repair_firewall_bouncer() {
    local bouncer_name="firewall-bouncer-$(hostname)"
    local api_key=""

    log "正在修复 Firewall Bouncer API Key..."

    mkdir -p "$BOUNCER_CONFIG_DIR"

    cscli bouncers delete "$bouncer_name" >/dev/null 2>&1 || true

    api_key="$(cscli -o raw bouncers add "$bouncer_name" 2>/dev/null || true)"

    [[ -n "$api_key" ]] || die "无法为 Firewall Bouncer 生成 API Key。"

    cat >"$BOUNCER_LOCAL_CONFIG" <<EOF_BOUNCER
mode: nftables
api_url: ${LAPI_URL}
api_key: ${api_key}
EOF_BOUNCER

    chmod 600 "$BOUNCER_LOCAL_CONFIG"

    systemctl daemon-reload
    systemctl enable "$BOUNCER_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$BOUNCER_SERVICE"
}

install_firewall_bouncer() {
    log "安装 CrowdSec nftables Firewall Bouncer..."
    apt-get install -y crowdsec-firewall-bouncer-nftables

    systemctl daemon-reload

    if systemctl enable --now "$BOUNCER_SERVICE" >/dev/null 2>&1 &&
       systemctl is-active --quiet "$BOUNCER_SERVICE"; then
        log "CrowdSec Firewall Bouncer 已正常启动。"
        return 0
    fi

    warn "Firewall Bouncer 首次启动失败，自动修复 LAPI API Key。"

    if ! repair_firewall_bouncer; then
        systemctl status "$BOUNCER_SERVICE" --no-pager -l || true
        journalctl -u "$BOUNCER_SERVICE" -n 100 --no-pager || true
        die "Firewall Bouncer 自动修复失败。"
    fi

    sleep 2

    if ! systemctl is-active --quiet "$BOUNCER_SERVICE"; then
        systemctl status "$BOUNCER_SERVICE" --no-pager -l || true
        journalctl -u "$BOUNCER_SERVICE" -n 100 --no-pager || true
        die "Firewall Bouncer 仍然启动失败。"
    fi

    log "CrowdSec Firewall Bouncer 已正常启动。"
    echo
    cscli bouncers list || true
}

install_packages() {
    install_base_packages
    install_crowdsec_engine
    install_firewall_bouncer
}

write_candidate_firewall() {
    local nft_bin
    nft_bin="$(command -v nft)"
    [[ -n "$nft_bin" ]] || die "未找到 nft 命令。"

    cat >"$CANDIDATE_NFT" <<EOF_NFT
# ============================================================
# CrowdSec Guard
# Public: SSH ${SSH_PORT}, HTTP 80, HTTPS 443
# 8443 public access is blocked; localhost is allowed.
# ============================================================

table inet ${GUARD_TABLE} {
    chain input {
        type filter hook input priority -50;
        policy drop;

        iifname "lo" accept

        ct state invalid drop
        ct state established,related accept

        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept

        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept

        tcp dport ${SSH_PORT} ct state new accept
        tcp dport 80 ct state new accept
        tcp dport 443 ct state new accept
    }
}
EOF_NFT

    log "检查 nftables 规则语法..."
    "$nft_bin" -c -f "$CANDIDATE_NFT"
}

write_persistent_firewall() {
    local nft_bin
    nft_bin="$(command -v nft)"

    install -d -m 0755 "$GUARD_DIR"
    install -m 0644 "$CANDIDATE_NFT" "$NFT_RULES"

    cat >"$APPLY_HELPER" <<EOF_HELPER
#!/usr/bin/env bash
set -euo pipefail
NFT_BIN="${nft_bin}"
TABLE="${GUARD_TABLE}"
RULES="${NFT_RULES}"

case "\${1:-apply}" in
    apply)
        "\$NFT_BIN" list table inet "\$TABLE" >/dev/null 2>&1 &&
            "\$NFT_BIN" delete table inet "\$TABLE" || true
        exec "\$NFT_BIN" -f "\$RULES"
        ;;
    remove)
        "\$NFT_BIN" list table inet "\$TABLE" >/dev/null 2>&1 &&
            "\$NFT_BIN" delete table inet "\$TABLE" || true
        ;;
    *)
        echo "usage: \$0 {apply|remove}" >&2
        exit 2
        ;;
esac
EOF_HELPER

    chmod 0755 "$APPLY_HELPER"

    cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=CrowdSec Guard host inbound firewall
After=local-fs.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${APPLY_HELPER} apply
ExecReload=${APPLY_HELPER} apply
ExecStop=${APPLY_HELPER} remove

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

write_rollback_helper() {
    cat >"$ROLLBACK_HELPER" <<'EOF_ROLLBACK'
#!/usr/bin/env bash
set -u

backup="${1:-}"
ufw_was_active="${2:-0}"
firewalld_was_active="${3:-0}"

nft list table inet crowdsec_guard >/dev/null 2>&1 &&
    nft delete table inet crowdsec_guard || true

if [[ -n "$backup" && -s "$backup" ]]; then
    nft -f "$backup" || true
fi

if [[ "$firewalld_was_active" == "1" ]]; then
    systemctl start firewalld >/dev/null 2>&1 || true
fi

if [[ "$ufw_was_active" == "1" ]] && command -v ufw >/dev/null 2>&1; then
    ufw --force enable >/dev/null 2>&1 || true
fi
EOF_ROLLBACK

    chmod 0755 "$ROLLBACK_HELPER"
}

rollback_now() {
    "$ROLLBACK_HELPER" "$BACKUP_NFT" "$UFW_WAS_ACTIVE" "$FIREWALLD_WAS_ACTIVE" || true
}

cleanup_on_exit() {
    if (( APPLIED == 1 && PERSISTED == 0 )); then
        warn "安装未完整确认，恢复原防火墙状态..."
        rollback_now
    fi

    systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
    rm -f "$CANDIDATE_NFT" "$BACKUP_NFT"
}

apply_firewall() {
    if nft list table inet "$GUARD_TABLE" >"$BACKUP_NFT" 2>/dev/null; then
        log "已备份原 ${GUARD_TABLE} 防火墙规则。"
    else
        : >"$BACKUP_NFT"
    fi

    write_rollback_helper

    log "应用临时 nftables 防火墙..."

    nft list table inet "$GUARD_TABLE" >/dev/null 2>&1 &&
        nft delete table inet "$GUARD_TABLE" || true

    nft -f "$CANDIDATE_NFT"
    APPLIED=1

    if (( FIREWALLD_WAS_ACTIVE == 1 )); then
        log "临时停止 firewalld..."
        systemctl stop firewalld || true
    fi

    if (( UFW_WAS_ACTIVE == 1 )); then
        log "临时停止 UFW..."
        ufw --force disable || true
    fi

    nft list table inet "$GUARD_TABLE" >/dev/null 2>&1 &&
        nft delete table inet "$GUARD_TABLE" || true
    nft -f "$CANDIDATE_NFT"

    systemd-run \
        --quiet \
        --unit="$ROLLBACK_UNIT" \
        --on-active=90s \
        "$ROLLBACK_HELPER" \
        "$BACKUP_NFT" \
        "$UFW_WAS_ACTIVE" \
        "$FIREWALLD_WAS_ACTIVE"

    echo
    echo "============================================================"
    warn "90 秒 SSH 安全验证窗口已经启动"
    echo
    echo "请现在："
    echo "  1. 不要关闭当前 SSH 窗口"
    echo "  2. 新开一个终端"
    echo "  3. 使用同一个 SSH 端口 ${SSH_PORT} 再登录一次"
    echo "  4. 确认新 SSH 会话正常后回来输入 y"
    echo
    echo "如果没有确认，系统会自动回滚防火墙。"
    echo "============================================================"
    echo

    if ! ask_yes_no "新的 SSH 会话已经成功登录，持久化规则吗？"; then
        die "未确认新的 SSH 会话，将回滚。"
    fi

    systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "${ROLLBACK_UNIT}.service" "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true

    log "持久化 nftables 防火墙..."
    write_persistent_firewall

    systemctl daemon-reload
    systemctl enable crowdsec-guard-fw.service >/dev/null
    systemctl restart crowdsec-guard-fw.service

    if (( FIREWALLD_WAS_ACTIVE == 1 )); then
        systemctl disable firewalld >/dev/null 2>&1 || true
    fi

    PERSISTED=1
}

show_summary() {
    echo
    echo "============================================================"
    log "安装完成"
    echo "============================================================"
    echo
    echo "公网允许："
    echo "  TCP ${SSH_PORT}   SSH"
    echo "  TCP 80            HTTP"
    echo "  TCP 443           HTTPS"
    echo
    echo "公网禁止："
    echo "  TCP/UDP 8443"
    echo "  以及其他所有未明确允许的入站 TCP/UDP"
    echo
    echo "本机 localhost：允许，可供 cloudflared 访问 127.0.0.1:8443"
    echo

    echo "CrowdSec Security Engine:"
    systemctl is-active crowdsec 2>/dev/null || true

    echo
    echo "CrowdSec Firewall Bouncer:"
    systemctl is-active "$BOUNCER_SERVICE" 2>/dev/null || true

    echo
    echo "CrowdSec Bouncers:"
    cscli bouncers list 2>/dev/null || true

    echo
    echo "检查 nftables："
    echo "  nft list table inet ${GUARD_TABLE}"

    echo
    echo "检查 CrowdSec："
    echo "  cscli metrics show acquisition"
    echo "  cscli decisions list"
    echo "  cscli alerts list"

    echo
    echo "检查 8443："
    echo "  ss -lntp | grep :8443"

    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltnp 2>/dev/null | awk '$4 ~ /:8443$/ {found=1} END {exit found ? 0 : 1}'; then
            echo
            warn "检测到服务监听 8443。防火墙已阻止公网访问。"
            warn "如果可以，建议服务直接绑定 127.0.0.1:8443。"
        fi
    fi

    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        echo
        warn "检测到 Docker 正在运行。"
        warn "Docker published ports 可能经过 FORWARD / Docker 自有规则，请额外检查："
        echo "  docker ps --format 'table {{.Names}}\t{{.Ports}}'"
    fi

    echo
}

main() {
    [[ $EUID -eq 0 ]] || die "请使用 root 执行，例如：sudo bash $0"
    command -v systemctl >/dev/null 2>&1 || die "当前系统不是 systemd，脚本停止。"
    [[ -f /etc/debian_version ]] || die "当前版本仅支持 Debian / Ubuntu。"

    need_tty

    echo
    echo "============================================================"
    echo " CrowdSec + nftables 安全安装"
    echo "============================================================"
    echo

    detect_ssh_port
    detect_conflicting_firewalls

    echo
    echo "即将配置："
    echo "  TCP ${SSH_PORT}   SSH"
    echo "  TCP 80            HTTP"
    echo "  TCP 443           HTTPS"
    echo "  8443              仅 localhost 可达"
    echo "  其他公网入站      DROP"
    echo

    ask_yes_no "确认开始安装吗？" || die "用户取消。"

    install_packages
    write_candidate_firewall

    trap cleanup_on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    apply_firewall
    show_summary

    trap - EXIT INT TERM HUP
    rm -f "$CANDIDATE_NFT" "$BACKUP_NFT"
}

main "$@"
