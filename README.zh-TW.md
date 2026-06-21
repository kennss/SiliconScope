# SiliconScope

[English](README.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md)

[![Website](https://img.shields.io/badge/website-siliconscope.calidalab.ai-5c9efa)](https://siliconscope.calidalab.ai)
[![Release](https://img.shields.io/github/v/release/kennss/SiliconScope?color=2b9348)](https://github.com/kennss/SiliconScope/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kennss/SiliconScope/total?color=2b9348)](https://github.com/kennss/SiliconScope/releases)
[![License: MIT](https://img.shields.io/github/license/kennss/SiliconScope)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-111)

**無需 sudo 的 Apple Silicon 系統監視器** —— 既是原生 SwiftUI 儀表板，**也是**完整的選單列套件，
以一級公民的方式追蹤 Activity Monitor 與終端類監視器看不到的 **ANE（Neural Engine）**、
**Media Engine** 與**記憶體頻寬**。

它源於一個想法：*親眼看看*裝置端 AI 與媒體負載如何驅動 Apple Silicon 的各個加速器 —— 後來成長為
一款能取代 iStat Menus 的日常監視器。

![本地 LLM 負載下的 SiliconScope 儀表板](docs/img/dashboard.png)

*執行本地 LLM 時（LM Studio · Llama-3.1-8B，GPU 100%）：SiliconScope 標記出**熱降頻**（GPU 頻率被壓制在峰值的 −20%），將負載與 M1 Max 的 400 GB/s 上限對比測量，辨識執行環境與模型，並即時顯示每個引擎 —— GPU / GPU 記憶體 / ANE / Media 與 E/P 核的疊加趨勢、每核溫度、功耗與頻寬。*

### 選單列 —— 每項指標，iStat 風格

可將任意卡片釘選為獨立的選單列項目 —— **CPU · GPU · 記憶體 · 網路 · SSD · 感測器 · 電池** —— 每項都有即時圖示與豐富的下拉選單。全程無需 sudo。

![依指標劃分的選單列套件](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU / Media / Neural 下拉選單">
  <img src="docs/img/menubar-sensors.png" width="250" alt="每核溫度">
  <img src="docs/img/menubar-battery.png" width="250" alt="電池健康與功耗">
</p>

*左：**GPU / Media / Neural** —— 以即時儀表 + 4 線 60 秒趨勢顯示 GPU、GPU 記憶體、ANE 與 Media。中：各單元溫度 —— 真實的 **E-Core / P-Core / GPU / Memory** 感測器（依晶片世代精選的 SMC 鍵，M1–M5，其餘後備至 HID）。右：電池健康、循環次數、狀態、SoC 功耗細分，以及耗電較多的 App。*

![測量本地模型的速度與能效](docs/img/benchmark.png)

*隨選基準測試：「Measure tok/s」執行一次短生成，測量模型的解碼速度與能效 —— **tokens/sec · tokens/Wh** —— 並依模型儲存。*

> 📊 **在你的 Mac 上測過 tok/s 嗎？** [發到 Discussions 吧](https://github.com/kennss/SiliconScope/discussions/5) —— 一張群眾外包的依晶片對照表，能幫助其他人挑選合適的硬體。

## 為什麼做它

我是在開發裝置端 AI 影片播放器 **Spectalo** 時做出 SiliconScope 的。為了看清它究竟如何驅動晶片，
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

**[⬇ 下載最新 DMG](https://github.com/kennss/SiliconScope/releases/latest)**，然後：

1. 開啟下載的 `SiliconScope-*.dmg`
2. 將 **SiliconScope** 拖曳至**應用程式**
3. 啟動它

已以 Developer ID 簽署並經 **Apple 公證**，開啟時不會出現 Gatekeeper 警告。需要 **macOS 14+ ·
Apple Silicon**。之後它會**自動更新**（Sparkle）—— 這是你最後一次手動下載 DMG。

想自行建置？請參閱英文 README 的 [Build & run](README.md#build--run)。

## 功能亮點

- **AI Workload 檢視** —— 瓶頸分類器（*bandwidth-bound* / *compute-bound* / *thermal-throttled* /
  *memory-pressured*）搭配依晶片的 **「% of ceiling」** 頻寬計 —— 回答「此刻是什麼在拖慢我的本地 LLM？」
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
- **程序** —— 排序、篩選、結束（卡片內捲動）
- **依指標的選單列項目** —— 將 CPU / GPU / 記憶體 / 網路 / SSD / 感測器 / 電池各自釘選為獨立的
  選單列圖示 + 下拉選單（外加整合的「SS」駕駛艙圖示）
- **自動更新** —— 內建 Sparkle 更新程式，選單中的「Check for Updates…」
- **無需 `sudo`。**

---

👉 建置步驟、無需 sudo 的實作原理（IOReport / SMC / HID）以及工程深入剖析，詳見
**[英文 README](README.md)**。

歡迎提出翻譯改進 —— 請提交 PR。
