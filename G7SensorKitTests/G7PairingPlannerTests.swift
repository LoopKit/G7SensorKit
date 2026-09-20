//
//  G7PairingPlannerTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import G7SensorKit

class G7PairingPlannerTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    func testFirstCandidateBecomesCurrent() {
        var planner = G7PairingPlanner()
        XCTAssertNil(planner.currentCandidate)
        XCTAssertTrue(planner.addCandidate(id: a, name: "DXCM01", isPhoneSlotHeld: false))
        XCTAssertEqual(planner.currentCandidate?.id, a)
        XCTAssertEqual(planner.nextAttemptNumber, 1)
    }

    func testDuplicateDiscoveryIsIgnored() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "DXCM01", isPhoneSlotHeld: false)
        XCTAssertFalse(planner.addCandidate(id: a, name: "DXCM01", isPhoneSlotHeld: false))
        XCTAssertEqual(planner.candidates.count, 1)
    }

    /// A sensor another phone is using will reject us, and rejections count
    /// toward a lockout, so free sensors are tried first.
    func testFreeSensorsAreTriedBeforeHeldOnes() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "held", isPhoneSlotHeld: true)
        planner.addCandidate(id: b, name: "free", isPhoneSlotHeld: false)
        // `a` was already current when `b` arrived, so it keeps its turn...
        XCTAssertEqual(planner.currentCandidate?.name, "held")

        // ...but among the untried tail, free ones jump ahead of held ones.
        planner.addCandidate(id: c, name: "held2", isPhoneSlotHeld: true)
        let d = UUID()
        planner.addCandidate(id: d, name: "free2", isPhoneSlotHeld: false)
        XCTAssertEqual(planner.candidates.map(\.name), ["held", "free", "free2", "held2"])
    }

    func testHeldCandidateIsDeferredNotDropped() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "free", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "held", isPhoneSlotHeld: true)
        XCTAssertEqual(planner.abandonCurrentCandidate(reason: "rejected"), .advanceToNext)
        XCTAssertEqual(planner.currentCandidate?.name, "held", "a held sensor may be our own; it still gets a turn")
    }

    func testOrdinaryFailuresRetryThenAdvance() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "B", isPhoneSlotHeld: false)

        for attempt in 1 ..< G7PairingPlanner.attemptsPerCandidate {
            XCTAssertEqual(planner.nextAttemptNumber, attempt)
            XCTAssertEqual(planner.recordFailure(), .retryCurrent)
        }
        XCTAssertEqual(planner.recordFailure(), .advanceToNext)
        XCTAssertEqual(planner.currentCandidate?.id, b)
        XCTAssertEqual(planner.nextAttemptNumber, 1, "attempts reset for the next candidate")
    }

    /// A rejection is terminal for that sensor, and retrying it invites the
    /// lockout, so it is dropped on the first one.
    func testRejectionAbandonsImmediately() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "B", isPhoneSlotHeld: false)

        XCTAssertEqual(planner.abandonCurrentCandidate(reason: "rejected"), .advanceToNext)
        XCTAssertEqual(planner.currentCandidate?.id, b)
    }

    func testGiveUpAfterLastCandidate() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "A", isPhoneSlotHeld: false)

        guard case .giveUp(let reason) = planner.abandonCurrentCandidate(reason: "wrong code") else {
            return XCTFail("expected give up")
        }
        XCTAssertTrue(reason.contains("A: wrong code"), "the user should learn why each sensor was skipped")
        XCTAssertNil(planner.currentCandidate)
    }

    func testGiveUpWithNoCandidatesExplainsNothingWasFound() {
        var planner = G7PairingPlanner()
        guard case .giveUp(let reason) = planner.recordFailure() else {
            return XCTFail("expected give up")
        }
        XCTAssertTrue(reason.lowercased().contains("no sensor"))
    }

    /// The held slot expires after ~15 minutes of silence, so a repeat
    /// advertisement can move a deferred candidate forward.
    func testSlotUpdateReordersUntriedCandidates() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "current", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "held", isPhoneSlotHeld: true)
        planner.addCandidate(id: c, name: "free", isPhoneSlotHeld: false)
        XCTAssertEqual(planner.candidates.map(\.name), ["current", "free", "held"])

        XCTAssertTrue(planner.updateSlot(id: b, isPhoneSlotHeld: false))
        XCTAssertEqual(planner.candidates.map(\.name), ["current", "free", "held"], "discovery order holds within a class")

        XCTAssertTrue(planner.updateSlot(id: c, isPhoneSlotHeld: true))
        XCTAssertEqual(planner.candidates.map(\.name), ["current", "held", "free"])

        XCTAssertFalse(planner.updateSlot(id: c, isPhoneSlotHeld: true), "no change reports no change")
    }

    func testSlotUpdateNeverMovesTheCurrentCandidate() {
        var planner = G7PairingPlanner()
        planner.addCandidate(id: a, name: "current", isPhoneSlotHeld: false)
        planner.addCandidate(id: b, name: "other", isPhoneSlotHeld: false)
        planner.updateSlot(id: a, isPhoneSlotHeld: true)
        XCTAssertEqual(planner.currentCandidate?.id, a, "a candidate mid-handshake must stay put")
    }
}
