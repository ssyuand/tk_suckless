#!/bin/bash
# ==========================================
# Probe Scanner (probe.sh) - Suckless 終極智慧對齊版
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

# 讀取 config 設定，若沒寫則給予防呆預設值
PROBE_SLEEP_DEEP=${PROBE_SLEEP_DEEP:-3600}
PROBE_INTERVAL=${PROBE_INTERVAL:-60}

PREFIX="${TARGET_URL##*@}"
PREFIX="${PREFIX%%/live*}"
SAVE_DIR="${HOME}/tk_suckless/${PREFIX}"
mkdir -p "$SAVE_DIR"

log() { echo "[PROBE] [$(date +'%H:%M:%S')] $1"; }
log "背景雷達啟動，目標: @$PREFIX | 戰備時段: $PROBE_START ~ $PROBE_END"

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
    # 1. 非排程時段：智慧型動態休眠 (精確對齊排程，防止 19:00 或 19:19 醒來時睡過頭)
    if ! is_in_time_window; then
        # 取得當前與排程開始的 Linux 系統秒數 (Epoch Time)
        curr_seconds=$(date +%s)
        start_seconds=$(date -d "$PROBE_START" +%s 2>/dev/null || date -f - +%s <<< "$(date +%Y-%m-%d) $PROBE_START")
        
        # 【智慧修正】如果算出來的排程秒數比現在還早，代表那是「明天」的排程，加上一天的秒數
        if [ "$start_seconds" -le "$curr_seconds" ]; then
            start_seconds=$(( start_seconds + 86400 ))
        fi
        
        # 計算距離開播排程「精確還剩幾秒」
        time_to_start=$(( start_seconds - curr_seconds ))
        
        # 【核心決策】如果距離排程開始的時間，已經小於預設的深度休眠時間（例如小於 3600 秒）
        if [ "$time_to_start" -lt "$PROBE_SLEEP_DEEP" ]; then
            log "⏳ 接近戰備時段！精確對齊排程，倒數 ${time_to_start} 秒後準點醒來..."
            sleep "$time_to_start"
        else
            # 離排程還很久（大於 1 小時），安心按照原訂計畫深度睡眠
            log "💤 非戰備時段，進入深度休眠 ${PROBE_SLEEP_DEEP} 秒..."
            sleep "$PROBE_SLEEP_DEEP"
        fi
        continue
    fi

    # 2. 已交接給核心：雷達退居二線，避免重複觸發
    if pgrep -f "record.sh.*$PREFIX" > /dev/null; then
        sleep 60
        continue
    fi

    # 3. 戰備時段：拔槍探測
    if streamlink --json "$TARGET_URL" 2>/dev/null | grep -q "best"; then
        log "⚠️ 發現 @$PREFIX 正在直播！派遣錄影核心..."
        nohup bash ./record.sh "$TARGET_URL" >> "$SAVE_DIR/${PREFIX}_record.log" 2>&1 &
        sleep 30
    else
        # 加上亂數避免被抓到規律 (防 Bot 機制)
        WAIT_TIME=$(( PROBE_INTERVAL + RANDOM % 21 ))
        log "目標未開播，等待 ${WAIT_TIME} 秒..."
        sleep "$WAIT_TIME"
    fi
done
