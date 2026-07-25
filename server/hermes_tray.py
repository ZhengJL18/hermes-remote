# -*- coding: utf-8 -*-
"""Hermes 隧道监控托盘 — 绿色=在线，红色=离线"""
import sys, os, traceback, threading, time, urllib.request

LOG = os.path.expanduser("~/hermes_tray.log")

def log(msg):
    try:
        with open(LOG, "a") as f: f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except: pass

log("tray starting")
try:
    import pystray
    from PIL import Image, ImageDraw
    log("imports ok")
except Exception as e:
    log(f"import error: {e}")
    sys.exit(1)

def create_icon(color):
    img = Image.new('RGB', (32, 32), color)
    d = ImageDraw.Draw(img)
    d.ellipse((6, 6, 26, 26), fill='white')
    d.ellipse((8, 8, 24, 24), fill=color)
    return img

def check(icon):
    while True:
        try:
            req = urllib.request.Request('http://your-server-ip/hermes/health',
                headers={'Authorization': 'Bearer your-hermes-key-here'})
            with urllib.request.urlopen(req, timeout=5) as r:
                online = r.status == 200
        except Exception as e:
            online = False
            log(f"health check error: {e}")
        try:
            icon.icon = create_icon('#00CC66' if online else '#FF3333')
        except: pass
        time.sleep(15)

try:
    icon = pystray.Icon('Hermes-Tunnel', create_icon('#FF3333'), 'Hermes',
        menu=pystray.Menu(
            pystray.MenuItem('Exit', lambda i: i.stop()),
        ))
    log("icon created")
    threading.Thread(target=check, args=(icon,), daemon=True).start()
    log("entering run")
    icon.run()
    log("run exited")
except Exception as e:
    log(f"fatal: {e}\n{traceback.format_exc()}")
