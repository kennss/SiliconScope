# SiliconScope

[English](README.md) · [Deutsch](README.de.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

[![Website](https://img.shields.io/badge/website-siliconscope.calidalab.ai-5c9efa)](https://siliconscope.calidalab.ai)
[![Release](https://img.shields.io/github/v/release/kennss/SiliconScope?color=2b9348)](https://github.com/kennss/SiliconScope/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kennss/SiliconScope/total?color=2b9348)](https://github.com/kennss/SiliconScope/releases)
[![License: MIT](https://img.shields.io/github/license/kennss/SiliconScope)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-111)

**无需 sudo 的 Apple Silicon 系统监视器** —— 既是原生 SwiftUI 仪表盘，**也是**完整的菜单栏套件，
一等公民式地追踪 Activity Monitor 和终端类监视器看不到的 **ANE（Neural Engine）**、
**Media Engine** 和**内存带宽**。

它源于一个想法：*亲眼看看*端侧 AI 与媒体负载如何驱动 Apple Silicon 的各个加速器 —— 后来成长为
一款可以替代 iStat Menus 的日常监视器。

*已由 [AAPL Ch.](https://applech2.com/archives/20260620-siliconscope-apple-silicon-mac-system-monitor.html)（日本）与 [ifun.de](https://www.ifun.de/siliconscope-ueberwacht-apple-ki-neural-engine-und-speicher-in-echtzeit-282222/)（德国）报道。*

![本地 LLM 负载下的 SiliconScope 仪表盘](docs/img/dashboard.png)

*整台机器一目了然 —— AI 工作负载瓶颈分类器、E/P 核叠加趋势、GPU / GPU 显存 / ANE / Media、对照 M1 Max 400 GB/s 上限测量的内存、每核温度、功耗与实时进程。底部的工具条就是 **Replay**（3.0 新增）：每一项指标都会被记录，因此你可以像 DVR 一样回放、拖动整段会话。*

### 菜单栏 —— 每项指标，iStat 风格

可将任意卡片固定为独立的菜单栏项 —— **CPU · GPU · 内存 · 网络 · SSD · 传感器 · 电池** —— 每项都有实时图标与丰富的下拉面板。全程无需 sudo。

![按指标划分的菜单栏套件](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU / Media / Neural 下拉面板">
  <img src="docs/img/menubar-sensors.png" width="250" alt="每核温度">
  <img src="docs/img/menubar-battery.png" width="250" alt="电池健康与功耗">
  <img src="docs/img/menubar-cockpit.png" width="250" alt="合并的 SS 驾驶舱 —— 工作负载、全部引擎、趋势、置顶进程">
</p>

*信息最丰富的四个下拉面板。**GPU / Media / Neural** —— 以实时仪表 + 4 线 60 秒趋势展示 GPU、GPU 显存、ANE 与 Media。**传感器** —— 按单元温度，来自真实的 **E-Core / P-Core / GPU / Memory** 传感器（按芯片世代精选的 SMC 键，M1–M5，其余回退到 HID）。**电池** —— 健康、循环次数、状态、SoC 功耗细分，以及耗电较多的 App。**SS 驾驶舱** —— 一个下拉里看整机：工作负载判定、每个引擎、60 秒趋势与置顶进程。*

![测量本地模型的速度与能效](docs/img/benchmark.png)

*按需基准测试：“Measure tok/s” 运行一次短生成，测量模型的解码速度与能效 —— **tokens/sec · tokens/Wh** —— 并按模型保存。*

> 📊 **在你的 Mac 上测过 tok/s 吗？** [发到 Discussions 吧](https://github.com/kennss/SiliconScope/discussions/5) —— 一张众包的按芯片对照表能帮助其他人挑选合适的硬件。

## 3.0 新功能

### 🧠 进程检查器 —— 逐进程指标，无需 sudo

点击任意进程即可打开检查器。它能显示活动监视器看不到的内容：**CPU（P/E 拆分）· IPC ·
逐进程功耗（W）· 内存 · 磁盘** —— 每项都带实时迷你图 —— 以及别处无法逐进程查看的那项信号：
**神经引擎内存**。一眼看清哪个 App 正在用 ANE、占用了多少。

![进程检查器 —— 逐进程的 CPU、IPC、功耗与神经引擎内存](docs/img/inspector.png)

*一款端侧转写 App 正在实时运行（右）：65% CPU、**2.43 IPC**、**0.64 W**，以及 **762 MB 神经引擎内存**
—— 其他监视器从不逐进程显示的 ANE 占用。对于 macOS 只按系统整体上报的加速器（GPU / ANE 功耗 /
Media / 带宽），都会如实标注 —— 绝不伪造逐进程数字。*

### ⏺ 录制与回放 —— 你 Mac 指标的 DVR

按下 **Record**，SiliconScope 会把每一项指标 —— CPU、GPU、ANE、Media、带宽、功耗、传感器、进程
—— 流式写入一个紧凑的 `.ssrec` 文件。随后可用 **播放 / 暂停 / 拖动 / 倍速** 回放整个仪表盘，
抓住那些等你回头看时早已消失的尖峰。一切都留在你的 Mac 上；导出录制即可分享或日后对比。

![Replay 工具条 —— 播放 / 暂停 / 单步、拖动、倍速与 Save](docs/img/replaybar.png)

*Replay 工具条：播放 / 暂停 / 单步、拖动时间轴、调整倍速，以及保存录制（Save）。*

## 为什么做它

我是在开发端侧 AI 视频播放器 **[Spectalo](https://spectalo.calidalab.ai/zh-Hans/)** 时做出 SiliconScope 的。为了看清它究竟如何驱动芯片，
我常常同时开着两个监视器 —— 可两个都不合用：

- **asitop / NeoAsitop** 有芯片级数字，但 TUI 看着粗糙、信息也单薄。
- **btop** 美观且信息密集，却恰恰看不到我需要的 —— **ANE（Neural Engine）、Media Engine
  和内存带宽。**

把两者并排开着既别扭又浪费屏幕。我本想 fork NeoAsitop 和 btop 来补缺口 —— 后来决定干脆好好做一个：
**一个原生、好看的 GUI**，既呈现 Apple Silicon 特有的信号，又能让普通人（而不只是终端老炮）真正读懂。

于是我做了出来。

而当它真正存在之后，我意识到终于可以告别用了多年的日常监视器 **iStat Menus** 了。这正是 **2.0** 的
意义所在 —— 在这个版本里，SiliconScope 长出了取代 iStat 所需的完整菜单栏套件、按单元传感器与电池健康。

## 安装

**[⬇ 下载最新 DMG](https://github.com/kennss/SiliconScope/releases/latest)**，然后：

1. 打开下载的 `SiliconScope-*.dmg`
2. 将 **SiliconScope** 拖入**应用程序**
3. 启动它

已用 Developer ID 签名并经 **Apple 公证**，打开时不会有 Gatekeeper 警告。需要 **macOS 14+ ·
Apple Silicon**。此后它会**自动更新**（Sparkle）—— 这是你最后一次手动下载 DMG。

想自行构建？参见英文 README 的 [Build & run](README.md#build--run)。

## 功能亮点

- **进程检查器** *(3.0 新增)* —— 聚焦单个进程，查看 CPU（P/E 拆分）、IPC、逐进程**功耗（W）**、
  内存、磁盘与**神经引擎内存** —— 全部无需 sudo
- **录制与回放** *(3.0 新增)* —— 把每一项指标录入 `.ssrec` 文件，并以**播放 / 暂停 / 拖动 / 倍速**
  回放仪表盘，就像 DVR
- **AI Workload 视图** —— 瓶颈分类器（*bandwidth-bound* / *compute-bound* / *thermal-throttled* /
  *memory-pressured*）配合按芯片的 **“% of ceiling”** 带宽计 —— 回答“此刻是什么在拖慢我的本地 LLM？”
- **E 核 / P 核区分** —— 按簇使用率 + 真实 DVFS 频率
- **GPU** —— 使用率、功耗、频率
- **ANE & Media Engine** —— Neural Engine 功耗与媒体编解码带宽（差异化所在）
- **内存带宽** —— CPU / GPU / Media / 合计 GB/s（本地 LLM 的瓶颈信号）
- **内存** —— Wired / Active / Compressed / Free 堆叠条 + macOS **内存压力**告警
- **网络** ↑/↓ 与**磁盘**读写 + 剩余空间，附实时图表
- **按单元温度** —— 通过按世代精选的 SMC 键读取的真实 **E-Core / P-Core / GPU / Memory**
  传感器（M1–M5，其余回退到 HID）、风扇转速、热压力，以及 **GPU 降频检测**（压力下频率是否被压到
  其滚动峰值之下）
- **电池** —— 充电状态、**健康度 %、循环次数、状态**（AppleSmartBattery）
- **功耗** —— 按域的 CPU / GPU / ANE / DRAM / SoC，以及电池
- **进程** —— 排序、筛选、结束，并**点击以检查**（卡片内滚动）
- **按指标的菜单栏项** —— 将 CPU / GPU / 内存 / 网络 / SSD / 传感器 / 电池各自固定为独立的菜单栏
  图标 + 下拉面板（外加合并的 “SS” 驾驶舱图标）
- **自动更新** —— 内置 Sparkle 更新器，菜单中的 “Check for Updates…”
- **无需 `sudo`。**

## 相关项目

**[Spectalo](https://spectalo.calidalab.ai/zh-Hans/)** —— 一款拥有端侧 AI 字幕与翻译（Whisper + Apple
Intelligence）的精美视频播放器，同样出自 Calida Lab。SiliconScope 正是在开发它的过程中诞生的。现于
TestFlight 免费公测 —— 秉持同样的理念：数据绝不离开你的设备。

<a href="https://spectalo.calidalab.ai/zh-Hans/"><img src="docs/img/spectalo-library.jpg" width="520" alt="Spectalo —— 端侧 AI 视频播放器"></a>

---

👉 构建步骤、无需 sudo 的实现原理（IOReport / SMC / HID）以及工程深潜，详见
**[英文 README](README.md)**。

欢迎提出翻译改进 —— 请提交 PR。
