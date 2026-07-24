# Hermes Mobile Changelog

## v8.1 (2026-07-24) — 基础设施修复 + 本地聊天记录 + 设备状态同步

### 🏗️ 架构升级

#### Relay 消息队列 v3
- **电脑状态同步**: 电脑通过 heartbeat 上报 busy/idle 状态，手机菜单实时显示 💻电脑在线/💻电脑忙碌中
- **忙时排队**: 电脑执行任务时 relay 不推消息，避免多设备并发冲突导致消息丢失
- **队列深度显示**: 菜单显示 📨N条消息排队
- **heartbeat 老化检测**: 超过 300s 无心跳标记 offline

#### 电脑端守护进程 v3
- 读取 `gateway_state.json` 中的 `active_agents` 判断 Gateway 是否忙碌
- 忙时跳过消息处理，空闲后自动继续
- 状态变化即时上报 relay

#### 本地聊天记录持久化
- JSON 文件存储（`hermes_sessions.json` + `chat_<id>.json`），无需 sqflite
- **加载流程**: 本地秒开 → 后台云端同步
- **会话列表**: 优先读本地数据库，离线也能看到历史
- 首次连接自动同步会话列表到本地

### 🐛 Bug 修复

| 问题 | 修复 |
|------|------|
| 丢包率 100% / 显示 `100%%` | `_measureLoss` 计算公式修正 (ok<5→ok<3)，去嵌入%，串行测试替代并行 |
| 云端 probe 超时 | 超时 3s→5s，RTT 过滤 1s→5s 适配移动网络 |
| probe 假"在线" | 无候选通过时抛异常，正确显示"已断线" |
| Settings 保存不生效 | `configVersionProvider` 递增自动触发重新探测 |
| `_refreshRtt` health URL 错误 | strip `/v1` 后再构造路径 |
| `getSessions` 静默吞 401 | 新增 `throwOnError` 参数 |
| ConnectionManager 指数退避溢出 | `retryCount.clamp(0,10)` |
| SSH 隧道端口 8643 被旧进程占用 | 换 8644 端口，nginx 同步更新 |
| relay client 发 Gateway 用错 Auth key | `API_KEY`→`HERMES_KEY` |
| `ref.listen` 红屏崩溃 | 移到 `build()` 方法 |
| 流式输出跳动打断阅读 | 去掉 `ref.listen(messagesProvider)` 的自动滚动 |
| 点会话后不自动滚到底部 | `await loadSession` 后再 `Navigator.pop` |
| relay 队列 `sent` 模式(占位符)泄漏到远端 | sent 消息直接 SSE，不再用 relay 中转 |

### ✨ 功能

| 功能 | 描述 |
|------|------|
| 单点配置 | `api_config.dart` 顶部常量唯一入口（LAN_IP/SERVER_IP/API Key/Relay URL/Relay Key） |
| 会话导出 | 三点菜单 → 导出，保存 Markdown 到 Downloads |
| 新对话入口 | 移入三点菜单（二级菜单），AppBar 只保留 ⋮ |
| 托盘灯 | 重启 bat 中加入 VBS 包装的 tray 进程 |

### ⚠️ 注意事项
- **第一次使用**: 进入 Settings 填写真实服务器地址和 API Key，保存后自动重连
- **SSH 隧道**: 如果云端不通，点桌面 `重启Hermes.bat`
- **API Key**: 代码中全部为占位符，可安全公开到 GitHub
