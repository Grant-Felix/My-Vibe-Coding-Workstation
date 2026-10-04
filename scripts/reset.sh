#!/usr/bin/env bash
#
# Vibe Coding Workstation — 重置 / 恢复 / 重装
#
# 用于 Workbench 三环境（dev/test/staging），把环境还原到「刚安装」的干净状态，
# 无需整体重装工作站。
#
#   reset.sh workbench <env>            清空该环境的数据卷（= 回到初始）
#   reset.sh workbench <env> --rebuild  清空并重建容器
#   reset.sh service <name>             重启单个服务
#   reset.sh status                     总览
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX="vibe-ws"

DRY_RUN=0
REBUILD=0
# 从位置参数中摘出标志
ARGS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --rebuild) REBUILD=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]:-}"

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
run()  { if [ "$DRY_RUN" = 1 ]; then printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_R" "$*"; else "$@"; fi; }

usage() {
  cat <<'EOF'
用法：
  reset.sh status                     查看各服务状态
  reset.sh service <name>             重启单个服务
  reset.sh workbench <env>            重置 Workbench 环境（dev|test|staging）
  reset.sh workbench <env> --rebuild  重置并重建容器

通用选项：
  --dry-run                           只预览，不执行
EOF
}

# ---- 状态总览 ----
cmd_status() {
  step "服务状态"
  local units
  units=$(systemctl --user list-units --type=service --all --no-legend 2>/dev/null \
          | awk '{print $1}' | grep -E "^${PREFIX}-" || true)
  if [ -z "$units" ]; then
    warn "未发现 ${PREFIX}-* 单元，可能尚未部署"
    return 0
  fi
  local u state
  for u in $units; do
    state=$(systemctl --user is-active "$u" 2>/dev/null || echo inactive)
    if [ "$state" = "active" ]; then
      printf '  %s✓%s %-40s %s\n' "$C_OK" "$C_R" "$u" "$state"
    else
      printf '  %s·%s %-40s %s\n' "$C_DIM" "$C_R" "$u" "$state"
    fi
  done
}

# ---- 重启单个服务 ----
cmd_service() {
  local name="${1:-}"
  [ -n "$name" ] || die "缺少服务名。例如：reset.sh service gateway"
  local unit="${PREFIX}-${name}.service"
  systemctl --user list-unit-files "$unit" >/dev/null 2>&1 \
    || systemctl --user cat "$unit" >/dev/null 2>&1 \
    || die "未找到单元 $unit"
  step "重启 $unit"
  run systemctl --user restart "$unit"
  ok "$unit 已重启"
}

# ---- 重置 Workbench ----
cmd_workbench() {
  local env="${1:-}"
  case "$env" in
    dev|test|staging) ;;
    "") die "缺少环境名：dev | test | staging" ;;
    *)  die "未知环境 '$env'（可选：dev | test | staging）" ;;
  esac

  local vol="${PREFIX}-workbench-${env}"
  local svc="${PREFIX}-workbench-${env}.service"

  step "重置 Workbench：$env"

  if ! podman volume exists "$vol" 2>/dev/null; then
    die "卷 $vol 不存在。该环境可能尚未部署"
  fi

  warn "这将清空 $vol 中的全部数据，且不可恢复"
  if [ "$DRY_RUN" = 0 ]; then
    printf '确认清空？[y/N] '
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) ;; *) say "已取消"; exit 0 ;; esac
  fi

  # 停服务 → 清卷 → 重启
  run systemctl --user stop "$svc" 2>/dev/null || true
  ok "已停止 $svc"

  # 用一次性容器清空卷内容（比 rm 卷再建更准确：保留卷本身与标签）
  run podman run --rm -v "${vol}:/target:Z" docker.io/library/alpine:3.20 \
      sh -c 'rm -rf /target/* /target/.[!.]* 2>/dev/null || true'
  ok "已清空卷 $vol"

  if [ "$REBUILD" = 1 ]; then
    run podman rm -f "${PREFIX}-workbench-${env}" 2>/dev/null || true
    ok "已删除旧容器（systemd 将按单元重建）"
  fi

  run systemctl --user start "$svc" 2>/dev/null || true
  ok "$env 环境已重置到初始状态"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    status)    cmd_status ;;
    service)   shift; cmd_service "$@" ;;
    workbench) shift; cmd_workbench "$@" ;;
    ""|-h|--help) usage ;;
    *) die "未知子命令：$cmd" ;;
  esac
}

main "$@"
