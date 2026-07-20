// Landing copy for both locales. Keys mirror the section structure in Landing.astro.
export type Lang = 'en' | 'ko';

export const REPO = 'https://github.com/kennss/SiliconScope';
export const RELEASES_LATEST = 'https://github.com/kennss/SiliconScope/releases/latest';
export const SPECTALO = 'https://spectalo.calidalab.ai';

export const STRINGS = {
  en: {
    nav: { features: 'Features', privacy: 'Privacy', download: 'Download' },
    hero: {
      title: 'See what your Apple Silicon is really doing.',
      sub: 'A sudoless macOS monitor with first-class ANE, Media Engine, and memory-bandwidth tracking — the signals Activity Monitor and btop don’t show. Menu bar and full dashboard.',
      download: 'Download for Apple Silicon',
      github: 'View on GitHub',
      badges: ['Free', 'Open source · MIT', 'No sudo', 'macOS 14+'],
    },
    features: [
      { tag: 'Menu-bar cockpit', title: 'Your whole Mac in one glyph',
        body: 'The combined SiliconScope menu-bar item: live CPU / GPU / ANE / Media / memory bars plus bandwidth, and a dropdown with six color-matched 60-second trends, top processes, and the live workload verdict.',
        img: '/img/menubar-cockpit.png' },
      { tag: 'ANE · Media · Bandwidth', title: 'The metrics others hide',
        body: 'First-class Neural Engine and Media Engine power, plus unified-memory bandwidth with the CPU / GPU / Media split — the real bottleneck signal for on-device AI and video.',
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
      sub: 'Activity Monitor도 btop도 보여주지 않는 ANE(뉴럴 엔진)·미디어 엔진·메모리 대역폭까지, sudo 없이 살펴봅니다. 메뉴바와 풀 대시보드, 두 가지 모습으로.',
      download: 'Apple Silicon용 다운로드',
      github: 'GitHub에서 보기',
      badges: ['무료', '오픈소스 · MIT', 'sudo 불필요', 'macOS 14+'],
    },
    features: [
      { tag: '메뉴바 콕핏', title: '맥 전체가 글리프 하나에',
        body: '통합 SiliconScope 메뉴바 아이템 하나에 CPU·GPU·ANE·미디어·메모리 막대와 대역폭이 실시간으로 담깁니다. 드롭다운을 열면 색을 맞춘 60초 추세 여섯 개와 상위 프로세스, 그리고 지금 무엇이 발목을 잡는지 일러 주는 판정이 펼쳐집니다.',
        img: '/img/menubar-cockpit.png' },
      { tag: 'ANE · 미디어 · 대역폭', title: '아무도 보여주지 않던 지표',
        body: 'Neural Engine과 미디어 엔진의 전력, 그리고 CPU·GPU·미디어로 나뉜 통합 메모리 대역폭까지 — 온디바이스 AI와 영상 작업의 진짜 병목을 짚어 냅니다.',
        img: '/img/menubar-gpu.png' },
      { tag: 'AI 워크로드', title: '대역폭에 묶였나, 연산에 묶였나',
        body: '로컬 LLM이 지금 대역폭에 묶였는지 연산에 묶였는지, 칩의 대역폭 스펙 한계에 비추어 실시간으로 가려냅니다. 버튼 한 번이면 초당 토큰 수와 와트당 토큰 효율까지 재어 줍니다.',
        img: '/img/benchmark.png' },
    ],
    gallery: {
      title: '지표마다, 저마다의 자리',
      sub: 'CPU·GPU·메모리·디스크·네트워크·센서·배터리 — 무엇이든 메뉴바에 띄우고, 풍부한 드롭다운으로 깊이 들여다봅니다. 각 카드의 ⬚(또는 설정)에서 켜고 끕니다.',
      items: [
        { img: '/img/cpu.png', label: 'CPU — E/P 코어, 주파수, 온도, 상위 프로세스' },
        { img: '/img/menubar-gpu.png', label: 'GPU / 미디어 / 뉴럴 — GPU, GPU 메모리, ANE, 미디어 + 4선 추세' },
        { img: '/img/memory.png', label: '메모리 — 압력, App/캐시, 스왑, 페이지 속도' },
        { img: '/img/menubar-disk.png', label: '디스크 — 로컬·네트워크 볼륨, 여유 공간, 실시간 읽기/쓰기' },
        { img: '/img/menubar-network.png', label: '네트워크 — 인터페이스별 IP·상태, 업/다운로드와 피크' },
        { img: '/img/menubar-sensors.png', label: '센서 — 유닛별 온도와 팬' },
        { img: '/img/menubar-battery.png', label: '배터리 — 건강도, 사이클, 전력' },
      ],
    },
    privacy: { title: 'Mac을 떠나지 않는 데이터',
      body: '설계 단계부터 sudo 없이, 오프라인으로 동작합니다. 텔레메트리도 분석도, 바깥으로 나가는 통신도 없습니다. 오픈소스이며 Developer ID 서명과 Apple 공증을 거쳤고, 업데이트는 스스로 받아옵니다.' },
    download: { title: '다운로드', button: 'Apple Silicon용 다운로드', source: '또는 소스에서 직접 빌드 →',
      brew: '또는 Homebrew로 설치',
      note: 'macOS 14 이상의 Apple Silicon. 게이트키퍼 경고 없이 바로 열리고, 이후로는 스스로 업데이트합니다.' },
    footer: { tagline: 'Calida Lab이 빚어낸 Apple Silicon 시스템 모니터.', other: 'Calida Lab의 또 다른 앱 · Spectalo' },
  },
} as const;
