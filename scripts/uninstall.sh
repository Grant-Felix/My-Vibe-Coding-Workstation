#!/usr/bin/env bash
#
# Vibe Coding Workstation —— 卸载
#
# 声明式：没有 manifest.json，没有账本，没有对账。
# 归属 = 统一前缀；卸载 = 删除以该前缀命名的产物。
# 状态即 workstation.yaml 与产物自身，两者都不会漂移。
#
# 分档：
#   （默认）   停服务 + 删产物（单元/配置/门户）+ 删容器/网络/卷
#   --purge    以上 + 删镜像 + 删凭证 + 删含 API 密钥的卷
#   --nuke     以上 + 清理本项目专属的 podman 残留
#   --dry-run  只预览
#
# 继承 Wraindrock D2：绝不使用 podman system prune；删除范围严格限定在前缀内。
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DECL="$REPO_DIR/workstation.yaml"

DRY_RUN=0; PURGE=0; NUKE=0; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --purge)   PURGE=1 ;;
    --nuke)    NUKE=1; PURGE=1 ;;
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) printf '未知参数：%s\n' "$arg" >&2; exit 2 ;;
  esac
done

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
run()  { if [ "$DRY_RUN" = 1 ]; then printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_R" "$*"; else "$@"; fi; }

# ── 从声明读取（唯一真源）─────────────────────────────────────────
# 用与 render.sh 相同的分层解析库：它正确剥离行内注释与引号。
# ⚠️ 不要退回 `sed -n "s/^\\s*key:...//"` —— 那会把行内注释一起吃进值里
#    （例如 "…/systemd    # 产物：Quadlet 单元"），导致产物路径完全错误、
#    卸载静默地什么也删不掉。此坑已踩过一次。
# shellcheck source=lib/decl.sh
. "$SCRIPT_DIR/lib/decl.sh"

_decl_files=()
decl_add_layer "$DECL"
decl_add_layer "$REPO_DIR/workstation.local.yaml"

get() { decl_get "$1"; }

PREFIX=$(get prefix)
UNIT_ROOT=$(get paths.unitRoot);     UNIT_ROOT="${UNIT_ROOT/#\~/$HOME}"
DERIVED_ROOT=$(get paths.derivedRoot); DERIVED_ROOT="${DERIVED_ROOT/#\~/$HOME}"
PUBLISH_PORT=$(get pod.publishPort)

[ -n "$PREFIX" ] || { printf '声明缺少 prefix\n' >&2; exit 1; }
[ -n "$UNIT_ROOT" ] || { printf '声明缺少 paths.unitRoot\n' >&2; exit 1; }

# 含 API 凭证的卷：默认保留，仅 --purge 删除
SECRET_VOLUMES=("${PREFIX}-agent-dsh")

is_secret() {
  local v
  for v in "${SECRET_VOLUMES[@]}"; do [ "$v" = "$1" ] && return 0; done
  return 1
}

# ── 1. 停服务 ───────────────────────────────────────────────────────
stop_units() {
  step "停止 systemd 单元"

  # 从**产物本身**枚举，而非硬编码列表 —— 这样改了声明也不需要改脚本
  local units=()
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    units+=("$(basename "$u")")
  done < <(find "$UNIT_ROOT" -maxdepth 1 -name "${PREFIX}*.service" 2>/dev/null)

  # 单元文件在，但 systemd 里的服务名由 Quadlet 生成；按来源文件推断
  local f svc
  for f in "$UNIT_ROOT"/${PREFIX}*.container "$UNIT_ROOT"/${PREFIX}*.pod; do
    [ -f "$f" ] || continue
    svc="$(basename "$f" | sed 's/\.[a-z]*$//').service"
    if systemctl --user is-active --quiet "$svc" 2>/dev/null; then
      if [ "$DRY_RUN" = 1 ]; then
        printf '  %s[dry-run]%s systemctl --user stop %s\n' "$C_DIM" "$C_R" "$svc"
      elif systemctl --user stop "$svc" 2>/dev/null; then
        ok "已停止 $svc"
      else
        warn "停止 $svc 失败（无用户总线？），继续"
      fi
    else
      skip "$svc 未运行"
    fi
  done 2>/dev/null || true
}

# ── 2. 删产物 ───────────────────────────────────────────────────────
remove_artifacts() {
  step "删除产物"

  local n=0 entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "$DRY_RUN" = 1 ]; then
      printf '  %s[dry-run]%s 删除 %s\n' "$C_DIM" "$C_R" "$entry"
    else
      rm -rf "$entry" && ok "已删除 $(basename "$entry")"
    fi
    n=$((n + 1))
  done < <(find "$UNIT_ROOT" -maxdepth 1 -name "${PREFIX}-*" -o -maxdepth 1 -name "${PREFIX}.*" 2>/dev/null)

  # 派生配置目录整体删除（它只属于本项目）
  if [ -d "$DERIVED_ROOT" ]; then
    if [ "$PURGE" = 1 ]; then
      run rm -rf "$DERIVED_ROOT" && ok "已删除 $DERIVED_ROOT（含凭证）"
    else
      run rm -rf "$DERIVED_ROOT/Caddyfile" "$DERIVED_ROOT/home" 2>/dev/null || true
      ok "已删除配置与门户文件（保留 *.env 凭证，如需删除加 --purge）"
    fi
    n=$((n + 1))
  fi

  [ "$n" -eq 0 ] && say "  $C_DIM无产物$C_R"

  # 非致命：无用户总线时不应中断卸载流程（否则残留自检会被跳过）
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s systemctl --user daemon-reload\n' "$C_DIM" "$C_R"
  else
    systemctl --user daemon-reload 2>/dev/null \
      || warn "systemd 重载失败（无用户总线），不影响产物删除"
  fi
}

# ── 3. 删 Pod 与容器 ────────────────────────────────────────────────
remove_containers() {
  step "删除 Pod 与容器"

  if podman pod exists "$PREFIX" 2>/dev/null; then
    run podman pod rm -f "$PREFIX" && ok "已删除 Pod $PREFIX"
  else
    skip "Pod $PREFIX 不存在"
  fi

  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    run podman rm -f "$c" && ok "已删除容器 $c"
  done < <(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${PREFIX}" || true)
}

# ── 4. 删网络 ───────────────────────────────────────────────────────
remove_networks() {
  step "删除网络"
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    run podman network rm -f "$n" && ok "已删除网络 $n"
  done < <(podman network ls --format '{{.Name}}' 2>/dev/null | grep -E "^${PREFIX}$" || true)
}

# ── 5. 删卷（凭证卷受保护）─────────────────────────────────────────
remove_volumes() {
  step "删除数据卷"

  local v found=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    found=1
    if is_secret "$v" && [ "$PURGE" != 1 ]; then
      warn "保留 $v（含 API 凭证）—— 如需删除加 --purge"
      continue
    fi
    run podman volume rm -f "$v" && ok "已删除卷 $v"
  done < <(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${PREFIX}" || true)

  [ "$found" = 0 ] && skip "无本项目的卷"
}

# ── 6. 删镜像 ───────────────────────────────────────────────────────
remove_images() {
  step "删除镜像"

  if [ "$PURGE" != 1 ]; then
    skip "未指定 --purge，保留镜像"
    return 0
  fi

  # 只删本项目构建/引用的镜像；仍被其他容器引用的保留
  local img inuse
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    inuse=$(podman ps -a --filter "ancestor=$img" --format '{{.Names}}' 2>/dev/null | wc -l)
    if [ "$inuse" -gt 0 ]; then
      warn "镜像 $img 仍被 $inuse 个容器使用，保留"
      continue
    fi
    run podman rmi -f "$img" && ok "已删除镜像 $img"
  done < <(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
             | grep -E "vibecotion|opencloudeu/opencloud|codeberg/forgejo|caddy|cloudflared|debian:13" || true)
}

# ── 7. nuke ─────────────────────────────────────────────────────────
nuke_residuals() {
  step "清理残留（仅本前缀）"
  if [ "$NUKE" != 1 ]; then skip "未指定 --nuke"; return 0; fi
  warn "仅作用于 ${PREFIX}*，不触碰其他资源（绝不用 system prune）"

  local x
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    run podman rm -f "$x" && ok "残留容器 $x"
  done < <(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${PREFIX}" || true)

  while IFS= read -r x; do
    [ -n "$x" ] || continue
    run podman volume rm -f "$x" && ok "残留卷 $x"
  done < <(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${PREFIX}" || true)
}

# ── 8. 残留自检 ─────────────────────────────────────────────────────
verify_clean() {
  step "残留自检"
  local r=0

  local uf
  uf=$(find "$UNIT_ROOT" -maxdepth 1 \( -name "${PREFIX}-*" -o -name "${PREFIX}.*" \) 2>/dev/null | wc -l)
  [ "$uf" -gt 0 ] && { err "仍有 $uf 个产物文件"; r=$((r+uf)); }

  podman pod exists "$PREFIX" 2>/dev/null && { err "Pod $PREFIX 仍存在"; r=$((r+1)); }

  local c v n
  c=$(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -cE "^${PREFIX}" || true)
  [ "$c" -gt 0 ] && { err "仍有 $c 个容器"; r=$((r+c)); }

  v=$(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${PREFIX}" | grep -vx "${PREFIX}-agent-dsh" | grep -c . || true)
  [ "$v" -gt 0 ] && { err "仍有 $v 个卷"; r=$((r+v)); }

  n=$(podman network ls --format '{{.Name}}' 2>/dev/null | grep -cE "^${PREFIX}$" || true)
  [ "$n" -gt 0 ] && { err "仍有 $n 个网络"; r=$((r+n)); }

  if podman volume exists "${PREFIX}-agent-dsh" 2>/dev/null; then
    if [ "$PURGE" = 1 ]; then err "凭证卷 ${PREFIX}-agent-dsh 仍存在"; r=$((r+1));
    else skip "${PREFIX}-agent-dsh 保留（含 API 凭证）"; fi
  fi

  if [ -d "$DERIVED_ROOT" ]; then
    local left
    left=$(find "$DERIVED_ROOT" -mindepth 1 2>/dev/null | wc -l)
    if [ "$left" -gt 0 ]; then
      if [ "$PURGE" = 1 ]; then err "$DERIVED_ROOT 仍有 $left 项"; r=$((r+1));
      else skip "$DERIVED_ROOT 保留凭证（预期）"; fi
    fi
  fi

  say ""
  if [ "$r" -eq 0 ]; then printf '%s✓ 无残留%s\n' "$C_OK" "$C_R"; return 0
  else printf '%s✗ 发现 %d 项残留%s\n' "$C_ERR" "$r" "$C_R"; return 1; fi
}

main() {
  printf '\n%sVibe Coding Workstation%s — 卸载%s\n' "$C_B" "$C_R" \
    "$([ "$DRY_RUN" = 1 ] && printf ' %s(dry-run)%s' "$C_DIM" "$C_R")"
  say "$C_DIM声明式卸载：无账本，归属由前缀 ${PREFIX}- 标识$C_R"

  if [ "$DRY_RUN" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
    printf '将删除以 %s 命名的全部产物与服务。继续？[y/N] ' "$PREFIX"
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) ;; *) say "已取消"; exit 0 ;; esac
  fi

  stop_units
  remove_artifacts
  remove_containers
  remove_networks
  remove_volumes
  remove_images
  nuke_residuals

  if [ "$DRY_RUN" = 1 ]; then
    say ""
    printf '%s以上为预览，未做任何改动。%s\n' "$C_DIM" "$C_R"
    exit 0
  fi

  verify_clean; local rc=$?
  say ""
  [ "$rc" -eq 0 ] && printf '%s卸载完成 — 无残留%s\n' "$C_OK$C_B" "$C_R" \
                  || printf '%s卸载完成，但有残留（见上）%s\n' "$C_WARN" "$C_R"
  exit $rc
}

main "$@"
