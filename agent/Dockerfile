# Vibe Coding Workstation — Agent 镜像（DeepSeek Harness）
#
# 决策 D14：DSH 在**容器内独立安装**，不挂载宿主安装。
# 理由：挂载宿主 Node/DSH 会破坏隔离性，并让卸载清单多出宿主侧外部依赖。
#
# 但 DSH 的运行需要 $DSH_HOME（profiles + 凭证），这部分**必须**是可注入的，
# 否则每次重建都要重新配置。折中：镜像通用，$DSH_HOME 用卷持久化。

FROM docker.io/library/node:24-bookworm-slim

# 基础工具：DSH 的插件机制依赖 pnpm；tini 负责正确的信号转发
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git tini procps less; \
    rm -rf /var/lib/apt/lists/*

# pnpm（DSH profile 用 pnpm workspace 管理插件）
RUN corepack enable && corepack prepare pnpm@latest --activate

# DSH 本体（版本固定，保证可复现；升级需显式改这里）
ARG DSH_VERSION=0.2.0-rc.2
RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
 && test -x /usr/local/bin/dsh

# $DSH_HOME —— 由卷挂载覆盖，此处仅建立挂载点与属主
ENV DSH_HOME=/home/agent/.dsh
ENV HOME=/home/agent
ENV NODE_ENV=production

RUN set -eux; \
    mkdir -p /home/agent/workspace "$DSH_HOME"; \
    chown -R 1000:1000 /home/agent

# 非 root 运行
USER 1000:1000

WORKDIR /home/agent/workspace

# 默认端口（网关按此转发）
ENV DSH_WEB_PORT=3080
EXPOSE 3080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["dsh", "web"]
