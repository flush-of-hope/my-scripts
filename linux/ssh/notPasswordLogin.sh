#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

MANAGED_BEGIN='# BEGIN MANAGED KEY-ONLY SSH AUTH'
MANAGED_END='# END MANAGED KEY-ONLY SSH AUTH'
SSHD_CONFIG='/etc/ssh/sshd_config'
TTY='/dev/tty'

# ============================================================
# 输出函数
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

ask_yes_no() {
    local prompt="$1"
    local ans=''

    printf '%s [y/N]: ' "$prompt" >"$TTY"
    IFS= read -r ans <"$TTY" || return 1

    [[ "$ans" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}


# ============================================================
# 基础检查
# ============================================================

check_environment() {

    [[ $EUID -eq 0 ]] ||
        die '请使用 root 权限运行，例如：sudo bash ssh-key-manager.sh'

    [[ -r "$TTY" && -w "$TTY" ]] ||
        die '需要交互式终端。'

    [[ -f /etc/debian_version ]] ||
        die '当前脚本仅支持 Debian / Ubuntu。'

    [[ -f "$SSHD_CONFIG" ]] ||
        die "未找到 $SSHD_CONFIG"


    SSHD_BIN="$(command -v sshd || true)"

    if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
        SSHD_BIN='/usr/sbin/sshd'
    fi

    [[ -x "$SSHD_BIN" ]] ||
        die '未找到 sshd，请先安装 openssh-server。'


    if ! command -v ssh-keygen >/dev/null 2>&1; then

        log '未找到 ssh-keygen，正在自动安装 openssh-client...'

        apt-get update

        DEBIAN_FRONTEND=noninteractive \
            apt-get install -y openssh-client
    fi


    if systemctl list-unit-files --type=service 2>/dev/null |
        grep -q '^ssh\.service'; then

        SSH_SERVICE='ssh'

    elif systemctl list-unit-files --type=service 2>/dev/null |
        grep -q '^sshd\.service'; then

        SSH_SERVICE='sshd'

    else

        die '无法找到 ssh.service 或 sshd.service。'
    fi
}


# ============================================================
# 选择目标用户
# ============================================================

select_user() {

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != 'root' ]]; then
        DEFAULT_USER="$SUDO_USER"
    else
        DEFAULT_USER='root'
    fi

    echo
    printf '请输入 SSH 用户 [默认: %s]: ' "$DEFAULT_USER" >"$TTY"

    IFS= read -r TARGET_USER <"$TTY"

    TARGET_USER="${TARGET_USER:-$DEFAULT_USER}"

    id "$TARGET_USER" >/dev/null 2>&1 ||
        die "用户不存在：$TARGET_USER"


    USER_HOME="$(
        getent passwd "$TARGET_USER" |
            cut -d: -f6
    )"

    USER_GROUP="$(id -gn "$TARGET_USER")"


    [[ -n "$USER_HOME" && -d "$USER_HOME" ]] ||
        die "无法确定 $TARGET_USER 的 HOME。"


    SSH_DIR="${USER_HOME}/.ssh"

    AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"


    install \
        -d \
        -m 700 \
        -o "$TARGET_USER" \
        -g "$USER_GROUP" \
        "$SSH_DIR"


    touch "$AUTHORIZED_KEYS"

    chown \
        "$TARGET_USER:$USER_GROUP" \
        "$AUTHORIZED_KEYS"

    chmod \
        600 \
        "$AUTHORIZED_KEYS"
}


# ============================================================
# 输入并校验 SSH 公钥
# ============================================================

read_public_key() {

    local temp_key

    echo
    echo '请粘贴 SSH 公钥完整一行，例如：'
    echo
    echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...'
    echo
    echo '或：'
    echo
    echo 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ...'
    echo

    printf 'SSH 公钥: ' >"$TTY"

    IFS= read -r SSH_PUBLIC_KEY <"$TTY"

    SSH_PUBLIC_KEY="$(
        printf '%s' "$SSH_PUBLIC_KEY" |
            sed '
                s/^[[:space:]]*//
                s/[[:space:]]*$//
            '
    )"


    [[ -n "$SSH_PUBLIC_KEY" ]] ||
        die '公钥不能为空。'


    temp_key="$(mktemp)"

    printf '%s\n' \
        "$SSH_PUBLIC_KEY" \
        >"$temp_key"


    if ! ssh-keygen \
        -l \
        -f "$temp_key" \
        >/dev/null 2>&1; then

        rm -f "$temp_key"

        die '输入的不是有效 SSH 公钥，请不要输入私钥。'
    fi


    log 'SSH 公钥校验成功：'

    ssh-keygen \
        -l \
        -f "$temp_key"


    rm -f "$temp_key"


    KEY_TYPE="$(
        awk '{print $1}' <<<"$SSH_PUBLIC_KEY"
    )"

    KEY_DATA="$(
        awk '{print $2}' <<<"$SSH_PUBLIC_KEY"
    )"
}


# ============================================================
# 添加 SSH 公钥
# ============================================================

add_public_key() {

    local comment=''
    local final_key=''

    select_user
    read_public_key


    # --------------------------------------------------------
    # 判断是否已经存在
    # --------------------------------------------------------

    if awk \
        -v type="$KEY_TYPE" \
        -v key="$KEY_DATA" \
        '
        $1==type && $2==key {
            found=1
        }

        END {
            exit !found
        }
        ' "$AUTHORIZED_KEYS"; then

        echo
        warn '这把 SSH 公钥已经存在。'
        echo

        return
    fi


    # --------------------------------------------------------
    # 用户备注
    # --------------------------------------------------------

    echo
    printf '给这台电脑写个备注 [可留空，例如 MacBook-Pro]: ' >"$TTY"

    IFS= read -r comment <"$TTY"

    comment="$(
        printf '%s' "$comment" |
            tr '\r\n\t' '   ' |
            sed 's/[[:space:]][[:space:]]*/ /g'
    )"


    if [[ -n "$comment" ]]; then

        final_key="${KEY_TYPE} ${KEY_DATA} ${comment}"

    else

        final_key="$SSH_PUBLIC_KEY"
    fi


    # --------------------------------------------------------
    # 写入 authorized_keys
    # --------------------------------------------------------

    printf '%s\n' \
        "$final_key" \
        >>"$AUTHORIZED_KEYS"


    chown \
        "$TARGET_USER:$USER_GROUP" \
        "$AUTHORIZED_KEYS"

    chmod \
        600 \
        "$AUTHORIZED_KEYS"


    echo
    log '新 SSH 公钥添加成功。'

    echo
    echo "用户：${TARGET_USER}"
    echo "文件：${AUTHORIZED_KEYS}"

    if [[ -n "$comment" ]]; then
        echo "备注：${comment}"
    fi

    echo
}


# ============================================================
# 查看 SSH 公钥
# ============================================================

list_public_keys() {

    select_user

    echo
    echo '============================================================'
    echo " ${TARGET_USER} 当前 SSH 公钥"
    echo '============================================================'
    echo


    if [[ ! -s "$AUTHORIZED_KEYS" ]]; then

        warn '当前 authorized_keys 为空。'

        return
    fi


    local number=0
    local line=''
    local temp_key=''
    local fingerprint=''
    local comment=''


    while IFS= read -r line; do

        [[ -z "$line" ]] && continue

        [[ "$line" =~ ^[[:space:]]*# ]] && continue


        if ! [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]]; then
            continue
        fi


        number=$((number + 1))

        temp_key="$(mktemp)"

        printf '%s\n' \
            "$line" \
            >"$temp_key"


        fingerprint="$(
            ssh-keygen \
                -l \
                -f "$temp_key" \
                2>/dev/null ||
            echo '无法识别'
        )"


        rm -f "$temp_key"


        comment="$(
            awk '
                {
                    $1=""
                    $2=""

                    sub(/^[[:space:]]+/, "")

                    print
                }
            ' <<<"$line"
        )"


        echo "[$number]"

        if [[ -n "$comment" ]]; then
            echo "备注: ${comment}"
        else
            echo '备注: 无'
        fi

        echo "信息: ${fingerprint}"

        echo
    done <"$AUTHORIZED_KEYS"


    if (( number == 0 )); then

        warn '没有找到有效的 SSH 公钥。'
    fi
}


# ============================================================
# 删除 SSH 公钥
# ============================================================

delete_public_key() {

    select_user


    if [[ ! -s "$AUTHORIZED_KEYS" ]]; then

        warn 'authorized_keys 当前为空。'

        return
    fi


    local -a keys=()
    local line=''


    while IFS= read -r line; do

        [[ -z "$line" ]] && continue

        [[ "$line" =~ ^[[:space:]]*# ]] && continue


        if [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]]; then

            keys+=("$line")
        fi

    done <"$AUTHORIZED_KEYS"


    if ((${#keys[@]} == 0)); then

        warn '没有找到有效 SSH 公钥。'

        return
    fi


    echo
    echo '============================================================'
    echo ' 当前 SSH 公钥'
    echo '============================================================'
    echo


    local i
    local tmp=''
    local info=''
    local comment=''


    for i in "${!keys[@]}"; do

        tmp="$(mktemp)"

        printf '%s\n' \
            "${keys[$i]}" \
            >"$tmp"


        info="$(
            ssh-keygen \
                -l \
                -f "$tmp" \
                2>/dev/null ||
            echo '无法识别'
        )"


        rm -f "$tmp"


        comment="$(
            awk '
                {
                    $1=""
                    $2=""

                    sub(/^[[:space:]]+/, "")

                    print
                }
            ' <<<"${keys[$i]}"
        )"


        echo "$((i + 1))) ${comment:-无备注}"

        echo "   ${info}"

        echo
    done


    printf '请输入需要删除的编号: ' >"$TTY"

    local selection=''

    IFS= read -r selection <"$TTY"


    [[ "$selection" =~ ^[0-9]+$ ]] ||
        die '请输入有效编号。'


    (( selection >= 1 && selection <= ${#keys[@]} )) ||
        die '编号超出范围。'


    local selected_key="${keys[$((selection - 1))]}"


    echo
    warn '准备删除以下公钥：'
    echo
    echo "$selected_key"
    echo


    if ! ask_yes_no '确认删除吗？'; then

        echo
        echo '已取消。'

        return
    fi


    # --------------------------------------------------------
    # 至少保留一把密钥
    # --------------------------------------------------------

    if ((${#keys[@]} == 1)); then

        echo
        warn '当前这是最后一把 SSH 公钥。'

        if ! ask_yes_no \
            '删除后可能无法通过 SSH 登录，仍然确定删除吗？'; then

            echo
            echo '已取消。'

            return
        fi
    fi


    local backup

    backup="${AUTHORIZED_KEYS}.bak.$(date +%Y%m%d-%H%M%S)"


    cp -a \
        "$AUTHORIZED_KEYS" \
        "$backup"


    local tmp_file

    tmp_file="$(mktemp)"


    awk \
        -v target="$selected_key" \
        '
        $0 != target {
            print
        }
        ' "$AUTHORIZED_KEYS" \
        >"$tmp_file"


    cat \
        "$tmp_file" \
        >"$AUTHORIZED_KEYS"


    rm -f \
        "$tmp_file"


    chown \
        "$TARGET_USER:$USER_GROUP" \
        "$AUTHORIZED_KEYS"

    chmod \
        600 \
        "$AUTHORIZED_KEYS"


    echo
    log 'SSH 公钥删除成功。'

    echo "备份：${backup}"
}


# ============================================================
# 当前 SSH 信息
# ============================================================

detect_connection_info() {

    CLIENT_IP=''
    SERVER_IP=''
    SSH_PORT=''


    if [[ -n "${SSH_CONNECTION:-}" ]]; then

        CLIENT_IP="$(
            awk '{print $1}' <<<"$SSH_CONNECTION"
        )"

        SERVER_IP="$(
            awk '{print $3}' <<<"$SSH_CONNECTION"
        )"

        SSH_PORT="$(
            awk '{print $4}' <<<"$SSH_CONNECTION"
        )"
    fi


    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then

        SSH_PORT="$(
            "$SSHD_BIN" -T 2>/dev/null |
                awk '$1=="port" {
                    print $2
                    exit
                }'
        )"
    fi


    SSH_PORT="${SSH_PORT:-22}"
}


# ============================================================
# sshd 有效配置
# ============================================================

effective_config() {

    if [[ -n "$CLIENT_IP" &&
          -n "$SERVER_IP" &&
          "$SSH_PORT" =~ ^[0-9]+$ ]]; then

        "$SSHD_BIN" \
            -T \
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
        awk \
            -v k="$key" \
            '
            $1==k {
                $1=""

                sub(/^[[:space:]]+/, "")

                print

                exit
            }
            '
}


# ============================================================
# 写 SSH 顶部管理块
# ============================================================

write_managed_block() {

    local mode="$1"

    local clean
    local tmp

    clean="$(mktemp)"
    tmp="$(mktemp)"


    awk \
        -v begin="$MANAGED_BEGIN" \
        -v end="$MANAGED_END" \
        '
        $0 == begin {
            skip=1
            next
        }

        $0 == end {
            skip=0
            next
        }

        !skip {
            print
        }
        ' "$SSHD_CONFIG" \
        >"$clean"


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

            echo 'PermitRootLogin prohibit-password'
        fi


        echo "$MANAGED_END"

        echo

        cat "$clean"

    } >"$tmp"


    chown \
        "$(stat -c '%u:%g' "$SSHD_CONFIG")" \
        "$tmp"

    chmod \
        "$(stat -c '%a' "$SSHD_CONFIG")" \
        "$tmp"


    mv \
        -f \
        "$tmp" \
        "$SSHD_CONFIG"


    rm -f \
        "$clean"
}


# ============================================================
# 初始化仅密钥登录
# ============================================================

setup_key_only() {

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


    # 添加第一把公钥
    if ! awk \
        -v type="$KEY_TYPE" \
        -v key="$KEY_DATA" \
        '
        $1==type && $2==key {
            found=1
        }

        END {
            exit !found
        }
        ' "$AUTHORIZED_KEYS"; then


        echo
        printf '这台电脑备注 [例如 MacBook-Pro]: ' >"$TTY"

        local key_comment=''

        IFS= read -r key_comment <"$TTY"


        if [[ -n "$key_comment" ]]; then

            printf '%s %s %s\n' \
                "$KEY_TYPE" \
                "$KEY_DATA" \
                "$key_comment" \
                >>"$AUTHORIZED_KEYS"

        else

            printf '%s\n' \
                "$SSH_PUBLIC_KEY" \
                >>"$AUTHORIZED_KEYS"
        fi
    fi


    chown \
        "$TARGET_USER:$USER_GROUP" \
        "$AUTHORIZED_KEYS"

    chmod \
        600 \
        "$AUTHORIZED_KEYS"


    # --------------------------------------------------------
    # 配置备份
    # --------------------------------------------------------

    BACKUP_DIR="/root/ssh-key-auth-backup-$(date +%Y%m%d-%H%M%S)"

    mkdir -p \
        "$BACKUP_DIR"

    BACKUP_FILE="${BACKUP_DIR}/sshd_config"


    cp -a \
        "$SSHD_CONFIG" \
        "$BACKUP_FILE"


    if [[ -d /etc/ssh/sshd_config.d ]]; then

        cp \
            -a \
            /etc/ssh/sshd_config.d \
            "$BACKUP_DIR/" \
            2>/dev/null || true
    fi


    # --------------------------------------------------------
    # 第一阶段
    #
    # 开启 publickey，但暂时保留密码
    # --------------------------------------------------------

    log '开启 SSH Public Key 登录，暂时保留密码登录...'


    write_managed_block 'enable-key'


    if ! "$SSHD_BIN" -t; then

        cp \
            -a \
            "$BACKUP_FILE" \
            "$SSHD_CONFIG"

        die 'SSH 配置检查失败，已经恢复。'
    fi


    if [[ "$(effective_value pubkeyauthentication)" != 'yes' ]]; then

        cp \
            -a \
            "$BACKUP_FILE" \
            "$SSHD_CONFIG"

        die 'PubkeyAuthentication 没有实际生效，已经恢复。'
    fi


    systemctl reload \
        "$SSH_SERVICE"


    echo
    echo '============================================================'
    echo ' 公钥已经启用'
    echo '============================================================'
    echo
    echo '目前密码登录仍然保留。'
    echo
    echo '请保持当前 SSH 窗口不要关闭。'
    echo
    echo '另开一个窗口测试：'
    echo
    echo "ssh -i ~/.ssh/id_rsa -o IdentitiesOnly=yes -p ${SSH_PORT} ${TARGET_USER}@服务器IP"
    echo


    if ! ask_yes_no \
        '已经确认新的 SSH 窗口使用密钥登录成功了吗？'; then

        echo
        warn '未关闭密码登录。'
        echo

        return
    fi


    # --------------------------------------------------------
    # 正式仅密钥
    # --------------------------------------------------------

    log '关闭 SSH 密码认证...'


    write_managed_block \
        'key-only'


    if ! "$SSHD_BIN" -t; then

        cp \
            -a \
            "$BACKUP_FILE" \
            "$SSHD_CONFIG"

        systemctl reload \
            "$SSH_SERVICE" \
            || true

        die 'SSH Key Only 配置检查失败，已恢复。'
    fi


    local pubkey
    local password
    local keyboard
    local auth_methods

    pubkey="$(
        effective_value pubkeyauthentication
    )"

    password="$(
        effective_value passwordauthentication
    )"

    keyboard="$(
        effective_value kbdinteractiveauthentication
    )"

    auth_methods="$(
        effective_value authenticationmethods
    )"


    if [[ "$pubkey" != 'yes' ||
          "$password" != 'no' ||
          "$keyboard" != 'no' ||
          "$auth_methods" != 'publickey' ]]; then

        cp \
            -a \
            "$BACKUP_FILE" \
            "$SSHD_CONFIG"

        systemctl reload \
            "$SSH_SERVICE" \
            || true

        die '最终 SSH 配置没有达到预期，已经自动恢复。'
    fi


    systemctl reload \
        "$SSH_SERVICE"


    echo
    echo '============================================================'
    echo ' SSH Key Only 配置完成'
    echo '============================================================'
    echo
    echo 'PubkeyAuthentication:'
    echo "  $pubkey"

    echo
    echo 'PasswordAuthentication:'
    echo "  $password"

    echo
    echo 'AuthenticationMethods:'
    echo "  $auth_methods"

    echo
    echo '以后增加电脑时直接重新运行本脚本：'
    echo
    echo '  选择 2：添加新的 SSH 公钥'
    echo
}


# ============================================================
# 主菜单
# ============================================================

show_menu() {

    clear 2>/dev/null || true

    echo '============================================================'
    echo ' SSH Key Manager'
    echo '============================================================'
    echo
    echo '1) 首次配置：仅允许 SSH 密钥登录'
    echo
    echo '2) 添加新的 SSH 公钥'
    echo
    echo '3) 查看当前 SSH 公钥'
    echo
    echo '4) 删除 SSH 公钥'
    echo
    echo '0) 退出'
    echo

    printf '请选择 [0-4]: ' >"$TTY"

    local choice

    IFS= read -r choice <"$TTY"


    case "$choice" in

        1)
            setup_key_only
            ;;

        2)
            add_public_key
            ;;

        3)
            list_public_keys
            ;;

        4)
            delete_public_key
            ;;

        0)
            exit 0
            ;;

        *)
            die '无效选择。'
            ;;
    esac
}


# ============================================================
# MAIN
# ============================================================

check_environment

show_menu
