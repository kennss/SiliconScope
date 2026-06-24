# SiliconScope

[English](README.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

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

![本地 LLM 负载下的 SiliconScope 仪表盘](docs/img/dashboard.png)

*运行本地 LLM 时（LM Studio · Llama-3.1-8B，GPU 100%）：SiliconScope 标记出**热降频**（GPU 频率被压制在峰值的 −20%），将负载与 M1 Max 的 400 GB/s 上限对比测量，识别运行时与模型，并实时显示每个引擎 —— GPU / GPU 显存 / ANE / Media 与 E/P 核的叠加趋势、每核温度、功耗与带宽。*

### 菜单栏 —— 每项指标，iStat 风格

可将任意卡片固定为独立的菜单栏项 —— **CPU · GPU · 内存 · 网络 · SSD · 传感器 · 电池** —— 每项都有实时图标与丰富的下拉面板。全程无需 sudo。

![按指标划分的菜单栏套件](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU / Media / Neural 下拉面板">
  <img src="docs/img/menubar-sensors.png" width="250" alt="每核温度">
  <img src="docs/img/menubar-battery.png" width="250" alt="电池健康与功耗">
</p>

*左：**GPU / Media / Neural** —— 以实时仪表 + 4 线 60 秒趋势展示 GPU、GPU 显存、ANE 与 Media。中：按单元温度 —— 真实的 **E-Core / P-Core / GPU / Memory** 传感器（按芯片世代精选的 SMC 键，M1–M5，其余回退到 HID）。右：电池健康、循环次数、状态、SoC 功耗细分，以及耗电较多的 App。*

![测量本地模型的速度与能效](docs/img/benchmark.png)

*按需基准测试：“Measure tok/s” 运行一次短生成，测量模型的解码速度与能效 —— **tokens/sec · tokens/Wh** —— 并按模型保存。*

> 📊 **在你的 Mac 上测过 tok/s 吗？** [发到 Discussions 吧](https://github.com/kennss/SiliconScope/discussions/5) —— 一张众包的按芯片对照表能帮助其他人挑选合适的硬件。

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
- **进程** —— 排序、筛选、结束（卡片内滚动）
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
