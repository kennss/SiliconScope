// Landing copy for both locales. Keys mirror the section structure in Landing.astro.
export type Lang = 'en' | 'ko';

export const REPO = 'https://github.com/kennss/SiliconScope';
export const RELEASES_LATEST = 'https://github.com/kennss/SiliconScope/releases/latest';
export const SPECTALO = 'https://spectalo.calidalab.ai';

/// Press coverage, newest first. Kept here rather than inline so both locales link the same
/// articles and only the lead-in sentence is translated.
export const PRESS = [
  { name: 'OWC Rocket Yard', href: 'https://eshop.macsales.com/blog/99094-siliconscope-improves-upon-macos-activity-monitor-with-apple-silicon-insights/' },
  { name: 'AAPL Ch.', href: 'https://applech2.com/archives/20260620-siliconscope-apple-silicon-mac-system-monitor.html' },
  { name: 'ifun.de', href: 'https://www.ifun.de/siliconscope-ueberwacht-apple-ki-neural-engine-und-speicher-in-echtzeit-282222/' },
];

export const STRINGS = {
  en: {
    nav: { features: 'Features', privacy: 'Privacy', download: 'Download' },
    hero: {
      title: 'See what your Apple Silicon is really doing.',
      sub: 'A sudoless macOS monitor with first-class ANE, Media Engine, and memory-bandwidth tracking — the signals Activity Monitor and btop don’t show. Menu bar and full dashboard. New in 4.0: watch your other machines too — headless Macs and Linux GPU boxes, in the same window.',
      download: 'Download for Apple Silicon',
      github: 'View on GitHub',
      badges: ['Free', 'Open source · MIT', 'No sudo', 'macOS 14+'],
      press: 'Featured on',
    },
    features: [
      { tag: 'New in 4.0 · Fleet', title: 'Your other machines, in the same dashboard',
        body: 'A headless Mac mini, a Linux GPU box, a cloud instance — run a small agent there and it joins this dashboard over an encrypted, paired connection. Remote Macs keep the full treatment, Neural Engine included; a Linux/NVIDIA box gets a GPU-centric view with VRAM holders and loaded Ollama models. One line to install, one paste to pair.',
        img: '/img/fleet.png' },
      { tag: 'Menu-bar cockpit', title: 'Your whole Mac in one glyph',
        body: 'The combined SiliconScope menu-bar item: live CPU / GPU / ANE / Media / memory bars plus bandwidth, and a dropdown with six color-matched 60-second trends, top processes, and the live workload verdict.',
        img: '/img/menubar-cockpit.png' },
      { tag: 'ANE · Media · Bandwidth', title: 'The metrics others hide',
        body: 'First-class Neural Engine activity — measured, not guessed from power, and live even on macOS 27 — plus Media Engine throughput and unified-memory bandwidth split into CPU / GPU / Media / ANE: the real bottleneck signal for on-device AI and video.',
        img: '/img/menubar-gpu.png' },
      { tag: 'AI workload', title: 'Bandwidth-bound or compute-bound?',
        body: 'A live verdict for your local LLM — bandwidth-bound or compute-bound — read against your chip’s spec bandwidth ceiling, plus a one-click tokens/sec + tokens-per-watt benchmark.',
        img: '/img/benchmark.png' },
    ],
    gallery: {
      title: 'Pin any metric to its own item',
      sub: 'CPU · GPU · Memory · Disks · Network · Sensors · Battery — each with a live glyph and a rich, iStat-style dropdown. Toggle any of them from the ⬚ on its dashboard card (or in Settings).',
      items: [
        { img: '/img/cpu.png', label: 'CPU — E/P cores, frequency, temp, top processes' },
        { img: '/img/menubar-gpu.png', label: 'GPU / Media / Neural — GPU, GPU memory, ANE, Media + 4-line trend' },
        { img: '/img/memory.png', label: 'Memory — pressure, app/cached, swap, page rates' },
        { img: '/img/menubar-disk.png', label: 'Disks — local & network volumes, free space, live read/write' },
        { img: '/img/menubar-network.png', label: 'Network — per-interface IP & state, up/down with peaks' },
        { img: '/img/menubar-sensors.png', label: 'Sensors — per-unit temperatures & fans' },
        { img: '/img/menubar-battery.png', label: 'Battery — health, cycles, power draw' },
      ],
    },
    privacy: { title: 'Nothing leaves your Mac',
      body: '100% sudoless and offline by design — no telemetry, no analytics, no outbound calls. Open source, Developer-ID signed and Apple-notarized, and it updates itself.' },
    download: { title: 'Download', button: 'Download for Apple Silicon', source: 'or build from source →',
      brew: 'or install with Homebrew',
      note: 'macOS 14+ on Apple Silicon. Opens with no Gatekeeper prompt, then auto-updates.' },
    footer: { tagline: 'An Apple Silicon system monitor by Calida Lab.', other: 'Also from Calida Lab: Spectalo' },
  },
  ko: {
    nav: { features: '기능', privacy: '프라이버시', download: '다운로드' },
    hero: {
      title: 'Apple Silicon, 그 속까지 들여다보다',
      sub: 'Activity Monitor도 btop도 보여 주지 않는 ANE(Neural Engine), 미디어 엔진, 메모리 대역폭까지 sudo 없이 봅니다. 메뉴바에서도, 전체 대시보드에서도 볼 수 있습니다. 4.0부터는 헤드리스 Mac이나 Linux GPU 박스 같은 다른 기계도 같은 창에서 함께 봅니다.',
      download: 'Apple Silicon용 다운로드',
      github: 'GitHub에서 보기',
      badges: ['무료', '오픈소스 · MIT', 'sudo 불필요', 'macOS 14+'],
      press: '소개된 곳',
    },
    features: [
      { tag: '4.0 · Fleet', title: '다른 기계도 같은 대시보드에서',
        body: '헤드리스 Mac mini, 책상 밑 Linux GPU 박스, 빌려 쓰는 클라우드 인스턴스에 작은 에이전트를 띄우면 암호화된 페어링 연결로 이 대시보드에 들어옵니다. 원격 Mac은 Neural Engine까지 로컬과 똑같이 보이고, Linux·NVIDIA 박스는 GPU 위주 화면에 VRAM을 잡고 있는 프로세스와 올라와 있는 Ollama 모델까지 보여 줍니다. 설치는 명령어 한 줄, 페어링은 링크 붙여 넣기 한 번이면 끝납니다.',
        img: '/img/fleet.png' },
      { tag: '메뉴바 콕핏', title: 'Mac 전체를 메뉴바 아이콘 하나로',
        body: 'SiliconScope 메뉴바 아이템 하나에 CPU·GPU·ANE·미디어·메모리 막대와 대역폭이 실시간으로 나옵니다. 드롭다운을 열면 색을 맞춘 60초 추세 그래프 여섯 개, 상위 프로세스, 지금 무엇이 병목인지 알려 주는 판정이 함께 보입니다.',
        img: '/img/menubar-cockpit.png' },
      { tag: 'ANE · 미디어 · 대역폭', title: '다른 모니터에는 없는 지표',
        body: 'Neural Engine 활동은 전력으로 짐작하지 않고 직접 재며, macOS 27에서도 실시간으로 보입니다. 미디어 엔진 처리량과 CPU·GPU·미디어·ANE별 메모리 대역폭까지 보여 주니, 온디바이스 AI나 영상 작업에서 실제 병목이 어디인지 알 수 있습니다.',
        img: '/img/menubar-gpu.png' },
      { tag: 'AI 워크로드', title: '대역폭이 병목일까, 연산이 병목일까',
        body: '로컬 LLM의 병목이 메모리 대역폭인지 연산인지, 칩의 대역폭 한계를 기준으로 실시간으로 판정합니다. 버튼 한 번으로 초당 토큰 수와 와트당 토큰 수도 잴 수 있습니다.',
        img: '/img/benchmark.png' },
    ],
    gallery: {
      title: '지표마다 메뉴바 아이템 하나씩',
      sub: 'CPU, GPU, 메모리, 디스크, 네트워크, 센서, 배터리 중 원하는 것을 메뉴바에 띄우고, 드롭다운에서 자세히 볼 수 있습니다. 각 카드의 ⬚ 버튼이나 설정에서 켜고 끕니다.',
      items: [
        { img: '/img/cpu.png', label: 'CPU — E/P 코어, 주파수, 온도, 상위 프로세스' },
        { img: '/img/menubar-gpu.png', label: 'GPU / 미디어 / Neural — GPU, GPU 메모리, ANE, 미디어와 추세 그래프 4개' },
        { img: '/img/memory.png', label: '메모리 — 메모리 압력, 앱/캐시 메모리, 스왑, 페이지 입출력' },
        { img: '/img/menubar-disk.png', label: '디스크 — 로컬·네트워크 볼륨, 여유 공간, 실시간 읽기/쓰기' },
        { img: '/img/menubar-network.png', label: '네트워크 — 인터페이스별 IP·상태, 업/다운로드와 피크' },
        { img: '/img/menubar-sensors.png', label: '센서 — 부위별 온도와 팬' },
        { img: '/img/menubar-battery.png', label: '배터리 — 배터리 성능, 충전 횟수, 전력' },
      ],
    },
    privacy: { title: '데이터는 Mac 밖으로 나가지 않습니다',
      body: '처음부터 sudo 없이, 인터넷 연결 없이 동작하도록 만들었습니다. 사용 기록 수집도 분석도 외부 통신도 없습니다. 소스는 공개되어 있고, Developer ID로 서명해 Apple 공증을 받았으며, 업데이트는 앱이 알아서 받습니다.' },
    download: { title: '다운로드', button: 'Apple Silicon용 다운로드', source: '또는 소스에서 직접 빌드 →',
      brew: '또는 Homebrew로 설치',
      note: 'macOS 14 이상, Apple Silicon Mac이 필요합니다. Gatekeeper 경고 없이 바로 열리고, 이후 업데이트는 앱이 알아서 받습니다.' },
    footer: { tagline: 'Calida Lab이 만든 Apple Silicon 시스템 모니터.', other: 'Calida Lab의 다른 앱 · Spectalo' },
  },
} as const;
