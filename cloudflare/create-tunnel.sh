#!/usr/bin/env bash
# Create/reuse a remotely managed Cloudflare Tunnel and its published hostname.
set +x
set -Eeuo pipefail
umask 077

readonly API_BASE='https://api.cloudflare.com/client/v4'
readonly TTY='/dev/tty'
readonly TOKEN_DIR='/etc/cloudflared/vps-setup'
readonly UNIT_FILE='/etc/systemd/system/cloudflared-vps-setup@.service'
readonly STATE_DIR='/var/lib/vps-setup/cloudflare'
readonly MANAGED_MARKER='# Managed by vps-setup Cloudflare installer'
WORK_DIR=''
tunnel_id=''

log() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup() {
    local rc=$?
    trap - EXIT
    [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
    if (( rc != 0 )) && [[ -n "$tunnel_id" ]]; then
        warn "操作未完成，隧道 ID：${tunnel_id}。可使用相同隧道名称重新运行。"
    fi
    exit "$rc"
}

prompt() {
    local target="$1" label="$2" default="${3:-}" answer=''
    printf '%s' "$label" >"$TTY"
    [[ -z "$default" ]] || printf ' [%s]' "$default" >"$TTY"
    printf ': ' >"$TTY"
    IFS= read -r answer <"$TTY" || die '输入已中断。'
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    printf -v "$target" '%s' "${answer:-$default}"
}

yes_no() {
    local answer=''
    printf '%s [y/N]: ' "$1" >"$TTY"
    IFS= read -r answer <"$TTY" || return 1
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

valid_domain() {
    local domain="$1" label
    local -a labels
    [[ ${#domain} -le 253 && "$domain" == *.* ]] || return 1
    IFS='.' read -r -a labels <<<"$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
    [[ "$domain" != *. ]]
}

require_environment() {
    [[ $EUID -eq 0 ]] || die '请使用 root 运行。'
    [[ -r "$TTY" && -w "$TTY" ]] || die '请在交互式终端中运行。'
    [[ -f /etc/debian_version ]] || die '仅支持 Debian / Ubuntu。'
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || die '需要正在运行的 systemd。'
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
        log '安装 curl、jq、ca-certificates 和 util-linux...'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq ca-certificates util-linux
    fi
    if [[ -e "$UNIT_FILE" ]] && ! grep -Fxq "$MANAGED_MARKER" "$UNIT_FILE"; then
        die "已有未受本脚本管理的 ${UNIT_FILE}，请先检查该服务文件。"
    fi
    install -d -m 0700 "$STATE_DIR"
    exec 9>"$STATE_DIR/.lock"
    flock -n 9 || die '另一个 CF 配置任务正在运行，请稍后重试。'
}

api_request() {
    local method="$1" path="$2" output="$3" payload="${4:-}" code
    local -a args=(--silent --show-error --proto '=https' --proto-redir '=https'
        --connect-timeout 15 --max-time 60 --request "$method"
        --header "@${WORK_DIR}/auth-header" --header 'Content-Type: application/json'
        --output "$output" --write-out '%{http_code}')
    [[ -z "$payload" ]] || args+=(--data-binary "@${payload}")
    # Do not retry writes: a timeout may occur after a resource was created.
    if ! code="$(curl "${args[@]}" "${API_BASE}${path}")"; then
        die "Cloudflare API 网络请求失败：${method} ${path}。"
    fi
    if [[ ! "$code" =~ ^2[0-9][0-9]$ ]] || ! jq -e '.success == true' "$output" >/dev/null 2>&1; then
        jq -r '.errors[]? | "Cloudflare 错误 \(.code): \(.message)"' "$output" >&2 2>/dev/null || true
        die "Cloudflare API 请求失败（HTTP ${code}），请检查 Token 权限和资源范围。"
    fi
}

collect_inputs() {
    local api_token='' default_name="vps-${HOSTNAME%%.*}"
    echo '需要的 API Token 权限：账户 / Cloudflare Tunnel / 编辑；区域 / DNS / 编辑；区域 / 区域 / 读取。'
    echo 'Token 的资源范围应包含目标账户和域名。Token 只在本次运行中使用。'
    printf 'Cloudflare API Token（输入不回显）: ' >"$TTY"
    IFS= read -rs api_token <"$TTY" || die '输入已中断。'
    printf '\n' >"$TTY"
    [[ "$api_token" =~ ^[A-Za-z0-9._-]+$ ]] || die 'API Token 为空或格式无效。'
    printf 'Authorization: Bearer %s\n' "$api_token" >"$WORK_DIR/auth-header"
    unset api_token

    prompt zone_name 'Cloudflare 中管理的域名（Zone，例如 example.com）'
    zone_name="${zone_name,,}"
    valid_domain "$zone_name" || die 'Zone 域名格式无效。'
    prompt public_hostname '需要绑定的完整域名（例如 panel.example.com）'
    public_hostname="${public_hostname,,}"
    valid_domain "$public_hostname" || die '公开域名格式无效。'
    [[ "$public_hostname" == "$zone_name" || "$public_hostname" == *."$zone_name" ]] || die '公开域名不属于输入的 Zone。'
    prompt tunnel_name '隧道名称（已存在时复用）' "$default_name"
    [[ "$tunnel_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die '隧道名称仅支持 1–64 位字母、数字、点、下划线和连字符。'
    prompt origin_url '本地服务地址（如 https://127.0.0.1:8443 或 ssh://127.0.0.1:22）' 'http://127.0.0.1:80'
    local origin_pattern='^((https?|ssh|tcp)://)(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9][A-Za-z0-9._-]*)(:([0-9]{1,5}))?$'
    [[ "$origin_url" =~ $origin_pattern ]] || die '源站地址需使用 http/https/ssh/tcp://主机[:端口]，不包含路径或密码。'
    local port="${BASH_REMATCH[5]:-}"
    [[ -z "$port" ]] || (( 10#$port >= 1 && 10#$port <= 65535 )) || die '源站端口需为 1–65535。'
    origin_request_json='{}'
    if [[ "$origin_url" == https://* ]]; then
        log '配置此公开应用路由的源站 TLS 参数。'
        origin_server_name=''
        no_tls_verify=false
        match_sni_to_host=false
        http2_origin=false
        ca_pool=''
        tls_timeout=10
        prompt origin_server_name '源站 HTTPS 证书对应的域名' "$public_hostname"
        origin_server_name="${origin_server_name,,}"
        valid_domain "$origin_server_name" || die '源站证书域名格式无效。'
        if yes_no '源站使用自签名证书，是否跳过源站 TLS 证书验证？'; then
            no_tls_verify=true
        fi
        if yes_no 'SNI 是否跟随请求 Host（Match SNI to host）？'; then
            match_sni_to_host=true
            log '已启用 Match SNI to host：SNI 将使用请求 Host，优先于上面填写的证书域名。'
        fi
        if [[ "$no_tls_verify" == false ]]; then
            prompt ca_pool '自定义 CA 证书文件的绝对路径（可选，回车使用系统 CA）'
            if [[ -n "$ca_pool" ]]; then
                [[ "$ca_pool" == /* && -f "$ca_pool" && -r "$ca_pool" ]] || die 'CA 证书必须是本机可读取的文件，并使用绝对路径。'
                grep -F -- '-----BEGIN CERTIFICATE-----' "$ca_pool" >/dev/null || die 'CA 文件需要包含 PEM 格式的证书。'
            fi
        fi
        prompt tls_timeout '源站 TLS 握手超时（整数秒，1–86400）' '10'
        [[ "$tls_timeout" =~ ^[0-9]+$ ]] || die 'TLS 超时需为整数秒，例如 10。'
        tls_timeout="$(jq -en --arg value "$tls_timeout" '$value | tonumber | select(. >= 1 and . <= 86400)')" || die 'TLS 超时需在 1–86400 秒之间。'
        if yes_no '是否使用 HTTP/2 连接 HTTPS 源站？'; then
            http2_origin=true
        fi
        origin_request_json="$(jq -cn --arg name "$origin_server_name" --arg ca "$ca_pool" --argjson timeout "$tls_timeout" \
            --argjson insecure "$no_tls_verify" --argjson sni "$match_sni_to_host" --argjson http2 "$http2_origin" \
            '{originServerName: $name, noTLSVerify: $insecure, matchSNItoHost: $sni, caPool: $ca, tlsTimeout: $timeout, http2Origin: $http2}')"
    fi
    echo
    printf 'Zone:   %s\n域名:   %s\n隧道:   %s\n源站:   %s\n' "$zone_name" "$public_hostname" "$tunnel_name" "$origin_url"
    if [[ "$origin_url" == https://* ]]; then
        printf '源站 TLS: 证书域名=%s，跳过验证=%s，SNI 跟随 Host=%s\n' "$origin_server_name" "$no_tls_verify" "$match_sni_to_host"
        printf '          CA=%s，握手超时=%s 秒，源站 HTTP/2=%s\n' "${ca_pool:-系统默认}" "$tls_timeout" "$http2_origin"
        [[ "$no_tls_verify" == false ]] || warn '已选择跳过源站 TLS 证书验证。'
    fi
    yes_no '确认创建 / 更新以上隧道、公开应用路由和 DNS，并启动本机连接服务？' || { log '已取消。'; exit 0; }
}

prepare_resources() {
    local count encoded_name
    api_request GET "/zones?name=${zone_name}&status=active&per_page=50" "$WORK_DIR/zone.json"
    count="$(jq --arg name "$zone_name" '[.result[] | select(.name == $name)] | length' "$WORK_DIR/zone.json")"
    [[ "$count" == 1 ]] || die '未找到唯一且已激活的 Zone，请检查域名、Zone 读取权限及 Token 资源范围。'
    zone_id="$(jq -r --arg name "$zone_name" '.result[] | select(.name == $name) | .id' "$WORK_DIR/zone.json")"
    account_id="$(jq -r --arg name "$zone_name" '.result[] | select(.name == $name) | .account.id' "$WORK_DIR/zone.json")"
    [[ "$zone_id" =~ ^[a-f0-9]{32}$ && "$account_id" =~ ^[a-f0-9]{32}$ ]] || die 'Cloudflare 返回的 Zone / Account ID 无效。'
    encoded_name="$(jq -nr --arg value "$tunnel_name" '$value | @uri')"
    api_request GET "/accounts/${account_id}/cfd_tunnel?name=${encoded_name}&is_deleted=false&per_page=100" "$WORK_DIR/tunnels.json"
    jq -e '(.result_info.total_pages // 1) <= 1' "$WORK_DIR/tunnels.json" >/dev/null || die '匹配的隧道过多，请使用更具体的名称。'
    jq --arg name "$tunnel_name" '[.result[] | select(.name == $name)]' "$WORK_DIR/tunnels.json" >"$WORK_DIR/matches.json"
    count="$(jq 'length' "$WORK_DIR/matches.json")"
    [[ "$count" == 0 || "$count" == 1 ]] || die '存在多个同名隧道，请使用唯一隧道名称。'
    if [[ "$count" == 1 ]]; then
        tunnel_id="$(jq -r '.[0].id' "$WORK_DIR/matches.json")"
        [[ "$(jq -r '.[0].config_src' "$WORK_DIR/matches.json")" == cloudflare ]] || die '同名隧道由本地管理，请使用一个新的名称。'
        [[ "$tunnel_id" =~ ^[a-f0-9-]{36}$ ]] || die 'Cloudflare 返回的隧道 ID 无效。'
        api_request GET "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" "$WORK_DIR/current-config.json"
        jq '.result.config // {}' "$WORK_DIR/current-config.json" >"$WORK_DIR/config.json"
    else
        printf '{}\n' >"$WORK_DIR/config.json"
    fi

    api_request GET "/zones/${zone_id}/dns_records?name=${public_hostname}&per_page=100" "$WORK_DIR/dns.json"
    count="$(jq --arg host "$public_hostname" '[.result[] | select(.name == $host)] | length' "$WORK_DIR/dns.json")"
    dns_id=''
    if [[ "$count" != 0 ]]; then
        [[ "$count" == 1 && -n "$tunnel_id" ]] || die '该域名已有其他 DNS 记录，请先处理冲突或换一个域名。'
        jq -e --arg host "$public_hostname" --arg target "${tunnel_id}.cfargotunnel.com" \
            '[.result[] | select(.name == $host)] | .[0] | .type == "CNAME" and .content == $target' "$WORK_DIR/dns.json" >/dev/null || die '该域名已有其他解析，本脚本不会覆盖。'
        dns_id="$(jq -r --arg host "$public_hostname" '.result[] | select(.name == $host) | .id' "$WORK_DIR/dns.json")"
        [[ "$dns_id" =~ ^[a-f0-9]{32}$ ]] || die 'Cloudflare 返回的 DNS ID 无效。'
    fi
    merge_ingress "$WORK_DIR/config.json" "$WORK_DIR/new-config.json"
}

merge_ingress() {
    jq --arg host "$public_hostname" --arg service "$origin_url" --argjson origin "$origin_request_json" '
        . as $config | (.ingress // []) as $rules |
        [$rules[] | select(.hostname == $host and (.path // "") != "")] as $paths |
        [$rules[] | select((.hostname // "") != "" or (.path // "") != "") | select(.hostname != $host)] as $keep |
        ([$rules[] | select(.hostname == $host and (.path // "") == "")] | first // {}) as $previous |
        ([$rules[] | select((.hostname // "") == "" and (.path // "") == "")] | last // {service: "http_status:404"}) as $fallback |
        (($previous.originRequest // {}) | del(.originServerName, .noTLSVerify, .matchSNItoHost, .caPool, .tlsTimeout, .http2Origin)) as $previous_origin |
        ($previous + {hostname: $host, service: $service, originRequest: ($previous_origin + $origin)}) as $route |
        {config: ($config + {ingress: ($paths + [$route] + $keep + [$fallback])})}
    ' "$1" >"$2"
}

ensure_cloudflared() {
    if dpkg-query -W -f='${Status}' cloudflared 2>/dev/null | grep -Fxq 'install ok installed' &&
        [[ -x /usr/bin/cloudflared ]] && /usr/bin/cloudflared tunnel run --help | grep -F -- '--token-file' >/dev/null; then
        return 0
    fi
    log '通过 Cloudflare 官方 APT 源安装 / 更新 cloudflared...'
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 120 -o "$WORK_DIR/cloudflare-main.gpg" https://pkg.cloudflare.com/cloudflare-main.gpg
    [[ -s "$WORK_DIR/cloudflare-main.gpg" ]] || die 'Cloudflare APT 密钥下载为空。'
    install -d -m 0755 /usr/share/keyrings
    install -m 0644 "$WORK_DIR/cloudflare-main.gpg" /usr/share/keyrings/cloudflare-main.gpg
    # Preserve an existing repository file; a missing source gets the official generic source.
    if [[ ! -e /etc/apt/sources.list.d/cloudflared.list ]]; then
        printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' >"$WORK_DIR/cloudflared.list"
        install -m 0644 "$WORK_DIR/cloudflared.list" /etc/apt/sources.list.d/cloudflared.list
    fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared
    [[ -x /usr/bin/cloudflared ]] && /usr/bin/cloudflared tunnel run --help | grep -F -- '--token-file' >/dev/null || die '需要支持 --token-file 的 cloudflared（2025.4.0 或更高）。'
}

apply_resources() {
    if [[ -z "$tunnel_id" ]]; then
        log '创建远程管理隧道...'
        jq -n --arg name "$tunnel_name" '{name: $name, config_src: "cloudflare"}' >"$WORK_DIR/create.json"
        api_request POST "/accounts/${account_id}/cfd_tunnel" "$WORK_DIR/created.json" "$WORK_DIR/create.json"
        tunnel_id="$(jq -r '.result.id' "$WORK_DIR/created.json")"
        [[ "$tunnel_id" =~ ^[a-f0-9-]{36}$ ]] || die 'Cloudflare 返回的隧道 ID 无效。'
    else
        log "复用同名隧道：${tunnel_name}（${tunnel_id}）。"
    fi
    # Check token access before changing hostname routes.
    api_request GET "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/token" "$WORK_DIR/token.json"
    jq -er '.result | select(type == "string" and length > 0)' "$WORK_DIR/token.json" >"$WORK_DIR/tunnel.token"
    log "创建 / 更新公开应用路由：${public_hostname} → ${origin_url}。"
    api_request PUT "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" "$WORK_DIR/configured.json" "$WORK_DIR/new-config.json"
    api_request GET "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" "$WORK_DIR/saved-config.json"
    jq -e --arg host "$public_hostname" --arg service "$origin_url" --argjson origin "$origin_request_json" '
        def tls_defaults: {originServerName: "", noTLSVerify: false, matchSNItoHost: false, caPool: "", tlsTimeout: 10, http2Origin: false};
        [.result.config.ingress[] | select(.hostname == $host and (.path // "") == "")] |
        length == 1 and (.[0].service == $service) and ((tls_defaults + (.[0].originRequest // {})) | contains($origin))
    ' "$WORK_DIR/saved-config.json" >/dev/null || die '路由或 TLS 参数保存后的校验失败，请检查 Cloudflare 路由配置。'
    log '公开应用路由及源站 TLS 参数已保存并校验。'
    if [[ -z "$dns_id" ]]; then
        log '创建代理 CNAME 解析...'
        jq -n --arg host "$public_hostname" --arg target "${tunnel_id}.cfargotunnel.com" \
            '{type: "CNAME", name: $host, content: $target, proxied: true, ttl: 1}' >"$WORK_DIR/create-dns.json"
        api_request POST "/zones/${zone_id}/dns_records" "$WORK_DIR/created-dns.json" "$WORK_DIR/create-dns.json"
        dns_id="$(jq -r '.result.id' "$WORK_DIR/created-dns.json")"
        [[ "$dns_id" =~ ^[a-f0-9]{32}$ ]] || die 'Cloudflare 返回的 DNS ID 无效。'
    else
        printf '{"proxied":true,"ttl":1}\n' >"$WORK_DIR/patch-dns.json"
        api_request PATCH "/zones/${zone_id}/dns_records/${dns_id}" "$WORK_DIR/patched-dns.json" "$WORK_DIR/patch-dns.json"
    fi
}

install_service() {
    local unit="cloudflared-vps-setup@${tunnel_id}.service"
    install -d -m 0700 "$TOKEN_DIR"
    install -m 0600 "$WORK_DIR/tunnel.token" "$TOKEN_DIR/${tunnel_id}.token"
    cat >"$WORK_DIR/service" <<SERVICE
${MANAGED_MARKER}
[Unit]
Description=VPS Setup Cloudflare Tunnel %i
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token-file ${TOKEN_DIR}/%i.token
Restart=on-failure
RestartSec=5s
TimeoutStopSec=45s

[Install]
WantedBy=multi-user.target
SERVICE
    install -m 0644 "$WORK_DIR/service" "$UNIT_FILE"
    jq -n --arg zone_id "$zone_id" --arg account_id "$account_id" --arg tunnel_id "$tunnel_id" --arg dns_id "$dns_id" \
        --arg hostname "$public_hostname" --arg origin "$origin_url" --arg unit "$unit" --argjson origin_request "$origin_request_json" \
        '{zone_id: $zone_id, account_id: $account_id, tunnel_id: $tunnel_id, dns_id: $dns_id, hostname: $hostname, origin: $origin, origin_request: $origin_request, unit: $unit}' >"$WORK_DIR/state.json"
    install -m 0600 "$WORK_DIR/state.json" "$STATE_DIR/${public_hostname}.json"
    systemctl daemon-reload
    systemctl enable "$unit"
    systemctl restart "$unit"
    systemctl is-active --quiet "$unit" || die "连接服务启动失败，请执行 journalctl -u ${unit} -n 50 --no-pager。"
    log "服务已启用开机启动：${unit}"
    log '检查 Cloudflare 连接状态...'
    local attempt status=''
    for attempt in {1..10}; do
        api_request GET "/accounts/${account_id}/cfd_tunnel/${tunnel_id}" "$WORK_DIR/status.json"
        status="$(jq -r '.result.status // "unknown"' "$WORK_DIR/status.json")"
        if [[ "$status" == healthy || "$status" == degraded ]]; then
            [[ "$status" != degraded ]] || warn '隧道已有连接，但当前状态为 degraded，请检查服务日志。'
            log "隧道连接成功，状态：${status}。"
            return 0
        fi
        sleep 2
    done
    die "域名和服务已配置，但暂未连接 Cloudflare（${status}）。请检查出站 TCP / UDP 7844 和 journalctl -u ${unit}。"
}

main() {
    require_environment
    WORK_DIR="$(mktemp -d -t vps-setup-cloudflare.XXXXXX)"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local zone_name public_hostname tunnel_name origin_url origin_server_name no_tls_verify origin_request_json
    local match_sni_to_host ca_pool tls_timeout http2_origin
    local zone_id account_id dns_id
    collect_inputs
    prepare_resources
    ensure_cloudflared
    apply_resources
    install_service
    log "配置完成：${public_hostname} → ${origin_url}"
    if [[ "$origin_url" == http://* || "$origin_url" == https://* ]]; then
        log "访问地址：https://${public_hostname}"
    else
        log 'SSH / TCP 服务需要客户端 cloudflared 配合连接。'
    fi
    log '可回到主菜单第 4 项，安装 cloudflared 自动更新任务。'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
