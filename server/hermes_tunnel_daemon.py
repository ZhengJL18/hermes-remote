#!/usr/bin/env pythonw
"""
Hermes SSH Tunnel Daemon — 永不死的隧道守护进程 v2

功能：
- 自动建立/维护 SSH 反向隧道
- 健康检测（30s 间隔）
- 隧道死亡自动重连（指数退避 5s→60s）
- PID 文件锁防多实例
- 启动时等待 Gateway 就绪
"""

import subprocess
import time
import sys
import os
import json
import socket
import urllib.request
import urllib.error
from datetime import datetime, timedelta

# =================== 配置 ===================
SSH_KEY = os.path.expanduser("~/.ssh/your-ssh-key-name")
SERVER = "ubuntu@your-server-ip"
LOCAL_PORT = 8642
REMOTE_PORT = 8646
HEALTH_CHECK_URL = "http://127.0.0.1:8642/health"
FULL_CHAIN_URL = "http://your-server-ip/hermes/health"
CHECK_INTERVAL = 30
RECONNECT_BACKOFF = [5, 10, 20, 40, 60]
LOG_FILE = os.path.expanduser("~/hermes_tunnel_daemon.log")
PID_FILE = os.path.expanduser("~/hermes_tunnel_daemon.pid")

# =================== PID 锁 ===================
def acquire_lock():
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE) as f:
                old_pid = int(f.read().strip())
            # Check if old process still exists
            import ctypes
            kernel32 = ctypes.windll.kernel32
            handle = kernel32.OpenProcess(1, False, old_pid)
            if handle:
                kernel32.CloseHandle(handle)
                log(f"Daemon already running (PID {old_pid}), exiting")
                sys.exit(0)
        except:
            pass
    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))

def release_lock():
    try:
        os.remove(PID_FILE)
    except:
        pass

# =================== 日志 ===================
def log(msg, level="INFO"):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] [{level}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except:
        pass

# =================== 健康检测 ===================
def check_gateway():
    """检查本地 Gateway"""
    try:
        req = urllib.request.Request(HEALTH_CHECK_URL)
        resp = urllib.request.urlopen(req, timeout=3)
        return resp.status == 200
    except:
        return False

def check_full_chain():
    """检查全链路"""
    try:
        req = urllib.request.Request(FULL_CHAIN_URL)
        resp = urllib.request.urlopen(req, timeout=5)
        return resp.status == 200
    except:
        return False

# =================== 服务器端清理 ===================
def clean_remote_port():
    """清理服务器上的隧道端口"""
    cmd = f'ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "{SSH_KEY}" {SERVER} "sudo fuser -k {REMOTE_PORT}/tcp 2>/dev/null; echo OK"'
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return "OK" in result.stdout
    except:
        return False

# =================== SSH 隧道 ===================
def start_tunnel():
    """启动 SSH 隧道"""
    cmd = [
        "ssh",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=no",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ConnectTimeout=10",
        "-N",
        "-R", f"{REMOTE_PORT}:localhost:{LOCAL_PORT}",
        "-i", SSH_KEY,
        SERVER
    ]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        return proc
    except Exception as e:
        log(f"Failed to start tunnel: {e}", "ERROR")
        return None

# =================== 主循环 ===================
def main():
    acquire_lock()
    log("=" * 50)
    log("Hermes Tunnel Daemon v2 starting...")
    log(f"  Port: {REMOTE_PORT} -> localhost:{LOCAL_PORT}")
    log(f"  Server: {SERVER}")
    log(f"  Interval: {CHECK_INTERVAL}s")
    log("=" * 50)

    # 等 Gateway
    for i in range(15):
        if check_gateway():
            log("Gateway ready")
            break
        time.sleep(2)
    else:
        log("Gateway not ready, starting anyway", "WARN")

    tunnel = None
    failures = 0
    stats = {"restarts": 0}

    while True:
        try:
            # 健康检测
            if check_gateway() and check_full_chain():
                if failures > 0:
                    log(f"RECOVERED after {failures} failures | restarts={stats['restarts']}")
                failures = 0
                time.sleep(CHECK_INTERVAL)
                continue

            # 死了
            failures += 1
            log(f"DOWN (failure #{failures})", "WARN")

            # 杀旧隧道
            if tunnel:
                try:
                    tunnel.terminate()
                    tunnel.wait(timeout=3)
                except:
                    try:
                        tunnel.kill()
                    except:
                        pass
                tunnel = None

            # 清理服务器端口
            clean_remote_port()
            time.sleep(2)

            # 重连
            delay = RECONNECT_BACKOFF[min(failures - 1, len(RECONNECT_BACKOFF) - 1)]
            log(f"Reconnecting in {delay}s...")
            time.sleep(delay)

            tunnel = start_tunnel()
            if tunnel:
                stats["restarts"] += 1
                log(f"Tunnel started (PID {tunnel.pid}, restart #{stats['restarts']})")
                time.sleep(5)  # 等隧道稳定

        except KeyboardInterrupt:
            break
        except Exception as e:
            log(f"Loop error: {e}", "ERROR")
            time.sleep(10)

    release_lock()
    log("Daemon stopped")

if __name__ == "__main__":
    main()
