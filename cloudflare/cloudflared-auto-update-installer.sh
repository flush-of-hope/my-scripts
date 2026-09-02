#!/usr/bin/env bash

set -Eeuo pipefail

readonly UPDATE_SCRIPT="/usr/local/bin/cloudflared-auto-update.sh"
readonly SERVICE_FILE="/etc/systemd/system/cloudflared-auto-update.service"
readonly TIMER_FILE="/etc/systemd/system/cloudflared-auto-update.timer"
readonly SERVICE_NAME="cloudflared-auto-update.service"
readonly TIMER_NAME="cloudflared-auto-update.timer"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "错误：$*" >&2
    exit 1
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
}

check_environment() {
    command -v systemctl >/dev/null 2>&1 || die "系统未使用 systemd。"
    command -v apt-get >/dev/null 2>&1 || die "仅支持 Debian/Ubuntu 等 APT 系统。"
    command -v dpkg-query >/dev/null 2>&1 || die "未找到 dpkg-query。"

    dpkg-query -W -f='${Status}' cloudflared 2>/dev/null \
        | grep -q '^install ok installed$' \
        || die "未检测到通过 APT 安装的 cloudflared。"

    systemctl cat cloudflared.service >/dev/null 2>&1 \
        || die "未找到 cloudflared.service，请先确认 Tunnel 服务已安装。"
}

install_task() {
    require_root
    check_environment

    log "正在创建 Cloudflared 更新脚本……"
    install -d -m 0755 /usr/local/bin

    tee "${UPDATE_SCRIPT}" >/dev/null <<'UPDATE_SCRIPT_EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

readonly LOG_TAG="cloudflared-auto-update"

log() {
    local message="$*"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${message}"
    logger -t "${LOG_TAG}" -- "${message}" || true
}

old_version="$(dpkg-query -W -f='${Version}' cloudflared 2>/dev/null || true)"

if [[ -z "${old_version}" ]]; then
    log "未检测到 cloudflared，取消更新。"
    exit 1
fi

log "当前版本：${old_version}"
log "开始刷新 APT 软件源……"

if ! apt-get update -qq; then
    log "APT 软件源刷新失败。"
    exit 1
fi

log "开始检查并升级 cloudflared……"

if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade cloudflared; then
    log "cloudflared 升级失败。"
    exit 1
fi

new_version="$(dpkg-query -W -f='${Version}' cloudflared 2>/dev/null || true)"

if [[ -z "${new_version}" ]]; then
    log "升级后无法读取 cloudflared 版本。"
    exit 1
fi

if [[ "${old_version}" == "${new_version}" ]]; then
    log "已经是最新版本：${old_version}，无需重启。"
    exit 0
fi

log "版本已更新：${old_version} -> ${new_version}"
log "正在重启 cloudflared.service……"

if systemctl restart cloudflared.service; then
    log "cloudflared.service 重启成功。"
else
    log "cloudflared.service 重启失败，请立即检查服务状态。"
    exit 1
fi
UPDATE_SCRIPT_EOF

    chmod 0755 "${UPDATE_SCRIPT}"

    log "正在创建 systemd 服务……"
    tee "${SERVICE_FILE}" >/dev/null <<SERVICE_EOF
[Unit]
Description=Update Cloudflared from APT Repository
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${UPDATE_SCRIPT}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SERVICE_EOF

    log "正在创建每日定时器……"
    tee "${TIMER_FILE}" >/dev/null <<'TIMER_EOF'
[Unit]
Description=Daily Cloudflared Update Check

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
RandomizedDelaySec=30m
Unit=cloudflared-auto-update.service

[Install]
WantedBy=timers.target
TIMER_EOF

    systemctl daemon-reload
    systemctl enable --now "${TIMER_NAME}"

    log "安装完成。每天 04:30 检查更新，并随机延迟 0～30 分钟。"
    log "只有版本发生变化时才会重启 cloudflared.service。"
    printf '\n'
    systemctl list-timers "${TIMER_NAME}" --no-pager
    printf '\n常用命令：\n'
    printf '  立即检查：sudo systemctl start %s\n' "${SERVICE_NAME}"
    printf '  查看日志：journalctl -u %s -n 100 --no-pager\n' "${SERVICE_NAME}"
    printf '  查看状态：systemctl status %s --no-pager\n' "${TIMER_NAME}"
}

uninstall_task() {
    require_root

    log "正在移除 Cloudflared 自动更新任务……"
    systemctl disable --now "${TIMER_NAME}" 2>/dev/null || true
    rm -f -- "${UPDATE_SCRIPT}" "${SERVICE_FILE}" "${TIMER_FILE}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" "${TIMER_NAME}" 2>/dev/null || true
    log "已移除自动更新任务；cloudflared 本身和 Tunnel 配置未被删除。"
}

show_status() {
    systemctl status "${TIMER_NAME}" --no-pager || true
    printf '\n'
    systemctl list-timers "${TIMER_NAME}" --no-pager || true
}

show_help() {
    cat <<'HELP_EOF'
用法：
  sudo bash cloudflared-auto-update-installer.sh install    安装或覆盖更新任务（默认）
  sudo bash cloudflared-auto-update-installer.sh uninstall  移除更新任务
  bash cloudflared-auto-update-installer.sh status           查看定时器状态
HELP_EOF
}

case "${1:-install}" in
    install)
        install_task
        ;;
    uninstall)
        uninstall_task
        ;;
    status)
        show_status
        ;;
    -h|--help|help)
        show_help
        ;;
    *)
        show_help >&2
        exit 2
        ;;
esac
