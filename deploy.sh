#!/bin/bash
# ============================================================
#  Hermes Agent Flutter — 一键编译 + 推送
#  用法: ./deploy.sh [apk|phone|server|all]
#    apk    仅编译 APK
#    phone  编译 + ADB 安装到手机
#    server 编译 + 上传到云服务器
#    all    编译 + 手机 + 服务器
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APK_PATH="$SCRIPT_DIR/build/app/outputs/flutter-apk/app-debug.apk"

# ── 环境 ──────────────────────────────────────────────────
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PATH="/d/flutter/bin:$PATH"
export ANDROID_HOME="D:/Android"
export JAVA_HOME="C:/Program Files/Microsoft/jdk-21.0.11.10-hotspot"

SERVER="ubuntu@43.139.179.58"
SERVER_PATH="/home/ubuntu/hermes-agent.apk"

# ── 颜色 ──────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── 编译 ──────────────────────────────────────────────────
build_apk() {
    echo -e "${BLUE}🔨 编译 Flutter APK...${NC}"
    cd "$SCRIPT_DIR"
    rm -f "$APK_PATH"  # 先删旧的，失败不会误用
    flutter build apk --debug 2>&1 | tail -5
    if [ ! -f "$APK_PATH" ]; then
        echo -e "${YELLOW}❌ 编译失败！${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ APK 编译完成${NC}"
    ls -lh "$APK_PATH"
}

# ── ADB 推送到手机 ───────────────────────────────────────
push_to_phone() {
    echo ""
    echo -e "${BLUE}📱 检测 ADB 设备...${NC}"
    DEVICES=$(adb devices 2>/dev/null | grep -v "List of" | grep "device$" | wc -l)
    if [ "$DEVICES" -eq 0 ]; then
        echo -e "${YELLOW}⚠️  未检测到设备，尝试 TCP/IP 连接...${NC}"
        # 常用手机 IP
        for ip in 192.168.3.{100..150} 192.168.1.{100..150}; do
            adb connect "$ip" 2>/dev/null && break
        done 2>/dev/null
        sleep 1
    fi

    if adb devices 2>/dev/null | grep -q "device$"; then
        echo -e "${GREEN}📲 安装到手机...${NC}"
        adb install -r "$APK_PATH" 2>&1
        echo -e "${GREEN}✅ 已安装！手机打开 Hermes Agent 即可${NC}"
    else
        echo -e "${YELLOW}⚠️  ADB 未连接，跳过手机推送${NC}"
        echo "   手动: adb install -r build/app/outputs/flutter-apk/app-debug.apk"
    fi
}

# ── 推送到 P2P Inbox ─────────────────────────────────────
INBOX="C:/Users/24368/Desktop/HermesInbox"

push_to_server() {
    echo ""
    echo -e "${BLUE}📤 推送到 P2P Inbox...${NC}"
    # 删光所有旧版本
    rm -f "$INBOX"/Hermes*.apk "$INBOX"/三一*.apk "$INBOX"/*.apk 2>/dev/null
    # 推送新版本
    cp "$APK_PATH" "$INBOX/Hermes.apk"
    echo -e "${GREEN}✅ P2P Inbox: $INBOX/Hermes.apk${NC}"
}

# ── 主流程 ────────────────────────────────────────────────
MODE="${1:-all}"
echo "=========================================="
echo "  Hermes Agent Flutter — 一键部署"
echo "=========================================="

build_apk

case "$MODE" in
    apk)
        push_to_server
        echo -e "${GREEN}✅ 完成 (编译+共享区)${NC}"
        ;;
    phone)
        push_to_phone
        ;;
    server)
        push_to_server
        ;;
    all|*)
        push_to_phone
        push_to_server
        ;;
esac

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  🎉 全部完成！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
