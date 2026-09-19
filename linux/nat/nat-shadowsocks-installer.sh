#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME="${0##*/}"
INTERNAL_PORT="80"
MODE="tcp_only"
PASSWORD=""
EXTERNAL_HOST=""
EXTERNAL_PORT=""
PORT_SET=false
MODE_SET=false
PASSWORD_SET=false
EXTERNAL_HOST_SET=false
EXTERNAL_PORT_SET=false
CONFIG_DIR="/etc/shadowsocks-libev"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks-nat.service"
SERVICE_NAME="shadowsocks-nat.service"

usage() {
  cat <<'EOF'
Install a low-memory Shadowsocks-libev exit server on Debian 13 NAT VPS.

Usage:
  bash nat-shadowsocks-installer.sh [options]

Run without options for the interactive installer. Press Enter to accept
recommended defaults; command-line options can pre-fill individual answers.

Options:
  --port PORT             Internal listening port (default: 80)
  --mode MODE             tcp_only or tcp_and_udp (default: tcp_only)
  --password PASSWORD     Use a specified password (default: generate/preserve)
  --external-host HOST    Public/shared NAT IPv4 or hostname, for output only
  --external-port PORT    Mapped public port, for output only
  -h, --help              Show this help

Example:
  bash nat-shadowsocks-installer.sh \
    --port 80 \
    --mode tcp_only \
    --external-host 165.154.233.93 \
    --external-port 31827
EOF
}

log() {
  printf '[+] %s\n' "$*"
}

die() {
  printf '[!] %s\n' "$*" >&2
  exit 1
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

while (($#)); do
  case "$1" in
    --port)
      (($# >= 2)) || die "--port requires a value"
      INTERNAL_PORT="$2"
      PORT_SET=true
      shift 2
      ;;
    --mode)
      (($# >= 2)) || die "--mode requires a value"
      MODE="$2"
      MODE_SET=true
      shift 2
      ;;
    --password)
      (($# >= 2)) || die "--password requires a value"
      PASSWORD="$2"
      PASSWORD_SET=true
      shift 2
      ;;
    --external-host)
      (($# >= 2)) || die "--external-host requires a value"
      EXTERNAL_HOST="$2"
      EXTERNAL_HOST_SET=true
      shift 2
      ;;
    --external-port)
      (($# >= 2)) || die "--external-port requires a value"
      EXTERNAL_PORT="$2"
      EXTERNAL_PORT_SET=true
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run this script as root"

prompt_value() {
  local prompt="$1" default_value="$2" reply
  read -r -p "${prompt} [${default_value}]: " reply
  printf '%s' "${reply:-$default_value}"
}

interactive_setup() {
  local reply mode_choice password_hint

  printf '\nShadowsocks NAT VPS interactive installer\n'
  printf '%s\n' 'Press Enter to accept the value shown in brackets.'

  if [[ "$PORT_SET" == false ]]; then
    INTERNAL_PORT="$(prompt_value 'Internal listening port' '80')"
  fi

  if [[ "$MODE_SET" == false ]]; then
    printf '\nTraffic mode:\n'
    printf '  1) TCP only (choose this when the provider only maps TCP)\n'
    printf '  2) TCP + UDP (the provider must map both protocols)\n'
    read -r -p 'Select mode [1]: ' mode_choice
    case "${mode_choice:-1}" in
      1) MODE="tcp_only" ;;
      2) MODE="tcp_and_udp" ;;
      *) die "Invalid mode selection" ;;
    esac
  fi

  if [[ "$EXTERNAL_HOST_SET" == false ]]; then
    read -r -p 'Public/shared NAT IP or hostname (optional): ' EXTERNAL_HOST
  fi
  if [[ -n "$EXTERNAL_HOST" && "$EXTERNAL_PORT_SET" == false ]]; then
    EXTERNAL_PORT="$(prompt_value 'Mapped external port' "$INTERNAL_PORT")"
  fi

  if [[ "$PASSWORD_SET" == false ]]; then
    if [[ -r "$CONFIG_FILE" ]]; then
      password_hint='leave blank to preserve the current password'
    else
      password_hint='leave blank to generate a secure password'
    fi
    read -r -s -p "Shadowsocks password (${password_hint}): " reply
    printf '\n'
    PASSWORD="$reply"
  fi

  printf '\nConfiguration summary:\n'
  printf '  Internal port : %s\n' "$INTERNAL_PORT"
  printf '  Mode          : %s\n' "$MODE"
  printf '  External host : %s\n' "${EXTERNAL_HOST:-not provided}"
  printf '  External port : %s\n' "${EXTERNAL_PORT:-not provided}"
  read -r -p 'Start installation? [Y/n]: ' reply
  case "${reply:-Y}" in
    y|Y|yes|YES) ;;
    *) printf 'Cancelled.\n'; exit 0 ;;
  esac
}

if [[ -t 0 ]]; then
  interactive_setup
else
  log "No interactive terminal detected; using supplied options and defaults"
fi

valid_port "$INTERNAL_PORT" || die "Invalid internal port: ${INTERNAL_PORT}"
[[ "$MODE" == "tcp_only" || "$MODE" == "tcp_and_udp" ]] || \
  die "Mode must be tcp_only or tcp_and_udp"
if [[ -n "$EXTERNAL_PORT" ]]; then
  valid_port "$EXTERNAL_PORT" || die "Invalid external port: ${EXTERNAL_PORT}"
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "This installer currently supports Debian only"
else
  die "Cannot detect the operating system"
fi

[[ "$(uname -m)" == "x86_64" ]] || die "This installer currently supports x86_64 only"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"

install_from_apt_cache() {
  local archive package
  local -a selected=()
  local wanted='^(shadowsocks-libev|libbloom2|libcares2|libcork16|libcorkipset1|libev4t64|libjsonparser1\.1|libmbedcrypto16)$'

  shopt -s nullglob
  for archive in /var/cache/apt/archives/*.deb; do
    package="$(dpkg-deb -f "$archive" Package 2>/dev/null || true)"
    if [[ "$package" =~ $wanted ]]; then
      selected+=("$archive")
    fi
  done
  shopt -u nullglob

  ((${#selected[@]} > 0)) || return 1
  log "APT could not finish; installing downloaded low-memory packages with dpkg"
  dpkg -i "${selected[@]}" || true
  command -v ss-server >/dev/null 2>&1
}

if ! command -v ss-server >/dev/null 2>&1; then
  log "Installing shadowsocks-libev"
  export DEBIAN_FRONTEND=noninteractive

  # APT can be OOM-killed on a 64 MiB container after downloads complete.
  # If that happens, install only the required cached packages with dpkg.
  apt-get update || true
  if ! apt-get \
      -o APT::Install-Recommends=false \
      -o APT::Install-Suggests=false \
      install -y shadowsocks-libev; then
    install_from_apt_cache || die \
      "Installation failed and required .deb files were not found in /var/cache/apt/archives"
  fi
fi

command -v ss-server >/dev/null 2>&1 || die "ss-server was not installed"
id nobody >/dev/null 2>&1 || die "The nobody user does not exist"
getent group nogroup >/dev/null 2>&1 || die "The nogroup group does not exist"

if [[ -z "$PASSWORD" && -r "$CONFIG_FILE" ]]; then
  PASSWORD="$(sed -n 's/^[[:space:]]*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n 1)"
fi
if [[ -z "$PASSWORD" ]]; then
  PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
fi
[[ ${#PASSWORD} -ge 12 ]] || die "Password must contain at least 12 characters"

if ss -H -lnt "sport = :${INTERNAL_PORT}" 2>/dev/null | grep -q .; then
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    die "TCP port ${INTERNAL_PORT} is already in use"
  fi
fi

install -d -m 755 "$CONFIG_DIR"
if [[ -f "$CONFIG_FILE" ]]; then
  cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

install -o nobody -g nogroup -m 600 /dev/null "$CONFIG_FILE"
cat >"$CONFIG_FILE" <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${INTERNAL_PORT},
  "password": "${PASSWORD}",
  "timeout": 300,
  "method": "chacha20-ietf-poly1305",
  "mode": "${MODE}",
  "fast_open": false
}
EOF
chown nobody:nogroup "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# Debian's packaged unit uses mount namespace hardening that fails in many
# restricted LXC/Podman NAT containers. This minimal unit lets ss-server bind
# as root and immediately drop privileges to nobody via its -a option.
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Shadowsocks NAT Exit Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/ss-server -a nobody -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF

systemctl disable --now shadowsocks-libev-server@config.service >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
sleep 1

systemctl is-active --quiet "$SERVICE_NAME" || {
  systemctl status "$SERVICE_NAME" --no-pager --full || true
  journalctl -u "$SERVICE_NAME" -n 30 --no-pager --full || true
  die "Shadowsocks failed to start"
}

ss -H -lnt "sport = :${INTERNAL_PORT}" 2>/dev/null | grep -q . || \
  die "Service is active but TCP port ${INTERNAL_PORT} is not listening"

printf '\nInstallation completed.\n'
printf 'Internal port : %s\n' "$INTERNAL_PORT"
printf 'Mode          : %s\n' "$MODE"
printf 'Method        : chacha20-ietf-poly1305\n'
printf 'Password      : %s\n' "$PASSWORD"
printf 'Service       : %s\n' "$SERVICE_NAME"

if [[ -n "$EXTERNAL_HOST" && -n "$EXTERNAL_PORT" ]]; then
  cat <<EOF

3x-ui / Xray outbound:
{
  "tag": "nat-out",
  "protocol": "shadowsocks",
  "settings": {
    "servers": [
      {
        "address": "${EXTERNAL_HOST}",
        "port": ${EXTERNAL_PORT},
        "method": "chacha20-ietf-poly1305",
        "password": "${PASSWORD}"
      }
    ]
  }
}
EOF
else
  printf '\nUse the provider-mapped public host and external port in the 3x-ui outbound.\n'
fi

if [[ "$MODE" == "tcp_only" ]]; then
  printf '\nNote: this installation is TCP-only because the NAT mapping must also support UDP.\n'
fi
