#!/usr/bin/env bash
#
# Vibe Coding Workstation — 部署
#
# 原则（见 design.md 第 0 节）：宿主零依赖、写入面可枚举。
# 本脚本只做四件事：
#   1. 校验前置条件（不安装任何宿主包）
#   2. 同步配置到 ~/.config/vibe-workstation（宿主的合法写入面之一）
#   3. 安装 Quadlet 单元并启动
#   4. 把本次创建的资源登记进 manifest（供 uninstall.sh 精确回收）
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

# ---- 常量：改名只需改这里 ----
PREFIX="vibe-ws"
CFG_DIR="${HOME}/.config/vibe-workstation"
QUADLET_DIR="${HOME}/.config/containers/systemd"
STATE_DIR="${HOME}/.local/state/vibe-workstation"
MANIFEST="${STATE_DIR}/manifest.json"
LOG_DIR="${STATE_DIR}/logs"

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

  local cf_env="${HOME}/.config/vibe-workstation/cloudflared.env"
  if [ -f "$cf_env" ] && grep -q '^TUNNEL_TOKEN=' "$cf_env" 2>/dev/null; then
    chmod 600 "$cf_env"
    ok "找到 Cloudflare Tunnel 凭证"
  else
    warn "缺少 $cf_env"
    say  "  Cloudflare 隧道将无法连接。创建方式："
    say  "    printf 'TUNNEL_TOKEN=%s\\n' '<你的 token>' > $cf_env && chmod 600 $cf_env"
  fi

  local oc_env="${HOME}/.config/vibe-workstation/opencloud.env"
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

# ---- 同步配置到宿主合法写入面 ----
sync_config() {
  step "同步配置"

  mkdir -p "$CFG_DIR"

  # 网关配置 + 门户静态文件（单一来源：仓库 config/）
  install -m 0644 "$REPO_DIR/config/gateway/Caddyfile" "$CFG_DIR/Caddyfile"
  ok "Caddyfile"

  rm -rf "$CFG_DIR/home"
  mkdir -p "$CFG_DIR/home"
  install -m 0644 "$REPO_DIR"/config/home/* "$CFG_DIR/home/"
  ok "门户静态文件（$(ls -1 "$REPO_DIR"/config/home | wc -l) 个）"
}

# ---- 安装 Quadlet 单元 ----
install_units() {
  step "安装 Quadlet 单元"

  mkdir -p "$QUADLET_DIR"

  # 先移除本项目的旧单元（按前缀），避免改名后残留
  find "$QUADLET_DIR" -maxdepth 1 -name "${PREFIX}*" -type f -delete 2>/dev/null || true

  local n=0
  for f in "$REPO_DIR"/quadlet/*; do
    [ -f "$f" ] || continue
    install -m 0644 "$f" "$QUADLET_DIR/$(basename "$f")"
    n=$((n + 1))
  done
  ok "已安装 ${n} 个单元到 $QUADLET_DIR"

  systemctl --user daemon-reload
  ok "systemd 已重载"
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

# ---- 写 manifest ----
write_manifest() {
  step "登记资源清单"

  mkdir -p "$STATE_DIR" "$LOG_DIR"

  local units_json="" vols_json="" nets_json=""

  # 枚举本项目的 Quadlet 单元（部署后落到宿主的那份）
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    units_json="${units_json}"$(basename "$f")","
  done < <(find "$QUADLET_DIR" -maxdepth 1 -name "${PREFIX}*" -type f 2>/dev/null | sort)
  units_json="[${units_json%,}]"

  # 卷与网络：从单元文件名推导，卸载时逐个核对
  vols_json=$(printf '%s' "$(cd "$REPO_DIR/quadlet" && ls *.volume 2>/dev/null | sed 's/\.volume$//' | sed 's/^/"/; s/$/",/' | tr -d '\n')")
  vols_json="[${vols_json%,}]"

  nets_json=$(printf '%s' "$(cd "$REPO_DIR/quadlet" && ls *.network 2>/dev/null | sed 's/\.network$//' | sed 's/^/"/; s/$/",/' | tr -d '\n')")
  nets_json="[${nets_json%,}]"

  cat > "$MANIFEST" <<JSON
{
  "name": "vibe-coding-workstation",
  "prefix": "${PREFIX}",
  "installed_at": "$(date -Iseconds)",
  "repo_dir": "${REPO_DIR}",
  "host_write_paths": [
    "${QUADLET_DIR}",
    "${CFG_DIR}",
    "${STATE_DIR}"
  ],
  "units": ${units_json},
  "volumes": ${vols_json},
  "networks": ${nets_json},
  "pod": "${PREFIX}",
  "published_port": 9999,
  "secrets": [
    "${HOME}/.config/vibe-workstation/cloudflared.env",
    "${HOME}/.config/vibe-workstation/opencloud.env"
  ]
}
JSON

  chmod 600 "$MANIFEST"
  ok "清单已写入 $MANIFEST"
  say "  $C_DIM卸载时据此精确回收，不使用 podman system prune$C_R"
}

# ---- 主流程 ----
main() {
  printf '\n%sVibe Coding Workstation%s — 部署\n' "$C_B" "$C_R"
  say "$C_DIM仓库：$REPO_DIR$C_R"

  preflight
  prepare_secrets
  sync_config
  install_units
  start_services

  if wait_ready; then
    write_manifest
    printf '\n%s部署完成%s\n' "$C_OK$C_B" "$C_R"
    say "  本机访问：http://127.0.0.1:9999"
    say "  公网访问：https://vibecotion.wraindrock.com"
    say "  $C_DIM卸载：$SCRIPT_DIR/uninstall.sh --dry-run  # 先预览$C_R"
  else
    write_manifest
    printf '\n%s部署未完全成功%s（清单已记录，便于清理）\n' "$C_WARN" "$C_R"
    exit 1
  fi
}

main "$@"
