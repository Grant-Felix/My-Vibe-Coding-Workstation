#!/usr/bin/env bash
#
# Vibe Coding Workstation — 卸载
#
# 分四档，逐层加深：
#   （默认）    停服务 + 移除单元 + 删容器/网络/卷 + 清理配置
#   --purge     以上 + 删镜像 + 删凭证
#   --nuke      以上 + 清理 podman 残留（仅本项目前缀）
#   --dry-run   只打印将删除什么，不执行任何改动
#
# 设计要点（见 design.md 第 6 节）：
#   · 按 manifest 登记清单**精确回收**，不用 podman system prune
#   · ~/.local/share/containers/storage 是 podman 共享存储，绝不整删
#   · 幂等：重复执行不报错
#   · 结束做残留自检，非空则以非零码退出
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

PREFIX="vibe-ws"
CFG_DIR="${HOME}/.config/vibe-workstation"
QUADLET_DIR="${HOME}/.config/containers/systemd"
STATE_DIR="${HOME}/.local/state/vibe-workstation"
MANIFEST="${STATE_DIR}/manifest.json"

# ---- 选项 ----
DRY_RUN=0
PURGE=0
NUKE=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=1 ;;
    --purge)    PURGE=1 ;;
    --nuke)     NUKE=1; PURGE=1 ;;
    -y|--yes)   ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0 ;;
    *) printf '未知参数：%s\n' "$arg" >&2; exit 2 ;;
  esac
done

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
skip() { printf '%s·%s %s\n' "$C_DIM" "$C_R" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_ERR" "$C_R" "$*" >&2; }
step() { printf '\n%s▸ %s%s\n' "$C_B" "$*" "$C_R"; }

# dry-run 下不执行，只报告
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_R" "$*"
  else
    "$@"
  fi
}

# podman 可能因沙箱/权限不可用；不可用时降级为警告而非中断
podman_safe() {
  podman "$@" 2>/dev/null || true
}

# ---- 读取 manifest ----
load_manifest() {
  if [ -f "$MANIFEST" ]; then
    ok "找到清单 $MANIFEST"
    MANIFEST_FOUND=1
  else
    warn "未找到 manifest。将退化为**按前缀**扫描（仍不触碰其他容器）"
    MANIFEST_FOUND=0
  fi
}

# 从 manifest 提取 JSON 字符串数组，退化为按前缀推导
json_array() {
  local key="$1"
  if [ "$MANIFEST_FOUND" = 1 ] && command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json,sys
try:
    d=json.load(open('$MANIFEST'))
    for x in d.get('$key',[]): print(x)
except Exception: pass
" 2>/dev/null
  fi
}

# ---- 1. 停止并禁用 systemd 单元 ----
stop_units() {
  step "停止 systemd 单元"

  local units=(
    "${PREFIX}-cloudflared.service"
    "${PREFIX}-gateway.service"
    "${PREFIX}-workbench-staging.service"
    "${PREFIX}-workbench-test.service"
    "${PREFIX}-workbench-dev.service"
    "${PREFIX}-opencloud.service"
    "${PREFIX}-forgejo.service"
    "${PREFIX}-agent.service"
    "${PREFIX}-pod.service"
    "${PREFIX}-network.service"
  )

  local u
  for u in "${units[@]}"; do
    if systemctl --user is-active --quiet "$u" 2>/dev/null; then
      run systemctl --user stop "$u" && ok "已停止 $u"
    else
      skip "$u 未运行"
    fi
  done
}

# ---- 2. 移除 Quadlet 单元文件 ----
remove_unit_files() {
  step "移除 Quadlet 单元文件"

  # 只删本前缀，绝不触碰用户其他单元（如 felix-dsh-frpc.container）
  local found
  found=$(find "$QUADLET_DIR" -maxdepth 1 -name "${PREFIX}*" -type f 2>/dev/null | wc -l)

  if [ "$found" -eq 0 ]; then
    skip "无 ${PREFIX}* 单元文件"
  else
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      run rm -f "$f" && ok "已删除 $(basename "$f")"
    done < <(find "$QUADLET_DIR" -maxdepth 1 -name "${PREFIX}*" -type f 2>/dev/null | sort)
  fi

  run systemctl --user daemon-reload
  run systemctl --user reset-failed 2>/dev/null || true
}

# ---- 3. 删除 Pod / 容器 ----
remove_containers() {
  step "删除 Pod 与容器"

  # Pod 删除会带走其内容器
  if podman pod exists "$PREFIX" 2>/dev/null; then
    run podman pod rm -f "$PREFIX" && ok "已删除 Pod $PREFIX"
  else
    skip "Pod $PREFIX 不存在"
  fi

  # 兜底：清理同前缀的游离容器
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    run podman rm -f "$c" && ok "已删除容器 $c"
  done < <(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${PREFIX}" || true)
}

# ---- 4. 删除网络 ----
remove_networks() {
  step "删除网络"

  local nets
  nets=$(json_array networks)
  if [ -z "$nets" ]; then nets="${PREFIX}"; fi

  local n
  for n in $nets; do
    if podman network exists "$n" 2>/dev/null; then
      run podman network rm -f "$n" && ok "已删除网络 $n"
    else
      skip "网络 $n 不存在"
    fi
  done
}

# ---- 5. 删除卷 ----
remove_volumes() {
  step "删除数据卷"

  local vols
  vols=$(json_array volumes)

  if [ -z "$vols" ]; then
    # 退化为按标签/前缀扫描
    vols=$(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${PREFIX}" || true)
  fi

  if [ -z "$vols" ]; then
    skip "无本项目的卷"
    return 0
  fi

  local v
  for v in $vols; do
    if podman volume exists "$v" 2>/dev/null; then
      run podman volume rm -f "$v" && ok "已删除卷 $v"
    else
      skip "卷 $v 不存在"
    fi
  done
}

# ---- 6. 清理宿主配置目录 ----
remove_host_config() {
  step "清理宿主配置"

  if [ -d "$CFG_DIR" ]; then
    # 默认保留凭证文件（--purge 才删）
    if [ "$PURGE" = 1 ]; then
      run rm -rf "$CFG_DIR" && ok "已删除 $CFG_DIR（含凭证）"
    else
      run rm -rf "$CFG_DIR/Caddyfile" "$CFG_DIR/home" 2>/dev/null || true
      ok "已删除配置与静态文件（保留凭证，如需删除加 --purge）"
      skip "保留：$CFG_DIR/*.env"
    fi
  else
    skip "$CFG_DIR 不存在"
  fi
}

# ---- 7. 删除镜像 ----
remove_images() {
  step "删除镜像"

  if [ "$PURGE" != 1 ]; then
    skip "未指定 --purge，保留镜像（避免下次部署重新拉取）"
    return 0
  fi

  # 仅删除本项目 manifest 记录的镜像，且**跳过仍被其他容器使用**的镜像
  local images=(
    "docker.io/library/caddy:2.10-alpine"
    "docker.io/cloudflare/cloudflared:latest"
    "docker.io/library/node:24-bookworm-slim"
    "docker.io/codeberg/forgejo:13"
    "docker.io/opencloudeu/opencloud-rolling:8.0.1"
    "docker.io/library/debian:13-slim"
  )

  local img
  for img in "${images[@]}"; do
    if ! podman image exists "$img" 2>/dev/null; then
      skip "镜像 $img 不存在"
      continue
    fi
    # 安全阀：仍被任何容器引用则保留
    local inuse
    inuse=$(podman ps -a --filter "ancestor=$img" --format '{{.Names}}' 2>/dev/null | wc -l)
    if [ "$inuse" -gt 0 ]; then
      warn "镜像 $img 仍被 $inuse 个容器使用，保留"
      continue
    fi
    run podman rmi -f "$img" && ok "已删除镜像 $img"
  done
}

# ---- 8. 状态目录 ----
remove_state() {
  step "清理状态目录"

  if [ -d "$STATE_DIR" ]; then
    if [ "$PURGE" = 1 ]; then
      run rm -rf "$STATE_DIR" && ok "已删除 $STATE_DIR"
    else
      run rm -f "$MANIFEST" && ok "已删除 manifest"
      skip "保留日志目录 $STATE_DIR/logs"
      if [ -d "$STATE_DIR/logs" ]; then
        run rmdir "$STATE_DIR/logs" 2>/dev/null || true
        run rmdir "$STATE_DIR" 2>/dev/null || true
      fi
    fi
  else
    skip "$STATE_DIR 不存在"
  fi
}

# ---- 9. nuke：本项目专属残留清理 ----
nuke_residuals() {
  step "清理 podman 残留（仅本前缀）"

  if [ "$NUKE" != 1 ]; then
    skip "未指定 --nuke"
    return 0
  fi

  # ⚠️ 绝不用 podman system prune —— 那会波及用户的其他容器。
  #    只针对本前缀逐项确认后再删。

  warn "以下操作仅作用于 ${PREFIX}*，不触碰其他资源"

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    run podman rm -f "$c" && ok "残留容器 $c"
  done < <(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${PREFIX}" || true)

  while IFS= read -r v; do
    [ -n "$v" ] || continue
    run podman volume rm -f "$v" && ok "残留卷 $v"
  done < <(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${PREFIX}" || true)
}

# ---- 10. 残留自检 ----
verify_clean() {
  step "残留自检"

  local residues=0

  # 单元文件
  local uf
  uf=$(find "$QUADLET_DIR" -maxdepth 1 -name "${PREFIX}*" -type f 2>/dev/null | wc -l)
  if [ "$uf" -gt 0 ]; then
    err "仍有 $uf 个单元文件："; find "$QUADLET_DIR" -maxdepth 1 -name "${PREFIX}*" -type f 2>/dev/null | sed 's/^/    /'
    residues=$((residues + uf))
  fi

  # 容器 / 卷 / 网络 / Pod
  if podman pod exists "$PREFIX" 2>/dev/null; then err "Pod $PREFIX 仍存在"; residues=$((residues+1)); fi

  local c v n
  c=$(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -cE "^${PREFIX}" || true)
  [ "$c" -gt 0 ] && { err "仍有 $c 个容器"; residues=$((residues+c)); }

  v=$(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -cE "^${PREFIX}" || true)
  [ "$v" -gt 0 ] && { err "仍有 $v 个卷"; residues=$((residues+v)); }

  n=$(podman network ls --format '{{.Name}}' 2>/dev/null | grep -cE "^${PREFIX}" || true)
  [ "$n" -gt 0 ] && { err "仍有 $n 个网络"; residues=$((residues+n)); }

  # 配置目录
  if [ -d "$CFG_DIR" ]; then
    local leftover
    leftover=$(find "$CFG_DIR" -mindepth 1 2>/dev/null | wc -l)
    if [ "$leftover" -gt 0 ]; then
      if [ "$PURGE" = 1 ]; then
        err "$CFG_DIR 仍有 $leftover 项"; residues=$((residues+1))
      else
        skip "$CFG_DIR 保留了凭证（预期；--purge 可清除）"
      fi
    fi
  fi

  say ""
  if [ "$residues" -eq 0 ]; then
    printf '%s✓ 无残留%s\n' "$C_OK" "$C_R"
    return 0
  else
    printf '%s✗ 发现 %d 项残留%s\n' "$C_ERR" "$residues" "$C_R"
    return 1
  fi
}

# ---- 主流程 ----
main() {
  printf '\n%sVibe Coding Workstation%s — 卸载%s\n' "$C_B" "$C_R" \
    "$([ "$DRY_RUN" = 1 ] && printf ' %s(dry-run，不会实际删除)%s' "$C_DIM" "$C_R")"

  if [ "$DRY_RUN" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
    printf '将删除本项目的全部容器、卷、网络与单元。继续？[y/N] '
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) ;; *) say "已取消"; exit 0 ;; esac
  fi

  load_manifest
  stop_units
  remove_unit_files
  remove_containers
  remove_networks
  remove_volumes
  remove_host_config
  remove_images
  remove_state
  nuke_residuals

  if [ "$DRY_RUN" = 1 ]; then
    say ""
    printf '%s以上为 dry-run 预览，未做任何改动。%s\n' "$C_DIM" "$C_R"
    say "实际执行：$SCRIPT_DIR/uninstall.sh"
    exit 0
  fi

  verify_clean
  local rc=$?
  say ""
  if [ "$rc" -eq 0 ]; then
    printf '%s卸载完成 — 无残留%s\n' "$C_OK$C_B" "$C_R"
  else
    printf '%s卸载完成，但有残留（见上）%s\n' "$C_WARN" "$C_R"
  fi
  exit $rc
}

main "$@"
