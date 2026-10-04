# Vibe Coding Workstation — Workbench 镜像
#
# 基础发行版：**Fedora 44**（决策 D17）——与宿主 Bazzite 44 同源。
# Node 工具链：**fnm + Node LTS**（决策 D18）——npm/pnpm/yarn 统一由 fnm 管理。
#
# 三个环境（dev / test / staging）**共享本镜像层**，但容器与数据卷完全隔离。
#
# 为什么必须自带常驻命令：
#   Fedora 镜像默认命令会立即退出，配合 Restart=always 形成崩溃循环。
#   故以 sleep infinity 常驻，供人 exec 进入工作。
#
# ⚠️ 不要改回 `dnf install nodejs24` —— 见 D18。

ARG FEDORA_VERSION=44
# ⚠️ 基础镜像源必须是 quay.io —— 已实测：
#     quay.io/fedora/fedora:44                  HTTP 200 ✅
#     registry.fedoraproject.org/fedora:44      HTTP 404 ❌（该路径不存在）
FROM quay.io/fedora/fedora:${FEDORA_VERSION}

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# 通用开发基线
RUN set -eux; \
    dnf -y --setopt=install_weak_deps=False install \
        ca-certificates \
        curl \
        wget \
        tar \
        xz \
        unzip \
        git \
        openssh-clients \
        gcc \
        gcc-c++ \
        make \
        python3 \
        python3-pip \
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

# ── fnm ─────────────────────────────────────────────────────────────
# Fedora 44 仓库不含 fnm（已核实），用官方发行包。
ARG FNM_VERSION=1.39.0
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  fnm_arch=linux ;; \
      aarch64) fnm_arch=arm64 ;; \
      *) echo "不支持的架构: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/fnm.zip \
      "https://github.com/Schniz/fnm/releases/download/v${FNM_VERSION}/fnm-${fnm_arch}.zip"; \
    unzip -q /tmp/fnm.zip -d /usr/local/bin; \
    rm -f /tmp/fnm.zip; \
    chmod +x /usr/local/bin/fnm

# ── 工作用户 ────────────────────────────────────────────────────────
ARG UID=1000
ARG GID=1000
RUN set -eux; \
    groupadd -g "${GID}" work 2>/dev/null || true; \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash work 2>/dev/null || true; \
    mkdir -p /work; \
    chown -R "${UID}:${GID}" /work

USER ${UID}:${GID}
WORKDIR /work

ENV HOME=/home/work
ENV FNM_DIR=/home/work/.fnm
ENV PATH="/home/work/.fnm:/home/work/.fnm/aliases/default/bin:${PATH}"

# ── Node LTS + npm/pnpm/yarn ────────────────────────────────────────
# ⚠️ fnm 参数语义见 agent/Dockerfile 注释："lts-latest" 非法，须用 --lts。
ARG NODE_VERSION=lts
RUN set -eux; \
    eval "$(fnm env --shell bash)"; \
    if [ "${NODE_VERSION}" = "lts" ]; then \
      fnm install --lts; \
    else \
      fnm install "${NODE_VERSION}"; \
    fi; \
    RESOLVED="$(fnm ls | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; \
    test -n "$RESOLVED"; \
    fnm default "$RESOLVED"; \
    fnm use "$RESOLVED"; \
    node --version; \
    npm --version; \
    # Node 24 的安装目录已自带 corepack/pnpm/yarn，无需 prepare 下载
    corepack enable; \
    pnpm --version; \
    yarn --version

# 常驻：容器保持运行，供 podman exec 进入
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]
