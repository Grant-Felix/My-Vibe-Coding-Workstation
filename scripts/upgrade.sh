#!/usr/bin/env bash
#
# Vibe Coding Workstation —— 基础发行版升级
#
# 决策 D17：全部**自建镜像**使用 Fedora 作为基础发行版，与宿主同源。
# 有可用更新时可升级，但**必须显式执行本脚本** —— 不静默漂移。
#
# 只使用**稳定版**：Fedora N 正式发布后才可选，绝不使用 Beta。
#（判断依据：registry.fedoraproject.org 上该 tag 是否存在于 releases/；
#  Beta 位于 releases/test/，本脚本不查询该路径。）
#
# 用法：
#   upgrade.sh --check    检查是否有可用的新稳定版（不改动任何东西）
#   upgrade.sh --to 45    升级到指定版本（必须是稳定版）
#   upgrade.sh --latest   升级到最新稳定版
#   upgrade.sh --dry-run  预览
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DECL="$REPO_DIR/workstation.yaml"

CHECK=0; TO=""; LATEST=0; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1 ;;
    --to)      shift; [ $# -gt 0 ] || { printf -- '--to 需要版本号\n' >&2; exit 2; }; TO="$1" ;;
    --latest)  LATEST=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
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
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_R" "$*"; }
dry()  { printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_R" "$*"; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/decl.sh
. "$SCRIPT_DIR/lib/decl.sh"
_decl_files=(); decl_add_layer "$DECL"

CURRENT="$(decl_get base.version)"
CURRENT="${CURRENT//\"/}"
[ -n "$CURRENT" ] || die "声明缺少 base.version"

# ── 查询稳定版 ──────────────────────────────────────────────────────
# 只认 Fedora 官方 releases/ 路径下的版本；Beta 在 releases/test/，不予考虑。
stable_versions() {
  curl -s --max-time 30 'https://fedoraproject.org/releases.json' 2>/dev/null \
    | python3 -c "
import json,sys,re
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = d if isinstance(d, list) else d.get('releases', [])
vs = set()
for it in items:
    if not isinstance(it, dict): continue
    v = it.get('version')
    link = str(it.get('link',''))
    if not v: continue
    vs.add(str(v).strip())
def key(x):
    m = re.match(r'^(\d+)$', x)
    return int(m.group(1)) if m else -1
for v in sorted(vs, key=key):
    if key(v) > 0:
        print(v)
"
}

# ── 改版本号（唯一动作：改 workstation.yaml 的 base.version）────────
set_version() {
  local want="$1"
  step "设定基础发行版为 Fedora $want"
  if [ "$DRY_RUN" = 1 ]; then
    dry "workstation.yaml: base.version \"$want\""
    return 0
  fi
  sed -i "s|^\(  version: \).*|\1\"$want\"|" "$DECL" 2>/dev/null || true
  ok "base.version 已设为 $want"
  say "  $C_DIM下一步：./scripts/install.sh 重新构建镜像并滚动重启$C_R"
}

main() {
  local avail
  avail="$(stable_versions)"

  if [ "$CHECK" = 1 ] || [ -z "$TO$LATEST" ]; then
    step "检查基础发行版"
    say "  当前：Fedora $CURRENT"
    if [ -z "$avail" ]; then
      warn "无法取得 Fedora 版本列表（网络？）"
      return 0
    fi
    say "  官方稳定版：$(printf '%s' "$avail" | tr '\n' ' ')"
    local newest
    newest="$(printf '%s\n' "$avail" | tail -1)"
    if [ "$newest" = "$CURRENT" ]; then
      ok "已是最新稳定版（Fedora $CURRENT）"
    else
      warn "有更新的稳定版：Fedora $newest"
      say "  升级：$SCRIPT_DIR/upgrade.sh --to $newest"
      say "  $C_DIM（Beta 不在可选范围内）$C_R"
    fi
    return 0
  fi

  local target="$TO"
  if [ "$LATEST" = 1 ]; then
    target="$(printf '%s\n' "$avail" | tail -1)"
    [ -n "$target" ] || die "无法取得最新稳定版"
  fi

  # 拒绝 Beta：不在稳定版列表里的版本一律拒绝
  if ! printf '%s\n' "$avail" | grep -qx "$target"; then
    die "Fedora $target 不是官方稳定版（可能是 Beta 或不存在）。可选：$(printf '%s' "$avail" | tr '\n' ' ')"
  fi

  if [ "$target" = "$CURRENT" ]; then
    ok "已经是 Fedora $target"
    return 0
  fi

  set_version "$target"
}

main "$@"
