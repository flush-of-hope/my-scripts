# New Machine Setup

这个目录提供一个统一入口，用于调用仓库里已经整理好的 Debian 新机配置脚本。

目标是：新机器初始化时只需要运行一个入口脚本，然后通过菜单选择需要执行的配置，不再重复输入多条 `bash <(curl ...)` 命令。

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/flush-of-hope/my-scripts/main/new-machine/setup.sh)
```

也可以先下载再执行：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/flush-of-hope/my-scripts/main/new-machine/setup.sh \
  -o setup.sh

chmod +x setup.sh
sudo ./setup.sh
```

> 建议使用 `root` 运行。

---

## 菜单

入口脚本启动后会显示：

```text
============================================================
 New Machine Setup - Debian
============================================================

1) Debian VPS / TCP 调优
2) SSH 密钥管理
3) 安装 3x-ui
4) 安装 Cloudflared 自动更新任务
5) 安装 CrowdSec + nftables 防火墙
6) 执行推荐新机初始化流程
7) 查看当前状态
0) 退出
```

菜单默认循环运行。

执行完一个功能后会返回主菜单，只有输入：

```text
0
```

才会退出入口脚本。

---

# 调用的现有脚本

入口脚本不会复制各模块的业务逻辑，而是实时下载并调用仓库中的现有脚本。

这样以后只要更新原脚本，入口脚本就会自动使用最新版本。

## 1. Debian VPS / TCP 调优

调用：

```text
linux/tcp/Debian_VPS_Tuning.sh
```

主要用于 Debian VPS 的基础网络 / TCP 调优。

该脚本还会自动检查：

- `jq`
- `curl`
- `sha256sum`

缺少依赖时自动安装。

---

## 2. SSH 密钥管理

调用：

```text
linux/ssh/notPasswordLogin.sh
```

包含：

- 初始化 / 修复 SSH 密钥登录
- 添加新的 SSH 公钥
- 查看当前 SSH 公钥
- 删除 SSH 公钥
- 关闭密码登录，仅允许 SSH Key
- 重新开启密码登录
- 查看 SSH 实际生效配置

这个子脚本本身也是循环菜单。

进入 SSH Key Manager 后，需要选择：

```text
0
```

退出 SSH 子菜单，才会返回 New Machine Setup 主菜单。

多台电脑建议每台电脑使用独立 SSH Key，而不是复制同一个私钥。

例如：

```text
MacBook        -> Key 1
Office PC      -> Key 2
Home PC        -> Key 3
Termius        -> Key 4
```

---

## 3. 3x-ui

调用：

```text
3x-ui/install-3x-ui.sh
```

当前脚本默认：

- SQLite
- 面板端口 `8443`
- 输入域名
- 输入管理员账号 / 密码
- Let's Encrypt 域名证书
- ACME HTTP-01 使用 TCP `80`
- 内核支持时尝试启用 BBR

执行前请确保域名已经解析到当前服务器公网 IP。

---

## 4. Cloudflared 自动更新

调用：

```text
cloudflare/cloudflared-auto-update-installer.sh
```

注意：这个脚本 **不是 Cloudflare Tunnel 首次安装脚本**。

它只负责给已经通过 APT 安装好的 `cloudflared` 配置自动更新任务。

入口脚本会先检测：

```text
cloudflared
```

如果没有安装，则不会强行执行自动更新配置。

当前自动更新任务：

- 每天约 `04:30` 检查
- 带随机延迟
- 只有版本升级后才重启 `cloudflared.service`

---

## 5. CrowdSec + nftables

调用：

```text
CrowdSec/install-crowdsec-guard.sh
```

这个脚本不仅安装 CrowdSec，还会管理主机入站防火墙，因此建议最后执行。

当前公网入站策略：

```text
SSH   -> 自动检测端口并人工确认
80    -> 允许
443   -> 允许
8443  -> 公网禁止
其他   -> DROP
```

本机 localhost 仍可访问 `8443`，因此适合：

```text
Cloudflare Tunnel
        |
        v
127.0.0.1:8443
        |
        v
3x-ui
```

CrowdSec 脚本应用防火墙后带 SSH 安全验证和自动回滚机制。

执行时不要提前关闭当前 SSH 会话。

---

# 推荐新机执行顺序

入口脚本菜单中的：

```text
6) 执行推荐新机初始化流程
```

按照下面顺序执行：

```text
1. Debian VPS / TCP 调优
        |
        v
2. SSH 密钥管理
        |
        v
3. 3x-ui
        |
        v
4. Cloudflared 自动更新
        |
        v
5. CrowdSec + nftables
```

其中 CrowdSec 放在最后，是因为它最终会收紧公网入站端口。

Cloudflared 自动更新步骤只有检测到已经安装 `cloudflared` 时才会执行，否则自动跳过。

各子脚本原有的确认步骤不会被入口脚本取消。

例如：

- SSH 关闭密码前仍需要确认 Key 登录可用
- CrowdSec 仍需要确认 SSH 端口
- CrowdSec 防火墙仍需要新开 SSH 窗口测试
- 3x-ui 仍需要输入域名、账号和密码

因此入口脚本只是减少重复命令，不会绕过安全确认。

---

# 查看服务器当前状态

菜单：

```text
7) 查看当前状态
```

会检查：

- Debian 系统版本
- Kernel
- SSH 端口
- `PubkeyAuthentication`
- `PasswordAuthentication`
- 3x-ui 是否安装
- cloudflared 是否安装
- cloudflared 自动更新 timer
- CrowdSec 是否安装 / active
- `crowdsec_guard` nftables 表是否已经加载

---

# 设计原则

入口脚本本身尽量保持简单，只负责：

1. 环境检查
2. 下载已有脚本
3. 调用已有脚本
4. 提供统一菜单
5. 展示状态
6. 推荐执行顺序

不会把其他目录中的几千行逻辑重新复制到 `setup.sh`。

这样维护时只需要修改对应模块，例如：

```text
linux/ssh/notPasswordLogin.sh
```

入口脚本不需要同步复制 SSH 逻辑。

---

# 目录结构

```text
my-scripts/
├── 3x-ui/
├── CrowdSec/
├── cloudflare/
├── linux/
│   ├── ssh/
│   └── tcp/
└── new-machine/
    ├── setup.sh
    └── README.md
```
