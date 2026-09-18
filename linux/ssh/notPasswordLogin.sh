(
set -Eeuo pipefail
IFS=$'\n\t'

echo "============================================================"
echo " SSH 密钥登录配置"
echo " 关闭密码登录，仅允许 SSH Public Key"
echo "============================================================"
echo

# ============================================================
# 基础检查
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 请使用 root 权限执行"
    echo
    echo "例如："
    echo "  sudo bash script.sh"
    exit 1
fi

if [ ! -f /etc/debian_version ]; then
    echo "[ERROR] 当前脚本仅支持 Debian / Ubuntu"
    exit 1
fi

if ! command -v sshd >/dev/null 2>&1; then
    echo "[ERROR] 未找到 sshd"
    exit 1
fi

if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "[INFO] 未找到 ssh-keygen，正在安装 openssh-client..."

    apt-get update
    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y openssh-client
fi


# ============================================================
# 确定目标用户
# ============================================================

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    DEFAULT_USER="$SUDO_USER"
else
    DEFAULT_USER="root"
fi

echo "检测到默认 SSH 用户：${DEFAULT_USER}"
echo

printf "请输入需要配置密钥登录的用户名 [默认: %s]: " "$DEFAULT_USER"
read -r TARGET_USER </dev/tty

TARGET_USER="${TARGET_USER:-$DEFAULT_USER}"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "[ERROR] 用户不存在：${TARGET_USER}"
    exit 1
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    echo "[ERROR] 无法确定用户 HOME：${TARGET_USER}"
    exit 1
fi

USER_GROUP="$(id -gn "$TARGET_USER")"

echo
echo "目标用户：${TARGET_USER}"
echo "HOME：${USER_HOME}"
echo


# ============================================================
# 输入 SSH 公钥
# ============================================================

echo "请粘贴 SSH 公钥完整一行。"
echo
echo "例如："
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... your@email"
echo
echo "或者："
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ... comment"
echo

printf "SSH 公钥: "
IFS= read -r SSH_PUBLIC_KEY </dev/tty

SSH_PUBLIC_KEY="$(
    printf '%s' "$SSH_PUBLIC_KEY" |
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
)"

if [ -z "$SSH_PUBLIC_KEY" ]; then
    echo "[ERROR] 公钥不能为空"
    exit 1
fi


# ============================================================
# 校验公钥
# ============================================================

TMP_KEY="$(mktemp)"
trap 'rm -f "$TMP_KEY"' EXIT

printf '%s\n' "$SSH_PUBLIC_KEY" > "$TMP_KEY"

if ! ssh-keygen -l -f "$TMP_KEY" >/dev/null 2>&1; then
    echo
    echo "[ERROR] 你输入的内容不是有效的 SSH 公钥"
    echo
    echo "请确认输入的是类似："
    echo
    echo "ssh-ed25519 AAAA..."
    echo
    echo "而不是私钥："
    echo
    echo "-----BEGIN OPENSSH PRIVATE KEY-----"
    exit 1
fi

echo
echo "[OK] SSH 公钥校验成功"

echo
echo "密钥信息："
ssh-keygen -l -f "$TMP_KEY"
echo


# ============================================================
# 创建 .ssh
# ============================================================

SSH_DIR="${USER_HOME}/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "$SSH_DIR"

touch "$AUTHORIZED_KEYS"

chown "$TARGET_USER:$USER_GROUP" "$SSH_DIR"
chown "$TARGET_USER:$USER_GROUP" "$AUTHORIZED_KEYS"

chmod 700 "$SSH_DIR"
chmod 600 "$AUTHORIZED_KEYS"


# ============================================================
# 防止重复添加密钥
# ============================================================

INPUT_KEY_DATA="$(
    awk '{print $2}' <<< "$SSH_PUBLIC_KEY"
)"

KEY_EXISTS=0

while IFS= read -r line; do

    case "$line" in
        ssh-*|ecdsa-*|sk-*)
            EXISTING_KEY_DATA="$(
                awk '{print $2}' <<< "$line" 2>/dev/null || true
            )"

            if [ "$EXISTING_KEY_DATA" = "$INPUT_KEY_DATA" ]; then
                KEY_EXISTS=1
                break
            fi
            ;;
    esac

done < "$AUTHORIZED_KEYS"


if [ "$KEY_EXISTS" -eq 1 ]; then

    echo "[INFO] 此公钥已经存在于："
    echo "       ${AUTHORIZED_KEYS}"

else

    echo "$SSH_PUBLIC_KEY" >> "$AUTHORIZED_KEYS"

    chown "$TARGET_USER:$USER_GROUP" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"

    echo "[OK] 公钥已经添加到："
    echo "     ${AUTHORIZED_KEYS}"
fi


# ============================================================
# 再次检查权限
# ============================================================

chmod 700 "$SSH_DIR"
chmod 600 "$AUTHORIZED_KEYS"

chown -R "$TARGET_USER:$USER_GROUP" "$SSH_DIR"


# ============================================================
# 检测当前 SSH 端口
# ============================================================

SSH_PORT=""

if [ -n "${SSH_CONNECTION:-}" ]; then
    SSH_PORT="$(
        awk '{print $4}' <<< "$SSH_CONNECTION" 2>/dev/null || true
    )"
fi

if ! [[ "${SSH_PORT:-}" =~ ^[0-9]+$ ]]; then

    SSH_PORT="$(
        sshd -T 2>/dev/null |
            awk '$1=="port"{print $2; exit}'
    )"
fi

SSH_PORT="${SSH_PORT:-22}"


# ============================================================
# 第一步：先要求用户测试密钥
# ============================================================

echo
echo "============================================================"
echo " 公钥已经安装"
echo "============================================================"
echo
echo "现在暂时【没有关闭密码登录】。"
echo
echo "请保持当前 SSH 窗口不要关闭。"
echo
echo "请另外打开一个新的终端窗口，用 SSH 密钥重新登录："
echo
echo "  ssh -p ${SSH_PORT} ${TARGET_USER}@服务器IP"
echo
echo "如果私钥不是默认路径，例如："
echo
echo "  ssh -i ~/.ssh/id_ed25519 -p ${SSH_PORT} ${TARGET_USER}@服务器IP"
echo
echo "确认新窗口可以正常使用密钥登录以后，再回来继续。"
echo

printf "是否已经确认密钥可以正常登录？[y/N]: "
read -r CONFIRM </dev/tty

case "$CONFIRM" in
    y|Y|yes|YES|Yes)
        ;;
    *)
        echo
        echo "[INFO] 未关闭密码登录。"
        echo "[INFO] 公钥已经安装，可以稍后重新运行本脚本。"
        exit 0
        ;;
esac


# ============================================================
# SSH 配置备份
# ============================================================

BACKUP_DIR="/root/ssh-config-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

cp -a /etc/ssh/sshd_config "$BACKUP_DIR/"

if [ -d /etc/ssh/sshd_config.d ]; then
    cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/"
fi

echo
echo "[OK] SSH 配置已经备份："
echo "     ${BACKUP_DIR}"


# ============================================================
# 判断是否支持 sshd_config.d
# ============================================================

DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN_FILE="${DROPIN_DIR}/99-key-only.conf"

USE_DROPIN=0

if grep -Eiq \
    '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
    /etc/ssh/sshd_config; then

    USE_DROPIN=1
fi


# ============================================================
# 创建仅密钥登录配置
# ============================================================

KEY_ONLY_CONFIG='
# Managed by SSH key-only setup script

PubkeyAuthentication yes

PasswordAuthentication no

KbdInteractiveAuthentication no

ChallengeResponseAuthentication no

# Root 可以使用密钥，但禁止密码
PermitRootLogin prohibit-password
'


if [ "$USE_DROPIN" -eq 1 ]; then

    mkdir -p "$DROPIN_DIR"

    printf '%s\n' "$KEY_ONLY_CONFIG" > "$DROPIN_FILE"

    chmod 644 "$DROPIN_FILE"

    echo
    echo "[OK] 已创建："
    echo "     ${DROPIN_FILE}"

else

    echo
    echo "[INFO] 当前 sshd_config 未启用 sshd_config.d"
    echo "[INFO] 将直接追加到 /etc/ssh/sshd_config"

    cat >> /etc/ssh/sshd_config <<'EOF'


# ============================================================
# SSH key-only authentication
# Managed by setup script
# ============================================================

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password

EOF

fi


# ============================================================
# 配置语法检查
# ============================================================

echo
echo "[INFO] 检查 SSH 配置..."

if ! sshd -t; then

    echo
    echo "[ERROR] SSH 配置检查失败"
    echo "[INFO] 正在恢复配置..."

    cp -a "$BACKUP_DIR/sshd_config" /etc/ssh/sshd_config

    if [ -d "$BACKUP_DIR/sshd_config.d" ]; then

        rm -rf /etc/ssh/sshd_config.d
        cp -a "$BACKUP_DIR/sshd_config.d" /etc/ssh/

    elif [ -f "$DROPIN_FILE" ]; then

        rm -f "$DROPIN_FILE"

    fi

    echo "[OK] SSH 配置已恢复"

    exit 1
fi

echo "[OK] SSH 配置语法正常"


# ============================================================
# 检查最终 sshd 生效配置
# ============================================================

echo
echo "============================================================"
echo " 最终认证配置"
echo "============================================================"

sshd -T 2>/dev/null |
    grep -E \
        '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitrootlogin) ' \
    || true

echo


# ============================================================
# 重载 SSH
# ============================================================

SSH_SERVICE=""

if systemctl list-unit-files 2>/dev/null |
    grep -q '^ssh\.service'; then

    SSH_SERVICE="ssh"

elif systemctl list-unit-files 2>/dev/null |
    grep -q '^sshd\.service'; then

    SSH_SERVICE="sshd"

else

    echo "[ERROR] 无法确定 SSH systemd 服务名称"
    exit 1
fi

echo "[INFO] Reload SSH 服务..."

systemctl reload "$SSH_SERVICE"

sleep 1

if ! systemctl is-active --quiet "$SSH_SERVICE"; then

    echo "[ERROR] SSH 服务异常"
    echo "[INFO] 正在恢复原配置..."

    cp -a "$BACKUP_DIR/sshd_config" /etc/ssh/sshd_config

    if [ -d "$BACKUP_DIR/sshd_config.d" ]; then

        rm -rf /etc/ssh/sshd_config.d
        cp -a "$BACKUP_DIR/sshd_config.d" /etc/ssh/

    fi

    systemctl restart "$SSH_SERVICE"

    exit 1
fi


# ============================================================
# 完成
# ============================================================

echo
echo "============================================================"
echo " 配置完成"
echo "============================================================"
echo
echo "用户："
echo "  ${TARGET_USER}"
echo
echo "SSH 端口："
echo "  ${SSH_PORT}"
echo
echo "认证方式："
echo "  SSH Public Key     允许"
echo "  Password           禁止"
echo "  Keyboard Interactive 禁止"
echo "  Challenge Response 禁止"
echo
echo "Root："
echo "  密钥登录           允许"
echo "  密码登录           禁止"
echo
echo "authorized_keys："
echo "  ${AUTHORIZED_KEYS}"
echo
echo "SSH 配置备份："
echo "  ${BACKUP_DIR}"
echo
echo "当前 SSH 窗口不会因为 reload 自动断开。"
echo
echo "建议现在再次新开一个 SSH 窗口确认仍可登录，"
echo "确认没问题后再关闭当前窗口。"
echo
)
