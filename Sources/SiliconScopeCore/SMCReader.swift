//
//  File:      SMCReader.swift
//  Created:   2026-06-08
//  Updated:   2026-06-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Minimal read-only Apple SMC client (sudoless) for fan speed and other
//             scalar keys. Opens the AppleSMC IOService and reads keys via the fixed
//             kernel ABI: readKeyInfo (cmd 9) then readBytes (cmd 5).
//  Notes:     SMCKeyData layout MUST match the kernel struct exactly (do not reorder).
//             Decodes flt/ui8/ui16/ui32/fpe2. Read-only — never writes SMC keys.
//
import Foundation
import IOKit

final class SMCReader {
    private typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct SMCLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
    private struct SMCKeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }

    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCLimitData()
        var keyInfo = SMCKeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private let kernelIndex: UInt32 = 2
    private let cmdReadKeyInfo: UInt8 = 9
    private let cmdReadBytes: UInt8 = 5
    private let cmdReadIndex: UInt8 = 8
    private var connection: io_connect_t = 0

    init?() {
        let matching = IOServiceMatching("AppleSMC")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return nil }
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return nil }
        let result = IOServiceOpen(device, mach_task_self_, 0, &connection)
        IOObjectRelease(device)
        guard result == kIOReturnSuccess, connection != 0 else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    /// Reads a scalar SMC key as Double, or nil if missing/unsupported type.
    func readDouble(_ key: String) -> Double? {
        guard let (type, bytes) = readKey(key) else { return nil }
        switch type {
        case "ui8 ": return Double(bytes[0])
        case "ui16": return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32": return Double((UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3]))
        case "flt ": return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "fpe2": return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        default: return nil
        }
    }

    /// Enumerates all `flt`-typed "T…" temperature keys present on this Mac.
    /// Run once (it scans every SMC key); then read the returned keys each sample.
    func temperatureKeys() -> [String] {
        guard let count = readDouble("#KEY"), count > 0 else { return [] }
        var keys: [String] = []
        for index in 0..<Int(count) {
            var input = SMCKeyData()
            input.data8 = cmdReadIndex
            input.data32 = UInt32(index)
            var output = SMCKeyData()
            guard call(&input, &output) else { continue }
            let key = string(from: output.key)
            guard key.hasPrefix("T") else { continue }
            if let (type, _) = readKey(key), type == "flt " { keys.append(key) }
        }
        return keys
    }

    /// Enumerates EVERY "T…" key present (any data type), with its SMC type FourCC and decoded
    /// value when the type is a scalar we understand. Unlike `temperatureKeys()` (flt-only,
    /// keys only), this is the full picture — for mapping sensors on chips not in the curated
    /// table, where a missing rail (e.g. an M4 Max core) may sit under an unknown key/type.
    /// One-shot diagnostic (scans every SMC key).
    func allTemperatureKeys() -> [(key: String, type: String, celsius: Double?)] {
        guard let count = readDouble("#KEY"), count > 0 else { return [] }
        var out: [(String, String, Double?)] = []
        for index in 0..<Int(count) {
            var input = SMCKeyData()
            input.data8 = cmdReadIndex
            input.data32 = UInt32(index)
            var output = SMCKeyData()
            guard call(&input, &output) else { continue }
            let key = string(from: output.key)
            guard key.hasPrefix("T"), let (type, _) = readKey(key) else { continue }
            let v = readDouble(key)
            let valid = (v.map { $0 > 5 && $0 < 130 } ?? false) ? v : nil
            out.append((key, type.trimmingCharacters(in: .whitespaces), valid))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: - Private

    private func readKey(_ key: String) -> (type: String, bytes: [UInt8])? {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = fourCharCode(key)
        input.data8 = cmdReadKeyInfo
        guard call(&input, &output) else { return nil }

        let dataSize = output.keyInfo.dataSize
        let dataType = string(from: output.keyInfo.dataType)
        guard dataSize > 0 else { return nil }

        input = SMCKeyData()
        input.key = fourCharCode(key)
        input.keyInfo.dataSize = dataSize
        input.data8 = cmdReadBytes
        output = SMCKeyData()
        guard call(&input, &output) else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0) }
        return (dataType, bytes)
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> Bool {
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection, kernelIndex,
            &input, MemoryLayout<SMCKeyData>.stride,
            &output, &outputSize
        )
        return result == kIOReturnSuccess
    }

    private func fourCharCode(_ string: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in string.utf8.prefix(4) { code = (code << 8) | UInt32(byte) }
        return code
    }

    private func string(from code: UInt32) -> String {
        let chars = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(bytes: chars, encoding: .ascii) ?? ""
    }
}
