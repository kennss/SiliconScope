//
//  File:      TokenRateAttachTests.swift
//  Created:   2026-09-13
//  Updated:   2026-09-13
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in the rule that stops SiliconScope from launching LM Studio (#60): the log
//             stream may only be attached on a fresh observation that LM Studio is already up.
//  Notes:     `lms log stream` STARTS LM Studio in service mode when it is not running, so every
//             case here is really asking "would this spawn `lms`?". The stale-observation case is
//             the one that shipped broken twice — first as an unconditional spawn with a 15 s
//             retry, then as a level-triggered re-attach that rebuilt the same loop.
//
import XCTest
@testable import SiliconScopeCore

final class TokenRateAttachTests: XCTestCase {

    /// The original bug: nothing observed, and we spawned anyway.
    func testNeverAttachesWhenLMStudioIsNotRunning() {
        XCTAssertFalse(TokenRateWatcher.shouldAttach(running: false, wasRunning: false, attached: false))
        XCTAssertFalse(TokenRateWatcher.shouldAttach(running: false, wasRunning: true, attached: false))
    }

    /// The app coming up while LM Studio is already running is the one case that should attach.
    func testAttachesOnceWhenLMStudioAppears() {
        XCTAssertTrue(TokenRateWatcher.shouldAttach(running: true, wasRunning: false, attached: false))
    }

    /// Steady state must not spawn a second stream every sample.
    func testDoesNotReattachWhileAlreadyStreaming() {
        XCTAssertFalse(TokenRateWatcher.shouldAttach(running: true, wasRunning: true, attached: true))
    }

    /// ⚠️ The resurrection loop, precisely. LM Studio has just been killed: the stream is already
    /// gone (`attached: false`) but the process scan has not caught up, so `running` is still true.
    /// A level test attaches here, spawns `lms`, and LM Studio comes back — which is what made it
    /// impossible to quit. The edge requirement is what refuses.
    func testStaleObservationAfterAQuitDoesNotResurrectIt() {
        XCTAssertFalse(TokenRateWatcher.shouldAttach(running: true, wasRunning: true, attached: false))
    }

    /// Only after the scan reports it gone, and it genuinely starts again, may we re-attach.
    func testReattachesAfterAFullDownUpCycle() {
        XCTAssertFalse(TokenRateWatcher.shouldAttach(running: false, wasRunning: true, attached: false))
        XCTAssertTrue(TokenRateWatcher.shouldAttach(running: true, wasRunning: false, attached: false))
    }

    /// Detaching stays level-triggered: the instant it is not observed, let the stream go.
    func testDetachesAsSoonAsItIsNotObserved() {
        XCTAssertTrue(TokenRateWatcher.shouldDetach(running: false, attached: true))
        XCTAssertFalse(TokenRateWatcher.shouldDetach(running: true, attached: true))
        XCTAssertFalse(TokenRateWatcher.shouldDetach(running: false, attached: false))
    }

    /// The observation itself — reading this, not asking `lms`, is what keeps us from launching it.
    func testIsLMStudioRunningReflectsObservedProcesses() {
        var s = AIRuntimeSample()
        XCTAssertFalse(s.isLMStudioRunning)
        s.processes = [
            .init(pid: 1, kind: .ollama, displayName: "Ollama", cpuPercent: 0, memoryBytes: 1 << 30, embeddedPort: nil),
        ]
        XCTAssertFalse(s.isLMStudioRunning)
        s.processes.append(
            .init(pid: 2, kind: .lmStudio, displayName: "LM Studio", cpuPercent: 0, memoryBytes: 2 << 30, embeddedPort: nil)
        )
        XCTAssertTrue(s.isLMStudioRunning)
    }
}
