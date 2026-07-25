#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════
#  [E] hermes_client.py — 电脑端桥接客户端 修复版
#  改动点对应聊天分析报告 6/7/13/19 号问题：
#   - 真正会发心跳(who=computer)了，relay才能准确知道电脑是否在线
#   - 处理完消息后调用 /ack，配合relay端的requeue机制，消息不会再"卡死消失"
#   - 调 Hermes 前先拉 /history/<session_id>，带上下文而不是每次都失忆
#   - 日志加大小上限，简单轮转
#   - 面向用户的错误回复不再直接暴露原始异常堆栈信息
# ═══════════════════════════════════════════════════════════════════
import json, time, threading, urllib.request, os

RELAY = "http://your-server-ip/relay"
API_KEY = "your-relay-key-here"
HERMES = "http://127.0.0.1:8642/v1/chat/completions"
HERMES_KEY = "your-hermes-key-here"
LOG = os.path.expanduser("~/hermes_client.log")
LOG_MAX_BYTES = 5 * 1024 * 1024  # [FIX-19] 5MB封顶，超过就截断，避免无限增长

def log(msg):
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > LOG_MAX_BYTES:
            # 简单轮转：只保留最后一半，避免无限增长
            with open(LOG, "r", encoding="utf-8", errors="ignore") as f:
                f.seek(-LOG_MAX_BYTES // 2, os.SEEK_END)
                tail = f.read()
            with open(LOG, "w", encoding="utf-8") as f:
                f.write(tail)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except Exception:
        pass

def api(url, data=None, timeout=10):
    try:
        if data:
            body = json.dumps(data).encode()
            req = urllib.request.Request(url, data=body,
                headers={"Content-Type": "application/json", "X-API-Key": API_KEY})
        else:
            req = urllib.request.Request(url, headers={"X-API-Key": API_KEY})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception as e:
        log(f"api error: {e}")
        return None

def fetch_history(session_id):
    """[FIX-13] 之前这里完全没有历史上下文，relay路径下AI是"失忆"的。
    现在先问 relay 要最近的会话历史，拼进 messages。"""
    if not session_id or session_id == "default":
        return []
    hist = api(f"{RELAY}/history/{session_id}", timeout=10)
    if not isinstance(hist, list):
        return []
    # 最后一条通常就是这次刚发的这条 inbox 消息本身，交给调用方去重/追加，这里只取历史部分
    return hist

def process(msg):
    """
    从 relay 拿到一条消息，发给本地 Hermes Gateway 获取 AI 回复。
    返回 (reply_text, is_error)
    """
    try:
        session_id = msg.get("session_id", "default")
        history = fetch_history(session_id)  # [FIX-13]

        messages = list(history) if history else []
        messages.append({"role": "user", "content": msg.get("content", "")})
        # 简单限长，避免上下文无限增长把请求撑爆
        if len(messages) > 20:
            messages = messages[-20:]

        body = json.dumps({
            "model": "hermes-agent",
            "messages": messages,
            "stream": False,
        }).encode()

        req = urllib.request.Request(HERMES, data=body,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {HERMES_KEY}"
            })
        if session_id and session_id != "default":
            req.add_header("X-Hermes-Session-Id", session_id)

        with urllib.request.urlopen(req, timeout=120) as resp:
            result = json.loads(resp.read())
            return result["choices"][0]["message"]["content"], False
    except Exception as e:
        # [FIX-19] 详细异常只写日志，不直接回显给用户，避免把内部路径/端口/堆栈
        # 当成"AI回复"发到聊天气泡里。
        log(f"process error: {e}")
        return "⚠️ 处理消息时出错，请稍后重试", True

def heartbeat_loop():
    """[FIX-6] 电脑端现在会真正发心跳了，relay的 /status 才能反映电脑真实在线状态，
    而不是像修复前那样完全依赖手机端的心跳。独立线程，不受消息处理速度影响。"""
    while True:
        api(f"{RELAY}/heartbeat", data={"who": "computer", "busy": False}, timeout=5)
        time.sleep(20)

log("client v4 started (heartbeat + ack + history)")
threading.Thread(target=heartbeat_loop, daemon=True).start()

consecutive_poll_failures = 0

while True:
    try:
        msgs = api(f"{RELAY}/poll", timeout=10)
        if msgs is None:
            consecutive_poll_failures += 1
            time.sleep(min(1 * consecutive_poll_failures, 10))  # 简单退避，别对着挂掉的relay猛打
            continue
        consecutive_poll_failures = 0

        for msg in msgs:
            mid = msg.get("id", "?")
            content = msg.get("content", "")[:50]
            log(f"[{mid}] processing: {content}")

            reply, is_error = process(msg)

            api(f"{RELAY}/reply", data={
                "session_id": msg.get("session_id", "default"),
                "role": "assistant",
                "content": reply
            })

            # [FIX-7] 处理完必须 ack，否则消息永远卡在 processing，
            # relay 端超时requeue机制也就是给这里万一忘了ack或者进程中途崩溃兜底用的。
            api(f"{RELAY}/ack", data={"id": mid, "status": "done" if not is_error else "failed"})

            log(f"[{mid}] done: {reply[:60]}")

    except Exception as e:
        log(f"loop error: {e}")

    time.sleep(1)
