#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# SSH Key Manager - Debian 专用版
#
# 功能：
#   1. 初始化/修复 SSH 密钥登录（不关闭密码）
#   2. 添加新的 SSH 公钥
#   3. 查看当前 SSH 公钥
#   4. 删除 SSH 公钥
#   5. 关闭密码登录（仅允许 SSH 密钥）
#   6. 开启密码登录（密码 + 密钥）
#   7. 查看 SSH 实际生效状态
#   0. 退出
#
# 设计原则：
#   - Debian / Ubuntu（优先 Debian）
#   - 直接使用 /etc/ssh/sshd_config 顶部受控块
#   - 避免 sshd_config.d 的顺序覆盖问题
#   - 所有修改先 sshd -t，再 reload
#   - 使用 sshd -T 检查最终实际生效值
#   - 关闭密码后要求新开 SSH 窗口验证；失败可立即恢复
#   - 菜单循环运行，只有选择 0 才退出
# ============================================================

readonly SSHD_CONFIG='/etc/ssh/sshd_config'
readonly TTY='/dev/tty'
readonly MANAGED_BEGIN='# BEGIN MANAGED SSH AUTH BY SSH-KEY-MANAGER'
readonly MANAGED_END='# END MANAGED SSH AUTH BY SSH-KEY-MANAGER'

SSHD_BIN=''
TARGET_USER=''
USER_HOME=''
USER_GROUP=''
SSH_DIR=''
AUTHORIZED_KEYS=''
CLIENT_IP=''
SERVER_IP=''
SSH_PORT='22'
KEY_TYPE=''
KEY_DATA=''
SSH_PUBLIC_KEY=''

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

# ============================================================
# 环境检查
# ============================================================

check_environment() {
    [[ $EUID -eq 0 ]] ||
        fatal '请使用 root 权限执行，例如：sudo ./ssh-key-manager.sh'

    [[ -r "$TTY" && -w "$TTY" ]] ||
        fatal '需要在交互式终端中运行。'

    [[ -f /etc/debian_version ]] ||
        fatal '此版本仅支持 Debian / Ubuntu。'

    [[ -f "$SSHD_CONFIG" ]] ||
        fatal "未找到 ${SSHD_CONFIG}。"

    SSHD_BIN="$(command -v sshd 2>/dev/null || true)"

    if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
        SSHD_BIN='/usr/sbin/sshd'
    fi

    [[ -x "$SSHD_BIN" ]] ||
        fatal '未找到 sshd，请先安装 openssh-server。'

    if ! command -v ssh-keygen >/dev/null 2>&1; then
        log '未找到 ssh-keygen，正在安装 openssh-client...'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client
    fi

    "$SSHD_BIN" -t ||
        fatal '当前 sshd_config 本身就存在语法错误，请先修复后再运行本脚本。'
}

# ============================================================
# Debian SSH reload
#
# 不再预先判断 ssh.service / sshd.service。
# Debian 标准优先 systemctl reload ssh；失败后依次兜底。
# ============================================================

find_sshd_master_pid() {
    local pid=''

    if command -v ss >/dev/null 2>&1; then
        pid="$(
            ss -H -lntp 2>/dev/null |
                awk '
                    /users:\(\("sshd"/ {
                        if (match($0, /pid=[0-9]+/)) {
                            p=substr($0, RSTART, RLENGTH)
                            sub(/^pid=/, "", p)
                            print p
                            exit
                        }
                    }
                '
        )"
    fi

    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid"
        return 0
    fi

    pid="$(
        ps -eo pid=,ppid=,comm= 2>/dev/null |
            awk '$3=="sshd" && $2==1 {print $1; exit}'
    )"

    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid"
        return 0
    fi

    return 1
}

reload_ssh() {
    local pid=''

    if ! "$SSHD_BIN" -t; then
        error 'sshd 配置语法检查失败，未 reload。'
        return 1
    fi

    # Debian 标准方式
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl reload ssh >/dev/null 2>&1; then
            log 'SSH 已通过 systemctl reload ssh 重新加载。'
            return 0
        fi

        if systemctl reload ssh.service >/dev/null 2>&1; then
            log 'SSH 已通过 ssh.service 重新加载。'
            return 0
        fi

        if systemctl reload sshd.service >/dev/null 2>&1; then
            log 'SSH 已通过 sshd.service 重新加载。'
            return 0
        fi
    fi

    # SysV 兼容
    if command -v service >/dev/null 2>&1; then
        if service ssh reload >/dev/null 2>&1; then
            log 'SSH 已通过 service ssh reload 重新加载。'
            return 0
        fi
    fi

    # 最后兜底：HUP sshd master，不主动 restart
    if pid="$(find_sshd_master_pid)"; then
        if kill -HUP "$pid"; then
            log "已向 sshd 主进程 PID ${pid} 发送 HUP。"
            return 0
        fi
    fi

    error 'sshd_config 语法正常，但无法安全 reload SSH。'
    return 1
}

# ============================================================
# 用户 / authorized_keys
# ============================================================

select_user() {
    local default_user='root'

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != 'root' ]]; then
        default_user="$SUDO_USER"
    fi

    echo
    printf '请输入 SSH 用户 [默认: %s]: ' "$default_user" >"$TTY"
    IFS= read -r TARGET_USER <"$TTY"
    TARGET_USER="${TARGET_USER:-$default_user}"

    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        error "用户不存在：${TARGET_USER}"
        return 1
    fi

    USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    USER_GROUP="$(id -gn "$TARGET_USER")"

    if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
        error "无法确定 ${TARGET_USER} 的 HOME。"
        return 1
    fi

    SSH_DIR="${USER_HOME}/.ssh"
    AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"

    install -d -m 700 -o "$TARGET_USER" -g "$USER_GROUP" "$SSH_DIR"
    touch "$AUTHORIZED_KEYS"
    chown "$TARGET_USER:$USER_GROUP" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
}

read_public_key() {
    local temp_key=''

    echo
    echo '请粘贴 SSH 公钥完整一行：'
    echo '  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...'
    echo '  ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ...'
    echo

    printf 'SSH 公钥: ' >"$TTY"
    IFS= read -r SSH_PUBLIC_KEY <"$TTY"

    SSH_PUBLIC_KEY="$(
        printf '%s' "$SSH_PUBLIC_KEY" |
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    )"

    if [[ -z "$SSH_PUBLIC_KEY" ]]; then
        error '公钥不能为空。'
        return 1
    fi

    temp_key="$(mktemp)"
    printf '%s\n' "$SSH_PUBLIC_KEY" >"$temp_key"

    if ! ssh-keygen -l -f "$temp_key" >/dev/null 2>&1; then
        rm -f "$temp_key"
        error '输入内容不是有效 SSH 公钥。请粘贴 .pub 内容，不要粘贴私钥。'
        return 1
    fi

    log 'SSH 公钥校验成功：'
    ssh-keygen -l -f "$temp_key"
    rm -f "$temp_key"

    KEY_TYPE="$(awk '{print $1}' <<<"$SSH_PUBLIC_KEY")"
    KEY_DATA="$(awk '{print $2}' <<<"$SSH_PUBLIC_KEY")"

    if [[ -z "$KEY_TYPE" || -z "$KEY_DATA" ]]; then
        error '无法解析 SSH 公钥。'
        return 1
    fi
}

key_exists() {
    awk -v key="$KEY_DATA" '
        {
            for (i=1; i<=NF; i++) {
                if ($i == key) found=1
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
        return 0
    fi

    if [[ -n "$comment" ]]; then
        printf '%s %s %s\n' "$KEY_TYPE" "$KEY_DATA" "$comment" >>"$AUTHORIZED_KEYS"
    else
        printf '%s\n' "$SSH_PUBLIC_KEY" >>"$AUTHORIZED_KEYS"
    fi

    chown "$TARGET_USER:$USER_GROUP" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"

    log 'SSH 公钥添加成功。'
}

collect_key_lines() {
    KEY_LINES=()
    local line=''

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
    local tmp=''
    local info=''

    tmp="$(mktemp)"
    printf '%s\n' "$line" >"$tmp"
    info="$(ssh-keygen -l -f "$tmp" 2>/dev/null || echo '无法识别')"
    rm -f "$tmp"

    printf '[%s] %s\n' "$number" "$info"
}

# ============================================================
# SSH 连接信息 / 实际生效配置
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
    if [[ -n "$TARGET_USER" && -n "$CLIENT_IP" && -n "$SERVER_IP" && "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        "$SSHD_BIN" -T \
            -C "user=${TARGET_USER},host=${SERVER_IP},addr=${CLIENT_IP},laddr=${SERVER_IP},lport=${SSH_PORT}"
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

show_auth_status() {
    local pubkey password keyboard auth_methods root_login auth_keys port

    select_user || return 1
    detect_connection_info

    pubkey="$(effective_value pubkeyauthentication)"
    password="$(effective_value passwordauthentication)"
    keyboard="$(effective_value kbdinteractiveauthentication)"
    auth_methods="$(effective_value authenticationmethods)"
    root_login="$(effective_value permitrootlogin)"
    auth_keys="$(effective_value authorizedkeysfile)"
    port="$(effective_value port)"

    echo
    echo '============================================================'
    echo ' SSH 实际生效状态'
    echo '============================================================'
    echo
    printf '%-32s %s\n' 'User:' "$TARGET_USER"
    printf '%-32s %s\n' 'Port:' "${port:-$SSH_PORT}"
    printf '%-32s %s\n' 'PubkeyAuthentication:' "$pubkey"
    printf '%-32s %s\n' 'PasswordAuthentication:' "$password"
    printf '%-32s %s\n' 'KbdInteractiveAuthentication:' "$keyboard"
    printf '%-32s %s\n' 'AuthenticationMethods:' "$auth_methods"
    printf '%-32s %s\n' 'PermitRootLogin:' "$root_login"
    printf '%-32s %s\n' 'AuthorizedKeysFile:' "$auth_keys"
    echo

    if [[ "$pubkey" == 'yes' && "$password" == 'no' && "$keyboard" == 'no' && "$auth_methods" == 'publickey' ]]; then
        log '当前为：仅 SSH 密钥登录。'
    elif [[ "$pubkey" == 'yes' && "$password" == 'yes' ]]; then
        warn '当前为：SSH 密钥 + 密码均可登录。'
    else
        warn '当前认证配置不是脚本的标准模式，请根据上面的实际值检查。'
    fi
}

# ============================================================
# sshd_config 顶部受控块
#
# OpenSSH 多数参数采用 first obtained value，因此受控块直接放在
# /etc/ssh/sshd_config 最顶部，位于 Include 之前。
# ============================================================

write_managed_block() {
    local mode="$1"
    local clean=''
    local tmp=''
    local mode_bits=''
    local owner=''
    local group=''

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
        echo '# Managed by ssh-key-manager.sh'
        echo '# Keep this block at the beginning of sshd_config.'
        echo

        case "$mode" in
            enable-key)
                # 仅确保公钥认证开启，不主动改变现有密码策略。
                echo 'PubkeyAuthentication yes'
                ;;

            key-only)
                echo 'PubkeyAuthentication yes'
                echo 'AuthenticationMethods publickey'
                echo 'PasswordAuthentication no'
                echo 'KbdInteractiveAuthentication no'
                echo 'ChallengeResponseAuthentication no'
                echo 'PermitRootLogin prohibit-password'
                ;;

            password-on)
                echo 'PubkeyAuthentication yes'
                echo 'AuthenticationMethods any'
                echo 'PasswordAuthentication yes'
                echo 'KbdInteractiveAuthentication no'
                echo 'ChallengeResponseAuthentication no'
                echo 'PermitRootLogin yes'
                ;;

            *)
                rm -f "$clean" "$tmp"
                error "未知 SSH 配置模式：${mode}"
                return 1
                ;;
        esac

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

backup_sshd_config() {
    local backup_dir="/root/ssh-key-manager-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "$SSHD_CONFIG" "${backup_dir}/sshd_config"
    printf '%s\n' "${backup_dir}/sshd_config"
}

restore_sshd_config() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        error "找不到备份：${backup_file}"
        return 1
    fi

    warn '正在恢复修改前的 SSH 配置...'
    cp -a "$backup_file" "$SSHD_CONFIG"

    if "$SSHD_BIN" -t >/dev/null 2>&1; then
        reload_ssh || true
    fi

    log 'SSH 配置已恢复。'
}

# ============================================================
# 1) 初始化 / 修复密钥登录
# ============================================================

setup_key_login() {
    local comment=''
    local backup_file=''
    local pubkey=''
    local auth_keys=''

    select_user || return 1
    detect_connection_info

    echo
    echo '============================================================'
    echo ' 初始化 / 修复 SSH 密钥登录'
    echo ' 此操作不会关闭密码登录'
    echo '============================================================'

    read_public_key || return 1

    if key_exists; then
        warn '该公钥已经存在，将继续修复 SSH 公钥认证配置。'
    else
        echo
        printf '给这台电脑写个备注 [可留空，例如 MacBook-Pro]: ' >"$TTY"
        IFS= read -r comment <"$TTY"
        comment="$(sanitize_comment "$comment")"
        append_public_key "$comment"
    fi

    backup_file="$(backup_sshd_config)"
    log "配置备份：${backup_file}"

    write_managed_block 'enable-key' || return 1

    if ! "$SSHD_BIN" -t; then
        restore_sshd_config "$backup_file"
        error 'SSH 配置语法检查失败，已经恢复。'
        return 1
    fi

    pubkey="$(effective_value pubkeyauthentication)"
    auth_keys="$(effective_value authorizedkeysfile)"

    if [[ "$pubkey" != 'yes' ]]; then
        restore_sshd_config "$backup_file"
        error "PubkeyAuthentication 实际生效值仍为：${pubkey}"
        return 1
    fi

    if [[ "$auth_keys" != *'.ssh/authorized_keys'* ]]; then
        restore_sshd_config "$backup_file"
        error "AuthorizedKeysFile=${auth_keys}，未包含 .ssh/authorized_keys。"
        return 1
    fi

    if ! reload_ssh; then
        restore_sshd_config "$backup_file"
        return 1
    fi

    echo
    log 'SSH 公钥认证已开启。密码策略没有被此操作主动关闭。'
    echo
    echo '请在另一个终端测试：'
    echo "  ssh -i ~/.ssh/id_rsa -o IdentitiesOnly=yes -p ${SSH_PORT} ${TARGET_USER}@服务器IP"
    echo
    echo '确认日志出现：'
    echo '  Server accepts key'
    echo '  Authenticated ... using "publickey"'
}

# ============================================================
# 2) 添加新密钥
# ============================================================

add_public_key() {
    local comment=''

    select_user || return 1
    read_public_key || return 1

    if key_exists; then
        warn '这把 SSH 公钥已经存在。'
        return 0
    fi

    echo
    printf '给这台电脑写个备注 [可留空，例如 Office-PC]: ' >"$TTY"
    IFS= read -r comment <"$TTY"
    comment="$(sanitize_comment "$comment")"

    append_public_key "$comment"

    echo
    echo "authorized_keys: ${AUTHORIZED_KEYS}"
    [[ -n "$comment" ]] && echo "备注: ${comment}"
    echo
    log '添加密钥不需要 reload SSH，立即对新连接生效。'
}

# ============================================================
# 3) 查看密钥
# ============================================================

list_public_keys() {
    local i=''

    select_user || return 1
    collect_key_lines

    echo
    echo '============================================================'
    echo " ${TARGET_USER} 当前 SSH 公钥"
    echo '============================================================'
    echo

    if ((${#KEY_LINES[@]} == 0)); then
        warn '当前没有找到有效 SSH 公钥。'
        return 0
    fi

    for i in "${!KEY_LINES[@]}"; do
        show_one_key "$((i + 1))" "${KEY_LINES[$i]}"
    done

    echo
    echo "共 ${#KEY_LINES[@]} 把密钥。"
}

# ============================================================
# 4) 删除密钥
# ============================================================

delete_public_key() {
    local selection=''
    local selected_key=''
    local backup=''
    local tmp_file=''
    local i=''

    select_user || return 1
    collect_key_lines

    if ((${#KEY_LINES[@]} == 0)); then
        warn '当前没有找到有效 SSH 公钥。'
        return 0
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

    if [[ ! "$selection" =~ ^[0-9]+$ ]]; then
        error '请输入有效编号。'
        return 1
    fi

    if (( selection < 1 || selection > ${#KEY_LINES[@]} )); then
        error '编号超出范围。'
        return 1
    fi

    selected_key="${KEY_LINES[$((selection - 1))]}"

    echo
    warn '准备删除：'
    echo "$selected_key"
    echo

    if ! ask_yes_no '确认删除吗？'; then
        warn '已取消。'
        return 0
    fi

    if ((${#KEY_LINES[@]} == 1)); then
        warn '这是最后一把 SSH 公钥。若密码登录已关闭，删除后可能无法再次登录。'

        if ! ask_yes_no '仍然确定删除吗？'; then
            warn '已取消。'
            return 0
        fi
    fi

    backup="${AUTHORIZED_KEYS}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$AUTHORIZED_KEYS" "$backup"

    tmp_file="$(mktemp)"
    awk -v target="$selected_key" '$0 != target {print}' "$AUTHORIZED_KEYS" >"$tmp_file"
    cat "$tmp_file" >"$AUTHORIZED_KEYS"
    rm -f "$tmp_file"

    chown "$TARGET_USER:$USER_GROUP" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"

    log 'SSH 公钥删除成功。'
    echo "备份：${backup}"
}

# ============================================================
# 5) 关闭密码登录
# ============================================================

disable_password_login() {
    local backup_file=''
    local pubkey=''
    local password=''
    local keyboard=''
    local auth_methods=''
    local root_login=''

    select_user || return 1
    detect_connection_info
    collect_key_lines

    echo
    echo '============================================================'
    echo ' 关闭 SSH 密码登录'
    echo '============================================================'

    if ((${#KEY_LINES[@]} == 0)); then
        error "${TARGET_USER} 没有任何 SSH 公钥，禁止关闭密码登录。"
        return 1
    fi

    echo
    echo "用户：${TARGET_USER}"
    echo "已检测到密钥数量：${#KEY_LINES[@]}"
    echo
    warn '执行后：密码登录将关闭，只允许 SSH Public Key。'
    warn '当前 SSH 会话通常不会断开，请保持当前窗口不要关闭。'
    echo

    if ! ask_yes_no '确认继续关闭密码登录吗？'; then
        warn '已取消。'
        return 0
    fi

    backup_file="$(backup_sshd_config)"
    log "配置备份：${backup_file}"

    write_managed_block 'key-only' || return 1

    if ! "$SSHD_BIN" -t; then
        restore_sshd_config "$backup_file"
        error 'SSH 配置语法检查失败，已经恢复。'
        return 1
    fi

    pubkey="$(effective_value pubkeyauthentication)"
    password="$(effective_value passwordauthentication)"
    keyboard="$(effective_value kbdinteractiveauthentication)"
    auth_methods="$(effective_value authenticationmethods)"
    root_login="$(effective_value permitrootlogin)"

    if [[ "$pubkey" != 'yes' || "$password" != 'no' || "$keyboard" != 'no' || "$auth_methods" != 'publickey' ]]; then
        echo
        error '最终实际生效配置不符合预期：'
        echo "  PubkeyAuthentication           = ${pubkey}"
        echo "  PasswordAuthentication         = ${password}"
        echo "  KbdInteractiveAuthentication   = ${keyboard}"
        echo "  AuthenticationMethods          = ${auth_methods}"
        echo "  PermitRootLogin                = ${root_login}"
        restore_sshd_config "$backup_file"
        return 1
    fi

    if ! reload_ssh; then
        restore_sshd_config "$backup_file"
        return 1
    fi

    # reload 后再次确认
    pubkey="$(effective_value pubkeyauthentication)"
    password="$(effective_value passwordauthentication)"
    keyboard="$(effective_value kbdinteractiveauthentication)"
    auth_methods="$(effective_value authenticationmethods)"

    if [[ "$pubkey" != 'yes' || "$password" != 'no' || "$keyboard" != 'no' || "$auth_methods" != 'publickey' ]]; then
        restore_sshd_config "$backup_file"
        error 'reload 后配置验证失败，已自动恢复。'
        return 1
    fi

    echo
    echo '============================================================'
    echo ' 密码登录已临时关闭，请立即测试新连接'
    echo '============================================================'
    echo
    echo '请保持这个窗口不要关闭。'
    echo '现在另外打开一个 Terminal / Termius，用密钥登录：'
    echo
    echo "  ssh -i ~/.ssh/id_rsa -o IdentitiesOnly=yes -p ${SSH_PORT} ${TARGET_USER}@服务器IP"
    echo
    echo '成功后回来输入 y。'
    echo '如果测试失败，输入 n，脚本会恢复原 SSH 配置。'
    echo

    if ask_yes_no '新的 SSH 密钥连接是否已经成功？'; then
        echo
        log '已确认密钥登录正常，保留“仅密钥登录”配置。'
        echo "配置备份：${backup_file}"
    else
        echo
        warn '未确认新连接成功，正在恢复密码登录配置...'
        restore_sshd_config "$backup_file"
    fi
}

# ============================================================
# 6) 开启密码登录
# ============================================================

enable_password_login() {
    local backup_file=''
    local pubkey=''
    local password=''
    local auth_methods=''
    local root_login=''

    select_user || return 1
    detect_connection_info

    echo
    echo '============================================================'
    echo ' 开启 SSH 密码登录'
    echo '============================================================'
    echo
    warn '执行后将允许密码认证，同时继续允许 SSH 密钥认证。'

    if [[ "$TARGET_USER" == 'root' ]]; then
        warn '目标用户是 root：此操作会允许 root 使用密码 SSH 登录。'
    fi

    echo
    if ! ask_yes_no '确认开启密码登录吗？'; then
        warn '已取消。'
        return 0
    fi

    backup_file="$(backup_sshd_config)"
    log "配置备份：${backup_file}"

    write_managed_block 'password-on' || return 1

    if ! "$SSHD_BIN" -t; then
        restore_sshd_config "$backup_file"
        error 'SSH 配置语法检查失败，已经恢复。'
        return 1
    fi

    pubkey="$(effective_value pubkeyauthentication)"
    password="$(effective_value passwordauthentication)"
    auth_methods="$(effective_value authenticationmethods)"
    root_login="$(effective_value permitrootlogin)"

    if [[ "$pubkey" != 'yes' || "$password" != 'yes' || "$auth_methods" != 'any' ]]; then
        echo
        error '实际生效配置不符合预期：'
        echo "  PubkeyAuthentication   = ${pubkey}"
        echo "  PasswordAuthentication = ${password}"
        echo "  AuthenticationMethods  = ${auth_methods}"
        echo "  PermitRootLogin         = ${root_login}"
        restore_sshd_config "$backup_file"
        return 1
    fi

    if ! reload_ssh; then
        restore_sshd_config "$backup_file"
        return 1
    fi

    log '密码登录已开启，同时保留 SSH 密钥登录。'
}

# ============================================================
# 主菜单
# ============================================================

print_menu() {
    clear 2>/dev/null || true

    echo '============================================================'
    echo ' SSH Key Manager - Debian'
    echo '============================================================'
    echo
    echo '1) 初始化 / 修复 SSH 密钥登录（不关闭密码）'
    echo '2) 添加新的 SSH 公钥'
    echo '3) 查看当前 SSH 公钥'
    echo '4) 删除 SSH 公钥'
    echo '5) 关闭密码登录（仅允许 SSH 密钥）'
    echo '6) 开启密码登录（密码 + 密钥）'
    echo '7) 查看 SSH 实际生效状态'
    echo '0) 退出脚本'
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
                setup_key_login || true
                pause_menu
                ;;
            2)
                add_public_key || true
                pause_menu
                ;;
            3)
                list_public_keys || true
                pause_menu
                ;;
            4)
                delete_public_key || true
                pause_menu
                ;;
            5)
                disable_password_login || true
                pause_menu
                ;;
            6)
                enable_password_login || true
                pause_menu
                ;;
            7)
                show_auth_status || true
                pause_menu
                ;;
            0)
                echo
                log '已退出 SSH Key Manager。'
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
