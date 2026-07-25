@echo off
REM Hermes v5 守护进程 — 每30秒检查 Gateway + frp隧道 + 桥接客户端
:loop

REM 1. 检查 Gateway
curl -s http://127.0.0.1:8642/health --max-time 3 >nul 2>&1
if %errorlevel% neq 0 (
    echo [%date% %time%] Gateway died, restarting...
    start "HermesGateway" /min hermes gateway run
)

REM 2. 检查 frp 隧道（通过云服务器）
curl -s http://your-server-ip/hermes/health --max-time 5 >nul 2>&1
if %errorlevel% neq 0 (
    echo [%date% %time%] frp tunnel died, restarting...
    taskkill /f /fi "WINDOWTITLE eq HermesFrp" 2>nul
    start "HermesFrp" /min C:\Users\24368\Desktop\frp\frp_0.70.1_windows_amd64\frpc.exe -c C:\Users\24368\Desktop\frp\frp_0.70.1_windows_amd64\frpc.toml
    timeout /t 5 >nul
)

REM 3. 检查桥接客户端（通过 relay 心跳）
curl -s http://your-server-ip/relay/status -H "X-API-Key: your-relay-key-here" --max-time 5 2>nul | findstr "online.*true" >nul
if %errorlevel% neq 0 (
    echo [%date% %time%] Client died, restarting...
    taskkill /f /fi "WINDOWTITLE eq HermesClient" 2>nul
    start "HermesClient" /min python -u "C:\Users\24368\hermes_client.py"
)

timeout /t 30 >nul
goto loop
