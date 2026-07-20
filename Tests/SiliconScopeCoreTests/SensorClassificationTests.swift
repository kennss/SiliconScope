//
//  File:      SensorClassificationTests.swift
//  Created:   2026-06-20
//  Updated:   2026-07-15
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins the pure classification maps: SMC-key → category, raw HID name → friendly
//             label/category, the per-generation curated key catalog, and the bandwidth
//             requestor → bucket map (adapted from NeoAsitop). These are exactly the lookups
//             that silently rot if a prefix is mistyped, so they get regression coverage.
//             Also pins the DIE0-prefixed / split-RD-WR requestor shape observed on macOS 27
//             beta (github.com/kennss/SiliconScope#14) alongside the original bare shape.
//
import XCTest
@testable import SiliconScopeCore

final class SensorClassificationTests: XCTestCase {

    // MARK: - SMC key → category (Apple Silicon prefixes)

    func testSMCCategoryByPrefix() {
        XCTAssertEqual(TemperatureSampler.category(for: "TB0T"), .battery)
        XCTAssertEqual(TemperatureSampler.category(for: "Tp01"), .cpu)
        XCTAssertEqual(TemperatureSampler.category(for: "Tg05"), .gpu)
        XCTAssertEqual(TemperatureSampler.category(for: "Tm02"), .memory)
        XCTAssertEqual(TemperatureSampler.category(for: "TC0D"), .other)
    }

    // MARK: - Raw HID name → friendly label + category

    func testFriendlyHIDClassification() {
        var r = TemperatureSampler.friendlyHID("gas gauge battery")
        XCTAssertEqual(r.category, .battery); XCTAssertEqual(r.label, "Battery")

        r = TemperatureSampler.friendlyHID("NAND CH0 temp")
        XCTAssertEqual(r.category, .memory); XCTAssertEqual(r.label, "NAND CH0 temp")

        r = TemperatureSampler.friendlyHID("PMU tdie3")          // "PMU " stripped → SoC/CPU
        XCTAssertEqual(r.category, .cpu); XCTAssertEqual(r.label, "tdie3")

        XCTAssertEqual(TemperatureSampler.friendlyHID("GPU something").category, .gpu)
    }

    /// Base M1 (MacBook Air) exposes "<unit> MTR Temp Sensor<N>" / "PMGR SOC Die" HID names when
    /// its SMC core keys aren't in the curated table. friendlyHID must clean-label + categorize
    /// these (not show raw "pACC MTR Temp Sensor5"). Names are the real set read on an M1 Air.
    func testFriendlyHIDBaseM1MTRNames() {
        var r = TemperatureSampler.friendlyHID("eACC MTR Temp Sensor0")
        XCTAssertEqual(r.category, .cpu); XCTAssertEqual(r.label, "E-Core 0")
        r = TemperatureSampler.friendlyHID("pACC MTR Temp Sensor5")
        XCTAssertEqual(r.category, .cpu); XCTAssertEqual(r.label, "P-Core 5")
        r = TemperatureSampler.friendlyHID("GPU MTR Temp Sensor4")
        XCTAssertEqual(r.category, .gpu); XCTAssertEqual(r.label, "GPU 4")
        r = TemperatureSampler.friendlyHID("ANE MTR Temp Sensor1")
        XCTAssertEqual(r.category, .other); XCTAssertEqual(r.label, "ANE 1")
        r = TemperatureSampler.friendlyHID("ISP MTR Temp Sensor5")
        XCTAssertEqual(r.category, .other); XCTAssertEqual(r.label, "ISP 5")
        r = TemperatureSampler.friendlyHID("SOC MTR Temp Sensor2")
        XCTAssertEqual(r.category, .other); XCTAssertEqual(r.label, "SoC 2")
        r = TemperatureSampler.friendlyHID("PMGR SOC Die Temp Sensor1")   // disambiguated from SOC MTR
        XCTAssertEqual(r.category, .other); XCTAssertEqual(r.label, "SoC die 1")
        // No trailing digit → no index suffix.
        XCTAssertEqual(TemperatureSampler.friendlyHID("eACC MTR Temp Sensor").label, "E-Core")
        // M1 Max HID names (PMU tdie…) must be UNCHANGED (fall through to the SoC/CPU default).
        XCTAssertEqual(TemperatureSampler.friendlyHID("PMU tdie3").label, "tdie3")
        XCTAssertEqual(TemperatureSampler.friendlyHID("PMU tdie3").category, .cpu)
    }

    /// The FULL raw HID sensor set read on a real MacBook Air M1 (2026-07-01) run through the actual
    /// buildSample→friendlyHID path — proves what the panel will display on base M1 (which reads
    /// 0/18 curated keys). Prints the grouped result and pins the key labels.
    func testBaseM1AirFullHIDSetClassifiesCleanly() {
        let air: [(name: String, celsius: Double)] = [
            ("ANE MTR Temp Sensor1", 30.0), ("GPU MTR Temp Sensor1", 30.0), ("GPU MTR Temp Sensor4", 30.0),
            ("ISP MTR Temp Sensor5", 30.0), ("NAND CH0 temp", 35.0),
            ("PMGR SOC Die Temp Sensor0", 36.9), ("PMGR SOC Die Temp Sensor1", 37.0), ("PMGR SOC Die Temp Sensor2", 36.8),
            ("PMU TP3w", 42.3), ("PMU tcal", 51.9),
            ("PMU tdev1", -21.7), ("PMU tdev3", 36.7), ("PMU tdev8", 36.8),
            ("PMU tdie1", 42.9), ("PMU tdie8", 41.0), ("PMU2 tdie1", 43.6),
            ("SOC MTR Temp Sensor0", 33.2), ("SOC MTR Temp Sensor1", 37.7), ("SOC MTR Temp Sensor2", 35.3),
            ("eACC MTR Temp Sensor0", 32.5), ("eACC MTR Temp Sensor3", 34.0),
            ("gas gauge battery", 32.5),
            ("pACC MTR Temp Sensor2", 35.1), ("pACC MTR Temp Sensor5", 38.5), ("pACC MTR Temp Sensor9", 35.6),
        ]
        let sample = TemperatureSampler.buildSample(fromHID: air.filter { $0.celsius > 5 && $0.celsius < 130 })
        print("\n=== M1 Air panel display (generated from the real HID set via actual code) ===")
        for g in sample.groups {
            print("  [\(g.category.rawValue)]")
            for s in g.sensors { print(String(format: "    %-14@ %5.1f C", s.name as NSString, s.celsius)) }
        }
        let cpu = sample.groups.first { $0.category == .cpu }!.sensors.map(\.name)
        let gpu = sample.groups.first { $0.category == .gpu }!.sensors.map(\.name)
        let other = sample.groups.first { $0.category == .other }!.sensors.map(\.name)
        XCTAssertTrue(cpu.contains("E-Core 0") && cpu.contains("P-Core 5"))   // eACC/pACC → cores
        XCTAssertTrue(gpu.contains("GPU 1") && gpu.contains("GPU 4"))         // GPU MTR → GPU
        XCTAssertTrue(other.contains("ANE 1") && other.contains("SoC 0"))    // ANE/SOC → Other
        XCTAssertTrue(other.contains("SoC die 0"))                           // PMGR SOC Die disambiguated
        XCTAssertFalse(cpu.contains { $0.contains("MTR") })                   // NO raw "MTR" names leak
        // Cores present → the redundant low-level die points are dropped from the CPU group.
        XCTAssertTrue(cpu.allSatisfy { $0.hasPrefix("E-Core") || $0.hasPrefix("P-Core") })
        XCTAssertFalse(cpu.contains { $0.contains("tdie") || $0.contains("tcal") || $0.contains("tdev") })
    }

    // MARK: - Curated per-generation catalog

    func testM1CatalogShape() {
        let m1 = SensorCatalog.curated(for: .m1)
        XCTAssertEqual(m1.filter { $0.category == .cpu }.count, 10)   // 2 E + 8 P
        XCTAssertEqual(m1.filter { $0.category == .gpu }.count, 4)
        XCTAssertEqual(m1.filter { $0.category == .memory }.count, 4)
        // Known anchor keys/names must not drift.
        XCTAssertTrue(m1.contains { $0.key == "Tp01" && $0.name == "P-Core 1" })
        XCTAssertTrue(m1.contains { $0.key == "Tp09" && $0.name == "E-Core 1" })
        XCTAssertTrue(m1.contains { $0.key == "Tg05" && $0.name == "GPU 1" })
    }

    func testEveryKnownGenerationHasCpuAndGpuKeys() {
        for gen in [AppleSiliconGen.m1, .m2, .m3, .m4, .m5] {
            let t = SensorCatalog.curated(for: gen)
            XCTAssertFalse(t.filter { $0.category == .cpu }.isEmpty, "\(gen) missing CPU keys")
            XCTAssertFalse(t.filter { $0.category == .gpu }.isEmpty, "\(gen) missing GPU keys")
        }
    }

    func testUnknownGenerationIsEmpty() {
        XCTAssertTrue(SensorCatalog.curated(for: .unknown).isEmpty)
    }

    // MARK: - Partial-curated HID supplement (e.g. M4 Max reads no Memory key)

    /// When a die exposes only a subset of its generation's curated keys, the intended-but-
    /// absent category is filled from HID — without injecting unrelated HID sensors or
    /// fabricating per-core CPU readings.
    func testSupplementFillsOnlyMissingIntendedCategory() {
        var sample = TemperatureSample()
        sample.cpuCelsius = 40; sample.cpuMaxCelsius = 67; sample.gpuCelsius = 60
        sample.groups = [
            SensorGroup(category: .cpu, sensors: [TempSensor(rawName: "Tp01", name: "P-Core 1", celsius: 40)]),
            SensorGroup(category: .gpu, sensors: [TempSensor(rawName: "Tg0K", name: "GPU 3", celsius: 60)]),
        ]
        let hid: [(name: String, celsius: Double)] = [
            (name: "NAND CH0 temp", celsius: 36),   // → .memory
            (name: "PMU tdie3", celsius: 58),        // → .cpu (must NOT be injected)
            (name: "gas gauge battery", celsius: 35) // → .battery (must NOT be injected)
        ]
        let out = TemperatureSampler.supplement(sample, withHID: hid, categories: [.memory])

        XCTAssertEqual(out.groups.first { $0.category == .memory }?.sensors.first?.name, "NAND CH0 temp")
        XCTAssertEqual(out.groups.first { $0.category == .cpu }?.sensors.count, 1)   // unchanged
        XCTAssertNil(out.groups.first { $0.category == .battery })                   // not requested
        XCTAssertEqual(out.cpuCelsius, 40); XCTAssertEqual(out.gpuCelsius, 60)       // representatives kept
        XCTAssertEqual(out.groups.map(\.category), [.cpu, .gpu, .memory])            // canonical order
    }

    func testSupplementWithNoMatchingHIDLeavesSampleUnchanged() {
        var sample = TemperatureSample()
        sample.groups = [SensorGroup(category: .cpu, sensors: [TempSensor(rawName: "Tp01", name: "P-Core 1", celsius: 40)])]
        let hid: [(name: String, celsius: Double)] = [(name: "PMU tdie3", celsius: 58)]   // .cpu only
        let out = TemperatureSampler.supplement(sample, withHID: hid, categories: [.memory])
        XCTAssertEqual(out.groups.count, 1)
        XCTAssertEqual(out.groups.first?.category, .cpu)
    }

    // MARK: - Bandwidth requestor → bucket (NeoAsitop-adapted map)

    func testBandwidthRequestorMap() {
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DCS"),   .total)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "ECPU0"), .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "PCPU1"), .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "GFX0"),  .gpu)
        for media in ["VENC", "VDEC", "ISP0", "JPG", "JPEG", "PRORES0", "STRM CODEC"] {
            XCTAssertEqual(BandwidthSampler.classify(requestor: media), .media, "\(media)")
        }
        // MSR is explicitly NOT media (matches NeoAsitop); DISP/ANS fall through to other.
        XCTAssertEqual(BandwidthSampler.classify(requestor: "MSR"),  .other)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DISP"), .other)
    }

    // MARK: - Bandwidth requestor map, DIE0-prefixed / per-core shape (github.com/kennss/SiliconScope#14)

    func testBandwidthRequestorMapWithDIE0Prefix() {
        // Apple restructured "AMC Stats" channel names on macOS 27 beta / M3 Max to prepend a
        // chip-id token ("DIE0") ahead of the requestor, and to give per-core requestors a
        // numeric suffix. classify() must see past the prefix without exact-matching cores.
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 ECPU0 DCS"), .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 ECPU1 DCS"), .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 PCPU0 DCS"), .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 GFX DCS"),   .gpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 GFXC DCS"),  .gpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 JPEG DCS"),  .media)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 PRORES DCS"), .media)
        // New macOS 27 requestor families with no chip-id ambiguity still fall through to other.
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 SEP DCS"), .other)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 ATC0 DCS"), .other)
    }

    func testReadWriteSuffixShapes() {
        // The suffix/DCS guard chain in BandwidthSampler.sample() must accept every RD/WR shape
        // observed across macOS 26 (bare) and macOS 27 (split/appended) — see #14 — while the
        // recovered requestor drops exactly the matched suffix, nothing more.
        let cases: [(name: String, requestor: String)] = [
            ("ECPU DCS RD",                       "ECPU DCS"),
            ("ECPU DCS WR",                        "ECPU DCS"),
            ("DIE0 GFX DCS RD/WR",                 "DIE0 GFX DCS"),
            ("DIE0 ATC0 DCS RD/WR/RDWR",           "DIE0 ATC0 DCS"),
            ("DIE0 ECPU0 DCS RD/WR + RD/WR",       "DIE0 ECPU0 DCS"),
        ]
        for c in cases {
            XCTAssertTrue(BandwidthSampler.hasReadWriteToken(c.name), "\(c.name) should be recognized as a byte-traffic channel")
            XCTAssertEqual(BandwidthSampler.stripReadWriteSuffix(c.name), c.requestor, "\(c.name)")
        }
        // Structural counters carry no RD/WR token at all and must be excluded.
        for structural in ["DCS CAS", "DCS RAS", "DCS PD CYCLES", "DCS PD ENTRIES",
                            "DCS SR CYCLES", "DCS SR ENTRIES", "DSID 0 HITS", "DSID 0 MISSES",
                            "PD DURATION(USEC)", "SR DURATION(USEC)"] {
            XCTAssertFalse(BandwidthSampler.hasReadWriteToken(structural), structural)
        }
    }

    // MARK: - Bandwidth requestor map, M5 Max "AMC Stats" names (github.com/kennss/SiliconScope#30)

    func testBandwidthRequestorMapM5MaxNames() {
        // On M5 Max the (currently unsubscribable) "AMC Stats" names gained a "PRIM " prefix and
        // renamed units: CPU "MCPU*"/"PCPU*", video "AVD"/"AVE*" (were VDEC/VENC), "SCODEC" (was
        // STRM CODEC). classify() must see past "PRIM " and map the new units — for whenever
        // "AMC Stats" subscribes again on some chip/OS.
        XCTAssertEqual(BandwidthSampler.classify(requestor: "PRIM MCPU0 DCS"),   .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "PRIM MCPU1 DCS"),   .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "PRIM PCPU0 DCS"),   .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "PRIM GFX DCS"),     .gpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "PRIM GFXC DCS"),    .gpu)
        for media in ["PRIM AVD DCS", "PRIM AVE0 DCS", "PRIM AVE1 DCS", "PRIM SCODEC DCS", "PRIM PRORES1 DCS"] {
            XCTAssertEqual(BandwidthSampler.classify(requestor: media), .media, media)
        }
        XCTAssertEqual(BandwidthSampler.classify(requestor: "PRIM ANE DCS"),     .other)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "PRIM DISPINT DCS"), .other)
    }
}
