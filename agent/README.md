# Agent 容器

## 定位

工作站的 AI 编码代理，默认 **DeepSeek Harness (DSH)**。
设计为**可替换**：换掉镜像即可切换 agent，网络/卷/路由不变。

## 为什么是自定义镜像而不是官方镜像

DSH 目前没有官方容器镜像，因此在本仓库内自建（`agent/Dockerfile`）。
镜像只装运行时，**不含任何凭证**。

## 凭证与配置的注入方式

DSH 运行需要 `$DSH_HOME`（含 `profiles/` 与 `.credentials.yaml`）。这部分**不打包进镜像**，
而是通过卷持久化，由 `install.sh` 在首次部署时**从宿主导入**。

| 路径 | 内容 | 来源 |
|---|---|---|
| `/home/agent/.dsh` | DSH_HOME（profiles、凭证） | 卷 `vibecotion-agent-dsh`，首次由宿主导入 |
| `/home/agent/workspace` | 工作目录 | 卷 `vibecotion-agent-data` |

> ⚠️ `.credentials.yaml` 含 API 密钥。它存在于**卷**中，不在镜像、不在仓库。
> 卸载时随 `--purge` 一并删除（见 `uninstall.sh`）。

## 替换为其他 agent

改 `quadlet/vibecotion-agent.container` 的 `Image=` 即可。若新 agent 不听 3080，
同时改 `config/gateway/Caddyfile` 中 `agent.vibecotion.wraindrock.com` 的上游端口。
