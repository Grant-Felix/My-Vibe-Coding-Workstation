# Vibe Coding Workstation — Agent 镜像（DeepSeek Harness）
#
# 基础发行版：**Fedora 44**（决策 D17）——与宿主 Bazzite 44 同源。
# Node 工具链：**fnm + Node LTS**（决策 D18）。
#
# D14：DSH 在**容器内独立安装**，不挂载宿主安装。
#     挂载宿主 Node/DSH 会破坏隔离性，并让卸载清单多出宿主侧外部依赖。
#
# D18：node/npm/pnpm/yarn 一律由 **fnm** 管理，使用 **Node LTS**。
#     理由：
#       · 与宿主一致（宿主也是 fnm 管理，v24.21.0）
#       · 不用发行版打包的 nodejs（版本受发行版节流，且与宿主工具链可能不一致）
#       · 升级只需改 NODE_VERSION，不必等发行版
#
# ⚠️ 不要改回 `dnf install nodejs24` —— 那会绕过 fnm，
#    使容器内 Node 与宿主不一致，且无法通过本次决策管理版本。

ARG FEDORA_VERSION=44
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION}

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# 基础工具
#   curl/tar/xz   fnm 与 Node 压缩包的下载解包
#   unzip         fnm 官方 zip 发行包
#   git           DSH 与版本控制
#   tini          信号转发（PID 1）
#   shadow-utils  useradd/groupadd
RUN set -eux; \
    dnf -y --setopt=install_weak_deps=False install \
        ca-certificates \
        curl \
        tar \
        xz \
        unzip \
        git \
        tini \
        procps-ng \
        less \
        shadow-utils; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/cache/libdnf5

# ── fnm ─────────────────────────────────────────────────────────────
# Fedora 44 仓库**不包含** fnm（已核实），故用官方发行包安装。
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
    chmod +x /usr/local/bin/fnm; \
    /usr/local/bin/fnm --version

# ── 用户（先建用户，再以该用户安装 Node）───────────────────────────
ARG UID=1000
ARG GID=1000
RUN set -eux; \
    groupadd -g "${GID}" agent 2>/dev/null || true; \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash agent 2>/dev/null || true; \
    mkdir -p /home/agent/workspace; \
    chown -R "${UID}:${GID}" /home/agent

USER ${UID}:${GID}
WORKDIR /home/agent

ENV HOME=/home/agent
ENV FNM_DIR=/home/agent/.fnm
# shellcheck disable=SC2016  # 单引号是刻意的：变量须在容器运行时展开
ENV PATH="/home/agent/.fnm:/home/agent/.fnm/aliases/default/bin:${PATH}"

# ── Node LTS（由 fnm 安装并设为默认）────────────────────────────────
# ⚠️ fnm 的参数语义（实测自 fnm --help）：
#     fnm install --lts        安装最新 LTS
#     fnm install <具体版本>    如 24.21.0
#     "lts-latest" **不是**合法参数，会直接构建失败。
# 因此默认走 --lts；要完全可复现时传具体版本号：
#     --build-arg NODE_VERSION=24.21.0
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
    npm --version

# ── pnpm / yarn ─────────────────────────────────────────────────────
# 实测：Node 24.21.0 的安装目录已直接提供 npm / npx / corepack / pnpm / yarn，
# 无需 corepack prepare 另行下载（那会引入构建期的网络依赖与失败点）。
# corepack enable 仅用于确保 shim 可用。
RUN set -eux; \
    eval "$(fnm env --shell bash)"; \
    corepack enable; \
    node --version; \
    npm --version; \
    pnpm --version; \
    yarn --version

# ── DSH ─────────────────────────────────────────────────────────────
ARG DSH_VERSION=0.2.0-rc.2
RUN set -eux; \
    eval "$(fnm env --shell bash)"; \
    npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"; \
    dsh --version

# $DSH_HOME —— 由卷挂载覆盖
ENV DSH_HOME=/home/agent/.dsh
ENV NODE_ENV=production

RUN mkdir -p "$DSH_HOME"

WORKDIR /home/agent/workspace

ENV DSH_WEB_PORT=3080
EXPOSE 3080

# 注意：ENTRYPOINT 用 tini，CMD 里的 dsh 由 fnm 的 PATH 提供。
# 若 fnm 的 default alias 未生效，改为 ["/bin/bash","-lc","dsh web"]。
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/bash", "-lc", "dsh web"]
