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

    func testSharingFollowsTheReadOnAppleWatchSetting() {
        let manager = makeManager(state: phoneState)
        XCTAssertFalse(manager.isConfigurationSharingEnabled, "off until the user turns it on")
        manager.setWatchDirectReadEnabled(true)
        XCTAssertTrue(manager.isConfigurationSharingEnabled)

        XCTAssertTrue(makeManager(state: G7CGMManagerState(rawValue: manager.rawState)).isWatchDirectReadEnabled)
        XCTAssertFalse(G7CGMManagerState(rawValue: manager.exportConfiguration().state).watchDirectReadEnabled,
                       "the setting is this controller's own")
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
        XCTAssertTrue(makeManager(state: adopted).state.configuredByAnotherController)
        XCTAssertFalse(makeManager(state: phoneState).state.configuredByAnotherController)
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
        XCTAssertTrue(restored.state.configuredByAnotherController)
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

    func testDeletingAPassedConfigurationRecordsNoSensorEnd() async {
        let manager = makeManager(state: G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state))
        await manager.delete()
        XCTAssertNil(manager.state.sensorEndRecordedFor, "the sensor's lifecycle is the other controller's")
        XCTAssertNil(manager.state.previousSensor)
        XCTAssertEqual(manager.state.sensorID, sensorID)
    }

    func testAPhoneManagerReplacingItsSensorStillDropsTheOldCode() {
        var state = phoneState
        state.sessionMode = .eavesdropping
        let manager = makeManager(state: state)
        _ = manager.sensor(manager.sensor, didDiscoverNewSensor: "DXCM77", activatedAt: Date(), peripheralIdentifier: UUID())
        XCTAssertNil(manager.state.pairingCode, "the code belonged to the sensor just replaced")
    }

    func testTheDisplaySlotFollowsTheRole() {
        let adopted = G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state)
        XCTAssertEqual(phoneState.displayType, .phone, "set up through its own UI: the phone's slot")
        XCTAssertEqual(adopted.displayType, .watch, "passed its configuration: the secondary slot")
        XCTAssertEqual(G7CGMManagerState(rawValue: adopted.rawValue).displayType, .watch, "and after a restore")
    }

    func testOnlyAPassedSensorKeepsThePeripheralItFinds() {
        let found = UUID()

        let state = phoneState
        let phone = makeManager(state: state)
        phone.sensor.bluetoothManager(phone.sensor.bluetoothManager, didAdoptPeripheral: found)
        XCTAssertEqual(phone.sensor.credentials.peripheralIdentifier, state.peripheralIdentifier, "keeps the one it paired with")
        XCTAssertEqual(phone.sensor.bluetoothManager.activePeripheralIdentifier, state.peripheralIdentifier)

        let passed = makeManager(state: G7CGMManagerState.adopted(from: phone.exportConfiguration().state))
        passed.sensor.bluetoothManager(passed.sensor.bluetoothManager, didAdoptPeripheral: found)
        XCTAssertEqual(passed.sensor.credentials.peripheralIdentifier, found, "handles are per device: it learns its own")
        XCTAssertEqual(passed.sensor.bluetoothManager.activePeripheralIdentifier, found)
        let saved = expectation(for: NSPredicate { _, _ in passed.state.peripheralIdentifier == found }, evaluatedWith: nil)
        wait(for: [saved], timeout: 2)
    }

    func testReadingDirectlyWithoutACodeOrKeyConnectsToNothing() {
        var passed = G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state)
        passed.pairingCode = nil
        passed.peripheralIdentifier = UUID()
        XCTAssertFalse(G7Sensor.canAuthenticate(mode: .direct, credentials: passed.sensorCredentials),
                       "not even its own peripheral: the link would close unauthenticated")
        XCTAssertNil(makeManager(state: passed).sensor.needsCodeForSensor, "nothing reached yet")
        XCTAssertFalse(makeManager(state: passed).sensor.bluetoothManagerCanAuthenticate(TestBluetoothManager()))

        var keyOnly = passed
        keyOnly.sharedKey = Data(repeating: 7, count: 16)
        XCTAssertTrue(G7Sensor.canAuthenticate(mode: .direct, credentials: keyOnly.sensorCredentials))
        XCTAssertTrue(G7Sensor.canAuthenticate(mode: .direct, credentials: phoneState.sensorCredentials))
        XCTAssertTrue(G7Sensor.canAuthenticate(mode: .eavesdropping, credentials: passed.sensorCredentials),
                      "eavesdropping needs neither")
    }

    func testAPassedManagerNeverDropsItsCodeOnDiscovery() {
        var state = G7CGMManagerState.adopted(from: makeManager(state: phoneState).exportConfiguration().state)
        state.sessionMode = .eavesdropping
        let manager = makeManager(state: state)
        _ = manager.sensor(manager.sensor, didDiscoverNewSensor: "DXCM77", activatedAt: Date(), peripheralIdentifier: UUID())
        XCTAssertEqual(manager.state.pairingCode, "1234")
    }

    // MARK: - A new sensor from the controller that passed the configuration

    func testANewSensorFromThePhoneKeepsTheSessionAndItsCentral() {
        let manager = makeManager(state: G7CGMManagerState.adopted(from: phoneState.sharedState))
        let central = manager.sensor.bluetoothManager
        let session = manager.sensor

        var next = phoneState
        next.sensorID = "DXCM77"
        next.pairingCode = "5678"
        next.activatedAt = Date()
        manager.adoptConfiguration(makeManager(state: next).exportConfiguration())

        XCTAssertTrue(manager.sensor === session, "the same session")
        XCTAssertTrue(manager.sensor.bluetoothManager === central,
                      "the same central: only one per app may claim the restore identifier")
        XCTAssertEqual(manager.sensor.sensorID, "DXCM77")
        XCTAssertEqual(manager.sensor.credentials.pairingCode, "5678")
        XCTAssertNil(manager.sensor.credentials.sharedKey)
        XCTAssertNil(manager.sensor.credentials.peripheralIdentifier, "the old sensor's handle goes with it")
        XCTAssertEqual(manager.state.sensorID, "DXCM77")
        XCTAssertEqual(manager.state.pairingCode, "5678")
        XCTAssertEqual(manager.state.sessionMode, .direct)
        XCTAssertTrue(manager.state.configuredByAnotherController)
        XCTAssertEqual(manager.state.displayType, .watch)
    }

    func testANewCodeForTheSameSensorIsTakenInPlace() {
        let manager = makeManager(state: G7CGMManagerState.adopted(from: phoneState.sharedState))
        var next = phoneState
        next.pairingCode = "9999"
        manager.adoptConfiguration(makeManager(state: next).exportConfiguration())
        XCTAssertEqual(manager.sensor.sensorID, sensorID)
        XCTAssertEqual(manager.sensor.credentials.pairingCode, "9999")
    }

    /// The watch's `directReadNeed` (watch target only) reports `.checkingCode` from this.
    func testTheLinkIsUpFromConnectionToDisconnection() {
        let manager = makeManager(state: G7CGMManagerState.adopted(from: phoneState.sharedState))
        XCTAssertFalse(manager.isLinkUp)
        manager.sensorDidConnect(manager.sensor, name: sensorID)
        XCTAssertTrue(manager.isLinkUp)
        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: false)
        XCTAssertFalse(manager.isLinkUp)
    }

    /// A key is not enough to read the sensor: the sensor sends readings only to a display whose Bluetooth
    /// bond it has confirmed. Until then the watch still has a need, and Start stays refused.
    func testAKeyWithoutTheBondStillLeavesANeed() {
        var adopted = G7CGMManagerState.adopted(from: phoneState.sharedState)
        adopted.sharedKey = Data(repeating: 1, count: 16)
        let manager = makeManager(state: adopted)
        XCTAssertNil(manager.passedSensorNeed, "a watch that paired before this was recorded is taken as bonded")

        manager.sensor(manager.sensor, bondIsConfirmed: false)
        XCTAssertTrue(manager.state.bondPending)
        XCTAssertEqual(manager.passedSensorNeed, .firstConnection)

        manager.sensorDidConnect(manager.sensor, name: sensorID)
        XCTAssertEqual(manager.passedSensorNeed, .checkingCode)
        manager.sensorIsAwaitingPairingAcceptance(manager.sensor)
        XCTAssertEqual(manager.passedSensorNeed, .pairingAcceptance, "the sensor keeps the link for the pairing request")

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: false)
        XCTAssertEqual(manager.passedSensorNeed, .firstConnection, "unanswered: the next connection asks again")

        manager.sensorDidConnect(manager.sensor, name: sensorID)
        manager.sensorIsAwaitingPairingAcceptance(manager.sensor)
        manager.sensor(manager.sensor, bondIsConfirmed: true)
        XCTAssertFalse(manager.state.bondPending)
        XCTAssertNil(manager.passedSensorNeed)
    }

    /// A watch that was bonded and lost its bond, with the app on screen: the handshake waits at the
    /// system's pairing request and has not ended, yet the watch already asks for the request to be accepted.
    func testALostBondAsksForThePairingRequestWhileTheHandshakeWaits() {
        var adopted = G7CGMManagerState.adopted(from: phoneState.sharedState)
        adopted.sharedKey = Data(repeating: 1, count: 16)
        let manager = makeManager(state: adopted)
        XCTAssertNil(manager.passedSensorNeed)

        manager.sensorDidConnect(manager.sensor, name: sensorID)
        manager.sensorIsAwaitingPairingAcceptance(manager.sensor)
        XCTAssertTrue(manager.state.bondPending)
        XCTAssertEqual(manager.passedSensorNeed, .pairingAcceptance)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: false)
        XCTAssertEqual(manager.passedSensorNeed, .firstConnection, "unanswered: the bond is still missing")
    }

    func testAPendingBondSurvivesARestore() {
        var adopted = G7CGMManagerState.adopted(from: phoneState.sharedState)
        adopted.sharedKey = Data(repeating: 1, count: 16)
        adopted.bondPending = true
        let restored = G7CGMManagerState(rawValue: adopted.rawValue)
        XCTAssertTrue(restored.bondPending)
        XCTAssertNil(G7CGMManagerState.adopted(from: phoneState.sharedState).rawValue["bondPending"], "not written when there is none")
    }

    /// The first pairing: the pairing request is asked for before the watch holds a key.
    func testAFirstPairingAsksForThePairingRequestToo() {
        let manager = makeManager(state: G7CGMManagerState.adopted(from: phoneState.sharedState))
        XCTAssertEqual(manager.passedSensorNeed, .firstConnection)
        manager.sensorDidConnect(manager.sensor, name: sensorID)
        manager.sensorIsAwaitingPairingAcceptance(manager.sensor)
        XCTAssertEqual(manager.passedSensorNeed, .pairingAcceptance)
    }

    func testComingOnScreenIsAnnouncedOnce() {
        let presence = G7AppPresence(onScreen: false)
        XCTAssertFalse(presence.canShowPairingRequest)
        let announced = expectation(forNotification: G7AppPresence.didComeOnScreen, object: presence)
        presence.setOnScreen(true)
        wait(for: [announced], timeout: 1)
        XCTAssertTrue(presence.canShowPairingRequest)

        let again = expectation(forNotification: G7AppPresence.didComeOnScreen, object: presence)
        again.isInverted = true
        presence.setOnScreen(true)
        wait(for: [again], timeout: 0.2)
        presence.setOnScreen(false)
        XCTAssertFalse(presence.canShowPairingRequest)
    }

    /// The watch's `readIsFromThisSensor` (watch target only) answers from this: after the phone moves to a
    /// new sensor, its latest reading is still the old sensor's.
    func testASyncIdentifierNamesTheSensorItCameFrom() {
        let manager = makeManager(state: G7CGMManagerState.adopted(from: phoneState.sharedState))
        XCTAssertEqual(manager.syncIdentifierNamesThisSensor("491234 \(sensorID) 3600"), true)
        XCTAssertEqual(manager.syncIdentifierNamesThisSensor("491234 DXCM77 3600"), false)
        XCTAssertEqual(manager.syncIdentifierNamesThisSensor("calibration \(sensorID) 1700000000.0 120"), true)
        XCTAssertNil(manager.syncIdentifierNamesThisSensor("invalid"))
    }

    func testAManagerSetUpHereKeepsItsOwnSensor() {
        let manager = makeManager(state: phoneState)
        var next = phoneState
        next.sensorID = "DXCM77"
        manager.adoptConfiguration(makeManager(state: next).exportConfiguration())
        XCTAssertEqual(manager.state.sensorID, sensorID)
    }
}
