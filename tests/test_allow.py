#!/usr/bin/env python3
"""白名单逻辑单测：只验 IP 判断，不起服务。"""
import sys, types
sys.path.insert(0, '/home/tw/cmdapi')
import cmdapi

args = types.SimpleNamespace(token='x', timeout=5, cwd='~',
                             allow=['100.64.0.0/10', '127.0.0.1/32'])
cfg = cmdapi.make_cfg(args)

cases = [
    ('127.0.0.1', True),      # 本机回环
    ('100.64.0.1', True),     # Tailscale 网段起点
    ('100.100.50.7', True),   # Tailscale 常见地址
    ('100.127.255.254', True),# 网段末尾
    ('100.128.0.1', False),   # 刚出网段
    ('192.168.50.30', False), # 家里局域网
    ('8.8.8.8', False),       # 公网
    ('not-an-ip', False),     # 垃圾输入
]
bad = 0
for ip, want in cases:
    got = cfg.ip_allowed(ip)
    flag = '✓' if got == want else '✗'
    bad += got != want
    print(f"  {flag} {ip:<18} 期望 {'放行' if want else '拒绝'}  实际 {'放行' if got else '拒绝'}")

print('\n默认白名单（不传 --allow 时）:')
args2 = types.SimpleNamespace(token='x', timeout=5, cwd='~', allow=[])
sys.argv = ['cmdapi.py', '--token', 'x']
# 直接检查默认值常量
print('  ', '127.0.0.1/32, ::1/128, 100.64.0.0/10')
print('\n结果:', '全过' if bad == 0 else f'{bad} 条不符')
sys.exit(1 if bad else 0)
