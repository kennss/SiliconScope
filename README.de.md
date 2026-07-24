# SiliconScope

[English](README.md) · **Deutsch** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

[![Website](https://img.shields.io/badge/website-siliconscope.calidalab.ai-5c9efa)](https://siliconscope.calidalab.ai)
[![Release](https://img.shields.io/github/v/release/kennss/SiliconScope?color=2b9348)](https://github.com/kennss/SiliconScope/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kennss/SiliconScope/total?color=2b9348)](https://github.com/kennss/SiliconScope/releases)
[![License: MIT](https://img.shields.io/github/license/kennss/SiliconScope)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-111)

[![#2 Swift Repository Of The Day](https://trendshift.io/api/badge/trendshift/repositories/57307/daily?language=Swift)](https://trendshift.io/repositories/57307)

**Ein Apple-Silicon-Systemmonitor ohne sudo** — ein natives SwiftUI-Dashboard **und** eine
vollständige Menüleisten-Suite — mit erstklassigem Tracking von **ANE (Neural Engine)**,
**Media Engine** und **Speicherbandbreite**, das die Aktivitätsanzeige und Terminal-Monitore
nicht zeigen.

Entstanden aus dem Wunsch zu *sehen*, wie On-Device-KI- und Medien-Workloads die
Apple-Silicon-Beschleuniger auslasten — und herangewachsen zu einem Alltags-Monitor, der
iStat Menus ersetzen kann.

**Neu in 4.0 — er beobachtet jetzt auch deine *anderen* Rechner.** Ein Mac mini ohne Bildschirm,
eine Linux-GPU-Kiste unter dem Schreibtisch, eine gemietete Cloud-Instanz: Dort läuft ein kleiner
Agent, und die Maschine tritt über eine verschlüsselte, gekoppelte Verbindung demselben Dashboard
bei. Ferne Macs bekommen die volle Behandlung — **Neural Engine inklusive**.

*Vorgestellt auf [ifun.de](https://www.ifun.de/siliconscope-ueberwacht-apple-ki-neural-engine-und-speicher-in-echtzeit-282222/) (DE) und [AAPL Ch.](https://applech2.com/archives/20260620-siliconscope-apple-silicon-mac-system-monitor.html) (JP).*

![SiliconScope-Dashboard unter Last eines lokalen LLM](docs/img/dashboard.png)

*Die ganze Maschine auf einen Blick — ein Engpass-Klassifikator für AI-Workloads, überlagerte E-/P-Kern-Trends, GPU / GPU-Speicher / ANE / Media, der Speicher gemessen an der 400-GB/s-Grenze des M1 Max, Temperaturen pro Kern, Leistung und laufende Prozesse. Die Leiste am unteren Rand ist **Replay** (neu in 3.0): jede Metrik wird aufgezeichnet, sodass du wie bei einem DVR durch eine Sitzung zurückspulen kannst.*

### Menüleiste — jede Metrik, im iStat-Stil

Pinne jede Karte als eigenständiges Menüleisten-Element an — **CPU · GPU · Speicher · Netzwerk · SSD · Sensoren · Akku** — jeweils mit Live-Glyphe und ausführlichem Dropdown. Alles ohne sudo.

![Die Menüleisten-Suite pro Metrik](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU- / Media- / Neural-Dropdown">
  <img src="docs/img/menubar-sensors.png" width="250" alt="Temperaturen pro Kern">
  <img src="docs/img/menubar-cockpit.png" width="250" alt="Kombiniertes SS-Cockpit — Workload, alle Engines, Trends, Top-Prozesse">
</p>

*Die informationsreichsten Dropdowns. **GPU / Media / Neural** — GPU, GPU-Speicher, ANE und Media als Live-Anzeigen + 60-Sekunden-Trend mit 4 Linien. **Sensoren** — Temperaturen pro Einheit aus echten **E-Core- / P-Core- / GPU- / Memory**-Sensoren (pro Chip-Generation kuratierte SMC-Schlüssel, M1–M5, sonst HID-Fallback). **SS-Cockpit** — die ganze Maschine in einem Dropdown: Workload-Urteil, jede Engine, 60-Sekunden-Trends und die Top-Prozesse.*

![Geschwindigkeit und Effizienz lokaler Modelle messen](docs/img/benchmark.png)

*On-Demand-Benchmark: „Measure tok/s" führt eine kurze Generierung aus und misst die Dekodiergeschwindigkeit und Energieeffizienz eines Modells — **tokens/sec · tokens/Wh** — und speichert sie pro Modell.*

> 📊 **Schon tok/s auf deinem Mac gemessen?** [Poste es in den Discussions](https://github.com/kennss/SiliconScope/discussions/5) — eine per Crowdsourcing erstellte Tabelle pro Chip hilft anderen bei der Hardware-Wahl.

## Neu in 4.0

### 🛰 Fleet — deine anderen Rechner, im selben Dashboard

Läuft auf einem entfernten Rechner ein Agent, taucht er in einer **Devices**-Seitenleiste neben
**This Mac** auf. Maschinen im eigenen LAN werden per mDNS automatisch gefunden — keine
IP-Konfiguration nötig.

![Die Fleet-Übersicht — alle Rechner auf einem Bildschirm](docs/img/fleet-overview.png)

*Drei Rechner auf einen Blick. Jede Kachel legt **GPU + VRAM** und **CPU + RAM** auf dieselbe Achse,
auf Apple Silicon kommen **ANE + Speicherbandbreite** dazu — das Metrik-Wort ist in der Farbe seiner
Linie eingefärbt, eine Legende erübrigt sich. Hier liegt das MacBook Pro bei **64 % GPU / 10 GB/s**,
das Air ist im Leerlauf, und die Ubuntu-Kiste hält **18,7 GB VRAM** mit zwei geladenen
Ollama-Modellen. This Mac ist immer die erste Kachel.*

- **Ein ferner Mac wird in genau dem Dashboard gezeichnet, das auch lokal läuft** — E-/P-Kerne, GPU,
  **ANE**, Media, Speicherbandbreite, Leistung, Lüfter. Soweit ich weiß, zeigt kein anderes Werkzeug
  die **Neural Engine eines fernen Macs**.
- **Eine Linux/NVIDIA-Kiste bekommt eine GPU-zentrierte Ansicht** — Auslastung, VRAM, Leistung gegen
  das Limit der Karte, Temperatur, welche Prozesse das VRAM halten, und geladene **Ollama**-Modelle.
  Sie tut nicht so, als hätte eine 3090 E-Kerne.

![Ein ferner Mac im vollen lokalen Dashboard, ANE inklusive](docs/img/fleet-remote-mac.png)

*Ein M1 Air ohne Bildschirm, von einem anderen Mac aus gesehen: **4E+4P**-Kerne, GPU/Media/**ANE
(geschätzt)**, dazu die echte Speicheraufteilung (**wired 1,0 / active 2,7 / compressed 0,5 GB**,
Druck 19 %) — und die Sensoren melden ehrlich **fanless**, statt einen Lüfterwert zu erfinden. Karten,
die ein Wire-Agent nicht füllen kann, werden weggelassen und nicht gefälscht.*

![Eine Linux-GPU-Kiste mit VRAM-Haltern und Ollama-Modellen](docs/img/fleet-linux.png)

*Dieselbe App, eine andere Klasse von Rechner. Eine RTX-3090-Kiste: **35 / 390 W** gegen das Limit der
Karte, **18,7 / 24 GB VRAM**, wer es hält (ein Python-venv mit **17,9 GB**) und die Ollama-Modelle auf
der Platte. Keine E-Kerne, keine ANE — weil sie beides nicht hat.*

Jede Verbindung ist **TLS-verschlüsselt und token-authentifiziert**, und der Viewer pinnt beim ersten
Verbinden das Zertifikat des Agents (TOFU) — ein neu geschlüsselter oder untergeschobener Agent wird
also abgelehnt statt stillschweigend vertraut.

![This Mac unverändert, mit der neuen Devices-Seitenleiste](docs/img/fleet-sidebar.png)

*Am Betrieb mit nur einem Mac ändert sich nichts — es ist dasselbe Dashboard, ergänzt um eine
einklappbare **Devices**-Seitenleiste. Klapp sie ein, und du bist exakt bei 3.x.*

#### Einen Agent installieren

Eine URL für jede Plattform — unter Linux als systemd-Dienst, unter macOS als LaunchAgent:

```sh
curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh | sh
```

Der Mac-Agent braucht **kein sudo** und läuft deshalb auch über `ssh` unbeaufsichtigt durch. Jeder
Installer gibt am Ende eine einzige `sscope://pair…`-Zeile aus — einfügen unter **Add machine…**, und
der Rechner ist in einem Schritt hinzugefügt *und* gekoppelt.

Auf einem Mac, an dem du tatsächlich sitzt, brauchst du gar keinen Agent:
**Einstellungen → Share this Mac**.

> **Mac ohne Bildschirm?** Aktiviere zuerst **Systemeinstellungen → Allgemein → Freigabe →
> Entfernte Anmeldung** — sonst lässt sich dort nichts installieren. **Außerhalb deines LAN**
> (Tailscale, VPN, Cloud)? Dorthin kommt mDNS nicht, also per Adresse unter **Add machine…**
> hinzufügen; lieber Tailscale oder einen SSH-Tunnel als den Port öffentlich freizugeben.

**Einen Agent entfernen** — auf dem betreffenden Rechner den Installer mit `--uninstall` ausführen (`curl -fsSL …/install-agent.sh | sh -s -- --uninstall`, oder lokal `sh install-agent.sh --uninstall`). Er stoppt den Dienst und löscht Binary, Token, Zertifikat und Keychain. Danach auf dem Viewer-Mac in der Fleet-Seitenleiste rechtsklicken → **Forget pairing**.

## Neu in 3.0

### 🧠 Prozess-Inspektor — Metriken pro Prozess, ohne sudo

Klicke auf einen beliebigen Prozess, um den Inspektor zu öffnen. Er zeigt, was die
Aktivitätsanzeige nicht kann: **CPU (P/E-Aufteilung) · IPC · Leistung pro Prozess (W) ·
Speicher · Disk** — jeweils mit einer Live-Sparkline — und das eine Signal, das sonst niemand
pro Prozess zeigt: **Neural-Engine-Speicher**. Sieh genau, welche App die ANE nutzt und wie
viel sie belegt.

![Prozess-Inspektor — CPU, IPC, Leistung und Neural-Engine-Speicher pro Prozess](docs/img/inspector.png)

*Eine On-Device-Transkriptions-App läuft live (rechts): 65 % CPU bei **2,43 IPC**, **0,64 W** und **762 MB
Neural-Engine-Speicher** — der ANE-Speicherbedarf, den kein anderer Monitor pro Prozess zeigt.
Beschleuniger, die macOS nur systemweit meldet (GPU / ANE-Leistung / Media / Bandbreite), sind
genau so gekennzeichnet — keine erfundenen Werte pro Prozess.*

### ⏺ Aufzeichnen & Abspielen — ein DVR für die Metriken deines Macs

Drücke **Record**, und SiliconScope schreibt jede Metrik — CPU, GPU, ANE, Media, Bandbreite,
Leistung, Sensoren, Prozesse — in eine kompakte `.ssrec`-Datei. Spiele dann das gesamte
Dashboard mit **Play / Pause / Scrub / Geschwindigkeit** ab und fang einen Ausschlag ein, der
längst vorbei ist, wenn du hinschaust. Alles bleibt auf deinem Mac; exportiere eine Aufzeichnung
zum Teilen oder zum späteren Vergleich.

![Die Replay-Leiste — Play / Pause / Einzelschritt, Scrubben, Geschwindigkeit und Save](docs/img/replaybar.png)

*Die Replay-Leiste: Play / Pause / Einzelschritt, durch die Zeitleiste scrubben, Geschwindigkeit ändern und die Aufzeichnung speichern.*

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

**Homebrew** — der einfachste Weg:

```sh
brew install --cask siliconscope
```

Oder das DMG holen: **[⬇ Neuestes DMG herunterladen](https://github.com/kennss/SiliconScope/releases/latest)** und:

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
  *thermal-throttled* / *memory-pressured*), gemessen an der Speicherbandbreiten-Obergrenze
  des jeweiligen Chips — beantwortet: „Was bremst mein lokales LLM gerade?"
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


### Mehr von Calida Lab

Datenschutzorientierte, geräteinterne Software — hauptsächlich für Apple Silicon:

- **[SpectaLing](https://spectaling.calidalab.ai/)** — geräteinterne Transkription + Live-Übersetzung & Simultandolmetschen (Mac/iPad). Eine datenschutzfreundliche MacWhisper-Alternative.
- **[SpectArk](https://spectark.calidalab.ai/)** — versionierte inkrementelle Backups für macOS: sichert in dem Moment, in dem sich eine Datei ändert.
- **[SnowChat](https://snowchat.calidalab.ai/)** — Ende-zu-Ende-verschlüsselter Messenger auf unserer eigenen Signal-Protokoll-Bibliothek.
- **[SnowClaw](https://snowclaw.calidalab.ai/)** — eine Referenzarchitektur für datenschutzwahrende agentische KI (Arbeitspapier).

**→ [www.calidalab.ai](https://www.calidalab.ai/)** · [@kennss](https://github.com/kennss)


Vorschläge zur Verbesserung der Übersetzung sind jederzeit willkommen — bitte einen PR einreichen.
