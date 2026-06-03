#!/bin/bash
# ==========================================
# Master Controller (launcher.sh) - 行程樹分析版
# ==========================================
CORE_SCRIPT="./record.sh"
PROBE_SCRIPT="./probe.sh"
CONFIG_FILE="./config.env"

if [ ! -f "$CORE_SCRIPT" ] || [ ! -f "$PROBE_SCRIPT" ]; then
    echo "[ERROR] 找不到核心腳本或刺探腳本！"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 找不到設定檔 config.env！"
    exit 1
fi

# 載入全域設定
source "$CONFIG_FILE"

PREFIX="${TARGET_URL##*@}"
PREFIX="${PREFIX%%/live*}"
SAVE_DIR="${HOME}/tk/${PREFIX}"
# 防呆機制：如果 config 沒寫 WEB_PORT，預設使用 36591
WEB_PORT=${WEB_PORT:-36591} 

case "$1" in
    start)
        echo "[Launcher] 正在清理戰場..."
        pkill -f "probe.sh" 2>/dev/null
        pkill -f "$(basename "$CORE_SCRIPT")" 2>/dev/null
        pkill -9 -f "streamlink" 2>/dev/null
        pkill -9 -f "ffmpeg.*mpegts" 2>/dev/null
        pkill -f "web_server.py" 2>/dev/null
        pkill -f "python3.*$WEB_PORT" 2>/dev/null
        sleep 1
        
        mkdir -p "$SAVE_DIR"

        echo "[Launcher] 啟動背景雷達刺探 (Target: @$PREFIX)..."
        nohup bash "$PROBE_SCRIPT" >> "$SAVE_DIR/${PREFIX}_probe.log" 2>&1 &
        echo "[Launcher] ✅ 雷達已在背景開始巡邏！(PID: $!)"

        if ! command -v python3 &> /dev/null; then
            echo "[ERROR] 系統未安裝 Python3，無法啟動網頁伺服器。"
        else
            echo "[Launcher] 正在同步啟動客製化網頁伺服器..."
            
            cat << 'EOF' > "$SAVE_DIR/web_server.py"
import os, http.server, socketserver, urllib.parse
from datetime import datetime

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/latest_size':
            self.send_response(200)
            self.send_header("Content-type", "text/plain; charset=utf-8")
            self.end_headers()
            try:
                files = [f for f in os.listdir('.') if f.endswith('.ts')]
                if not files:
                    self.wfile.write(b"NONE|0")
                    return
                latest_file = max(files, key=os.path.getmtime)
                size = os.path.getsize(latest_file)
                if size > 1024**3: size_str = f"<b>{size/1024**3:.2f} GB</b>"
                else: size_str = f"{size/1024**2:.2f} MB"
                self.wfile.write(f"{latest_file}|{size_str}".encode('utf-8'))
            except Exception:
                self.wfile.write(b"ERROR|0")
            return
        return super().do_GET()

    def list_directory(self, path):
        try:
            files = os.listdir(path)
        except OSError:
            self.send_error(404, "No permission")
            return None
        files.sort(key=lambda a: os.path.getmtime(os.path.join(path, a)), reverse=True)
        r = ['<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>直播錄影庫</title>']
        r.append('<style>body{background:#121212;color:#e0e0e0;font-family:sans-serif;padding:20px;line-height:1.6} table{width:100%;max-width:900px;border-collapse:collapse;margin-top:20px} th,td{padding:12px;text-align:left;border-bottom:1px solid #333} th{background:#222;color:#fff} a{color:#4facfe;text-decoration:none} a:hover{text-decoration:underline} tr:hover{background:#1a1a1a} .live-badge{background:#dc3545;color:#fff;font-size:12px;padding:3px 8px;border-radius:12px;margin-left:10px;animation:pulse 1.5s infinite;vertical-align:middle} @keyframes pulse{0%{opacity:1} 50%{opacity:0.4} 100%{opacity:1}}</style></head><body>')
        r.append('<h2>🎥 直播錄影檔案庫 <span class="live-badge">🔴 Live</span></h2><table id="vidTable"><tr><th>檔名</th><th>大小</th><th>錄影時間</th></tr>')
        for name in files:
            if name.startswith(".") or name == "web_server.py" or name.endswith(".log"): continue
            fullname = os.path.join(path, name)
            displayname = name + "/" if os.path.isdir(fullname) else name
            stat = os.stat(fullname)
            size = stat.st_size
            if os.path.isdir(fullname): size_str = "-"
            elif size > 1024**3: size_str = f"<b>{size/1024**3:.2f} GB</b>"
            else: size_str = f"{size/1024**2:.2f} MB"
            mtime = datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M:%S')
            r.append(f'<tr><td><a href="{urllib.parse.quote(name)}">{displayname}</a></td><td>{size_str}</td><td>{mtime}</td></tr>')
        r.append('</table>')
        r.append('''<script>
            setInterval(function(){
                fetch('/api/latest_size').then(r => r.text()).then(txt => {
                    if(!txt || txt.includes("NONE") || txt.includes("ERROR")) return;
                    let parts = txt.split('|');
                    let table = document.getElementById("vidTable");
                    if(table && table.rows.length > 1) {
                        let firstRow = table.rows[1];
                        if(firstRow.cells[0].innerText.includes(parts[0])) {
                            firstRow.cells[1].innerHTML = parts[1];
                        } else { location.reload(); }
                    }
                });
            }, 1000);
        </script></body></html>''')
        encoded = ''.join(r).encode('utf-8')
        self.send_response(200)
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
        return None

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", 36591), Handler) as httpd:
    httpd.serve_forever()
EOF

            sed -i "s/36591/$WEB_PORT/g" "$SAVE_DIR/web_server.py"
            cd "$SAVE_DIR" || exit
            nohup python3 web_server.py > web_server_error.log 2>&1 &
            
            LOCAL_IP=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
            [ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"
            echo "================================================="
            echo -e "👉 系統已全面啟動！面板網址: \e[36mhttp://$LOCAL_IP:$WEB_PORT\e[0m"
            echo "================================================="
        fi
        ;;
    stop)
        echo "[Launcher] 發送終止指令..."
        pkill -f "probe.sh" 2>/dev/null
        pkill -f "$(basename "$CORE_SCRIPT")" 2>/dev/null
        pkill -9 -f "streamlink" 2>/dev/null
        pkill -9 -f "ffmpeg.*mpegts" 2>/dev/null
        pkill -f "web_server.py" 2>/dev/null
        pkill -f "python3.*$WEB_PORT" 2>/dev/null
        echo "[Launcher] 🛑 刺探雷達、錄影引擎與網頁伺服器已完全關閉。"
        ;;
    status)
        trap 'printf "\e[0m"; clear; exit' INT
        declare -A LAST_BYTES
        
        while true; do
            clear 
            echo "================================================================================================"
            echo " 系統即時監控面板 (Target: @$PREFIX)  |  退出面板請按 [Ctrl+C]"
            echo "================================================================================================"
            
            # 【Suckless 黑魔法】：直接分析系統行程樹
            PROBE_STATE="\e[31m[已停止 STOPPED]\e[0m"
            PROBE_PID=$(pgrep -f "[p]robe.sh" | head -n 1)
            
            if [ -n "$PROBE_PID" ]; then
                if pgrep -f "$(basename "$CORE_SCRIPT")" > /dev/null; then
                    PROBE_STATE="\e[32m[已交接錄影: 哨兵休眠中]\e[0m"
                else
                    CHILD_PID=$(pgrep -P "$PROBE_PID" | head -n 1)
                    
                    if [ -n "$CHILD_PID" ]; then
                        CHILD_CMD=$(ps -p "$CHILD_PID" -o comm= 2>/dev/null)
                        
                        if [[ "$CHILD_CMD" == "streamlink" ]]; then
                            PROBE_STATE="\e[35m[正在發送請求: 檢測開播狀態...]\e[0m"
                        elif [[ "$CHILD_CMD" == "sleep" ]]; then
                            SLEEP_VAL=$(ps -p "$CHILD_PID" -o args= | awk '{print $2}')
                            ELAPSED=$(ps -p "$CHILD_PID" -o etimes= | tr -d ' ')
                            REMAIN=$(( SLEEP_VAL - ELAPSED ))
                            [ $REMAIN -lt 0 ] && REMAIN=0

                            if [ "$SLEEP_VAL" -ge 300 ]; then
                                PROBE_STATE="\e[33m[深度休眠: 非排程時段 (倒數 ${REMAIN} 秒後醒來)]\e[0m"
                            else
                                PROBE_STATE="\e[36m[刺探待命中: 倒數 ${REMAIN} 秒後發起偵測]\e[0m"
                            fi
                        else
                            PROBE_STATE="\e[90m[資料處理中...]\e[0m"
                        fi
                    else
                        PROBE_STATE="\e[90m[資料處理中...]\e[0m"
                    fi
                fi
            fi
            
            echo -e " 📡 雷達刺探 (probe):   $PROBE_STATE"

            # 錄影與網頁狀態
            if pgrep -f "$(basename "$CORE_SCRIPT")" > /dev/null; then
                echo -e " 🎥 核心引擎 (record):  \e[32m[錄影中 RUNNING]\e[0m"
            else
                echo -e " 🎥 核心引擎 (record):  \e[90m[待命/未開播 SLEEPING]\e[0m"
            fi
            
            if pgrep -f "web_server.py" > /dev/null; then
                echo -e " 🌐 網頁伺服器 (Web):   \e[32m[運行中: Port $WEB_PORT]\e[0m"
            else
                echo -e " 🌐 網頁伺服器 (Web):   \e[31m[未啟動]\e[0m"
            fi
            
            echo "------------------------------------------------------------------------------------------------"
            echo "=== 錄影核心 IO 監控 ==="
            printf "%-12s | %-8s | %-6s  %-10s | %-10s | %s\n" "時間" "PID" "狀態" "速度(KiB)" "大小(MB/KB)" "目標檔案"
            echo "------------------------------------------------------------------------------------------------"
            
            HAS_RECORD=0
            for pid in $(pgrep -f "ffmpeg.*mpegts"); do
                [ -f "/proc/$pid/io" ] || continue
                curr=$(awk '/^write_bytes:/ {print $2}' "/proc/$pid/io" 2>/dev/null)
                [[ -z "$curr" ]] && continue
                prev=${LAST_BYTES[$pid]:-0}
                LAST_BYTES[$pid]=$curr
                if [ "$prev" -eq 0 ]; then continue; fi
                
                speed=$(awk -v c="$curr" -v p="$prev" 'BEGIN {print int((c - p) / 1024 / 1.0)}')
                if [ "$speed" -gt 0 ]; then status_icon="\e[32m✔\e[0m"; else status_icon="\e[31m✘\e[0m"; fi
                file=$(lsof -p "$pid" 2>/dev/null | awk '$9 ~ /\.ts$/ {print $9}' | head -n 1)
                fsize_val="0.00"
                [ -f "$file" ] && fsize_val=$(ls -nl "$file" | awk '{b=$5; if(b>=1048576) printf "%.2f", b/1048576; else printf "%.2f", b/1024}')
                
                printf "%-10s | %-8s | %-12b  %-12s | %-10s | %s\n" "$(date +%H:%M:%S)" "$pid" "$status_icon" "$speed" "$fsize_val" "$file"
                HAS_RECORD=1
            done
            
            if [ "$HAS_RECORD" -eq 0 ]; then
                echo -e "  \e[90m(目前無正在寫入的錄影進程)\e[0m"
            fi
            
            sleep 1.0
        done
        ;;
    log)
        echo "你想查看哪個日誌？ 1) 網頁/系統 2) 刺探雷達 (probe) 3) 錄影核心 (record)"
        read -rp "選擇 (1/2/3): " log_choice
        case "$log_choice" in
            1) [ -f "$SAVE_DIR/web_server_error.log" ] && tail -f "$SAVE_DIR/web_server_error.log" || echo "無網頁日誌" ;;
            2) [ -f "$SAVE_DIR/${PREFIX}_probe.log" ] && tail -f "$SAVE_DIR/${PREFIX}_probe.log" || echo "無雷達日誌" ;;
            3) [ -f "$SAVE_DIR/${PREFIX}_record.log" ] && tail -f "$SAVE_DIR/${PREFIX}_record.log" || echo "無錄影日誌" ;;
            *) echo "無效選擇" ;;
        esac
        ;;
    *)
        echo "使用方式: ./launcher.sh {start|stop|status|log}"
        exit 1
        ;;
esac
