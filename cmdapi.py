#!/usr/bin/env python3
"""cmdapi — 被控机 B 上的远程命令执行 API。

两个端点，一个服务：
    POST /cmd      {"cmd": "ls -l"}                     # 以当前用户执行
    POST /sudocmd  {"cmd": "systemctl restart nginx",
                    "password": "***"}                   # 以 sudo 执行（密码只走 stdin）

设计要点（全部来自需求）：
  * token 认证：请求头 Authorization: Bearer <token>
  * IP 白名单：--allow 支持 CIDR，可重复；默认只放行本机
  * --host 绑定地址（0.0.0.0 = 全网卡；100.x.x.x = 只听那张网卡）
  * --port 默认 10086
  * 返回体 = 命令输出原文（stdout+stderr 合并，顺序与终端一致），退出码放响应头 X-Exit-Code
"""
from __future__ import annotations

import argparse
import hmac
import ipaddress
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.1.0"
DEFAULT_PORT = 10086
DEFAULT_TIMEOUT = 300
MAX_BODY = 1 << 20  # 1 MiB


# ---------------------------------------------------------------- 执行
def run_command(cmd: str, password: str | None, timeout: int, cwd: str) -> tuple[bytes, int]:
    """跑一条命令，返回 (合并后的输出字节, 退出码)。

    password 为 None → 普通用户；否则 sudo -S（密码从 stdin 读），并用 -k 保证
    每次请求都真实验证密码（不吃之前 15 分钟的缓存）。
    """
    shell = "/bin/bash" if os.path.exists("/bin/bash") else "/bin/sh"
    if password is None:
        argv = [shell, "-c", cmd]
        stdin_data = None
    else:
        argv = ["sudo", "-S", "-k", "-p", "", shell, "-c", cmd]
        stdin_data = password + "\n"

    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=cwd,
            start_new_session=True,  # 便于超时时整组杀掉
        )
    except FileNotFoundError:
        return b"[cmdapi] sudo not found\n", 127

    try:
        out, _ = proc.communicate(
            input=stdin_data.encode("utf-8") if stdin_data is not None else None,
            timeout=timeout,
        )
        code = proc.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        out, _ = proc.communicate()
        out += f"\n[cmdapi] timeout after {timeout}s\n".encode()
        code = 124
    return out, code


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = f"cmdapi/{VERSION}"
    protocol_version = "HTTP/1.1"

    # --- 配置从 server 上取
    @property
    def cfg(self):
        return self.server.cfg  # type: ignore[attr-defined]

    def log_message(self, fmt, *args):  # 保持安静：自己记审计行
        pass

    def _audit(self, path: str, status: int, code: int | None, started: float, size: int):
        line = (
            f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} ip={self.client_address[0]} "
            f"path={path} http={status} exit={code if code is not None else '-'} "
            f"bytes={size} ms={int((time.monotonic() - started) * 1000)}"
        )
        print(line, file=sys.stderr, flush=True)

    def _plain(self, status: int, body: bytes, extra: dict[str, str] | None = None):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Cmdapi-Version", VERSION)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _deny(self, status: int, msg: str, path: str, started: float):
        body = (msg + "\n").encode()
        self._plain(status, body)
        self._audit(path, status, None, started, len(body))

    def do_GET(self):
        started = time.monotonic()
        self._deny(405, "use POST", self.path, started)

    def do_POST(self):
        started = time.monotonic()
        path = self.path.split("?", 1)[0]
        cfg = self.cfg

        # 1) IP 白名单
        ip = self.client_address[0]
        if not cfg.ip_allowed(ip):
            return self._deny(403, "forbidden: ip not allowed", path, started)

        # 2) token
        auth = self.headers.get("Authorization", "")
        scheme, _, provided = auth.partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(provided.strip(), cfg.token):
            return self._deny(401, "unauthorized", path, started)

        # 3) 路由
        if path not in ("/cmd", "/sudocmd"):
            return self._deny(404, "not found", path, started)

        # 4) body
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return self._deny(400, "bad content-length", path, started)
        if length <= 0 or length > MAX_BODY:
            return self._deny(400, "bad body size", path, started)
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return self._deny(400, "body must be JSON", path, started)
        cmd = payload.get("cmd") if isinstance(payload, dict) else None
        if not isinstance(cmd, str) or not cmd:
            return self._deny(400, "missing cmd", path, started)

        password = None
        if path == "/sudocmd":
            password = payload.get("password")
            if not isinstance(password, str) or not password:
                return self._deny(400, "missing password", path, started)

        # 5) 执行
        out, code = run_command(cmd, password, cfg.timeout, cfg.cwd)
        self._plain(200, out, {"X-Exit-Code": str(code)})
        self._audit(path, 200, code, started, len(out))


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, cfg):
        super().__init__(addr, handler)
        self.cfg = cfg


def make_cfg(args):
    class Cfg:
        token = args.token
        timeout = args.timeout
        cwd = os.path.expanduser(args.cwd)
        nets = []
    for item in args.allow:
        try:
            Cfg.nets.append(ipaddress.ip_network(item, strict=False))
        except ValueError:
            sys.exit(f"bad --allow value: {item}")

    def ip_allowed(ip_str: str) -> bool:
        try:
            ip = ipaddress.ip_address(ip_str)
        except ValueError:
            return False
        return any(ip in n for n in Cfg.nets)

    Cfg.ip_allowed = staticmethod(ip_allowed)
    return Cfg


def main():
    ap = argparse.ArgumentParser(prog="cmdapi", description="被控机远程命令执行 API")
    ap.add_argument("--host", default="0.0.0.0", help="绑定地址（绑定网卡即限制了来源网段）")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--token", default=os.environ.get("CMDAPI_TOKEN", ""), help="认证 token（也可用 CMDAPI_TOKEN）")
    ap.add_argument("--allow", action="append", default=[],
                    help="允许的 IP/网段，可重复；默认 127.0.0.1/32 与 ::1/128")
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="单条命令超时秒数")
    ap.add_argument("--cwd", default="~", help="执行命令的工作目录，默认家目录")
    ap.add_argument("--version", action="version", version=f"cmdapi {VERSION}")
    args = ap.parse_args()

    if not args.token:
        sys.exit("missing --token (or CMDAPI_TOKEN env)")
    if not args.allow:
        args.allow = ["127.0.0.1/32", "::1/128"]

    cfg = make_cfg(args)
    srv = Server((args.host, args.port), Handler, cfg)
    print(f"cmdapi {VERSION} listening on {args.host}:{args.port}  "
          f"allow={','.join(args.allow)}  cwd={cfg.cwd}  timeout={cfg.timeout}s", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("bye", file=sys.stderr)


if __name__ == "__main__":
    main()
