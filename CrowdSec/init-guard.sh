#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# CrowdSec Guard - Standalone Initializer
#
# 用于以下场景：
#   - CrowdSec / nftables 已经由其他方式安装
#   - 但不存在本仓库的 crowdsec_guard 管理层
#
# 本脚本只初始化 Guard 防火墙管理层：
#   - 不安装/重装 CrowdSec
#   - 不修改 Firewall Bouncer API Key
#   - 不安装 3x-ui / cloudflared
#
# 基础公网放行：SSH / 80 / 443
# 其他入站默认 DROP
# 带 90 秒 SSH 自动回滚保护。
# ============================================================

readonly TTY='/dev/tty'
readonly TABLE='crowdsec_guard'
readonly GUARD_DIR='/etc/crowdsec-guard'
readonly NFT_RULES="${GUARD_DIR}/firewall.nft"
readonly GUARD_HELPER='/usr/local/sbin/crowdsec-guard-fw'
readonly GUARD_SERVICE='crowdsec-guard-fw.service'
readonly SERVICE_FILE="/etc/systemd/system/${GUARD_SERVICE}"
readonly ROLLBACK_HELPER='/usr/local/sbin/crowdsec-guard-bootstrap-rollback'

CANDIDATE_NFT="/run/crowdsec-guard-bootstrap-$$.nft"
BACKUP_NFT="/run/crowdsec-guard-bootstrap-old-$$.nft"
ROLLBACK_UNIT="crowdsec-guard-bootstrap-$$"
SSH_PORT=''
APPLIED=0
PERSISTED=0

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

fatal() {
    printf "${red}[x]${reset} %s\n" "$*" >&2
    exit 1
}

ask_yes_no() {
    local prompt="$1"
    local answer=''
    printf '%s [y/N]: ' "$prompt" >"$TTY"
    IFS= read -r answer <"$TTY" || return 1
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

port_is_listening() {
    local port="$1"
    ss -H -ltn 2>/dev/null |
        awk -v p="$port" '{a=$4; sub(/^.*:/,"",a); if (a==p) found=1} END {exit found ? 0 : 1}'
}

check_environment() {
    [[ $EUID -eq 0 ]] || fatal '请使用 root 权限运行。'
    [[ -r "$TTY" && -w "$TTY" ]] || fatal '需要交互式终端。'
    command -v nft >/dev/null 2>&1 || fatal '未检测到 nftables（nft）。'
    command -v systemctl >/dev/null 2>&1 || fatal '未检测到 systemd。'
    command -v ss >/dev/null 2>&1 || fatal '未检测到 ss/iproute2。'

    if ! command -v cscli >/dev/null 2>&1 && ! systemctl list-unit-files crowdsec.service >/dev/null 2>&1; then
        fatal '未检测到 CrowdSec。请先安装 CrowdSec，或执行总入口第 5 步。'
    fi

    if systemctl list-unit-files crowdsec.service >/dev/null 2>&1 && ! systemctl is-active --quiet crowdsec; then
        warn '检测到 CrowdSec，但 crowdsec.service 当前不是 active。'
        ask_yes_no '仍然只初始化 Guard 防火墙管理层吗？' || fatal '用户取消。'
    fi
}

detect_ssh_port() {
    local active_port=''
    local p=''
    local -a ports=()

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        active_port="$(awk '{print $4}' <<<"$SSH_CONNECTION" 2>/dev/null || true)"
        valid_port "$active_port" && ports+=("$active_port")
    fi

    while IFS= read -r p; do
        valid_port "$p" && ports+=("$p")
    done < <(
        ss -H -ltnp 2>/dev/null |
            awk '/sshd/ {a=$4; sub(/^.*:/,"",a); print a}' |
            sort -nu
    )

    if command -v sshd >/dev/null 2>&1; then
        while IFS= read -r p; do
            valid_port "$p" && ports+=("$p")
        done < <(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -nu)
    elif [[ -x /usr/sbin/sshd ]]; then
        while IFS= read -r p; do
            valid_port "$p" && ports+=("$p")
        done < <(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -nu)
    fi

    mapfile -t ports < <(printf '%s\n' "${ports[@]:-}" | awk 'NF' | sort -nu)

    if valid_port "$active_port"; then
        SSH_PORT="$active_port"
        log "从当前 SSH 会话检测到 SSH 端口：${SSH_PORT}"
    elif ((${#ports[@]} == 1)); then
        SSH_PORT="${ports[0]}"
        log "检测到 SSH 端口：${SSH_PORT}"
    elif ((${#ports[@]} > 1)); then
        warn "检测到多个 SSH 端口：${ports[*]}"
        printf '请输入需要保留的 SSH 端口: ' >"$TTY"
        IFS= read -r SSH_PORT <"$TTY"
    else
        printf '请输入当前 SSH 端口: ' >"$TTY"
        IFS= read -r SSH_PORT <"$TTY"
    fi

    valid_port "$SSH_PORT" || fatal "SSH 端口无效：${SSH_PORT}"
    port_is_listening "$SSH_PORT" || fatal "TCP ${SSH_PORT} 当前没有监听，为防止锁死停止执行。"

    ask_yes_no "确认公网必须保留 SSH TCP ${SSH_PORT} 吗？" || fatal '用户取消。'
}

show_existing_firewalls() {
    local found=0

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        warn '检测到 UFW 正在运行。Guard 会与 UFW 叠加；自定义端口也可能需要在 UFW 中放行。'
        found=1
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        warn '检测到 firewalld 正在运行。Guard 会与 firewalld 叠加；自定义端口也可能需要在 firewalld 中放行。'
        found=1
    fi

    if (( found == 1 )); then
        echo
        ask_yes_no '确认在现有防火墙之上增加 CrowdSec Guard 管理层吗？' || fatal '用户取消。'
    fi
}

write_candidate() {
    cat >"$CANDIDATE_NFT" <<EOF_NFT
table inet ${TABLE} {
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
}

write_rollback_helper() {
    cat >"$ROLLBACK_HELPER" <<'EOF_ROLLBACK'
#!/usr/bin/env bash
set -u
backup="${1:-}"

nft list table inet crowdsec_guard >/dev/null 2>&1 &&
    nft delete table inet crowdsec_guard || true

if [[ -n "$backup" && -s "$backup" ]]; then
    nft -f "$backup" || true
fi
EOF_ROLLBACK
    chmod 0755 "$ROLLBACK_HELPER"
}

rollback_now() {
    "$ROLLBACK_HELPER" "$BACKUP_NFT" || true
}

cleanup() {
    if (( APPLIED == 1 && PERSISTED == 0 )); then
        warn '未完成确认，恢复初始化前的 crowdsec_guard 状态...'
        rollback_now
    fi

    systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
    rm -f "$CANDIDATE_NFT" "$BACKUP_NFT"
}

write_persistent_files() {
    local nft_bin
    nft_bin="$(command -v nft)"

    install -d -m 0755 "$GUARD_DIR"
    install -m 0644 "$CANDIDATE_NFT" "$NFT_RULES"

    cat >"$GUARD_HELPER" <<EOF_HELPER
#!/usr/bin/env bash
set -euo pipefail
NFT_BIN="${nft_bin}"
TABLE='${TABLE}'
RULES='${NFT_RULES}'

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
    chmod 0755 "$GUARD_HELPER"

    cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=CrowdSec Guard host inbound firewall
After=local-fs.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${GUARD_HELPER} apply
ExecReload=${GUARD_HELPER} apply
ExecStop=${GUARD_HELPER} remove

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    systemctl daemon-reload
    systemctl enable "$GUARD_SERVICE" >/dev/null
}

apply_with_rollback() {
    if nft list table inet "$TABLE" >"$BACKUP_NFT" 2>/dev/null; then
        log '检测到旧 crowdsec_guard，已临时备份。'
        nft delete table inet "$TABLE"
    else
        : >"$BACKUP_NFT"
    fi

    if ! nft -c -f "$CANDIDATE_NFT"; then
        rollback_now
        fatal 'Guard nftables 规则语法检查失败。'
    fi

    nft -f "$CANDIDATE_NFT"
    APPLIED=1

    write_rollback_helper

    systemd-run \
        --quiet \
        --unit="$ROLLBACK_UNIT" \
        --on-active=90s \
        "$ROLLBACK_HELPER" "$BACKUP_NFT"

    echo
    echo '============================================================'
    warn '90 秒 SSH 安全验证窗口已启动'
    echo
    echo '请保持当前 SSH 不关闭，并新开一个终端重新登录。'
    echo "确认 SSH TCP ${SSH_PORT} 可以正常登录后，再回来输入 y。"
    echo '如果不确认，Guard 会自动回滚。'
    echo '============================================================'
    echo

    if ! ask_yes_no '新的 SSH 会话已经成功登录，是否持久化 Guard？'; then
        fatal '未确认新 SSH 会话，自动回滚。'
    fi

    systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "${ROLLBACK_UNIT}.service" "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true

    write_persistent_files
    systemctl restart "$GUARD_SERVICE"

    nft list table inet "$TABLE" >/dev/null 2>&1 || fatal 'Guard 持久化后未检测到 nftables 表。'
    [[ -x "$GUARD_HELPER" ]] || fatal 'Guard helper 创建失败。'

    PERSISTED=1
}

main() {
    check_environment

    if nft list table inet "$TABLE" >/dev/null 2>&1 &&
       [[ -x "$GUARD_HELPER" ]] &&
       systemctl cat "$GUARD_SERVICE" >/dev/null 2>&1; then
        log 'CrowdSec Guard 管理层已经存在，无需重复初始化。'
        exit 0
    fi

    echo
    echo '============================================================'
    echo ' CrowdSec Guard 兼容初始化'
    echo '============================================================'
    echo
    echo '检测到 CrowdSec/nftables 已存在，但不是本脚本管理的 Guard。'
    echo '本操作不会重装 CrowdSec，只创建端口管理所需的 Guard 管理层。'
    echo

    detect_ssh_port
    show_existing_firewalls

    echo
    echo '初始化后 Guard 基础公网规则：'
    echo "  SSH TCP ${SSH_PORT}"
    echo '  HTTP TCP 80'
    echo '  HTTPS TCP 443'
    echo '  其他未明确允许的入站默认 DROP'
    echo

    ask_yes_no '确认初始化 CrowdSec Guard 管理层吗？' || fatal '用户取消。'

    write_candidate
    trap cleanup EXIT INT TERM HUP
    apply_with_rollback

    trap - EXIT INT TERM HUP
    rm -f "$CANDIDATE_NFT" "$BACKUP_NFT"

    echo
    log 'CrowdSec Guard 管理层初始化完成。'
}

main "$@"
