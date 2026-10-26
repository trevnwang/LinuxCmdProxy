# cmdapi — 被控机（B）远程命令执行 API

一台 Linux 机器上跑的单文件服务，主控机（A）通过 HTTP 调它执行命令。
**零第三方依赖**，只用 Python 3 标准库；装上就能跑。

```
A ── POST /cmd ────────────────► B  以当前用户执行
A ── POST /sudocmd + password ─► B  sudo -S 执行（密码走 stdin）
```

## 需求（用户 2026-10-23 提出，原文要点）

1. 被控 B 两个接口：`/cmd` 普通用户运行，`/sudocmd` sudo 运行且需带 sudo 密码。
2. **必须有 token 认证**，token 不对调不通。
3. `/sudocmd` 除 token 外还要 sudo 密码。
4. **优先一个服务两个端点**（不能做才拆两个端口）。
5. `--host 0.0.0.0` 语义：支持 `--host x.x.x.x`，例如 `--host 100.x.x.x` 就只有该网段能访问；
   另有 IP block：不在允许列表的 IP 拒绝。
6. `--port` 可指定，默认 `10086`。
7. 返回值 = bash/zsh 给的**纯文字**，不多不少，行为与终端里跑一模一样。
8. 工程目录在用户家目录，**git 管理**每次需求变更与澄清。

## 决策记录（每次澄清一次 commit）

| # | 决策 | 结论 | 来源 |
|---|---|---|---|
| D1 | 被控机 B | 另一台 Linux，不在本机；代码按“自己就是 B”写 | 2026-10-23 澄清 |
| D2 | `--host` 语义 | 就是**绑定地址**（标准语义）；`100.x.x.x` 只听该网卡 | 2026-10-23 澄清 |
| D3 | IP 白名单 | 独立一层 `--allow`（支持 CIDR、可重复），默认只放行本机回环 | 需求第 5 条 |
| D4 | sudo 密码传输 | **JSON body**：`{"cmd": "...", "password": "..."}`（方案 A） | 2026-10-23 选 A |
| D5 | sudo 密码使用 | `sudo -S -k -p ''`，密码只走 **stdin**，绝不进 argv（防 `ps` 泄露） | 设计 |
| D6 | token 传输 | `Authorization: Bearer <token>`；常量时间比较 | 设计 |
| D7 | 返回体 | stdout+stderr **合并原文**，不加工；退出码放响应头 **`X-Exit-Code`** | **待用户确认（方案 A 暂定）** |
| D8 | 服务形态 | 单进程双端点（`/cmd`、`/sudocmd`），不拆端口 | 需求第 3 条 |
| D9 | 目标机环境 | **Ubuntu 22.04+**，Python 3.10+（默认自带），`sudo` 已装；代码只用标准库，语法按 3.10 校验 | 2026-10-23 澄清 |

## 用法

```bash
# 被控机 B
python3 cmdapi.py --host 100.x.x.x --port 10086 \
    --token '一串随机串' --allow 100.64.0.0/10

# 主控机 A
curl -sS -X POST http://1.2.3.4:10086/cmd \
     -H "Authorization: Bearer 一串随机串" \
     -d '{"cmd":"uname -a"}' -D-

curl -sS -X POST http://1.2.3.4:10086/sudocmd \
     -H "Authorization: Bearer 一串随机串" \
     -d '{"cmd":"systemctl restart nginx","password":"***"}' -D-
```

响应：

```
HTTP/1.1 200 OK
X-Exit-Code: 0
Content-Type: text/plain; charset=utf-8
...
<命令输出原文>
```

失败码：

| HTTP | 含义 |
|---|---|
| 400 | body 不是 JSON / 缺 `cmd` / `/sudocmd` 缺 `password` |
| 401 | token 缺失或不对 |
| 403 | 来源 IP 不在 `--allow` 内 |
| 404 | 路径不是 `/cmd`、`/sudocmd` |
| 405 | 用了 GET（只收 POST） |

命令超时：进程组整组 SIGKILL，`X-Exit-Code: 124`，输出尾部追加一行 `[cmdapi] timeout after Ns`。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--host` | `0.0.0.0` | 绑定地址 |
| `--port` | `10086` | 端口 |
| `--token` | 环境变量 `CMDAPI_TOKEN` → 否则 `~/.cmdapi/token` | 不传也不报错：没有就**自动生成**一个（600 存盘，重启沿用），启动时打印 |
| `--allow` | `127.0.0.1/32`、`::1/128`、`100.64.0.0/10` | 允许的 IP/CIDR，可重复（空格分隔多个） |
| `--timeout` | `300` | 单条命令超时（秒） |
| `--cwd` | `~` | 命令的工作目录 |

## 不传 `--token` 会怎样

```bash
python3 cmdapi.py            # 不报错
# → 未指定 --token，已生成默认 token 并保存到 ~/.cmdapi/token (600)：
#      EfSHDRaDiZQOHfv21CuoGETN72idepWpmT3cqBSmy4U
```

- 首次启动生成 32 字节随机串，写 `~/.cmdapi/token`（目录 700、文件 600）；
- 之后每次启动**沿用同一个**，不会变；
- 显式 `--token` 或 `CMDAPI_TOKEN` 优先，默认文件只在两者都没有时才用。

> 生产环境仍建议显式指定 token（`deploy.sh` 会写进 `/etc/cmdapi.env`），默认 token 只是让手工试跑不卡在参数上。

## `--host` 和 `--allow` 是两件事

| 参数 | 作用 | 典型用法 |
|---|---|---|
| `--host` | **只决定监听哪张网卡** | `0.0.0.0` 全听；`100.x.x.x` 只听那张网卡（该写法是举例，填真实地址） |
| `--allow` | **按来源 IP 放行**，不在名单内直接 `403` | `--allow 100.64.0.0/10 --allow 127.0.0.1/32` |

一条需求只需要 `--allow`：**来源是 `100.64.0.0/10` 或 `127.0.0.1` 就放行，否则 403**。
`--host` 保持默认 `0.0.0.0` 即可，不必为了限制来源去改它。

## 安全须知（必读）

- 这套东西等价于**把 shell（甚至 root）挂在 HTTP 上**。**只在内网 / Tailscale 上开**，绝不映射公网。
- 明文 HTTP 会让 token 和 sudo 密码在链路上可见；能上 HTTPS 就上（反代或 stunnel 都行）。
- `--allow` 与 `--host` 两道一起用：绑 `100.x` 网卡 + 只放行 `100.64.0.0/10`。
- token 别写进命令行历史：用 `CMDAPI_TOKEN` 环境变量或 systemd `EnvironmentFile`。
- 审计日志只记 IP / 路径 / 退出码 / 耗时 / 字节数，**不记命令正文和密码**。

## 状态

- `cmdapi.py` 0.1.0：双端点、token、IP 白名单、超时、退出码头。
- 待定：D7 退出码方案（A 头部 / B 不给 / C 映射 500）。

## 注册成 systemd 服务（被控机 B）—— 正式交付形态

```bash
sudo bash deploy.sh '你的TOKEN'          # 默认 0.0.0.0:10086，只放行 100.64.0.0/10 + 127.0.0.1
# 自定义（绑定地址 / 端口 / 多个网段用引号包起来）
sudo bash deploy.sh '你的TOKEN' 0.0.0.0 10086 "100.64.0.0/10 127.0.0.1/32"
# 卸载
sudo bash deploy.sh --uninstall
```

脚本做四件事，全程幂等，可重复跑：

1. 检查 Python ≥ 3.10、`sudo` 存在；
2. 程序装到 `/opt/cmdapi/cmdapi.py`，token 写 `/etc/cmdapi.env`（600，只走 `EnvironmentFile`，不进 argv）；
3. 生成 `/etc/systemd/system/cmdapi.service`（`User=$SUDO_USER`、`Restart=on-failure`、`WantedBy=multi-user.target`）；
4. `daemon-reload` → `enable` → `restart`，并打印 `is-enabled` / `is-active` 与端口监听情况。

服务特性：

- **开机自启**（`systemctl is-enabled cmdapi` → `enabled`）
- **崩溃自动拉起**（`Restart=on-failure`，`RestartSec=2`）
- 日志走 journal：`journalctl -u cmdapi -f`
- 停止：`sudo systemctl stop cmdapi`

## 手工安装为 systemd 服务（被控机 B）

```bash
# 1) token 文件（600）
printf 'CMDAPI_TOKEN=%s\n' "$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" > ~/.cmdapi.env
chmod 600 ~/.cmdapi.env

# 2) 装服务（把 User 换成跑它的账号）
sudo cp systemd/cmdapi.service.example /etc/systemd/system/cmdapi@.service
sudo systemctl daemon-reload
sudo systemctl enable --now cmdapi@$USER

# 3) 查
systemctl status cmdapi@$USER
journalctl -u cmdapi@$USER -f     # 审计日志：ip/path/http/exit/bytes/ms
```

## 自测

```bash
bash smoke.sh    # 13 项：鉴权、路由、退出码、合并输出、超时、IP 白名单
```
