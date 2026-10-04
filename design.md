# My Vibe Coding Workstation — 设计文档

> 隔离的 Vibe Coding 工作站。基于 **Podman + Quadlet** 的容器组自动化部署与**自动化卸载**。
> 设计核心不是「能跑起来」，而是**卸得干净、可重置、无残留**。

---

## 0. 第一原则：完全容器化

**本项目的一切功能性组件都在容器里运行。宿主机只提供 Podman + systemd。**

这条不是口号，它有一个可检验的推论：

> **宿主机的写入面必须收敛为一份可枚举的清单。**
> 任何落在清单之外的宿主写入，都是设计缺陷。

### 宿主的角色定位

| 宿主提供 | 宿主不提供 |
|---|---|
| Podman 5.8.7 | 任何服务运行时（Python/Node/Java/DB...） |
| systemd + Quadlet 生成器 | 任何语言运行时或包管理器依赖 |
| Linger（用户级服务常驻） | 任何工作站功能逻辑 |
| `~/.config/containers/systemd/`（单元落点） | 任何数据（全部在卷里） |

### 宿主的全部写入面（白名单）

部署后，宿主上只允许存在以下位置。**除此之外任何新增都是 bug**：

```
~/.config/containers/systemd/            # Quadlet 单元（由 config 生成）
~/.local/share/containers/storage/       # podman rootless 存储（镜像/卷）
~/.local/state/vibe-workstation/         # manifest.json + 日志
~/.config/vibe-workstation/              # 用户可改的配置覆盖
/run/user/$UID/                         # podman 运行时（临时，登出清空）
```

> ⚠️ 注意 `~/.local/share/containers/storage/` 是 podman 的共享存储，
> **卸载时绝不能整个删除** —— 用户可能有其他容器。
> 必须按 manifest 登记的资源逐个回收。这是 A2 与「不误伤」的分界线。

### 工具链

- install / uninstall / reset 一律为 **纯 POSIX shell**，只用 `bash` + coreutils + `podman`。
- **不引入** Python / Node / 容器化工具链。理由：工具链一旦容器化，就必须挂载 podman socket
  （等价于给容器 root 权限），既扩大攻击面，又让「卸载工具链自己」变成先有鸡还是先有蛋的递归问题。
- 脚本本身是**无状态**的：所有状态写入 manifest，脚本可随时删除重来。

---

## 1. 目标 / 约束 / 验收

### 目标
在一台 Bazzite(Silverblue) 主机上，用 Podman Quadlet 提供一套自包含的 Vibe Coding 工作站容器组，
一条命令部署，一条命令**彻底卸载**，且工作台本身可**重置到初始状态**。

### 硬约束（来自实测环境）
| 约束 | 实测值 | 影响 |
|---|---|---|
| 主机 OS | Bazzite 44 (Silverblue, `ID_LIKE=fedora`) | **不可变系统**：`/usr` 只读；一切变更必须落在 `/etc`、`/var`、`~` |
| Podman | **5.8.7** | 原生支持 Quadlet；支持 `.container/.network/.volume/.pod/.kube` |
| Quadlet 生成器 | `/usr/lib/systemd/system-generators/podman-system-generator` 存在 | 可用 systemd 单元驱动容器 |
| Linger | `felix` → `Linger=yes` | **rootless 用户级 Quadlet 可在登出后持续运行** |
| 网络后端 | `pasta` + `slirp4netns` 均存在 | rootless 网络可用 |
| `podman-compose` | **未安装** | 不作为依赖；`docker-compose` v5.5.1 存在但仅作可选 |
| 运行时目录 | `/run/user/1000` 在我的沙箱中为只读 | 沙箱假象，非主机真实状态 |

### 验收标准
- `A1` 一条命令完成部署，全部容器 healthy。
- `A2` **一条命令彻底卸载**，且卸载后磁盘上无残留（镜像 / 卷 / 网络 / 单元 / 配置 / 缓存）。
- `A3` 可重置：工作台能还原到「刚安装」的干净状态，无需重装。
- `A4` 卸载是**幂等**的：重复执行不报错、不误删。
- `A5` 卸载前有**dry-run** 预览，明确列出将要删除的东西。
- `A6` **宿主零依赖**：部署不安装任何宿主包，不改动 `/usr`（不可变系统上也做得到）。
- `A7` **写入面合规**：部署后宿主新增路径 ⊆ 第 0 节白名单；有自动化检查。
- `A8` 停止全部服务后的宿主状态，与从未部署过**无法区分**（除 podman 共享存储的固有目录外）。

### 非目标
- 不做 Kubernetes 编排（单机场景，Quadlet 足够）。
- 不追求多用户 / 多租户。

---

## 2. 主矛盾

**「功能完整的开发环境」 vs 「零残留卸载」** —— 二者天然冲突：
越完整的开发环境越倾向于在宿主留下全局状态（全局包、宿主配置、缓存、后台服务）；
而彻底卸载要求所有状态**可枚举、可定位、可回收**。

**主导约束：可卸载性优先。**
因此确立一条铁律：

> **凡是有状态的东西，都必须落在工作站自己的命名空间里，并且登记在册。**

推论（这些是设计决策，不是建议）：
1. 所有持久化数据 → **命名卷**或 `var/lib/...` 下的**专属子目录**，绝不散落。
2. 所有配置 → 由 `config/` 目录单一来源生成，不手改运行中的容器。
3. 不在宿主 `/usr`、宿主 home 根目录直接安装软件包。
4. 卸载脚本按**登记清单**回收，而非靠 `podman system prune` 这种大范围误伤操作。

---

## 3. 容器组（5 个）

| # | 名称 | 角色 | 状态性 | 可替换 |
|---|---|---|---|---|
| 1 | **Home** | 本项目主页 / 功能入口门户（**纯导航 + 状态展示**，不做反向代理） | 无状态（配置驱动） | — |
| 2 | **Agent** | AI 编码代理，默认 **DeepSeek Harness** | 会话/凭据 | **✅ 可替换**（接口化） |
| 3 | **Forgejo** | 自托管 Git 服务 | 强状态（仓库数据） | — |
| 4 | **OpenCloud** | 云盘 / 文件同步与协作（`opencloudeu/opencloud-rolling`） | 强状态 | — |
| 5 | **Workbench** | 完整可用的开发系统（**可重置/可恢复/可重装**） | 需快照 | — |

### OpenCloud 实测结论（已确认产品）

已确认为 **OpenCloud**（`opencloud-eu`，从 ownCloud Infinite Scale 分叉的德国项目），
**不是 Nextcloud**。官方部署参考 `opencloud-eu/opencloud-compose`。

镜像与端口（来自官方 compose 实测）：

| 项 | 值 |
|---|---|
| 主镜像 | `opencloudeu/opencloud-rolling:8.0.1` |
| 主服务内部端口 | **9200** |
| 反向代理 | **Traefik v3.7.12，官方注明「always enabled and can't be disabled」** |
| 持久化 | `opencloud-config` → `/etc/opencloud`；`opencloud-data` → `/var/lib/opencloud` |
| 运行用户 | `1000:1000` |

**三条对本项目有实质影响的硬约束：**

1. 🔴 **端口 8000-9999 被 OpenCloud 内部占用**
   官方 `.env.example` 原文：
   > *"Don't use ports in the range of 8000-9999 and 5232 as those ports are used internally"*
   这**直接否决了**把工作站端口规划放在 8xxx/9xxx 段的方案。详见第 9 节端口规划。

2. 🔴 **OpenCloud 强依赖域名 + HTTPS，而非纯端口访问**
   它硬编码 `OC_URL: https://${OC_DOMAIN}`，并通过 Traefik 按 `Host(${OC_DOMAIN})` 路由。
   纯 `http://localhost:port` 访问**不是官方支持的路径**。
   → 需要在本机做 hosts 映射（如 `cloud.workstation.local`）+ 自签证书（`INSECURE=true`）。

3. 🔴 **官方 Traefik 配置挂载 Docker socket**
   `${DOCKER_SOCKET_PATH:-/var/run/docker.sock}:/var/run/docker.sock:ro`
   → 违背第 0 节的隔离原则，且 Podman 环境下 socket 路径不同（`/run/user/1000/podman/podman.sock`）。
   → **对策**：改用官方 `external-proxy/` 配置（假定已有反代），由我们自己的反代容器承担；
     或自行编写 Traefik 的静态配置，**不挂 socket**（用 file provider 而非 docker provider）。
     这是本项目需要**自行解决**的技术点，不是照抄官方 compose 就行。

> 结论：容器 4 **不是一个容器，而是一个小型服务组**
> （opencloud + traefik + 可选 collabora/keycloak）。
> 这会显著影响卷规划、启动顺序与卸载清单。见第 9 节。



### Workbench 的环境语义
你提到它要同时承担**开发环境 / 测试环境 / 预生产环境**。这三种语义建议用**同一套基础镜像 + 三份不同的卷/网络命名空间**实现：

```
workbench-dev      → 日常开发，允许脏
workbench-test     → 测试，从干净基线起
workbench-staging  → 预生产，只接受已验证产物
```

三者共享镜像层（省磁盘），但**数据卷与网络完全隔离**（互不污染）。

---

## 4. Home（门户）的设计取向

你的原话先要密码，随后又说不要 —— **记录为：不需要认证**。
（若之后想要，可加一层反向代理或 `basic auth`，不改动容器拓扑。）

**门户职责边界（已定）**：纯导航 + 状态展示。**不做统一反向代理网关**。
理由：网关化会让门户成为全站单点故障，且要处理各服务的路径前缀改写（Forgejo / 云盘对子路径支持不一）。
代价是所有服务各自暴露端口 —— 由端口规划（见待确认项）统一收敛。

「必须做得漂亮」→ 这被当作**明确验收项**，不是修辞。设计取向：
- 深色为主、单一强调色，无饱和度冲突；
- 卡片式功能入口，每个服务一张卡（名称 / 图标 / 简介 / 状态灯 / 一键打开）；
- 状态灯**真实反映**容器健康状态（运行时探测，非写死）；
- 响应式，手机也能看；
- 零构建步骤的纯静态前端（HTML/CSS/少量 JS），避免为了门户引入 node 工具链。

---

## 5. 目录布局（单一来源）

```
My Vibe Coding Workstation/
├── README.md
├── design.md                 # 本文档
├── .gitignore
├── quadlet/                  # Quadlet 单元（部署的唯一事实来源）
│   ├── workstation.network
│   ├── home.container
│   ├── agent.container
│   ├── forgejo.container
│   ├── opencloud.container
│   ├── workbench.container
│   └── *.volume
├── config/                   # 各服务的配置源
│   ├── home/
│   ├── forgejo/
│   └── ...
├── scripts/
│   ├── install.sh            # 部署
│   ├── uninstall.sh          # 彻底卸载（支持 --dry-run）
│   ├── reset.sh              # 重置 / 恢复 / 重装 Workbench
│   └── lib/                  # 公共函数（日志、清单登记）
└── docs/
    ├── ARCHITECTURE.md
    ├── UNINSTALL.md          # 卸载到底删了什么（可审计）
    └── FAQ.md
```

---

## 6. 零残留卸载策略

这是本项目**最核心**的部分。卸载分三层，逐层加深：

```
uninstall.sh --dry-run     # 只打印将删除什么，不执行
uninstall.sh               # 停服务 + 移除单元 + 删容器/网络/卷
uninstall.sh --purge       # 以上 + 删镜像 + 删用户级配置 + 删数据
uninstall.sh --nuke        # 以上 + 清理 podman 残留 (system prune)
```

**登记清单机制**：部署时把本次创建的资源 id 写入
`~/.local/state/vibe-workstation/manifest.json`。
卸载时**按清单精确回收**，而非盲目扫描。
好处：不误删用户的其他容器；重复卸载幂等；可审计（`docs/UNINSTALL.md` 列出每一项）。

**卸载后自检**：脚本最后执行残留扫描，列出任何仍存在的相关资源，非空则以非零码退出。

---

## 7. 决策记录与待确认项

### 已确认（本轮）

| # | 议题 | 决策 |
|---|---|---|
| D1 | 容器化范围 | **宿主零依赖**：所有功能性组件在容器内；宿主只提供 Podman + systemd |
| D2 | 工具链形态 | **纯 POSIX shell**，不引入语言运行时、不容器化工具链 |
| D3 | 门户角色 | **纯导航 + 状态展示**，不做反向代理网关、不做 SSO |
| D4 | 门户认证 | **不需要密码**（你的语音中先要后撤，记录为不需要） |
| D5 | 部署机制 | Podman Quadlet + rootless 用户级 systemd（依赖已实测的 `Linger=yes`） |
| D6 | 卸载策略 | manifest 登记清单精确回收，**禁止** `podman system prune` 式大范围操作 |
| D7 | 容器 4 | **OpenCloud**（`opencloud-eu` / ownCloud Infinite Scale 系），非 Nextcloud |
| D8 | 端口段 | ~~99999~~ **无效**（超出 0-65535）；改为 **7xxx 段**，见第 9 节 |

### 待确认（阻塞项）

1. 🟡 **Workbench 三环境形态** —— 我的倾向：**三个容器共享镜像层，数据卷与网络完全隔离**。
   备选：单容器 + 三种快照。前者隔离更硬，后者省资源。
4. 🟡 **Agent 容器「可替换」的边界** —— 仅换镜像，还是需同时并存多个不同 agent 实例？
5. 🟡 **DeepSeek Harness 的接入方式** —— 宿主已有 DSH 安装
   (`~/.local/share/fnm/.../node_modules/@deepseek-ai/dsh/`)。
   是容器内独立安装，还是复用宿主安装并挂载进去？后者违反 D1 的零依赖原则，
   我倾向**容器内独立安装**。
6. 🟢 **Forgejo / 云盘 的对外访问方式** —— 仅局域网，还是需要对外暴露？影响 TLS 与网络设计。

---

## 8. 端口规划

### 关于 `99999`

❌ **无效端口**。TCP/UDP 端口号是 16 位无符号整数，合法范围 **0–65535**。
`99999` 会被内核直接拒绝（`bind: Address already in use` 之外的 `EINVAL` 类错误）。
猜测你想表达的是 **9999**（探索性端口的常见上界）。

### 为什么最终不选 9xxx

两个独立理由：

1. **OpenCloud 内部占用 8000-9999**（官方明文警告，见 4.1）。
2. **你机器上 `9091` 已被占用**（实测 `ss -tlnp`：`127.0.0.1:9091` 有监听，疑似 transmission）。
   9xxx 段不是干净的。

### 推荐方案：`7xxx` 段

实测你当前监听端口：`53, 631, 1053, 3080, 3081, 3082, 5355, 7891, 7897, 9091, 38463`。
**整个 7000-7499 段完全空闲**，仅需避开 7891/7897。

| 服务 | 端口 | 说明 |
|---|---|---|
| **Home 门户** | `7000` | 入口，导航 + 状态展示 |
| **Agent (DSH)** | `7001` | 可替换的 agent |
| **Forgejo** | `7002` | Git 服务（SSH 另用 `7022`） |
| **OpenCloud** | `7003` | 经自建反代；内部 9200 不暴露 |
| **Workbench dev** | `7010` | |
| **Workbench test** | `7011` | |
| **Workbench staging** | `7012` | |

> 全部绑定 `127.0.0.1`（仅本机可访问），除非你需要局域网访问 —— 见待确认项 6。

---

## 9. 当前进度

- [x] 本地 git 仓库初始化
- [x] GitHub 远程仓库创建并推送
- [x] 环境实测（OS / podman / quadlet / linger / 网络）
- [x] 设计文档（本文件）
- [ ] 开放问题确认
- [ ] Quadlet 单元编写
- [ ] Home 门户实现
- [ ] install / uninstall / reset 脚本
- [ ] 实测验收 A1–A5
