#!/bin/bash
# ==============================================================================
# Suckless Core Engine (record.sh) - 純粹核心版
# ==============================================================================

# 【一樣改成自動感應地址】
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$SCRIPT_DIR/venv/bin:$PATH"

TARGET_URL="$1"

if [ -z "$TARGET_URL" ]; then
    echo "[CORE] 錯誤：未提供目標網址！"
    exit 1
fi

PREFIX="${TARGET_URL##*@}"
PREFIX="${PREFIX%%/live*}"
SAVE_DIR="${HOME}/tk_suckless/${PREFIX}"
mkdir -p "$SAVE_DIR"

log() { echo "[CORE] [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log "Engine initialized. Target: @$PREFIX"

START_TIME=$(date +%s)
TS_FILE="$SAVE_DIR/$(date +%Y%m%d-%H%M%S).ts"
log "Recording started: ${TS_FILE##*/}"

env LD_PRELOAD="/usr/lib/libjemalloc.so" \
    taskset -c 0 \
    ionice -c 2 -n 0 \
    streamlink "$TARGET_URL" "hd,ld,best" \
    --ringbuffer-size 512M \
    --stream-segment-threads 1 \
    --stream-timeout 60 \
    --http-header "Referer=https://www.tiktok.com/" \
    --http-header "Origin=https://www.tiktok.com" \
    --http-header "User-Agent=Mozilla/5.0 (X11; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0" \
    -O 2>/dev/null | ffmpeg -y -i pipe:0 -c copy -f mpegts "$TS_FILE" > /dev/null 2>&1 &

STREAM_PID=$!
wait $STREAM_PID

LIFESPAN=$(( $(date +%s) - START_TIME ))
if [ ! -s "$TS_FILE" ] || [ "$LIFESPAN" -lt 5 ]; then
    rm -f "$TS_FILE"
    log "Junk removed (${LIFESPAN}s). Stream ended."
else
    log "Segment saved (${LIFESPAN}s). Stream ended."
fi

exit 0
