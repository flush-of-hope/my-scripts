(
set -e

echo "========================================"
echo " Debian VPS Tuning 一键安装"
echo "========================================"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 请使用 root 用户运行"
    exit 1
fi

if [ ! -f /etc/debian_version ]; then
    echo "[ERROR] 仅支持 Debian / Ubuntu"
    exit 1
fi

packages=""

command -v jq >/dev/null 2>&1 || packages="$packages jq"
command -v curl >/dev/null 2>&1 || packages="$packages curl"
command -v sha256sum >/dev/null 2>&1 || packages="$packages coreutils"

if [ -n "$packages" ]; then
    echo "[INFO] 缺少依赖:$packages"
    echo "[INFO] 正在自动安装..."

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y $packages
fi

echo "[OK] jq: $(jq --version)"
echo "[OK] curl: $(curl --version | head -n1)"

dvt_tmp="$(mktemp -d)"
trap 'rm -rf -- "$dvt_tmp"' EXIT

echo "[INFO] 下载 debian-vps-tuning v0.1.0-rc.11..."

curl \
    --fail \
    --show-error \
    --silent \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 15 \
    --max-time 120 \
    -o "$dvt_tmp/debian-vps-tuning.sh" \
    "https://github.com/alieismy/debian-vps-tuning/releases/download/v0.1.0-rc.11/debian-vps-tuning.sh"

echo "[INFO] 校验 SHA256..."

printf '%s  %s\n' \
    '24b1b9a15ad0c50834ef450f98a6a2d25b95bd93d89d22c00422f77e38b4ad96' \
    "$dvt_tmp/debian-vps-tuning.sh" \
    | sha256sum -c -

echo "[OK] 校验通过"
echo "[INFO] 开始执行..."

bash "$dvt_tmp/debian-vps-tuning.sh"
)
