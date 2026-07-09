# SiliconScope

[English](README.md) · [Deutsch](README.de.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · **日本語** · [한국어](README.ko.md)

[![Website](https://img.shields.io/badge/website-siliconscope.calidalab.ai-5c9efa)](https://siliconscope.calidalab.ai)
[![Release](https://img.shields.io/github/v/release/kennss/SiliconScope?color=2b9348)](https://github.com/kennss/SiliconScope/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kennss/SiliconScope/total?color=2b9348)](https://github.com/kennss/SiliconScope/releases)
[![License: MIT](https://img.shields.io/github/license/kennss/SiliconScope)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-111)

[![#2 Swift Repository Of The Day](https://trendshift.io/api/badge/trendshift/repositories/57307/daily?language=Swift)](https://trendshift.io/repositories/57307)

**sudo 不要の Apple Silicon システムモニター** — ネイティブ SwiftUI ダッシュボード **と**
本格的なメニューバー一式を備え、Activity Monitor やターミナル系モニターでは見えない
**ANE（Neural Engine）**・**Media Engine**・**メモリ帯域幅**を一級の指標として追跡します。

オンデバイス AI とメディアのワークロードが Apple Silicon のアクセラレータをどう動かしているかを
*実際に見たい* という思いから生まれ、iStat Menus の代わりに使える常用モニターへと育ちました。

*[AAPL Ch.](https://applech2.com/archives/20260620-siliconscope-apple-silicon-mac-system-monitor.html)（日本語）と [ifun.de](https://www.ifun.de/siliconscope-ueberwacht-apple-ki-neural-engine-und-speicher-in-echtzeit-282222/)（ドイツ語）に掲載されました。*

![ローカル LLM 負荷時の SiliconScope ダッシュボード](docs/img/dashboard.png)

*マシン全体をひと目で — AI ワークロードのボトルネック分類器、E/P コアの重ね描きトレンド、GPU / GPU メモリ / ANE / Media、M1 Max の 400 GB/s 上限に対して測定したメモリ、コア別温度、電力、そして稼働中のプロセス。下部のバーが **Replay**（3.0 で新登場）: すべての指標が記録されるので、DVR のようにセッションを巻き戻してスクラブできます。*

### メニューバー — すべての指標を、iStat 風に

任意のカードを独立したメニューバー項目としてピン留めできます — **CPU · GPU · メモリ · ネットワーク · SSD · センサー · バッテリー** — それぞれにライブグリフと充実したドロップダウン。すべて sudo 不要。

![指標ごとのメニューバー一式](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU / Media / Neural ドロップダウン">
  <img src="docs/img/menubar-sensors.png" width="250" alt="コア別温度">
  <img src="docs/img/menubar-cockpit.png" width="250" alt="統合 SS コックピット — ワークロード・全エンジン・トレンド・上位プロセス">
</p>

*最も情報量の多いドロップダウン。**GPU / Media / Neural** — GPU・GPU メモリ・ANE・Media をライブメーター + 4 本線の 60 秒トレンドで。**センサー** — ユニット別温度、実際の **E-Core / P-Core / GPU / Memory** センサー（チップ世代ごとに厳選した SMC キー、M1–M5、その他は HID フォールバック）。**SS コックピット** — マシン全体を 1 つのドロップダウンに: ワークロード判定、すべてのエンジン、60 秒トレンド、上位プロセス。*

![ローカルモデルの速度と効率を測定](docs/img/benchmark.png)

*オンデマンドベンチマーク:「Measure tok/s」が短い生成を 1 回実行し、モデルのデコード速度とエネルギー効率 — **tokens/sec · tokens/Wh** — を測定してモデルごとに保存します。*

> 📊 **あなたの Mac で tok/s を測りましたか？** [Discussions に投稿してください](https://github.com/kennss/SiliconScope/discussions/5) — チップ別のクラウドソース表は、他の人のハードウェア選びに役立ちます。

## 3.0 の新機能

### 🧠 プロセスインスペクタ — プロセスごとの指標を、sudo なしで

任意のプロセスをクリックするとインスペクタが開きます。Activity Monitor では見えないものを
表示します: **CPU（P/E 分割）· IPC · プロセスごとの電力（W）· メモリ · ディスク** — それぞれ
ライブのスパークライン付き — そして他のどこもプロセス単位では見せない指標、**Neural Engine
メモリ**。どのアプリが ANE を使い、どれだけ確保しているかが一目でわかります。

![プロセスインスペクタ — プロセスごとの CPU・IPC・電力・Neural Engine メモリ](docs/img/inspector.png)

*オンデバイスの文字起こしアプリがライブで動作中（右）: CPU 65%、**IPC 2.43**、**0.64 W**、そして
**762 MB の Neural Engine メモリ** — 他のモニターがプロセス単位で見せない ANE のフットプリント。
macOS がシステム全体でしか報告しないアクセラレータ（GPU / ANE 電力 / Media / 帯域幅）は、その旨
明示しています — プロセスごとの数値を捏造しません。*

### ⏺ 記録と再生 — Mac の指標のための DVR

**Record** を押すと、SiliconScope はあらゆる指標 — CPU・GPU・ANE・Media・帯域幅・電力・センサー・
プロセス — をコンパクトな `.ssrec` ファイルにストリーム記録します。あとはダッシュボード全体を
**再生 / 一時停止 / スクラブ / 速度変更** で再生でき、見たときにはもう消えているスパイクも
捉えられます。すべて Mac 内に留まります。記録を書き出して共有したり、後で比較したりできます。

![Replay バー — 再生 / 一時停止 / コマ送り、スクラブ、速度、Save](docs/img/replaybar.png)

*Replay バー: 再生 / 一時停止 / コマ送り、タイムラインのスクラブ、速度変更、そして記録の保存（Save）。*

## 作った理由

オンデバイス AI 動画プレーヤー **[Spectalo](https://spectalo.calidalab.ai/ja/)** を開発する中で SiliconScope を作りました。それが実際に
チップをどう動かしているかを見るため、モニターを 2 つ同時に開く羽目になり、どちらもしっくり
来ませんでした:

- **asitop / NeoAsitop** はチップレベルの数値はあるものの、TUI は見づらく情報も薄い。
- **btop** は美しく高密度なのに、肝心の **ANE（Neural Engine）・Media Engine・メモリ帯域幅** が
  見えない。

2 つを並べて開くのは煩わしく、画面の無駄でした。NeoAsitop と btop を fork して穴を埋めようと
しましたが、いっそ正しく作ることにしました — Apple Silicon 固有の信号を見せつつ、ターミナルの
住人でなくても読める **ひとつのネイティブで見やすい GUI** を。

そうして作りました。

そしてそれが出来上がると、長年の常用モニターだった **iStat Menus** とついに別れる時が来たと
気づきました。それが **2.0** です — SiliconScope が iStat の座を引き継ぐために必要な、完全な
メニューバー一式・ユニット別センサー・バッテリー健全性を備えたリリースです。

## インストール

**[⬇ 最新 DMG をダウンロード](https://github.com/kennss/SiliconScope/releases/latest)** して:

1. ダウンロードした `SiliconScope-*.dmg` を開く
2. **SiliconScope** を **アプリケーション** にドラッグ
3. 起動する

Developer ID 署名 + **Apple 公証**済みなので、Gatekeeper の警告なしに開けます。**macOS 14+ ·
Apple Silicon** が必要。以降は **自動更新**（Sparkle）するため、手動で DMG を落とすのはこれが
最後です。

自分でビルドしたい場合は、英語版 README の [Build & run](README.md#build--run) を参照してください。

## 主な機能

- **プロセスインスペクタ** *(3.0 で新登場)* — 1 つのプロセスに絞って CPU（P/E 分割）、IPC、
  プロセスごとの**電力（W）**、メモリ、ディスク、**Neural Engine メモリ**を表示 — すべて sudo なし
- **記録と再生** *(3.0 で新登場)* — あらゆる指標を `.ssrec` ファイルに記録し、ダッシュボードを
  **再生 / 一時停止 / スクラブ / 速度変更**で再生 — DVR のように
- **AI Workload ビュー** — ボトルネック分類器（*bandwidth-bound* / *compute-bound* /
  *thermal-throttled* / *memory-pressured*）とチップ別の **「% of ceiling」** 帯域ゲージ —
  「今、ローカル LLM の何が律速か？」に答えます。
- **E コア / P コアの分離** — クラスタ別の使用率 + 実際の DVFS 周波数
- **GPU** — 使用率・電力・周波数
- **ANE & Media Engine** — Neural Engine の電力とメディアコーデック帯域（差別化点）
- **メモリ帯域幅** — CPU / GPU / Media / 合計 GB/s（ローカル LLM のボトルネック信号）
- **メモリ** — Wired / Active / Compressed / Free の積み上げバー + macOS の **メモリ圧迫** 警告
- **ネットワーク** ↑/↓ と **ディスク** 読み書き + 空き容量、ライブグラフ付き
- **ユニット別温度** — 世代別に厳選した SMC キーで読む実際の **E-Core / P-Core / GPU / Memory**
  センサー（M1–M5、その他は HID フォールバック）、ファン RPM、サーマル圧迫、**GPU スロットル
  検知**（圧迫時にクロックがローリングピーク以下に抑えられているか）
- **バッテリー** — 充電状態・**健全性 %・サイクル数・状態**（AppleSmartBattery）
- **電力** — ドメイン別 CPU / GPU / ANE / DRAM / SoC、およびバッテリー
- **プロセス** — 並べ替え・絞り込み・終了、そして**クリックして詳細表示**（カード内スクロール）
- **指標ごとのメニューバー項目** — CPU / GPU / メモリ / ネットワーク / SSD / センサー /
  バッテリーをそれぞれ独立したグリフ + ドロップダウンにピン留め（統合「SS」コックピットグリフも）
- **自動更新** — 内蔵の Sparkle アップデーター、メニューの「Check for Updates…」
- **`sudo` 不要。**

## 関連プロジェクト

**[Spectalo](https://spectalo.calidalab.ai/ja/)** — オンデバイス AI 字幕・翻訳（Whisper + Apple
Intelligence）を備えた美しい動画プレーヤー。同じ Calida Lab 製で、SiliconScope はこれを作る過程から
生まれました。TestFlight で無料オープンベータ中 — 同じ思想です。「何もデバイスの外に出ません」。

<a href="https://spectalo.calidalab.ai/ja/"><img src="docs/img/spectalo-library.jpg" width="520" alt="Spectalo — オンデバイス AI 動画プレーヤー"></a>

---

👉 ビルド手順、sudo 不要の仕組み（IOReport / SMC / HID）、技術的なディープダイブは
**[英語版 README](README.md)** にあります。

翻訳の改善提案はいつでも歓迎です — PR をお寄せください。
