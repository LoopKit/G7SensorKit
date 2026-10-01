//
//  G7DeviceHandoffTests.swift
//  G7SensorKitTests
//
//  Configuration sharing: what the export carries and leaves out, and how a manager passed its
//  configuration behaves differently from one set up here, decided at run time, not by platform.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import CoreBluetooth
import LoopKit
@testable import G7SensorKit

/// CBCentralManager with the state restoration option raises an exception in a test bundle.
private class TestBluetoothManager: G7BluetoothManager {
    override func makeCentralManager(queue: DispatchQueue) -> CBCentralManager {
        return CBCentralManager(delegate: self, queue: queue)
    }
}

final class G7DeviceHandoffTests: XCTestCase {

    private let sensorID = "DXCM42"
    private let activatedAt = Date(timeIntervalSinceNow: -54000)

    private func makeManager(state: G7CGMManagerState) -> G7CGMManager {
        G7CGMManager(state: state, sensor: G7Sensor(mode: state.sessionMode, credentials: state.sensorCredentials,
                                                    bluetoothManager: TestBluetoothManager()))
    }

    /// A phone following a sensor directly, with everything only it should hold.
    private var phoneState: G7CGMManagerState {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        state.sensorID = sensorID
        state.activatedAt = activatedAt
        state.pairingCode = "1234"
        state.sharedKey = Data(repeating: 7, count: 16)
        state.peripheralIdentifier = UUID()
        state.latestReadingTimestamp = Date()
        state.shareUsername = "someone"
        return state
    }

    func testExportCarriesTheSensorAndItsCodeOnly() {
        let configuration = makeManager(state: phoneState).exportConfiguration()
        let shared = G7CGMManagerState(rawValue: configuration.state)

        XCTAssertEqual(configuration.managerIdentifier, "G7CGMManager")
        XCTAssertEqual(shared.sensorID, sensorID)
        XCTAssertEqual(shared.activatedAt, activatedAt)
        XCTAssertEqual(shared.pairingCode, "1234")
        XCTAssertNil(shared.sharedKey, "the key is this controller's bond")
        XCTAssertNil(shared.peripheralIdentifier, "the peripheral handle is per device")
        XCTAssertNil(shared.latestReadingTimestamp)
        XCTAssertNil(shared.shareUsername)
        XCTAssertNil(configuration.deliveredUnits)
    }

    func testTheExportIsStableWhileTheSensorIsUnchanged() {
        var state = phoneState
        let first = makeManager(state: state).exportConfiguration()
        state.latestReadingTimestamp = Date().addingTimeInterval(300)
        state.lastAuthenticationFailure = "refused"
        let second = makeManager(state: state).exportConfiguration()
        XCTAssertEqual(first.state as NSDictionary, second.state as NSDictionary,
                       "a host rebuilds only when the export changes, so readings must not change it")
    }

    func testAdoptReadsDirectlyAndKnowsItWasPassedItsConfiguration() {
        let adopted = G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state)

        XCTAssertTrue(adopted.configuredByAnotherController)
        XCTAssertEqual(adopted.sessionMode, .direct)
        XCTAssertEqual(adopted.sensorCredentials.sensorID, sensorID)
        XCTAssertEqual(adopted.sensorCredentials.pairingCode, "1234")
        XCTAssertNil(adopted.sensorCredentials.sharedKey)
        XCTAssertEqual(adopted.activatedAt, activatedAt, "passed in, so readings are named from the first")
        XCTAssertTrue(makeManager(state: adopted).isConfiguredByAnotherController)
        XCTAssertFalse(makeManager(state: phoneState).isConfiguredByAnotherController)
    }

    func testAnAdoptedManagerAsksTheSensorForItsVersion() {
        let state = G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state)
        let sensor = G7Sensor(mode: .direct, credentials: state.sensorCredentials, bluetoothManager: TestBluetoothManager())
        let manager = G7CGMManager(adopted: state, sensor: sensor)
        XCTAssertTrue(manager.sensor.needsVersionInfo, "the version carries the session length, as on a restore")
    }

    func testAPassedConfigurationSurvivesARestore() throws {
        var adopted = G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state)
        adopted.sessionMode = .eavesdropping   // whatever was saved, a passed configuration reads directly
        let restored = makeManager(state: G7CGMManagerState(rawValue: adopted.rawValue))
        XCTAssertTrue(restored.isConfiguredByAnotherController)
        XCTAssertEqual(restored.sessionMode, .direct)
    }

    func testARestoreSetUpHereKeepsItsMode() throws {
        var state = phoneState
        state.sessionMode = .eavesdropping
        XCTAssertEqual(makeManager(state: G7CGMManagerState(rawValue: state.rawValue)).sessionMode, .eavesdropping)
    }

    func testAPassedSensorIsNotForgottenAtTheEndOfAGracePeriod() throws {
        let manager = makeManager(state: G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state))
        manager.suspectedSessionEndGracePeriod = 100

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)
        let graceStart = try XCTUnwrap(manager.state.suspectedSessionEndAt)
        manager.handleSuspectedSessionEndGraceExpiry(graceStart: graceStart)

        XCTAssertEqual(manager.state.sensorID, sensorID, "the controller that passed it decides when it ended")
        XCTAssertEqual(manager.state.pairingCode, "1234")
        XCTAssertNil(manager.state.suspectedSessionEndAt)
    }

    func testAPassedSensorIsNotForgottenWhenItsGracePeriodEndedWhileNotRunning() {
        var state = G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state)
        state.suspectedSessionEndAt = Date(timeIntervalSinceNow: -3600)

        let manager = makeManager(state: G7CGMManagerState(rawValue: state.rawValue))

        XCTAssertEqual(manager.state.sensorID, sensorID, "a relaunch must not forget what the live expiry keeps")
        XCTAssertEqual(manager.state.pairingCode, "1234")
        XCTAssertNil(manager.state.suspectedSessionEndAt)
    }

    func testDeletingAPassedConfigurationRecordsNoSensorEnd() {
        let manager = makeManager(state: G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state))
        let deleted = expectation(description: "deleted")
        manager.delete { deleted.fulfill() }
        wait(for: [deleted], timeout: 2)
        XCTAssertNil(manager.state.sensorEndRecordedFor, "the sensor's lifecycle is the other controller's")
        XCTAssertNil(manager.state.previousSensor)
        XCTAssertEqual(manager.state.sensorID, sensorID)
    }

    func testAPhoneManagerReplacingItsSensorStillDropsTheOldCode() {
        var state = phoneState
        state.sessionMode = .eavesdropping
        let manager = makeManager(state: state)
        _ = manager.sensor(manager.sensor, didDiscoverNewSensor: "DXCM77", activatedAt: Date())
        XCTAssertNil(manager.state.pairingCode, "the code belonged to the sensor just replaced")
    }

    func testAPassedManagerNeverDropsItsCodeOnDiscovery() {
        var state = G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state)
        state.sessionMode = .eavesdropping
        let manager = makeManager(state: state)
        _ = manager.sensor(manager.sensor, didDiscoverNewSensor: "DXCM77", activatedAt: Date())
        XCTAssertEqual(manager.state.pairingCode, "1234")
    }
}
