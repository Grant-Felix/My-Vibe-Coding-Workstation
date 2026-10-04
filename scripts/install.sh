#!/usr/bin/env bash
#
# Vibe Coding Workstation — 部署
#
# 原则（见 design.md 第 0 节）：宿主零依赖、写入面可枚举。
# 本脚本只做四件事：
#   1. 校验前置条件（不安装任何宿主包）
#   2. 同步配置到 ~/.config/vibecotion（宿主的合法写入面之一）
#   3. 安装 Quadlet 单元并启动
#   4. 渲染产物（声明 → 产物）。没有账本：卸载靠前缀归属，不靠记账。
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

# ---- 从声明读取（唯一真源）----
# 不在脚本里硬编码 prefix / 路径：那会让声明不再是真源。
# 用与 render.sh 同一套分层解析库（已剥离行内注释与引号）。
# shellcheck source=lib/decl.sh
. "$SCRIPT_DIR/lib/decl.sh"

_decl_files=()
decl_add_layer "$REPO_DIR/workstation.yaml"
decl_add_layer "$REPO_DIR/workstation.local.yaml"

PREFIX="$(decl_get prefix)"
DERIVED_ROOT="$(decl_get paths.derivedRoot)"; DERIVED_ROOT="${DERIVED_ROOT/#\~/$HOME}"
CFG_DIR="$DERIVED_ROOT"

[ -n "$PREFIX" ] || { printf '声明缺少 prefix（workstation.yaml）\n' >&2; exit 1; }
[ -n "$DERIVED_ROOT" ] || { printf '声明缺少 paths.derivedRoot\n' >&2; exit 1; }

# ---- 输出 ----
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
  C_DIM=$'\033[2m';  C_B=$'\033[1m';    C_R=$'\033[0m'
else
  C_OK=; C_WARN=; C_ERR=; C_DIM=; C_B=; C_R=
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_OK" "$C_R" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_R" "$*"; }
die()  { printf '%s✗%s %s\n' "$C_ERR" "$C_R" "$*" >&2; exit 1; }
step() { printf '\n%s▸ %s%s\n' "$C_B" "$*" "$C_R"; }

# ---- 前置检查：只检查，绝不安装 ----
preflight() {
  step "前置检查"

  command -v podman >/dev/null 2>&1 || die "未找到 podman。本脚本不代为安装（宿主零依赖原则）"
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl"

  local pv
  pv=$(podman --version 2>/dev/null | awk '{print $3}') || true
  [ -n "${pv:-}" ] || die "podman 无法执行。若在沙箱中运行，请到真实宿主执行"
  ok "podman ${pv}"

  # Quadlet 生成器
  if [ -x /usr/libexec/podman/quadlet ] || [ -e /usr/lib/systemd/system-generators/podman-system-generator ]; then
    ok "Quadlet 生成器可用"
  else
    die "未找到 Quadlet 生成器（需要 podman >= 4.4）"
  fi

  # Linger：rootless 服务在登出后仍需常驻
  local linger
  linger=$(loginctl show-user "$(id -u)" --property=Linger --value 2>/dev/null || echo no)
  if [ "$linger" = "yes" ]; then
    ok "Linger 已启用（服务可在登出后常驻）"
  else
    warn "Linger 未启用。登出后服务会停止。启用：loginctl enable-linger $USER"
  fi

  # 端口占用检查
  # 端口来自声明，不硬编码。
  local port
  port="$(decl_get pod.publishPort)"; port="${port//\"/}"
  [ -n "$port" ] || port=9999

  if command -v ss >/dev/null 2>&1; then
    if ss -tln 2>/dev/null | grep -qE ":(\$port)\b"; then
      # 关键：区分「我们上次留下的」与「别人的服务」。
      # 前者是部署失败后的正常残留，应当自动接管，而不是让用户手工清理。
      if podman pod exists "$PREFIX" 2>/dev/null; then
        warn "端口 $port 被本项目上次的 Pod（${PREFIX}）占用，正在接管"
        if podman pod rm -f "$PREFIX" >/dev/null 2>&1; then
          ok "已移除旧 Pod，端口 $port 释放"
          # 给内核一点时间回收 socket
          local i; for i in 1 2 3 4 5; do
            ss -tln 2>/dev/null | grep -qE ":(\$port)\b" || break
            sleep 1
          done
        else
          warn "旧 Pod 移除失败，请手动执行：podman pod rm -f $PREFIX"
        fi
      fi

      if ss -tln 2>/dev/null | grep -qE ":(\$port)\b"; then
        warn "端口 $port 仍被占用：${C_DIM}（此处重新探测，非上面的旧记录）${C_R}"
        ss -tlnp 2>/dev/null | grep -E ":(\$port)\b" | sed 's/^/    /' || true
        say  "  若是本项目的其它残留：podman pod rm -f $PREFIX"
        say  "  若是别的服务：先停止它，或改 workstation.yaml 的 pod.publishPort"
        die  "端口 $port 不可用"
      fi
    fi
    ok "端口 $port 空闲"
  fi
}

# ---- 凭证准备 ----
prepare_secrets() {
  step "凭证"

  mkdir -p "$CFG_DIR"
  chmod 700 "$CFG_DIR"

  local cf_env="${HOME}/.config/vibecotion/cloudflared.env"
  # 只判「文件存在且有键」是不够的 —— 文档里的占位符 '<你的 token>'
  # 被原样复制时同样满足该条件，结果脚本报「✓」而隧道连不上。
  # 因此这里做三重校验：非空 → 非占位符 → 长度合理。
  local cf_tok=""
  if [ -f "$cf_env" ]; then
    cf_tok="$(sed -n 's/^TUNNEL_TOKEN=//p' "$cf_env" | head -1 | tr -d '\r"' | tr -d "'" | sed 's/[[:space:]]*$//')"
  fi

  if [ -z "$cf_tok" ]; then
    warn "缺少 $cf_env 或其中无 TUNNEL_TOKEN"
    say  "  Cloudflare 隧道将无法连接。从 Cloudflare 面板复制 token 后执行："
    say  "    printf 'TUNNEL_TOKEN=%s\\n' 'eyJhIjoi...你的真实token...' > $cf_env"
    say  "    chmod 600 $cf_env"
  elif printf '%s' "$cf_tok" | grep -qE '<[^>]*>|YOUR_|PLACEHOLDER|xxxx'; then
    warn "TUNNEL_TOKEN 是**占位符**，不是真实凭证"
    say  "  当前值前 24 字符：$(printf '%s' "$cf_tok" | head -c 24)"
    say  "  请从 Cloudflare 面板 → Zero Trust → Networks → Tunnels 复制真实 token"
  elif [ "${#cf_tok}" -lt 40 ]; then
    warn "TUNNEL_TOKEN 仅 ${#cf_tok} 字符，疑似不完整（真实 token 通常上百字符）"
  else
    chmod 600 "$cf_env"
    ok "找到 Cloudflare Tunnel 凭证（${#cf_tok} 字符）"
  fi

  local oc_env="${HOME}/.config/vibecotion/opencloud.env"
  if [ -f "$oc_env" ] && grep -q '^IDM_ADMIN_PASSWORD=' "$oc_env" 2>/dev/null; then
    chmod 600 "$oc_env"
    ok "找到 OpenCloud 管理员凭证"
  else
    warn "缺少 $oc_env，正在生成随机管理员密码"
    local pw
    pw=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    umask 077
    printf 'IDM_ADMIN_PASSWORD=%s\n' "$pw" > "$oc_env"
    chmod 600 "$oc_env"
    ok "已生成并保存到 $oc_env"
    say "  管理员密码：$C_B${pw}$C_R  （用户名为 admin，请妥善保存）"
  fi
}

# ---- 渲染产物（声明 → 产物）----
# 决策（继承 Wraindrock D2）：没有 manifest.json。状态即 workstation.yaml，
# 产物由 render.sh 生成并自动清理陈旧项。本脚本不记账。
render_artifacts() {
  step "渲染产物"

  [ -x "$SCRIPT_DIR/render.sh" ] || die "缺少 render.sh"
  "$SCRIPT_DIR/render.sh" || die "渲染失败"

  # daemon-reload 是便利而非正确性前提：产物已落盘，systemd 会在下次
  # 需要时自行察觉。无用户总线（如非交互会话）时不因此中断。
  if systemctl --user daemon-reload 2>/dev/null; then
    ok "systemd 已重载"
  else
    warn "systemd 重载失败（无用户会话总线？）。产物已就位，登录后可手动重载"
  fi
}

# ---- 构建 agent 镜像 ----
build_images() {
  step "构建镜像"

  # 需要本地构建的镜像：<目录> —— 目录名即镜像名后缀
  # 这些镜像**必须**本地构建：它们携带各自的常驻命令，
  # 换成上游同名基础镜像会导致容器立即退出（崩溃循环）。
  local dirs=(agent workbench)

  # 基础发行版版本来自声明（决策 D17）。传入构建参数，
  # 使「改 workstation.yaml 的 base.version」能真正影响镜像。
  local fedora_ver node_ver fnm_ver
  fedora_ver="$(decl_get base.version)";    fedora_ver="${fedora_ver//\"/}"
  node_ver="$(decl_get base.node.version)"; node_ver="${node_ver//\"/}"
  fnm_ver="$(decl_get base.node.fnmVersion)"; fnm_ver="${fnm_ver//\"/}"
  [ -n "$fedora_ver" ] || fedora_ver=44
  [ -n "$node_ver" ]   || node_ver=lts
  [ -n "$fnm_ver" ]    || fnm_ver=1.39.0
  say "  基础发行版：Fedora $fedora_ver"
  say "  Node 工具链：fnm $fnm_ver + Node $node_ver（npm/pnpm/yarn）"

  local d tag rc=0
  for d in "${dirs[@]}"; do
    tag="localhost/${PREFIX}-${d}:latest"

    # 镜像已存在且发行版一致才跳过；版本变了必须重建
    if podman image exists "$tag" 2>/dev/null; then
      local have_f have_n
      have_f="$(podman image inspect "$tag" --format '{{ index .Labels "org.vibecotion.fedora" }}' 2>/dev/null || true)"
      have_n="$(podman image inspect "$tag" --format '{{ index .Labels "org.vibecotion.node" }}' 2>/dev/null || true)"
      if [ "$have_f" = "$fedora_ver" ] && [ "$have_n" = "$node_ver" ]; then
        ok "镜像 $tag 已存在（Fedora $fedora_ver / Node $node_ver，跳过构建）"
        say "  $C_DIM如需强制重建：podman rmi $tag 后重新运行本脚本$C_R"
        continue
      fi
      say "  $C_DIM$tag 当前为 Fedora \"${have_f:-未知}\" / Node \"${have_n:-未知}\"，"
      say "  与声明（Fedora $fedora_ver / Node $node_ver）不符，重建$C_R"
    fi

    if [ ! -f "$REPO_DIR/$d/Dockerfile" ]; then
      warn "缺少 $d/Dockerfile，跳过"
      rc=1
      continue
    fi

    say "  构建 $tag（Fedora $fedora_ver，Node $node_ver，首次较慢）"

    # 构建日志写入文件：失败时打印尾部，成功时静默。
    # 不能丢弃 —— 构建失败时的真实原因只存在于这份日志里。
    local buildlog="$REPO_DIR/.build-$d.log"
    if podman build \
         --build-arg "FEDORA_VERSION=$fedora_ver" \
         --build-arg "NODE_VERSION=$node_ver" \
         --build-arg "FNM_VERSION=$fnm_ver" \
         --label "org.vibecotion.fedora=$fedora_ver" \
         --label "org.vibecotion.node=$node_ver" \
         -t "$tag" -f "$REPO_DIR/$d/Dockerfile" "$REPO_DIR/$d" >"$buildlog" 2>&1; then
      ok "已构建 $tag"
      rm -f "$buildlog"
    else
      warn "构建失败。日志（末 30 行）："
      say "  $C_DIM──────────────────────────────────────────────$C_R"
      tail -30 "$buildlog" | sed "s/^/    /"
      say "  $C_DIM──────────────────────────────────────────────$C_R"
      say "  完整日志：$buildlog"
      rc=1
    fi
  done

  if [ "$rc" != 0 ]; then
    warn "有镜像未能构建，对应服务将无法启动（其余服务不受影响）"
  fi
  return 0
}

# ---- 导入 DSH_HOME ----
seed_dsh_home() {
  step "初始化 Agent 的 DSH_HOME"

  local vol="${PREFIX}-agent-dsh"
  local src="${HOME}/.dsh"

  if ! podman volume exists "$vol" 2>/dev/null; then
    warn "卷 $vol 不存在（单元可能尚未生效），跳过"
    return 0
  fi

  # 已有内容则绝不覆盖 —— 凭证是用户资产
  local existing
  existing=$(podman run --rm -v "${vol}:/t:Z" docker.io/library/alpine:3.20 \
              sh -c 'ls -A /t 2>/dev/null | head -1' 2>/dev/null || true)

  if [ -n "${existing:-}" ]; then
    ok "DSH_HOME 已有内容，保留不动"
    return 0
  fi

  if [ ! -f "${src}/.credentials.yaml" ]; then
    warn "宿主 ${src}/.credentials.yaml 不存在，无法导入凭证"
    say  "  Agent 首次启动后需在容器内登录，或手动放入 API key"
    return 0
  fi

  # ⚠️ 绝不把宿主 ${src} 挂进容器 —— 即使加 :ro，`:Z` 也会**重打宿主目录的
  #    SELinux 标签**为 container_file_t，从而改变用户家目录的状态。
  #    （此坑已踩：`~/.dsh` 被改成 container_file_t，而 restorecon 在
  #      SELinux 禁用时不生效，无法就地复原。）
  #    改用 tar 管道：宿主读、容器写；用户数据从不进入容器的挂载命名空间。
  say "  从 ${src} 导入 DSH_HOME（profiles + 凭证）"
  if tar -C "${src}" -cf - . 2>/dev/null \
     | podman run --rm -i \
         -v "${vol}:/dest:Z" \
         docker.io/library/alpine:3.20 \
         sh -c 'tar -C /dest -xf - && chown -R 1000:1000 /dest' >/dev/null 2>&1; then
    ok "已导入（凭证现存在于卷中，未进入仓库或镜像）"
  else
    warn "导入失败。可手动执行："
    say "    tar -C ${src} -cf - . | podman run --rm -i -v ${vol}:/dest:Z \\"
    say "      alpine:3.20 sh -c 'tar -C /dest -xf - && chown -R 1000:1000 /dest'"
  fi
}



# ---- 启动 ----
start_services() {
  step "启动服务"

  # 顺序：network → pod → 各服务 → gateway → cloudflared
  # 依赖关系已在各单元的 After/Requires 中声明，systemd 会自行排序。
  local units=(
    "${PREFIX}-network.service"
    "${PREFIX}-pod.service"
    "${PREFIX}-agent.service"
    "${PREFIX}-forgejo.service"
    "${PREFIX}-opencloud.service"
    "${PREFIX}-workbench-dev.service"
    "${PREFIX}-workbench-test.service"
    "${PREFIX}-workbench-staging.service"
    "${PREFIX}-gateway.service"
    "${PREFIX}-cloudflared.service"
  )

  for u in "${units[@]}"; do
    if systemctl --user start "$u" 2>/dev/null; then
      ok "$u"
    else
      warn "$u 启动失败（可能是单元尚未生成，稍后重试）"
    fi
  done
}

# ---- 等待就绪 ----
wait_ready() {
  step "等待网关就绪"

  local i
  for i in $(seq 1 30); do
    if curl -fsS --max-time 2 "http://127.0.0.1:9999/healthz" >/dev/null 2>&1; then
      ok "网关已在 http://127.0.0.1:9999 响应"
      return 0
    fi
    sleep 2
  done

  warn "网关 60 秒内未就绪。查看日志："
  say "    journalctl --user -u ${PREFIX}-gateway.service -n 50 --no-pager"
  return 1
}

# ---- 主流程 ----
main() {
  printf '\n%sVibe Coding Workstation%s — 部署\n' "$C_B" "$C_R"
  say "$C_DIM仓库：$REPO_DIR$C_R"

  preflight
  prepare_secrets
  render_artifacts
  build_images
  start_services
  seed_dsh_home

  if wait_ready; then
    printf '\n%s部署完成%s\n' "$C_OK$C_B" "$C_R"
    say "  本机访问：http://127.0.0.1:9999"
    say "  公网访问：https://vibecotion.wraindrock.com"
    say "  $C_DIM卸载：$SCRIPT_DIR/uninstall.sh --dry-run  # 先预览$C_R"
  else
    printf '\n%s部署未完全成功%s（无账本：直接跑 render.sh 或 uninstall.sh 即可）\n' "$C_WARN" "$C_R"
    exit 1
  fi
}

main "$@"
