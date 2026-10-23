#!/usr/bin/env bash
# cmdapi 冒烟测试：只在本机回环上跑，不改系统
set -u
cd "$(dirname "$0")"
TOK="test-token-123"
PORT=10086
LOG=/tmp/cmdapi_smoke_server.log

python3 cmdapi.py --host 127.0.0.1 --port $PORT --token "$TOK" --allow 127.0.0.1/32 --timeout 3 >"$LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT
sleep 1.2

req() { # $1=desc $2..=curl args
  local desc="$1"; shift
  echo "── $desc"
  curl -sS -m 8 -o /tmp/out.txt -D /tmp/hdr.txt "$@" || echo "  curl failed"
  local code; code=$(awk 'NR==1{print $2}' /tmp/hdr.txt)
  local exitcode; exitcode=$(grep -i '^X-Exit-Code:' /tmp/hdr.txt | tr -d '\r' | awk '{print $2}')
  echo "  HTTP=$code  X-Exit-Code=${exitcode:-—}"
  echo "  body: $(head -c 200 /tmp/out.txt | tr '\n' '|')"
}

B="http://127.0.0.1:$PORT"
req "无 token（应 401）"        -X POST "$B/cmd" -d '{"cmd":"echo hi"}'
req "错 token（应 401）"       -X POST "$B/cmd" -H "Authorization: Bearer nope" -d '{"cmd":"echo hi"}'
req "正常 echo（应 200/0）"    -X POST "$B/cmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"echo hi"}'
req "退出码 3（应 200/3）"     -X POST "$B/cmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"exit 3"}'
req "stdout+stderr 合并顺序"   -X POST "$B/cmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"echo 1; echo 2 >&2; echo 3"}'
req "未授权路径（应 404）"     -X POST "$B/nope" -H "Authorization: Bearer $TOK" -d '{"cmd":"echo hi"}'
req "GET（应 405）"            "$B/cmd" -H "Authorization: Bearer $TOK"
req "缺 cmd（应 400）"         -X POST "$B/cmd" -H "Authorization: Bearer $TOK" -d '{}'
req "sudocmd 缺密码（应 400）" -X POST "$B/sudocmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"id -u"}'
req "sudocmd 错密码（应 200/1）" -X POST "$B/sudocmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"id -u","password":"definitely-wrong"}'
req "超时（应 124）"           -X POST "$B/cmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"sleep 10; echo never"}'
req "工作目录=家目录"          -X POST "$B/cmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"pwd"}'

kill $PID 2>/dev/null; sleep 0.3
# IP 白名单拒绝
python3 cmdapi.py --host 127.0.0.1 --port $PORT --token "$TOK" --allow 10.0.0.0/8 >"$LOG" 2>&1 &
PID=$!; sleep 1.0
req "IP 不在白名单（应 403）"  -X POST "$B/cmd" -H "Authorization: Bearer $TOK" -d '{"cmd":"echo hi"}'
echo
echo "── 服务端审计日志"
cat "$LOG"
