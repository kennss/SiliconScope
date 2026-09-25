# SiliconScope

[English](README.md) · **Deutsch** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

[![Website](https://img.shields.io/badge/website-siliconscope.calidalab.ai-5c9efa)](https://siliconscope.calidalab.ai)
[![Release](https://img.shields.io/github/v/release/kennss/SiliconScope?color=2b9348)](https://github.com/kennss/SiliconScope/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kennss/SiliconScope/total?color=2b9348)](https://github.com/kennss/SiliconScope/releases)
[![License: MIT](https://img.shields.io/github/license/kennss/SiliconScope)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-111)

[![#2 Swift Repository Of The Day](https://trendshift.io/api/badge/trendshift/repositories/57307/daily?language=Swift)](https://trendshift.io/repositories/57307)

**Ein Systemmonitor für Apple Silicon, der ohne sudo auskommt**: ein natives SwiftUI-Dashboard
**und** eine vollständige Menüleisten-Suite. Er erfasst auch das, was weder die Aktivitätsanzeige
noch Terminal-Monitore zeigen: **ANE (Neural Engine)**, **Media Engine** und **Speicherbandbreite**.

Den Anstoß gab der Wunsch, zu *sehen*, wie On-Device-KI- und Medien-Workloads die Beschleuniger
von Apple Silicon auslasten. Daraus ist inzwischen ein Monitor für den täglichen Einsatz geworden,
der iStat Menus ersetzen kann.

**Seit Version 4.0 behält SiliconScope auch deine *anderen* Rechner im Blick.** Ob Mac mini ohne
Bildschirm, Linux-Rechner mit GPU unter dem Schreibtisch oder gemietete Cloud-Instanz: Dort läuft
ein kleiner Agent, und die Maschine erscheint über eine verschlüsselte, gekoppelte Verbindung im
selben Dashboard. Entfernte Macs werden dabei vollständig dargestellt, **Neural Engine inklusive**.

*Darüber berichtet haben [ifun.de](https://www.ifun.de/siliconscope-ueberwacht-apple-ki-neural-engine-und-speicher-in-echtzeit-282222/) (DE), [OWC Rocket Yard](https://eshop.macsales.com/blog/99094-siliconscope-improves-upon-macos-activity-monitor-with-apple-silicon-insights/) (US) und [AAPL Ch.](https://applech2.com/archives/20260620-siliconscope-apple-silicon-mac-system-monitor.html) (JP).*

![SiliconScope-Dashboard unter On-Device-KI-Last](docs/img/dashboard.png)

*Ein M1 Max unter macOS 27 bei echter On-Device-KI-Last: [Spectalo](https://spectalo.calidalab.ai/) führt seine Core-ML-Modelle aus. Der Workload-Klassifikator meldet **ANE (CoreML)**, die Neural Engine ist **zu 100 % aktiv und bewegt 16 GB/s**. Dieser Wert beruht auf der gemessenen Aktivzeit der Cluster (Residency) und bleibt deshalb auch unter macOS 27 aktuell, wo die Energiezähler dieses Chips nur etwa alle halbe Stunde aktualisiert werden. Die GPU läuft mit 100 % bei 36 W, die Speicherbandbreite liegt bei 306 GB/s, die Obergrenze des Chips bei 400 GB/s (**bandbreitenlimitiert**). **system 105 W** in der Kopfzeile ist die Leistungsaufnahme des gesamten Macs. Farbe setzt das Dashboard nur dort ein, wo etwas Aufmerksamkeit verlangt, hier Rot für CPU- und GPU-Temperaturen über 90 °C; alles andere bleibt neutral. Die Leiste am unteren Rand ist **Replay** (seit 3.0): Jede Metrik wird aufgezeichnet, sodass du eine Sitzung wie mit einem Festplattenrekorder zurückspulen kannst.*

### Menüleiste: jede Metrik, wie bei iStat

Jede Karte lässt sich als eigenes Menüleisten-Element anheften (**CPU · GPU · Speicher · Netzwerk · SSD · Sensoren · Akku**), jeweils mit laufend aktualisierter Mini-Anzeige und ausführlichem Dropdown. Für jedes Element legst du die **Darstellung** fest (Balken · Verlaufsgraph · zwei Zeilen · Einzelwert · Symbol) und bestimmst, welche Messwerte es anzeigt. Eine Metrik kann so sogar doppelt auftauchen: CPU als Balken *und* als Graph. Das alles ohne sudo.

![Die Menüleisten-Suite pro Metrik](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU- / Media- / Neural-Dropdown">
  <img src="docs/img/menubar-sensors.png" width="250" alt="Temperaturen pro Kern">
  <img src="docs/img/menubar-cockpit.png" width="250" alt="Kombiniertes SS-Cockpit — Workload, alle Engines, Trends, Top-Prozesse">
</p>

*Die ausführlichsten Dropdowns. **GPU / Media / Neural**: GPU, GPU-Speicher, ANE und Media als Live-Anzeigen, dazu ein 60-Sekunden-Verlauf mit 4 Linien. **Sensoren**: Temperaturen je Komponente aus echten **E-Core- / P-Core- / GPU- / Memory**-Sensoren (SMC-Schlüssel, für jede Chipgeneration von M1–M5 eigens zusammengestellt, sonst HID als Fallback). **SS-Cockpit**: der ganze Rechner in einem Dropdown mit Workload-Einschätzung, allen Engines, 60-Sekunden-Verläufen und den Top-Prozessen.*

![Geschwindigkeit und Effizienz lokaler Modelle messen](docs/img/benchmark.png)

*Benchmark auf Abruf: „Measure tok/s" startet eine kurze Generierung, misst Dekodiergeschwindigkeit und Energieeffizienz des Modells (**tokens/sec · tokens/Wh**) und speichert die Werte je Modell.*

> 📊 **Schon tok/s auf deinem Mac gemessen?** [Trag deine Werte in den Discussions ein](https://github.com/kennss/SiliconScope/discussions/5). Eine gemeinsam gepflegte Tabelle je Chip hilft anderen, die passende Hardware zu finden.

## Neu in 4.0

### 🛰 Fleet: deine anderen Rechner im selben Dashboard

Sobald auf einem entfernten Rechner ein Agent läuft, erscheint er in der Seitenleiste **Devices**
neben **This Mac**. Rechner im lokalen Netz findet SiliconScope per mDNS automatisch, IP-Adressen
musst du nicht eintragen.

![Die Fleet-Übersicht — alle Rechner auf einem Bildschirm](docs/img/fleet-overview.png)

*Drei Rechner auf einen Blick. Jede Kachel zeigt **GPU + VRAM** und **CPU + RAM** auf jeweils
einer gemeinsamen Achse, auf Apple Silicon zusätzlich **ANE + Speicherbandbreite**. Jedes
Metrik-Kürzel ist in der Farbe seiner Linie eingefärbt, eine Legende ist daher überflüssig. In der
untersten Zeile steht die **von der Runtime gemessene Generierungsrate** und wie lange die Messung
zurückliegt: Der Ubuntu-Rechner kam auf **262 tok/s**, beide Macs auf **28 tok/s**. Beschreibt
ein Wert nicht mehr den aktuellen Zustand, wird er blasser dargestellt. This Mac ist immer die
erste Kachel.*

- **Ein entfernter Mac erscheint in genau demselben Dashboard wie der lokale**: E-/P-Kerne, GPU,
  **ANE**, Media, Speicherbandbreite, Leistungsaufnahme, Lüfter. Meines Wissens zeigt kein anderes
  Tool die **Neural Engine eines entfernten Macs** an.
- **Ein Linux-Rechner mit NVIDIA-Karte bekommt eine auf die GPU zugeschnittene Ansicht**: Auslastung,
  VRAM, Leistungsaufnahme im Verhältnis zum Limit der Karte, Temperatur, welche Prozesse VRAM belegen,
  und geladene **Ollama**-Modelle. E-Kerne dichtet sie einer 3090 nicht an.

![Ein ferner Mac im vollen lokalen Dashboard, ANE inklusive](docs/img/fleet-remote-mac.png)

*Ein M1 Air ohne Bildschirm, von einem anderen Mac aus betrachtet: **4E+4P**-Kerne, GPU/Media/**ANE
(geschätzt)** und die tatsächliche Speicheraufteilung (**wired 1,0 / active 2,7 / compressed 0,5 GB**,
Speicherdruck 19 %). Die Sensoren melden korrekt **fanless**, statt einen Lüfterwert zu erfinden.
Karten, die ein Agent über das Netzwerk nicht füllen kann, fallen weg; vorgetäuscht wird nichts.*

![Eine Linux-GPU-Kiste mit VRAM-Haltern und Ollama-Modellen](docs/img/fleet-linux.png)

*Dieselbe App, eine andere Rechnerklasse: ein Rechner mit RTX 3090 im Leerlauf. Zu sehen sind
**34 / 390 W** im Verhältnis zum Limit der Karte, **0,5 / 24 GB VRAM** und welcher Prozess ihn belegt
(das Python von ComfyUI mit **0,2 GB**), die Kapazität beider Laufwerke (seit 4.4) und die
Ollama-Modelle auf der Platte, grau dargestellt, weil keines geladen ist. E-Kerne und ANE fehlen,
denn der Rechner hat beides nicht.*

Jede Verbindung ist **TLS-verschlüsselt und per Token authentifiziert**. Beim ersten
Verbindungsaufbau pinnt der Viewer das Zertifikat des Agents (TOFU). Ein Agent mit neuem Schlüssel
oder ein untergeschobener Agent wird deshalb abgelehnt, statt stillschweigend als vertrauenswürdig
zu gelten.

![This Mac unverändert, mit der neuen Devices-Seitenleiste](docs/img/fleet-sidebar.png)

*Wer nur einen Mac nutzt, merkt davon nichts: Das Dashboard ist dasselbe, lediglich ergänzt um die
einklappbare Seitenleiste **Devices**. Klappst du sie ein, sieht alles exakt so aus wie in 3.x.*

#### Einen Agent installieren

Eine URL für alle Plattformen; unter Linux richtet sie einen systemd-Dienst ein, unter macOS einen
LaunchAgent:

```sh
curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh | sh
```

Der Mac-Agent braucht **kein sudo**, die Installation läuft daher auch per `ssh` ohne Rückfragen
durch. Am Ende gibt jeder Installer eine einzige `sscope://pair…`-Zeile aus. Fügst du sie unter
**Add machine…** ein, ist der Rechner in einem Schritt hinzugefügt *und* gekoppelt.

Für einen Mac, an dem du selbst sitzt, brauchst du überhaupt keinen Agent:
**Einstellungen → Share this Mac**.

**Auf einem Intel-Mac** liefert der Agent CPU- und Speicherwerte, also das, was dieser Rechner
tatsächlich zu bieten hat. Die Chip-Metriken fehlen, weil die zugehörige Hardware fehlt: Es gibt
keine Neural Engine, keine Media Engine und weder Unified-Memory-Bandbreite noch Leistungsaufnahme
je Domäne. Diese Werte stammen aus einer Schnittstelle, die nur Apple Silicon bereitstellt. Die App
selbst läuft weiterhin ausschließlich auf Apple Silicon.

**Auf einem Windows-Rechner** liefert der Agent CPU- und Speicherwerte und erfasst eine NVIDIA-Karte
über denselben `nvidia-smi`-Weg wie unter Linux: Auslastung, VRAM, Temperatur, Leistungsaufnahme und
VRAM je Prozess. Windows kennt keinen Load Average; das Feld bleibt deshalb leer, statt eine
erfundene Zahl anzuzeigen. Die Laufwerkskapazität wird unter Windows noch nicht erfasst. Einen
Installer als Einzeiler gibt es dafür noch nicht: Baue den Agent mit `GOOS=windows go build ./agent`
und führe ihn als geplante Aufgabe aus.

> **Mac ohne Bildschirm?** Aktiviere zuerst **Systemeinstellungen → Allgemein → Freigabe →
> Entfernte Anmeldung**, sonst lässt sich darauf nichts installieren. **Außerhalb deines LAN**
> (Tailscale, VPN, Cloud) reicht mDNS nicht hin; füge den Rechner dann unter **Add machine…** per
> Adresse hinzu. Tailscale oder ein SSH-Tunnel ist dabei besser, als den Port öffentlich freizugeben.

> **Ist der Blockierungsmodus aktiv oder blockiert die Firewall alle eingehenden Verbindungen,** erreicht der
> Viewer den Agent nicht: Der Mac taucht gar nicht erst auf oder zeigt einen roten Punkt mit einem TLS- oder
> Hostnamen-Fehler. Öffne auf diesem Mac **Systemeinstellungen → Netzwerk → Firewall → Optionen**, schalte
> **Alle eingehenden Verbindungen blockieren** aus, prüfe, ob SiliconScope (bzw. `sscope-agent-mac`) zugelassen
> ist, und starte SiliconScope danach neu. Herausgefunden hat das
> [@progenitor-amborella](https://github.com/progenitor-amborella) in [#63](https://github.com/kennss/SiliconScope/issues/63).

**Einen Agent entfernen:** Führe auf dem betreffenden Rechner denselben Installer mit `--uninstall` aus.

```sh
curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh | sh -s -- --uninstall
```

Der Befehl stoppt den Dienst und löscht Binary, Token, Zertifikat und Keychain. Anschließend
klickst du auf dem Viewer-Mac in der Fleet-Seitenleiste mit der rechten Maustaste auf den Rechner
und wählst **Forget pairing**.

## Neu in 3.0

### 🧠 Prozess-Inspektor: Metriken je Prozess, ohne sudo

Ein Klick auf einen Prozess öffnet den Inspektor. Er zeigt, was die Aktivitätsanzeige nicht kann:
**CPU (P/E-Aufteilung) · IPC · Leistung pro Prozess (W) · Speicher · Disk**, jeweils mit
Live-Sparkline. Dazu kommt das eine Signal, das sonst kein Tool pro Prozess ausweist: der
**Neural-Engine-Speicher**. So siehst du genau, welche App die ANE nutzt und wie viel Speicher sie
dort belegt.

![Prozess-Inspektor — CPU, IPC, Leistung und Neural-Engine-Speicher pro Prozess](docs/img/inspector.png)

*Rechts läuft live eine App für On-Device-Transkription: 65 % CPU bei **2,43 IPC**, **0,64 W** und
**762 MB Neural-Engine-Speicher**. Diesen ANE-Speicherbedarf zeigt kein anderer Monitor pro Prozess
an. Beschleuniger, die macOS nur systemweit meldet (GPU / ANE-Leistung / Media / Bandbreite), sind
entsprechend gekennzeichnet; erfundene Werte pro Prozess gibt es nicht.*

### ⏺ Aufzeichnen & Abspielen: ein Rekorder für die Messwerte deines Macs

Nach einem Klick auf **Record** schreibt SiliconScope jede Metrik (CPU, GPU, ANE, Media, Bandbreite,
Leistung, Sensoren, Prozesse) in eine kompakte `.ssrec`-Datei. Anschließend spielst du das gesamte
Dashboard mit **Play / Pause / Scrub / Geschwindigkeit** ab und erwischst so auch eine Lastspitze,
die längst vorbei war, als du hingeschaut hast. Alle Daten bleiben auf deinem Mac. Eine Aufzeichnung
lässt sich exportieren, um sie weiterzugeben oder später mit einem anderen Durchlauf zu vergleichen.

![Die Replay-Leiste — Play / Pause / Einzelschritt, Scrubben, Geschwindigkeit und Save](docs/img/replaybar.png)

*Die Replay-Leiste: Play / Pause / Einzelschritt, in der Zeitleiste spulen, Geschwindigkeit ändern und die Aufzeichnung speichern.*

## Warum ich es gebaut habe

SiliconScope entstand, während ich an **[Spectalo](https://spectalo.calidalab.ai/)** arbeitete,
einem Videoplayer mit On-Device-KI. Um zu sehen, wie er den Chip tatsächlich auslastet, hatte ich
ständig zwei Monitore gleichzeitig offen, und keiner passte wirklich:

- **asitop / NeoAsitop** lieferten zwar die Werte auf Chip-Ebene, aber die TUI war unansehnlich
  und detailarm.
- **btop** war schön und informationsdicht, zeigte aber ausgerechnet das nicht, was ich brauchte:
  **ANE (Neural Engine), Media Engine und Speicherbandbreite**.

Beide Fenster nebeneinander offen zu halten, war mühsam und kostete Bildschirmfläche. Zunächst
wollte ich NeoAsitop und btop forken, um die Lücken zu stopfen. Dann habe ich mich entschieden, es
gleich richtig zu machen: **eine einzige native, gut lesbare Oberfläche**, die die für Apple Silicon
spezifischen Signale zeigt und auch ohne Vorliebe fürs Terminal verständlich ist.

Also habe ich es gebaut.

Als es fertig war, war klar, dass ich mich endlich von **iStat Menus** verabschieden konnte, das
jahrelang mein Systemmonitor für den Alltag gewesen war. Dafür steht **2.0**: die Version, mit der
SiliconScope die vollständige Menüleisten-Suite, Sensoren je Komponente und die Anzeige der
Akkugesundheit bekam, die es brauchte, um iStat zu ersetzen.

## Installation

Am einfachsten geht es mit **Homebrew**:

```sh
brew install --cask siliconscope
```

Alternativ lädst du das DMG herunter: **[⬇ Neuestes DMG herunterladen](https://github.com/kennss/SiliconScope/releases/latest)**. Danach:

1. Das heruntergeladene `SiliconScope-*.dmg` öffnen
2. **SiliconScope** in den Ordner **Programme** ziehen
3. Die App starten

Die App ist mit einer Developer ID signiert und **von Apple notarisiert**, Gatekeeper warnt beim
Öffnen also nicht. Voraussetzung sind **macOS 14+ · Apple Silicon**. Updates installiert die App
danach **selbst** (Sparkle); ein DMG musst du also nie wieder von Hand herunterladen.

> **Vorabversionen von macOS (Betas) werden nicht unterstützt.** Für dieses Projekt gibt es genau
> einen Mac, und auf dem läuft die finale Version. Was in einer Developer-Beta passiert, lässt sich
> hier also weder nachstellen noch überprüfen. Meldungen aus Betas sind trotzdem willkommen und haben
> schon geholfen: SiliconScope liest private IOReport-Schnittstellen, die Apple zwischen einzelnen
> Builds umbenennt, und eine früh entdeckte Umbenennung ist behoben, bevor sie alle trifft.
> Korrekturen erscheinen aber erst zur finalen macOS-Version, nicht für einen Beta-Seed.

Du willst selbst bauen? Die Anleitung steht unter [Build & run](README.md#build--run) im englischen README.

## Hauptfunktionen

- **Prozess-Inspektor** *(seit 3.0)*: nimmt einen einzelnen Prozess in den Fokus und zeigt CPU
  (P/E-Aufteilung), IPC, Leistung pro Prozess **(W)**, Speicher, Disk und **Neural-Engine-Speicher**,
  alles ohne sudo
- **Aufzeichnen & Abspielen** *(seit 3.0)*: zeichnet jede Metrik in eine `.ssrec`-Datei auf und
  spielt das Dashboard wie ein Festplattenrekorder mit **Play / Pause / Scrub / Geschwindigkeit** ab
- **AI-Workload-Ansicht**: ein Engpass-Klassifikator (*bandwidth-bound* / *compute-bound* /
  *thermal-throttled* / *memory-pressured*), der sich an der spezifizierten maximalen
  Speicherbandbreite des jeweiligen Chips orientiert. Er beantwortet die Frage: „Was bremst mein
  lokales LLM gerade aus?"
- **Trennung von E- und P-Kernen**: Auslastung je Cluster plus echte DVFS-Frequenzen
- **GPU**: Auslastung, Leistungsaufnahme, Frequenz
- **ANE & Media Engine**: Aktivität der Neural Engine (gemessene Cluster-Residency),
  Leistungsaufnahme und Speicherverkehr, dazu die Bandbreite der Medien-Codecs; hier hebt sich
  SiliconScope von anderen Monitoren ab
- **Speicherbandbreite**: CPU / GPU / Media / ANE / gesamt in GB/s (bei lokalen LLMs das
  entscheidende Signal für Engpässe)
- **Speicher**: gestapelter Balken aus Wired / Active / Compressed / Free, dazu Warnungen von macOS
  bei hohem **Speicherdruck**
- **Netzwerk** ↑/↓ und **Festplatte** (Lesen/Schreiben, freier Platz) mit Live-Graphen
- **Temperaturen je Komponente**: echte **E-Core- / P-Core- / GPU- / Memory**-Sensoren über
  SMC-Schlüssel, die für jede Generation eigens zusammengestellt sind (M1–M5, sonst HID-Fallback),
  Lüfterdrehzahl (RPM), thermischer Druck und **Erkennung von GPU-Throttling** (ob der Takt unter
  thermischem Druck unter dem gleitenden Spitzenwert bleibt)
- **Akku**: Ladezustand, **Akkugesundheit in %, Ladezyklen, Zustand** (AppleSmartBattery)
- **Leistungsaufnahme**: je Domäne CPU / GPU / ANE / DRAM / SoC sowie Akku
- **Prozesse**: sortieren, filtern, beenden und **per Klick inspizieren** (scrollbar innerhalb der
  Karte)
- **Menüleisten-Elemente je Metrik**: CPU / GPU / Speicher / Netzwerk / SSD / Sensoren / Akku lassen
  sich jeweils als eigene Anzeige mit Dropdown anheften (plus die kombinierte „SS"-Cockpit-Anzeige)
- **Automatische Updates**: eingebauter Sparkle-Updater, „Check for Updates…" im Menü
- **Kein `sudo` nötig.**

## Verwandtes Projekt

**[Spectalo](https://spectalo.calidalab.ai/)** ist ein schöner Videoplayer, der Untertitel und
Übersetzungen per KI **On-Device** erzeugt (Whisper + Apple Intelligence). Er stammt ebenfalls von
Calida Lab, und SiliconScope ist bei der Arbeit daran entstanden. Die offene Beta über TestFlight
ist kostenlos, und es gilt derselbe Grundsatz: Nichts verlässt dein Gerät.

<a href="https://spectalo.calidalab.ai/"><img src="docs/img/spectalo-library.jpg" width="520" alt="Spectalo — On-Device-KI-Videoplayer"></a>

---

👉 Die Build-Anleitung, wie das Ganze ohne sudo funktioniert (IOReport / SMC / HID), und
technische Hintergründe findest du im **[englischen README](README.md)**.


### Mehr von Calida Lab

Software, die lokal auf dem Gerät läuft und den Datenschutz an erste Stelle setzt, überwiegend für Apple Silicon:

- **[SpectaLing](https://spectaling.calidalab.ai/)**: Transkription direkt auf dem Gerät, dazu Live-Übersetzung und Simultandolmetschen (Mac/iPad). Eine datenschutzfreundliche Alternative zu MacWhisper.
- **[SpectArk](https://spectark.calidalab.ai/)**: versionierte Echtzeit-Backups für die Mac-Ordner, die dir wichtig sind. Jede Änderung ist binnen Sekunden gesichert, mit Wiederherstellungspunkten wie bei Time Machine, auf jeder beliebigen Festplatte oder jedem NAS.
- **[SpectaBooks](https://spectabooks.calidalab.ai/)**: ein Reader für die Bücher, die du bereits besitzt. Text, EPUB, PDF und Comics aus eigenen Ordnern, iCloud Drive oder Google Drive; die Leseposition wird zwischen iPhone, iPad und Mac synchronisiert, Vorlesen und Übersetzen laufen direkt auf dem Gerät.
- **[SnowChat](https://snowchat.calidalab.ai/)**: Ende-zu-Ende-verschlüsselter Messenger auf Basis unserer eigenen Bibliothek für das Signal-Protokoll.
- **[SnowClaw](https://snowclaw.calidalab.ai/)**: eine Referenzarchitektur für agentische KI, die die Privatsphäre wahrt (Arbeitspapier).

**→ [www.calidalab.ai](https://www.calidalab.ai/)** · [@kennss](https://github.com/kennss)


Verbesserungsvorschläge für die deutsche Fassung sind jederzeit willkommen, am liebsten als PR.
