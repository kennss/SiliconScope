# SiliconScope

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · **日本語** · [한국어](README.ko.md)

[![Website](https://img.shields.io/badge/website-siliconscope.calidalab.ai-5c9efa)](https://siliconscope.calidalab.ai)
[![Release](https://img.shields.io/github/v/release/kennss/SiliconScope?color=2b9348)](https://github.com/kennss/SiliconScope/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kennss/SiliconScope/total?color=2b9348)](https://github.com/kennss/SiliconScope/releases)
[![License: MIT](https://img.shields.io/github/license/kennss/SiliconScope)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-111)

**sudo 不要の Apple Silicon システムモニター** — ネイティブ SwiftUI ダッシュボード **と**
本格的なメニューバー一式を備え、Activity Monitor やターミナル系モニターでは見えない
**ANE（Neural Engine）**・**Media Engine**・**メモリ帯域幅**を一級の指標として追跡します。

オンデバイス AI とメディアのワークロードが Apple Silicon のアクセラレータをどう動かしているかを
*実際に見たい* という思いから生まれ、iStat Menus の代わりに使える常用モニターへと育ちました。

![ローカル LLM 負荷時の SiliconScope ダッシュボード](docs/img/dashboard.png)

*ローカル LLM 実行中（LM Studio · Llama-3.1-8B、GPU 100%）: SiliconScope は **サーマルスロットリング**（GPU クロックがピーク比 −20% に抑制）を検知し、ワークロードを M1 Max の 400 GB/s 上限に対して測定。ランタイムとモデルを認識し、すべてのエンジンをライブ表示します — GPU / GPU メモリ / ANE / Media と E/P コアの重ね描きトレンド、コア別温度、電力、帯域幅まで。*

### メニューバー — すべての指標を、iStat 風に

任意のカードを独立したメニューバー項目としてピン留めできます — **CPU · GPU · メモリ · ネットワーク · SSD · センサー · バッテリー** — それぞれにライブグリフと充実したドロップダウン。すべて sudo 不要。

![指標ごとのメニューバー一式](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU / Media / Neural ドロップダウン">
  <img src="docs/img/menubar-sensors.png" width="250" alt="コア別温度">
  <img src="docs/img/menubar-battery.png" width="250" alt="バッテリーの状態と電力">
</p>

*左: **GPU / Media / Neural** — GPU・GPU メモリ・ANE・Media をライブメーター + 4 本線の 60 秒トレンドで。中央: ユニット別温度 — 実際の **E-Core / P-Core / GPU / Memory** センサー（チップ世代ごとに厳選した SMC キー、M1–M5、その他は HID フォールバック）。右: バッテリーの健全性・サイクル数・状態、SoC 電力の内訳、電力を多く消費するアプリ。*

![ローカルモデルの速度と効率を測定](docs/img/benchmark.png)

*オンデマンドベンチマーク:「Measure tok/s」が短い生成を 1 回実行し、モデルのデコード速度とエネルギー効率 — **tokens/sec · tokens/Wh** — を測定してモデルごとに保存します。*

> 📊 **あなたの Mac で tok/s を測りましたか？** [Discussions に投稿してください](https://github.com/kennss/SiliconScope/discussions/5) — チップ別のクラウドソース表は、他の人のハードウェア選びに役立ちます。

## 作った理由

オンデバイス AI 動画プレーヤー **Spectalo** を開発する中で SiliconScope を作りました。それが実際に
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
- **プロセス** — 並べ替え・絞り込み・終了（カード内スクロール）
- **指標ごとのメニューバー項目** — CPU / GPU / メモリ / ネットワーク / SSD / センサー /
  バッテリーをそれぞれ独立したグリフ + ドロップダウンにピン留め（統合「SS」コックピットグリフも）
- **自動更新** — 内蔵の Sparkle アップデーター、メニューの「Check for Updates…」
- **`sudo` 不要。**

---

👉 ビルド手順、sudo 不要の仕組み（IOReport / SMC / HID）、技術的なディープダイブは
**[英語版 README](README.md)** にあります。

翻訳の改善提案はいつでも歓迎です — PR をお寄せください。
