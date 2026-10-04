#!/usr/bin/env bash
#
# Vibe Coding Workstation —— 诊断信息收集
#
# 只读：不修改任何东西。用于在部署异常时一次性拿到全部线索。
#
#   ./scripts/doctor.sh            # 打印到终端
#   ./scripts/doctor.sh > d.txt    # 存文件，便于贴回
#   ./scripts/doctor.sh --logs     # 额外附上每个服务的完整日志尾部
#
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
PREFIX="vibecotion"

WITH_LOGS=0
[ "${1:-}" = "--logs" ] && WITH_LOGS=1

hdr() { printf '\n========== %s ==========\n' "$*"; }
sub() { printf '\n--- %s ---\n' "$*"; }

hdr "环境"
echo "时间:        $(date -Iseconds)"
echo "主机:        $(cat /etc/os-release 2>/dev/null | sed -n 's/^PRETTY_NAME=//p')"
echo "内核:        $(uname -r)"
echo "podman:      $(podman --version 2>&1 | head -1)"
echo "systemd:     $(systemctl --version 2>/dev/null | head -1)"
echo "SELinux:     $(getenforce 2>/dev/null || echo unknown)"
echo "linger:      $(loginctl show-user "$(id -u)" --property=Linger --value 2>/dev/null)"
echo "XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-<unset>}"

sub "代理环境（导致容器内构建失败的关键）"
env | grep -iE 'proxy' | sed 's/^/  /' || echo "  （无）"

hdr "服务状态"
systemctl --user list-units --all --no-legend 2>/dev/null | grep "$PREFIX" | sed 's/^/  /' \
  || echo "  （未发现 $PREFIX 单元）"

hdr "Pod 与容器"
sub "pod"
podman pod ps 2>&1 | sed 's/^/  /'
sub "容器（本项目）"
podman ps -a --format '  {{.Names}}\t{{.Status}}\t{{.Image}}' 2>&1 | grep "$PREFIX" || echo "  （无）"
sub "镜像（本项目 + 基础）"
podman images --format '  {{.Repository}}:{{.Tag}}\t{{.Created}}' 2>&1 \
  | grep -E 'vibecotion|fedoraproject|quay.io/fedora|forgejo|opencloud|caddy|cloudflared' || echo "  （无）"
sub "卷"
podman volume ls --format '  {{.Name}}' 2>&1 | grep "$PREFIX" || echo "  （无）"

hdr "端口与入口"
sub "9999 监听情况"
ss -tlnp 2>/dev/null | grep -E ':(9999)\b' | sed 's/^/  /' || echo "  9999 未监听"
sub "入口自测"
for u in http://127.0.0.1:9999/healthz http://127.0.0.1:9999/; do
  printf '  %-40s ' "$u"
  curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 "$u" 2>&1 || echo "失败"
done

hdr "各服务日志（末尾 15 行）"
for name in gateway agent forgejo opencloud cloudflared workbench-dev workbench-test workbench-staging; do
  sub "vibecotion-$name"
  podman logs --tail 15 "$PREFIX-$name" 2>&1 | sed 's/^/  /' || echo "  （取不到日志）"
done

if [ "$WITH_LOGS" = 1 ]; then
  hdr "systemd journal（完整）"
  for name in gateway agent forgejo opencloud cloudflared; do
    sub "vibecotion-$name.service"
    journalctl --user -u "$PREFIX-$name.service" -n 60 --no-pager 2>&1 | sed 's/^/  /'
  done
fi

hdr "渲染产物一致性"
"$SCRIPT_DIR/render.sh" --check 2>&1 | tail -5 | sed 's/^/  /'

hdr "构建日志存在情况"
ls -l "$REPO_DIR"/.build-*.log 2>/dev/null | sed 's/^/  /' || echo "  （无，说明上次构建成功或未构建）"

hdr "结束"
echo "若要更多信息，重跑并加 --logs。"
