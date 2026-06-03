# 🎥 TikTok Live Recorder - Suckless Edition (個人專屬備忘錄)

這是我為了實現 24/7 全天候監控 TikTok 直播，並將系統資源耗損降到最低，基於 **Unix / Suckless 哲學** 打造的微服務錄影架構。

**核心開發準則：** 不造多餘的輪子、不用肥大的框架、不寫無謂的硬碟 I/O，一切向 Linux Kernel 借力。

---

## 🧠 核心原理與實作細節 (How It Actually Works)
這裡記錄了這套系統最精華的技術細節，以免未來忘記當初為什麼這樣寫。

### 1. 零 I/O 狀態監控 (Process Tree Introspection)
**問題：** 雷達 (`probe.sh`) 在背景休眠倒數時，監控面板 (`status`) 怎麼知道它還要睡幾秒？如果把剩餘秒數寫進 `.txt`，每秒讀寫會大幅損耗 SSD。
**實作：** * 利用 Linux 原生的「行程樹 (Process Tree)」概念。當 Bash 執行 `sleep 120` 時，實際上是 fork 出了一個子進程。
* 面板透過 `pgrep -P <probe的PID>` 找到那個 `sleep` 子進程。
* 利用 `ps -o args=` 抓出它原本打算睡幾秒 (120)，再用 `ps -o etimes=` 去問系統核心「這個進程已經活了幾秒？」。
* 兩者相減，完美得到倒數計時，**全程 0 硬碟讀寫**。

### 2. 即時 I/O 速度計算 (ProcFS)
**問題：** 如何在面板顯示 FFmpeg 當下的寫入速度？
**實作：**
* 不依賴外部監控工具，直接讀取 Linux 內核即時映射的虛擬檔案系統 `/proc/$pid/io`。
* 面板每秒抓取一次 `write_bytes` 的數值，與前一秒的數值相減並除以 1024，精準算出當下的 KiB/s 寫入速度。

### 3. 底層效能壓榨 (Performance Tuning)
為了確保長駐錄影不卡死伺服器，`record.sh` 在啟動 `streamlink` 與 `ffmpeg` 時下了猛藥：
* **`taskset -c 0`：** 將錄影進程死死綁定在 CPU 的第 0 號核心上，防止作業系統在多核心間頻繁切換 (Context Switching) 浪費效能。
* **`ionice -c 2 -n 0`：** 強制接管磁碟 I/O 排程，確保即使硬碟在忙其他事，錄影的寫入動作也能順暢執行，避免影片掉幀 (Drop frames)。
* **`LD_PRELOAD="/usr/lib/libjemalloc.so"`：** 替換掉系統預設的 glibc 記憶體分配器，改用 jemalloc，徹底解決長時間錄影可能造成的記憶體碎片化與外洩 (Memory Leak)。

### 4. 自動垃圾回收 (Garbage Collection)
**實作：** `record.sh` 啟動時記錄 `START_TIME=$(date +%s)`。當 `wait $STREAM_PID` 收到斷線訊號解除阻塞後，計算 `LIFESPAN`。如果主播只是閃退 (存活 < 5 秒) 或檔案大小為 0 (`! -s "$TS_FILE"`)，腳本會直接 `rm -f` 刪除該 `.ts` 檔，保持硬碟乾淨。

### 5. 網頁端免重整刷新 (Vanilla AJAX)
**問題：** 想在網頁看最新錄影檔變多大，但不想用 React/Vue 這種肥框架，也不想一直按 F5。
**實作：** * 在啟動時動態生成一個純 Python 的 `http.server`。
* 覆寫 `do_GET` 寫了一個極簡 API `/api/latest_size`，只回傳最新檔案的名稱與大小。
* 網頁前端塞入一段純 JavaScript 的 `setInterval`，每秒打一次 API 並只抽換 Table 裡面的那格 HTML (`innerHTML`)，實現極度輕量化的即時動態面板。

---

## 🏗️ 系統架構：三叉戟設計 (Trident)

為了避免一個腳本掛掉導致全網癱瘓，系統嚴格拆分為三個獨立組件：

1. **`config.env` (全域設定)：** 將目標網址 (`TARGET_URL`)、時段與 Port 抽離。主程式完全不可變 (Immutable)，以後換主播只要改這份檔案。
2. **`probe.sh` (雷達哨兵)：** 專職在外圍巡邏。包含跨夜時間判斷邏輯，以及**亂數微調 (Jitter)** 機制（基礎等待 + 0~20秒隨機亂數），防止規律請求被 TikTok 當成機器人 Ban IP。
3. **`record.sh` (錄影核心)：** 純粹的勞工。沒有迴圈，收到網址 ➔ 錄影 ➔ 結束清理 ➔ 關閉自己。
4. **`launcher.sh` (總機面板)：** 負責發送啟動與終止訊號，以及渲染終端機 UI。

---

## 🛠️ 快速操作手冊

**1. 啟動與修改設定**
```bash
# 1. 打造一個全新的工具箱 (建立新的 venv)
python3 -m venv venv

# 2. 打開工具箱
source venv/bin/activate

# 3. 把 streamlink 這個工具裝進去
pip install streamlink

# 4. 把工具箱關起來 (裝完就好了)
deactivate

## 核心指令
./launcher.sh start   # 啟動系統 (清空舊進程，將雷達與 Web 丟入背景)
./launcher.sh status  # 打開動態監控儀表板 (按 Ctrl+C 退出面板，不影響背景錄影)
./launcher.sh stop    # 優雅關閉 (發送 pkill 清空所有相關進程，不留殭屍)
./launcher.sh log     # 選擇查看不同組件的系統日誌
