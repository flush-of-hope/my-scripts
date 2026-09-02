#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# CrowdSec + nftables 一键安全安装脚本
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

CANDIDATE_NFT="/run/crowdsec-guard-candidate-$$.nft"
BACKUP_NFT="/run/crowdsec-guard-old-$$.nft"
ROLLBACK_UNIT="crowdsec-guard-rollback-$$"

SSH_PORT=""
APPLIED=0
PERSISTED=0

UFW_WAS_ACTIVE=0
FIREWALLD_WAS_ACTIVE=0


# ============================================================
# 通用函数
# ============================================================

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
    [[ -r "$TTY" && -w "$TTY" ]] || \
        die "需要交互式终端进行 SSH 安全确认。请下载脚本后用 sudo bash 执行。"
}

ask_yes_no() {
    local prompt="$1"
    local ans=""

    printf '%s [y/N]: ' "$prompt" >"$TTY"
    IFS= read -r ans <"$TTY" || return 1

    [[ "$ans" =~ ^[Yy]$ ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        (( "$1" >= 1 && "$1" <= 65535 ))
}

port_is_listening() {
    local p="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null |
            awk '{print $4}' |
            grep -Eq "(^|:)${p}$"

    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null |
            awk 'NR>2 {print $4}' |
            grep -Eq "(^|:)${p}$"

    else
        warn "没有 ss/netstat，无法验证监听状态，将以 SSH 配置检测结果为准。"
        return 0
    fi
}


# ============================================================
# SSH 端口检测
# ============================================================

detect_ssh_port() {
    local active_port=""
    local p=""
    local -a ports=()

    #
    # 1. 当前 SSH 会话
    #
    # SSH_CONNECTION:
    # client_ip client_port server_ip server_port
    #
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        active_port="$(
            awk '{print $4}' <<<"$SSH_CONNECTION" 2>/dev/null || true
        )"

        if valid_port "$active_port"; then
            ports+=("$active_port")
        fi
    fi

    #
    # 2. 当前 sshd 实际监听
    #
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

    #
    # 3. sshd 最终生效配置
    #
    if command -v sshd >/dev/null 2>&1; then
        while IFS= read -r p; do
            valid_port "$p" && ports+=("$p")
        done < <(
            sshd -T 2>/dev/null |
                awk '$1=="port" {print $2}' |
                sort -nu
        )
    fi

    #
    # 去重
    #
    mapfile -t ports < <(
        printf '%s\n' "${ports[@]:-}" |
            awk 'NF' |
            sort -nu
    )

    #
    # 当前 SSH 会话优先级最高
    #
    if valid_port "$active_port"; then

        SSH_PORT="$active_port"

        log "从当前 SSH 会话检测到服务端 SSH 端口：${SSH_PORT}"

    elif ((${#ports[@]} == 1)); then

        SSH_PORT="${ports[0]}"

        log "检测到 SSH 监听端口：${SSH_PORT}"

    elif ((${#ports[@]} > 1)); then

        warn "检测到多个 SSH 端口："
        printf '%s\n' "${ports[@]}"

        printf '请输入需要保留的 SSH 端口: ' >"$TTY"
        IFS= read -r SSH_PORT <"$TTY"

    else

        warn "无法自动识别 SSH 端口。"

        printf '请输入当前 SSH 端口: ' >"$TTY"
        IFS= read -r SSH_PORT <"$TTY"
    fi

    valid_port "$SSH_PORT" ||
        die "SSH 端口无效：${SSH_PORT}"

    port_is_listening "$SSH_PORT" ||
        die "TCP ${SSH_PORT} 当前没有监听。为防止 SSH 锁死，停止执行。"

    echo

    if ! ask_yes_no "确认当前 SSH 端口为 TCP ${SSH_PORT} 吗？"; then

        printf '请输入正确的 SSH 端口: ' >"$TTY"
        IFS= read -r SSH_PORT <"$TTY"

        valid_port "$SSH_PORT" ||
            die "SSH 端口无效：${SSH_PORT}"

        port_is_listening "$SSH_PORT" ||
            die "TCP ${SSH_PORT} 当前没有监听。停止执行。"

        ask_yes_no "最终确认放行 SSH TCP ${SSH_PORT}？" ||
            die "用户取消。"
    fi
}


# ============================================================
# 检测已有防火墙
# ============================================================

detect_conflicting_firewalls() {
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q '^Status: active'; then
            UFW_WAS_ACTIVE=1
        fi
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        FIREWALLD_WAS_ACTIVE=1
    fi

    if (( UFW_WAS_ACTIVE || FIREWALLD_WAS_ACTIVE )); then

        local fw_names=""

        (( UFW_WAS_ACTIVE == 1 )) &&
            fw_names+="UFW "

        (( FIREWALLD_WAS_ACTIVE == 1 )) &&
            fw_names+="firewalld"

        echo
        warn "检测到已有活动防火墙：${fw_names}"
        warn "为了保证最终确实只有 80/443/SSH 对公网开放，"
        warn "本脚本需要使用 nftables 接管主机入站规则。"

        ask_yes_no "允许脚本接管当前主机防火墙吗？" ||
            die "用户取消。"
    fi
}


# ============================================================
# CrowdSec 安装
# ============================================================

install_packages() {
    local pkg_mgr=""

    if command -v apt-get >/dev/null 2>&1; then

        pkg_mgr="apt"

        export DEBIAN_FRONTEND=noninteractive

        log "安装基础依赖..."

        apt-get update

        apt-get install -y \
            curl \
            ca-certificates \
            gnupg \
            nftables \
            iproute2

    elif command -v dnf >/dev/null 2>&1; then

        pkg_mgr="dnf"

        log "安装基础依赖..."

        dnf install -y \
            curl \
            ca-certificates \
            nftables \
            iproute

    elif command -v yum >/dev/null 2>&1; then

        pkg_mgr="yum"

        log "安装基础依赖..."

        yum install -y \
            curl \
            ca-certificates \
            nftables \
            iproute

    else
        die "当前发行版暂不支持。"
    fi

    log "添加 CrowdSec 官方仓库..."

    curl -fsSL https://install.crowdsec.net | bash

    log "安装 CrowdSec Security Engine..."

    case "$pkg_mgr" in

        apt)
            apt-get update

            apt-get install -y \
                crowdsec \
                crowdsec-firewall-bouncer-nftables
            ;;

        dnf)
            dnf install -y \
                crowdsec \
                crowdsec-firewall-bouncer-nftables
            ;;

        yum)
            yum install -y \
                crowdsec \
                crowdsec-firewall-bouncer-nftables
            ;;
    esac

    log "启动 CrowdSec..."

    systemctl enable --now crowdsec

    #
    # Linux collection 内包含 SSHD 保护
    #
    cscli hub update || true
    cscli collections install crowdsecurity/linux || true

    systemctl restart crowdsec

    log "启动 CrowdSec nftables Firewall Bouncer..."

    systemctl enable --now crowdsec-firewall-bouncer
}


# ============================================================
# 生成临时 nftables 规则
# ============================================================

write_candidate_firewall() {
    local nft_bin

    nft_bin="$(command -v nft)"

    [[ -n "$nft_bin" ]] ||
        die "未找到 nft 命令。"

    cat >"$CANDIDATE_NFT" <<EOF
# ============================================================
# CrowdSec Guard
#
# Public:
#   SSH TCP ${SSH_PORT}
#   HTTP TCP 80
#   HTTPS TCP 443
#
# TCP/UDP 8443 public access is NOT allowed.
# localhost remains available for cloudflared.
# ============================================================

table inet ${GUARD_TABLE} {

    chain input {

        type filter hook input priority -50;
        policy drop;

        # ----------------------------------------------------
        # localhost
        #
        # cloudflared 可以：
        #   https://127.0.0.1:8443
        #   https://localhost:8443
        # ----------------------------------------------------

        iifname "lo" accept


        # ----------------------------------------------------
        # Conntrack
        # ----------------------------------------------------

        ct state invalid drop
        ct state established,related accept


        # ----------------------------------------------------
        # ICMP
        #
        # ICMP 没有 TCP/UDP 端口。
        # IPv6 Neighbor Discovery / PMTU 等依赖 ICMPv6。
        # ----------------------------------------------------

        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept


        # ----------------------------------------------------
        # DHCP client replies
        # ----------------------------------------------------

        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept


        # ----------------------------------------------------
        # SSH
        # ----------------------------------------------------

        tcp dport ${SSH_PORT} ct state new accept


        # ----------------------------------------------------
        # HTTP / HTTPS
        # ----------------------------------------------------

        tcp dport 80 ct state new accept
        tcp dport 443 ct state new accept


        # ----------------------------------------------------
        # 其他全部 DROP
        #
        # 因此包括：
        #   TCP 8443
        #   UDP 8443
        #   其他所有 TCP/UDP 入站
        # ----------------------------------------------------
    }
}
EOF

    log "检查 nftables 规则语法..."

    "$nft_bin" -c -f "$CANDIDATE_NFT"
}


# ============================================================
# 持久化防火墙
# ============================================================

write_persistent_firewall() {
    local nft_bin

    nft_bin="$(command -v nft)"

    install -d -m 0755 "$GUARD_DIR"

    install -m 0644 \
        "$CANDIDATE_NFT" \
        "$NFT_RULES"

    #
    # apply helper
    #

    cat >"$APPLY_HELPER" <<EOF
#!/usr/bin/env bash

set -euo pipefail

NFT_BIN="${nft_bin}"
TABLE="${GUARD_TABLE}"
RULES="${NFT_RULES}"

case "\${1:-apply}" in

    apply)

        "\$NFT_BIN" list table inet "\$TABLE" \
            >/dev/null 2>&1 \
            && "\$NFT_BIN" delete table inet "\$TABLE"

        exec "\$NFT_BIN" -f "\$RULES"
        ;;

    remove)

        "\$NFT_BIN" list table inet "\$TABLE" \
            >/dev/null 2>&1 \
            && "\$NFT_BIN" delete table inet "\$TABLE" \
            || true
        ;;

    *)

        echo "usage: \$0 {apply|remove}" >&2
        exit 2
        ;;
esac
EOF

    chmod 0755 "$APPLY_HELPER"

    #
    # systemd
    #

    cat >"$SERVICE_FILE" <<EOF
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
EOF
}


# ============================================================
# 自动回滚
# ============================================================

write_rollback_helper() {

    cat >"$ROLLBACK_HELPER" <<'EOF'
#!/usr/bin/env bash

set -u

backup="${1:-}"
ufw_was_active="${2:-0}"
firewalld_was_active="${3:-0}"

#
# 删除新规则
#

nft list table inet crowdsec_guard \
    >/dev/null 2>&1 \
    && nft delete table inet crowdsec_guard \
    || true


#
# 恢复之前 crowdsec_guard
#

if [[ -n "$backup" && -s "$backup" ]]; then
    nft -f "$backup" || true
fi


#
# 恢复 firewalld
#

if [[ "$firewalld_was_active" == "1" ]]; then
    systemctl start firewalld \
        >/dev/null 2>&1 || true
fi


#
# 恢复 UFW
#

if [[ "$ufw_was_active" == "1" ]] &&
   command -v ufw >/dev/null 2>&1; then

    ufw --force enable \
        >/dev/null 2>&1 || true
fi
EOF

    chmod 0755 "$ROLLBACK_HELPER"
}


rollback_now() {
    "$ROLLBACK_HELPER" \
        "$BACKUP_NFT" \
        "$UFW_WAS_ACTIVE" \
        "$FIREWALLD_WAS_ACTIVE" \
        || true
}


cleanup_on_exit() {

    if (( APPLIED == 1 && PERSISTED == 0 )); then

        warn "安装未完整确认，恢复原防火墙状态..."

        rollback_now
    fi

    systemctl stop \
        "${ROLLBACK_UNIT}.timer" \
        >/dev/null 2>&1 || true

    rm -f \
        "$CANDIDATE_NFT" \
        "$BACKUP_NFT"
}


# ============================================================
# 应用防火墙 + SSH 安全确认
# ============================================================

apply_firewall() {

    #
    # 如果之前已经有本脚本规则，先备份
    #

    if nft list table inet "$GUARD_TABLE" \
        >"$BACKUP_NFT" 2>/dev/null; then

        log "已备份原 ${GUARD_TABLE} 防火墙规则。"

    else
        : >"$BACKUP_NFT"
    fi


    write_rollback_helper


    #
    # 应用候选规则
    #

    log "应用临时 nftables 防火墙..."

    nft list table inet "$GUARD_TABLE" \
        >/dev/null 2>&1 \
        && nft delete table inet "$GUARD_TABLE" \
        || true

    nft -f "$CANDIDATE_NFT"

    APPLIED=1


    #
    # 暂停冲突防火墙
    #

    if (( FIREWALLD_WAS_ACTIVE == 1 )); then

        log "临时停止 firewalld..."

        systemctl stop firewalld || true
    fi


    if (( UFW_WAS_ACTIVE == 1 )); then

        log "临时停止 UFW..."

        ufw --force disable || true
    fi


    #
    # UFW/firewalld 停止过程可能改变 nftables，
    # 因此再次确保我们的规则存在。
    #

    nft list table inet "$GUARD_TABLE" \
        >/dev/null 2>&1 \
        && nft delete table inet "$GUARD_TABLE" \
        || true

    nft -f "$CANDIDATE_NFT"


    #
    # 90 秒自动回滚
    #

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
    echo
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


    #
    # 取消自动回滚
    #

    systemctl stop \
        "${ROLLBACK_UNIT}.timer" \
        >/dev/null 2>&1 || true


    systemctl reset-failed \
        "${ROLLBACK_UNIT}.service" \
        "${ROLLBACK_UNIT}.timer" \
        >/dev/null 2>&1 || true


    #
    # 持久化
    #

    log "持久化 nftables 防火墙..."

    write_persistent_firewall

    systemctl daemon-reload

    systemctl enable \
        crowdsec-guard-fw.service

    systemctl restart \
        crowdsec-guard-fw.service


    #
    # 最终禁用 firewalld
    #

    if (( FIREWALLD_WAS_ACTIVE == 1 )); then

        systemctl disable firewalld \
            >/dev/null 2>&1 || true
    fi


    PERSISTED=1
}


# ============================================================
# 最终检查
# ============================================================

show_summary() {

    echo
    echo "============================================================"
    log "安装完成"
    echo "============================================================"

    echo
    echo "公网允许："
    echo
    echo "  TCP ${SSH_PORT}   SSH"
    echo "  TCP 80            HTTP"
    echo "  TCP 443           HTTPS"
    echo
    echo "公网禁止："
    echo
    echo "  TCP/UDP 8443"
    echo "  以及其他所有未明确允许的入站 TCP/UDP"
    echo
    echo "本机："
    echo
    echo "  localhost / 127.0.0.1 / ::1 正常允许"
    echo "  cloudflared 可以访问 127.0.0.1:8443"
    echo


    echo "CrowdSec Security Engine:"
    systemctl is-active crowdsec 2>/dev/null || true

    echo

    echo "CrowdSec Firewall Bouncer:"
    systemctl is-active \
        crowdsec-firewall-bouncer \
        2>/dev/null || true


    echo
    echo "CrowdSec Bouncers:"
    cscli bouncers list 2>/dev/null || true


    echo
    echo "检查 nftables："
    echo
    echo "  nft list table inet ${GUARD_TABLE}"


    echo
    echo "检查 CrowdSec："
    echo
    echo "  cscli metrics show acquisition"
    echo "  cscli decisions list"
    echo "  cscli alerts list"


    echo
    echo "检查 8443："
    echo
    echo "  ss -lntp | grep :8443"


    #
    # 8443 监听提示
    #

    if command -v ss >/dev/null 2>&1; then

        if ss -H -ltnp 2>/dev/null |
            grep -qE '(:|\])8443\b'; then

            echo
            warn "检测到有服务监听 8443。"

            warn "防火墙已经阻止公网访问，"
            warn "但建议让该服务直接绑定：127.0.0.1:8443"
        fi
    fi


    #
    # Docker 特别提醒
    #

    if command -v docker >/dev/null 2>&1 &&
       systemctl is-active --quiet docker 2>/dev/null; then

        echo
        warn "检测到 Docker 正在运行。"

        warn "本规则主要限制主机 INPUT；Docker 的 published ports"
        warn "可能走 FORWARD/Docker 自己的规则。"

        echo
        echo "请额外检查："
        echo
        echo "  docker ps --format 'table {{.Names}}\t{{.Ports}}'"
    fi

    echo
}


# ============================================================
# MAIN
# ============================================================

main() {

    [[ $EUID -eq 0 ]] ||
        die "请使用 root 执行，例如：sudo bash $0"

    command -v systemctl >/dev/null 2>&1 ||
        die "当前系统不是 systemd，脚本停止。"

    need_tty

    echo
    echo "============================================================"
    echo " CrowdSec + nftables 安全安装"
    echo "============================================================"
    echo


    #
    # 第一步必须先确认 SSH
    #

    detect_ssh_port

    detect_conflicting_firewalls


    echo
    echo "即将配置："
    echo
    echo "  TCP ${SSH_PORT}   SSH"
    echo "  TCP 80            HTTP"
    echo "  TCP 443           HTTPS"
    echo
    echo "  8443              仅 localhost 可达"
    echo
    echo "  其他公网入站      DROP"
    echo


    ask_yes_no "确认开始安装吗？" ||
        die "用户取消。"


    install_packages

    write_candidate_firewall


    #
    # 从这里开始如果脚本异常退出自动恢复
    #

    trap cleanup_on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP


    apply_firewall

    show_summary


    #
    # 成功，关闭 trap
    #

    trap - EXIT INT TERM HUP


    rm -f \
        "$CANDIDATE_NFT" \
        "$BACKUP_NFT"
}


main "$@"
