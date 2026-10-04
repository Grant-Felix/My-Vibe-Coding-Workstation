# Vibe Coding Workstation — Agent 镜像（DeepSeek Harness）
#
# 基础发行版：**Fedora 44**（决策 D17）——与宿主 Bazzite 44 同源。
#
# 决策 D14：DSH 在**容器内独立安装**，不挂载宿主安装。
# 理由：挂载宿主 Node/DSH 会破坏隔离性，并让卸载清单多出宿主侧外部依赖。
#
# 但 DSH 的运行需要 $DSH_HOME（profiles + 凭证），这部分**必须**可注入，
# 否则每次重建都要重新配置。折中：镜像通用，$DSH_HOME 用卷持久化。
#
# Node 版本：Fedora 44 官方仓库提供 nodejs24 = 24.13.1
#（已从 Fedora 仓库元数据核实），满足 DSH 的 Node 24 要求，无需换发行版。

ARG FEDORA_VERSION=44
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION}

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# 基础工具：pnpm 由 corepack 提供；tini 负责正确的信号转发
RUN set -eux; \
    dnf -y --setopt=install_weak_deps=False install \
        ca-certificates \
        curl \
        git \
        nodejs24 \
        npm \
        tini \
        procps-ng \
        less \
        shadow-utils; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/cache/libdnf5

# nodejs24 提供的是 node/npm；建 node 符号链接以便脚本与 DSH 按惯例调用
RUN set -eux; \
    if command -v node24 >/dev/null 2>&1 && ! command -v node >/dev/null 2>&1; then \
      ln -sf "$(command -v node24)" /usr/local/bin/node; \
    fi; \
    node --version

# pnpm（DSH profile 用 pnpm workspace 管理插件）
RUN corepack enable && corepack prepare pnpm@latest --activate

# DSH 本体（版本固定，保证可复现；升级需显式改这里）
ARG DSH_VERSION=0.2.0-rc.2
RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
 && test -x /usr/local/bin/dsh \
 && dsh --version

# $DSH_HOME —— 由卷挂载覆盖，此处仅建立挂载点与属主
ENV DSH_HOME=/home/agent/.dsh
ENV HOME=/home/agent
ENV NODE_ENV=production

# 非 root 用户：uid 与宿主一致，避免卷内文件属主错乱
ARG UID=1000
ARG GID=1000
RUN set -eux; \
    groupadd -g "${GID}" agent 2>/dev/null || true; \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash agent 2>/dev/null || true; \
    mkdir -p "$DSH_HOME" /home/agent/workspace; \
    chown -R "${UID}:${GID}" /home/agent

USER ${UID}:${GID}

WORKDIR /home/agent/workspace

# 默认端口（网关按此转发）
ENV DSH_WEB_PORT=3080
EXPOSE 3080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["dsh", "web"]
