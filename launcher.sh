#!/bin/bash
# ==========================================
# Master Controller (launcher.sh) - 終極單檔整合版
# (純 Linux 版：含本機 mpv 遙控器、網頁端雷達即時狀態)
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

source "$CONFIG_FILE"
PREFIX="${TARGET_URL##*@}"
PREFIX="${PREFIX%%/live*}"
SAVE_DIR="${HOME}/tk_suckless/${PREFIX}"
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
            
            # --- 以下是動態生成的 Python 伺服器 (內含 HTML) ---
            cat << 'EOF' > "$SAVE_DIR/web_server.py"
import os, sys, http.server, socketserver, urllib.parse, subprocess, shutil
from datetime import datetime

# ================= HTML 模板 =================
HTML_TEMPLATE = """
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>直播錄影庫</title>
<style>
body{background:#121212;color:#e0e0e0;font-family:sans-serif;padding:20px;line-height:1.6}
table{width:100%;max-width:1000px;border-collapse:collapse;margin-top:20px}
th,td{padding:12px;text-align:left;border-bottom:1px solid #333;vertical-align:middle}
th{background:#222;color:#fff} a{color:#4facfe;text-decoration:none;font-weight:bold} a:hover{text-decoration:underline} tr:hover{background:#1a1a1a}
.live-badge{background:#dc3545;color:#fff;font-size:12px;padding:3px 8px;border-radius:12px;margin-left:10px;animation:pulse 1.5s infinite;vertical-align:middle;display:inline-block}
.offline-badge{background:#6c757d;color:#fff;font-size:12px;padding:3px 8px;border-radius:12px;margin-left:10px;vertical-align:middle;display:inline-block}
@keyframes pulse{0%{opacity:1} 50%{opacity:0.4} 100%{opacity:1}}
.preview-box{position:relative;display:inline-block;cursor:pointer;width:40px;text-align:center}
.preview-box .icon{font-size:22px;filter:grayscale(100%);opacity:0.6;transition:all 0.2s;display:inline-block}
.preview-box:hover .icon{filter:grayscale(0%);opacity:1;transform:scale(1.2)}
.thumb{position:absolute;left:40px;top:50%;transform:translateY(-50%) translateX(-10px);width:256px;height:144px;background:#000;border-radius:8px;object-fit:cover;border:2px solid #4facfe;box-shadow:0 8px 25px rgba(0,0,0,0.9);opacity:0;visibility:hidden;transition:all 0.2s cubic-bezier(0.2,0.8,0.2,1);z-index:900;pointer-events:none}
.preview-box:hover .thumb{opacity:1;visibility:visible;transform:translateY(-50%) translateX(15px)}
.disk-container{max-width:1000px;background:#1a1a1a;padding:15px;border-radius:8px;border:1px solid #333;margin:20px 0;box-sizing:border-box}
.disk-label{font-size:14px;color:#aaa;margin-bottom:8px;display:flex;justify-content:space-between;align-items:center;} 
.disk-label span{color:#fff;font-weight:bold}
.disk-bar-bg{width:100%;height:10px;background:#111;border-radius:5px;overflow:hidden}
.disk-bar-fill{height:100%;width:0%;background:#4facfe;transition:width 0.5s ease, background 0.3s ease}
.schedule-text{color:#aaa !important; font-size:12px; font-weight:normal !important; margin-left:8px;}
</style></head><body>

<h2>🎥 直播錄影檔案庫 <span id="liveBadge" class="offline-badge">⚪ 未開播</span></h2>
<div class="disk-container">
    <div class="disk-label"><span>💾 伺服器磁碟空間</span><span id="diskText">計算中...</span></div>
    <div class="disk-bar-bg"><div id="diskBarFill" class="disk-bar-fill"></div></div>
    
    <div class="disk-label" style="margin-top:15px; border-top:1px solid #333; padding-top:15px;">
        <span>📡 雷達狀態 <span class="schedule-text">(排程: __PROBE_START__ ~ __PROBE_END__)</span></span>
        <span id="probeText" style="color:#ffc107;">連線中...</span>
    </div>
</div>
<table id="vidTable"><tr><th style="width:60px;text-align:center;">預覽</th><th>檔名</th><th>大小</th><th>錄影時間</th></tr>
{VIDEO_ROWS}
</table>

<script>
setInterval(function(){
    fetch('/api/latest_size').then(r => r.text()).then(txt => {
        if(!txt || txt.includes("ERROR")) return;
        let parts = txt.split('|');
        
        if(parts.length >= 5) {
            let diskPct = parseFloat(parts[4]);
            document.getElementById("diskText").innerText = parts[3] + " (" + parts[4] + "%)";
            let bar = document.getElementById("diskBarFill");
            bar.style.width = diskPct + "%";
            bar.style.background = diskPct > 90 ? "#dc3545" : "#4facfe";
        }
        
        if(parts.length >= 6) {
            let badge = document.getElementById("liveBadge");
            if(parts[5] === "1") { badge.className = "live-badge"; badge.innerText = "🔴 錄影中"; } 
            else { badge.className = "offline-badge"; badge.innerText = "⚪ 未開播"; }
        }
        
        if(parts.length >= 7) {
            document.getElementById("probeText").innerText = parts[6];
        }
        
        if(parts[0] === "NONE") return;
        
        let table = document.getElementById("vidTable");
        if(table && table.rows.length > 1) {
            let firstRow = table.rows[1];
            if(firstRow.cells[1].innerText.includes(parts[0])) {
                firstRow.cells[2].innerHTML = parts[1];
                firstRow.cells[3].innerHTML = parts[2];
            } else { location.reload(); }
        }
    });
}, 1000);

function openPlayer(filename) {
    fetch('/api/play/' + encodeURIComponent(filename))
        .then(response => {
            if(!response.ok) alert("無法播放：找不到檔案，或請檢查系統圖形介面權限。");
        });
}
</script></body></html>
"""
# ============================================

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/api/play/'):
            filename = os.path.basename(urllib.parse.unquote(self.path[10:]))
            if os.path.exists(filename) and filename.endswith('.ts'):
                my_env = os.environ.copy()
                if 'DISPLAY' not in my_env: my_env['DISPLAY'] = ':0'
                if 'WAYLAND_DISPLAY' not in my_env and my_env.get('XDG_SESSION_TYPE') == 'wayland':
                    my_env['WAYLAND_DISPLAY'] = 'wayland-0'
                try:
                    subprocess.Popen(['mpv', filename], env=my_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except Exception: pass
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
            else: self.send_error(404)
            return

        if self.path == '/api/latest_size':
            self.send_response(200)
            self.send_header("Content-type", "text/plain; charset=utf-8")
            self.end_headers()
            try:
                is_live = "0"
                ps_ffmpeg = subprocess.run(['pgrep', '-f', 'ffmpeg.*mpegts'], stdout=subprocess.PIPE)
                if ps_ffmpeg.returncode == 0: is_live = "1"

                probe_status = "⚪ 未知狀態"
                try:
                    if is_live == "1":
                        probe_status = "🟢 已交接錄影 (哨兵休眠)"
                    else:
                        ps_probe = subprocess.run(['pgrep', '-f', '[p]robe.sh'], stdout=subprocess.PIPE, text=True)
                        if ps_probe.stdout.strip():
                            probe_pid = ps_probe.stdout.strip().split()[0]
                            ps_child = subprocess.run(['pgrep', '-P', probe_pid], stdout=subprocess.PIPE, text=True)
                            
                            if ps_child.stdout.strip():
                                child_pid = ps_child.stdout.strip().split()[0]
                                ps_comm = subprocess.run(['ps', '-p', child_pid, '-o', 'comm='], stdout=subprocess.PIPE, text=True)
                                child_comm = ps_comm.stdout.strip()
                                
                                if child_comm == 'streamlink':
                                    probe_status = "🟣 發送請求中 (檢測開播...)"
                                elif child_comm == 'sleep':
                                    ps_args = subprocess.run(['ps', '-p', child_pid, '-o', 'args='], stdout=subprocess.PIPE, text=True)
                                    sleep_val = int(ps_args.stdout.strip().split()[1])
                                    
                                    ps_etime = subprocess.run(['ps', '-p', child_pid, '-o', 'etime='], stdout=subprocess.PIPE, text=True)
                                    etime_str = ps_etime.stdout.strip()
                                    elapsed = 0
                                    if etime_str:
                                        for pt in etime_str.replace('-', ':').split(':'):
                                            elapsed = elapsed * 60 + int(pt)
                                            
                                    remain = max(0, sleep_val - elapsed)
                                    
                                    if sleep_val >= 300:
                                        probe_status = f"💤 深度休眠 (倒數 {remain} 秒後醒來)"
                                    else:
                                        probe_status = f"🟡 刺探待命中 (倒數 {remain} 秒後探測)"
                                else:
                                    probe_status = "🔄 資料處理中..."
                            else:
                                probe_status = "🔄 資料處理中..."
                        else:
                            probe_status = "❌ 雷達已停止"
                except Exception:
                    probe_status = "⚠️ 狀態讀取失敗"

                disk = shutil.disk_usage('.')
                d_used, d_total = disk.used / (1024**3), disk.total / (1024**3)
                d_pct = (disk.used / disk.total) * 100
                disk_info = f"{d_used:.2f} GB / {d_total:.2f} GB|{d_pct:.1f}"

                files = [f for f in os.listdir('.') if f.endswith('.ts')]
                if not files:
                    self.wfile.write(f"NONE|0|0|{disk_info}|{is_live}|{probe_status}".encode('utf-8'))
                    return
                
                latest_file = max(files, key=os.path.getmtime)
                size = os.path.getsize(latest_file)
                mtime_str = datetime.fromtimestamp(os.path.getmtime(latest_file)).strftime('%Y-%m-%d %H:%M:%S')
                size_str = f"<b>{size/1024**3:.2f} GB</b>" if size > 1024**3 else f"{size/1024**2:.2f} MB"
                
                # 修復了這裡的編碼問題
                self.wfile.write(f"{latest_file}|{size_str}|{mtime_str}|{disk_info}|{is_live}|{probe_status}".encode('utf-8'))
            except Exception:
                # 修復了這裡的編碼問題
                self.wfile.write("ERROR|0|0|0|0|0|錯誤".encode('utf-8'))
            return
            
        if self.path.startswith('/thumb/'):
            filename = urllib.parse.unquote(self.path[7:])
            if not filename.endswith('.ts') or not os.path.exists(filename):
                self.send_error(404)
                return
            thumb_name = f".{filename}.jpg"
            if not os.path.exists(thumb_name):
                cmd = ['ffmpeg', '-y', '-ss', '00:00:05', '-i', filename, '-vframes', '1', '-s', '256x144', thumb_name]
                try: subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                except Exception: pass
            if os.path.exists(thumb_name):
                self.send_response(200)
                self.send_header("Content-type", "image/jpeg")
                self.end_headers()
                with open(thumb_name, 'rb') as f: self.wfile.write(f.read())
            else: self.send_error(404)
            return

        return super().do_GET()

    def list_directory(self, path):
        try: files = os.listdir(path)
        except OSError:
            self.send_error(404, "No permission")
            return None
            
        files.sort(key=lambda a: os.path.getmtime(os.path.join(path, a)), reverse=True)
        rows_html = ""
        for name in files:
            if name.startswith(".") or name == "web_server.py" or name.endswith(".log"): continue
            fullname = os.path.join(path, name)
            displayname = name + "/" if os.path.isdir(fullname) else name
            size = os.stat(fullname).st_size
            if os.path.isdir(fullname): size_str = "-"
            elif size > 1024**3: size_str = f"<b>{size/1024**3:.2f} GB</b>"
            else: size_str = f"{size/1024**2:.2f} MB"
            
            mtime = datetime.fromtimestamp(os.stat(fullname).st_mtime).strftime('%Y-%m-%d %H:%M:%S')
            
            safe_name = name.replace("'", "\\'")
            onclick_attr = f"onclick=\"openPlayer('{safe_name}')\""
            
            thumb_html = f'<div class="preview-box" {onclick_attr}><span class="icon">▶️</span><img src="/thumb/{urllib.parse.quote(name)}" class="thumb" loading="lazy" alt="preview"></div>'
            rows_html += f'<tr><td style="text-align:center;">{thumb_html}</td><td><a href="javascript:void(0);" {onclick_attr}>{displayname}</a></td><td>{size_str}</td><td>{mtime}</td></tr>\n'

        final_html = HTML_TEMPLATE.replace('{VIDEO_ROWS}', rows_html)
        encoded = final_html.encode('utf-8')
        self.send_response(200)
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
        return None

port = int(sys.argv[1]) if len(sys.argv) > 1 else 36591
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", port), Handler) as httpd:
    httpd.serve_forever()
EOF

            sed -i "s/__PROBE_START__/${PROBE_START:-未設定}/g" "$SAVE_DIR/web_server.py"
            sed -i "s/__PROBE_END__/${PROBE_END:-未設定}/g" "$SAVE_DIR/web_server.py"

            cd "$SAVE_DIR" || exit
            nohup python3 web_server.py "$WEB_PORT" > web_server_error.log 2>&1 &
            
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
                            if [ "$SLEEP_VAL" -ge 300 ]; then PROBE_STATE="\e[33m[深度休眠: 非排程時段 (倒數 ${REMAIN} 秒後醒來)]\e[0m"
                            else PROBE_STATE="\e[36m[刺探待命中: 倒數 ${REMAIN} 秒後發起偵測]\e[0m"
                            fi
                        else PROBE_STATE="\e[90m[資料處理中...]\e[0m"; fi
                    else PROBE_STATE="\e[90m[資料處理中...]\e[0m"; fi
                fi
            fi
            
            echo -e " 📡 雷達刺探 (probe):   $PROBE_STATE"
            if pgrep -f "$(basename "$CORE_SCRIPT")" > /dev/null; then echo -e " 🎥 核心引擎 (record):  \e[32m[錄影中 RUNNING]\e[0m"
            else echo -e " 🎥 核心引擎 (record):  \e[90m[待命/未開播 SLEEPING]\e[0m"; fi
            
            if pgrep -f "web_server.py" > /dev/null; then echo -e " 🌐 網頁伺服器 (Web):   \e[32m[運行中: Port $WEB_PORT]\e[0m"
            else echo -e " 🌐 網頁伺服器 (Web):   \e[31m[未啟動]\e[0m"; fi
            
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
                status_icon="\e[32m✔\e[0m"
                [ "$speed" -le 0 ] && status_icon="\e[31m✘\e[0m"
                file=$(lsof -p "$pid" 2>/dev/null | awk '$9 ~ /\.ts$/ {print $9}' | head -n 1)
                fsize_val="0.00"
                [ -f "$file" ] && fsize_val=$(ls -nl "$file" | awk '{b=$5; if(b>=1048576) printf "%.2f", b/1048576; else printf "%.2f", b/1024}')
                printf "%-10s | %-8s | %-12b  %-12s | %-10s | %s\n" "$(date +%H:%M:%S)" "$pid" "$status_icon" "$speed" "$fsize_val" "$file"
                HAS_RECORD=1
            done
            [ "$HAS_RECORD" -eq 0 ] && echo -e "  \e[90m(目前無正在寫入的錄影進程)\e[0m"
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
