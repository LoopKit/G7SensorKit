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
