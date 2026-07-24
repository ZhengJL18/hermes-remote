# Hermes Remote — Flutter 移动端遥控器

通过云中继 + SSH 隧道，让手机远程操控电脑上的 [Hermes Agent](https://github.com/NousResearch/hermes-agent)。

## 功能

- 💬 **实时聊天** — SSE 流式输出，Markdown 渲染
- ☁️ **离线消息** — SQLite 持久化 relay 消息队列，电脑不在线消息不丢
- 🔀 **多通道自动切换** — 局域网优先，远程云服务器兜底，探针自动选最快
- 📊 **状态监控** — 底部状态栏：连接灯 + 延迟 + 丢包率，独立定时刷新
- ⚙️ **完全可配置** — 设置页自定义 API 地址（局域网/远程）、Relay 地址、API Key
- 💾 **本地缓存** — SharedPreferences 缓存最近会话，断网也能看历史
- 🎨 **Hermes 设计语言** — 橙色主色调，AI 透明气泡，用户细线边框

## 架构

```
手机 Flutter → 云 relay (Python + SQLite) → 电脑 client → Hermes Agent
                    ↕ (消息队列 + 心跳)
              手机/电脑状态双向可见
```

## 快速开始

1. 电脑端部署 relay 和 client（见 `/tools`）
2. 手机安装 APK
3. 设置页填入：
   - 局域网地址（如 `http://192.168.x.x:8642/v1`）
   - 远程地址（如 `http://your-server/hermes/v1`）
   - API Key
4. APP 自动探测，选最快的通道连接

## 配置项

| 设置 | 说明 |
|------|------|
| 局域网地址 | 优先使用，同 WiFi 下满速 |
| 远程地址 | SSH 隧道暴露的公网地址 |
| API Key | Hermes API Server 的认证密钥 |
| Relay 地址 | 云中继服务地址 |
| Relay Key | 中继认证密钥 |

## 技术栈

- Flutter 3.x + Dart
- Riverpod 状态管理
- SharedPreferences 本地缓存
- HttpClient SSE 流式 + relay 轮询
- Python http.server (Threading) + SQLite 消息队列

## 开发

```bash
flutter pub get
flutter build apk --debug
```

APK 输出到 `build/app/outputs/flutter-apk/app-debug.apk`
