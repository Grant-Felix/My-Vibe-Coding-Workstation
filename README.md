# Vibe Coding Workstation

> 隔离的容器化 Vibe Coding 工作站。基于 **Podman + Quadlet**，
> 一条命令部署，一条命令**彻底卸载**（无账本、无残留）。

当前版本：**V.26.10.4-1**（见 `VERSION`）

---

## 这是什么

一台机器上的**编排纪律**：用一份声明，跑起一组自托管服务，并且能干净地拆掉。

不是操作系统，不是内核。凡 systemd / Podman / Quadlet 已经会做的事，一律不重造 ——
本项目只做它们不做的那一件事：**把声明变成产物**。

---

## 容器组

| 服务 | 地址 | 说明 |
|---|---|---|
| **Home 门户** | `vibecotion.wraindrock.com` | 导航 + 状态展示（纯静态） |
| **Agent** | `agent.vibecotion.wraindrock.com` | DeepSeek Harness，**可替换** |
| **Forgejo** | `git.vibecotion.wraindrock.com` | 自托管 Git |
| **OpenCloud** | `cloud.vibecotion.wraindrock.com` | 文件存储与同步 |
| **Workbench** | `dev/test/staging.vibecotion.wraindrock.com` | 可重置的开发/测试/预生产环境 |

全部容器在**同一个 Pod** 内，对外只暴露**一个端口 `9999`**；
公网经 **Cloudflare Tunnel** 出站接入，**宿主不开放任何入站端口**。

---

## 快速开始

```bash
# ① 放好 Cloudflare 隧道凭证（不入库）
#    先 cd 到本项目根目录，再执行 —— 脚本用相对路径。
mkdir -p ~/.config/vibecotion && chmod 700 ~/.config/vibecotion

# ⚠️ 下面这行里的「你的真实 token」必须替换成 Cloudflare 面板上的实际值。
#    不要照抄尖括号文字 —— 那会被当成真实凭证写进去，隧道连不上。
#    真实 token 形如 eyJhIjoi...（通常上百字符）。
printf 'TUNNEL_TOKEN=%s\n' '你的真实 token' > ~/.config/vibecotion/cloudflared.env
chmod 600 ~/.config/vibecotion/cloudflared.env

# ② 部署
./scripts/install.sh
```

> 凭证在两处获取：Cloudflare 面板 → **Zero Trust** → **Networks** → **Tunnels** → 你的隧道 → 复制 token。
> 安装脚本会校验它**不是占位符、长度合理**，不合格会明确报错而不是静默通过。

访问 <https://vibecotion.wraindrock.com>（需先在 Cloudflare 面板配好隧道路由）。

---

## 日常命令

| 命令 | 作用 |
|---|---|
| `./scripts/install.sh` | 部署（渲染产物 → 构建镜像 → 启动服务） |
| `./scripts/render.sh` | 重新渲染产物（改声明后执行） |
| `./scripts/render.sh --dump` | 打印组合后的声明，**不写文件** |
| `./scripts/render.sh --check` | 校验产物与声明是否一致 |
| `./scripts/render.sh --dry-run` | 预览将要做的改动 |
| `./scripts/reset.sh status` | 查看各服务状态 |
| `./scripts/reset.sh workbench dev` | 重置某个环境到初始状态 |
| `./scripts/uninstall.sh --dry-run` | **预览卸载**（推荐先跑） |
| `./scripts/uninstall.sh` | 卸载（保留凭证与数据卷） |
| `./scripts/uninstall.sh --purge` | 卸载并删除镜像与凭证 |
| `./scripts/release.sh` | 递增版本号、同步各处、打 tag |

---

## 设计要点

### 声明是唯一真源，且被强制

改 `workstation.yaml`，然后跑 `render.sh`。声明与 `quadlet/` **双向校验** ——
任一方多出条目就报错，不会静默漂移。

### 分层组合

```
空根 → workstation.yaml → workstation.local.yaml → --patch <file>
```

基线可提交，个人差异放 `workstation.local.yaml`（已被 gitignore）。
覆盖**按 id 定位**（`services.forgejo.port`），不依赖顺序。

### 无账本卸载

**没有 `manifest.json`。** 归属由统一前缀 `vibecotion-` 标识，
卸载 = 删除这些产物。账本会漂移，前缀不会。

含 API 凭证的卷（`vibecotion-agent-dsh`）**默认保留**，仅 `--purge` 删除。

### 宿主写入面（白名单）

```
~/.config/containers/systemd/    # Quadlet 产物
~/.config/vibecotion/            # 网关配置 + 门户 + 凭证
```

除此之外宿主不应新增任何东西。卸载后残留自检会验证这一点。

---

## 目录

```
workstation.yaml      # 声明（唯一真源）
VERSION               # 版本号（权威值）
quadlet/              # Quadlet 单元（渲染源）
config/gateway/       # Caddy 路由
config/home/          # 门户静态页
agent/                # Agent 镜像（DSH）
workbench/            # Workbench 镜像
scripts/              # 渲染 / 部署 / 卸载 / 重置 / 发版
design.md             # 完整设计文档与决策记录
```

完整推理见 **[design.md](design.md)**。

---

## 宿主要求

| 项 | 要求 | 实测环境 |
|---|---|---|
| OS | Fedora Atomic 系（不可变） | Bazzite 44 |
| Podman | ≥ 5.0 | 5.8.7 |
| systemd | ≥ 252 | 259 |
| Linger | 开启（服务登出后常驻） | `loginctl enable-linger` |
