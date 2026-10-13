#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SETUP_VERSION='2026-10-13.3'
readonly TTY='/dev/tty'
readonly RAW_BASE='https://raw.githubusercontent.com/flush-of-hope/my-scripts/main'
readonly LAUNCHER_PATH='/usr/local/bin/vps-setup'

readonly SCRIPT_TUNING='https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh'
readonly SCRIPT_DIAGNOSTICS='https://raw.githubusercontent.com/xykt/ScriptMenu/main/menu.sh'
readonly SCRIPT_SSH='linux/ssh/notPasswordLogin.sh'
readonly SCRIPT_3XUI='3x-ui/install-3x-ui.sh'
readonly SCRIPT_CLOUDFLARED='cloudflare/cloudflared-auto-update-installer.sh'
readonly SCRIPT_CROWDSEC='CrowdSec/install-crowdsec-guard.sh'
readonly SCRIPT_GUARD_INIT='CrowdSec/init-guard.sh'
readonly SCRIPT_PORT_MANAGER='CrowdSec/manage-ports.sh'

green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
reset='\033[0m'

log() { printf "${green}[+]${reset} %s\n" "$*"; }
warn() { printf "${yellow}[!]${reset} %s\n" "$*"; }
error() { printf "${red}[x]${reset} %s\n" "$*" >&2; }
fatal() { error "$*"; exit 1; }

ask_yes_no() {
    local prompt="$1" answer=''
    printf '%s [y/N]: ' "$prompt" >"$TTY"
    IFS= read -r answer <"$TTY" || return 1
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

pause_menu() {
    echo
    printf '按 Enter 返回主菜单...' >"$TTY"
    IFS= read -r _ <"$TTY" || true
}

check_environment() {
    [[ $EUID -eq 0 ]] || fatal '请使用 root 权限运行。'
    [[ "${1:-}" == '--install' || ( -r "$TTY" && -w "$TTY" ) ]] || fatal '需要在交互式终端中运行。'
    [[ -f /etc/debian_version ]] || fatal '此入口脚本仅支持 Debian / Ubuntu。'

    if ! command -v curl >/dev/null 2>&1; then
        log '未检测到 curl，正在安装 curl 和 ca-certificates...'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
    fi
}

run_remote_script() {
    local path="$1"
    shift || true

    local cache_buster url tmp rc=0
    cache_buster="$(date +%s%N 2>/dev/null || date +%s)"
    if [[ "$path" == https://* ]]; then
        url="${path}?cb=${cache_buster}"
    else
        url="${RAW_BASE}/${path}?cb=${cache_buster}"
    fi
    tmp="$(mktemp -t new-machine-script.XXXXXX)"

    log "下载：${path}"

    if ! curl \
        --fail \
        --show-error \
        --silent \
        --location \
        --header 'Cache-Control: no-cache' \
        --header 'Pragma: no-cache' \
        --proto '=https' \
        --proto-redir '=https' \
        --connect-timeout 15 \
        --max-time 120 \
        -o "$tmp" \
        "$url"; then
        rm -f -- "$tmp"
        error "下载失败：${path}"
        return 1
    fi

    [[ -s "$tmp" ]] || {
        rm -f -- "$tmp"
        error "下载文件为空：${path}"
        return 1
    }

    echo
    log "开始执行：${path}"
    echo

    set +e
    bash "$tmp" "$@"
    rc=$?
    set -e

    rm -f -- "$tmp"

    if (( rc == 0 )); then
        log "执行完成：${path}"
    else
        error "脚本执行失败：${path}，退出码 ${rc}"
    fi

    return "$rc"
}

install_launcher() {
    local tmp

    if ! mkdir -p -- "${LAUNCHER_PATH%/*}"; then
        error '无法创建快捷命令安装目录。'
        return 1
    fi
    tmp="$(mktemp "${LAUNCHER_PATH%/*}/.vps-setup.XXXXXX")" || {
        error '无法创建快捷命令临时文件。'
        return 1
    }

    if ! cat >"$tmp" <<'LAUNCHER'
#!/usr/bin/env bash
# Managed by flush-of-hope/my-scripts/new-machine/setup.sh
set -Eeuo pipefail

readonly SCRIPT_URL='https://raw.githubusercontent.com/flush-of-hope/my-scripts/main/new-machine/setup.sh'

if [[ $EUID -ne 0 ]]; then
    echo '请使用 root 运行，或执行 sudo vps-setup。' >&2
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    echo '未检测到 curl，请先安装 curl 和 ca-certificates。' >&2
    exit 1
fi

tmp="$(mktemp -t vps-setup.XXXXXX)"
trap 'rm -f -- "$tmp"' EXIT
cache_buster="$(date +%s%N 2>/dev/null || date +%s)"

echo '[+] 正在获取最新的 VPS Setup 脚本...'
if ! curl \
    --fail --show-error --silent --location \
    --header 'Cache-Control: no-cache' \
    --header 'Pragma: no-cache' \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 120 \
    -o "$tmp" "${SCRIPT_URL}?cb=${cache_buster}"; then
    echo '获取最新脚本失败，请检查网络后重试。' >&2
    exit 1
fi

if [[ ! -s "$tmp" ]] || ! bash -n "$tmp"; then
    echo '下载的脚本为空或语法无效，请稍后重试。' >&2
    exit 1
fi

bash "$tmp" "$@"
LAUNCHER
    then
        rm -f -- "$tmp"
        error '生成快捷命令失败。'
        return 1
    fi

    if ! bash -n "$tmp" || ! chmod 755 "$tmp" || ! mv -f -- "$tmp" "$LAUNCHER_PATH"; then
        rm -f -- "$tmp"
        error '安装快捷命令失败。'
        return 1
    fi

    log "快捷命令已安装：${LAUNCHER_PATH}"
    log '以后输入 vps-setup 即可运行；非 root 用户执行 sudo vps-setup。'
    log '每次运行都会重新获取 GitHub main 分支的最新脚本。'
}

run_tuning() {
    echo
    warn '【第 1 步】tcpfit / TCP 调优。'
    warn '此操作可能修改系统网络参数。'
    ask_yes_no '确认执行第 1 步吗？' || { warn '已取消。'; return 0; }
    run_remote_script "$SCRIPT_TUNING"
}

run_diagnostics() {
    echo
    log '启动 XY 系列 VPS 质量检测菜单（ScriptMenu）。'
    log '可选择 IP 质量、网络质量和硬件质量检测。'
    warn '退出检测子菜单后会返回本菜单。'
    run_remote_script "$SCRIPT_DIAGNOSTICS"
}

run_package_manager() {
    local package='' status=''

    echo
    log '安装 / 更新软件（APT）。'
    echo '输入软件包名称即可，例如 curl、wget、htop、git、nginx。'
    printf '软件包名称（输入 0 或直接 Enter 返回）: ' >"$TTY"
    IFS= read -r package <"$TTY" || return 0
    package="${package#"${package%%[![:space:]]*}"}"
    package="${package%"${package##*[![:space:]]}"}"

    [[ -n "$package" && "$package" != '0' ]] || return 0

    if [[ ! "$package" =~ ^[a-z0-9][a-z0-9+.-]+(:[a-z0-9][a-z0-9-]*)?$ ]]; then
        error '请输入一个有效的软件包名称，例如 curl 或 libssl-dev。'
        return 1
    fi

    log '刷新 APT 软件包索引...'
    if ! apt-get update; then
        error '软件包索引刷新失败，请检查网络和 APT 软件源。'
        return 1
    fi

    status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
    if [[ "$status" == 'install ok installed' ]]; then
        log "${package} 已安装，正在检查并更新到软件源提供的最新版本..."
        if ! apt-get install --only-upgrade -y -- "$package"; then
            error "更新失败：${package}。"
            return 1
        fi
    else
        log "${package} 未安装，正在安装..."
        if ! apt-get install -y -- "$package"; then
            error "安装失败：${package}，请检查软件包名称和 APT 软件源。"
            return 1
        fi
    fi

    log "安装 / 更新完成：${package}。"
}

run_ssh_manager() {
    echo
    log '【第 2 步】启动 SSH Key Manager。'
    warn 'SSH 子脚本本身也是循环菜单；选择 0 后会返回本菜单。'
    run_remote_script "$SCRIPT_SSH"
}

run_3xui() {
    echo
    warn '【第 3 步】安装 3x-ui。'
    warn '脚本会要求输入域名、管理员账号和密码。'
    warn '默认面板端口为 8443，ACME HTTP-01 使用 80 端口。'
    ask_yes_no '确认执行第 3 步吗？' || { warn '已取消。'; return 0; }
    run_remote_script "$SCRIPT_3XUI"
}

cloudflared_installed() {
    command -v dpkg-query >/dev/null 2>&1 &&
        dpkg-query -W -f='${Status}' cloudflared 2>/dev/null | grep -Fq 'install ok installed'
}

run_cloudflared_update() {
    echo
    log '【第 4 步】配置 Cloudflared 自动更新。'

    if ! cloudflared_installed; then
        warn '当前没有检测到通过 APT 安装的 cloudflared。'
        warn '该子脚本只负责配置 cloudflared 自动更新，不负责首次安装 Tunnel。'
        return 1
    fi

    run_remote_script "$SCRIPT_CLOUDFLARED" install
}

run_crowdsec() {
    echo
    warn '【第 5 步 / 最后一步】安装 CrowdSec + nftables 防火墙。'
    warn '最终公网仅允许 80、443 和确认后的 SSH 端口；8443 公网访问会被阻止。'
    ask_yes_no '确认执行最后一步吗？' || { warn '已取消。'; return 0; }
    run_remote_script "$SCRIPT_CROWDSEC"
}

crowdsec_present() {
    command -v cscli >/dev/null 2>&1 ||
        systemctl list-unit-files crowdsec.service >/dev/null 2>&1
}

guard_ready() {
    command -v nft >/dev/null 2>&1 &&
        nft list table inet crowdsec_guard >/dev/null 2>&1 &&
        [[ -x /usr/local/sbin/crowdsec-guard-fw ]] &&
        systemctl cat crowdsec-guard-fw.service >/dev/null 2>&1
}

run_port_manager() {
    echo

    if guard_ready; then
        log '检测到已管理的 CrowdSec Guard，直接进入端口管理。'
        warn '端口管理器执行完成后选择 0，会返回本菜单。'
        run_remote_script "$SCRIPT_PORT_MANAGER"
        return $?
    fi

    warn '未检测到本脚本管理的 crowdsec_guard。'

    if ! command -v nft >/dev/null 2>&1; then
        warn '系统未安装 nftables，无法初始化 Guard 管理层。'
        warn '请先安装 nftables/CrowdSec，或执行第 5 步。'
        return 1
    fi

    if ! crowdsec_present; then
        warn '系统未检测到 CrowdSec。'
        warn '请先安装 CrowdSec，或执行第 5 步。'
        return 1
    fi

    echo
    log '检测到 CrowdSec + nftables 已存在，但它们不是通过本脚本安装的。'
    echo '可以只补齐 CrowdSec Guard 管理层，不会重装 CrowdSec、3x-ui 或 cloudflared。'
    echo '初始化时会自动检测 SSH 端口，并使用 90 秒回滚保护。'
    echo

    if ! ask_yes_no '是否初始化 Guard 管理层后继续端口管理？'; then
        warn '已取消。'
        return 0
    fi

    if ! run_remote_script "$SCRIPT_GUARD_INIT"; then
        error 'Guard 管理层初始化失败。'
        return 1
    fi

    if ! guard_ready; then
        error '初始化完成后仍未检测到完整的 Guard 管理层。'
        return 1
    fi

    echo
    log 'Guard 管理层已就绪，进入端口管理。'
    run_remote_script "$SCRIPT_PORT_MANAGER"
}

show_status() {
    local ssh_port='unknown' pubkey='unknown' password='unknown'

    clear 2>/dev/null || true
    echo '============================================================'
    echo ' 新机当前状态'
    echo '============================================================'
    echo

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        printf '系统:              %s\n' "${PRETTY_NAME:-unknown}"
    fi

    printf '内核:              %s\n' "$(uname -r)"

    if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
        local sshd_bin
        sshd_bin="$(command -v sshd 2>/dev/null || printf '/usr/sbin/sshd')"
        ssh_port="$($sshd_bin -T 2>/dev/null | awk '$1=="port" {print $2; exit}' || true)"
        pubkey="$($sshd_bin -T 2>/dev/null | awk '$1=="pubkeyauthentication" {print $2; exit}' || true)"
        password="$($sshd_bin -T 2>/dev/null | awk '$1=="passwordauthentication" {print $2; exit}' || true)"
    fi

    printf 'SSH 端口:          %s\n' "${ssh_port:-unknown}"
    printf 'SSH 公钥认证:      %s\n' "${pubkey:-unknown}"
    printf 'SSH 密码认证:      %s\n' "${password:-unknown}"
    echo

    printf '3x-ui:             '
    command -v x-ui >/dev/null 2>&1 && echo '已安装' || echo '未检测到'

    printf 'cloudflared:       '
    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared --version 2>/dev/null | head -n1 || echo '已安装'
    else
        echo '未安装'
    fi

    printf 'cloudflared timer: '
    if systemctl is-enabled cloudflared-auto-update.timer >/dev/null 2>&1; then
        echo '已启用'
    else
        echo '未启用'
    fi

    printf 'CrowdSec:          '
    if crowdsec_present; then
        systemctl is-active --quiet crowdsec 2>/dev/null && echo '已安装 / active' || echo '已安装 / 非 active'
    else
        echo '未安装'
    fi

    printf 'CrowdSec Guard:    '
    if guard_ready; then
        echo '已管理 / 规则已加载'
    elif command -v nft >/dev/null 2>&1 && nft list table inet crowdsec_guard >/dev/null 2>&1; then
        echo '存在规则，但管理组件不完整'
    else
        echo '未初始化'
    fi

    printf '自定义 TCP 端口:  '
    if [[ -s /etc/crowdsec-guard/custom-tcp-ports.conf ]]; then
        tr '\n' ' ' </etc/crowdsec-guard/custom-tcp-ports.conf
        echo
    else
        echo '无'
    fi

    echo
}

run_recommended_flow() {
    echo
    echo '============================================================'
    echo ' 按推荐顺序执行全部步骤'
    echo '============================================================'
    echo
    echo '将严格按照菜单 1 → 5 执行：'
    echo '  1. tcpfit / TCP 调优'
    echo '  2. SSH 密钥管理'
    echo '  3. 3x-ui'
    echo '  4. Cloudflared 自动更新（仅 cloudflared 已安装时）'
    echo '  5. CrowdSec + nftables（最后执行）'
    echo
    warn '各子脚本自己的安全确认和交互输入仍然保留。'
    ask_yes_no '确认按 1 → 5 顺序开始执行吗？' || { warn '已取消。'; return 0; }

    log '[第 1 步 / 5] tcpfit / TCP 调优'
    run_remote_script "$SCRIPT_TUNING" || return 1

    log '[第 2 步 / 5] SSH Key Manager'
    run_remote_script "$SCRIPT_SSH" || return 1

    log '[第 3 步 / 5] 3x-ui'
    run_remote_script "$SCRIPT_3XUI" || return 1

    log '[第 4 步 / 5] Cloudflared 自动更新'
    if cloudflared_installed; then
        run_remote_script "$SCRIPT_CLOUDFLARED" install || warn 'Cloudflared 自动更新配置失败。'
    else
        warn '未检测到 APT 安装的 cloudflared，第 4 步自动跳过。'
    fi

    log '[第 5 步 / 5] CrowdSec + nftables'
    ask_yes_no '确认执行最后一步 CrowdSec 防火墙配置吗？' || { warn '已跳过第 5 步。'; return 0; }
    run_remote_script "$SCRIPT_CROWDSEC"
}

print_menu() {
    clear 2>/dev/null || true

    echo '============================================================'
    echo ' New Machine Setup - Debian'
    echo " 版本: ${SETUP_VERSION}"
    echo '============================================================'
    echo
    echo '【推荐执行顺序：从 1 开始依次往下执行】'
    echo
    echo '1) 第 1 步：tcpfit / TCP 调优'
    echo '2) 第 2 步：SSH 密钥管理'
    echo '3) 第 3 步：安装 3x-ui'
    echo '4) 第 4 步：安装 Cloudflared 自动更新任务'
    echo '5) 第 5 步：安装 CrowdSec + nftables 防火墙（最后）'
    echo
    echo '【辅助功能】'
    echo
    echo '6) 一键按 1 → 5 顺序执行全部步骤'
    echo '7) CrowdSec Guard 端口管理 / 自动兼容初始化'
    echo '8) 查看当前状态'
    echo '9) VPS 质量检测菜单（IP / 网络 / 硬件）'
    echo '10) 安装 / 更新软件（输入软件包名称）'
    echo '11) 安装 / 更新快捷命令 vps-setup（每次获取最新版）'
    echo '0) 退出'
    echo
}

main_loop() {
    local choice=''

    while true; do
        print_menu
        printf '请选择 [0-11]: ' >"$TTY"
        IFS= read -r choice <"$TTY" || choice='0'

        case "$choice" in
            1) run_tuning || true; pause_menu ;;
            2) run_ssh_manager || true; pause_menu ;;
            3) run_3xui || true; pause_menu ;;
            4) run_cloudflared_update || true; pause_menu ;;
            5) run_crowdsec || true; pause_menu ;;
            6) run_recommended_flow || true; pause_menu ;;
            7) run_port_manager || true; pause_menu ;;
            8) show_status || true; pause_menu ;;
            9) run_diagnostics || true; pause_menu ;;
            10) run_package_manager || true; pause_menu ;;
            11) install_launcher || true; pause_menu ;;
            0) echo; log '已退出 New Machine Setup。'; exit 0 ;;
            *) warn '无效选择，请输入 0-11。'; sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --install) check_environment --install; install_launcher ;;
    '') check_environment; main_loop ;;
    *) fatal '用法：setup.sh [--install]（--install 仅安装快捷命令）。' ;;
esac

