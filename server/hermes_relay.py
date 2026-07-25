#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════
#  [D] hermes_relay.py — 云端消息队列 修复版
#  改动点对应聊天分析报告里的 6/7/8/9 号问题：
#   - 心跳不再"谁发都算电脑在线"
#   - processing 状态的消息加超时自动requeue，不会永久卡死/丢失
#   - 加了真正会被调用的后台清理线程
#   - /status 的 outbox 计数不再硬编码为0
#   - 新增 /history/<session_id>，供电脑端桥接拉取会话上下文
# ═══════════════════════════════════════════════════════════════════
import json, time, threading, sqlite3, os
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

API_KEY = "your-relay-key-here"
DB = os.path.expanduser("~/hermes_relay.db")
LOCK = threading.Lock()
TTL = 300                      # 心跳超时(秒)
PROCESSING_TIMEOUT = 90        # [FIX-8] 消息被取走(processing)超过这么久还没done→当作卡死,requeue回pending

# [FIX-6] 手机和电脑分开记录，不再混用一个字段
device_status = {
    "phone":    {"online": False, "last_heartbeat": 0},
    "computer": {"online": False, "busy": False, "last_heartbeat": 0},
}

def init_db():
    conn = sqlite3.connect(DB)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS queue(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        direction TEXT,
        session_id TEXT,
        data TEXT,
        status TEXT DEFAULT 'pending',
        ts REAL,
        updated_ts REAL
    )""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_q_status ON queue(direction, status)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_q_session ON queue(session_id, ts)")
    conn.commit()
    conn.close()

def enqueue(direction, session_id, data):
    with LOCK:
        conn = sqlite3.connect(DB)
        now = time.time()
        conn.execute(
            "INSERT INTO queue(direction,session_id,data,status,ts,updated_ts) VALUES(?,?,?,'pending',?,?)",
            (direction, session_id, json.dumps(data), now, now))
        conn.commit()
        mid = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        conn.close()
    return mid

def dequeue(direction, limit=10):
    with LOCK:
        conn = sqlite3.connect(DB)
        rows = conn.execute(
            "SELECT id,data FROM queue WHERE direction=? AND status='pending' ORDER BY id LIMIT ?",
            (direction, limit)).fetchall()
        ids = [r[0] for r in rows]
        if ids:
            placeholders = ','.join('?' * len(ids))
            conn.execute(
                f"UPDATE queue SET status='processing', updated_ts=? WHERE id IN ({placeholders})",
                (time.time(), *ids))
            conn.commit()
        conn.close()
    return [{"id": r[0], **json.loads(r[1])} for r in rows]

def ack(msg_id, new_status="done"):
    if msg_id is None:  # [FIX-#] 校验，避免UPDATE ... WHERE id=NULL静默无效
        return False
    with LOCK:
        conn = sqlite3.connect(DB)
        conn.execute("UPDATE queue SET status=?, updated_ts=? WHERE id=?",
                     (new_status, time.time(), msg_id))
        conn.commit()
        conn.close()
    return True

def requeue_stuck():
    """[FIX-8] processing 状态超过 PROCESSING_TIMEOUT 还没 ack → 当作电脑端处理失败/掉线,
    重新丢回 pending，让下一次 /poll 能再次拿到，而不是永久卡死。"""
    with LOCK:
        conn = sqlite3.connect(DB)
        cutoff = time.time() - PROCESSING_TIMEOUT
        conn.execute(
            "UPDATE queue SET status='pending', updated_ts=? WHERE status='processing' AND updated_ts < ?",
            (time.time(), cutoff))
        conn.commit()
        conn.close()

def cleanup_old():
    """[FIX-7] 现在真的会被后台线程周期调用了。"""
    with LOCK:
        conn = sqlite3.connect(DB)
        conn.execute("DELETE FROM queue WHERE status='done'")
        conn.execute("DELETE FROM queue WHERE ts < ?", (time.time() - 3600,))
        conn.commit()
        conn.close()

def maintenance_loop():
    while True:
        try:
            requeue_stuck()
            cleanup_old()
        except Exception as e:
            print(f"[maintenance] {e}")
        time.sleep(30)

init_db()

class Relay(BaseHTTPRequestHandler):
    def _auth(self):
        return self.headers.get("X-API-Key", "") == API_KEY

    def _json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "X-API-Key, Content-Type")
        self.end_headers()

    def do_POST(self):
        if not self._auth():
            self._json({"error": "unauthorized"}, 401)
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length > 0 else b'{}'
            body = json.loads(raw)
        except Exception as e:
            self._json({"error": f"bad request: {e}"}, 400)
            return

        if self.path == "/send":
            mid = enqueue("inbox", body.get("session_id", "default"), body)
            self._json({"ok": True, "id": mid})

        elif self.path == "/reply":
            enqueue("outbox", body.get("session_id", "default"), body)
            self._json({"ok": True})

        elif self.path == "/ack":
            ok = ack(body.get("id"), body.get("status", "done"))
            self._json({"ok": ok})

        elif self.path == "/heartbeat":
            # [FIX-6] 严格按 who 字段区分，谁发的心跳只更新谁的状态，
            # 手机在线 ≠ 电脑在线。未知/缺失 who 时不更新任何状态，只回200。
            who = body.get("who")
            if who in ("phone", "computer"):
                device_status[who]["online"] = True
                device_status[who]["last_heartbeat"] = time.time()
                if who == "computer":
                    device_status["computer"]["busy"] = body.get("busy", False)
            self._json({"ok": True})

        else:
            self._json({"error": "unknown"}, 404)

    def do_GET(self):
        if not self._auth():
            self._json({"error": "unauthorized"}, 401)
            return

        if self.path == "/poll":
            msgs = dequeue("inbox", limit=10)
            self._json(msgs)

        elif self.path.startswith("/fetch"):
            sid = self.path.replace("/fetch/", "").replace("/fetch", "") or None
            with LOCK:
                conn = sqlite3.connect(DB)
                if sid:
                    rows = conn.execute(
                        "SELECT id,data FROM queue WHERE direction='outbox' AND session_id=? AND status='pending' ORDER BY id",
                        (sid,)).fetchall()
                else:
                    # [安全提示] 不带sessionId会拿到所有会话的outbox；
                    # 客户端应始终带sessionId，服务端这里保留兼容行为但不建议依赖。
                    rows = conn.execute(
                        "SELECT id,data FROM queue WHERE direction='outbox' AND status='pending' ORDER BY id"
                    ).fetchall()
                ids = [r[0] for r in rows]
                if ids:
                    placeholders = ','.join('?' * len(ids))
                    conn.execute(f"DELETE FROM queue WHERE id IN ({placeholders})", ids)
                    conn.commit()
                conn.close()
            self._json([{"id": r[0], **json.loads(r[1])} for r in rows])

        elif self.path.startswith("/history/"):
            # [新增，支撑E文件的上下文修复] 返回某个session最近N条inbox+outbox消息
            sid = self.path.replace("/history/", "")
            with LOCK:
                conn = sqlite3.connect(DB)
                rows = conn.execute(
                    "SELECT direction,data,ts FROM queue WHERE session_id=? ORDER BY ts DESC LIMIT 20",
                    (sid,)).fetchall()
                conn.close()
            history = []
            for direction, data, ts in reversed(rows):
                d = json.loads(data)
                history.append({
                    "role": "user" if direction == "inbox" else "assistant",
                    "content": d.get("content", ""),
                })
            self._json(history)

        elif self.path == "/status":
            now = time.time()
            phone_age = now - device_status["phone"]["last_heartbeat"]
            computer_age = now - device_status["computer"]["last_heartbeat"]
            with LOCK:
                conn = sqlite3.connect(DB)
                inbox_n = conn.execute(
                    "SELECT COUNT(*) FROM queue WHERE direction='inbox' AND status IN ('pending','processing')"
                ).fetchone()[0]
                outbox_n = conn.execute(  # [FIX-9] 真查，不再硬编码0
                    "SELECT COUNT(*) FROM queue WHERE direction='outbox' AND status='pending'"
                ).fetchone()[0]
                conn.close()
            self._json({
                "ok": True, "version": 5,
                "phone": {
                    "online": device_status["phone"]["online"] and phone_age < TTL,
                    "last_seen_sec": int(phone_age),
                },
                "computer": {
                    "online": device_status["computer"]["online"] and computer_age < TTL,
                    "busy": device_status["computer"]["busy"],
                    "last_seen_sec": int(computer_age),
                },
                "queue": {"inbox": inbox_n, "outbox": outbox_n, "total": inbox_n + outbox_n}
            })

        else:
            self._json({"error": "unknown"}, 404)

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    threading.Thread(target=maintenance_loop, daemon=True).start()  # [FIX-7]
    ThreadingHTTPServer(("0.0.0.0", 8700), Relay).serve_forever()
