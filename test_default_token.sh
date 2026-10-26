#!/usr/bin/env bash
# 验证：不传 --token 也能启动，自动生成默认 token；重启沿用同一个
set -u
cd "$(dirname "$0")"
export HOME=/tmp/cmdapi_home
rm -rf "$HOME"; mkdir -p "$HOME"
PORT=10092
LOG=/tmp/tok_test.log

start() { python3 cmdapi.py --host 127.0.0.1 --port $PORT --allow 127.0.0.1/32 >"$LOG" 2>&1 & echo $!; }

PID=$(start); sleep 1.4
echo "── 启动输出"; cat "$LOG"
TOK=$(tail -1 "$LOG" | tr -d ' ')
echo "── 提取到的 token: ${#TOK} 位"
echo "── token 文件权限: $(stat -c '%a %n' "$HOME/.cmdapi/token")"
echo "── 用这个 token 调 /cmd"
curl -sS -m 5 -X POST "http://127.0.0.1:$PORT/cmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"echo default-token-ok"}' -D- | tail -3
kill $PID 2>/dev/null; sleep 0.5

PID=$(start); sleep 1.4
TOK2=$(tail -1 "$LOG" | tr -d ' ')
echo "── 重启后 token 与首次一致? $([ "$TOK" = "$TOK2" ] && echo 是 || echo 否)"
kill $PID 2>/dev/null; sleep 0.3

echo "── 显式 --token 仍优先"
python3 cmdapi.py --host 127.0.0.1 --port $PORT --token explicit-abc --allow 127.0.0.1/32 >"$LOG" 2>&1 &
PID=$!; sleep 1.2
curl -sS -m 5 -o /dev/null -w "  explicit token → HTTP %{http_code}\n" -X POST "http://127.0.0.1:$PORT/cmd" -H "Authorization: Bearer explicit-abc" -d '{"cmd":"true"}'
curl -sS -m 5 -o /dev/null -w "  旧默认 token → HTTP %{http_code}（应 401）\n" -X POST "http://127.0.0.1:$PORT/cmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"true"}'
kill $PID 2>/dev/null
