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
| 4 | **Open Cloud** | 云盘 / 文件同步与协作 | 强状态 | — |
| 5 | **Workbench** | 完整可用的开发系统（**可重置/可恢复/可重装**） | 需快照 | — |

### 关于「Open Cloud」的标注
> ⚠️ **待确认**：你说的「open cloud」我不确定具体指哪个产品。
> 我的候选猜测：**Nextcloud**（最常见）、OpenCloud（ownCloud 系）、或 Sealafile。
> 请给出准确名字 / 镜像名 —— 这会直接决定数据目录布局和卸载清单。
> 在确认前，设计里按「一个自托管云盘服务」抽象处理。

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

### 待确认（阻塞项）

1. 🔴 **「Open Cloud」是哪个服务？** —— 候选：Nextcloud / OpenCloud / SeaFile。
   直接决定数据目录布局与卸载清单，猜错会导致容器 4 返工。
2. 🔴 **端口规划** —— 是否统一用某个端口段？门户需读取各服务端口来生成入口链接。
3. 🟡 **Workbench 三环境形态** —— 我的倾向：**三个容器共享镜像层，数据卷与网络完全隔离**。
   备选：单容器 + 三种快照。前者隔离更硬，后者省资源。
4. 🟡 **Agent 容器「可替换」的边界** —— 仅换镜像，还是需同时并存多个不同 agent 实例？
5. 🟡 **DeepSeek Harness 的接入方式** —— 宿主已有 DSH 安装
   (`~/.local/share/fnm/.../node_modules/@deepseek-ai/dsh/`)。
   是容器内独立安装，还是复用宿主安装并挂载进去？后者违反 D1 的零依赖原则，
   我倾向**容器内独立安装**。
6. 🟢 **Forgejo / 云盘 的对外访问方式** —— 仅局域网，还是需要对外暴露？影响 TLS 与网络设计。

---

## 8. 当前进度

- [x] 本地 git 仓库初始化
- [x] GitHub 远程仓库创建并推送
- [x] 环境实测（OS / podman / quadlet / linger / 网络）
- [x] 设计文档（本文件）
- [ ] 开放问题确认
- [ ] Quadlet 单元编写
- [ ] Home 门户实现
- [ ] install / uninstall / reset 脚本
- [ ] 实测验收 A1–A5
