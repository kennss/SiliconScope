# SiliconScope

[English](README.md) · **Deutsch** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

[![Website](https://img.shields.io/badge/website-siliconscope.calidalab.ai-5c9efa)](https://siliconscope.calidalab.ai)
[![Release](https://img.shields.io/github/v/release/kennss/SiliconScope?color=2b9348)](https://github.com/kennss/SiliconScope/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kennss/SiliconScope/total?color=2b9348)](https://github.com/kennss/SiliconScope/releases)
[![License: MIT](https://img.shields.io/github/license/kennss/SiliconScope)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-111)

**Ein Apple-Silicon-Systemmonitor ohne sudo** — ein natives SwiftUI-Dashboard **und** eine
vollständige Menüleisten-Suite — mit erstklassigem Tracking von **ANE (Neural Engine)**,
**Media Engine** und **Speicherbandbreite**, das die Aktivitätsanzeige und Terminal-Monitore
nicht zeigen.

Entstanden aus dem Wunsch zu *sehen*, wie On-Device-KI- und Medien-Workloads die
Apple-Silicon-Beschleuniger auslasten — und herangewachsen zu einem Alltags-Monitor, der
iStat Menus ersetzen kann.

*Vorgestellt auf [ifun.de](https://www.ifun.de/siliconscope-ueberwacht-apple-ki-neural-engine-und-speicher-in-echtzeit-282222/) (DE) und [AAPL Ch.](https://applech2.com/archives/20260620-siliconscope-apple-silicon-mac-system-monitor.html) (JP).*

![SiliconScope-Dashboard unter Last eines lokalen LLM](docs/img/dashboard.png)

*Die ganze Maschine auf einen Blick — ein Engpass-Klassifikator für AI-Workloads, überlagerte E-/P-Kern-Trends, GPU / GPU-Speicher / ANE / Media, der Speicher gemessen an der 400-GB/s-Grenze des M1 Max, Temperaturen pro Kern, Leistung und laufende Prozesse. Die Leiste am unteren Rand ist **Replay** (neu in 3.0): jede Metrik wird aufgezeichnet, sodass du wie bei einem DVR durch eine Sitzung zurückspulen kannst.*

### Menüleiste — jede Metrik, im iStat-Stil

Pinne jede Karte als eigenständiges Menüleisten-Element an — **CPU · GPU · Speicher · Netzwerk · SSD · Sensoren · Akku** — jeweils mit Live-Glyphe und ausführlichem Dropdown. Alles ohne sudo.

![Die Menüleisten-Suite pro Metrik](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU- / Media- / Neural-Dropdown">
  <img src="docs/img/menubar-sensors.png" width="250" alt="Temperaturen pro Kern">
  <img src="docs/img/menubar-battery.png" width="250" alt="Akkuzustand und Leistung">
</p>

*Links: **GPU / Media / Neural** — GPU, GPU-Speicher, ANE und Media als Live-Anzeigen + 60-Sekunden-Trend mit 4 Linien. Mitte: Temperaturen pro Einheit — echte **E-Core- / P-Core- / GPU- / Memory**-Sensoren (pro Chip-Generation kuratierte SMC-Schlüssel, M1–M5, sonst HID-Fallback). Rechts: Akku-Gesundheit, Ladezyklen und Zustand, Aufschlüsselung der SoC-Leistung, die stromhungrigsten Apps.*

![Geschwindigkeit und Effizienz lokaler Modelle messen](docs/img/benchmark.png)

*On-Demand-Benchmark: „Measure tok/s" führt eine kurze Generierung aus und misst die Dekodiergeschwindigkeit und Energieeffizienz eines Modells — **tokens/sec · tokens/Wh** — und speichert sie pro Modell.*

> 📊 **Schon tok/s auf deinem Mac gemessen?** [Poste es in den Discussions](https://github.com/kennss/SiliconScope/discussions/5) — eine per Crowdsourcing erstellte Tabelle pro Chip hilft anderen bei der Hardware-Wahl.

## Neu in 3.0

### 🧠 Prozess-Inspektor — Metriken pro Prozess, ohne sudo

Klicke auf einen beliebigen Prozess, um den Inspektor zu öffnen. Er zeigt, was die
Aktivitätsanzeige nicht kann: **CPU (P/E-Aufteilung) · IPC · Leistung pro Prozess (W) ·
Speicher · Disk** — jeweils mit einer Live-Sparkline — und das eine Signal, das sonst niemand
pro Prozess zeigt: **Neural-Engine-Speicher**. Sieh genau, welche App die ANE nutzt und wie
viel sie belegt.

![Prozess-Inspektor — CPU, IPC, Leistung und Neural-Engine-Speicher pro Prozess](docs/img/inspector.png)

*SpectaloWhispr transkribiert live (rechts): 65 % CPU bei **2,43 IPC**, **0,64 W** und **762 MB
Neural-Engine-Speicher** — der ANE-Speicherbedarf, den kein anderer Monitor pro Prozess zeigt.
Beschleuniger, die macOS nur systemweit meldet (GPU / ANE-Leistung / Media / Bandbreite), sind
genau so gekennzeichnet — keine erfundenen Werte pro Prozess.*

### ⏺ Aufzeichnen & Abspielen — ein DVR für die Metriken deines Macs

Drücke **Record**, und SiliconScope schreibt jede Metrik — CPU, GPU, ANE, Media, Bandbreite,
Leistung, Sensoren, Prozesse — in eine kompakte `.ssrec`-Datei. Spiele dann das gesamte
Dashboard mit **Play / Pause / Scrub / Geschwindigkeit** ab und fang einen Ausschlag ein, der
längst vorbei ist, wenn du hinschaust. Alles bleibt auf deinem Mac; exportiere eine Aufzeichnung
zum Teilen oder zum späteren Vergleich.

## Warum ich es gebaut habe

SiliconScope ist beim Entwickeln von **[Spectalo](https://spectalo.calidalab.ai/)** entstanden,
einem On-Device-KI-Videoplayer. Um zu sehen, wie er den Chip tatsächlich auslastet, musste ich
ständig zwei Monitore gleichzeitig offen haben — und keiner hat mich überzeugt:

- **asitop / NeoAsitop** liefern zwar Werte auf Chip-Ebene, aber das TUI ist schwer lesbar und
  informationsarm.
- **btop** ist schön und dicht, zeigt aber genau das Entscheidende nicht: **ANE (Neural Engine),
  Media Engine und Speicherbandbreite**.

Zwei Fenster nebeneinander offen zu halten war lästig und Platzverschwendung. Ich wollte
NeoAsitop und btop forken, um die Lücke zu schließen — habe es dann aber lieber richtig gemacht:
**ein einziges, natives, gut lesbares GUI**, das die Apple-Silicon-spezifischen Signale zeigt und
auch ohne Terminal-Affinität verständlich ist.

Also habe ich es gebaut.

Und als es fertig war, war klar, dass ich mich endlich von **iStat Menus** verabschieden konnte,
meinem langjährigen Alltags-Monitor. Das ist **2.0** — die Version mit der vollständigen
Menüleisten-Suite, Sensoren pro Einheit und Akku-Gesundheit, die SiliconScope braucht, um iStats
Platz einzunehmen.

## Installation

**[⬇ Neuestes DMG herunterladen](https://github.com/kennss/SiliconScope/releases/latest)** und:

1. Das geladene `SiliconScope-*.dmg` öffnen
2. **SiliconScope** in den Ordner **Programme** ziehen
3. Starten

Mit Developer ID signiert + **von Apple notarisiert**, also ohne Gatekeeper-Warnung zu öffnen.
Benötigt **macOS 14+ · Apple Silicon**. Danach **aktualisiert es sich automatisch** (Sparkle) —
das ist das letzte Mal, dass du manuell ein DMG laden musst.

Wenn du selbst bauen willst, siehe [Build & run](README.md#build--run) im englischen README.

## Hauptfunktionen

- **Prozess-Inspektor** *(neu in 3.0)* — fokussiere einen Prozess für CPU (P/E-Aufteilung), IPC,
  Leistung pro Prozess **(W)**, Speicher, Disk und **Neural-Engine-Speicher** — alles ohne sudo
- **Aufzeichnen & Abspielen** *(neu in 3.0)* — zeichne jede Metrik in eine `.ssrec`-Datei auf und
  spiele das Dashboard mit **Play / Pause / Scrub / Geschwindigkeit** ab, wie ein DVR
- **AI-Workload-Ansicht** — ein Engpass-Klassifikator (*bandwidth-bound* / *compute-bound* /
  *thermal-throttled* / *memory-pressured*) plus eine **„% of ceiling"**-Bandbreitenanzeige pro
  Chip — beantwortet: „Was bremst mein lokales LLM gerade?"
- **E-Kern- / P-Kern-Trennung** — Auslastung pro Cluster + echte DVFS-Frequenzen
- **GPU** — Auslastung, Leistung, Frequenz
- **ANE & Media Engine** — Neural-Engine-Leistung und Medien-Codec-Bandbreite (das
  Alleinstellungsmerkmal)
- **Speicherbandbreite** — CPU / GPU / Media / gesamt GB/s (das Engpass-Signal für lokale LLMs)
- **Speicher** — gestapelte Balken aus Wired / Active / Compressed / Free + macOS-Warnung bei
  **Speicherdruck**
- **Netzwerk** ↑/↓ und **Festplatte** Lesen/Schreiben + freier Speicher, mit Live-Graphen
- **Temperaturen pro Einheit** — echte **E-Core- / P-Core- / GPU- / Memory**-Sensoren über pro
  Generation kuratierte SMC-Schlüssel (M1–M5, sonst HID-Fallback), Lüfter-RPM, thermischer Druck,
  **GPU-Throttling-Erkennung** (ob der Takt unter Druck unter dem rollierenden Spitzenwert
  gehalten wird)
- **Akku** — Ladezustand, **Gesundheit %, Ladezyklen, Zustand** (AppleSmartBattery)
- **Leistung** — pro Domäne CPU / GPU / ANE / DRAM / SoC sowie Akku
- **Prozesse** — sortieren, filtern, beenden und **zum Inspizieren anklicken** (Scrollen innerhalb der Karte)
- **Menüleisten-Element pro Metrik** — CPU / GPU / Speicher / Netzwerk / SSD / Sensoren / Akku
  jeweils als eigene Glyphe + Dropdown anpinnen (plus die kombinierte „SS"-Cockpit-Glyphe)
- **Automatische Updates** — eingebauter Sparkle-Updater, „Check for Updates…" im Menü
- **Kein `sudo` nötig.**

## Verwandtes Projekt

**[Spectalo](https://spectalo.calidalab.ai/)** — ein schöner Videoplayer mit **On-Device**-KI-
Untertiteln und -Übersetzung (Whisper + Apple Intelligence), aus demselben Lab (Calida Lab).
SiliconScope ist beim Entwickeln davon entstanden. Kostenlose offene Beta über TestFlight —
dieselbe Haltung: nichts verlässt dein Gerät.

<a href="https://spectalo.calidalab.ai/"><img src="docs/img/spectalo-library.jpg" width="520" alt="Spectalo — On-Device-KI-Videoplayer"></a>

---

👉 Build-Anleitung, die Funktionsweise ohne sudo (IOReport / SMC / HID) und technische
Deep-Dives findest du im **[englischen README](README.md)**.

Vorschläge zur Verbesserung der Übersetzung sind jederzeit willkommen — bitte einen PR einreichen.
