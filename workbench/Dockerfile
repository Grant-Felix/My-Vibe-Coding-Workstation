# Vibe Coding Workstation — Workbench 镜像
#
# 基础发行版：**Fedora 44**（决策 D17）——与宿主 Bazzite 44 同源，
# glibc/工具链一致，排查问题不需在两套发行版间换算。
#
# 三个环境（dev / test / staging）**共享本镜像层**，但容器与数据卷完全隔离。
#
# 为什么必须自带常驻命令：
#   Fedora 镜像的默认命令会立即退出。容器随即被 Restart=always 反复拉起
#   → 崩溃循环。因此这里以 sleep infinity 常驻，供人 exec 进去工作。
#
# 升级：改 ARG FEDORA_VERSION 即可（见 scripts/upgrade.sh）。
#       仅接受**稳定版**，不使用 Beta。

ARG FEDORA_VERSION=44
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION}

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# 通用开发基线：
#   git              版本控制（与 Forgejo 配合）
#   gcc/gcc-c++/make 编译工具链
#   python3/pip      脚本与自动化
#   nodejs/npm       前端与 JS 工具链
#   curl/wget/jq     网络与 JSON 处理
#   ripgrep/vim-minimal  排查与编辑
#   procps-ng/iproute/netcat  运行时排查
RUN set -eux; \
    dnf -y --setopt=install_weak_deps=False install \
        ca-certificates \
        git \
        openssh-clients \
        gcc \
        gcc-c++ \
        make \
        python3 \
        python3-pip \
        nodejs \
        npm \
        curl \
        wget \
        jq \
        ripgrep \
        less \
        vim-minimal \
        procps-ng \
        iproute \
        nmap-ncat \
        tini \
        shadow-utils; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/cache/libdnf5

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
