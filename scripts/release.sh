#!/usr/bin/env bash
#
# Vibe Coding Workstation —— 打包 / 发版
#
# 版本号格式：
#   V.<年>.<月>.<日>-<n>        例：V.26.10.4-1
#     · 年取两位（26 = 2026）
#     · 月/日不补零（10 月 4 日 → 10.4）
#     · n = **当天第 n 次打包**，从 1 开始；跨天自动重置为 1
#
# 状态存于仓库根的 VERSION 文件（唯一真源）。版本号同时体现于三处：
#   1. VERSION 文件        —— 权威值
#   2. workstation.yaml    —— 声明中可读（供渲染与卸载时排查）
#   3. 门户页脚            —— 运行时可见，一眼知道跑的是哪版
#   4. git tag（默认）      —— 可追溯
#
# 用法：
#   release.sh            递增版本、同步各处、打 tag
#   release.sh --show     只打印当前版本
#   release.sh --sync     不递增，仅把 VERSION 同步到各处
#   release.sh --no-tag   递增与同步，但不打 tag
#   release.sh --dry-run  预览
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
VERSION_FILE="$REPO_DIR/VERSION"

SHOW=0; SYNC_ONLY=0; NO_TAG=0; DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --show)    SHOW=1 ;;
    --sync)    SYNC_ONLY=1 ;;
    --no-tag)  NO_TAG=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
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
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_R" "$*"; }
dry()  { printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_R" "$*"; }

# ── 生成今天的版本前缀 ──────────────────────────────────────────────
# 年两位、月日不补零：2026-10-04 → V.26.10.4
today_prefix() {
  printf 'V.%s.%s.%s' "$(date +%y)" "$(date +%-m)" "$(date +%-d)"
}

read_version() {
  [ -f "$VERSION_FILE" ] || { printf '' ; return 0; }
  head -1 "$VERSION_FILE" | tr -d '[:space:]'
}

# ── 递增 ────────────────────────────────────────────────────────────
bump_version() {
  local cur today next_n
  cur="$(read_version)"
  today="$(today_prefix)"

  if [ -z "$cur" ]; then
    next_n=1
  else
    # 取出 <日期部分> 与 <n>
    local cur_date cur_n
    cur_date="${cur%-*}"
    cur_n="${cur##*-}"
    case "$cur_n" in
      ''|*[!0-9]*) cur_n=0 ;;   # 旧格式或损坏，从 0 起算
    esac
    if [ "$cur_date" = "$today" ]; then
      next_n=$((cur_n + 1))     # 同一天：递增
    else
      next_n=1                  # 跨天：重置
    fi
  fi

  printf '%s-%s' "$today" "$next_n"
}

# ── 同步到各处 ──────────────────────────────────────────────────────
sync_version() {
  local ver="$1"

  # 1) VERSION 文件
  if [ "$DRY_RUN" = 1 ]; then
    dry "写 VERSION: $ver"
  else
    printf '%s\n' "$ver" > "$VERSION_FILE"
    ok "VERSION = $ver"
  fi

  # 2) workstation.yaml —— 供渲染/排查读取
  local decl="$REPO_DIR/workstation.yaml"
  if [ -f "$decl" ]; then
    if grep -q '^version:' "$decl"; then
      if [ "$DRY_RUN" = 1 ]; then
        dry "workstation.yaml: version: $ver"
      else
        # 就地替换（保持文件其余部分不动）
        sed -i "s|^version:.*|version: $ver|" "$decl"
        ok "workstation.yaml version 已更新"
      fi
    else
      # 插到 requires 之前（若没有 requires 则插到 apiVersion 之后）
      if [ "$DRY_RUN" = 1 ]; then
        dry "workstation.yaml: 插入 version: $ver"
      else
        if grep -q '^requires:' "$decl"; then
          sed -i "0,/^requires:/s//version: $ver\n\nrequires:/" "$decl"
        else
          sed -i "0,/^apiVersion:.*/s//&\nversion: $ver/" "$decl"
        fi
        ok "workstation.yaml version 已插入"
      fi
    fi

    # 3) 门户页脚 —— 写入一个供前端读取的文件
    local home_dir="$REPO_DIR/config/home"
    if [ -d "$home_dir" ]; then
      if [ "$DRY_RUN" = 1 ]; then
        dry "config/home/version.json: $ver"
      else
        printf '{\n  "version": "%s",\n  "released": "%s"\n}\n' "$ver" "$(date -Iseconds)" \
          > "$home_dir/version.json"
        ok "门户版本文件已生成"
      fi
    fi
  fi
}

# ── git tag ─────────────────────────────────────────────────────────
tag_version() {
  local ver="$1"
  if [ "$NO_TAG" = 1 ]; then
    warn "跳过打 tag（--no-tag）"
    return 0
  fi

  if git -C "$REPO_DIR" rev-parse "$ver" >/dev/null 2>&1; then
    warn "tag $ver 已存在，跳过"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    dry "git tag $ver"
    return 0
  fi

  if git -C "$REPO_DIR" tag "$ver"; then
    ok "已打 tag：$ver"
    say "  $C_DIM推送：git push origin $ver$C_R"
  else
    warn "打 tag 失败（可能不在 git 仓库内）"
  fi
}

# ── 主流程 ──────────────────────────────────────────────────────────
main() {
  if [ "$SHOW" = 1 ]; then
    local v; v="$(read_version)"
    printf '%s\n' "${v:-<未设置>}"
    exit 0
  fi

  local target
  if [ "$SYNC_ONLY" = 1 ]; then
    target="$(read_version)"
    [ -n "$target" ] || { printf 'VERSION 为空，无法 --sync\n' >&2; exit 1; }
    step "同步版本 $target（不递增）"
  else
    target="$(bump_version)"
    step "打包版本 $target"
    say "  当前：${CUR:-}$(read_version)"
  fi

  [ "$DRY_RUN" = 1 ] && say "  $C_DIM(仅预览)$C_R"

  sync_version "$target"
  tag_version "$target"

  say ""
  printf '%s版本：%s%s\n' "$C_B" "$target" "$C_R"
}

main "$@"
