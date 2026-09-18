#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

MANAGED_BEGIN='# BEGIN MANAGED KEY-ONLY SSH AUTH'
MANAGED_END='# END MANAGED KEY-ONLY SSH AUTH'
SSHD_CONFIG='/etc/ssh/sshd_config'
TTY='/dev/tty'

SSH_SERVICE=''
SSHD_BIN=''
TARGET_USER=''
USER_HOME=''
USER_GROUP=''
SSH_DIR=''
AUTHORIZED_KEYS=''
CLIENT_IP=''
SERVER_IP=''
SSH_PORT='22'

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

ask_yes_no() {
    local prompt="$1"
    local ans=''

    printf '%s [y/N]: ' "$prompt" >"$TTY"
    IFS= read -r ans <"$TTY" || return 1

    [[ "$ans" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

# ============================================================
# SSH service 检测
# ============================================================

detect_ssh_service() {
    SSH_SERVICE=''

    if systemctl cat ssh.service >/dev/null 2>&1; then
        SSH_SERVICE='ssh.service'
    elif systemctl cat sshd.service >/dev/null 2>&1; then
        SSH_SERVICE='sshd.service'
    else
        die '无法确定 SSH systemd 服务。'
    fi

    log "检测到 SSH 服务：${SSH_SERVICE}"

    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        log '检测到 ssh.socket 激活模式。'
    fi
}

reload_ssh() {
    "$SSHD_BIN" -t || die 'sshd 配置语法检查失败，未重新加载 SSH。'

    if systemctl is-active --quiet "$SSH_SERVICE" 2>/dev/null; then
        systemctl reload "$SSH_SERVICE"
    elif systemctl is-active --quiet ssh.socket 2>/dev/null; then
        # socket activation 模式下，新连接会读取新配置。
        # 重启 socket 让监听状态重新建立；现有 SSH 会话不会因此主动退出。
        systemctl restart ssh.socket
    else
        systemctl reload-or-restart "$SSH_SERVICE"
    fi
}

# ============================================================
# 环境检查
# ============================================================

check_environment() {
    [[ $EUID -eq 0 ]] ||
        die '请使用 root 权限运行，例如：sudo bash ssh-key-manager.sh'

    [[ -r "$TTY" && -w "$TTY" ]] ||
        die '需要交互式终端运行。'

    [[ -f /etc/debian_version ]] ||
        die '当前脚本仅支持 Debian / Ubuntu。'

    [[ -f "$SSHD_CONFIG" ]] ||
        die "未找到 ${SSHD_CONFIG}"

    SSHD_BIN="$(command -v sshd || true)"

    if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
        SSHD_BIN='/usr/sbin/sshd'
    fi

    [[ -x "$SSHD_BIN" ]] ||
        die '未找到 sshd，请先安装 openssh-server。'

    if ! command -v ssh-keygen >/dev/null 2>&1; then
        log '未找到 ssh-keygen，正在自动安装 openssh-client...'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client
    fi

    detect_ssh_service
}

# ============================================================
# 用户与 authorized_keys
# ============================================================

select_user() {
    local default_user

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != 'root' ]]; then
        default_user="$SUDO_USER"
    else
        default_user='root'
    fi

    echo
    printf '请输入 SSH 用户 [默认: %s]: ' "$default_user" >"$TTY"
    IFS= read -r TARGET_USER <"$TTY"
    TARGET_USER="${TARGET_USER:-$default_user}"

    id "$TARGET_USER" >/dev/null 2>&1 ||
        die "用户不存在：${TARGET_USER}"

    USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    USER_GROUP="$(id -gn "$TARGET_USER")"

    [[ -n "$USER_HOME" && -d "$USER_HOME" ]] ||
        die "无法确定 ${TARGET_USER} 的 HOME。"

    SSH_DIR="${USER_HOME}/.ssh"
    AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"

    install -d -m 700 -o "$TARGET_USER" -g "$USER_GROUP" "$SSH_DIR"
    touch "$AUTHORIZED_KEYS"
    chown "$TARGET_USER:$USER_GROUP" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
}

read_public_key() {
    local temp_key

    echo
    echo '请粘贴 SSH 公钥完整一行，例如：'
    echo '  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...'
    echo '  ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ...'
    echo

    printf 'SSH 公钥: ' >"$TTY"
    IFS= read -r SSH_PUBLIC_KEY <"$TTY"

    SSH_PUBLIC_KEY="$(
        printf '%s' "$SSH_PUBLIC_KEY" |
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    )"

    [[ -n "$SSH_PUBLIC_KEY" ]] || die '公钥不能为空。'

    temp_key="$(mktemp)"
    printf '%s\n' "$SSH_PUBLIC_KEY" >"$temp_key"

    if ! ssh-keygen -l -f "$temp_key" >/dev/null 2>&1; then
        rm -f "$temp_key"
        die '输入的不是有效 SSH 公钥。请粘贴 .pub 内容，不要粘贴私钥。'
    fi

    log 'SSH 公钥校验成功：'
    ssh-keygen -l -f "$temp_key"
    rm -f "$temp_key"

    KEY_TYPE="$(awk '{print $1}' <<<"$SSH_PUBLIC_KEY")"
    KEY_DATA="$(awk '{print $2}' <<<"$SSH_PUBLIC_KEY")"

    [[ -n "$KEY_TYPE" && -n "$KEY_DATA" ]] ||
        die '无法解析 SSH 公钥。'
}

key_exists() {
    awk -v key="$KEY_DATA" '
        {
            for (i=1; i<=NF; i++) {
                if ($i == key) {
                    found=1
                }
            }
        }
        END { exit !found }
    ' "$AUTHORIZED_KEYS"
}

sanitize_comment() {
    printf '%s' "$1" |
        tr '\r\n\t' '   ' |
        sed 's/[[:space:]][[:space:]]*/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

append_public_key() {
    local comment="$1"

    if key_exists; then
        warn '这把 SSH 公钥已经存在，不重复添加。'
        return 1
    fi

    if [[ -n "$comment" ]]; then
        printf '%s %s %s\n' "$KEY_TYPE" "$KEY_DATA" "$comment" >>"$AUTHORIZED_KEYS"
    else
        printf '%s\n' "$SSH_PUBLIC_KEY" >>"$AUTHORIZED_KEYS"
    fi

    chown "$TARGET_USER:$USER_GROUP" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"

    return 0
}

# ============================================================
# 密钥管理
# ============================================================

add_public_key() {
    local comment=''

    select_user
    read_public_key

    if key_exists; then
        echo
        warn '这把 SSH 公钥已经存在。'
        return
    fi

    echo
    printf '给这台电脑写个备注 [可留空，例如 MacBook-Pro]: ' >"$TTY"
    IFS= read -r comment <"$TTY"
    comment="$(sanitize_comment "$comment")"

    append_public_key "$comment" || return

    echo
    log '新 SSH 公钥添加成功。'
    echo "用户：${TARGET_USER}"
    echo "文件：${AUTHORIZED_KEYS}"
    [[ -n "$comment" ]] && echo "备注：${comment}"
    echo
}

collect_key_lines() {
    KEY_LINES=()

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ (ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-) ]]; then
            KEY_LINES+=("$line")
        fi
    done <"$AUTHORIZED_KEYS"
}

show_one_key() {
    local number="$1"
    local line="$2"
    local tmp info

    tmp="$(mktemp)"
    printf '%s\n' "$line" >"$tmp"
    info="$(ssh-keygen -l -f "$tmp" 2>/dev/null || echo '无法识别')"
    rm -f "$tmp"

    printf '[%s] %s\n' "$number" "$info"
}

list_public_keys() {
    local i

    select_user
    collect_key_lines

    echo
    echo '============================================================'
    echo " ${TARGET_USER} 当前 SSH 公钥"
    echo '============================================================'
    echo

    if ((${#KEY_LINES[@]} == 0)); then
        warn '当前没有找到有效 SSH 公钥。'
        return
    fi

    for i in "${!KEY_LINES[@]}"; do
        show_one_key "$((i + 1))" "${KEY_LINES[$i]}"
    done

    echo
    echo "共 ${#KEY_LINES[@]} 把密钥。"
}

delete_public_key() {
    local selection selected_key backup tmp_file i

    select_user
    collect_key_lines

    if ((${#KEY_LINES[@]} == 0)); then
        warn '当前没有找到有效 SSH 公钥。'
        return
    fi

    echo
    echo '============================================================'
    echo ' 当前 SSH 公钥'
    echo '============================================================'
    echo

    for i in "${!KEY_LINES[@]}"; do
        show_one_key "$((i + 1))" "${KEY_LINES[$i]}"
    done

    echo
    printf '请输入需要删除的编号: ' >"$TTY"
    IFS= read -r selection <"$TTY"

    [[ "$selection" =~ ^[0-9]+$ ]] || die '请输入有效编号。'
    (( selection >= 1 && selection <= ${#KEY_LINES[@]} )) || die '编号超出范围。'

    selected_key="${KEY_LINES[$((selection - 1))]}"

    echo
    warn '准备删除：'
    echo "$selected_key"
    echo

    ask_yes_no '确认删除吗？' || {
        echo '已取消。'
        return
    }

    if ((${#KEY_LINES[@]} == 1)); then
        warn '这是当前最后一把 SSH 公钥。删除后可能无法登录。'
        ask_yes_no '仍然确定删除吗？' || {
            echo '已取消。'
            return
        }
    fi

    backup="${AUTHORIZED_KEYS}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$AUTHORIZED_KEYS" "$backup"

    tmp_file="$(mktemp)"
    awk -v target="$selected_key" '$0 != target {print}' "$AUTHORIZED_KEYS" >"$tmp_file"
    cat "$tmp_file" >"$AUTHORIZED_KEYS"
    rm -f "$tmp_file"

    chown "$TARGET_USER:$USER_GROUP" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"

    echo
    log 'SSH 公钥删除成功。'
    echo "备份：${backup}"
}

# ============================================================
# SSH 实际配置检测
# ============================================================

detect_connection_info() {
    CLIENT_IP=''
    SERVER_IP=''
    SSH_PORT=''

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        CLIENT_IP="$(awk '{print $1}' <<<"$SSH_CONNECTION")"
        SERVER_IP="$(awk '{print $3}' <<<"$SSH_CONNECTION")"
        SSH_PORT="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
    fi

    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        SSH_PORT="$(
            "$SSHD_BIN" -T 2>/dev/null |
                awk '$1=="port" {print $2; exit}'
        )"
    fi

    SSH_PORT="${SSH_PORT:-22}"
}

effective_config() {
    if [[ -n "$CLIENT_IP" && -n "$SERVER_IP" && "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        "$SSHD_BIN" -T \
            -C "user=$TARGET_USER" \
            -C "host=$CLIENT_IP" \
            -C "addr=$CLIENT_IP" \
            -C "laddr=$SERVER_IP" \
            -C "lport=$SSH_PORT"
    else
        "$SSHD_BIN" -T
    fi
}

effective_value() {
    local key="$1"

    effective_config 2>/dev/null |
        awk -v k="$key" '
            $1==k {
                $1=""
                sub(/^[[:space:]]+/, "")
                print
                exit
            }
        '
}

# ============================================================
# sshd_config 顶部受控配置块
# ============================================================

write_managed_block() {
    local mode="$1"
    local clean tmp mode_bits owner group

    clean="$(mktemp)"
    tmp="$(mktemp)"

    awk \
        -v begin="$MANAGED_BEGIN" \
        -v end="$MANAGED_END" '
        $0 == begin { skip=1; next }
        $0 == end   { skip=0; next }
        !skip       { print }
    ' "$SSHD_CONFIG" >"$clean"

    {
        echo "$MANAGED_BEGIN"
        echo '# Managed by SSH Key Manager'
        echo '# Keep this block at the beginning of sshd_config'
        echo
        echo 'PubkeyAuthentication yes'

        if [[ "$mode" == 'key-only' ]]; then
            echo 'AuthenticationMethods publickey'
            echo 'PasswordAuthentication no'
            echo 'KbdInteractiveAuthentication no'
            echo 'ChallengeResponseAuthentication no'
            echo 'PermitRootLogin prohibit-password'
        fi

        echo "$MANAGED_END"
        echo
        cat "$clean"
    } >"$tmp"

    mode_bits="$(stat -c '%a' "$SSHD_CONFIG")"
    owner="$(stat -c '%u' "$SSHD_CONFIG")"
    group="$(stat -c '%g' "$SSHD_CONFIG")"

    chown "$owner:$group" "$tmp"
    chmod "$mode_bits" "$tmp"
    mv -f "$tmp" "$SSHD_CONFIG"
    rm -f "$clean"
}

restore_sshd_config() {
    local backup_file="$1"

    warn '正在恢复 SSH 配置...'
    cp -a "$backup_file" "$SSHD_CONFIG"

    if "$SSHD_BIN" -t >/dev/null 2>&1; then
        reload_ssh || true
    fi

    log 'SSH 配置已恢复。'
}

# ============================================================
# 首次配置 Key Only
# ============================================================

setup_key_only() {
    local comment=''
    local backup_dir backup_file
    local pubkey password keyboard auth_methods root_login auth_keys_effective

    select_user
    detect_connection_info

    echo
    echo '============================================================'
    echo ' SSH Key Only 初始化'
    echo '============================================================'
    echo
    echo "用户：${TARGET_USER}"
    echo "SSH 端口：${SSH_PORT}"

    read_public_key

    if key_exists; then
        warn '这把公钥已经存在，将直接继续配置。'
    else
        echo
        printf '这台电脑备注 [可留空，例如 MacBook-Pro]: ' >"$TTY"
        IFS= read -r comment <"$TTY"
        comment="$(sanitize_comment "$comment")"
        append_public_key "$comment" || true
    fi

    backup_dir="/root/ssh-key-auth-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    backup_file="${backup_dir}/sshd_config"
    cp -a "$SSHD_CONFIG" "$backup_file"

    if [[ -d /etc/ssh/sshd_config.d ]]; then
        cp -a /etc/ssh/sshd_config.d "$backup_dir/" 2>/dev/null || true
    fi

    log "SSH 配置备份：${backup_dir}"

    # 第一阶段：只确保公钥认证开启，不关闭密码
    log '第一阶段：开启 SSH 公钥认证，暂时保留密码登录...'
    write_managed_block 'enable-key'

    if ! "$SSHD_BIN" -t; then
        restore_sshd_config "$backup_file"
        die 'SSH 配置语法检查失败。'
    fi

    pubkey="$(effective_value pubkeyauthentication)"
    auth_keys_effective="$(effective_value authorizedkeysfile)"

    if [[ "$pubkey" != 'yes' ]]; then
        restore_sshd_config "$backup_file"
        die 'PubkeyAuthentication 最终生效值不是 yes。'
    fi

    if [[ "$auth_keys_effective" != *'.ssh/authorized_keys'* ]]; then
        restore_sshd_config "$backup_file"
        die "AuthorizedKeysFile=${auth_keys_effective}，未包含 .ssh/authorized_keys。"
    fi

    reload_ssh

    echo
    echo '============================================================'
    echo ' 第一阶段完成'
    echo '============================================================'
    echo
    echo '密码登录目前【尚未关闭】。'
    echo '请保持当前 SSH 窗口不要关闭。'
    echo
    echo '另外打开一个新的 Terminal / Termius，测试密钥登录：'
    echo
    echo "ssh -i ~/.ssh/id_rsa -o IdentitiesOnly=yes -p ${SSH_PORT} ${TARGET_USER}@服务器IP"
    echo
    echo '使用 -v/-vv 时应看到：'
    echo '  Server accepts key'
    echo '  Authenticated ... using "publickey"'
    echo

    if ! ask_yes_no '已经确认新的 SSH 会话可以通过密钥正常登录吗？'; then
        warn '未关闭密码登录。公钥认证已经开启。'
        return
    fi

    # 第二阶段：真正关闭密码
    log '第二阶段：关闭密码登录，仅允许 SSH Public Key...'
    write_managed_block 'key-only'

    if ! "$SSHD_BIN" -t; then
        restore_sshd_config "$backup_file"
        die 'Key Only 配置语法检查失败。'
    fi

    pubkey="$(effective_value pubkeyauthentication)"
    password="$(effective_value passwordauthentication)"
    keyboard="$(effective_value kbdinteractiveauthentication)"
    auth_methods="$(effective_value authenticationmethods)"
    root_login="$(effective_value permitrootlogin)"

    if [[ "$pubkey" != 'yes' ||
          "$password" != 'no' ||
          "$keyboard" != 'no' ||
          "$auth_methods" != 'publickey' ]]; then

        echo
        warn '最终 SSH 实际生效配置与预期不一致：'
        echo "  PubkeyAuthentication     = ${pubkey}"
        echo "  PasswordAuthentication   = ${password}"
        echo "  KbdInteractiveAuthentication = ${keyboard}"
        echo "  AuthenticationMethods    = ${auth_methods}"

        restore_sshd_config "$backup_file"
        die '最终配置验证失败，已经自动恢复。'
    fi

    reload_ssh

    # reload 后再次验证
    pubkey="$(effective_value pubkeyauthentication)"
    password="$(effective_value passwordauthentication)"
    keyboard="$(effective_value kbdinteractiveauthentication)"
    auth_methods="$(effective_value authenticationmethods)"
    root_login="$(effective_value permitrootlogin)"

    if [[ "$pubkey" != 'yes' ||
          "$password" != 'no' ||
          "$keyboard" != 'no' ||
          "$auth_methods" != 'publickey' ]]; then
        restore_sshd_config "$backup_file"
        die 'reload 后最终配置验证失败，已经自动恢复。'
    fi

    echo
    echo '============================================================'
    echo ' SSH 仅密钥登录配置完成'
    echo '============================================================'
    echo
    echo "PubkeyAuthentication:           ${pubkey}"
    echo "PasswordAuthentication:         ${password}"
    echo "KbdInteractiveAuthentication:   ${keyboard}"
    echo "AuthenticationMethods:          ${auth_methods}"
    echo "PermitRootLogin:                ${root_login}"
    echo
    echo "authorized_keys: ${AUTHORIZED_KEYS}"
    echo "配置备份:       ${backup_dir}"
    echo
    echo '以后增加其他电脑时，重新运行脚本选择：'
    echo '  2) 添加新的 SSH 公钥'
    echo
}

# ============================================================
# 主菜单
# ============================================================

show_menu() {
    local choice

    echo
    echo '============================================================'
    echo ' SSH Key Manager'
    echo '============================================================'
    echo
    echo '1) 首次配置：仅允许 SSH 密钥登录'
    echo '2) 添加新的 SSH 公钥'
    echo '3) 查看当前 SSH 公钥'
    echo '4) 删除 SSH 公钥'
    echo '0) 退出'
    echo

    printf '请选择 [0-4]: ' >"$TTY"
    IFS= read -r choice <"$TTY"

    case "$choice" in
        1) setup_key_only ;;
        2) add_public_key ;;
        3) list_public_keys ;;
        4) delete_public_key ;;
        0) exit 0 ;;
        *) die '无效选择。' ;;
    esac
}

check_environment
show_menu
