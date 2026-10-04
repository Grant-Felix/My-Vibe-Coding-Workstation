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
  if command -v ss >/dev/null 2>&1; then
    if ss -tln 2>/dev/null | grep -qE ':(9999)\b'; then
      warn "端口 9999 已被占用："
      ss -tlnp 2>/dev/null | grep -E ':(9999)\b' | sed 's/^/    /' || true
      die  "请先释放 9999，或修改 quadlet/${PREFIX}.pod 与网关单元中的端口"
    fi
    ok "端口 9999 空闲"
  fi
}

# ---- 凭证准备 ----
prepare_secrets() {
  step "凭证"

  mkdir -p "$CFG_DIR"
  chmod 700 "$CFG_DIR"

  local cf_env="${HOME}/.config/vibecotion/cloudflared.env"
  if [ -f "$cf_env" ] && grep -q '^TUNNEL_TOKEN=' "$cf_env" 2>/dev/null; then
    chmod 600 "$cf_env"
    ok "找到 Cloudflare Tunnel 凭证"
  else
    warn "缺少 $cf_env"
    say  "  Cloudflare 隧道将无法连接。创建方式："
    say  "    printf 'TUNNEL_TOKEN=%s\\n' '<你的 token>' > $cf_env && chmod 600 $cf_env"
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

  local d tag rc=0
  for d in "${dirs[@]}"; do
    tag="localhost/${PREFIX}-${d}:latest"

    if podman image exists "$tag" 2>/dev/null; then
      ok "镜像 $tag 已存在（跳过构建）"
      say "  $C_DIM如需重建：podman rmi $tag 后重新运行本脚本$C_R"
      continue
    fi

    if [ ! -f "$REPO_DIR/$d/Dockerfile" ]; then
      warn "缺少 $d/Dockerfile，跳过"
      rc=1
      continue
    fi

    say "  构建 $tag（首次较慢）"
    if podman build -t "$tag" -f "$REPO_DIR/$d/Dockerfile" "$REPO_DIR/$d" >/dev/null 2>&1; then
      ok "已构建 $tag"
    else
      warn "构建失败。手动查看："
      say "    podman build -t $tag -f $REPO_DIR/$d/Dockerfile $REPO_DIR/$d"
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

  say "  从 ${src} 导入 DSH_HOME（profiles + 凭证）"
  if podman run --rm \
       -v "${vol}:/dest:Z" \
       -v "${src}:/src:ro,Z" \
       docker.io/library/alpine:3.20 \
       sh -c 'cp -a /src/. /dest/ && chown -R 1000:1000 /dest' >/dev/null 2>&1; then
    ok "已导入（凭证现存在于卷中，未进入仓库或镜像）"
  else
    warn "导入失败。可手动执行："
    say "    podman run --rm -v ${vol}:/dest:Z -v ${src}:/src:ro,Z alpine:3.20 sh -c 'cp -a /src/. /dest/'"
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
