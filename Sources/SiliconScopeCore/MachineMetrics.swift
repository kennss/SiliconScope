//
//  File:      MachineMetrics.swift
//  Created:   2026-07-21
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The source-agnostic fleet metric schema — the boundary the Mac aggregator consumes
//             for every remote machine, regardless of how the data arrives. Mirrors the Go Linux
//             agent's JSON (agent/main.go) so its output decodes directly, and carries Apple-Silicon
//             extras (E/P split, ANE/Media, per-requestor bandwidth, power breakdown, fans) that a
//             Mac agent fills in. Keeping this UI-independent (Core) is what lets one view render
//             both a Linux GPU box and a headless Mac.
//  Notes:     JSON keys are camelCase matching the property names, so no CodingKeys are needed.
//             Apple-only fields are Optional so Linux JSON (which omits them) still decodes — the
//             UI shows a slot only when its value is present. Byte fields are absolute bytes; `ts`
//             is unix ms. `kind` is "linux" | "mac". All fleet types are `Fleet*`-prefixed to avoid
//             colliding with the local live-monitor snapshot types.
//
import Foundation

public struct MachineMetrics: Codable, Sendable, Identifiable, Equatable {
    public var id: String { machineId }
    public let machineId: String
    public let hostname: String
    public let os: String
    public let kind: String            // "linux" | "mac"
    public let agentVersion: String
    public let ts: Int64               // unix ms
    public let cpu: FleetCPU
    public let memory: FleetMemory
    @DefaultEmpty public var gpus: [FleetGPU]
    public let llm: FleetLLM?
    public let apple: FleetApple?      // Apple-Silicon extras; nil on Linux
    // Local-filesystem capacity. OPTIONAL: a pre-disks agent omits the key and still decodes
    // (arrives nil), and the UI renders nothing rather than an empty card.
    public let disks: [FleetDisk]?
    // Thermal pressure and temperatures. On the COMMON block, like `cpu.model`: every Mac has a
    // thermal pressure level, whatever its architecture. OPTIONAL: nil from an agent that predates
    // it, which the viewer renders as "unknown" rather than as a calm "nominal" it never read.
    public let thermal: FleetThermal?
    // Disk and network throughput. Common block: the APIs behind it are not Apple-Silicon ones.
    // OPTIONAL, and its absence is what hides the Network & Disk card on a remote page — a card of
    // zeros would read as an idle machine rather than as one that did not say.
    public let io: FleetIO?
    // The last three things This Mac shows and a remote page did not (#56): which AI runtimes are
    // running and what they have loaded, the busiest processes, and the battery. Each OPTIONAL and
    // each independent — an absent block is "not reported", which the viewer must never render as
    // "none" (no runtime, no processes, no battery).
    public let aiRuntime: FleetAIRuntime?
    public let processes: [FleetProcess]?
    public let battery: FleetBattery?

    public init(machineId: String, hostname: String, os: String, kind: String, agentVersion: String,
                ts: Int64, cpu: FleetCPU, memory: FleetMemory, gpus: [FleetGPU],
                llm: FleetLLM? = nil, apple: FleetApple? = nil, disks: [FleetDisk]? = nil,
                thermal: FleetThermal? = nil, io: FleetIO? = nil, aiRuntime: FleetAIRuntime? = nil,
                processes: [FleetProcess]? = nil, battery: FleetBattery? = nil) {
        self.machineId = machineId; self.hostname = hostname; self.os = os; self.kind = kind
        self.agentVersion = agentVersion; self.ts = ts; self.cpu = cpu; self.memory = memory
        self.gpus = gpus; self.llm = llm; self.apple = apple; self.disks = disks
        self.thermal = thermal; self.io = io; self.aiRuntime = aiRuntime
        self.processes = processes; self.battery = battery
    }
}

public struct FleetDisk: Codable, Sendable, Equatable {
    public let mount: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let fsType: String?

    public init(mount: String, totalBytes: Int64, freeBytes: Int64, fsType: String? = nil) {
        self.mount = mount; self.totalBytes = totalBytes; self.freeBytes = freeBytes; self.fsType = fsType
    }

    /// Used is DERIVED, never transmitted — the agent sends only total + free.
    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    public var usedFraction: Double {
        totalBytes > 0 ? Double(min(usedBytes, totalBytes)) / Double(totalBytes) : 0
    }
}

/// The AI runtimes running on a machine, and what their local API reports having loaded.
///
/// Enum-like fields travel as Strings and are parsed tolerantly on arrival, for the reason given on
/// `FleetThermal.pressure`: a Swift String enum throws on a value it does not know, and one new
/// runtime kind would otherwise take the whole machine offline in the viewer.
public struct FleetAIRuntime: Codable, Sendable, Equatable {
    @DefaultEmpty public var processes: [FleetRuntimeProcess]
    /// The runtime API's answer, when the machine asked. nil when it did not — the viewer says
    /// "not reported", never "no model loaded".
    public let api: FleetRuntimeAPI?

    public init(processes: [FleetRuntimeProcess], api: FleetRuntimeAPI?) {
        self.processes = processes; self.api = api
    }
}

public struct FleetRuntimeProcess: Codable, Sendable, Equatable {
    public let pid: Int32
    public let kind: String            // AIRuntimeKind raw value
    public let cpuPercent: Double
    public let memoryBytes: Int64

    public init(pid: Int32, kind: String, cpuPercent: Double, memoryBytes: Int64) {
        self.pid = pid; self.kind = kind; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
    }
}

public struct FleetRuntimeAPI: Codable, Sendable, Equatable {
    public let status: String          // RuntimeAPISample.Status raw value
    public let source: String?         // RuntimeAPISample.Source raw value
    @DefaultEmpty public var models: [FleetRuntimeModel]
    public let tokensPerSec: Double?

    public init(status: String, source: String?, models: [FleetRuntimeModel], tokensPerSec: Double?) {
        self.status = status; self.source = source; self.models = models; self.tokensPerSec = tokensPerSec
    }
}

public struct FleetRuntimeModel: Codable, Sendable, Equatable {
    public let name: String
    public let sizeBytes: Int64
    public let sizeVRAMBytes: Int64
    public let parameterSize: String?
    public let quantization: String?
    public let contextLength: Int?

    public init(name: String, sizeBytes: Int64, sizeVRAMBytes: Int64, parameterSize: String?,
                quantization: String?, contextLength: Int?) {
        self.name = name; self.sizeBytes = sizeBytes; self.sizeVRAMBytes = sizeVRAMBytes
        self.parameterSize = parameterSize; self.quantization = quantization; self.contextLength = contextLength
    }
}

/// One process, as the Processes card lists it.
///
/// ⚠️ The NAME only — never the executable path or argv. A command line is where people put
/// tokens and passwords (`--api-key …`), and a fleet payload is read by another machine; the local
/// card has both because it is this machine's own business.
public struct FleetProcess: Codable, Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: Int64

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: Int64) {
        self.pid = pid; self.name = name; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
    }
}

/// Battery state. Sent only by a machine that has one, so its absence reads as "no battery" only
/// for an agent recent enough to have sent `aiRuntime` too; older agents simply did not say.
public struct FleetBattery: Codable, Sendable, Equatable {
    public let percent: Double
    public let isCharging: Bool
    public let isPluggedIn: Bool

    public init(percent: Double, isCharging: Bool, isPluggedIn: Bool) {
        self.percent = percent; self.isCharging = isCharging; self.isPluggedIn = isPluggedIn
    }
}

/// Disk and network throughput in bytes per second, as rates the agent derived from its own
/// counters over its own elapsed time. Each field is optional on its own, so an agent that can
/// read one side and not the other says so instead of sending a zero for the side it cannot see.
public struct FleetIO: Codable, Sendable, Equatable {
    public let diskReadBytesPerSec: Double?
    public let diskWriteBytesPerSec: Double?
    public let netDownBytesPerSec: Double?
    public let netUpBytesPerSec: Double?

    public init(diskReadBytesPerSec: Double?, diskWriteBytesPerSec: Double?,
                netDownBytesPerSec: Double?, netUpBytesPerSec: Double?) {
        self.diskReadBytesPerSec = diskReadBytesPerSec; self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.netDownBytesPerSec = netDownBytesPerSec; self.netUpBytesPerSec = netUpBytesPerSec
    }
}

/// Thermal state of a machine: the kernel's pressure level plus the temperatures the agent read.
///
/// Scalars and groups both travel, and the scalars are NOT recomputed from the groups on arrival.
/// `cpuCelsius` is the product of the agent's own rules — which sensors count as die points, the
/// plausibility floor that throws out a stuck key (#57) — and a viewer re-deriving it would apply
/// its own version of those rules to someone else's machine.
public struct FleetThermal: Codable, Sendable, Equatable {
    /// `ThermalSample.Pressure` raw value: nominal | fair | serious | critical.
    ///
    /// ⚠️ A String on the wire, parsed tolerantly on arrival. A Swift String enum THROWS on a value
    /// it does not know, and a throw here would take the whole machine offline in the viewer — one
    /// newer macOS pressure level away from the #33 failure.
    public let pressure: String?
    public let cpuCelsius: Double?
    public let cpuMaxCelsius: Double?
    public let gpuCelsius: Double?
    public let batteryCelsius: Double?
    @DefaultEmpty public var sensors: [FleetSensorGroup]

    public init(pressure: String?, cpuCelsius: Double? = nil, cpuMaxCelsius: Double? = nil,
                gpuCelsius: Double? = nil, batteryCelsius: Double? = nil,
                sensors: [FleetSensorGroup] = []) {
        self.pressure = pressure; self.cpuCelsius = cpuCelsius; self.cpuMaxCelsius = cpuMaxCelsius
        self.gpuCelsius = gpuCelsius; self.batteryCelsius = batteryCelsius; self.sensors = sensors
    }
}

/// One sensor category as the machine reports it. `category` is `SensorCategory`'s raw value,
/// kept a String for the same reason `FleetThermal.pressure` is.
public struct FleetSensorGroup: Codable, Sendable, Equatable {
    public let category: String
    @DefaultEmpty public var sensors: [FleetSensor]

    public init(category: String, sensors: [FleetSensor]) {
        self.category = category; self.sensors = sensors
    }
}

public struct FleetSensor: Codable, Sendable, Equatable {
    public let rawName: String      // the SMC key or HID product name, e.g. "Tp01" / "PMU tdie3"
    public let name: String         // display name
    public let celsius: Double

    public init(rawName: String, name: String, celsius: Double) {
        self.rawName = rawName; self.name = name; self.celsius = celsius
    }
}

public struct FleetCPU: Codable, Sendable, Equatable {
    public let cores: Int
    public let usagePercent: Double
    public let loadAvg1: Double
    // Apple E/P cluster split (nil on Linux, which reports one blended usagePercent).
    public let eUsagePercent: Double?
    public let pUsagePercent: Double?
    public let eFreqMHz: Double?
    public let pFreqMHz: Double?
    public let eCores: Int?          // Apple E/P core counts (nil on Linux)
    public let pCores: Int?
    /// What this machine calls its CPU, e.g. "Apple M1 Max" or "Intel(R) Core(TM) i9-9880H".
    ///
    /// ⚠️ Lives here, on the common block, because every machine has one. It used to travel only
    /// inside `apple.chip`, so the moment an Intel Mac correctly stopped sending that block it had
    /// nowhere left to say its own name and the viewer fell back to printing "Apple Silicon" at it
    /// (#56). A name is not an Apple-Silicon-only fact.
    public let model: String?
    /// The cluster's DVFS steps (MHz, ascending) — the chip's clock CEILING, which is what a
    /// throttle is measured against.
    ///
    /// ⚠️ Before these were sent, the viewer built a remote topology whose "DVFS table" was the
    /// single CURRENT clock. The ceiling was therefore always the present reading, a clock can
    /// never sit below itself, and CPU throttling on a remote Mac was structurally unreportable.
    public let eFreqsMHz: [Double]?
    public let pFreqsMHz: [Double]?
    /// What the chip calls its clusters. Not always "E"/"P": an M5 Max reports "Super" for its top
    /// tier, and a remote page that relabelled it would disagree with the machine's own.
    public let eLevelName: String?
    public let pLevelName: String?

    public init(cores: Int, usagePercent: Double, loadAvg1: Double,
                eUsagePercent: Double? = nil, pUsagePercent: Double? = nil,
                eFreqMHz: Double? = nil, pFreqMHz: Double? = nil,
                eCores: Int? = nil, pCores: Int? = nil, model: String? = nil,
                eFreqsMHz: [Double]? = nil, pFreqsMHz: [Double]? = nil,
                eLevelName: String? = nil, pLevelName: String? = nil) {
        self.cores = cores; self.usagePercent = usagePercent; self.loadAvg1 = loadAvg1
        self.eUsagePercent = eUsagePercent; self.pUsagePercent = pUsagePercent
        self.eFreqMHz = eFreqMHz; self.pFreqMHz = pFreqMHz
        self.eCores = eCores; self.pCores = pCores; self.model = model
        self.eFreqsMHz = eFreqsMHz; self.pFreqsMHz = pFreqsMHz
        self.eLevelName = eLevelName; self.pLevelName = pLevelName
    }
}

public struct FleetMemory: Codable, Sendable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64
    // Apple VM breakdown (nil on Linux and on pre-1.1 Mac agents). Without it a remote Mac's Memory
    // card had to render Wired/Compressed/App/Cached/Swap as fabricated zeros; an instrument must not
    // invent numbers. used / free / pressure% and every stacked-bar fraction are DERIVED from
    // wired+active+compressed, so sending those three restores all of them at once.
    public let wiredBytes: Int64?
    public let activeBytes: Int64?
    public let compressedBytes: Int64?
    public let appMemoryBytes: Int64?
    public let cachedFilesBytes: Int64?
    public let swapUsedBytes: Int64?
    public let swapTotalBytes: Int64?
    public let pressure: String?        // MemorySample.Pressure raw value: normal | warning | critical

    public init(totalBytes: Int64, usedBytes: Int64, availableBytes: Int64,
                wiredBytes: Int64? = nil, activeBytes: Int64? = nil, compressedBytes: Int64? = nil,
                appMemoryBytes: Int64? = nil, cachedFilesBytes: Int64? = nil,
                swapUsedBytes: Int64? = nil, swapTotalBytes: Int64? = nil, pressure: String? = nil) {
        self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.availableBytes = availableBytes
        self.wiredBytes = wiredBytes; self.activeBytes = activeBytes; self.compressedBytes = compressedBytes
        self.appMemoryBytes = appMemoryBytes; self.cachedFilesBytes = cachedFilesBytes
        self.swapUsedBytes = swapUsedBytes; self.swapTotalBytes = swapTotalBytes; self.pressure = pressure
    }
}

public struct FleetGPUProc: Codable, Sendable, Equatable {
    public let pid: Int
    public let name: String
    public let vramBytes: Int64

    public init(pid: Int, name: String, vramBytes: Int64) {
        self.pid = pid; self.name = name; self.vramBytes = vramBytes
    }
}

public struct FleetGPU: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let name: String
    public let driver: String
    public let vramTotalBytes: Int64
    public let vramUsedBytes: Int64
    public let utilizationPercent: Double
    public let temperatureC: Double
    public let powerDrawW: Double
    public let powerLimitW: Double
    @DefaultEmpty public var processes: [FleetGPUProc]
    public let freqMHz: Double?         // GPU clock; nil when the agent doesn't report it

    public init(index: Int, name: String, driver: String, vramTotalBytes: Int64, vramUsedBytes: Int64,
                utilizationPercent: Double, temperatureC: Double, powerDrawW: Double, powerLimitW: Double,
                processes: [FleetGPUProc], freqMHz: Double? = nil) {
        self.index = index; self.name = name; self.driver = driver
        self.vramTotalBytes = vramTotalBytes; self.vramUsedBytes = vramUsedBytes
        self.utilizationPercent = utilizationPercent; self.temperatureC = temperatureC
        self.powerDrawW = powerDrawW; self.powerLimitW = powerLimitW
        self.processes = processes; self.freqMHz = freqMHz
    }

    /// VRAM fraction used (0…1), for a bar.
    public var vramFraction: Double { vramTotalBytes > 0 ? Double(vramUsedBytes) / Double(vramTotalBytes) : 0 }
}

public struct FleetLLMModel: Codable, Sendable, Equatable {
    public let name: String
    public let sizeBytes: Int64

    public init(name: String, sizeBytes: Int64) { self.name = name; self.sizeBytes = sizeBytes }
}

public struct FleetOllama: Codable, Sendable, Equatable {
    public let running: Bool
    @DefaultEmpty public var models: [FleetLLMModel]
    @DefaultEmpty public var loaded: [FleetLLMModel]

    public init(running: Bool, models: [FleetLLMModel], loaded: [FleetLLMModel]) {
        self.running = running; self.models = models; self.loaded = loaded
    }
}

/// A runtime's own count of its own decode rate, as reported by the agent.
///
/// ⚠️ **Measured, and therefore stale.** Every source publishes a rate only for work that has
/// already finished — llama.cpp's gauge covers its last predictions, LM Studio emits one event per
/// completed prediction — so `measuredAt` is not decoration. A rate with no age reads as "right
/// now", and a number from an hour ago presented that way is the same class of claim as a state
/// asserted without its measurement.
///
/// Absent rather than zero when nothing reports one: Ollama exposes no server-side rate at all
/// (its embedded llama-server ships without `--metrics`), and a missing measurement is a different
/// fact from a measured 0 tok/s.
public struct FleetTokenRate: Codable, Sendable, Equatable {
    public let tokensPerSec: Double
    public let source: String            // "llama.cpp" | "lmstudio"
    public let model: String?
    public let measuredAt: Int64         // unix ms
    public let ttftSec: Double?          // time to first token, where the runtime reports it

    public init(tokensPerSec: Double, source: String, model: String?,
                measuredAt: Int64, ttftSec: Double?) {
        self.tokensPerSec = tokensPerSec; self.source = source; self.model = model
        self.measuredAt = measuredAt; self.ttftSec = ttftSec
    }

    public var measuredDate: Date { Date(timeIntervalSince1970: Double(measuredAt) / 1000) }

    /// How long ago the rate was measured. The UI uses this to say "2 min ago" rather than
    /// implying the number is live.
    public var age: TimeInterval { max(0, Date().timeIntervalSince(measuredDate)) }

    /// Runtime name as it should appear in the UI.
    public var sourceLabel: String {
        switch source {
        case "lmstudio":  return "LM Studio"
        case "llama.cpp": return "llama.cpp"
        default:          return source
        }
    }
}

public struct FleetLLM: Codable, Sendable, Equatable {
    public let ollama: FleetOllama?
    public let rate: FleetTokenRate?
    public init(ollama: FleetOllama?, rate: FleetTokenRate? = nil) {
        self.ollama = ollama; self.rate = rate
    }
}

// MARK: - Apple-Silicon extras (Mac agent)

/// Metrics unique to Apple Silicon that have no place in the Linux/NVIDIA shape: the Neural Engine
/// and Media engine, per-requestor memory bandwidth, a full power breakdown, and fan speeds. All
/// present only when `kind == "mac"`.
public struct FleetApple: Codable, Sendable, Equatable {
    public let chip: String            // e.g. "Apple M1 Max"
    public let aneWatts: Double        // Neural Engine power (estimate — no util API exists)
    public let anePeakWatts: Double    // for bar scaling
    public let mediaGBs: Double        // Media engine throughput (GB/s)
    public let mediaPeakGBs: Double
    public let socWatts: Double        // whole-SoC power (sensor or derived sum)
    public let power: FleetPower
    public let bandwidth: FleetBandwidth
    @DefaultEmpty public var fanRPMs: [Double]   // empty on fanless Macs (MacBook Air)
    public let gpuFreqsMHz: [Double]?  // GPU DVFS steps (MHz, ascending)
    /// The agent's decaying observed GPU-clock peak — the GPU throttle's reference. Sent for the
    /// same reason `anePeakWatts` is: it is state accumulated over the agent's own history, which
    /// a viewer polling once a second never sees. nil from an agent that predates it.
    public let gpuClockPeakMHz: Double?

    public init(chip: String, aneWatts: Double, anePeakWatts: Double, mediaGBs: Double,
                mediaPeakGBs: Double, socWatts: Double, power: FleetPower,
                bandwidth: FleetBandwidth, fanRPMs: [Double],
                gpuFreqsMHz: [Double]? = nil, gpuClockPeakMHz: Double? = nil) {
        self.chip = chip; self.aneWatts = aneWatts; self.anePeakWatts = anePeakWatts
        self.mediaGBs = mediaGBs; self.mediaPeakGBs = mediaPeakGBs; self.socWatts = socWatts
        self.power = power; self.bandwidth = bandwidth; self.fanRPMs = fanRPMs
        self.gpuFreqsMHz = gpuFreqsMHz; self.gpuClockPeakMHz = gpuClockPeakMHz
    }

    public var hasFans: Bool { !fanRPMs.isEmpty }
}

public struct FleetPower: Codable, Sendable, Equatable {
    public let cpuWatts: Double
    public let eCpuWatts: Double
    public let pCpuWatts: Double
    public let gpuWatts: Double
    public let aneWatts: Double
    public let dramWatts: Double
    /// How the watts above were measured — `PowerSample.railWindowSeconds`, carried as is: nil
    /// live, > 0 an average over that many seconds, 0 not known yet (macOS 27's slow energy
    /// counters, #65). nil from an agent that predates it, which is what its numbers were.
    public let windowSeconds: Double?
    /// `PowerSample.gpuWindowSeconds`: the GPU's own basis when it is read on a faster clock than
    /// the rails (macOS 27). nil → the GPU shares `windowSeconds`.
    public let gpuWindowSeconds: Double?

    public init(cpuWatts: Double, eCpuWatts: Double, pCpuWatts: Double,
                gpuWatts: Double, aneWatts: Double, dramWatts: Double, windowSeconds: Double? = nil,
                gpuWindowSeconds: Double? = nil) {
        self.cpuWatts = cpuWatts; self.eCpuWatts = eCpuWatts; self.pCpuWatts = pCpuWatts
        self.gpuWatts = gpuWatts; self.aneWatts = aneWatts; self.dramWatts = dramWatts
        self.windowSeconds = windowSeconds; self.gpuWindowSeconds = gpuWindowSeconds
    }
}

public extension FleetApple {
    /// The remote machine's power as a PowerSample — the ONE place the wire becomes the local
    /// type, so a remote page and a fleet tile cannot read the same payload two ways.
    var powerSample: PowerSample {
        var p = PowerSample()
        p.cpuWatts = power.cpuWatts
        p.eCPUWatts = power.eCpuWatts
        p.pCPUWatts = power.pCpuWatts
        p.gpuWatts = power.gpuWatts
        p.aneWatts = power.aneWatts
        p.dramWatts = power.dramWatts
        p.measuredSocWatts = socWatts
        p.railWindowSeconds = power.windowSeconds
        p.gpuWindowSeconds = power.gpuWindowSeconds
        return p
    }
}

public struct FleetBandwidth: Codable, Sendable, Equatable {
    public let cpuGBs: Double
    public let gpuGBs: Double
    public let mediaGBs: Double
    public let otherGBs: Double
    public let totalGBs: Double
    public let isEstimated: Bool
    public let totalPeakGBs: Double?   // engine's decaying observed peak, for 0…1 scaling (nil on skew)

    public init(cpuGBs: Double, gpuGBs: Double, mediaGBs: Double, otherGBs: Double,
                totalGBs: Double, isEstimated: Bool, totalPeakGBs: Double? = nil) {
        self.cpuGBs = cpuGBs; self.gpuGBs = gpuGBs; self.mediaGBs = mediaGBs
        self.otherGBs = otherGBs; self.totalGBs = totalGBs; self.isEstimated = isEstimated
        self.totalPeakGBs = totalPeakGBs
    }
}
