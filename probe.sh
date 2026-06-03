#!/bin/bash
# ==========================================
# Probe Scanner (probe.sh) - Suckless 純淨版
# ==========================================

# 【這就是變聰明的地方】自動抓取當前資料夾，永遠找旁邊的 venv 工具箱！
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$SCRIPT_DIR/venv/bin:$PATH"

if [ -f "./config.env" ]; then
    source ./config.env
else
    echo "[PROBE] 錯誤：找不到 config.env 設定檔！"
    exit 1
fi

PREFIX="${TARGET_URL##*@}"
PREFIX="${PREFIX%%/live*}"
SAVE_DIR="${HOME}/tk_suckless/${PREFIX}"
mkdir -p "$SAVE_DIR"

log() { echo "[PROBE] [$(date +'%H:%M:%S')] $1"; }
log "背景雷達啟動，目標: @$PREFIX | 時段: $PROBE_START ~ $PROBE_END"

is_in_time_window() {
    local curr=$(date +%H%M)
    local start_t=$(echo "$PROBE_START" | tr -d ':')
    local end_t=$(echo "$PROBE_END" | tr -d ':')
    
    if [ "$start_t" -eq "$end_t" ]; then return 0; fi

    if [ "$start_t" -lt "$end_t" ]; then
        if [ "$curr" -ge "$start_t" ] && [ "$curr" -le "$end_t" ]; then return 0; else return 1; fi
    else
        if [ "$curr" -ge "$start_t" ] || [ "$curr" -le "$end_t" ]; then return 0; else return 1; fi
    fi
}

while true; do
    if ! is_in_time_window; then
        sleep 300
        continue
    fi

    if pgrep -f "record.sh.*$PREFIX" > /dev/null; then
        sleep 60
        continue
    fi

    if streamlink --json "$TARGET_URL" 2>/dev/null | grep -q "best"; then
        log "⚠️ 發現 @$PREFIX 正在直播！派遣錄影核心..."
        nohup bash ./record.sh "$TARGET_URL" >> "$SAVE_DIR/${PREFIX}_record.log" 2>&1 &
        sleep 30
    else
        WAIT_TIME=$(( PROBE_INTERVAL + RANDOM % 21 ))
        log "目標未開播，等待 ${WAIT_TIME} 秒..."
        sleep $WAIT_TIME
    fi
done
