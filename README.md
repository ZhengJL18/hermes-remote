# Hermes Remote — Flutter 移动端遥控器

通过 SSH 隧道 + 云中继，让手机远程操控电脑上的 [Hermes Agent](https://github.com/NousResearch/hermes-agent)。

## 功能

- 实时聊天：SSE 流式输出，支持 Markdown 渲染
- 离线消息：云 relay 消息队列，电脑不在线消息不丢
- 多通道：局域网直连优先，云服务器兜底
- 状态监控：延迟/丢包率实时显示，连接状态灯
- 可配置：任意 Hermes API Server 地址 + Key 均可连接

## 快速开始

1. 设置页填入你的 Hermes API 地址和 Key
2. 电脑端部署 relay 和 client（见 `/tools` 目录）
3. 开始聊天

## 架构

```
手机 Flutter → 云 relay(消息队列) → 电脑 client → Hermes Agent
```
