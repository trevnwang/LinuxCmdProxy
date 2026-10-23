#!/usr/bin/env bash
# 在【被控机 B】上跑：一键装成 systemd 服务
#   bash deploy.sh 'TOKEN串' [绑定地址] [端口] [允许网段]
# 例：bash deploy.sh 'abc123' 100.x.x.x 10086 100.64.0.0/10
set -euo pipefail

TOKEN="${1:-}"; HOST="${2:-0.0.0.0}"; PORT="${3:-10086}"; ALLOW="${4:-100.64.0.0/10}"
[ -n "$TOKEN" ] || { echo "用法: bash deploy.sh 'TOKEN串' [host] [port] [allow-cidr]" >&2; exit 2; }

say() { printf '\033[1m%s\033[0m\n' "$*"; }

say "① 环境检查"
PY=$(command -v python3 || true)
[ -n "$PY" ] || { echo "没找到 python3" >&2; exit 1; }
$PY - <<'PYCHK'
import sys
if sys.version_info < (3, 10):
    sys.exit(f"需要 Python 3.10+，当前 {sys.version.split()[0]}")
print("  python:", sys.version.split()[0])
PYCHK
command -v sudo >/dev/null || { echo "没找到 sudo" >&2; exit 1; }
echo "  sudo: $(sudo -V | head -1)"

say "② 写 token 文件 (~/.cmdapi.env, 600)"
umask 077
printf 'CMDAPI_TOKEN=%s\n' "$TOKEN" > "$HOME/.cmdapi.env"
chmod 600 "$HOME/.cmdapi.env"
echo "  已写 $HOME/.cmdapi.env"

say "③ 安装 systemd 单元"
SRC="$(cd "$(dirname "$0")" && pwd)/systemd/cmdapi.service"
sed -e "s|--host 0.0.0.0|--host $HOST|" \
    -e "s|--port 10086|--port $PORT|" \
    -e "s|--allow 100.64.0.0/10|--allow $ALLOW|" "$SRC" > /tmp/cmdapi@.service
sudo install -m 644 /tmp/cmdapi@.service /etc/systemd/system/cmdapi@.service
sudo systemctl daemon-reload
sudo systemctl enable --now "cmdapi@$USER"
sleep 1.5

say "④ 验收"
systemctl --no-pager --lines=0 status "cmdapi@$USER" | head -5 || true
ss -lntp 2>/dev/null | grep ":$PORT" || echo "  ⚠ 端口 $PORT 没在听"
echo
echo "本地自测（走本机回环，需要 --allow 里包含 127.0.0.1）："
echo "  curl -sS -X POST http://127.0.0.1:$PORT/cmd -H 'Authorization: Bearer <token>' -d '{\"cmd\":\"id\"}' -D-"
echo
echo "主控端调用（A）："
echo "  curl -sS -X POST http://<B的IP>:$PORT/cmd -H 'Authorization: Bearer <token>' -d '{\"cmd\":\"uname -a\"}' -D-"
