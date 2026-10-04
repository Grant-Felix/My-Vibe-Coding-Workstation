#!/usr/bin/env bash
#
# Vibe Coding Workstation —— 渲染器
#
# 声明 → 产物。幂等。产物是派生物，可随时重建、可随时删除。
#
# 决策记录（继承 Wraindrock D2）：
#   状态即 workstation.yaml；没有 manifest.json，没有账本，没有对账。
#   归属由统一前缀标识；陈旧产物按前缀+非期望集合自动清除。
#
# 用法：
#   render.sh            渲染产物
#   render.sh --dry-run  只预览会改什么
#   render.sh --check    只校验，不改动；有差异则非零退出
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DECL="$REPO_DIR/workstation.yaml"

DRY_RUN=0
CHECK=0
DUMP=0
PATCHES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check)   CHECK=1 ;;
    --dump)    DUMP=1 ;;
    --patch)   shift; [ $# -gt 0 ] || { printf -- '--patch 需要参数\n' >&2; exit 2; }; PATCHES+=("$1") ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_R=$'\033[0m'; C_WARN=$'\033[33m'
else
  C_OK=; C_DIM=; C_B=; C_R=; C_WARN=
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_OK" "$C_R" "$*"; }
step() { printf '\n%s▸ %s%s\n' "$C_B" "$*" "$C_R"; }
dry()  { printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_R" "$*"; }

# ── 解析声明（分层组合）─────────────────────────────────────────────
# 借鉴 DeepSeek Harness：配置树从空根起，按顺序叠加各层，后者覆盖前者。
#   DSH:  空根 → bundles → profile patch → $DSH_HOME patch → --patch
#   此处: 空根 → workstation.yaml → workstation.local.yaml → --patch <file>
#
# local 层被 .gitignore 忽略：个人差异不污染仓库，仓库基线也不覆盖个人设置。
# shellcheck source=lib/decl.sh
. "$SCRIPT_DIR/lib/decl.sh"

_decl_files=()
decl_add_layer "$DECL"
decl_add_layer "$REPO_DIR/workstation.local.yaml"
for p in "${PATCHES[@]:-}"; do
  [ -n "$p" ] || continue
  [ -f "$p" ] || { printf -- '--patch 文件不存在：%s\n' "$p" >&2; exit 2; }
  decl_add_layer "$p"
done

get() { decl_get "$1"; }

# ── 运行环境校验（借鉴 DSH 的 peer 版本检查）────────────────────────
# 版本不足时明确报错，而不是让它以诡异方式失败。
# 同时提供**豁免**通道（WORKSTATION_SKIP_ENV_CHECK=1），
# 对应 DSH 的 version-exemptions：知道自己越界的人可以显式承担风险。
verify_environment() {
  [ "${WORKSTATION_SKIP_ENV_CHECK:-0}" = 1 ] && {
    printf '%s!%s 已跳过环境校验（WORKSTATION_SKIP_ENV_CHECK=1）\n' "$C_WARN" "$C_R" >&2
    return 0
  }

  local want_podman want_systemd
  want_podman=$(get requires.podman)
  want_systemd=$(get requires.systemd)

  local bad=0

  # 版本比较：去掉 > / >= / 空格，逐段比数字
  _ver_ge() {
    # $1 = 实际, $2 = 要求（如 "5.0"）；返回 0 表示满足
    local a b
    a=$(printf '%s' "$1" | tr -cd '0-9.' | cut -d. -f1-2)
    b=$(printf '%s' "$2" | tr -cd '0-9.' | cut -d. -f1-2)
    [ -z "$a" ] && return 1
    awk -v a="$a" -v b="$b" 'BEGIN{
      split(a,x,"."); split(b,y,".");
      for(i=1;i<=2;i++){ x[i]+=0; y[i]+=0 }
      if(x[1]!=y[1]) exit (x[1]>y[1])?0:1;
      exit (x[2]>=y[2])?0:1
    }'
  }

  # 注意：值里可能带引号（">=5.0"），比较时统一剥字符，但显示时去引号
  want_podman=$(printf '%s' "$want_podman" | tr -d '"')
  want_systemd=$(printf '%s' "$want_systemd" | tr -d '"')

  if command -v podman >/dev/null 2>&1; then
    local pv
    pv=$(podman --version 2>/dev/null | awk '{print $3}')
    if [ -z "$pv" ]; then
      # 取不到版本（沙箱/权限/运行时目录不可写）——明确警告，不静默通过
      printf '%s!%s 无法取得 podman 版本（命令存在但未能执行）\n' "$C_WARN" "$C_R" >&2
      printf '    要求 %s。请确认可在真实用户会话中执行 podman\n' "$want_podman" >&2
    elif ! _ver_ge "$pv" "$want_podman"; then
      printf '%s✗%s podman %s 低于要求 %s\n' "$C_WARN" "$C_R" "$pv" "$want_podman" >&2
      printf '    Quadlet 的 .pod/.network 需要 podman %s\n' "$want_podman" >&2
      bad=$((bad+1))
    else
      printf '  %spodman %s ✓（要求 %s）%s\n' "$C_DIM" "$pv" "$want_podman" "$C_R"
    fi
  else
    printf '%s✗%s 未找到 podman（要求 %s）\n' "$C_WARN" "$C_R" "$want_podman" >&2
    bad=$((bad+1))
  fi

  if command -v systemctl >/dev/null 2>&1; then
    local sv
    sv=$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')
    if [ -n "$sv" ] && ! _ver_ge "$sv" "$want_systemd"; then
      printf '%s✗%s systemd %s 低于要求 %s\n' "$C_WARN" "$C_R" "$sv" "$want_systemd" >&2
      bad=$((bad+1))
    elif [ -n "$sv" ]; then
      printf '  %ssystemd %s ✓（要求 %s）%s\n' "$C_DIM" "$sv" "$want_systemd" "$C_R"
    fi
  fi

  if [ "$bad" -gt 0 ]; then
    printf '\n环境不满足声明要求。要么升级，要么显式跳过：\n' >&2
    printf '    WORKSTATION_SKIP_ENV_CHECK=1 %s\n' "$0" >&2
    return 1
  fi

  # 输出被命令替换捕获时不影响调用方；这里只在 stderr 打印进度
  return 0
}

# --dump：打印组合后的最终声明，不做任何写操作（对应 DSH --dump-config）
if [ "$DUMP" = 1 ]; then
  printf '# 组合层（先者被后者覆盖）：\n'
  for f in "${_decl_files[@]}"; do printf '#   %s\n' "$f"; done
  printf '#\n'
  decl_compose
  exit 0
fi

PREFIX=$(get prefix)
NAME=$(get name)
DOMAIN=$(get domain)
PUBLISH_PORT=$(get pod.publishPort)

UNIT_ROOT=$(get paths.unitRoot)
UNIT_ROOT="${UNIT_ROOT/#\~/$HOME}"
DERIVED_ROOT=$(get paths.derivedRoot)
DERIVED_ROOT="${DERIVED_ROOT/#\~/$HOME}"

[ -n "$PREFIX" ] || { printf '声明缺少 prefix\n' >&2; exit 1; }
[ -n "$UNIT_ROOT" ] || { printf '声明缺少 paths.unitRoot\n' >&2; exit 1; }
[ -n "$DERIVED_ROOT" ] || { printf '声明缺少 paths.derivedRoot\n' >&2; exit 1; }

# ── 期望的产物集合 ──────────────────────────────────────────────────
# 产物一律以 <prefix>- 开头。这就是归属标识。
declare -a WANTED=()

want() { WANTED+=("$1"); }

# ── 声明与实际的一致性校验 ──────────────────────────────────────────
# 借鉴 DSH 的显式校验思路：宁可在渲染前明确报错，也不要静默漂移。
# 声明里的每个服务都必须在 quadlet/ 有对应产物；反之亦然
#（除 cloudflared 这类 kind: tunnel 的特殊项）。
verify_declaration() {
  local strict="${1:-1}"
  local bad=0

  # 声明里的服务 id
  local declared
  declared=$(decl_compose | sed -n 's/^services\.\([a-z][a-z0-9-]*\)\..*/\1/p' | sort -u)

  # 从 quadlet/ 反推的服务 id（<prefix>-<id>.container 或 <prefix>-<id>-<env>.container）
  local actual
  actual=$(ls "$REPO_DIR"/quadlet/ 2>/dev/null \
           | sed -n "s/^${PREFIX}-\(.*\)\.container$/\1/p" \
           | sed 's/-\(dev\|test\|staging\)$//' \
           | sort -u)

  local s
  for s in $declared; do
    printf '%s\n' "$actual" | grep -qx "$s" || {
      printf '%s声明了服务 %s，但 quadlet/ 中没有对应单元%s\n' "$C_WARN" "$s" "$C_R" >&2
      bad=$((bad+1))
    }
  done
  for s in $actual; do
    printf '%s\n' "$declared" | grep -qx "$s" || {
      printf '%squadlet/ 中存在 %s，但声明未列出%s\n' "$C_WARN" "$s" "$C_R" >&2
      bad=$((bad+1))
    }
  done

  if [ "$bad" -gt 0 ] && [ "$strict" = 1 ]; then
    printf '\n声明与实现不一致（%d 处）。请同步 workstation.yaml 与 quadlet/。\n' "$bad" >&2
    return 1
  fi
  return 0
}

plan() {
  verify_environment || exit 1
  verify_declaration 1 || exit 1

  # 1) Quadlet 单元：源在 quadlet/，文件名已是 <prefix>-*
  local f
  for f in "$REPO_DIR"/quadlet/*; do
    [ -f "$f" ] || continue
    want "$UNIT_ROOT/$(basename "$f")"
  done

  # 2) 网关配置与门户静态文件
  want "$DERIVED_ROOT/Caddyfile"
  local s
  for s in "$REPO_DIR"/config/home/*; do
    [ -f "$s" ] || continue
    want "$DERIVED_ROOT/home/$(basename "$s")"
  done
}

# ── 渲染 ────────────────────────────────────────────────────────────
render() {
  plan

  step "渲染产物"
  say "  声明：$DECL"
  say "  前缀：$PREFIX"
  say "  域名：$DOMAIN"

  [ "$DRY_RUN" = 1 ] && say "  $C_DIM(仅预览)$C_R"

  local changed=0
  for target in "${WANTED[@]}"; do
    local src
    case "$target" in
      "$UNIT_ROOT"/*) src="$REPO_DIR/quadlet/$(basename "$target")" ;;
      "$DERIVED_ROOT/Caddyfile") src="$REPO_DIR/config/gateway/Caddyfile" ;;
      "$DERIVED_ROOT/home/"*) src="$REPO_DIR/config/home/$(basename "$target")" ;;
      *) continue ;;
    esac
    [ -f "$src" ] || continue

    if [ -f "$target" ] && cmp -s "$src" "$target"; then
      continue   # 无变化
    fi
    changed=$((changed + 1))

    if [ "$DRY_RUN" = 1 ] || [ "$CHECK" = 1 ]; then
      dry "$target"
    else
      mkdir -p "$(dirname "$target")"
      install -m 0644 "$src" "$target"
      ok "$target"
    fi
  done

  # 3) 清理陈旧产物
  cleanup_stale

  say ""
  if [ "$CHECK" = 1 ]; then
    if [ "$changed" -gt 0 ]; then
      printf '%s✗ 产物与声明不一致（%d 处）%s\n' "$C_WARN" "$changed" "$C_R"
      return 1
    fi
    printf '%s✓ 产物与声明一致%s\n' "$C_OK" "$C_R"
    return 0
  fi

  if [ "$changed" -eq 0 ]; then
    printf '%s✓ 已是最新（无变化）%s\n' "$C_OK" "$C_R"
  else
    printf '%s✓ 渲染完成（%d 处变化）%s\n' "$C_OK" "$changed" "$C_R"
  fi
}

# ── 陈旧产物清理（继承 Wraindrock D2 的 find_stale）─────────────────
# 用户手工删掉源文件后，残留的产物必须自动消失，否则系统与现实分家。
# 删除范围**严格限制**在以 <prefix>- 开头者。
cleanup_stale() {
  step "清理陈旧产物"

  local removed=0

  stale_in() {
    local root="$1"
    [ -d "$root" ] || return 0
    local entry
    # 只扫描以 <prefix> 开头的条目
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      local keeper=0 w
      for w in "${WANTED[@]}"; do
        [ "$w" = "$entry" ] && { keeper=1; break; }
      done
      [ "$keeper" = 1 ] && continue

      if [ "$DRY_RUN" = 1 ] || [ "$CHECK" = 1 ]; then
        dry "删除 $entry"
      else
        rm -rf "$entry" && ok "已删除陈旧 $entry"
      fi
      removed=$((removed + 1))
    done < <(find "$root" -maxdepth 1 -name "${PREFIX}-*" 2>/dev/null)
    # 门户静态目录下的陈旧文件
    if [ -d "$root/home" ]; then
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        local keeper=0 w
        for w in "${WANTED[@]}"; do
          [ "$w" = "$entry" ] && { keeper=1; break; }
        done
        [ "$keeper" = 1 ] && continue
        if [ "$DRY_RUN" = 1 ] || [ "$CHECK" = 1 ]; then
          dry "删除 $entry"
        else
          rm -f "$entry" && ok "已删除陈旧 $entry"
        fi
        removed=$((removed + 1))
      done < <(find "$root/home" -maxdepth 1 -type f 2>/dev/null)
    fi
  }

  stale_in "$UNIT_ROOT"
  stale_in "$DERIVED_ROOT"

  [ "$removed" -eq 0 ] && say "  $C_DIM无陈旧产物$C_R"
  return 0
}

render
