#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════
#  [F] hermes_tunnel_v3.py — TCP 反向隧道 修复版
#  改动点对应聊天分析报告 1/2/4/5/20 号问题（这几个是"隧道经常死"的主因）：
#   - 控制连接(csock)加超时，不会再永久阻塞整个服务
#   - 修掉响应转发时的死循环(对端断开时recv()一直返回b''却不退出)
#   - 4字节长度头和请求体读取都改成"读够为止"的精确读取，不再假设一次recv就能读满
#   - 电脑端重连时会先关掉旧的控制连接，不再有僵尸连接占位
#   - 控制通道加了一个简单的共享密钥握手，防止陌生连接冒充"电脑端"接管隧道
#   - 公网端口本身依然没有应用层鉴权，这层建议必须由 nginx/relay 的 X-API-Key 兜底，
#     见聊天里第5号问题，光靠这个脚本改不掉"tunnel本身不解析HTTP"这个设计局限
# ═══════════════════════════════════════════════════════════════════
import socket, sys, time

CTRL = 7000
PUB = 8648
HANDSHAKE_SECRET = b"your-relay-key-here"  # [FIX-5] 和relay用同一把key，仅用于"谁能注册成电脑端"的校验，
                                         #   不是完整的应用层鉴权方案，只是把"随便一个TCP连接就能顶替电脑端"这个洞堵上


def _recv_exact(sock, n):
    """[FIX-4] 精确读满 n 字节；连接中途断开返回 None（而不是死循环或半截数据）。"""
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def client():
    while True:
        try:
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 15)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 5)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
            s.settimeout(30)
            s.connect(("your-server-ip", CTRL))
            s.sendall(HANDSHAKE_SECRET)  # [FIX-5] 握手
            print("[client] Connected")

            while True:
                try:
                    header = _recv_exact(s, 4)
                    if header is None:
                        break
                    length = int.from_bytes(header, 'big')
                    if length > 10_000_000 or length < 0:
                        break

                    data = _recv_exact(s, length)
                    if data is None:
                        break

                    api = socket.socket()
                    api.settimeout(10)
                    try:
                        api.connect(("127.0.0.1", 8642))
                        api.sendall(data)

                        resp = b""
                        api.settimeout(5)
                        while True:
                            try:
                                c = api.recv(65536)
                                if not c:
                                    break
                                resp += c
                            except socket.timeout:
                                break
                    finally:
                        api.close()

                    s.sendall(len(resp).to_bytes(4, 'big') + resp)

                except socket.timeout:
                    continue
                except Exception:
                    break

        except Exception as e:
            print(f"[client] {e}")

        print("[client] Reconnecting...")
        time.sleep(5)


def server():
    ctrl = socket.socket()
    ctrl.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ctrl.bind(("0.0.0.0", CTRL))
    ctrl.listen(5)  # [FIX-20] 放宽backlog，避免重连期间被拒

    pub = socket.socket()
    pub.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    pub.bind(("0.0.0.0", PUB))
    pub.listen(50)
    pub.settimeout(1.0)  # 定期回来检查是否有新的电脑端连接需要接管

    ctrl.settimeout(0.5)

    print(f"[server] Ready ctrl={CTRL} pub={PUB}")
    csock = None

    while True:
        try:
            # [FIX-20] 每轮都非阻塞检查一下有没有新的电脑端来连接；
            # 有的话不管旧连接死没死，直接切换过去（旧的关掉），
            # 避免"旧连接半死不活占着位置，真正的重连排不上号"。
            try:
                new_csock, addr = ctrl.accept()
                if csock is not None:
                    try:
                        csock.close()
                    except Exception:
                        pass
                token = _recv_exact_blocking(new_csock, len(HANDSHAKE_SECRET), timeout=5)
                if token != HANDSHAKE_SECRET:
                    print(f"[server] Rejected ctrl conn from {addr}: bad handshake")
                    new_csock.close()
                else:
                    new_csock.settimeout(30)  # [FIX-1] 关键修复：不会再永久阻塞
                    csock = new_csock
                    print(f"[server] Client: {addr}")
            except socket.timeout:
                pass

            if csock is None:
                time.sleep(0.2)
                continue

            try:
                conn, addr = pub.accept()
            except socket.timeout:
                continue

            req = b""
            conn.settimeout(5)
            try:
                while True:
                    c = conn.recv(65536)
                    if not c:
                        break
                    req += c
                    if b"\r\n\r\n" in req:
                        break
            except socket.timeout:
                pass

            if req:
                try:
                    csock.sendall(len(req).to_bytes(4, 'big') + req)

                    header = _recv_exact(csock, 4)  # [FIX-1][FIX-4] 现在有超时,不会永久挂住
                    if header:
                        rlen = int.from_bytes(header, 'big')
                        resp = _recv_exact(csock, rlen)  # [FIX-2] 断线时返回None而不是死循环空转
                        if resp is not None:
                            conn.sendall(resp)
                except (socket.timeout, ConnectionError, OSError) as e:
                    print(f"[server] ctrl conn broken: {e}")
                    try:
                        csock.close()
                    except Exception:
                        pass
                    csock = None  # 触发下一轮等待电脑端重新握手

            conn.close()

        except Exception as e:
            print(f"[server] {e}")
            if csock:
                try:
                    csock.close()
                except Exception:
                    pass
                csock = None


def _recv_exact_blocking(sock, n, timeout=5):
    sock.settimeout(timeout)
    try:
        return _recv_exact(sock, n)
    except socket.timeout:
        return None


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "server":
        server()
    else:
        client()
