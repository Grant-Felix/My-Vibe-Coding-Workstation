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
~/.local/state/vibecotion/         # manifest.json + 日志
~/.config/vibecotion/              # 用户可改的配置覆盖
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

## 1.5 与姊妹项目 Wraindrock 的关系

同一台机器、同一域名下存在姊妹项目 **`~/项目/Wraindrock`**（2026-10-01 建立）。
本项目与它的关系必须明确，否则两边设计会互相漂移。

### 定位

> **本项目是独立的，并且是「全新的 Wraindrock」。
> 它只解决当前的一部分需求（隔离容器工作站），是未来 Wraindrock 的一块拼图。**

（用户决策，2026-10-04）

### 从 Wraindrock 继承的纪律

Wraindrock 的决策记录（`docs/决策记录.md`）是**上一代失败换来的**，以下教训同样成立：

| 教训 | 出处 | 本项目处置 |
|---|---|---|
| 上一代死于「用造操作系统的力气解决装软件的问题」 | §1 主要矛盾 | 不造内核；systemd/podman/quadlet 会做的一律不重造 |
| **记账是冗余的，账本本身会漂移** | D2 | ⚠️ **与现存 `manifest.json` 冲突，见下** |
| 模块契约里没有逃生舱（无 install.sh / hooks） | D3 | 本项目当前**未遵守**：install.sh 执行任意步骤 |
| 只做「声明 → 产物」，产物是派生物不入库 | D1 | 尚未过渡 |

### 对齐情况（2026-10-04 更新）

| 项 | Wraindrock | 本项目 | 状态 |
|---|---|---|---|
| 卸载机制 | 声明式：状态即真源，卸载 = 删产物 | **声明式：状态即 `workstation.yaml`，卸载 = 删产物** | ✅ **已对齐** |
| 归属标识 | 前缀 `wraindrock-` | 前缀 `vibecotion-` | ✅ 同机制 |
| 陈旧产物 | `find_stale()` 自动清理 | `render.sh` 的 `cleanup_stale()` | ✅ 同机制 |
| 入口 | `Network=host` + `127.0.0.1:8080`，不开入站端口 | **Pod 端口映射 `9999`** | 有意选择（D16） |
| 模块初始化 | 用户手动 `wrd exec` 发起 | install.sh 自动执行 | ⚠️ 仍不一致 |
| 渲染器语言 | Python 3 | **纯 POSIX shell**（无运行时依赖） | 有意选择（D2） |

> **`manifest.json` 已彻底移除。** 这是本项目此前唯一「未被论证的偏离」，
> 现已按用户决定改正（2026-10-04）。**不存在账本，因此不存在账本漂移。**
> 仍存的一处差异是「模块初始化是否自动」，属功能性取舍，非状态管理问题。

### 澄清：端口 9999 与 Wraindrock D5 并不冲突

Wraindrock D5 选 `127.0.0.1:8080` 是**因为当时无特权**（实测 `CapBnd` 为空、
`ip_unprivileged_port_start=1024`）。但 **9999 > 1024，rootless 本来就能绑**，不需要特权。

真正的区别不是「要不要特权」，而是**「是否把端口暴露到宿主网络」**：
- Wraindrock：不暴露（隧道直连回环）
- 本项目：暴露 9999 到宿主（D16，有意为之）

这是**取舍**，不是**冲突**。

---

## 2. 主矛盾

**「功能完整的开发环境」 vs 「零残留卸载」** —— 二者天然冲突：
越完整的开发环境越倾向于在宿主留下全局状态（全局包、宿主配置、缓存、后台服务）；
而彻底卸载要求所有状态**可枚举、可定位、可回收**。

**主导约束：可卸载性优先。**
因此确立一条铁律：

> **凡是有状态的东西，都必须落在工作站自己的命名空间里，且归属可由前缀推导。**

推论（这些是设计决策，不是建议）：
1. 所有持久化数据 → **命名卷**，绝不散落。
2. 所有配置 → 由 `workstation.yaml` 声明 + `config/` 单一来源**渲染**生成，不手改产物。
3. 不在宿主 `/usr`、宿主 home 根目录直接安装软件包。
4. 卸载 = **删除以 `vibecotion-` 开头的产物**，**无账本**。
   绝不使用 `podman system prune` 这种大范围误伤操作。

**为什么不记账**（继承 Wraindrock D2 的论证）：
命令式脚本执行一堆副作用，才需要把每一条记进 `manifest.json` 供卸载回放。
一旦改成声明式，副作用即**渲染产物**，其路径由实例名与前缀唯一决定 ——
记账是冗余的，而**账本本身会漂移**（账本与现实的偏差无从察觉，
还得再写一个 reconcile 去对账，于是又长出一个内核部件）。

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
`~/.local/state/vibecotion/manifest.json`。
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
| D8 | 端口段 | `99999` **无效**（超出 0-65535）。最终：**对外唯一端口 `9999`**，其余为 Pod 内部端口 |
| D9 | 域名 | `vibecotion.wraindrock.com`（Cloudflare 托管，**已开启代理**） |
| D10 | 入口形态 | `9999` 后为**独立网关容器**（非门户兼任），门户保持纯导航 |
| D11 | 对外暴露方式 | **Cloudflare Tunnel**（`cloudflare/cloudflared` 容器，出站连接） |
| D12 | 路由方式 | **按域名**（`Host(...)` 匹配），非路径路由 |
| D13 | 隧道凭证 | token 存于**本地 gitignored 文件**，**绝不入库**（仓库为 Public） |
| D14 | Agent 接入 | **DSH 在容器内独立安装**，不挂载宿主安装（维持隔离与可卸载性） |
| D15 | 与 Wraindrock 关系 | **独立项目**，定位为「全新的 Wraindrock」，只覆盖其中一个子集需求 |
| D16 | 入口模式 | 保留 **Pod 端口映射 9999**（不采用 Wraindrock D5 的 Network=host + 127.0.0.1:8080） |

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

### 最终方案：单端口 `9999`

**决策（用户指定）**：Pod 对外**只映射一个端口 `9999`**，其余全部为 Pod 内部端口映射。

实测 `9999` 在本机**完全空闲**（当前监听：`53, 631, 1053, 3080, 3081, 3082, 5355, 7891, 7897, 9091, 38463`）。

| 层 | 端口 | 可见性 |
|---|---|---|
| **对外唯一入口** | `9999` | 映射到宿主，唯一 |
| Home 门户 | 内部 `8080` | Pod 内 |
| Agent (DSH) | 内部 `3080` | Pod 内 |
| Forgejo | 内部 `3000`（SSH `2222`） | Pod 内 |
| OpenCloud | 内部 `9200` + Traefik | Pod 内 |
| Workbench dev/test/staging | 内部各自 | Pod 内 |

> **关于「OpenCloud 不要用 8000-9999」的澄清**：
> 那条警告针对的是**共享宿主网络下的端口冲突**。Pod 内各容器处于同一 network namespace，
> 内部端口由我们统一编排、互不重叠即可，与宿主的 `9999` 不冲突。
> **该警告在我们的架构下不构成约束** —— 但不能在 Pod 内重复占用同一内部端口。

### 关键推论：单端口 ⟹ 必须做路由（不可回避）

**浏览器在 Pod 外，够不到 Pod 内部端口。** 因此「从主页跳转到 agent」这个动作，
浏览器实际发起的是对 `9999` 的请求。要让它到达正确容器，`9999` 背后**必须有转发能力**。

这不是设计偏好，是约束的数学推论：

```
对外一个端口 + 能跳到任意模块  ⟹  入口必须能按规则分发
```

**采用的形态**：`9999` 后面是**网关容器**（Caddy），职责：
1. `/` → Home 门户（纯静态导航页）
2. 其余路径/域名 → 转发到对应服务容器

门户本身**仍是纯导航**（不承担转发），转发由**独立网关容器**完成。
好处：门户挂掉只影响导航页，各服务仍可直接访问；职责不纠缠。

### 路由方式：待定（域名 vs 路径）

见下方待确认项。倾向**域名路由**，因 OpenCloud 硬依赖 `Host(...)` 匹配。

---

## 9. 域名与对外暴露：`vibecotion.wraindrock.com`

### 实测结果

| 查询 | 结果 | 判读 |
|---|---|---|
| NS | `athena.ns.cloudflare.com` / `jason.ns.cloudflare.com` | 域名托管在 **Cloudflare DNS** |
| `vibecotion.wraindrock.com` A | `172.67.133.185`, `104.21.5.186` | **Cloudflare 共享代理 IP** |
| Cloudflare 边缘证书 | `CN=wraindrock.com`，Let's Encrypt (YE2) | 由 **Cloudflare 边缘**签发 |
| HTTPS 响应 | **HTTP 530**，`server: cloudflare`，`cf-ray: ...-HKG` | **Cloudflare 回源失败**（Origin DNS error） |

### 判读

1. **该子域名记录为「已代理」（橙云 Proxied）**，不是 DNS-only。
   证据：解析到 `172.67.x` / `104.21.x`（Cloudflare anycast 段），而非源站 IP。

2. **当前 `530`**：Cloudflare 能解析该主机名，但**找不到可达的源站**。
   即：Cloudflare 侧的源站地址没配好（或源站离线）。这是一个**配置问题，需要你在 Cloudflare 面板处理**。

3. ⚠️ **本机 DNS 被代理劫持**
   实测 `getent` / `dig @1.1.1.1` 均返回 `198.18.0.25` —— 这是 **RFC 2544 基准测试网段**，
   是 Clash 类代理 **fake-IP 模式**的特征。说明你本机有透明代理（呼应监听的 `7891`/`7897`）。
   → **本机自测域名时必须绕过代理**（用 DoH，或把域名加入直连规则），否则看到的 IP 是假的。

### 架构影响：TLS 终止点上移，但回源是难点

Cloudflare 代理模式下：**TLS 在 Cloudflare 边缘终止**，浏览器到边缘是 Cloudflare 的可信证书。
这对我们**有利**：
- ✅ **不再需要自签证书**，也不再需要在本机信任内部 CA。
- ✅ OpenCloud 硬编码的 `OC_URL: https://${OC_DOMAIN}` **天然满足**（对外就是 HTTPS）。
- ⚠️ 但 **Cloudflare 到源站这一段**仍需处理：
  - 用 **Cloudflare Tunnel**（`cloudflared` 容器）→ **最契合本项目**：
    出站连接，**无需公网 IP、无需端口转发、无需暴露 `9999` 到公网**。
    且 `cloudflared` 是**一个容器**，天然符合「完全容器化」与「可干净卸载」。
  - 或 DNS-only + 公网端口转发 → 需要公网可达 + 端口映射权限，
    且要处理家庭宽带的动态 IP（DDNS），**可卸载性更差**（路由器上留配置）。

> **已采纳 Cloudflare Tunnel**。它让「对外唯一端口」变成「对外零端口」：
> 流量走 cloudflared 出站隧道直达 Pod 网关，**宿主不需要开放任何入站端口**。
> 这比映射 `9999` 到公网**更安全**，也更符合隔离目标。
> 若你仍希望局域网内用 `9999` 直连，两者可**并存**（局域网直连 9999，公网走隧道）。

### 隧道凭证的安全处理

```
实测 token 载荷：
  account tag : b2a7bb7cc6bc198ddf8b60051c78226c
  tunnel id   : be1ad0ec-090f-4a09-9bb9-17def19c0e24
  secret      : 48 字符（不记录）
```

**存放位置**：`~/.config/vibecotion/cloudflared.env`（`chmod 600`），**不属于仓库**。

**三条硬规则**：
1. **绝不提交入库** —— 本仓库是 **Public**，token 等同于隧道凭证。
2. 部署时由 `install.sh` **从该文件读取**并注入容器环境变量（`TUNNEL_TOKEN`），
   **不硬编码进 Quadlet 单元**（Quadlet 单元要入库）。
3. 卸载时**一并删除**该凭证文件（见第 6 节 manifest 清单）。

> ⚠️ **建议你事后轮换此 token**：它已出现在对话记录中。
> Cloudflare 面板 → Zero Trust → Networks → Tunnels → 该隧道 → 重新生成凭证即可。
> 轮换后只需更新本地那个文件，无需改动任何入库代码。

### 域名规划

统一使用 `vibecotion.wraindrock.com` 的子域，全部指向同一隧道：

| 主机名 | 目标 | 说明 |
|---|---|---|
| `vibecotion.wraindrock.com` | Home 门户 | 主入口 |
| `agent.vibecotion.wraindrock.com` | Agent 容器 | Vibe 开发 |
| `git.vibecotion.wraindrock.com` | Forgejo | 代码托管 |
| `cloud.vibecotion.wraindrock.com` | OpenCloud | 存储（**必须独立域名**，其硬依赖 `Host` 匹配） |
| `dev.vibecotion.wraindrock.com` | Workbench dev | |
| `test.vibecotion.wraindrock.com` | Workbench test | |
| `staging.vibecotion.wraindrock.com` | Workbench staging | |

> 通配符证书 + 通配符隧道路由（`*.vibecotion.wraindrock.com`）可省去逐个配置，
> 但需在 Cloudflare 面板为每条主机名配置 Tunnel 的 Public Hostname 映射。

### Cloudflare 面板配置核查（实测 + 截图）

**隧道名**：`Wraindrock`，id `be1ad0ec-090f-4a09-9bb9-17def19c0e24`

面板三条路由（**已由用户修正后**，实读）：

| 顺序 | 目标 | 服务 |
|---|---|---|
| 1 | `www.wraindrock.com` | `https://localhost:9999` |
| 2 | `vibecotion.wraindrock.com` | `https://localhost:9999` |
| 3 | `*.wraindrock.com` | `https://localhost:9999` |

**修正验证（DNS 实测）**：

| 项 | 修正前 | 修正后 |
|---|---|---|
| P1 拼写 | `vvibecotion` 存在 / `vibecotion` NXDOMAIN | ✅ 反转：`vibecotion` `Status:0`；`vvibecotion` `Status:3` |
| P3 端口 | 45677/45678/45679 三个独立端口 | ✅ 统一为 `9999` |
| P2 目标主机名 | `localhost` | ⬜ **待改**，见下 |

**发现三个问题：**

#### 🔴 P1：主机名拼写不符（已用 DNS 证实）

| 主机名 | DNS 结果 | 结论 |
|---|---|---|
| `vibecotion.wraindrock.com`（单 v，需求） | `Status:3` **NXDOMAIN** | **记录不存在** |
| `vvibecotion.wraindrock.com`（双 v，面板） | `Status:0` → `172.67.133.185` | 记录存在 |

面板多输了一个 `v`。**两条路可选**：改面板为单 v，或改用双 v 作为正式域名。

#### 🟡 P2：`localhost` 取决于 cloudflared 的部署方式（待定）

Cloudflare Tunnel 的 `localhost` 指 **cloudflared 容器自身**，非宿主机。

| cloudflared 部署方式 | 正确目标 |
|---|---|
| 在**同一 Pod** 内（**本项目采用**） | `http://gateway:9999`（Pod 内容器名） |
| `--network host` | `http://localhost:9999` |

本项目采用 **Pod 内**部署，故面板应填 `http://gateway:9999`。

另：面板当前为 `https://`，而网关仅监听明文 HTTP（Pod 内部，外层已由 Cloudflare 加密），
`https://` 会导致 **TLS 握手失败**，应改为 `http://`。

**最终目标值**：`http://gateway:9999`

#### 关于当前 `530`

`vibecotion.wraindrock.com` 与 `www.wraindrock.com` 实测均返回 **HTTP 530**。
这是**预期状态**：隧道路由已配置，但 **cloudflared 尚未上线**，Cloudflare 无可用连接。
→ 该状态码是**部署后验证隧道是否打通的最直接信号**（530 → 200）。

#### 🔴 P3：三个不同端口违背单端口架构

45677 / 45678 / 45679 是三条**独立**目标，等同于"每个服务各自暴露"，
与「对外单端口 + 网关统一路由」的架构冲突。
**正确形态：三条规则全部指向同一个网关** `http://gateway:9999`，
由网关按 `Host` 头分流到各容器。

> 另注：官方 `cloudflare/cloudflared` 容器的 `--url` 常用 `http://` 而非 `https://`；
> 若网关只监听明文 HTTP，配 `https://` 会握手失败。见实施阶段确认。

---

## 10. 当前进度

- [x] 本地 git 仓库初始化
- [x] GitHub 远程仓库创建并推送
- [x] 环境实测（OS / podman / quadlet / linger / 网络）
- [x] 设计文档（本文件）
- [x] 确认产品（OpenCloud）与端口模型（单端口 `9999`）
- [x] 确认域名 `vibecotion.wraindrock.com` 及 Cloudflare 托管状态实测
- [ ] 开放问题确认
- [ ] Quadlet 单元编写
- [ ] Home 门户实现
- [ ] install / uninstall / reset 脚本
- [ ] 实测验收 A1–A5
