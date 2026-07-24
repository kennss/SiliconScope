# SiliconScope

[English](README.md) · [Deutsch](README.de.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md)

[![Website](https://img.shields.io/badge/website-siliconscope.calidalab.ai-5c9efa)](https://siliconscope.calidalab.ai)
[![Release](https://img.shields.io/github/v/release/kennss/SiliconScope?color=2b9348)](https://github.com/kennss/SiliconScope/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kennss/SiliconScope/total?color=2b9348)](https://github.com/kennss/SiliconScope/releases)
[![License: MIT](https://img.shields.io/github/license/kennss/SiliconScope)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-111)

[![#2 Swift Repository Of The Day](https://trendshift.io/api/badge/trendshift/repositories/57307/daily?language=Swift)](https://trendshift.io/repositories/57307)

**無需 sudo 的 Apple Silicon 系統監視器** —— 既是原生 SwiftUI 儀表板，**也是**完整的選單列套件，
以一級公民的方式追蹤 Activity Monitor 與終端類監視器看不到的 **ANE（Neural Engine）**、
**Media Engine** 與**記憶體頻寬**。

它源於一個想法：*親眼看看*裝置端 AI 與媒體負載如何驅動 Apple Silicon 的各個加速器 —— 後來成長為
一款能取代 iStat Menus 的日常監視器。

**4.0 新功能 —— 它現在也看著你*其他*的機器。** 無頭的 Mac mini、桌子底下的 Linux GPU 主機、
租來的雲端執行個體 —— 在那邊跑一個小小的 agent，它就會透過加密且已配對的連線加入同一個儀表板。
遠端 Mac 依然是完整待遇，**連 Neural Engine 都在**。

*已獲 [AAPL Ch.](https://applech2.com/archives/20260620-siliconscope-apple-silicon-mac-system-monitor.html)（日本）與 [ifun.de](https://www.ifun.de/siliconscope-ueberwacht-apple-ki-neural-engine-und-speicher-in-echtzeit-282222/)（德國）報導。*

![本地 LLM 負載下的 SiliconScope 儀表板](docs/img/dashboard.png)

*整台機器一目了然 —— AI 工作負載瓶頸分類器、E/P 核疊加趨勢、GPU / GPU 記憶體 / ANE / Media、對照 M1 Max 400 GB/s 上限測量的記憶體、每核溫度、功耗與即時程序。底部的工具列就是 **Replay**（3.0 新增）：每一項指標都會被記錄，因此你可以像 DVR 一樣回放、拖曳整段工作階段。*

### 選單列 —— 每項指標，iStat 風格

可將任意卡片釘選為獨立的選單列項目 —— **CPU · GPU · 記憶體 · 網路 · SSD · 感測器 · 電池** —— 每項都有即時圖示與豐富的下拉選單。全程無需 sudo。

![依指標劃分的選單列套件](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU / Media / Neural 下拉選單">
  <img src="docs/img/menubar-sensors.png" width="250" alt="每核溫度">
  <img src="docs/img/menubar-cockpit.png" width="250" alt="合併的 SS 駕駛艙 —— 工作負載、全部引擎、趨勢、置頂程序">
</p>

*資訊最豐富的下拉面板。**GPU / Media / Neural** —— 以即時儀表 + 4 線 60 秒趨勢顯示 GPU、GPU 記憶體、ANE 與 Media。**感測器** —— 各單元溫度，來自真實的 **E-Core / P-Core / GPU / Memory** 感測器（依晶片世代精選的 SMC 鍵，M1–M5，其餘後備至 HID）。**SS 駕駛艙** —— 一個下拉看整機：工作負載判定、每個引擎、60 秒趨勢與置頂程序。*

![測量本地模型的速度與能效](docs/img/benchmark.png)

*隨選基準測試：「Measure tok/s」執行一次短生成，測量模型的解碼速度與能效 —— **tokens/sec · tokens/Wh** —— 並依模型儲存。*

> 📊 **在你的 Mac 上測過 tok/s 嗎？** [發到 Discussions 吧](https://github.com/kennss/SiliconScope/discussions/5) —— 一張群眾外包的依晶片對照表，能幫助其他人挑選合適的硬體。

## 4.0 新功能

### 🛰 Fleet —— 你的其他機器，在同一個儀表板裡

在遠端主機上跑一個 agent，它就會出現在 **This Mac** 旁邊的 **Devices** 側邊欄。
同一個區域網路內的機器會透過 mDNS 自動探索 —— 不必設定 IP。

![Fleet 總覽 —— 所有機器在一個畫面裡](docs/img/fleet-overview.png)

*三台機器一目了然。每張圖磚把 **GPU + VRAM** 與 **CPU + RAM** 疊在同一個座標軸上，Apple Silicon 還會
再加上 **ANE + 記憶體頻寬**；指標名稱依線條顏色上色，所以不需要圖例。圖中 MacBook Pro 位於
**GPU 64% / 10 GB/s**，Air 閒置，Ubuntu 主機佔著 **18.7 GB 顯示記憶體**，並常駐兩個 Ollama 模型。
This Mac 永遠是第一張圖磚。*

- **遠端 Mac 會用與本機完全相同的儀表板繪製** —— E/P 核心、GPU、**ANE**、Media、記憶體頻寬、功耗、
  風扇。就我所知，沒有其他工具能顯示**遠端 Mac 的 Neural Engine**。
- **Linux/NVIDIA 主機拿到的是以 GPU 為中心的檢視** —— 使用率、顯示記憶體、相對顯示卡上限的功耗、
  溫度、誰佔著顯示記憶體，以及已載入的 **Ollama** 模型。它不會假裝 3090 有 E 核心。

![遠端 Mac 使用完整的本機儀表板，含 ANE](docs/img/fleet-remote-mac.png)

*從另一台 Mac 看過去的無頭 M1 Air：**4E+4P** 核心、GPU/Media/**ANE 估計值**，以及真實的記憶體組成
（**wired 1.0 / active 2.7 / compressed 0.5 GB**，壓力 19%）—— 感測器不會捏造風扇讀數，而是老實回報
**fanless**。協定裡填不出來的卡片會被省略，而不是造假。*

![顯示顯示記憶體佔用行程與 Ollama 模型的 Linux GPU 主機](docs/img/fleet-linux.png)

*同一個 App，不同類型的機器。一台 RTX 3090 主機：相對顯示卡上限的 **35 / 390 W**、
**18.7 / 24 GB 顯示記憶體**、是誰佔著它（一個 Python venv 佔 **17.9 GB**），以及磁碟上的 Ollama 模型。
沒有 E 核心，也沒有 ANE —— 因為它本來就沒有。*

每一條連線都經過 **TLS 加密並以權杖認證**，而且檢視端會在首次連線時釘選 agent 的憑證（TOFU），
因此換過金鑰或偽裝的 agent 會被拒絕，而不是被悄悄信任。

![維持原樣的 This Mac，以及新增的 Devices 側邊欄](docs/img/fleet-sidebar.png)

*只用一台 Mac 的方式完全沒有改變 —— 還是同一個儀表板，只是多了一個可收合的 **Devices** 側邊欄。
收起來就跟 3.x 一模一樣。*

#### 安裝 agent

所有平台同一個 URL —— 在 Linux 上裝成 systemd 服務，在 macOS 上裝成 LaunchAgent：

```sh
curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh | sh
```

Mac 端的 agent **不需要 sudo**，所以透過 `ssh` 執行也能一路跑完、不會卡住。每個安裝指令碼最後都會
印出一行 `sscope://pair…` 連結 —— 貼進 App 的 **Add machine…**，新增與配對就一次完成。

如果是你自己在用的 Mac，連 agent 都不需要：**設定 → Share this Mac**。

> **無頭 Mac？** 請先開啟**系統設定 → 一般 → 共享 → 遠端登入**，否則你無法在上面安裝任何東西。
> **不在同一個區域網路**（Tailscale、VPN、雲端）？mDNS 到不了，請在 **Add machine…** 裡以位址新增；
> 比起把連接埠曝露到公開網際網路，更建議走 Tailscale 或 SSH 通道。

**移除 agent** —— 在那台機器上帶 `--uninstall` 執行安裝指令碼（`curl -fsSL …/install-agent.sh | sh -s -- --uninstall`，或本機的 `sh install-agent.sh --uninstall`）。它會停止服務並刪除二進位、權杖、憑證與鑰匙圈。接著在檢視端 Mac 的 Fleet 側邊欄右鍵該機器 → **Forget pairing**。

## 3.0 新功能

### 🧠 程序檢查器 —— 逐程序指標，無需 sudo

點擊任一程序即可開啟檢查器。它能顯示活動監視器看不到的內容：**CPU（P/E 拆分）· IPC ·
逐程序功耗（W）· 記憶體 · 磁碟** —— 每項都帶即時迷你圖 —— 以及別處無法逐程序查看的那項訊號：
**神經引擎記憶體**。一眼看清哪個 App 正在用 ANE、佔用了多少。

![程序檢查器 —— 逐程序的 CPU、IPC、功耗與神經引擎記憶體](docs/img/inspector.png)

*一款裝置端轉寫 App 正在即時執行（右）：65% CPU、**2.43 IPC**、**0.64 W**，以及 **762 MB 神經引擎記憶體**
—— 其他監視器從不逐程序顯示的 ANE 佔用。對於 macOS 只按系統整體回報的加速器（GPU / ANE 功耗 /
Media / 頻寬），都會如實標註 —— 絕不偽造逐程序數字。*

### ⏺ 錄製與回放 —— 你 Mac 指標的 DVR

按下 **Record**，SiliconScope 會把每一項指標 —— CPU、GPU、ANE、Media、頻寬、功耗、感測器、程序
—— 串流寫入一個精簡的 `.ssrec` 檔案。隨後可用 **播放 / 暫停 / 拖曳 / 倍速** 回放整個儀表板，
抓住那些等你回頭看時早已消失的尖峰。一切都留在你的 Mac 上；匯出錄製即可分享或日後比對。

![Replay 工具列 —— 播放 / 暫停 / 單步、拖曳、倍速與 Save](docs/img/replaybar.png)

*Replay 工具列：播放 / 暫停 / 單步、拖曳時間軸、調整倍速，以及儲存錄製（Save）。*

## 為什麼做它

我是在開發裝置端 AI 影片播放器 **[Spectalo](https://spectalo.calidalab.ai/zh/)** 時做出 SiliconScope 的。為了看清它究竟如何驅動晶片，
我常常同時開著兩個監視器 —— 可兩個都不合用：

- **asitop / NeoAsitop** 有晶片級數字，但 TUI 看起來粗糙、資訊也單薄。
- **btop** 美觀且資訊密集，卻恰恰看不到我需要的 —— **ANE（Neural Engine）、Media Engine
  與記憶體頻寬。**

把兩者並排開著既彆扭又浪費螢幕。我本想 fork NeoAsitop 和 btop 來補缺口 —— 後來決定乾脆好好做一個：
**一個原生、好看的 GUI**，既呈現 Apple Silicon 特有的訊號，又能讓一般人（而不只是終端老手）真正讀懂。

於是我做了出來。

而當它真正存在之後，我意識到終於可以告別用了多年的日常監視器 **iStat Menus** 了。這正是 **2.0** 的
意義所在 —— 在這個版本裡，SiliconScope 長出了取代 iStat 所需的完整選單列套件、各單元感測器與電池健康。

## 安裝

**Homebrew** —— 最簡單的方式：

```sh
brew install --cask siliconscope
```

或下載 DMG：**[⬇ 下載最新 DMG](https://github.com/kennss/SiliconScope/releases/latest)**，然後：

1. 開啟下載的 `SiliconScope-*.dmg`
2. 將 **SiliconScope** 拖曳至**應用程式**
3. 啟動它

已以 Developer ID 簽署並經 **Apple 公證**，開啟時不會出現 Gatekeeper 警告。需要 **macOS 14+ ·
Apple Silicon**。之後它會**自動更新**（Sparkle）—— 這是你最後一次手動下載 DMG。

想自行建置？請參閱英文 README 的 [Build & run](README.md#build--run)。

## 功能亮點

- **程序檢查器** *(3.0 新增)* —— 聚焦單一程序，查看 CPU（P/E 拆分）、IPC、逐程序**功耗（W）**、
  記憶體、磁碟與**神經引擎記憶體** —— 全部無需 sudo
- **錄製與回放** *(3.0 新增)* —— 把每一項指標錄入 `.ssrec` 檔案，並以**播放 / 暫停 / 拖曳 / 倍速**
  回放儀表板，就像 DVR
- **AI Workload 檢視** —— 瓶頸分類器（*bandwidth-bound* / *compute-bound* / *thermal-throttled* /
  *memory-pressured*），對照各晶片的記憶體頻寬規格上限 —— 回答「此刻是什麼在拖慢我的本地 LLM？」
- **E 核 / P 核區分** —— 各叢集使用率 + 真實 DVFS 頻率
- **GPU** —— 使用率、功耗、頻率
- **ANE & Media Engine** —— Neural Engine 功耗與媒體編解碼頻寬（差異化所在）
- **記憶體頻寬** —— CPU / GPU / Media / 合計 GB/s（本地 LLM 的瓶頸訊號）
- **記憶體** —— Wired / Active / Compressed / Free 堆疊長條 + macOS **記憶體壓力**警示
- **網路** ↑/↓ 與**磁碟**讀寫 + 剩餘空間，並附即時圖表
- **各單元溫度** —— 透過依世代精選的 SMC 鍵讀取的真實 **E-Core / P-Core / GPU / Memory**
  感測器（M1–M5，其餘後備至 HID）、風扇轉速、熱壓力，以及 **GPU 降頻偵測**（壓力下頻率是否被壓到
  其滾動峰值之下）
- **電池** —— 充電狀態、**健康度 %、循環次數、狀態**（AppleSmartBattery）
- **功耗** —— 依電源域的 CPU / GPU / ANE / DRAM / SoC，以及電池
- **程序** —— 排序、篩選、結束，並**點擊以檢查**（卡片內捲動）
- **依指標的選單列項目** —— 將 CPU / GPU / 記憶體 / 網路 / SSD / 感測器 / 電池各自釘選為獨立的
  選單列圖示 + 下拉選單（外加整合的「SS」駕駛艙圖示）
- **自動更新** —— 內建 Sparkle 更新程式，選單中的「Check for Updates…」
- **無需 `sudo`。**

## 相關專案

**[Spectalo](https://spectalo.calidalab.ai/zh/)** —— 一款具備裝置端 AI 字幕與翻譯（Whisper + Apple
Intelligence）的精美影片播放器，同樣出自 Calida Lab。SiliconScope 正是在開發它的過程中誕生的。目前於
TestFlight 免費公測 —— 秉持同樣的理念：資料絕不離開你的裝置。

<a href="https://spectalo.calidalab.ai/zh/"><img src="docs/img/spectalo-library.jpg" width="520" alt="Spectalo —— 裝置端 AI 影片播放器"></a>

---

👉 建置步驟、無需 sudo 的實作原理（IOReport / SMC / HID）以及工程深入剖析，詳見
**[英文 README](README.md)**。


### 來自 Calida Lab 的更多產品

隱私優先、裝置端執行的軟體（主要面向 Apple Silicon）:

- **[SpectaLing](https://spectaling.calidalab.ai/)** — 裝置端轉錄 + 即時翻譯與同步口譯（Mac/iPad）。注重隱私的 MacWhisper 替代方案。
- **[SpectArk](https://spectark.calidalab.ai/)** — macOS 版本化增量備份，檔案一變更即刻保存。
- **[SnowChat](https://snowchat.calidalab.ai/)** — 基於自研 Signal 協定實作的端對端加密即時通訊。
- **[SnowClaw](https://snowclaw.calidalab.ai/)** — 隱私保護型代理 AI 的參考架構（工作論文）。

**→ [www.calidalab.ai](https://www.calidalab.ai/zh/)** · [@kennss](https://github.com/kennss)


歡迎提出翻譯改進 —— 請提交 PR。
