# Workbench 容器

## 定位

可重置的开发 / 测试 / 预生产环境。对应需求中的第 5 个容器。

## 三个环境

| 环境 | 容器名 | 数据卷 | 用途 |
|---|---|---|---|
| dev | `vibecotion-workbench-dev` | `vibecotion-workbench-dev` | 日常开发，允许脏状态 |
| test | `vibecotion-workbench-test` | `vibecotion-workbench-test` | 测试，从干净基线起 |
| staging | `vibecotion-workbench-staging` | `vibecotion-workbench-staging` | 预生产，只收已验证产物 |

**共享镜像层**（同一个镜像），**数据卷与运行状态完全隔离** —— 互不污染。

## 进入工作

容器内是常驻的（`sleep infinity`），用 exec 进入：

```bash
podman exec -it vibecotion-workbench-dev bash
```

工作目录是 `/work`（挂载到各自的卷）。

## 重置

```bash
./scripts/reset.sh workbench dev            # 清空该环境数据，回到初始
./scripts/reset.sh workbench dev --rebuild  # 并重建容器
```

## 为什么镜像里要带 `sleep infinity`

基础镜像（debian）的默认命令是 `bash`，无 TTY 时**立即退出**。
配合 Quadlet 的 `Restart=always` 会形成**崩溃循环**。
因此镜像自带常驻入口，容器保持运行，供人 exec 进入工作。
