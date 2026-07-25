# Hermes Server

Hermes Agent 云端中继系统 — 消息队列 + 反向代理 + 桥接客户端。

## 架构

```
手机 App ──► nginx ──► frp tunnel ──► PC (Hermes Gateway)
                │
                └──► relay (消息队列) ──► hermes_client (桥接)
```

## 文件说明

| 文件 | 部署位置 | 功能 |
|------|----------|------|
| `hermes_relay.py` | 云服务器 | HTTP 消息队列（收/发/poll/ack/心跳），SQLite + WAL |
| `hermes_tunnel_v3.py` | 云服务器(server) + 本机(client) | TCP 反向隧道（已废弃，推荐用 frp 替代） |
| `hermes_client.py` | 本机 | 桥接客户端：从 relay poll 消息 → 调本地 Hermes API → 回写 relay |
| `hermes_tunnel_daemon.py` | 本机 | SSH 隧道守护进程（已废弃，推荐用 frp 替代） |
| `hermes_tray.py` | 本机 | 系统托盘图标，实时显示隧道状态 |
| `hermes_startup.bat` | 本机 | 开机自启脚本 |
| `hermes_watchdog.bat` | 本机 | 守护进程，每 30 秒检查所有服务 |

## 部署步骤

### 1. 云服务器

```bash
# 安装 relay
scp hermes_relay.py ubuntu@your-server:/home/ubuntu/
ssh ubuntu@your-server "nohup python3 hermes_relay.py &"

# 安装 frps
# 下载 frp: https://github.com/fatedier/frp/releases
# 配置 frps.toml，bindPort=7000，remotePort=18642
# nginx 配置: proxy_pass http://127.0.0.1:18642/ → /hermes/
```

### 2. 本机

```bash
# 复制文件到用户目录
# 修改脚本中的 your-server-ip / your-relay-key-here 为实际值
# 双击 hermes_startup.bat 启动
```

## 安全说明

- 所有密钥/Token 在源码中用占位符 `your-xxx-here` 替换
- relay API Key、frp Token 请单独生成 `openssl rand -hex 32`
- 公网端口应通过 nginx + TLS 代理，不直接暴露
