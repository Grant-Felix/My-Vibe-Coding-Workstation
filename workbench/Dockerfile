# Vibe Coding Workstation — Workbench 镜像
#
# 三个环境（dev / test / staging）**共享本镜像层**，但容器与数据卷完全隔离。
# 这是设计 D5 的实现：省磁盘，且互不污染。
#
# 为什么必须自带常驻命令：
#   debian 基础镜像的默认命令是 bash，无 TTY 会立即退出。
#   容器随即被 Restart=always 反复拉起 → 崩溃循环。
#   因此这里以 sleep infinity 常驻，供人 exec 进去工作。

FROM docker.io/library/debian:13-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# 通用开发基线：
#   git        版本控制（与 Forgejo 配合）
#   build-essential  编译工具链
#   python3    脚本与自动化
#   nodejs/npm 前端与 JS 工具链
#   curl/wget  网络调试
#   常用排查工具
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        openssh-client \
        build-essential \
        python3 \
        python3-pip \
        python3-venv \
        nodejs \
        npm \
        curl \
        wget \
        jq \
        ripgrep \
        less \
        vim-tiny \
        procps \
        iproute2 \
        netcat-openbsd \
        tini; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# 非 root 工作用户：uid 与宿主一致，避免卷内文件属主错乱
ARG UID=1000
ARG GID=1000
RUN set -eux; \
    groupadd -g "${GID}" work 2>/dev/null || true; \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash work 2>/dev/null || true; \
    mkdir -p /work; \
    chown -R "${UID}:${GID}" /work

USER ${UID}:${GID}
WORKDIR /work

# 常驻：容器保持运行，供 podman exec 进入
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]
