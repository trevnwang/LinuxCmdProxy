#!/usr/bin/env bash
# 在【被控机 B】上跑：注册成 systemd 服务（开机自启、失败自动重启）
#   安装：sudo bash deploy.sh 'TOKEN串' [绑定地址] [端口] "允许网段1 允许网段2"
#   例：  sudo bash deploy.sh 'abc123'                       # 默认：0.0.0.0:10086，只放行 100.64.0.0/10 与本机回环
#         sudo bash deploy.sh 'abc123' 0.0.0.0 10086 "100.64.0.0/10 127.0.0.1/32"
#   卸载：sudo bash deploy.sh --uninstall
set -euo pipefail

TOKEN="${1:-}"; HOST="${2:-0.0.0.0}"; PORT="${3:-10086}"; ALLOW="${4:-100.64.0.0/10 127.0.0.1/32}"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
need_root() { [ "$(id -u)" = "0" ] || { echo "请用 sudo 跑：sudo bash deploy.sh ..." >&2; exit 2; }; }

if [ "${1:-}" = "--uninstall" ]; then
  need_root
  say "卸载 cmdapi 服务"
  systemctl disable --now cmdapi.service 2>/dev/null || true
  rm -f /etc/systemd/system/cmdapi.service /etc/cmdapi.env
  rm -rf /opt/cmdapi
  systemctl daemon-reload
  echo "  已移除 systemd 单元、/opt/cmdapi、/etc/cmdapi.env"
  exit 0
fi

need_root

# 没给 token 就自动生成一个（与 cmdapi.py 的默认行为一致），并打印出来
if [ -z "$TOKEN" ]; then
  TOKEN=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')
  echo "未指定 token，已自动生成：$TOKEN"
  echo "（它也写在 /etc/cmdapi.env 里，之后可用 sudo cat /etc/cmdapi.env 查回）"
fi

# 服务以调用 sudo 的普通账号运行（sudo 下 $USER 是 root，要用 SUDO_USER）
RUN_USER="${SUDO_USER:-root}"
RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
DIR="$(cd "$(dirname "$0")" && pwd)"

say "① 环境检查"
python3 - <<'PYCHK'
import sys
if sys.version_info < (3, 10):
    sys.exit(f"需要 Python 3.10+，当前 {sys.version.split()[0]}")
print("  python:", sys.version.split()[0])
PYCHK
command -v sudo >/dev/null || { echo "没找到 sudo" >&2; exit 1; }
echo "  sudo: $(sudo -V | head -1)"
echo "  运行账号: $RUN_USER ($RUN_HOME)"

say "② 摆放程序与 token"
install -d -m 755 /opt/cmdapi
install -m 755 "$DIR/cmdapi.py" /opt/cmdapi/cmdapi.py
umask 077
printf 'CMDAPI_TOKEN=%s\n' "$TOKEN" > /etc/cmdapi.env
chmod 600 /etc/cmdapi.env
echo "  /opt/cmdapi/cmdapi.py"
echo "  /etc/cmdapi.env (600)"

say "③ 写 systemd 单元并注册"
ALLOW_ARGS=""
for c in $ALLOW; do ALLOW_ARGS="$ALLOW_ARGS --allow $c"; done
cat > /etc/systemd/system/cmdapi.service <<UNIT
[Unit]
Description=cmdapi - remote command execution API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$RUN_HOME
EnvironmentFile=/etc/cmdapi.env
ExecStart=/usr/bin/python3 /opt/cmdapi/cmdapi.py --host $HOST --port $PORT $ALLOW_ARGS --cwd $RUN_HOME
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable cmdapi.service >/dev/null
systemctl restart cmdapi.service
sleep 1.5

say "④ 验收"
systemctl --no-pager --lines=0 status cmdapi.service | head -6 || true
ss -lntp 2>/dev/null | grep ":$PORT" || echo "  ⚠ 端口 $PORT 没在听"
echo
echo "开机自启: $(systemctl is-enabled cmdapi.service)   当前: $(systemctl is-active cmdapi.service)"
echo
echo "主控端调用（A）："
echo "  curl -sS -X POST http://<B的IP>:$PORT/cmd -H 'Authorization: Bearer <token>' -d '{\"cmd\":\"uname -a\"}' -D-"
echo "  curl -sS -X POST http://<B的IP>:$PORT/sudocmd -H 'Authorization: Bearer <token>' -d '{\"cmd\":\"id -u\",\"password\":\"<sudo密码>\"}' -D-"
echo
echo "日志: journalctl -u cmdapi -f   停止: sudo systemctl stop cmdapi   卸载: sudo bash deploy.sh --uninstall"
