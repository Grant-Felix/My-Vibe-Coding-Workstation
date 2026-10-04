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
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --check)   CHECK=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) printf '未知参数：%s\n' "$a" >&2; exit 2 ;;
  esac
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

# ── 解析声明 ────────────────────────────────────────────────────────
# 零依赖：只用 grep/sed 读这个受控格式，不引 YAML 解析器。
# 格式受限于本文件自身的写法（键: 值，两级缩进），够用且无依赖。
get() {
  # get <键> —— 取顶层键的值
  sed -n "s/^\\s*${1}:\\s*\\(.*\\)\s*$/\\1/p" "$DECL" | head -1
}

PREFIX=$(get prefix)
NAME=$(get name)
DOMAIN=$(get domain)
PUBLISH_PORT=$(sed -n 's/^\s*publishPort:\s*\(.*\)\s*$/\1/p' "$DECL" | head -1)

UNIT_ROOT=$(sed -n 's/^\s*unitRoot:\s*\(.*\)\s*$/\1/p' "$DECL" | head -1)
UNIT_ROOT="${UNIT_ROOT/#\~/$HOME}"
DERIVED_ROOT=$(sed -n 's/^\s*derivedRoot:\s*\(.*\)\s*$/\1/p' "$DECL" | head -1)
DERIVED_ROOT="${DERIVED_ROOT/#\~/$HOME}"

[ -n "$PREFIX" ] || { printf '声明缺少 prefix\n' >&2; exit 1; }
[ -n "$UNIT_ROOT" ] || { printf '声明缺少 paths.unitRoot\n' >&2; exit 1; }
[ -n "$DERIVED_ROOT" ] || { printf '声明缺少 paths.derivedRoot\n' >&2; exit 1; }

# ── 期望的产物集合 ──────────────────────────────────────────────────
# 产物一律以 <prefix>- 开头。这就是归属标识。
declare -a WANTED=()

want() { WANTED+=("$1"); }

plan() {
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
