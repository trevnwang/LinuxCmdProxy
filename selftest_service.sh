#!/usr/bin/env bash
# 本机验证「注册成服务」这条路径（用 systemd --user，不动系统单元）
set -u
U=~/.config/systemd/user/cmdapi-selftest.service
PORT=10090
TOK=selftest-token

mkdir -p ~/.config/systemd/user
cat > "$U" <<EOF
[Unit]
Description=cmdapi selftest (user unit)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/tw
ExecStart=/usr/bin/python3 /home/tw/cmdapi/cmdapi.py --host 127.0.0.1 --port $PORT --token $TOK --allow 127.0.0.1/32 --timeout 5
Restart=on-failure
RestartSec=1

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now cmdapi-selftest.service >/dev/null 2>&1
sleep 1.5

echo "① 状态"
systemctl --user is-active cmdapi-selftest.service
systemctl --user is-enabled cmdapi-selftest.service

echo "② 首次调用"
curl -sS -m 5 -X POST "http://127.0.0.1:$PORT/cmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"echo service-ok; id -un"}' -D- | head -12

echo "③ 杀掉主进程，验证 systemd 自动拉起"
OLD=$(systemctl --user show cmdapi-selftest.service -p MainPID --value)
kill -9 "$OLD" 2>/dev/null
sleep 2.5

echo "   旧 PID=$OLD  新 PID=$(systemctl --user show cmdapi-selftest.service -p MainPID --value)"
echo "   状态=$(systemctl --user is-active cmdapi-selftest.service)"

echo "④ 重启后再调一次"
curl -sS -m 5 -X POST "http://127.0.0.1:$PORT/cmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"date +%T"}' -D- | tail -3

echo "⑤ 停止并清理自测单元"
systemctl --user disable --now cmdapi-selftest.service >/dev/null 2>&1
rm -f "$U"
systemctl --user daemon-reload
echo "   已移除 $U"
