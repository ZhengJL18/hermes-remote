@echo off
REM Hermes v5 — Gateway + frp隧道 + 桥接客户端 + 30秒守护
REM 开机自启: 放入 shell:startup 文件夹

REM 起 Gateway
start "HermesGateway" /min hermes gateway run

REM 起 frp 隧道（替代旧的 hermes_tunnel_v3.py）
start "HermesFrp" /min C:\Users\24368\Desktop\frp\frp_0.70.1_windows_amd64\frpc.exe -c C:\Users\24368\Desktop\frp\frp_0.70.1_windows_amd64\frpc.toml

REM 等隧道建立
timeout /t 5 >nul

REM 起桥接客户端（poll relay → 调 Hermes → reply）
start "HermesClient" /min python -u "C:\Users\24368\hermes_client.py"

REM 起系统托盘（右下角绿/红灯，后台隐藏）
cscript //nologo "C:\Users\24368\Desktop\button\tray_hidden.vbs"

REM 起守护进程
start "HermesWatchdog" /min cmd /c "C:\Users\24368\hermes_watchdog.bat"

echo Hermes v5 started: Gateway + frp + Client + Watchdog
