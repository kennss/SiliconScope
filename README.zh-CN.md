# SiliconScope

[English](README.md) · [Deutsch](README.de.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

[![Website](https://img.shields.io/badge/website-siliconscope.calidalab.ai-5c9efa)](https://siliconscope.calidalab.ai) [![Release](https://img.shields.io/github/v/release/kennss/SiliconScope?color=2b9348)](https://github.com/kennss/SiliconScope/releases/latest) [![Downloads](https://img.shields.io/github/downloads/kennss/SiliconScope/total?color=2b9348)](https://github.com/kennss/SiliconScope/releases) [![License: MIT](https://img.shields.io/github/license/kennss/SiliconScope)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-111)

[![#2 Swift Repository Of The Day](https://trendshift.io/api/badge/trendshift/repositories/57307/daily?language=Swift)](https://trendshift.io/repositories/57307)

**无需 sudo 的 Apple Silicon 系统监控工具。** 它既有原生 SwiftUI 仪表盘，**也有**一整套菜单栏组件。活动监视器和终端监控工具看不到的 **ANE（Neural Engine）**、**Media Engine** 和**内存带宽**，在这里都是重点监测项。

最初只是想*亲眼看看*端侧 AI 和媒体任务是怎样调动 Apple Silicon 各个加速器的，后来慢慢完善，成了一款可以常驻使用、足以替代 iStat Menus 的监控工具。

**从 4.0 开始，它也能监控你的*其他*机器。** 无头运行的 Mac mini、桌子底下的 Linux GPU 主机、租来的云服务器，只要在上面跑一个轻量 agent，就能通过加密配对的连接接入同一个仪表盘。远程 Mac 的指标一项不少，**Neural Engine 也在其中**。

*媒体报道：[OWC Rocket Yard](https://eshop.macsales.com/blog/99094-siliconscope-improves-upon-macos-activity-monitor-with-apple-silicon-insights/)（美国）、[AAPL Ch.](https://applech2.com/archives/20260620-siliconscope-apple-silicon-mac-system-monitor.html)（日本）、[ifun.de](https://www.ifun.de/siliconscope-ueberwacht-apple-ki-neural-engine-und-speicher-in-echtzeit-282222/)（德国）。*

![端侧 AI 负载下的 SiliconScope 仪表盘](docs/img/dashboard.png)

*一台 M1 Max，系统为 macOS 27，正在跑真实的端侧 AI 任务：[Spectalo](https://spectalo.calidalab.ai/) 在运行它的 Core ML 模型。负载分类器给出的判断是 **ANE (CoreML)**，Neural Engine **100 % 活跃，数据吞吐 16 GB/s**。这个数值来自实测的簇驻留率，所以即使在 macOS 27 上也是实时的（在这个系统上，这颗芯片的能耗计数器大约半小时才更新一次）。GPU 占用 100 %，功耗 36 W；内存带宽 306 GB/s，而芯片上限是 400 GB/s（**带宽受限**）；顶栏的 **system 105 W** 是整台 Mac 的功耗。只有需要留意的地方才会上色，比如这里 CPU 和 GPU 温度超过 90 °C，显示为红色，其余一律用中性色。底部那一条就是 **Replay**（3.0 新增）：所有指标都有记录，可以像录像机一样拖动进度，回看整段过程。*

### 菜单栏：iStat 风格，每项指标单独成项

任意一张卡片都能单独固定到菜单栏：**CPU · GPU · 内存 · 网络 · SSD · 传感器 · 电池**，每项都有实时图标和信息丰富的下拉面板。每一项可以单独选择**显示样式**（条形 · 历史曲线 · 双行 · 单值 · 图标）和要绘制的读数，所以同一个指标甚至可以放两次，比如 CPU 一个用条形、一个用曲线。全部无需 sudo。

![按指标拆分的菜单栏组件](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU / Media / Neural 下拉面板"> <img src="docs/img/menubar-sensors.png" width="250" alt="每个核心的温度"> <img src="docs/img/menubar-cockpit.png" width="250" alt="SS 综合面板：负载判断、所有引擎、趋势、占用最高的进程">
</p>

*信息最多的几个下拉面板。**GPU / Media / Neural**：用实时仪表显示 GPU、显存、ANE 和 Media，并附 60 秒的 4 线趋势图。**传感器**：按部件显示温度，数据来自真实的 **E-Core / P-Core / GPU / Memory** 传感器（M1–M5 按芯片代际精选 SMC 键，其他机型回退到 HID）。**SS 综合面板**：一个下拉面板看全机，包括负载判断、每个引擎、60 秒趋势和占用最高的进程。*

![测量本地模型的速度与能效](docs/img/benchmark.png)

*按需基准测试：“Measure tok/s” 会跑一次简短的生成，测出模型的解码速度和能效（**tokens/sec · tokens/Wh**），结果按模型分别保存。*

> 📊 **在自己的 Mac 上测过 tok/s？** 欢迎[发到 Discussions](https://github.com/kennss/SiliconScope/discussions/5)。大家一起凑出一张按芯片划分的对照表，方便别人挑选合适的硬件。

## 4.0 新功能

### 🛰 Fleet：其他机器也放进同一个仪表盘

在远程主机上运行 agent 后，它会出现在 **Devices** 侧边栏里，和 **This Mac** 并列。局域网内的机器通过 mDNS 自动发现，不用手动填 IP。

![Fleet 总览：所有机器一屏看完](docs/img/fleet-overview.png)

*三台机器一目了然。每张卡片把 **GPU + VRAM** 和 **CPU + RAM** 画在同一坐标轴上，Apple Silicon机器还会加上 **ANE + 内存带宽**。指标名的颜色和对应曲线一致，所以不需要图例。卡片最下面一行是**运行时实测的解码速度**，并注明是多久之前测的：Ubuntu 主机为 **262 tok/s**，两台 Mac 都是 **28 tok/s**。数值一旦过时就会变暗。This Mac 始终排在第一张。*

- **远程 Mac 的显示和本机仪表盘完全相同**：E/P 核、GPU、**ANE**、Media、内存带宽、功耗、风扇。据我所知，目前还没有别的工具能显示**远程 Mac 的 Neural Engine**。
- **Linux/NVIDIA 主机则以 GPU 为主**：利用率、显存、功耗（对照显卡功耗上限）、温度、哪些进程占着显存，以及已加载的 **Ollama** 模型。它不会硬给 3090 编出 E 核来。

![远程 Mac 显示完整的本机仪表盘，含 ANE](docs/img/fleet-remote-mac.png)

*在另一台 Mac 上查看一台无头运行的 M1 Air：**4E+4P** 核心、GPU/Media/**ANE 估算值**，以及真实的内存构成（**wired 1.0 / active 2.7 / compressed 0.5 GB**，内存压力 19%）。传感器一栏如实显示 **fanless**，不会编造风扇读数。通过网络传不过来的卡片直接省略，不做假数据。*

![Linux GPU 主机：显存占用进程与 Ollama 模型](docs/img/fleet-linux.png)

*同一个 App，换一类机器。一台空闲的 RTX 3090 主机：功耗 **34 / 390 W**（对照显卡上限），**0.5 / 24 GB 显存**及占用它的进程（ComfyUI 的 Python，**0.2 GB**），两块硬盘的容量（4.4 新增），还有磁盘上的 Ollama 模型，都没有加载，所以显示为灰色。没有 E 核，也没有 ANE，因为这台机器本来就没有。*

所有连接都经过 **TLS 加密和令牌认证**。查看端在首次连接时会固定 agent 的证书（TOFU），之后如果 agent 换了密钥或遭人冒充，连接会直接被拒绝，不会悄悄放行。

![This Mac 保持原样，新增 Devices 侧边栏](docs/img/fleet-sidebar.png)

*只用一台 Mac 的话，什么都没变：还是原来的仪表盘，只多了一个可折叠的 **Devices** 侧边栏。折起来就和 3.x 完全一样。*

#### 安装 agent

各平台共用同一个 URL，在 Linux 上安装为 systemd 服务，在 macOS 上安装为 LaunchAgent：

```sh
curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh | sh
```

Mac 版 agent **不需要 sudo**，所以通过 `ssh` 执行也能全程无人值守地装完。每个安装脚本最后都会输出一行 `sscope://pair…` 链接，粘贴到 App 的 **Add machine…** 里，添加和配对一步完成。

如果是你平时坐在前面用的那台 Mac，连 agent 都不用装，直接打开**设置 → Share this Mac** 即可。

**在 Intel Mac 上**，agent 只报告 CPU 和内存，因为这类机器本身就只有这些。芯片级指标之所以缺失，是因为硬件里就没有：没有 Neural Engine，没有 Media Engine，也没有统一内存带宽和分域功耗，这些数据来自只有 Apple Silicon 才提供的接口。SiliconScope App 本身仍然只支持 Apple Silicon。

**在 Windows 机器上**，agent 报告 CPU 和内存；NVIDIA 显卡则走和 Linux 相同的 `nvidia-smi` 路径，提供利用率、显存、温度、功耗和每进程显存。Windows 没有 load average，这一栏留空，不会凭空编一个数字；磁盘容量目前也还没有采集。这台机器会像 Linux GPU 主机一样加入 Fleet。暂时还没有一行命令的安装脚本：请用 `GOOS=windows go build ./agent` 构建 agent，再以计划任务的方式运行。

> **无头 Mac？** 请先打开**系统设置 → 通用 → 共享 → 远程登录**，否则没法在上面安装任何东西。**不在同一局域网**（Tailscale、VPN、云服务器）？mDNS 发现不了，需要在 **Add machine…** 里按地址添加。建议走 Tailscale 或 SSH 隧道，不要把端口直接暴露到公网。

> **开启了锁定模式，或防火墙设为阻止所有传入连接的 Mac**，查看端连不上它的 agent：要么根本不出现在列表里，要么显示红点并报 TLS 错误或主机名无法解析。在那台 Mac 上打开**系统设置 → 网络 → 防火墙 → 选项**，关闭**阻止所有传入连接**，确认 SiliconScope（或 `sscope-agent-mac`）在允许列表中，然后重启 SiliconScope。这是 [@progenitor-amborella](https://github.com/progenitor-amborella) 在 [#63](https://github.com/kennss/SiliconScope/issues/63) 中整理的方法。

**卸载 agent**：在那台机器上运行同一个安装脚本，加上 `--uninstall` 参数：

```sh
curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh | sh -s -- --uninstall
```

脚本会停止服务，并删除二进制文件、令牌、证书和钥匙串。之后在查看端 Mac 的 Fleet 侧边栏里右键点击该机器 → **Forget pairing**。

## 3.0 新功能

### 🧠 进程检查器：逐进程指标，无需 sudo

点击任意进程即可打开检查器，看到活动监视器看不到的数据：**CPU（P/E 拆分）· IPC ·进程功耗（W）· 内存 · 磁盘**，每项都配有实时迷你图。另外还有一项别处都无法按进程查看的指标：**Neural Engine 内存**。哪个 App 在用 ANE、占了多少，一眼就能看清。

![进程检查器：逐进程的 CPU、IPC、功耗与 Neural Engine 内存](docs/img/inspector.png)

*右侧是一款正在实时运行的端侧转写 App：CPU 65%、**2.43 IPC**、**0.64 W**，以及 **762 MB Neural Engine 内存**。其他监控工具从来不按进程显示 ANE 占用。GPU / ANE 功耗 / Media / 带宽这几项 macOS 只提供系统总量，检查器会明确标注为系统级，绝不伪造逐进程数字。*

### ⏺ 录制与回放：Mac 指标的录像机

按下 **Record**，SiliconScope 会把所有指标（CPU、GPU、ANE、Media、带宽、功耗、传感器、进程）持续写入一个紧凑的 `.ssrec` 文件。之后可以用**播放 / 暂停 / 拖动 / 倍速**回放整个仪表盘，那些等你回头去看时早已消失的峰值，也能抓个正着。数据全部留在本机；需要时可以导出录制文件，分享给别人或留着以后对比。

![Replay 控制条：播放 / 暂停 / 单步、拖动、倍速与 Save](docs/img/replaybar.png)

*Replay 控制条：播放 / 暂停 / 单步，拖动时间轴，调节倍速，以及保存录制（Save）。*

## 为什么做它

SiliconScope 是我在开发端侧 AI 视频播放器 **[Spectalo](https://spectalo.calidalab.ai/zh-Hans/)** 时做出来的。为了看清它到底是怎么调用芯片的，我经常同时开着两个监控工具，但哪个都不顺手：

- **asitop / NeoAsitop** 有芯片级数据，但 TUI 界面粗糙，信息也少。
- **btop** 好看、信息密度高，偏偏看不到我最需要的 **ANE（Neural Engine）、Media Engine和内存带宽。**

两个并排开着既别扭，又占屏幕。我一开始打算 fork NeoAsitop 和 btop 来补上缺口，后来决定干脆认真做一个：**一个原生、好看的 GUI**，把 Apple Silicon 特有的指标都展示出来，而且不只是终端老手，普通用户也能看懂。

于是就有了它。

做出来以后我才意识到，终于可以和用了多年的 **iStat Menus** 说再见了。**2.0** 正是为此而来：这一版补齐了完整的菜单栏组件、按部件划分的传感器和电池健康度，足以在我自己的 Mac 上取代 iStat。

## 安装

**Homebrew**（最简单）：

```sh
brew install --cask siliconscope
```

也可以下载 DMG：**[⬇ 下载最新 DMG](https://github.com/kennss/SiliconScope/releases/latest)**，然后：

1. 打开下载好的 `SiliconScope-*.dmg`
2. 把 **SiliconScope** 拖进**应用程序**
3. 启动即可

App 已使用 Developer ID 签名并通过 **Apple 公证**，打开时不会弹出 Gatekeeper 提示。系统要求：**macOS 14+ · Apple Silicon**。之后会通过 Sparkle **自动更新**，这也是你最后一次手动下载 DMG。

> **不支持 macOS 预览版（Beta）。** 本项目只有一台 Mac，装的是正式版，没法复现或验证开发者 Beta 上的问题。不过仍然欢迎反馈，之前的反馈也确实帮上了忙：SiliconScope 读取的是 Apple 私有的 IOReport 接口，Apple 会在不同版本之间给它们改名，发现得越早，就越能赶在影响所有用户之前修好。只是修复会随正式版发布，不会针对某个 Beta 版本单独适配。

想自己构建？请看英文 README 的 [Build & run](README.md#build--run)。

## 功能亮点

- **进程检查器** *(3.0 新增)*：聚焦单个进程，查看 CPU（P/E 拆分）、IPC、进程级**功耗（W）**、内存、磁盘和 **Neural Engine 内存**，全部无需 sudo
- **录制与回放** *(3.0 新增)*：把所有指标录进 `.ssrec` 文件，再用**播放 / 暂停 / 拖动 / 倍速**回放仪表盘，就像录像机一样
- **AI Workload 视图**：瓶颈分类器（*bandwidth-bound* / *compute-bound* / *thermal-throttled* / *memory-pressured*），以各芯片标称的内存带宽上限为基准，回答“本地 LLM 这会儿卡在哪儿？”
- **E 核 / P 核分开显示**：按簇统计使用率，外加真实 DVFS 频率
- **GPU**：使用率、功耗、频率
- **ANE 与 Media Engine**：Neural Engine 活跃度（实测簇驻留率）、功耗和内存流量，以及媒体编解码带宽（这是与其他工具的主要区别）
- **内存带宽**：CPU / GPU / Media / ANE / 总计，单位 GB/s（判断本地 LLM 瓶颈的关键信号）
- **内存**：Wired / Active / Compressed / Free 堆叠条，以及 macOS **内存压力**警告
- **网络** ↑/↓ 与**磁盘**读写、剩余空间，附实时图表
- **按部件划分的温度**：通过按代际精选的 SMC 键读取真实的 **E-Core / P-Core / GPU / Memory**传感器（M1–M5，其他机型回退到 HID），另有风扇转速、热压力，以及 **GPU 降频检测**（在压力下，频率是否被压在其滚动峰值以下）
- **电池**：充电状态、**健康度 %、循环次数、状况**（AppleSmartBattery）
- **功耗**：CPU / GPU / ANE / DRAM / SoC 分域功耗，以及电池
- **进程**：排序、筛选、结束进程，**点击即可查看详情**（卡片内滚动）
- **每项指标一个菜单栏项**：CPU / GPU / 内存 / 网络 / SSD / 传感器 / 电池都能单独固定为菜单栏图标 + 下拉面板（另有一个综合的 “SS” 面板图标）
- **自动更新**：内置 Sparkle 更新器，菜单里有 “Check for Updates…”
- **无需 `sudo`。**

## 相关项目

**[Spectalo](https://spectalo.calidalab.ai/zh-Hans/)**：同样出自 Calida Lab 的视频播放器，界面精致，字幕和翻译都在端侧生成（Whisper + Apple Intelligence）。SiliconScope 就是在开发它的过程中诞生的。目前在TestFlight 免费公测，理念也一样：数据不离开你的设备。

<a href="https://spectalo.calidalab.ai/zh-Hans/"><img src="docs/img/spectalo-library.jpg" width="520" alt="Spectalo：端侧 AI 视频播放器"></a>

---

👉 构建步骤、免 sudo 的实现原理（IOReport / SMC / HID）和各项技术细节，请看**[英文 README](README.md)**。


### Calida Lab 的其他产品

注重隐私、在设备端运行的软件（主要面向 Apple Silicon）：

- **[SpectaLing](https://spectaling.calidalab.ai/)** — 端侧转录，外加实时翻译和同声传译（Mac/iPad）。注重隐私的 MacWhisper 替代品。
- **[SpectArk](https://spectark.calidalab.ai/)** — 只备份你在意的 Mac 文件夹，实时保留每个版本：每次改动几秒内存档，提供 Time Machine 式的恢复点，可备份到任意磁盘或 NAS。
- **[SpectaBooks](https://spectabooks.calidalab.ai/zh-Hans/)** — 给你手头已有的书用的阅读器：读取你自己的文件夹、iCloud Drive 或 Google Drive 里的文本、EPUB、PDF 和漫画，阅读进度在 iPhone、iPad 和 Mac 之间同步，朗读和翻译都在设备端完成。
- **[SnowChat](https://snowchat.calidalab.ai/)** — 端到端加密的即时通讯应用，基于自研的 Signal 协议库。
- **[SnowClaw](https://snowclaw.calidalab.ai/)** — 注重隐私保护的智能体 AI 参考架构（工作论文）。

**→ [www.calidalab.ai](https://www.calidalab.ai/zh-Hans/)** · [@kennss](https://github.com/kennss)


翻译有改进建议？欢迎提交 PR。
