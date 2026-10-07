//
//  File:      NetworkSamplerTests.swift
//  Created:   2026-10-09
//  Developer: Gabriel-Florin Manaila / IBM
//  Overview:  Tests for NetworkSampler, InterfaceStat, and NetworkSample decoding compatibility.
//
import XCTest
@testable import SiliconScopeCore

final class NetworkSamplerTests: XCTestCase {

    func testNetworkSampleDefaultInitialization() {
        let sample = NetworkSample()
        XCTAssertEqual(sample.downloadBytesPerSec, 0)
        XCTAssertEqual(sample.uploadBytesPerSec, 0)
        XCTAssertTrue(sample.interfaces.isEmpty)
    }

    func testNetworkSampleBackwardCompatibilityDecoding() throws {
        // Older recordings / fleet wire frames omit the "interfaces" key entirely.
        let jsonWithoutInterfaces = """
        {
            "downloadBytesPerSec": 1024000.0,
            "uploadBytesPerSec": 512000.0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(NetworkSample.self, from: jsonWithoutInterfaces)
        XCTAssertEqual(decoded.downloadBytesPerSec, 1024000.0)
        XCTAssertEqual(decoded.uploadBytesPerSec, 512000.0)
        XCTAssertEqual(decoded.interfaces, [])
    }

    func testNetworkSampleFullDecodingAndEncoding() throws {
        let original = NetworkSample()
        var sample = original
        sample.downloadBytesPerSec = 4096.0
        sample.uploadBytesPerSec = 2048.0
        sample.interfaces = [
            InterfaceStat(name: "Wi-Fi", bsdName: "en0", downloadBytesPerSec: 3000.0, uploadBytesPerSec: 1500.0),
            InterfaceStat(name: "Ethernet", bsdName: "en1", downloadBytesPerSec: 1096.0, uploadBytesPerSec: 548.0)
        ]

        let encoded = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(NetworkSample.self, from: encoded)

        XCTAssertEqual(decoded.downloadBytesPerSec, 4096.0)
        XCTAssertEqual(decoded.uploadBytesPerSec, 2048.0)
        XCTAssertEqual(decoded.interfaces.count, 2)
        XCTAssertEqual(decoded.interfaces[0].name, "Wi-Fi")
        XCTAssertEqual(decoded.interfaces[0].bsdName, "en0")
        XCTAssertEqual(decoded.interfaces[0].id, "en0")
        XCTAssertEqual(decoded.interfaces[0].downloadBytesPerSec, 3000.0)
        XCTAssertEqual(decoded.interfaces[0].uploadBytesPerSec, 1500.0)
        XCTAssertEqual(decoded.interfaces[1].name, "Ethernet")
        XCTAssertEqual(decoded.interfaces[1].bsdName, "en1")
    }

    func testVirtualAndTunnelInterfaceClassification() {
        // VPN tunnels and internal interfaces that duplicate traffic or are not physical
        let tunnels = ["utun0", "utun3", "tun0", "tap0", "ipsec0", "ppp0", "gif0", "stf0", "awdl0", "llw0", "p2p0", "anpi0", "dummy0"]
        for iface in tunnels {
            XCTAssertTrue(NetworkSampler.isVirtualOrTunnel(bsdName: iface), "\(iface) should be identified as virtual/tunnel")
        }

        // Physical / standard network interfaces
        let physical = ["en0", "en1", "en2", "bridge0"]
        for iface in physical {
            XCTAssertFalse(NetworkSampler.isVirtualOrTunnel(bsdName: iface), "\(iface) should not be identified as virtual/tunnel")
        }
    }

    func testNetworkSamplerLiveSampleDoesNotCrash() {
        let sampler = NetworkSampler()
        let sample1 = sampler.sample()
        // First tick latches baseline counters and returns 0 rate
        XCTAssertEqual(sample1.downloadBytesPerSec, 0)
        XCTAssertEqual(sample1.uploadBytesPerSec, 0)
        XCTAssertTrue(sample1.interfaces.count <= NetworkSampler.maxInterfaceRows)

        // Give a small pause to measure deltas
        Thread.sleep(forTimeInterval: 0.05)
        let sample2 = sampler.sample()
        XCTAssertGreaterThanOrEqual(sample2.downloadBytesPerSec, 0)
        XCTAssertGreaterThanOrEqual(sample2.uploadBytesPerSec, 0)
        XCTAssertTrue(sample2.interfaces.count <= NetworkSampler.maxInterfaceRows)
    }
}
