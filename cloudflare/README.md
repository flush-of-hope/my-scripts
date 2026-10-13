# Cloudflare Tunnel 自动配置

`create-tunnel.sh` 在 Debian / Ubuntu（systemd）服务器上，通过 Cloudflare API 创建或复用远程管理隧道，配置公开域名的路由和 DNS，再启动本机连接服务。

## 使用方法

以 root 运行 `vps-setup`，选择 **12) 自动创建 CF 隧道 / 域名解析**。

也可以独立运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/flush-of-hope/my-scripts/main/cloudflare/create-tunnel.sh)
```

服务器需要能访问 Cloudflare API、官方软件源和 Tunnel 连接端点。脚本会在需要时安装 `curl`、`jq`、`ca-certificates`、`util-linux` 和 APT 版 `cloudflared`。

## 创建 API Token

在 [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) 创建一个自定义 Token：

| 范围 | 权限项 | 级别 |
| --- | --- | --- |
| Account（账户） | Cloudflare Tunnel | Edit（编辑） |
| Zone（区域） | DNS | Edit（编辑） |
| Zone（区域） | Zone | Read（读取） |

Account 资源选择隧道所属账户，Zone 资源选择要使用的域名。Zone 读取权限用于自动查询 Zone ID 和 Account ID；无需手动输入这些 ID。

只在服务器交互提示中输入 API Token。输入不回显，临时认证文件只允许 root 读取，退出时删除；API Token 不写入仓库、长期配置或命令行参数。

## 输入示例

| 输入项 | 示例 |
| --- | --- |
| Zone 域名 | `example.com` |
| 完整公开域名 | `panel.example.com` |
| 隧道名称 | `vps-hk-panel` |
| 本地服务地址 | `https://127.0.0.1:8443` |
| 源站证书域名（HTTPS） | `panel.example.com` |

Zone 应填写 Cloudflare 控制台中实际管理的域名，委派的子域也应填写该子域本身。域名需要在 Cloudflare 中处于 active 状态。

HTTPS 源站默认验证证书并设置 Origin Server Name。只有明确选择自签名证书选项，才会启用 `noTLSVerify`。

HTTP 示例：`http://127.0.0.1:8080`。SSH 示例：`ssh://127.0.0.1:24754`。SSH / TCP 公开服务需要客户端使用 cloudflared，不能直接当作普通 SSH IP 或端口连接。

## 重复运行与已有配置

- 同名的远程管理隧道会复用；本地管理隧道需要使用不同名称。
- 更新输入域名的默认路由，保留同域名的路径路由、其他域名、通配符路由、兜底规则及全局配置。
- 新的域名规则放在通配符规则之前，同域名的路径规则仍在默认规则之前。
- DNS 不存在时创建代理 CNAME，指向 `<隧道ID>.cfargotunnel.com`。
- 已有 CNAME 指向同一隧道时复用；其他 DNS 记录冲突时停止，不覆盖已有解析。
- 每个隧道使用独立的 `cloudflared-vps-setup@<隧道ID>.service`，原有 `cloudflared.service` 保留。
- 失败时保留已经创建的云端资源，显示隧道 ID；使用相同名称重新运行可继续配置。

## 服务和自动更新

连接 Token 保存在 `/etc/cloudflared/vps-setup/<隧道ID>.token`，权限为 `0600`。systemd 服务通过 `--token-file` 读取它；该选项需要 cloudflared 2025.4.0 或更高版本，脚本会检查支持情况。

服务启用开机启动。查看状态和日志：

```bash
systemctl status 'cloudflared-vps-setup@<隧道ID>.service' --no-pager
journalctl -u 'cloudflared-vps-setup@<隧道ID>.service' -n 50 --no-pager
```

最后检查 Cloudflare 的连接状态。`healthy` 只表示隧道已连接，源站服务仍需要正常运行；长时间未连接时检查出站 TCP / UDP `7844`。

完成后可选择 `vps-setup` 第 4 项安装每日自动更新任务。已有自动更新任务需要再执行第 4 项一次，更新到支持独立隧道服务的版本。只有 cloudflared 版本发生变化时，更新任务才会重启正在运行的默认服务和 vps-setup 隧道服务。

配置摘要保存在 `/var/lib/vps-setup/cloudflare/<公开域名>.json`，不包含 API Token 或连接 Token。

## 官方参考

- [通过 API 创建隧道、配置路由和 DNS](https://developers.cloudflare.com/tunnel/get-started/)
- [Zone 查询接口及权限](https://developers.cloudflare.com/api/resources/zones/methods/list/)
- [cloudflared 官方 APT 软件源](https://pkg.cloudflare.com/)
- [Tunnel 启动参数](https://developers.cloudflare.com/tunnel/reference/run-parameters/)
