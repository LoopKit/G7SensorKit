//
//  G7CGMManagerTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import CoreBluetooth
@testable import G7SensorKit

/// CBCentralManager with the state restoration option raises an exception in a
/// test bundle, which lacks the bluetooth-central background mode.
private class TestBluetoothManager: G7BluetoothManager {
    override func makeCentralManager(queue: DispatchQueue) -> CBCentralManager {
        return CBCentralManager(delegate: self, queue: queue)
    }
}

final class G7CGMManagerTests: XCTestCase {

    private static let sensorID = "DXCM99"

    private func makeManager(gracePeriod: TimeInterval) -> G7CGMManager {
        var state = G7CGMManagerState()
        state.sensorID = Self.sensorID
        state.activatedAt = Date(timeIntervalSinceNow: -54000) // ~15h old session
        let sensor = G7Sensor(sensorID: state.sensorID, bluetoothManager: TestBluetoothManager())
        let manager = G7CGMManager(state: state, sensor: sensor)
        manager.suspectedSessionEndGracePeriod = gracePeriod
        return manager
    }

    private var okGlucoseMessage: G7GlucoseMessage {
        // Same sample as G7GlucoseMessageTests: glucose 138, algorithm state ok
        return G7GlucoseMessage(data: Data(hexadecimalString: "4e00c35501002601000106008a00060187000f")!)!
    }

    /// A grace period in flight when the app is terminated must be re-established
    /// on restore: the deferred scan is an in-memory work item and does not survive.
    /// Restore runs during init, so this goes through the internal init to pick up
    /// the bluetooth seam, and uses the production default grace period.
    private func makeRestoredManager(suspectedSessionEndAt: Date?,
                                     latestReadingTimestamp: Date?) -> G7CGMManager {
        var state = G7CGMManagerState()
        state.sensorID = Self.sensorID
        state.activatedAt = Date(timeIntervalSinceNow: -54000)
        state.suspectedSessionEndAt = suspectedSessionEndAt
        state.latestReadingTimestamp = latestReadingTimestamp

        let sensor = G7Sensor(sensorID: state.sensorID, bluetoothManager: TestBluetoothManager())
        return G7CGMManager(state: state, sensor: sensor)
    }

    func testRestoreForgetsSensorWhenGraceExpiredWhileNotRunning() {
        // Grace started an hour ago, nothing heard since: the session really ended.
        let manager = makeRestoredManager(
            suspectedSessionEndAt: Date(timeIntervalSinceNow: -3600),
            latestReadingTimestamp: Date(timeIntervalSinceNow: -7200)
        )

        XCTAssertNil(manager.state.sensorID)
    }

    func testRestoreKeepsSensorWhenReadingArrivedAfterGraceStart() {
        // A reading after the grace period began proves the session survived.
        let manager = makeRestoredManager(
            suspectedSessionEndAt: Date(timeIntervalSinceNow: -3600),
            latestReadingTimestamp: Date(timeIntervalSinceNow: -60)
        )

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
        XCTAssertNil(manager.state.suspectedSessionEndAt)
    }

    func testRestoreKeepsSensorWhileGraceStillRunning() {
        // Terminated one minute into a 15-minute grace period: still within the
        // window, so keep the sensor and let the re-armed deferral decide.
        let manager = makeRestoredManager(
            suspectedSessionEndAt: Date(timeIntervalSinceNow: -60),
            latestReadingTimestamp: Date(timeIntervalSinceNow: -120)
        )

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
        XCTAssertNotNil(manager.state.suspectedSessionEndAt)
    }

    func testRestoreWithNoPendingGraceLeavesSensorAlone() {
        let manager = makeRestoredManager(
            suspectedSessionEndAt: nil,
            latestReadingTimestamp: Date(timeIntervalSinceNow: -7200)
        )

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    func testSuspectedSessionEndPersistsGraceStart() {
        let manager = makeManager(gracePeriod: 10)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)

        XCTAssertNotNil(manager.state.suspectedSessionEndAt)
    }

    func testReadingClearsPersistedGraceStart() {
        let manager = makeManager(gracePeriod: 10)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)
        XCTAssertNotNil(manager.state.suspectedSessionEndAt)

        manager.sensor(manager.sensor, didRead: okGlucoseMessage)

        XCTAssertNil(manager.state.suspectedSessionEndAt)
    }

    func testSuspectedSessionEndKeepsSensorDuringGracePeriod() {
        let manager = makeManager(gracePeriod: 10)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    func testSuspectedSessionEndForgetsSensorAfterGracePeriodWithoutReadings() {
        let manager = makeManager(gracePeriod: 0.1)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)

        let forgotten = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in manager.state.sensorID == nil },
            object: nil
        )
        wait(for: [forgotten], timeout: 5)
    }

    func testReadingDuringGracePeriodPreventsForgettingSensor() {
        let manager = makeManager(gracePeriod: 0.5)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)
        manager.sensor(manager.sensor, didRead: okGlucoseMessage)

        let graceElapsed = expectation(description: "grace period elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            graceElapsed.fulfill()
        }
        wait(for: [graceElapsed], timeout: 5)

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    func testGraceExpiryAfterCommsSinceGraceStartKeepsSensor() throws {
        // A reading races the expiry: it is already dispatched when the reading
        // arrives and clears the marker. Expiry must notice it no longer owns
        // the window and leave the sensor alone.
        let manager = makeManager(gracePeriod: 100)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)
        let graceStart = try XCTUnwrap(manager.state.suspectedSessionEndAt)

        manager.sensor(manager.sensor, didRead: okGlucoseMessage)
        manager.handleSuspectedSessionEndGraceExpiry(graceStart: graceStart)

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    func testGraceExpiryWithoutCommsForgetsSensor() throws {
        let manager = makeManager(gracePeriod: 100)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)
        let graceStart = try XCTUnwrap(manager.state.suspectedSessionEndAt)

        manager.handleSuspectedSessionEndGraceExpiry(graceStart: graceStart)

        XCTAssertNil(manager.state.sensorID)
    }

    /// An expiry from a superseded grace period must not forget the sensor.
    func testStaleGraceExpiryDoesNotForgetSensor() {
        let manager = makeManager(gracePeriod: 100)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)

        manager.handleSuspectedSessionEndGraceExpiry(graceStart: Date(timeIntervalSinceNow: -3600))

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    func testNonSuspectedDisconnectDoesNotForgetSensor() {
        let manager = makeManager(gracePeriod: 0.1)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: false)

        let graceElapsed = expectation(description: "grace period elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            graceElapsed.fulfill()
        }
        wait(for: [graceElapsed], timeout: 5)

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }
}
