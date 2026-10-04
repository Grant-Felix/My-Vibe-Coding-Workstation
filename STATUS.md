# 项目状态 —— 暂停中

> **状态：暂停**
> 暂停原因：**token 资金不足**（非技术阻塞）。
> 暂停时间：2026-10-04
> 最后提交：`642c3e0`

---

## 一句话

代码已完整落盘并推送（含已定位的修复），**但从未成功完成过一次完整部署**。
本机留有上次失败部署的半成品，恢复时按「恢复步骤」走即可。

---

## 当前事实（实测，非推测）

| 项 | 状态 |
|---|---|
| 本地 / 远程 | 一致，均为 `642c3e0` |
| 工作区 | 干净（无未提交改动） |
| 标签 | `V.26.10.4-1`（已推送） |
| 版本 | `V.26.10.4-1` |
| 部署状态 | ❌ **未成功过** |
| 本机遗留 | Quadlet 产物 20 个、`~/.config/vibecotion/` 配置与凭证；**9999 仍被占用（Pod 仍在运行）** |

---

## 已经做完的（有验证）

- 声明式渲染链（`render.sh` / `decl.sh`）—— 回归通过
- 零残留卸载（`uninstall.sh`，无账本，前缀归属）—— 实测无残留
- 前缀安全护栏 —— 实测不触碰用户其他单元
- 版本号体系（`release.sh`，四处同步）—— 实测一致
- 门户页面 —— 浏览器实测渲染出 6 张卡片
- DSH_HOME 导入 —— 已改为 tar 管道（不再重打 SELinux 标签）

---

## 未完成 / 下次要先做的

### 1. 部署从未成功（最高优先）

上次失败的**直接原因已定位并修复**，但修复后**尚未重新验证**：

| 已修 | 证据 |
|---|---|
| 回环代理导致容器内 dnf 连不上 | `Failed to connect ... via 127.0.0.1`（`127.0.0.1` 在容器内是它自己）→ 改为构建时 `--network host` |
| Forgejo 镜像不存在 | `docker.io/codeberg/forgejo` → **仓库 404**；已改为 `codeberg.org/forgejo/forgejo:16`（实测 200） |
| OpenCloud 被镜像 Entrypoint 吞掉 | 镜像 `Entrypoint=['/usr/bin/opencloud']`，我的 `Exec=` 变成子命令 → 已改为 `Entrypoint=/bin/sh` + `Exec=-c "..."` |

**这三条修复都还没在真机上跑过一次。**

### 2. 已知未验证项

- 20 个 Quadlet 单元能否被你的 systemd 接受
- Caddy 路由是否按 Host 正确分流（上次 gateway 起来了但端口未就绪，原因未查清）
- Cloudflare 隧道链路（当时仍是 530）
- Workbench 三环境能否正常常驻

### 3. 悬而未决的技术债

- **`~/.dsh` 的 SELinux 标签**被我改成了 `container_file_t`（`:Z` 的副作用）。
  当前 SELinux 为 Disabled，**无功能影响**；若日后启用 SELinux，先设 permissive 再跑
  `sudo restorecon -R -v ~/.dsh`。代码已修，不会再发生。
- 上游 4 个镜像（cloudflared/forgejo/caddy/opencloud）无法改用 Fedora，与决策 D17 存在范围差异（已在 design.md 记录）。

---

## 恢复步骤

```bash
cd "/var/home/felix/项目/My Vibe Coding Workstation"
git pull

# ① 若想让上次遗留彻底消失（推荐先做，避免状态混淆）
./scripts/uninstall.sh --dry-run    # 先看会删什么
./scripts/uninstall.sh              # 默认保留凭证与数据卷

# ② 确认 token 有效（上次已写入真实 token，184 字符）
ls -l ~/.config/vibecotion/cloudflared.env

# ③ 重新部署（会重建镜像，已修代理问题；首次较慢）
./scripts/install.sh

# ④ 若仍有异常，一次性收集诊断
./scripts/doctor.sh --logs > d.txt
```

---

## 资金恢复后的第一个动作

```bash
./scripts/install.sh        # 观察三处修复是否奏效：
                            #   回环代理 → dnf 能否联网
                            #   forgejo   → codeberg.org 镜像能否拉取
                            #   opencloud → 容器能否常驻而非秒退
```

若仍失败，`./scripts/doctor.sh --logs` 的输出足以定位。

---

## 可以安全删除的

- `~/.config/vibecotion/cloudflared.env.bak.*`（我写入前的自动备份，内容是旧占位符）
- 仓库内 `.build-*.log`（失败构建日志，已被 gitignore；留作排查也行）
